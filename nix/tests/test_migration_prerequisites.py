"""Native claims fail closed and bind actual providers and local sessions."""
import importlib
from contextlib import ExitStack
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

    def desktop(self, backend):
        """Real private sockets/providers; redirect only fixed host socket paths."""
        module = self.module()
        stack = self.enterContext(ExitStack())
        fixture = self.root/backend
        fixture.mkdir()
        runtime = fixture/'runtime'
        runtime.mkdir(mode=0o700)
        x11 = fixture/'x11'
        x11.mkdir(mode=0o1777)
        x11.chmod(0o1777)
        real_lstat = Path.lstat
        def lstat(path, *args, **kwargs):
            info = real_lstat(path, *args, **kwargs)
            if path == x11:
                # The fixture cannot chown the conventional shared X11 directory.
                info = os.stat_result((*info[:4], 0, *info[5:]))
            return info
        stack.enter_context(patch.object(Path, 'lstat', lstat))
        host_runtime = Path(f'/run/user/{os.getuid()}')
        def path(value):
            selected = Path(value)
            return runtime if selected == host_runtime else x11 if selected == Path('/tmp/.X11-unix') else selected
        stack.enter_context(patch.object(module, 'Path', path))
        for name in ['bus'] + (['wayland-1'] if backend == 'wayland' else []):
            connection = stack.enter_context(socket.socket(socket.AF_UNIX))
            connection.bind(str(runtime/name))
            connection.listen(64)
        if backend == 'x11':
            connection = stack.enter_context(socket.socket(socket.AF_UNIX))
            connection.bind(str(x11/'X0'))
            connection.listen(64)
        for name in ['systemctl'] + (['wl-copy','wl-paste'] if backend == 'wayland' else []):
            executable = self.bin/name
            executable.write_text('#!/bin/sh\necho running\n')
            executable.chmod(0o700)
        environment = {'PATH':str(self.bin), 'DOTFILES_CALLER_PATH':str(self.bin),
                       'XDG_RUNTIME_DIR':str(runtime), 'DBUS_SESSION_BUS_ADDRESS':'unix:path='+str(runtime/'bus')}
        environment.update({'WAYLAND_DISPLAY':'wayland-1'} if backend == 'wayland' else {'DISPLAY':':0'})
        stack.enter_context(patch.dict(os.environ, environment, clear=True))
        self.manifest['nativeDependencies'] = [{'id':'desktop-clipboard'}]
        return module, runtime, x11

    def test_local_x11_uses_existing_osc52_without_wayland_or_cliphist(self):
        module, runtime, x11 = self.desktop('x11')
        result = module.inspect_native(self.manifest, self.home)[0]
        self.assertEqual(result['status'], 'observed')
        self.assertEqual(result['backend'], 'osc52')
        self.assertIn(str(x11/'X0'), result['observations'])
        self.assertIn(str(runtime/'bus'), result['observations'])
        self.assertEqual(list(self.home.iterdir()), [])

    def test_wayland_without_capture_does_not_require_cliphist(self):
        module, runtime, _ = self.desktop('wayland')
        result = module.inspect_native(self.manifest, self.home)[0]
        self.assertEqual(result['status'], 'observed')
        self.assertEqual(result['backend'], 'wl-copy')
        self.assertIn(str(self.bin/'wl-copy'), result['observations'])
        self.assertIn(str(runtime/'wayland-1'), result['observations'])

    def test_configured_capture_requires_cliphist_and_binds_config(self):
        module, _, _ = self.desktop('wayland')
        override = self.home/'.config/systemd/user/cliphist.service.d/override.conf'
        override.parent.mkdir(parents=True)
        override.write_text('[Service]\nExecStart=/usr/bin/wl-paste --watch capture\n')
        missing = module.inspect_native(self.manifest, self.home)[0]
        self.assertEqual(missing['status'], 'unverified')
        executable = self.bin/'cliphist'
        executable.write_text('#!/bin/sh\nexit 0\n')
        executable.chmod(0o700)
        observed = module.inspect_native(self.manifest, self.home)[0]
        self.assertEqual(observed['status'], 'observed')
        self.assertIn(str(override), observed['observations'])
        override.write_text('[Service]\nExecStart=/different-capture\n')
        self.assertNotEqual(observed, module.inspect_native(self.manifest, self.home)[0])

    def test_local_session_rejects_remote_malformed_and_mismatched_backends(self):
        for backend in ['x11','wayland']:
            with self.subTest(backend=backend):
                module, _, _ = self.desktop(backend)
                for change in [{'SSH_CONNECTION':'remote 22 local 22'}, {'SSH_CLIENT':'remote 22 22'},
                               {'SSH_TTY':'/dev/pts/1'}, {'DISPLAY':'remote:0','WAYLAND_DISPLAY':''},
                               {'DISPLAY':':0/../1','WAYLAND_DISPLAY':''},
                               {'WAYLAND_DISPLAY':'../foreign'}, {'XDG_SESSION_TYPE':'tty'},
                               {'XDG_SESSION_TYPE':'x11' if backend == 'wayland' else 'wayland'}]:
                    with self.subTest(change=change), patch.dict(os.environ, change):
                        result = module.inspect_native(self.manifest,self.home)[0]
                        claims = {claim['claim']:claim['status'] for claim in result['claims']}
                        self.assertEqual(claims['local-session-permissions'], 'unverified')

    def test_x11_screen_selection_is_bound_into_evidence(self):
        module, _, _ = self.desktop('x11')
        first = module.inspect_native(self.manifest, self.home)[0]
        with patch.dict(os.environ, {'DISPLAY':':0.1'}):
            second = module.inspect_native(self.manifest, self.home)[0]
        self.assertEqual(first['status'], 'observed')
        self.assertEqual(second['status'], 'observed')
        self.assertNotEqual(first, second)

    def test_each_native_capture_marker_including_dangling_links_requires_tools(self):
        module, _, _ = self.desktop('wayland')
        self.assertEqual(module.inspect_native(self.manifest,self.home)[0]['status'], 'observed')
        for name in ['hypr/hyprland.lua','hypr/hyprland.conf','clipboard-history/store','cliphist/config',
                     'systemd/user/cliphist.service.d/override.conf','systemd/user/cliphist.service',
                     'systemd/user/default.target.wants/cliphist.service',
                     'systemd/user/graphical-session.target.wants/cliphist.service']:
            with self.subTest(marker=name):
                path = self.home/'.config'/name
                path.parent.mkdir(parents=True,exist_ok=True)
                path.symlink_to(self.root/'absent')
                result = module.inspect_native(self.manifest,self.home)[0]
                self.assertEqual(result['status'], 'unverified')
                self.assertEqual(result['observations'][str(path)]['type'], 'symlink')
                path.unlink()

    def test_x11_cannot_satisfy_configured_wayland_capture(self):
        module, _, _ = self.desktop('x11')
        config = self.home/'.config/cliphist/config'
        config.parent.mkdir(parents=True)
        config.write_text('max-items 500\n')
        for name in ['wl-copy','wl-paste','cliphist']:
            executable = self.bin/name
            executable.write_text('#!/bin/sh\nexit 0\n')
            executable.chmod(0o700)
        self.assertEqual(module.inspect_native(self.manifest,self.home)[0]['status'], 'unverified')

    def test_wayland_requires_both_native_providers(self):
        module, _, _ = self.desktop('wayland')
        for name in ['wl-copy','wl-paste']:
            with self.subTest(command=name):
                executable = self.bin/name
                executable.chmod(0o600)
                self.assertEqual(module.inspect_native(self.manifest,self.home)[0]['status'], 'unverified')
                executable.chmod(0o700)

    def test_local_socket_type_owner_connection_and_runtime_permissions_fail_closed(self):
        module, runtime, x11 = self.desktop('x11')
        runtime.chmod(0o755)
        self.assertEqual(module.inspect_native(self.manifest,self.home)[0]['status'], 'unverified')
        runtime.chmod(0o700)
        x11.chmod(0o777)
        self.assertEqual(module.inspect_native(self.manifest,self.home)[0]['status'], 'unverified')
        x11.chmod(0o1777)
        selected = x11/'X0'
        real_lstat = Path.lstat
        def foreign(path, *args, **kwargs):
            info = real_lstat(path, *args, **kwargs)
            return os.stat_result((*info[:4], os.getuid()+1, *info[5:])) if path == selected else info
        with patch.object(Path, 'lstat', foreign):
            self.assertEqual(module.inspect_native(self.manifest,self.home)[0]['status'], 'unverified')
        first = module.inspect_native(self.manifest,self.home)[0]
        self.assertEqual(first['status'], 'observed')
        selected.unlink()
        connection = self.enterContext(socket.socket(socket.AF_UNIX))
        connection.bind(str(selected))
        connection.listen(2)
        self.assertNotEqual(first, module.inspect_native(self.manifest,self.home)[0])
        connection.close()
        self.assertEqual(module.inspect_native(self.manifest,self.home)[0]['status'], 'unverified')
        selected.unlink()
        selected.write_text('not a socket')
        self.assertEqual(module.inspect_native(self.manifest,self.home)[0]['status'], 'unverified')
        selected.unlink()
        selected.symlink_to(runtime/'bus')
        self.assertEqual(module.inspect_native(self.manifest,self.home)[0]['status'], 'unverified')

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
