#!/usr/bin/env python3
"""Exercise t with real Git worktrees/tmux and simulated graphical windows."""

import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest


REPOSITORY = Path(__file__).resolve().parents[3]
LAUNCHER = Path(os.environ.get("T_LAUNCHER", str(REPOSITORY / ".local/bin/t")))
TMUX = shutil.which("tmux")
GIT = shutil.which("git")

SHIM = r'''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
if (os.environ.get("PAIR_FAIL_ATTACH_PROBE") and "#{session_attached}" in args
        and os.path.exists(os.environ["PAIR_WINDOW_LOG"])):
    sys.exit("fixture: attachment probe failed")
if not args or ("attach-session" in args and "-c" in args):
    fd = os.open(os.environ["PAIR_ATTACH_LOG"], os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    os.write(fd, (json.dumps(args) + "\n").encode())
    os.close(fd)
    sys.exit(0)
os.execv(os.environ["PAIR_REAL_TMUX"], [os.environ["PAIR_REAL_TMUX"], "-f", "/dev/null", "-S", os.environ["PAIR_SOCKET"], *args])
'''

GHOSTTY = r'''#!/usr/bin/env python3
import json, os, signal, subprocess, sys
args = sys.argv[1:]
fd = os.open(os.environ["PAIR_WINDOW_LOG"], os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
os.write(fd, (json.dumps({"pid": os.getpid(), "args": args}) + "\n").encode())
os.close(fd)
if os.environ.get("PAIR_FAIL_WINDOW"):
    sys.exit(1)
if os.environ.get("PAIR_STALL_WINDOW"):
    signal.pause()
assert "TMUX" not in os.environ and "TMUX_PANE" not in os.environ
command = args[args.index("-e") + 1:]
child = subprocess.Popen([command[0], "-C", *command[1:]], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
def stop(*_):
    child.terminate()
signal.signal(signal.SIGTERM, stop)
child.wait()
'''


