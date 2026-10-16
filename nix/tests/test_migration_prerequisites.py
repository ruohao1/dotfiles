"""Native claims fail closed and bind actual providers and local sessions."""
import importlib
import os
from pathlib import Path
import shutil
import socket
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(os.environ.get('DOTFILES_MIGRATION_SOURCE_ROOT', Path(__file__).resolve().parents[2]))
sys.path.insert(0, str(ROOT / 'nix'))

class PrerequisiteTests(unittest.TestCase):
    def setUp(self):
        parent = Path(os.environ.get('DOTFILES_MIGRATION_TEST_ROOT', '/tmp/dotfiles-isq318-tests'))
        parent.mkdir(exist_ok=True)
        self.root = Path(tempfile.mkdtemp(prefix='native-', dir=parent))
        self.home = self.root / 'home'
        self.home.mkdir()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.manifest = dict(system='x86_64-linux', activationPackage='/nix/store/fixture', nativeDependencies=[], files=[], commandRequirements=[])

    def module(self):
        self.assertTrue((ROOT / 'nix/migration/prerequisites.py').exists(), 'native collector missing')
        return importlib.import_module('migration.prerequisites')

    def test_unknown_claim_cannot_manufacture_readiness(self):
        module = self.module()
        self.manifest['nativeDependencies'] = [{'id':'future-native', 'requiredClaims':['receipt']}]
        result = module.inspect_native(self.manifest, self.home)
        self.assertEqual(result[0]['status'], 'unverified')
        self.assertTrue(result[0]['claims'])

    def test_executable_presence_does_not_prove_ghostty_or_font(self):
        module = self.module()
        executable = self.bin / 'ghostty'
        executable.write_text('#!/bin/sh\nexit 0\n')
        executable.chmod(0o700)
        self.manifest['nativeDependencies'] = [{'id':'ghostty'}, {'id':'space-mono-nerd-font'}]
        with patch.dict(os.environ, {'DOTFILES_CALLER_PATH':str(self.bin)}):
            result = module.inspect_native(self.manifest, self.home)
        self.assertTrue(all(r['status'] != 'observed' for r in result))
        self.assertEqual(result[0]['selectedExecutable'], str(executable))
        self.assertEqual(result[0]['binding']['home'], str(self.home))

    def test_remote_or_foreign_session_is_not_trusted(self):
        module = self.module()
        self.manifest['nativeDependencies'] = [{'id':'desktop-clipboard'}]
        for environment in [{'XDG_RUNTIME_DIR':str(self.root), 'WAYLAND_DISPLAY':'wayland-1'},
                            {'DBUS_SESSION_BUS_ADDRESS':'tcp:host=remote,port=123', 'WAYLAND_DISPLAY':'wayland-1'},
                            {'WAYLAND_DISPLAY':'/tmp/foreign-display'}]:
            with self.subTest(environment=environment), patch.dict(os.environ, environment):
                self.assertEqual(module.inspect_native(self.manifest,self.home)[0]['status'], 'unverified')

    def test_declared_empty_claims_do_not_override_required_observations(self):
        module = self.module()
        self.manifest['nativeDependencies'] = [{'id':'notebook-uv-project','requiredClaims':[]}]
        result = module.inspect_native(self.manifest,self.home)[0]
        self.assertNotEqual(result['status'],'observed')
        self.assertTrue(result['claims'])

    def test_absent_destination_uses_selected_config_without_default_file_creation(self):
        module = self.module()
        source = self.root / 'source/.config/ghostty/config.ghostty'
        source.parent.mkdir(parents=True)
        source.write_text('font-family = SpaceMono Nerd Font Mono\n')
        executable = self.bin/'ghostty'
        executable.write_text('''#!/bin/sh
case "$1" in
 --version) echo 'Ghostty 1.3.1'; exit 0;;
esac
case "$1" in
 +validate-config) case "$*" in *--config-file=*) exit 0;; *) exit 72;; esac;;
 +show-config) test -f "$XDG_CONFIG_HOME/ghostty/config.ghostty" || exit 71; echo 'font-family = SpaceMono Nerd Font Mono';;
 +list-fonts) echo 'SpaceMono Nerd Font Mono';;
 *) exit 73;;
esac
''')
        executable.chmod(0o700)
        self.manifest['files']=[{'target':'.config/ghostty/config.ghostty','source':str(source)}]
        self.manifest['nativeDependencies']=[{'id':'ghostty'},{'id':'space-mono-nerd-font'}]
        with patch.dict(os.environ,{'DOTFILES_CALLER_PATH':str(self.bin)}):
            result=module.inspect_native(self.manifest,self.home)
        self.assertEqual([r['status'] for r in result],['observed','observed'])
        self.assertEqual(list(self.home.iterdir()),[])

    def test_runtime_json_key_order_does_not_change_native_evidence(self):
        from types import SimpleNamespace
        module = self.module()
        self.manifest['nativeDependencies'] = [{'id':'uv-visidata'}]
        self.manifest['commandRequirements'] = [{'command':'nvim','provider':str(self.root)}]
        self.manifest['files'] = [{'target':'.config/nvim/lua/data_query/tool.lua',
                                  'source':'/nix/store/fixture-runtime/.config/nvim/lua/data_query/tool.lua'}]
        outputs = ['{"parquet":{"ok":true},"data_query":{"duckdb":{"ok":true}}}',
                   '{"data_query":{"duckdb":{"ok":true}},"parquet":{"ok":true}}']
        with patch.dict(os.environ,{'DOTFILES_CALLER_PATH':str(self.bin)}), patch.object(module.subprocess,'run',side_effect=[SimpleNamespace(returncode=0,stdout=x,stderr='') for x in outputs]):
            first = module.inspect_native(self.manifest,self.home)
            second = module.inspect_native(self.manifest,self.home)
        self.assertEqual(first,second)
        self.assertEqual(first[0]['status'],'observed')

    @unittest.skipUnless(str(ROOT).startswith('/nix/store/') and shutil.which('nvim'),
                         'actual immutable Neovim runtime is exercised by the native Nix check')
    def test_actual_first_use_neovim_probe_keeps_home_unchanged(self):
        self.manifest['nativeDependencies'] = [{'id':'uv-visidata'}]
        self.manifest['commandRequirements'] = [{'command':'nvim','provider':str(Path(shutil.which('nvim')).parent.parent)}]
        self.manifest['files'] = [{'target':'.config/nvim/lua/data_query/tool.lua',
                                  'source':str(ROOT/'.config/nvim/lua/data_query/tool.lua')}]
        result = self.module().inspect_native(self.manifest,self.home)
        self.assertTrue(result[0]['queries'], 'actual selected Neovim must execute')
        self.assertEqual(list(self.home.rglob('*')), [], 'first-use observation wrote into the home')
