"""Exercise session navigation on private tmux servers, never the user's server."""
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import shlex
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
import unittest

SOURCE = Path(__file__).resolve().parents[2]
HELPER = Path(os.environ.get('DOTFILES_SESSION_NAVIGATOR_HELPER',
                             SOURCE / '.config/tmux/scripts/session-navigator'))
KEYS = Path(os.environ.get('DOTFILES_SESSION_NAVIGATOR_KEYS', SOURCE / '.config/tmux/conf/keys.conf'))
TMUX = shutil.which('tmux')
FZF = shutil.which('fzf')

FZF_SHIM = r'''
import json, os, subprocess, sys
from pathlib import Path
data = sys.stdin.buffer.read()
Path(os.environ['NAV_INPUT']).write_bytes(data)
Path(os.environ['NAV_ENV']).write_text(json.dumps(dict(os.environ)))
mode = os.environ.get('NAV_MODE', 'select')
if mode in ('cancel', 'interrupt', 'error'):
    sys.exit({'cancel': 1, 'interrupt': 130, 'error': 2}[mode])
record = next(row for row in data.split(b'\0')
              if row.startswith(os.environ['NAV_SELECTED'].encode() + b'\t'))
if mode == 'disappear':
    subprocess.run([os.environ['NAV_TMUX'], '-S', os.environ['NAV_SOCKET'],
                    'kill-session', '-t', os.environ['NAV_SELECTED']], check=True)
elif mode == 'detach':
    subprocess.run([os.environ['NAV_TMUX'], '-S', os.environ['NAV_SOCKET'],
                    'detach-client', '-t', os.environ['NAV_CLIENT']], check=True)
if mode == 'modified':
    record += b' forged label'
elif mode == 'foreign':
    record = b'$999999\tnot offered'
elif mode == 'multiple':
    record += b'\0' + record
elif mode == 'empty':
    record = b''
sys.stdout.buffer.write(record + (b'' if mode == 'unterminated' else b'\0'))
'''


