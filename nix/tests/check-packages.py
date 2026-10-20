#!/usr/bin/env python3
"""Probe the selected package closure; never infer native host capabilities."""
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest


def version_satisfies(text, minimum=None, exact=None, stable=False):
    match = re.search(r"(?<![0-9])([0-9]+\.[0-9]+(?:\.[0-9]+)?)([-+][a-zA-Z0-9.-]+)?", text)
    if not match or ((stable or exact) and match.group(2)):
        return False
    def numeric(value):
        parts = tuple(map(int, value.split(".")))
        return parts + (0,) * (3 - len(parts))
    if stable and text[match.end():].strip():
        return False
    actual = numeric(match.group(1))
    return ((minimum is None or actual >= numeric(minimum))
            and (exact is None or actual == numeric(exact)))


def coverage_errors(requirements, native, expected=()):
    errors = []
    commands = set()
    ids = [entry["id"] for entry in native]
    if len(ids) != len(set(ids)):
        errors.append("duplicate native prerequisite IDs")
    for req in requirements:
        name = req["command"]
        if name in commands:
            errors.append(f"{name}: duplicate command provider")
        commands.add(name)
        provider = bool(req.get("provider"))
        prerequisite = bool(req.get("native"))
        if provider == prerequisite:
            errors.append(f"{name}: requires exactly one package or native prerequisite")
        if prerequisite and req["native"] not in ids:
            errors.append(f"{name}: unknown native prerequisite {req['native']}")
    for name in sorted(set(expected) - commands):
        errors.append(f"{name}: missing inventory entry")
    return errors


def probe_lsp(executable, arguments, timeout=20):
    """Require an actual framed initialize result, and always reap owned processes."""
    with tempfile.TemporaryDirectory(prefix="dotfiles-lsp-") as workspace, tempfile.TemporaryFile() as stderr:
        process = subprocess.Popen(
            [executable, *arguments], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=stderr, cwd=workspace, start_new_session=True,
        )
        def send(message):
            data = json.dumps(message).encode()
            process.stdin.write(f"Content-Length: {len(data)}\r\n\r\n".encode() + data)
            process.stdin.flush()
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        try:
            send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
                "processId": os.getpid(), "rootUri": Path(workspace).as_uri(),
                "capabilities": {}, "workspaceFolders": [],
                "clientInfo": {"name": "dotfiles-package-check", "version": "1"},
            }})
            deadline = time.monotonic() + timeout
            buffer = b""
            while time.monotonic() < deadline:
                if not selector.select(max(0, deadline - time.monotonic())):
                    break
                data = os.read(process.stdout.fileno(), 65536)
                if not data:
                    break
                buffer += data
                if len(buffer) > 4 * 1024 * 1024:
                    raise RuntimeError("LSP response exceeds 4 MiB")
                while b"\r\n\r\n" in buffer:
                    headers, body = buffer.split(b"\r\n\r\n", 1)
                    match = re.search(rb"(?:^|\r\n)Content-Length: *([0-9]+)", headers, re.I)
                    if not match:
                        raise RuntimeError("LSP emitted invalid Content-Length header")
                    length = int(match.group(1))
                    if len(body) < length:
                        break
                    message = json.loads(body[:length])
                    buffer = body[length:]
                    if message.get("id") == 1 and "method" not in message:
                        result = message.get("result")
                        if not isinstance(result, dict) or not isinstance(result.get("capabilities"), dict):
                            raise RuntimeError(f"LSP initialize failed: {message}")
                        return result
                    if "method" in message and "id" in message:
                        result = ([{}] * len(message.get("params", {}).get("items", []))
                                  if message["method"] == "workspace/configuration" else None)
                        send({"jsonrpc": "2.0", "id": message["id"], "result": result})
            stderr.seek(0)
            detail = stderr.read(1000).decode(errors="replace")
            raise RuntimeError(f"LSP did not return initialize capabilities within {timeout}s: {detail}")
        except (OSError, ValueError) as error:
            raise RuntimeError(f"LSP protocol failure: {error}") from error
        finally:
            selector.close()
            # Only this invocation's fresh session is signalled, including children.
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
            # The leader may exit on TERM while a child ignores it.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=2)
            process.stdin.close()
            process.stdout.close()


