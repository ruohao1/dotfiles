#!/usr/bin/env python3
"""Exercise the real checker gates without loading editor or plugin code."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[2]
CHECKER = (SOURCE / '.config/dotfiles/check-terminal-stack').read_text()
NAMES = ('fzf-lua image.nvim jupytext.nvim lazy.nvim mini.icons mini.pairs '
         'mini.starter mini.surround molten-nvim nvim-treesitter oil.nvim '
         'otter.nvim quarto-nvim smart-splits.nvim tokyonight.nvim which-key.nvim').split()


def section(start, end):
    begin = CHECKER.index(start)
    return CHECKER[begin:CHECKER.index(end, begin)]


class NeovimCheckerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='checker-neovim-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for child in ['home', 'check', 'nvim', 'data', 'bin']:
            (self.root / child).mkdir(mode=0o700)
        self.lock = self.root / 'nvim/lazy-lock.json'
        self.marker = self.root / 'runtime-executed'
        # A failed guard must never reach a real editor, tmux server or Python app.
        for name in ['nvim', 'tmux', 'python3']:
            stub = self.root / 'bin' / name
            stub.write_text('#!/bin/sh\nprintf "%s\\n" "$0" >> "$CHECKER_SPY"\nexit 77\n')
            stub.chmod(0o700)
        self.env = {'PATH': str(self.root / 'bin') + os.pathsep + os.defpath,
                    'HOME': str(self.root / 'home'), 'LANG': 'C.UTF-8',
                    'CHECKER_SPY': str(self.marker)}
        self.pins = {name: {'branch': 'main', 'commit': '1' * 40} for name in NAMES}

    def run_shell(self, body):
        setup = f'''
set -u
check_tmp={shlex.quote(str(self.root / 'check'))}
nvim_root={shlex.quote(str(self.root / 'nvim'))}
nvim_data_root={shlex.quote(str(self.root / 'data'))}
check_socket="$check_tmp/private.sock"
nvim_config_ready=true
failures=0
warnings=0
pass() {{ printf 'PASS %s\\n' "$1"; }}
fail() {{ failures=$((failures + 1)); printf 'FAIL %s\\n' "$1"; }}
warn() {{ warnings=$((warnings + 1)); printf 'WARN %s\\n' "$1"; }}
'''
        return subprocess.run(['/bin/sh', '-c', setup + body], env=self.env,
                              cwd=self.root, capture_output=True, text=True, timeout=10)

    def gate(self, pins, *, dirty=False, wrong_revision=False):
        self.lock.write_text(json.dumps(pins))
        before = self.lock.read_bytes()
        functions = section('approved_nvim_plugins=', '\nnvim_trust_reject() {')
        gate = section('mini_icons_dir="$nvim_data_root/lazy/mini.icons"',
                       '\nif [ "$nvim_config_ready" = true ] && command -v nvim')
        # Isolate the policy from source verification, whose real Git/object
        # implementation has its own checker selftests. Failures remain observable.
        stubs = f'''
nvim_plugin_checkout_path_is_exact() {{ return 0; }}
nvim_plugin_revision_is_exact() {{ return {1 if wrong_revision else 0}; }}
require_clean_git_worktree() {{ return {1 if dirty else 0}; }}
'''
        result = self.run_shell(functions + stubs + gate +
                                '\nprintf "RESULT %s %s\\n" "$plugins_trusted" "$failures"\n')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.lock.read_bytes(), before, 'source lock was rewritten')
        self.assertFalse(self.marker.exists(), 'gate executed application code')
        return result.stdout

    def test_local_pins_are_retained_without_opening_runtime_gate(self):
        self.pins['draft.nvim'] = {'commit': '2' * 40}
        self.pins['lazy.nvim']['commit'] = '3' * 40
        output = self.gate(self.pins)
        self.assertIn('RESULT false 0', output)
        self.assertIn('Partial Neovim validation', output)
        projected = json.loads((self.root / 'check/nvim-managed-lock.json').read_text())
        self.assertEqual(projected, {name: self.pins[name] for name in NAMES})

    def test_standard_lock_can_open_gate_after_source_checks(self):
        self.assertIn('RESULT true 0', self.gate(self.pins))

    def test_missing_managed_plugin_is_a_failure(self):
        del self.pins['mini.icons']
        output = self.gate(self.pins)
        self.assertIn('FAIL', output)
        self.assertNotIn('RESULT false 0', output)
        self.assertNotIn('RESULT true', output)

    def test_malformed_managed_pin_is_a_failure_even_with_local_plugins(self):
        self.pins['draft.nvim'] = {'commit': '2' * 40}
        self.pins['lazy.nvim']['commit'] = 'not-a-revision'
        output = self.gate(self.pins)
        self.assertIn('FAIL', output)
        self.assertNotIn('RESULT false 0', output)
        self.assertNotIn('RESULT true', output)

    def test_dirty_managed_source_is_a_failure_even_with_local_plugins(self):
        self.pins['draft.nvim'] = {'commit': '2' * 40}
        output = self.gate(self.pins, dirty=True)
        self.assertIn('FAIL', output)
        self.assertNotIn('RESULT false 0', output)
        self.assertNotIn('RESULT true', output)

    def test_wrong_managed_revision_is_a_failure_even_with_local_plugins(self):
        self.pins['draft.nvim'] = {'commit': '2' * 40}
        output = self.gate(self.pins, wrong_revision=True)
        self.assertIn('FAIL', output)
        self.assertNotIn('RESULT false 0', output)
        self.assertNotIn('RESULT true', output)

    def test_closed_gate_skips_configured_checks_without_new_failures(self):
        parquet = section('parquet_integration_root="$check_tmp/nvim-parquet-integration"',
                          '\ndata_query_fixture_root=')
        query = section('data_query_fixture_root=', '\ntask9_ready=false\n')
        start = CHECKER.index('\ntask9_ready=false\n')
        probe = CHECKER.index('\n  nvim_pane=$(tmux -S "$check_socket" new-window', start)
        stop = CHECKER.rfind('\nif ', start, probe)
        tui = CHECKER[start:stop]
        interactive = section('if [ "${1:-}" = "--interactive" ]; then',
                              '\ncheck_clipboard_history\n')
        body = '''
plugins_trusted=false
tmux_started=true
platform=linux
parquet_runtime_ready=true
data_query_runtime_ready=true
parquet_tool_python=python3
run_nvim_parquet_integration_test() { nvim; }
run_interactive_matrix() { nvim; }
'''
        # Preserve an earlier managed-source error through every downstream SKIP.
        for failures in [0, 1]:
            with self.subTest(existing_failures=failures):
                result = self.run_shell(body + f'failures={failures}\n' + parquet + query + tui +
                                        '\nset -- --interactive\n' + interactive +
                                        f'\n[ "$failures" -eq {failures} ]\n')
                self.assertFalse(self.marker.exists(), 'closed gate launched application code')
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertNotIn('FAIL ', result.stdout)
                self.assertIn('SKIP', result.stdout)


if __name__ == '__main__':
    unittest.main()