@unittest.skipUnless(TMUX, 'tmux is required for private session navigation tests')
class SessionNavigatorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='sn-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.home = self.root / 'home with space'
        self.home.mkdir()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.socket = self.root / "s' $"
        self.env = {'HOME': str(self.home), 'PATH': str(self.bin) + ':' + os.environ.get('PATH', os.defpath),
                    'TERM': 'xterm-256color', 'LANG': 'C.UTF-8', 'SHELL': '/bin/sh',
                    'TMUX': str(self.root / 'wrong-socket') + ',0,0', 'TMUX_PANE': '%999999',
                    'NAV_INPUT': str(self.root / 'fzf-input'), 'NAV_ENV': str(self.root / 'fzf-env'),
                    'NAV_TMUX': TMUX, 'NAV_SOCKET': str(self.socket)}
        self.clients = []
        self.server = subprocess.Popen([TMUX, '-D', '-S', str(self.socket), '-f', '/dev/null'],
                                       env=self.env, cwd=self.home, stdout=subprocess.DEVNULL,
                                       stderr=subprocess.DEVNULL)
        self.addCleanup(self.stop)
        self.wait(self.socket.exists)
        self.first = self.session('origin')
        self.second = self.session('other-client')
        self.target = self.session('destination')
        self.command('set-option', '-g', 'status', 'off')
        self.command('set-option', '-s', 'escape-time', '10')
        self.invoker = self.attach(self.first)
        self.other = self.attach(self.second)
        self.write_fzf(FZF_SHIM)

    def command(self, *args):
        result = subprocess.run([TMUX, '-S', str(self.socket), '-f', '/dev/null', *args],
                                env=self.env, cwd=self.home, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.removesuffix('\n')

    def session(self, name, path=None):
        return self.command('new-session', '-d', '-P', '-F', '#{session_id}', '-s', name,
                            '-c', str(path or self.home), '/bin/sh')

    def attach(self, session):
        pid, master = pty.fork()
        if pid == 0:
            env = {key: value for key, value in self.env.items() if key not in ('TMUX', 'TMUX_PANE')}
            os.execve(TMUX, [TMUX, '-S', str(self.socket), 'attach-session', '-t', session], env)
        client = {'pid': pid, 'master': master, 'output': bytearray()}
        self.clients.append(client)
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 120, 0, 0))
        os.kill(pid, signal.SIGWINCH)

        def identify():
            for line in self.command('list-clients', '-F', '#{client_pid}\t#{client_name}').splitlines():
                client_pid, name = line.split('\t')
                if client_pid == str(pid):
                    client['name'] = name
                    return True
            return False

        self.wait(identify)
        return client

    def drain(self):
        for client in self.clients:
            while select.select([client['master']], [], [], 0)[0]:
                try:
                    data = os.read(client['master'], 65536)
                except OSError:
                    break
                if not data:
                    break
                client['output'].extend(data)

    def wait(self, predicate, timeout=5):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.drain()
            if predicate():
                return
            time.sleep(0.02)
        self.fail('private tmux did not reach expected state; output=' + repr(bytes(self.invoker['output'])[-1000:]
                  if hasattr(self, 'invoker') else b''))

    def positions(self):
        return dict(line.split('\t') for line in
                    self.command('list-clients', '-F', '#{client_name}\t#{session_id}').splitlines())

    def write_fzf(self, body):
        executable = self.bin / 'fzf'
        executable.write_text('#!' + sys.executable + '\n' + body)
        executable.chmod(0o755)

    def navigate(self, mode='select', target=None, **extra):
        return subprocess.run([str(HELPER), str(self.socket), self.invoker['name']],
                              env=dict(self.env, NAV_MODE=mode, NAV_SELECTED=target or self.target,
                                       NAV_CLIENT=self.invoker['name'], **extra),
                              cwd=self.home, text=True, capture_output=True, timeout=10)

    def stop(self):
        subprocess.run([TMUX, '-S', str(self.socket), 'kill-server'], env=self.env,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
        try:
            self.server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.server.kill()
            self.server.wait()
        for client in self.clients:
            try:
                os.kill(client['pid'], signal.SIGTERM)
            except ProcessLookupError:
                pass
            os.waitpid(client['pid'], 0)
            os.close(client['master'])

    def test_selection_switches_only_the_invoking_client(self):
        result = self.navigate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.positions(), {self.invoker['name']: self.target,
                                           self.other['name']: self.second})

    def test_cancellation_does_not_switch_either_client(self):
        before = self.positions()
        for mode in ('cancel', 'interrupt'):
            with self.subTest(mode=mode):
                result = self.navigate(mode)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.positions(), before)

    def test_fzf_error_or_unoffered_output_does_not_switch(self):
        before = self.positions()
        for mode in ('error', 'modified', 'foreign', 'multiple', 'empty', 'unterminated'):
            with self.subTest(mode=mode):
                result = self.navigate(mode)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertEqual(self.positions(), before)

    def test_disappearing_selection_does_not_switch_to_a_name_prefix(self):
        similar = self.session('destination-other')
        before = self.positions()
        result = self.navigate('disappear')
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.positions(), before)
        self.assertIn(similar, self.command('list-sessions', '-F', '#{session_id}').splitlines())

    def test_disappearing_invoker_does_not_switch_the_remaining_client(self):
        result = self.navigate('detach')
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.positions(), {self.other['name']: self.second})

    def test_names_and_paths_are_display_only_and_controls_are_escaped(self):
        marker = self.root / 'INJECTED'
        suffix = " λ ' \" ; $(touch " + str(marker) + ") `touch " + str(marker) + "`"
        path = self.root / ('project' + suffix.replace('/', '_') + '\tline\nnext\x1b[31m')
        path.mkdir()
        target = self.session('destination' + suffix, path)
        result = self.navigate(target=target)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.positions(), {self.invoker['name']: target,
                                           self.other['name']: self.second})
        records = (self.root / 'fzf-input').read_bytes().split(b'\0')
        record = next(row for row in records if row.startswith(target.encode() + b'\t'))
        label = record.split(b'\t', 1)[1].decode()
        self.assertIn('λ', label)
        self.assertIn('destination', label)
        self.assertIn('project', label)
        self.assertIn(str(self.root), label)
        self.assertFalse(any(ord(char) < 32 or ord(char) == 127 for char in label), repr(label))
        self.assertFalse(marker.exists(), 'a display label was evaluated as shell or tmux code')

    def test_inherited_fzf_options_cannot_change_selection_protocol(self):
        options = self.root / 'fzf-options'
        options.write_text('--print-query --multi\n')
        result = self.navigate(FZF_DEFAULT_OPTS='--expect=enter --filter=origin',
                               FZF_DEFAULT_OPTS_FILE=str(options))
        self.assertEqual(result.returncode, 0, result.stderr)
        child_environment = json.loads((self.root / 'fzf-env').read_text())
        self.assertNotIn('FZF_DEFAULT_OPTS', child_environment)
        self.assertNotIn('FZF_DEFAULT_OPTS_FILE', child_environment)
        self.assertEqual(self.positions()[self.invoker['name']], self.target)

    @unittest.skipUnless(FZF, 'fzf is required for the genuine popup input test')
    def test_real_fzf_popup_search_and_cancellation_through_prefix(self):
        scripts = self.home / '.config/tmux/scripts'
        scripts.mkdir(parents=True)
        shutil.copy2(HELPER, scripts / 'session-navigator')
        installed_keys = scripts.parent / 'keys.conf'
        shutil.copy2(KEYS, installed_keys)
        self.command('source-file', str(installed_keys))
        self.command('set-option', '-g', 'prefix', 'M-Space')
        self.command('set-option', '-g', 'prefix2', 'None')
        path = self.root / "path-only-search-token-λ ' quoted"
        path.mkdir()
        target = self.session("popup-λ ' quoted", path)
        ready = self.root / 'real-fzf-ready'
        finished = self.root / 'real-fzf-finished'
        searched = self.root / 'real-fzf-searched'
        observer = '--bind=result:execute-silent(printf %s {q} > ' + shlex.quote(str(searched)) + ')'
        self.write_fzf('import os, subprocess, sys\nfrom pathlib import Path\n'
                       + 'Path(' + repr(str(ready)) + ').write_text(str(os.getppid()))\n'
                       + 'result = subprocess.run([' + repr(FZF) + ', *sys.argv[1:], ' + repr(observer) + '])\n'
                       + 'Path(' + repr(str(finished)) + ').write_text(str(result.returncode))\n'
                       + 'sys.exit(result.returncode)\n')
        self.command('set-environment', '-g', 'FZF_DEFAULT_OPTS', '--filter=must-not-match')

        def popup():
            ready.unlink(missing_ok=True)
            finished.unlink(missing_ok=True)
            searched.unlink(missing_ok=True)
            self.invoker['output'].clear()
            os.write(self.invoker['master'], b'\x1b ')
            self.wait(lambda: self.invoker['name'] + '\t1' in self.command(
                'list-clients', '-F', '#{client_name}\t#{client_prefix}').splitlines())
            os.write(self.invoker['master'], b'f')
            self.wait(lambda: ready.exists() and searched.exists())

        def closed():
            if not finished.exists():
                return False
            try:
                os.kill(int(ready.read_text()), 0)
            except ProcessLookupError:
                return True
            return False

        for query in (b'pthonlysrch', b'popup'):
            with self.subTest(query=query):
                self.command('switch-client', '-c', self.invoker['name'], '-t', self.first)
                popup()
                os.write(self.invoker['master'], query)
                self.wait(lambda: searched.exists() and searched.read_bytes() == query)
                os.write(self.invoker['master'], b'\r')
                self.wait(closed)
                self.assertEqual(finished.read_text(), '0')
                self.wait(lambda: self.positions().get(self.invoker['name']) == target)
                self.assertEqual(self.positions()[self.other['name']], self.second)
        for key in (b'\x1b', b'\x03'):
            with self.subTest(cancel_key=key):
                before = self.positions()
                popup()
                os.write(self.invoker['master'], key)
                self.wait(closed)
                self.assertEqual(finished.read_text(), '130')
                self.assertEqual(self.positions(), before)


if __name__ == '__main__':
    unittest.main(verbosity=2)