def probe_cc(executable):
    with tempfile.TemporaryDirectory(prefix="dotfiles-cc-") as directory:
        binary = str(Path(directory) / "smoke")
        source = '#include <stdio.h>\nint main(void) { puts("dotfiles compiler"); return 0; }\n'
        try:
            subprocess.run([executable, "-x", "c", "-", "-o", binary], input=source,
                           capture_output=True, text=True, timeout=30, check=True)
            result = subprocess.run([binary], capture_output=True, text=True, timeout=5, check=True)
        except (OSError, subprocess.SubprocessError) as error:
            raise RuntimeError(f"C compiler compile/run failed: {error}") from error
        if result.stdout != "dotfiles compiler\n":
            raise RuntimeError("compiled C program returned unexpected output")
        return True


class GuardTests(unittest.TestCase):
    def test_compiler_requires_compilation_and_executable_result(self):
        compiler = os.environ.get("DOTFILES_TEST_CC") or shutil.which("cc")
        if not compiler:
            self.skipTest("compiler unavailable for isolated guard selftest")
        self.assertTrue(probe_cc(compiler))
        with self.assertRaises(RuntimeError):
            probe_cc(sys.executable)

    def test_version_comparison_and_stable_release(self):
        for text, minimum, exact, stable, want in [
            ("tmux 3.7c", "3.7", None, False, True),
            ("tmux 3.10", "3.7", None, False, True),
            ("NVIM v0.11.5", "0.12.0", None, False, False),
            ("taplo 0.10.0-dev", "0.10.0", None, True, False),
            ("taplo 0.10.0", "0.10.0", None, True, True),
            ("1.1.412", None, "1.1.411", False, False),
            ("1.1.411-dev", None, "1.1.411", False, False),
            ("taplo 0.10.0 unexpected-suffix", "0.10.0", None, True, False),
            ("1.1.411", None, "1.1.411", False, True),
            ("unknown", "0.8.0", None, False, False),
        ]:
            with self.subTest(text=text):
                self.assertEqual(version_satisfies(text, minimum, exact, stable), want)

    def test_missing_and_duplicate_providers_fail(self):
        self.assertTrue(coverage_errors([{"command": "git"}], []))
        self.assertTrue(coverage_errors([
            {"command": "git", "provider": "/nix/store/a"},
            {"command": "git", "provider": "/nix/store/b"},
        ], []))
        self.assertTrue(coverage_errors([
            {"command": "bwrap", "provider": "/nix/store/a", "native": "linux-bwrap"},
        ], [{"id": "linux-bwrap"}]))
        self.assertTrue(coverage_errors([{"command": "bwrap", "native": "missing"}], []))
        self.assertEqual(coverage_errors([
            {"command": "git", "provider": "/nix/store/a"},
            {"command": "bwrap", "native": "linux-bwrap"},
        ], [{"id": "linux-bwrap"}]), [])


    def test_missing_contract_command_fails_coverage(self):
        self.assertTrue(coverage_errors(
            [{"command": "git", "provider": "/nix/store/a"}], [], ["git", "taplo"]))

    def test_lsp_requires_initialize_response(self):
        server = """
import json,sys
headers={}
while True:
    line=sys.stdin.buffer.readline()
    if line == b'\\r\\n': break
    key,value=line.decode().split(':',1)
    headers[key.lower()]=value.strip()
request=json.loads(sys.stdin.buffer.read(int(headers['content-length'])))
response={'jsonrpc':'2.0','id':request['id'],'result':{'capabilities':{}}}
data=json.dumps(response).encode()
sys.stdout.buffer.write(('Content-Length: %d\\r\\n\\r\\n' % len(data)).encode()+data)
sys.stdout.buffer.flush()
sys.stdin.read()
"""
        self.assertEqual(probe_lsp(sys.executable, ["-c", server], timeout=2),
                         {"capabilities": {}})
        with self.assertRaises(RuntimeError):
            probe_lsp(sys.executable, ["-c", "print('not an LSP')"], timeout=2)
        with self.assertRaises(RuntimeError):
            probe_lsp(sys.executable, ["-c", "import time;time.sleep(30)"], timeout=0.1)

    def test_lsp_reaps_term_resistant_child_after_leader_exits(self):
        def live(pid):
            if sys.platform.startswith('linux'):
                try:
                    return (Path('/proc') / str(pid) / 'stat').read_text().rsplit(')', 1)[1].split()[0] != 'Z'
                except FileNotFoundError:
                    return False
            result = subprocess.run(['/bin/ps', '-o', 'stat=', '-p', str(pid)],
                                    capture_output=True, text=True, timeout=2)
            return bool(result.stdout.strip()) and not result.stdout.strip().startswith('Z')

        child = """
import json,os,signal,sys,time
from pathlib import Path
signal.signal(signal.SIGTERM, signal.SIG_IGN)
record=Path(sys.argv[1])
record.with_suffix('.ready').write_text(json.dumps({'child':os.getpid(),'group':os.getpgrp()}))
record.with_suffix('.ready').replace(record)
time.sleep(10)
"""
        server = """
import json,subprocess,sys,time
from pathlib import Path
record=Path(sys.argv[1])
subprocess.Popen([sys.executable,'-c',sys.argv[2],str(record)])
deadline=time.monotonic()+2
while not record.exists():
    if time.monotonic() >= deadline: raise RuntimeError('child did not become ready')
    time.sleep(0.01)
headers={}
while True:
    line=sys.stdin.buffer.readline()
    if line == b'\\r\\n': break
    key,value=line.decode().split(':',1)
    headers[key.lower()]=value.strip()
request=json.loads(sys.stdin.buffer.read(int(headers['content-length'])))
response={'jsonrpc':'2.0','id':request['id']}
if sys.argv[3] == 'success': response['result']={'capabilities':{}}
else: response['error']={'code':-32603,'message':'fixture initialize failure'}
data=json.dumps(response).encode()
sys.stdout.buffer.write(('Content-Length: %d\\r\\n\\r\\n' % len(data)).encode()+data)
sys.stdout.buffer.flush()
time.sleep(10)
"""
        for outcome in ['success', 'failure']:
            with self.subTest(outcome=outcome), tempfile.TemporaryDirectory(prefix='dotfiles-lsp-child-') as directory:
                record = Path(directory) / 'child.json'
                owned = None
                try:
                    if outcome == 'success':
                        self.assertEqual(probe_lsp(sys.executable, ['-c', server, str(record), child, outcome], timeout=3),
                                         {'capabilities': {}})
                    else:
                        with self.assertRaisesRegex(RuntimeError, 'LSP initialize failed:.*fixture initialize failure'):
                            probe_lsp(sys.executable, ['-c', server, str(record), child, outcome], timeout=3)
                    owned = json.loads(record.read_text())
                    self.assertNotEqual(owned['group'], os.getpgrp())
                    deadline = time.monotonic() + 1
                    while live(owned['child']) and time.monotonic() < deadline:
                        time.sleep(0.01)
                    with self.assertRaises(ProcessLookupError):
                        os.kill(owned['group'], 0)  # The direct child was reaped, not just killed.
                    self.assertFalse(live(owned['child']), 'owned TERM-resistant child remains live')
                finally:
                    # RED assertions must not leave this test's known fresh group alive.
                    if owned is None and record.exists():
                        owned = json.loads(record.read_text())
                    if owned is not None and owned['group'] != os.getpgrp():
                        try:
                            os.killpg(owned['group'], signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                        deadline = time.monotonic() + 2
                        while live(owned['child']) and time.monotonic() < deadline:
                            time.sleep(0.01)
                        self.assertFalse(live(owned['child']), 'test final cleanup left a live child')
                        print(json.dumps({'lspOutcome': outcome, **owned, 'noLiveOwnedChild': True}))

    def test_lsp_already_exited_group_preserves_probe_failure(self):
        with tempfile.TemporaryDirectory(prefix='dotfiles-lsp-exited-') as directory:
            record = Path(directory) / 'leader'
            server = 'import os,sys;from pathlib import Path;Path(sys.argv[1]).write_text(str(os.getpid()));sys.stdin.buffer.read1(65536);os._exit(0)'
            with self.assertRaisesRegex(RuntimeError, 'LSP did not return initialize capabilities'):
                probe_lsp(sys.executable, ['-c', server, str(record)], timeout=2)
            with self.assertRaises(ProcessLookupError):
                os.kill(int(record.read_text()), 0)


# Independent contract inventory: removing a declaration cannot make coverage pass.
COMMON_COMMANDS = {
    "git", "python3", "nvim", "tmux", "fzf", "rg", "jq", "shellcheck", "stylua",
    "tree-sitter", "herdr", "identify", "convert", "uv", "node", "npm", "dotfiles-update",
    "bash-language-server", "pyright", "pyright-langserver", "vscode-json-language-server",
    "yaml-language-server", "lua-language-server", "taplo", "iconv", "sha256sum",
    "shasum", "bash", "curl", "awk", "sed", "grep", "find", "diff", "tar", "gzip",
    "unzip", "xz", "cc", "ghostty", "visidata",
}


def check_package(req):
    executable = Path(req["provider"]) / "bin" / req["command"]
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise RuntimeError(f"missing executable {executable}")
    if req.get("npmPackage"):
        metadata = json.loads((Path(req["packageRoot"]) / req["npmPackage"] / "package.json").read_text())
        if metadata["version"] != req["exact"]:
            raise RuntimeError(f"npm version {metadata['version']} != {req['exact']}")
    if req.get("args") is not None:
        result = subprocess.run([str(executable), *req["args"]], capture_output=True,
                                text=True, timeout=20, check=True)
        output = result.stdout + result.stderr
        if not version_satisfies(output, req.get("minimum"), req.get("exact"), req.get("stable", False)):
            raise RuntimeError(f"version requirement not met: {output[:300]}")
        if req.get("maximumExclusive") and version_satisfies(output, req["maximumExclusive"]):
            raise RuntimeError(f"version must be below {req['maximumExclusive']}: {output[:300]}")
        print(f"VERSION {req['command']}: {output.splitlines()[0]}")
    if "capability" in req:
        result = subprocess.run([str(executable), *req["capability"]], input=req.get("input", ""),
                                capture_output=True, text=True, timeout=20, check=True)
        if "output" in req and result.stdout != req["output"]:
            raise RuntimeError("capability produced unexpected output")
        if "outputPrefix" in req and not result.stdout.startswith(req["outputPrefix"]):
            raise RuntimeError("checksum capability produced incorrect digest")
    if req.get("compileC"):
        probe_cc(str(executable))
    if "lsp" in req:
        probe_lsp(str(executable), req["lsp"])
    print(f"PASS {req['command']}")


def main(path):
    manifest = json.loads(Path(path).read_text())
    requirements = manifest["commandRequirements"]
    native = manifest["nativeDependencies"]
    expected = COMMON_COMMANDS | ({"bwrap", "timeout"} if manifest["system"].endswith("-linux") else set())
    errors = coverage_errors(requirements, native, expected)
    if errors:
        raise RuntimeError("incomplete package inventory: " + "; ".join(errors))
    # Resolve child-process tools only from the declared store closure.
    os.environ["PATH"] = ":".join(dict.fromkeys(
        str(Path(req["provider"]) / "bin") for req in requirements if "provider" in req))
    failures = []
    for req in requirements:
        if "native" in req:
            print(f"NATIVE {req['command']}: {req['native']} (host validation required)")
            continue
        try:
            check_package(req)
        except (RuntimeError, OSError, subprocess.SubprocessError) as error:
            failures.append(f"{req['command']}: {error}")
    if failures:
        raise RuntimeError("package check failed:\n" + "\n".join(failures))
    print(f"PASS complete {manifest['system']} package inventory; native checks deferred to target host")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        unittest.main(argv=[sys.argv[0]])
    elif len(sys.argv) == 2:
        try:
            main(sys.argv[1])
        except (RuntimeError, OSError, ValueError) as error:
            print(error, file=sys.stderr)
            sys.exit(1)
    else:
        sys.exit("usage: check-packages.py --self-test | REQUIREMENTS.json")
