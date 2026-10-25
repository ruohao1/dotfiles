"""Render updater notices in private tmux clients; no updater network or activation."""
import fcntl
import os
from pathlib import Path
import pty
import re
import select
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

    def windows(self):
        return self.command('display-message', '-p', '-c', self.client_name,
                            '#{W:#{T:window-status-format},#{T:window-status-current-format}}')

    @staticmethod
    def visible(value):
        return re.sub(r'#\[[^\]]*\]', '', value).replace('##', '#')

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
        for name, value in [('active', '1'), ('mode', 'INSERT'), ('path', 'src/main.lua'), ('modified', '1'),
                            ('errors', '2'), ('warnings', '1'), ('line', '42'), ('column', '7')]:
            self.command('set-option', '-p', '-t', pane, '@dotfiles_nvim_' + name, value)
        self.attach()
        self.wait(lambda: b'update v1.2.3' in self.output)
        self.assertIn('INSERT', self.render('left'))
        right = self.render()
        for cue in ['src/main.lua', '[+]', 'E2', 'W1', '42:7']:
            self.assertIn(cue, right)
        self.assertLess(right.index('src/main.lua'), right.index('[+]'))
        self.assertLess(right.index('[+]'), right.index('E2'))
        self.assertIn('#[fg=#e0af68,bg=#2A2F41][+]', right)
        for value in ('0', '', 'true', '01', '1#[fg=red]'):
            self.command('set-option', '-p', '-t', pane, '@dotfiles_nvim_modified', value)
            self.assertNotIn('[+]', self.render())
        self.command('set-option', '-p', '-t', pane, '@dotfiles_nvim_modified', '1')
        self.resize(60)
        self.wait(lambda: self.command('display-message', '-p', '-c', self.client_name, '#{client_width}') == '60')
        self.assertIn('[+]', self.render())
        self.assertIn('42:7', self.render())
        self.resize(120)
        self.wait(lambda: self.command('display-message', '-p', '-c', self.client_name, '#{client_width}') == '120')
        self.command('copy-mode', '-t', pane)
        self.assertIn('COPY', self.render('left'))
        self.command('send-keys', '-t', pane, '-X', 'cancel')
        self.command('bind-key', '-T', 'resize', 'Escape', 'switch-client', '-T', 'root')
        self.command('switch-client', '-c', self.client_name, '-T', 'resize')
        self.assertIn('RESIZE', self.render('left'))
        self.command('switch-client', '-c', self.client_name, '-T', 'prefix')
        self.assertIn('PREFIX', self.render('left'))

    def test_selected_window_and_rounded_zoom_index_keep_the_window_name(self):
        self.command('rename-window', '-t', 'updates:0', 'console')
        self.command('split-window', '-d', '-t', 'updates:0', '/bin/sh')
        self.command('new-window', '-d', '-t', 'updates:1', '-n', 'other', '/bin/sh')
        self.attach()
        self.assertIn('#[fg=#a9b1d6,bg=#2A2F41,bold] 0 console', self.windows())
        self.command('resize-pane', '-Z', '-t', 'updates:0')
        self.assertIn('0 console', self.visible(self.windows()))
        self.assertIn('#[fg=#787c99,bg=#2A2F41]#[fg=#1A1B26,bg=#787c99]0'
                      '#[fg=#787c99,bg=#2A2F41]#[fg=#a9b1d6,bg=#2A2F41,bold] console', self.windows())
        self.command('select-window', '-t', 'updates:1')
        self.assertIn('0 console', self.visible(self.windows()))
        self.assertIn('#[fg=#787c99,bg=#1A1B26]#[fg=#1A1B26,bg=#787c99]0'
                      '#[fg=#787c99,bg=#1A1B26] console', self.windows())
        self.assertIn('#[fg=#a9b1d6,bg=#2A2F41,bold] 1 other', self.windows())
        self.command('resize-pane', '-Z', '-t', 'updates:0')
        self.assertNotIn('0', self.visible(self.windows()))
        self.assertIn('0 console', self.visible(self.windows()))
        self.command('rename-window', '-t', 'updates:0', 'a-very-long-window-name')
        self.command('resize-pane', '-Z', '-t', 'updates:0')
        self.resize(60)
        self.wait(lambda: self.command('display-message', '-p', '-c', self.client_name, '#{client_width}') == '60')
        self.assertIn('0 ', self.visible(self.windows()))
        self.assertNotIn('a-very-long-window-name', self.visible(self.windows()))
        self.command('move-window', '-s', 'updates:0', '-t', 'updates:12')
        self.assertIn('12 a-ver', self.visible(self.windows()))
        self.assertNotIn('[12]', self.visible(self.windows()))

    def test_inactive_output_and_bell_markers_clear_when_selected(self):
        pane = self.command('new-window', '-d', '-P', '-F', '#{pane_id}', '-t', 'updates:1',
                            '-n', 'alerts', '/bin/sh')
        self.attach()
        self.command('send-keys', '-t', pane, "printf 'output\\n'", 'Enter')
        self.wait(lambda: self.command('display-message', '-p', '-t', pane, '#{window_activity_flag}') == '1')
        self.assertIn('#[fg=#7dcfff,bg=#1A1B26]•', self.windows())
        self.assertIn('alerts•', self.visible(self.windows()))
        self.command('send-keys', '-t', pane, "printf '\\007'", 'Enter')
        self.wait(lambda: self.command('display-message', '-p', '-t', pane, '#{window_bell_flag}') == '1')
        self.assertIn('#[fg=#f7768e,bg=#1A1B26]!', self.windows())
        self.assertIn('alerts•!', self.visible(self.windows()))
        self.command('select-window', '-t', pane)
        self.assertNotIn('•', self.visible(self.windows()))
        self.assertNotIn('!', self.visible(self.windows()))

    def test_project_uses_session_start_directory_and_quotes_format_characters(self):
        project = self.root / 'r#(touch X)'
        project.mkdir()
        self.command('new-session', '-d', '-s', 'project', '-c', str(project).replace('#', '##'), '/bin/sh')
        self.assertEqual(self.command('display-message', '-p', '-t', 'project:', '#{session_path}'), str(project))
        self.attach()
        self.command('switch-client', '-c', self.client_name, '-t', 'project')
        self.assertIn('r#(touch X)', self.visible(self.render('left')))
        self.command('send-keys', '-t', 'project:', 'cd /', 'Enter')
        self.wait(lambda: self.command('display-message', '-p', '-t', 'project:', '#{pane_current_path}') == '/')
        self.assertIn('r#(touch X)', self.visible(self.render('left')))
        self.assertFalse((project / 'X').exists(), 'project label executed a tmux job')
        self.resize(60)
        self.wait(lambda: self.command('display-message', '-p', '-c', self.client_name, '#{client_width}') == '60')
        left = self.visible(self.render('left'))
        self.assertIn(' S ', left)
        self.assertNotIn('r#(touch X)', left)
        self.assertNotRegex(self.visible(self.render()), r'\d\d:\d\d')

    def test_narrow_clock_is_hidden_for_shell_and_remote_commands(self):
        original = self.command('show-options', '-gv', 'status-right')
        self.command('set-option', '-g', 'status-right',
                     original.replace('pane_current_command', '@status_test_command'))
        self.attach()
        for command in ('sh', 'ssh', 'mosh-client'):
            with self.subTest(command=command):
                self.command('set-option', '-g', '@status_test_command', command)
                for width, visible in ((79, False), (80, True)):
                    self.resize(width)
                    self.wait(lambda: self.command('display-message', '-p', '-c', self.client_name,
                                                    '#{client_width}') == str(width))
                    self.assertEqual(bool(re.search(r'\d\d:\d\d', self.visible(self.render()))), visible)

    def test_attached_git_summary_keeps_counter_tail_within_each_width_budget(self):
        summary = self.home / '.config/dotfiles/git-summary'
        summary.write_text("#!/bin/sh\nprintf '%s\\n' 'topic/abcdefghijklmnopqrstuvwxyz +12 ~3 ?4 !1'\n")
        self.attach()
        for width, expected in [(120, '…yz +12 ~3 ?4 !1'), (100, '…12 ~3 ?4 !1'), (80, '…3 ?4 !1')]:
            with self.subTest(width=width):
                self.output.clear()
                self.resize(width)
                self.command('refresh-client', '-S', '-t', self.client_name)
                self.wait(lambda: expected.encode() in self.output)
                self.assertNotIn(b'topic/abcdefghijklmnopqrstuvwxyz', self.output)
        self.output.clear()
        self.resize(60)
        self.wait(lambda: self.command('display-message', '-p', '-c', self.client_name, '#{client_width}') == '60')
        self.assertNotIn(b' ?4 !1', self.output)

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

    def audit_status_jobs(self):
        source = (SOURCE / '.config/dotfiles/check-terminal-stack').read_text()
        function = 'tmux_status_jobs_are_exact() {' + source.split('tmux_status_jobs_are_exact() {', 1)[1].split('\n}\n', 1)[0] + '\n}\n'
        harness = self.root / 'audit.sh'
        harness.write_text(function + '\ntmux_status_jobs_are_exact "$1" updates\n')
        return subprocess.run(['/bin/sh', str(harness), str(self.socket)], env=self.env,
                              cwd=self.home, text=True, capture_output=True, timeout=10)

    def test_source_audit_requires_quoted_project_and_exact_modified_predicate(self):
        source = (SOURCE / '.config/dotfiles/check-terminal-stack').read_text()
        functions = ''
        for name in ['count_occurrences', 'tmux_status_assignment_manifest_is_exact',
                     'tmux_status_palette_is_exact', 'tmux_status_source_is_safe']:
            functions += name + '() {' + source.split(name + '() {', 1)[1].split('\n}\n', 1)[0] + '\n}\n'
        harness = self.root / 'source-audit.sh'
        harness.write_text(functions + '\ntmux_status_source_is_safe "$1"\n')
        original = (SOURCE / '.config/tmux/conf/status.conf').read_text()
        candidate = self.root / 'status.conf'
        mutations = [None,
                     ('#{b;qh:session_path}', '#{b:session_path}'),
                     ('#{b;qh:session_path}', '#{session_path}'),
                     ('#{==:#{@dotfiles_nvim_modified},1}', '#{@dotfiles_nvim_modified}'),
                     ('#{==:#{@dotfiles_nvim_modified},1}', '#{==:#{@dotfiles_nvim_modified},true}')]
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                candidate.write_text(original if mutation is None else original.replace(mutation[0], mutation[1], 1))
                result = subprocess.run(['/bin/sh', str(harness), str(candidate)], env=self.env,
                                        cwd=self.home, text=True, capture_output=True, timeout=10)
                self.assertEqual(result.returncode == 0, mutation is None, result.stdout + result.stderr)

    def test_checker_accepts_only_the_exact_updater_job(self):
        result = self.audit_status_jobs()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        original = self.command('show-options', '-gv', 'status-right')
        for replacement in ['check', 'status --tmux && id', 'status --tmux --unsafe']:
            with self.subTest(replacement=replacement):
                self.command('set-option', '-g', 'status-right', original.replace('status --tmux', replacement))
                self.assertNotEqual(self.audit_status_jobs().returncode, 0)
        self.command('set-option', '-g', 'status-right', original.replace('command -v dotfiles-update >/dev/null 2>&1 && exec ', ''))
        self.assertNotEqual(self.audit_status_jobs().returncode, 0)
        self.command('set-option', '-g', 'status-right', original)
        self.assertEqual(self.audit_status_jobs().returncode, 0)

    def test_checker_accepts_escaped_show_output_without_decoding_stored_escapes(self):
        # tmux 3.4 escapes variable dollars in cmdq_print, including both commands.
        wrapper = self.bin / 'tmux'
        wrapper.write_text('#!' + sys.executable + '\nimport re, subprocess, sys\n'
                           + 'result = subprocess.run([' + repr(self.tmux) + ', *sys.argv[1:]], capture_output=True)\n'
                           + 'value = result.stdout\n'
                           + 'if "show-options" in sys.argv or "display-message" in sys.argv:\n'
                           + '    value = re.sub(rb"\\$(?=[A-Za-z_{])", lambda m: b"\\\\" + m[0], value)\n'
                           + 'sys.stdout.buffer.write(value)\nsys.stderr.buffer.write(result.stderr)\n'
                           + 'sys.exit(result.returncode)\n')
        wrapper.chmod(0o755)
        result = self.audit_status_jobs()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        original = next(line for line in (SOURCE / '.config/tmux/conf/status.conf').read_text().splitlines()
                        if line.startswith("set -g status-left '")).split("'", 1)[1][:-1]
        for replacement in [r'\$HOME', r'\\$HOME', '${HOME}', '$HOME/../foreign']:
            with self.subTest(replacement=replacement):
                self.command('set-option', '-g', 'status-left', original.replace('$HOME', replacement))
                self.assertNotEqual(self.audit_status_jobs().returncode, 0)
        self.command('set-option', '-g', 'status-left', original)
        self.assertEqual(self.audit_status_jobs().returncode, 0)

    def test_checker_audits_global_values_without_expanding_jobs(self):
        original = next(line for line in (SOURCE / '.config/tmux/conf/status.conf').read_text().splitlines()
                        if line.startswith("set -g status-left '")).split("'", 1)[1][:-1]
        marker = self.root / 'must-not-exist'
        self.command('set-option', '-g', '@unsafe', '#(touch ' + str(marker) + ')')
        self.command('set-option', '-g', 'status-left', original + ' #{E:@unsafe} #(touch ' + str(marker) + ')')
        self.command('set-option', '-t', 'updates', 'status-left', original)
        self.assertNotEqual(self.audit_status_jobs().returncode, 0, 'safe local override hid altered global status')
        self.assertFalse(marker.exists(), 'auditing expanded or executed the stored format')
        self.command('set-option', '-g', 'status-left', original)
        self.assertEqual(self.audit_status_jobs().returncode, 0)

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
