"""Check the navigator binding audit using only private tmux key tables."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

SOURCE = Path(__file__).resolve().parents[2]
KEYS = Path(os.environ.get('DOTFILES_SESSION_NAVIGATOR_KEYS', SOURCE / '.config/tmux/conf/keys.conf'))
BINDING = ('bind-key f run-shell -b '
           '\'exec "$HOME/.config/tmux/scripts/session-navigator" --popup '
           '#{q:socket_path} #{q:client_name}\'\n')


@unittest.skipUnless(shutil.which('tmux'), 'tmux is required for binding serialization')
class SessionNavigatorCheckerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='navigator-checker-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.home = self.root / 'home'
        self.home.mkdir(mode=0o700)
        self.env = {'HOME': str(self.home), 'PATH': os.environ.get('PATH', os.defpath),
                    'LANG': 'C.UTF-8', 'SHELL': '/bin/sh'}
        self.tmux = shutil.which('tmux')
        self.socket = self.root / 's'
        self.server = subprocess.Popen([self.tmux, '-D', '-S', str(self.socket), '-f', '/dev/null'],
                                       env=self.env, cwd=self.home, stdout=subprocess.DEVNULL,
                                       stderr=subprocess.PIPE)
        self.addCleanup(self.stop)
        deadline = time.monotonic() + 5
        while not self.socket.exists() and self.server.poll() is None and time.monotonic() < deadline:
            time.sleep(0.02)
        self.command('new-session', '-d', '-s', 'checker', '/bin/sh')
        self.pristine = self.root / 'pristine'
        self.pristine.write_text(self.bindings())
        source = (SOURCE / '.config/dotfiles/check-terminal-stack').read_text()
        functions = ''
        for name in ['tmux_pristine_binding_delta_is_exact', 'tmux_copy_pipe_and_run_shell_payloads_are_safe']:
            functions += name + '() {' + source.split(name + '() {', 1)[1].split('\n}\n', 1)[0] + '\n}\n'
        # Load the production expectation, not a value derived from the observed binding.
        expectation = '\n'.join(line.strip() for line in source.splitlines()
                                if line.startswith('  tmux_session_navigator_command='))
        self.audit = self.root / 'audit.sh'
        self.audit.write_text(functions + '\n' + expectation + '\n'
                              'tmux_url_enabled=false\n'
                              'if [ "$3" = payload ]; then\n'
                              '  tmux_copy_pipe_and_run_shell_payloads_are_safe "$2"\n'
                              'else\n'
                              '  tmux_pristine_binding_delta_is_exact "$1" "$2" "" "M-\\\\"\n'
                              'fi\n')

    def command(self, *arguments):
        result = subprocess.run([self.tmux, '-S', str(self.socket), *arguments], env=self.env,
                                cwd=self.home, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def stop(self):
        subprocess.run([self.tmux, '-S', str(self.socket), 'kill-server'], env=self.env,
                       cwd=self.home, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       timeout=10)
        try:
            self.server.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            self.server.terminate()
            self.server.communicate(timeout=10)

    def bindings(self):
        # Retain the changed key and a pristine shell-bearing key. The complete
        # checker covers all tables; this regression isolates the popup contract.
        return ''.join(line + '\n' for line in self.command('list-keys', '-T', 'prefix').splitlines()
                       if line.split()[3] in ('f', ':'))

    def source_binding(self, text=BINDING):
        config = self.root / 'binding.conf'
        config.write_text(text)
        self.command('source-file', str(config))

    def check(self, payload=False):
        candidate = self.root / 'candidate'
        candidate.write_text(self.bindings())
        return subprocess.run(['/bin/sh', str(self.audit), str(self.pristine), str(candidate),
                               'payload' if payload else 'delta'],
                              env=self.env, cwd=self.home, text=True, capture_output=True, timeout=10)

    def test_accepts_canonical_popup_serialized_by_tmux(self):
        self.source_binding()
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_current_keys_config_uses_the_canonical_popup(self):
        self.command('source-file', str(KEYS))
        actual = self.bindings()
        self.source_binding()
        self.assertEqual(actual, self.bindings())
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_rejects_previous_choose_tree_binding(self):
        self.source_binding('bind-key f choose-tree -Zw\n')
        result = self.check()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('noncanonical owned tmux binding delta: table=prefix key=f', result.stdout)

    def test_rejects_changed_helper_arguments_and_shell_payload(self):
        for replacement in [BINDING.replace('#{q:client_name}', '#{client_name}'),
                            BINDING.replace('session-navigator', 'other-helper'),
                            BINDING.replace("#{q:client_name}'", "#{q:client_name}; id'")]:
            with self.subTest(binding=replacement):
                self.source_binding(replacement)
                result = self.check()
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('noncanonical owned tmux binding delta: table=prefix key=f', result.stdout)

    def test_rejects_popup_on_unowned_colon_binding(self):
        self.source_binding()
        for popup in ['display-popup -E wl-copy', BINDING.split('bind-key f ', 1)[1].strip()]:
            with self.subTest(popup=popup):
                self.source_binding('bind-key : ' + popup + '\n')
                result = self.check()
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('unowned tmux binding delta: table=prefix key=:', result.stdout)

    def test_payload_audit_accepts_only_the_exact_owned_navigator(self):
        self.source_binding()
        result = self.check(payload=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.source_binding(BINDING.replace('bind-key f ', 'bind-key : ', 1))
        result = self.check(payload=True)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_payload_audit_rejects_modified_navigator_command(self):
        for replacement in [BINDING.replace('--popup', '--other'),
                            BINDING.replace("#{q:client_name}'", "#{q:client_name}; id'")]:
            with self.subTest(binding=replacement):
                self.source_binding(replacement)
                result = self.check(payload=True)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)