class ProjectPairs(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="project-pairs-")
        self.root = Path(self.temporary.name)
        self.socket = str(self.root / "tmux.sock")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.home = self.root / "home"
        scripts = self.home / ".config/tmux/scripts"
        scripts.mkdir(parents=True)
        self.launcher = self.home / ".local/bin/t"
        self.launcher.parent.mkdir(parents=True)
        shutil.copy2(LAUNCHER, self.launcher)
        for name in ("workspace", "project-session"):
            shutil.copy2(REPOSITORY / ".config/tmux/scripts" / name, scripts / name)
        self.windows = self.root / "windows.jsonl"
        self.attachments = self.root / "attach.jsonl"
        for name, content in (("tmux", SHIM), ("ghostty", GHOSTTY), ("nvim", "#!/bin/sh\nexec sleep 3600\n")):
            path = self.bin / name
            path.write_text(content)
            path.chmod(0o700)
        inherited = {key: value for key, value in os.environ.items()
                     if not key.startswith("TMUX_WORKSPACE_") and key not in
                     ("NVIM", "NVIM_APPNAME", "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR")}
        self.env = dict(inherited, HOME=str(self.home),
                        XDG_CONFIG_HOME=str(self.home / ".config"),
                        XDG_CACHE_HOME=str(self.root / "cache"), XDG_DATA_HOME=str(self.root / "data"),
                        GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1",
                        PATH=str(self.bin) + ":" + os.environ["PATH"], TMUX="", TMUX_PANE="",
                        DISPLAY=":fixture", WAYLAND_DISPLAY="", SSH_CONNECTION="", SSH_CLIENT="", SSH_TTY="",
                        XDG_STATE_HOME=str(self.root / "state"), XDG_RUNTIME_DIR=str(self.root / "runtime"),
                        TMUX_WORKSPACE_TESTING="1", TMUX_WORKSPACE_SOCKET=self.socket,
                        PAIR_REAL_TMUX=TMUX, PAIR_SOCKET=self.socket,
                        PAIR_WINDOW_LOG=str(self.windows), PAIR_ATTACH_LOG=str(self.attachments), SHELL="/bin/sh")

    def tearDown(self):
        subprocess.run([TMUX, "-S", self.socket, "kill-server"], env=self.env, capture_output=True)
        for item in self.window_log():
            try:
                os.kill(item["pid"], signal.SIGTERM)
            except ProcessLookupError:
                pass
        self.temporary.cleanup()

    def git(self, *args):
        return subprocess.run([GIT, *map(str, args)], env=self.env,
                              check=True, capture_output=True, text=True).stdout

    def repository(self, name):
        path = self.root / name
        path.mkdir(parents=True)
        self.git("init", "-q", path)
        self.git("-C", path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                 "commit", "--allow-empty", "-qm", "initial")
        return path

    def tmux(self, *args):
        return subprocess.run([TMUX, "-f", "/dev/null", "-S", self.socket, *args],
                              env=self.env, check=True, capture_output=True, text=True).stdout.removesuffix("\n")

    def launch(self, path, arguments=(), **extra):
        result = subprocess.run([self.launcher, *arguments], cwd=path, env=dict(self.env, **extra), capture_output=True,
                                text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def sessions(self):
        return self.tmux("list-sessions", "-F", "#{session_id}").splitlines()

    def value(self, session, expression):
        return self.tmux("display-message", "-p", "-t", session + ":", expression)

    def pair(self, root, editor_attached=1):
        matches = [item for item in self.sessions() if self.value(item, "#{session_path}") == str(root)]
        self.assertEqual(len(matches), 2)
        pair = {self.value(item, "#{@dotfiles_project_role}"): item for item in matches}
        self.assertEqual(set(pair), {"shell", "nvim"})
        self.assertEqual(self.value(pair["shell"], "#{@dotfiles_project_editor}"), pair["nvim"])
        self.assertEqual(self.value(pair["nvim"], "#{@dotfiles_project_shell}"), pair["shell"])
        self.assertEqual(self.value(pair["nvim"], "#{session_attached}"), str(editor_attached))
        return pair

    def window_log(self):
        return [json.loads(line) for line in self.windows.read_text().splitlines()] if self.windows.exists() else []

    def test_default_launch_reuses_only_the_shell(self):
        root = self.repository("shell only")
        nested = root / "src"
        nested.mkdir()
        self.launch(root)
        sessions = self.sessions()
        self.assertEqual(len(sessions), 1)
        pane = self.value(sessions[0], "#{pane_id}")
        for directory, environment in (
            (nested, {}),
            (root, {"SSH_CONNECTION": "fixture"}),
            (root, {"DISPLAY": "", "WAYLAND_DISPLAY": ""}),
        ):
            result = self.launch(directory, **environment)
            self.assertEqual(self.sessions(), sessions)
            self.assertEqual(self.value(sessions[0], "#{pane_id}"), pane)
            self.assertNotIn("Neovim is ready", result.stderr)
            last = json.loads(self.attachments.read_text().splitlines()[-1])
            self.assertEqual(last[-1], sessions[0])
        self.assertEqual(self.window_log(), [])

    def test_editor_opt_in_reuses_the_default_shell(self):
        root = self.repository("opt in")
        self.launch(root)
        shell = self.sessions()[0]
        pane = self.value(shell, "#{pane_id}")
        self.launch(root, arguments=("--with-editor",))
        pair = self.pair(root)
        self.assertEqual(pair["shell"], shell)
        self.assertEqual(self.value(shell, "#{pane_id}"), pane)
        self.launch(root)
        self.assertEqual(self.pair(root), pair)
        last = json.loads(self.attachments.read_text().splitlines()[-1])
        self.assertEqual(last[-1], shell)
        self.assertEqual(len(self.window_log()), 1)

    def test_repeat_and_nested_launch_reuse_the_editor(self):
        root = self.repository("project alpha")
        nested = root / "src"
        nested.mkdir()
        self.launch(nested, arguments=("--with-editor",))
        first = self.pair(root)
        pid = self.value(first["nvim"], "#{pane_pid}")
        self.launch(root, arguments=("--with-editor",))
        self.launch(nested, arguments=("--with-editor",))
        self.assertEqual(first, self.pair(root))
        self.assertEqual(pid, self.value(first["nvim"], "#{pane_pid}"))
        self.assertEqual(len(self.window_log()), 1)
        self.assertEqual(len(self.attachments.read_text().splitlines()), 3)

    def test_linked_worktrees_remain_independent(self):
        main = self.repository("repository")
        feature = self.root / "feature worktree"
        self.git("-C", main, "worktree", "add", "-qb", "feature", feature)
        self.launch(main, arguments=("--with-editor",))
        first = self.pair(main)
        editor_pid = self.value(first["nvim"], "#{pane_pid}")
        self.launch(feature, arguments=("--with-editor",))
        second = self.pair(feature)
        self.assertEqual(len(self.sessions()), 4)
        self.assertTrue(set(first.values()).isdisjoint(second.values()))
        self.assertEqual(editor_pid, self.value(first["nvim"], "#{pane_pid}"))
        self.assertEqual(len(self.window_log()), 2)
        self.launch(main, arguments=("--with-editor",))
        self.assertEqual(first, self.pair(main))
        self.assertEqual(second, self.pair(feature))
        self.assertEqual(len(self.window_log()), 2)

    def test_same_directory_names_do_not_collide(self):
        left = self.repository("left/repo")
        right = self.repository("right/repo")
        self.launch(left, arguments=("--with-editor",))
        self.launch(right, arguments=("--with-editor",))
        self.assertNotEqual(self.pair(left), self.pair(right))
        self.assertEqual(len(self.sessions()), 4)

    def test_closed_window_reopens_the_same_neovim(self):
        root = self.repository("reopen")
        self.launch(root, arguments=("--with-editor",))
        pair = self.pair(root)
        pid = self.value(pair["nvim"], "#{pane_pid}")
        os.kill(self.window_log()[0]["pid"], signal.SIGTERM)
        for _ in range(100):
            if self.value(pair["nvim"], "#{session_attached}") == "0":
                break
            time.sleep(0.02)
        self.launch(root)
        self.assertEqual(pair, self.pair(root, editor_attached=0))
        self.assertEqual(pid, self.value(pair["nvim"], "#{pane_pid}"))
        self.assertEqual(len(self.window_log()), 1)
        self.launch(root, arguments=("--with-editor",))
        self.assertEqual(pair, self.pair(root))
        self.assertEqual(pid, self.value(pair["nvim"], "#{pane_pid}"))
        self.assertEqual(len(self.window_log()), 2)

    def test_reconnect_repairs_unpersisted_pair_options(self):
        root = self.repository("restored")
        self.launch(root, arguments=("--with-editor",))
        pair = self.pair(root)
        for session in pair.values():
            for option in ("role", "editor", "shell"):
                self.tmux("set-option", "-uq", "-t", session, "@dotfiles_project_" + option)
        self.launch(root, arguments=("--with-editor",))
        self.assertEqual(pair, self.pair(root))
        self.assertEqual(len(self.window_log()), 1)

    def test_existing_exact_directory_shell_is_preserved(self):
        root = self.repository("existing")
        self.tmux("new-session", "-d", "-s", "my-custom-session", "-c", str(root))
        self.assertEqual(self.tmux("show-environment", "-g", "HOME"), "HOME=" + str(self.home))
        original = self.value("=my-custom-session", "#{session_id}")
        pane = self.value(original, "#{pane_id}")
        self.launch(root)
        self.assertEqual(self.sessions(), [original])
        self.assertEqual(pane, self.value(original, "#{pane_id}"))
        self.assertEqual(self.window_log(), [])

    def test_concurrent_launches_create_one_pair(self):
        root = self.repository("concurrent")
        processes = [subprocess.Popen([self.launcher, "--with-editor"], cwd=root, env=self.env, stdout=subprocess.PIPE,
                                      stderr=subprocess.PIPE, text=True) for _ in range(2)]
        results = []
        for process in processes:
            _, error = process.communicate(timeout=20)
            results.append((process.returncode, error))
        for status, error in results:
            self.assertEqual(status, 0, error)
        self.pair(root)
        self.assertEqual(len(self.sessions()), 2)
        self.assertEqual(len(self.window_log()), 1)

    def test_failed_graphical_launch_can_be_retried(self):
        root = self.repository("window-failure")
        result = subprocess.run([self.launcher, "--with-editor"], cwd=root, env=dict(self.env, PAIR_FAIL_WINDOW="1"),
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 1)
        self.assertIn("Ghostty exited", result.stderr)
        sessions = self.sessions()
        self.assertEqual(len(sessions), 2)
        self.launch(root, arguments=("--with-editor",))
        self.pair(root)
        self.assertEqual(sessions, self.sessions())

    def test_failed_attachment_probe_reaps_the_new_terminal(self):
        root = self.repository("probe failure")
        result = subprocess.run(
            [self.launcher, "--with-editor"], cwd=root,
            env=dict(self.env, PAIR_STALL_WINDOW="1", PAIR_FAIL_ATTACH_PROBE="1"),
            capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("attachment probe failed", result.stderr)
        windows = self.window_log()
        self.assertEqual(len(windows), 1)
        with self.assertRaises(ProcessLookupError, msg="failed launch left its terminal process running"):
            os.kill(windows[0]["pid"], 0)

    def test_symbolic_path_reuses_the_physical_worktree(self):
        root = self.repository("physical")
        symbolic = self.root / "alias"
        symbolic.symlink_to(root, target_is_directory=True)
        self.launch(symbolic, arguments=("--with-editor",))
        first = self.pair(root)
        self.launch(root, arguments=("--with-editor",))
        self.assertEqual(first, self.pair(root))
        self.assertEqual(len(self.window_log()), 1)

    def test_directory_with_shell_characters_and_trailing_newline(self):
        root = self.repository("literal $(touch NEVER) ' [x];\n")
        self.launch(root, arguments=("--with-editor",))
        first = self.pair(root)
        self.launch(root, arguments=("--with-editor",))
        self.assertEqual(first, self.pair(root))
        self.assertFalse((root / "NEVER").exists())
        self.assertEqual(len(self.window_log()), 1)

    def test_ambiguous_exact_directory_remains_an_error(self):
        root = self.repository("ambiguous")
        for name in ("one", "two"):
            self.tmux("new-session", "-d", "-s", name, "-c", str(root))
        result = subprocess.run([self.launcher], cwd=root, env=self.env, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 1)
        self.assertIn("multiple sessions use directory", result.stderr)
        self.assertEqual(len(self.sessions()), 2)
        self.assertEqual(self.window_log(), [])

    def test_exact_non_git_session_gets_a_pair(self):
        root = self.root / "notes"
        root.mkdir()
        self.tmux("new-session", "-d", "-s", "notes", "-c", str(root))
        self.launch(root, arguments=("--with-editor",))
        self.pair(root)

    def test_unmatched_non_git_directory_keeps_native_fallback(self):
        self.launch(self.root)
        self.assertEqual(json.loads(self.attachments.read_text()), [])
        self.assertEqual(self.window_log(), [])

    def test_invalid_invocations_do_not_create_sessions(self):
        for arguments, extra, expected in (([], {"TMUX": "existing"}, 1), (["unexpected"], {}, 2),
                                           (["--editor", "unexpected"], {}, 2),
                                           (["--with-editor", "unexpected"], {}, 2),
                                           (["--editor", "--with-editor"], {}, 2)):
            result = subprocess.run([self.launcher, *arguments], cwd=self.root, env=dict(self.env, **extra),
                                    capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, expected)
        self.assertFalse(Path(self.socket).exists())
        self.assertEqual(self.window_log(), [])

    def test_ssh_attaches_shell_without_launching_a_remote_window(self):
        root = self.repository("remote")
        for key in ("SSH_CONNECTION", "SSH_CLIENT", "SSH_TTY"):
            with self.subTest(key=key):
                # Even a forwarded DISPLAY must not launch a remote Ghostty.
                result = self.launch(root, arguments=("--with-editor",),
                                     **{key: "fixture", "PAIR_FAIL_WINDOW": "1"})
                pair = self.pair(root, editor_attached=0)
                last = json.loads(self.attachments.read_text().splitlines()[-1])
                self.assertEqual(last[-1], pair["shell"])
                self.assertIn("t --editor", result.stderr)
        self.assertEqual(len(self.sessions()), 2)
        self.assertEqual(self.window_log(), [])

    def test_second_ssh_terminal_attaches_existing_editor(self):
        root = self.repository("remote editor")
        self.launch(root, arguments=("--with-editor",), SSH_CONNECTION="fixture")
        pair = self.pair(root, editor_attached=0)
        pid = self.value(pair["nvim"], "#{pane_pid}")
        self.launch(root, arguments=("--editor",), SSH_CONNECTION="fixture")
        last = json.loads(self.attachments.read_text().splitlines()[-1])
        self.assertEqual(last[-1], pair["nvim"])
        self.assertEqual(pid, self.value(pair["nvim"], "#{pane_pid}"))
        self.assertEqual(len(self.sessions()), 2)
        self.assertEqual(self.window_log(), [])

    def test_headless_launch_still_attaches_shell(self):
        root = self.repository("headless")
        self.launch(root, arguments=("--with-editor",), DISPLAY="", WAYLAND_DISPLAY="", PAIR_FAIL_WINDOW="1")
        pair = self.pair(root, editor_attached=0)
        last = json.loads(self.attachments.read_text().splitlines()[-1])
        self.assertEqual(last[-1], pair["shell"])
        self.assertEqual(self.window_log(), [])

    def test_explicit_editor_can_open_first_without_ghostty(self):
        root = self.repository("editor first")
        self.launch(root, arguments=("--editor",), PAIR_FAIL_WINDOW="1")
        pair = self.pair(root, editor_attached=0)
        last = json.loads(self.attachments.read_text().splitlines()[-1])
        self.assertEqual(last[-1], pair["nvim"])
        self.assertEqual(self.window_log(), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
