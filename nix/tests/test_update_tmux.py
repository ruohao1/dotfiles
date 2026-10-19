"""Render updater notices in private tmux clients; no updater network or activation."""
import fcntl
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import struct
import subprocess
import tempfile
import termios
import time
import unittest

SOURCE = Path(__file__).resolve().parents[2]


@unittest.skipUnless(shutil.which('tmux'), 'tmux is required for attached status rendering')
class UpdateTmuxTests(unittest.TestCase):
    def setUp(self):
        parent = Path(os.environ.get('DOTFILES_UPDATE_TMUX_TEST_ROOT', '/tmp/dotfiles-update-tmux-tests'))
        parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.temporary = tempfile.TemporaryDirectory(prefix='t-', dir=parent)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.home = self.root / 'h'
        self.home.mkdir(mode=0o700)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        summary = self.home / '.config/dotfiles/git-summary'
        summary.parent.mkdir(parents=True)
        summary.write_text('#!/bin/sh\nexit 0\n')
        summary.chmod(0o755)
        self.env = {'HOME': str(self.home), 'PATH': str(self.bin) + ':' + os.environ.get('PATH', os.defpath),
                    'TERM': 'xterm-256color', 'LANG': 'C.UTF-8', 'SHELL': '/bin/sh'}
        self.tmux = shutil.which('tmux')
        self.socket = self.root / 's'
        self.calls = self.root / 'calls'
        self.release = self.root / 'release'
        self.client = None
        self.master = None
        self.output = bytearray()
        self.clients = []
        self.command('-f', '/dev/null', 'new-session', '-d', '-s', 'updates', '-c', str(self.home), '/bin/sh')
        self.addCleanup(self.stop)
        self.command('source-file', str(SOURCE / '.config/tmux/conf/status.conf'))
        self.command('set-option', '-g', 'status-interval', '1')

    def command(self, *args):
        result = subprocess.run([self.tmux, '-S', str(self.socket), *args], env=self.env,
                                cwd=self.home, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def helper(self, badge='update v1.2.3', blocked=False):
        helper = self.bin / 'dotfiles-update'
        helper.write_text('#!/bin/sh\n[ "$#" -eq 2 ] && [ "$1" = status ] && [ "$2" = --tmux ] || exit 1\n'
                          + 'printf "called\\n" >> "' + str(self.calls) + '"\n'
                          + 'printf "%s\\n" ' + "'" + badge + "'" + '\n'
                          + ('while [ ! -e "' + str(self.release) + '" ]; do sleep 0.05; done\n' if blocked else ''))
        helper.chmod(0o755)

    def attach(self, width=120):
        pid, master = pty.fork()
        if pid == 0:
            os.execve(self.tmux, [self.tmux, '-S', str(self.socket), 'attach-session', '-t', 'updates'], self.env)
        self.client, self.master = pid, master
        self.clients.append((pid, master))
        self.resize(width)
        self.wait(lambda: self.command('list-clients', '-F', '#{client_name}'))
        self.client_name = self.command('list-clients', '-F', '#{client_name}').splitlines()[0]

    def resize(self, width):
        fcntl.ioctl(self.master, termios.TIOCSWINSZ, struct.pack('HHHH', 24, width, 0, 0))
        os.kill(self.client, signal.SIGWINCH)
        self.drain()

    def drain(self):
        if self.master is None:
            return
        while select.select([self.master], [], [], 0)[0]:
            try:
                self.output.extend(os.read(self.master, 65536))
            except OSError:
                break

    def wait(self, predicate, timeout=5):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.drain()
            value = predicate()
            if value:
                return value
            time.sleep(0.03)
        self.fail('private tmux status did not reach the expected state')

    def render(self, side='right'):
        self.drain()
        return self.command('display-message', '-p', '-c', self.client_name, '#{T:status-' + side + '}')

    def stop(self):
        self.release.touch()
        for pid, master in self.clients:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            os.waitpid(pid, 0)
            os.close(master)
        self.clients = []
        self.client = self.master = None
        subprocess.run([self.tmux, '-S', str(self.socket), 'kill-server'], env=self.env,
                       cwd=self.home, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)

    def test_attached_client_shows_cached_badge_without_waiting_for_refresh(self):
        self.helper(blocked=True)
        self.attach()
        self.wait(lambda: b'update v1.2.3' in self.output)
        self.assertIn('SHELL', self.render('left'))
        self.assertFalse(self.release.exists(), 'cached display waited for refresh completion')
        self.output.clear()
        self.resize(80)
        self.wait(lambda: b'UPD' in self.output)
        self.assertNotIn(b'update v1.2.3', self.output)
        self.output.clear()
        self.resize(60)
        self.wait(lambda: self.command('display-message', '-p', '-c', self.client_name, '#{client_width}') == '60')
        self.wait(lambda: b' S ' in self.output)
        self.assertNotIn(b'UPD', self.output)
        self.assertNotIn(b'update ', self.output)
        self.assertIn(' S ', self.render('left'))

    @unittest.skipUnless(shutil.which('nvim'), 'Neovim is required for the editor cue fixture')
    def test_existing_editor_and_keytable_cues_remain_visible(self):
        self.helper()
        pane = self.command('new-window', '-d', '-P', '-F', '#{pane_id}', '-t', 'updates:',
                            shutil.which('nvim'), '--headless', '-u', 'NONE', '-i', 'NONE', '+sleep 300', '+qa!')
        self.command('select-window', '-t', pane)
        self.wait(lambda: self.command('display-message', '-p', '-t', pane, '#{pane_current_command}')
                  in ('nvim', 'nvim-wrapped'))
        for name, value in [('active', '1'), ('mode', 'INSERT'), ('path', 'src/main.lua'),
                            ('errors', '2'), ('warnings', '1'), ('line', '42'), ('column', '7')]:
            self.command('set-option', '-p', '-t', pane, '@dotfiles_nvim_' + name, value)
        self.attach()
        self.wait(lambda: b'update v1.2.3' in self.output)
        self.assertIn('INSERT', self.render('left'))
        right = self.render()
        for cue in ['src/main.lua', 'E2', 'W1', '42:7']:
            self.assertIn(cue, right)
        self.command('copy-mode', '-t', pane)
        self.assertIn('COPY', self.render('left'))
        self.command('send-keys', '-t', pane, '-X', 'cancel')
        self.command('bind-key', '-T', 'resize', 'Escape', 'switch-client', '-T', 'root')
        self.command('switch-client', '-c', self.client_name, '-T', 'resize')
        self.assertIn('RESIZE', self.render('left'))
        self.command('switch-client', '-c', self.client_name, '-T', 'prefix')
        self.assertIn('PREFIX', self.render('left'))

    def test_two_clients_stop_triggering_jobs_after_detach(self):
        self.helper()
        self.attach()
        self.attach()
        self.wait(lambda: self.command('display-message', '-p', '#{session_attached}') == '2')
        self.wait(lambda: b'update v1.2.3' in self.output)
        self.command('detach-client', '-s', 'updates')
        self.wait(lambda: self.command('display-message', '-p', '#{session_attached}') == '0')
        calls = self.calls.read_text()
        time.sleep(1.2)
        self.assertEqual(self.calls.read_text(), calls)

    def test_checker_accepts_only_the_exact_updater_job(self):
        source = (SOURCE / '.config/dotfiles/check-terminal-stack').read_text()
        function = 'tmux_status_jobs_are_exact() {' + source.split('tmux_status_jobs_are_exact() {', 1)[1].split('\n}\n', 1)[0] + '\n}\n'
        harness = self.root / 'audit.sh'
        harness.write_text(function + '\ntmux_status_jobs_are_exact "$1" updates\n')
        def audit():
            return subprocess.run(['/bin/sh', str(harness), str(self.socket)], env=self.env,
                                  cwd=self.home, text=True, capture_output=True, timeout=10)
        result = audit()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        original = self.command('show-options', '-gv', 'status-right')
        for replacement in ['check', 'status --tmux && id', 'status --tmux --unsafe']:
            with self.subTest(replacement=replacement):
                self.command('set-option', '-g', 'status-right', original.replace('status --tmux', replacement))
                self.assertNotEqual(audit().returncode, 0)
        self.command('set-option', '-g', 'status-right', original.replace('command -v dotfiles-update >/dev/null 2>&1 && exec ', ''))
        self.assertNotEqual(audit().returncode, 0)
        self.command('set-option', '-g', 'status-right', original)
        self.assertEqual(audit().returncode, 0)

    def test_detached_session_does_not_start_updater(self):
        self.helper()
        self.assertEqual(self.command('display-message', '-p', '#{session_attached}'), '0')
        self.command('display-message', '-p', '#{T:status-right}')
        time.sleep(0.15)
        self.assertFalse(self.calls.exists())

    def test_missing_helper_and_invalid_badge_are_empty(self):
        self.attach()
        self.assertNotIn('UPD', self.render())
        self.assertNotIn('update ', self.render())
        self.helper('update v1.2.3#[fg=red]evil')
        self.command('refresh-client', '-S', '-t', self.client_name)
        self.wait(lambda: self.calls.exists())
        self.assertNotIn('evil', self.render())
        self.assertNotIn('UPD', self.render())


if __name__ == '__main__':
    unittest.main(verbosity=2)
