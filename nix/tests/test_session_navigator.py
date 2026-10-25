"""Exercise session navigation on private tmux servers, never the user's server."""
import errno
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
PROJECT_HELPER = HELPER.resolve().with_name('project-session')
KEYS = Path(os.environ.get('DOTFILES_SESSION_NAVIGATOR_KEYS', SOURCE / '.config/tmux/conf/keys.conf'))
TMUX = shutil.which('tmux')
FZF = shutil.which('fzf')

FZF_SHIM = r'''
import json, os, subprocess, sys
from pathlib import Path
data = sys.stdin.buffer.read()
Path(os.environ['NAV_INPUT']).write_bytes(data)
Path(os.environ['NAV_ENV']).write_text(json.dumps(dict(os.environ)))
calls = Path(os.environ['NAV_CALLS'])
stage = len(calls.read_text().splitlines()) if calls.exists() else 0
with calls.open('a') as log:
    log.write(json.dumps({'prompt': next(arg for arg in sys.argv if arg.startswith('--prompt=')),
                         'records': data.decode().rstrip('\0').split('\0')}) + '\n')
modes = json.loads(os.environ['NAV_MODES'])
mode = modes[min(stage, len(modes) - 1)]
if mode in ('cancel', 'interrupt', 'error'):
    sys.exit({'cancel': 1, 'interrupt': 130, 'error': 2}[mode])
allowed = json.loads(os.environ['NAV_PROJECT_IDS']) if stage == 0 else [os.environ['NAV_SELECTED']]
record = next(row for row in data.split(b'\0')
              if row.split(b'\t', 1)[0].decode() in allowed)
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
                    'NAV_CALLS': str(self.root / 'fzf-calls'),
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
        if path is None:
            path = self.root / 'projects' / name
            path.mkdir(parents=True, exist_ok=True)
        return self.command('new-session', '-d', '-P', '-F', '#{session_id}', '-s', name,
                            '-c', str(path), '/bin/sh')

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

    def picker_calls(self):
        return [json.loads(line) for line in (self.root / 'fzf-calls').read_text().splitlines()]

    def managed_editor_name(self, path):
        result = subprocess.run([sys.executable, str(PROJECT_HELPER), 'editor-name', str(path)],
                                env=self.env, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.removesuffix('\n')

    def navigate(self, mode='select', target=None, project_ids=None, helper=HELPER, **extra):
        target = target or self.target
        (self.root / 'fzf-calls').unlink(missing_ok=True)
        return subprocess.run([str(helper), str(self.socket), self.invoker['name']],
                              env=dict(self.env, NAV_MODES=json.dumps(mode if isinstance(mode, list) else [mode]),
                                       NAV_SELECTED=target, NAV_PROJECT_IDS=json.dumps(project_ids or [target]),
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
        self.assertEqual(len(self.picker_calls()), 1, 'singleton project should switch directly')
        labels = dict(row.split('\t', 1) for row in self.picker_calls()[0]['records'])
        self.assertTrue(labels[self.first].startswith('● '))
        self.assertTrue(labels[self.second].startswith('  '))
        result = self.navigate('cancel')
        self.assertEqual(result.returncode, 0, result.stderr)
        labels = dict(row.split('\t', 1) for row in self.picker_calls()[0]['records'])
        self.assertTrue(labels[self.target].startswith('● '))
        self.assertTrue(labels[self.first].startswith('  '))
        self.assertEqual(self.positions(), {self.invoker['name']: self.target,
                                           self.other['name']: self.second})

    def test_active_markers_use_the_invoking_client_and_group_membership(self):
        path = self.root / 'active-project'
        path.mkdir()
        names = ('a-shell', self.managed_editor_name(path), 'z-extra')
        members = [self.session(name, path) for name in names]
        self.command('switch-client', '-c', self.invoker['name'], '-t', members[1])
        self.command('switch-client', '-c', self.other['name'], '-t', members[2])
        before = self.positions()
        result = self.navigate(['select', 'cancel'], target=members[1], project_ids=members)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.picker_calls()
        projects = dict(row.split('\t', 1) for row in calls[0]['records'])
        marked = [identity for identity, label in projects.items() if label.startswith('● ')]
        self.assertEqual(marked, [members[0]], 'active session is not the project representative')
        self.assertTrue(all(label.startswith('  ') for identity, label in projects.items()
                            if identity != members[0]))
        sessions = dict(row.split('\t', 1) for row in calls[1]['records'])
        self.assertEqual(sessions, {members[0]: '  Terminal · a-shell',
                                    members[1]: '● Editor · Neovim',
                                    members[2]: '  Terminal · z-extra'})
        self.assertEqual(self.positions(), before)

    def test_shared_directory_is_one_project_with_every_session_selectable(self):
        path = self.root / 'shared-project'
        path.mkdir()
        members = [self.session(name, path) for name in ('project-shell', 'nvim-project', 'extra-shell')]
        result = self.navigate(target=members[-1], project_ids=members)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.picker_calls()
        self.assertEqual(len(calls), 2, 'shared project must open a second session picker')
        self.assertEqual(calls[0]['prompt'], '--prompt=Projects> ')
        self.assertEqual(calls[1]['prompt'], '--prompt=Sessions> ')
        self.assertEqual(len(calls[0]['records']), 4)
        project_rows = [row for row in calls[0]['records'] if row.split('\t', 1)[0] in members]
        self.assertEqual(len(project_rows), 1)
        self.assertIn(str(path), project_rows[0])
        self.assertIn('3 sessions', project_rows[0])
        self.assertEqual({row.split('\t', 1)[0] for row in calls[1]['records']}, set(members))
        self.assertEqual(self.positions(), {self.invoker['name']: members[-1],
                                           self.other['name']: self.second})

    def test_friendly_labels_identify_only_the_exact_managed_editor_without_renaming(self):
        path = self.root / 'friendly-project'
        path.mkdir()
        names = ('my-shell', self.managed_editor_name(path), 'nvim-custom', 'extra-terminal')
        members = [self.session(name, path) for name in names]
        self.assertEqual(self.command('show-options', '-qv', '-t', members[1], '@dotfiles_project_role'), '')
        before = self.command('list-sessions', '-F', '#{session_id}\t#{session_name}')
        result = self.navigate(target=members[1], project_ids=members)
        self.assertEqual(result.returncode, 0, result.stderr)
        labels = dict(row.split('\t', 1) for row in self.picker_calls()[1]['records'])
        self.assertEqual(labels, {members[0]: '  Terminal · my-shell', members[1]: '  Editor · Neovim',
                                  members[2]: '  Terminal · nvim-custom', members[3]: '  Terminal · extra-terminal'})
        self.assertEqual(self.positions(), {self.invoker['name']: members[1], self.other['name']: self.second})
        self.assertEqual(self.command('list-sessions', '-F', '#{session_id}\t#{session_name}'), before)

    def test_missing_project_helper_keeps_sessions_accessible_with_terminal_labels(self):
        standalone = self.root / 'standalone' / 'session-navigator'
        standalone.parent.mkdir()
        shutil.copy2(HELPER, standalone)
        path = self.root / 'fallback-project'
        path.mkdir()
        editor_name = self.managed_editor_name(path)
        members = [self.session(name, path) for name in ('shell', editor_name)]
        result = self.navigate(target=members[1], project_ids=members, helper=standalone)
        self.assertEqual(result.returncode, 0, result.stderr)
        labels = dict(row.split('\t', 1) for row in self.picker_calls()[1]['records'])
        self.assertEqual(labels, {members[0]: '  Terminal · shell', members[1]: '  Terminal · ' + editor_name})
        self.assertEqual(self.positions(), {self.invoker['name']: members[1], self.other['name']: self.second})

    def test_distinct_directories_with_the_same_basename_stay_separate(self):
        paths = [self.root / side / 'project' for side in ('left', 'right')]
        for path in paths:
            path.mkdir(parents=True)
        members = [self.session(name, path) for name, path in zip(('left', 'right'), paths)]
        for target, path in zip(members, paths):
            with self.subTest(path=path):
                result = self.navigate(target=target)
                self.assertEqual(result.returncode, 0, result.stderr)
                calls = self.picker_calls()
                self.assertEqual(len(calls), 1)
                self.assertEqual(len(calls[0]['records']), 5)
                self.assertTrue(any(str(path) in row for row in calls[0]['records']))
                self.assertEqual(self.positions()[self.invoker['name']], target)

    def test_raw_paths_remain_distinct_when_display_labels_collide(self):
        for kind, suffixes, count in (('controls', (b'\t', b'\n'), 5), ('invalid', (b'\xff', b'\xfe'), 7)):
            with self.subTest(kind=kind):
                paths = [Path(os.fsdecode(os.fsencode(self.root) + b'/' + kind.encode() + suffix))
                         for suffix in suffixes]
                try:
                    for path in paths:
                        path.mkdir()
                except (UnicodeError, OSError) as error:
                    if kind == 'invalid' and (isinstance(error, UnicodeError) or error.errno == errno.EILSEQ):
                        self.skipTest('filesystem rejects non-UTF8 filenames')
                    raise
                members = [self.session(kind + name, path) for name, path in zip(('-one', '-two'), paths)]
                result = self.navigate(target=members[1])
                self.assertEqual(result.returncode, 0, result.stderr)
                calls = self.picker_calls()
                self.assertEqual(len(calls), 1)
                offered = dict(row.split('\t', 1) for row in calls[0]['records'])
                self.assertEqual(len(offered), count)
                if kind == 'controls':
                    self.assertEqual(offered[members[0]], offered[members[1]])
                self.assertTrue(set(members).issubset(offered))
                self.assertEqual(self.positions()[self.invoker['name']], members[1])

    def test_second_picker_cancellation_and_invalid_output_leave_clients_unchanged(self):
        path = self.root / 'shared-project'
        path.mkdir()
        members = [self.session(name, path) for name in ('project-shell', 'nvim-project')]
        before = self.positions()
        for mode in ('cancel', 'interrupt', 'error', 'modified', 'foreign', 'multiple', 'empty', 'unterminated'):
            with self.subTest(mode=mode):
                result = self.navigate(['select', mode], target=members[1], project_ids=members)
                self.assertEqual(len(self.picker_calls()), 2)
                self.assertEqual(result.returncode == 0, mode in ('cancel', 'interrupt'), result.stderr)
                self.assertEqual(self.positions(), before)

    def test_second_picker_disappearing_session_or_client_never_redirects(self):
        path = self.root / 'shared-project'
        path.mkdir()
        members = [self.session(name, path) for name in ('project-shell', 'project-shell-other', 'nvim-project')]
        before = self.positions()
        result = self.navigate(['select', 'disappear'], target=members[0], project_ids=members)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(len(self.picker_calls()), 2)
        self.assertEqual(self.positions(), before)
        result = self.navigate(['select', 'detach'], target=members[1], project_ids=members[1:])
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(len(self.picker_calls()), 2)
        self.assertEqual(self.positions(), {self.other['name']: self.second})

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
        peer = self.session('peer', path)
        result = self.navigate(target=target, project_ids=[target, peer])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.positions(), {self.invoker['name']: target,
                                           self.other['name']: self.second})
        calls = self.picker_calls()
        project = next(row.split('\t', 1)[1] for row in calls[0]['records']
                       if row.split('\t', 1)[0] in (target, peer))
        session = next(row.split('\t', 1)[1] for row in calls[1]['records'] if row.startswith(target + '\t'))
        self.assertIn('project', project)
        self.assertIn(str(self.root), project)
        self.assertIn('destination', session)
        for label in (project, session):
            self.assertIn('λ', label)
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
        shutil.copy2(PROJECT_HELPER, scripts / 'project-session')
        installed_keys = scripts.parent / 'keys.conf'
        shutil.copy2(KEYS, installed_keys)
        self.command('source-file', str(installed_keys))
        self.command('set-option', '-g', 'prefix', 'M-Space')
        self.command('set-option', '-g', 'prefix2', 'None')
        path = self.root / "path-only-search-token-λ ' quoted"
        path.mkdir()
        target = self.session(self.managed_editor_name(path), path)
        peer = self.session('console-shell', path)
        ready = self.root / 'real-fzf-ready'
        finished = self.root / 'real-fzf-finished'
        searched = self.root / 'real-fzf-searched'
        observer = '--bind=focus:execute-silent(printf %s {1} > ' + shlex.quote(str(searched)) + ')'
        self.write_fzf('import json, os, subprocess, sys\nfrom pathlib import Path\n'
                       + 'Path(' + repr(str(searched)) + ').unlink(missing_ok=True)\n'
                       + 'prompt = next(arg for arg in sys.argv if arg.startswith("--prompt="))\n'
                       + 'Path(' + repr(str(ready)) + ').write_text(json.dumps({"pid": os.getppid(), "prompt": prompt}))\n'
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
            self.wait(lambda: ready.exists() and searched.exists()
                      and json.loads(ready.read_text())['prompt'] == '--prompt=Projects> ')
            self.wait(lambda: '●'.encode() in self.invoker['output'])

        def closed():
            if not finished.exists():
                return False
            try:
                os.kill(json.loads(ready.read_text())['pid'], 0)
            except ProcessLookupError:
                return True
            return False

        def choose_project():
            before = self.positions()
            os.write(self.invoker['master'], b'pthonlysrch')
            self.wait(lambda: searched.exists() and searched.read_text() in (target, peer))
            os.write(self.invoker['master'], b'\r')
            self.wait(lambda: json.loads(ready.read_text())['prompt'] == '--prompt=Sessions> '
                      and searched.exists())
            self.assertEqual(self.positions(), before, 'choosing the project must not switch yet')

        popup()
        choose_project()
        os.write(self.invoker['master'], b'Neovim')
        self.wait(lambda: searched.exists() and searched.read_text() == target)
        os.write(self.invoker['master'], b'\r')
        self.wait(closed)
        self.assertEqual(finished.read_text(), '0')
        self.wait(lambda: self.positions().get(self.invoker['name']) == target)
        self.assertEqual(self.positions()[self.other['name']], self.second)
        for stage in ('project', 'session'):
            for key in (b'\x1b', b'\x03'):
                with self.subTest(stage=stage, cancel_key=key):
                    before = self.positions()
                    popup()
                    if stage == 'session':
                        choose_project()
                    os.write(self.invoker['master'], key)
                    self.wait(closed)
                    self.assertEqual(finished.read_text(), '130')
                    self.assertEqual(self.positions(), before)


if __name__ == '__main__':
    unittest.main(verbosity=2)
