#!/usr/bin/env python3
"""Exercise clipboard checks with private deployed leaves and native assets."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[2]
CAPTURE = ['clipboard-history/store', 'cliphist/config',
           'systemd/user/cliphist.service.d/override.conf']
EDITOR = ['nvim/lua/clipboard/history.lua', 'nvim/tests/clipboard_history.lua']


class ClipboardCheckerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='checker-clipboard-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.home = self.root / 'home'
        self.config = self.home / '.config'
        self.config.mkdir(parents=True, mode=0o700)
        self.source = self.root / 'source/.config'
        # Keep the canonical source tree separate from the deployed HOME.
        for relative in ['dotfiles/check-terminal-stack', 'dotfiles/lib/config-source.py',
                         'dotfiles/lib/tmux-audit.sh', *EDITOR]:
            target = self.source / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(SOURCE / '.config' / relative, target)
            target.chmod(target.stat().st_mode & ~0o022)
            deployed = self.config / relative
            deployed.parent.mkdir(parents=True, exist_ok=True)
            deployed.symlink_to(target)
        shutil.copytree(SOURCE / '.config/dotfiles/manifests', self.config / 'dotfiles/manifests')
        tools = self.root / 'bin'
        tools.mkdir()
        # Deliberately omit native capture tools: these are source regressions,
        # and must never connect to the host's systemd or clipboard service.
        for name in ['python3', 'id', 'find', 'uname', 'mktemp', 'mkdir',
                     'env', 'grep', 'cat', 'rm', 'sed', 'git']:
            target = shutil.which(name)
            if target:
                (tools / name).symlink_to(Path(target).resolve())
        nvim = tools / 'nvim'
        nvim.write_text("""#!/bin/sh
[ "$#" -eq 10 ] && [ "$1" = --clean ] && [ "$2" = --headless ] \
  && [ "$3" = -u ] && [ "$4" = NONE ] && [ "$5" = -i ] && [ "$6" = NONE ] \
  && [ "$7" = -c ] && [ "$8" = 'lua vim.opt.runtimepath:prepend(vim.env.DOTFILES_NVIM_ROOT)' ] \
  && [ "$9" = -l ] || exit 1
[ "${10}" = "$DOTFILES_NVIM_ROOT/tests/clipboard_history.lua" ] || exit 1
printf '%s\\n' "$DOTFILES_NVIM_ROOT" > "$CHECKER_NVIM_CALL"
printf '%s\\n' 'Neovim clipboard history assertions: ok'
""")
        nvim.chmod(0o755)
        self.nvim_call = self.root / 'nvim-call'
        self.env = {'CHECKER_NVIM_CALL': str(self.nvim_call), 'PATH': str(tools), 'HOME': str(self.home), 'LANG': 'C.UTF-8',
                    'PYTHONDONTWRITEBYTECODE': '1', 'NVIM_LOG_FILE': str(self.root / 'nvim.log'),
                    'DOTFILES_CHECK_MODE': 'clipboard-history-self-test'}
        temporary = self.root / 'tmp'
        temporary.mkdir(mode=0o700)
        self.env['TMPDIR'] = str(temporary)

    def native_capture(self):
        for relative in CAPTURE:
            target = self.config / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(SOURCE / '.config' / relative, target)

    def check(self):
        result = subprocess.run(['/bin/sh', str(self.config / 'dotfiles/check-terminal-stack')],
                                env=self.env, cwd=self.home, text=True,
                                capture_output=True, timeout=60)
        return result, result.stdout + result.stderr

    def test_deployed_editor_links_accept_canonical_sources(self):
        self.native_capture()
        result, output = self.check()
        self.assertEqual(result.returncode, 0, output)
        self.assertEqual(self.nvim_call.read_text().strip(), str(self.config / 'nvim'))
        self.assertIn('Neovim clipboard history injected processes and native-buffer assertions pass', output)

    def test_native_ordinary_editor_files_remain_supported(self):
        self.native_capture()
        for relative in ['dotfiles/check-terminal-stack', 'dotfiles/lib/config-source.py',
                         'dotfiles/lib/tmux-audit.sh', *EDITOR]:
            deployed = self.config / relative
            deployed.unlink()
            shutil.copy2(self.source / relative, deployed)
        result, output = self.check()
        self.assertEqual(result.returncode, 0, output)
        self.assertEqual(self.nvim_call.read_text().strip(), str(self.config / 'nvim'))

    def test_foreign_deployed_audit_module_is_never_sourced(self):
        marker = self.root / 'foreign-module-executed'
        foreign = self.root / 'foreign.sh'
        foreign.write_text(f': > "{marker}"\nexit 71\n')
        deployed = self.config / 'dotfiles/lib/tmux-audit.sh'
        deployed.unlink()
        deployed.symlink_to(foreign)
        result, output = self.check()
        self.assertFalse(marker.exists(), 'foreign module executed before source validation')
        self.assertEqual(result.returncode, 0, output)
        self.assertTrue(self.nvim_call.exists(), 'canonical module did not load')

    def test_non_hypr_home_keeps_portable_editor_checks_without_capture_assets(self):
        result, output = self.check()
        self.assertEqual(result.returncode, 0, output)
        self.assertEqual(self.nvim_call.read_text().strip(), str(self.config / 'nvim'))
        self.assertIn('Neovim clipboard history injected processes and native-buffer assertions pass', output)
        self.assertNotIn('capture policy and Hyprland-only manifests are exact', output)

    def test_foreign_editor_links_are_rejected_before_execution(self):
        self.native_capture()
        foreign = self.root / 'foreign.lua'
        foreign.write_text('-- foreign editor source\n')
        deployed = self.config / EDITOR[1]
        deployed.unlink()
        deployed.symlink_to(foreign)
        result, output = self.check()
        self.assertNotEqual(result.returncode, 0, output)
        self.assertFalse(self.nvim_call.exists(), 'untrusted editor source reached Neovim')

    def test_native_capture_symlinks_remain_rejected(self):
        self.native_capture()
        helper = self.config / CAPTURE[0]
        helper.unlink()
        helper.symlink_to(SOURCE / '.config' / CAPTURE[0])
        result, output = self.check()
        self.assertNotEqual(result.returncode, 0, output)

    def test_hypr_config_requires_missing_capture_assets(self):
        for name in ['hyprland.lua', 'hyprland.conf']:
            with self.subTest(name=name):
                hypr = self.config / 'hypr' / name
                hypr.parent.mkdir(exist_ok=True)
                hypr.write_text('# native Hypr configuration\n')
                result, output = self.check()
                self.assertNotEqual(result.returncode, 0, output)
                hypr.unlink()

    def test_partial_or_dangling_capture_assets_cannot_skip_native_checks(self):
        for relative in [*CAPTURE, 'systemd/user/cliphist.service',
                         'systemd/user/default.target.wants/cliphist.service',
                         'systemd/user/graphical-session.target.wants/cliphist.service']:
            with self.subTest(relative=relative):
                target = self.config / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.symlink_to(self.root / 'missing')
                result, output = self.check()
                self.assertNotEqual(result.returncode, 0, output)
                target.unlink()


if __name__ == '__main__':
    unittest.main(verbosity=2)
