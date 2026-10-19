"""Manager failures must prevent unsafe file restoration."""
import importlib
import os
import plistlib
import shlex
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(os.environ.get('DOTFILES_MIGRATION_SOURCE_ROOT', Path(__file__).resolve().parents[2]))
sys.path.insert(0, str(ROOT / 'nix'))

class ServiceTests(unittest.TestCase):
    def setUp(self):
        parent = Path(os.environ.get('DOTFILES_MIGRATION_TEST_ROOT', '/tmp/dotfiles-isq318-tests'))
        parent.mkdir(exist_ok=True)
        self.root = Path(tempfile.mkdtemp(prefix='services-', dir=parent))
        self.home = self.root / 'home'
        self.home.mkdir(mode=0o700)
        self.state = self.root / 'state'
        self.state.write_text('active')
        self.fail = self.root / 'fail'
        self.unit = self.root / 'fixture.service'
        self.unit.write_text('[Service]\nExecStart=/nix/store/reviewed/bin/worker supervise\n')
        self.target = self.home / '.config/systemd/user/fixture.service'
        self.target.parent.mkdir(parents=True)
        self.target.symlink_to(self.unit)
        self.provider = self.root / 'provider'
        self.provider.write_text(f'FragmentPath={self.target}\nNeedDaemonReload=no\nExecStart={{ path=/nix/store/reviewed/bin/worker ; argv[]=/nix/store/reviewed/bin/worker supervise ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }}\n')
        self.manager = self.root / 'systemctl'
        self.manager.write_text(f'''#!/bin/sh
case "$2" in
 show) printf 'LoadState=loaded\\nActiveState=%s\\nUnitFileState=enabled\\n' "$(cat {self.state})"; cat {self.provider};;
 stop) echo inactive > {self.state}; test ! -e {self.fail};;
 start) echo active > {self.state};;
 daemon-reload|enable|disable) exit 0;;
 *) exit 98;;
esac
''')
        self.manager.chmod(0o700)
        self.manifest = {'services': [{'manager': 'systemd', 'name': 'fixture.service', 'kind': 'service', 'files': [{'target': '.config/systemd/user/fixture.service', 'source': str(self.unit)}]}],
                         'serviceManagerEffects': [{'manager': 'systemd', 'systemctlPath': str(self.manager)}]}

    def module(self):
        self.assertTrue((ROOT / 'nix/migration/services.py').exists(), 'service recovery implementation missing')
        return importlib.import_module('migration.services')

    def test_partial_stop_failure_is_not_success_and_retry_observes_state(self):
        module = self.module()
        manager = module.Services(self.manifest, self.home)
        before = manager.snapshot()
        self.fail.touch()
        with self.assertRaises(module.Conflict):
            manager.stop()
        self.assertEqual(self.state.read_text().strip(), 'inactive')
        self.fail.unlink()
        manager.stop()
        manager.restore(before)
        self.assertEqual(self.state.read_text().strip(), 'active')

    def test_unavailable_manager_does_not_mean_absent(self):
        module = self.module()
        self.manager.unlink()
        with self.assertRaises(module.Conflict):
            module.Services(self.manifest, self.home).snapshot()

    def test_stop_exit_zero_but_still_active_fails(self):
        module = self.module()
        self.manager.write_text(f'#!/bin/sh\nprintf "LoadState=loaded\\nActiveState=active\\nUnitFileState=enabled\\n"\ncat {self.provider}\n')
        with self.assertRaises(module.Conflict):
            module.Services(self.manifest, self.home).stop()

    def test_restore_does_not_reenable_an_already_restored_unit_layout(self):
        module = self.module()
        self.manager.write_text(self.manager.read_text().replace('daemon-reload|enable|disable) exit 0;;','enable) exit 77;;\n daemon-reload|disable) exit 0;;'))
        manager = module.Services(self.manifest,self.home)
        before = manager.snapshot()
        manager.stop()
        manager.restore(before)
        self.assertEqual(manager.snapshot(),before)


    def test_partial_bootout_failure_stays_recoverable(self):
        module = self.module()
        self.manager.write_text(f'''#!/bin/sh
case "$1" in
 print-disabled) echo 'disabled services = {{ "fixture.agent" => false }}';;
 print) if [ "$(cat {self.state})" = active ]; then printf 'state = running\\npath = /fixture/original.plist\\nprogram = /fixture/original\\narguments = {{\\n /fixture/original\\n supervise\\n}}\\n'; else echo 'Could not find service' >&2; exit 113; fi;;
 bootout) echo inactive > {self.state}; test ! -e {self.fail};;
 bootstrap|kickstart) echo active > {self.state};;
 enable|disable) exit 0;;
 *) exit 98;;
esac
''')
        self.manifest = {'services':[{'manager':'launchd','name':'fixture.agent','kind':'agent','files':[{'target':'Library/LaunchAgents/fixture.plist'}]}],
                         'serviceManagerEffects':[{'manager':'launchd','launchctlPath':str(self.manager)}]}
        manager = module.Services(self.manifest,self.home)
        before = manager.snapshot()
        self.fail.touch()
        with self.assertRaises(module.Conflict): manager.stop()
        self.assertEqual(self.state.read_text().strip(),'inactive')
        self.fail.unlink()
        manager.stop()
        manager.restore(before)
        self.assertEqual(self.state.read_text().strip(),'active')

    def test_active_global_provider_does_not_verify_home_activation(self):
        module = self.module()
        self.provider.write_text(self.provider.read_text().replace(str(self.target), '/etc/systemd/user/fixture.service'))
        with self.assertRaises(module.Conflict):
            module.Services(self.manifest, self.home).verify_active()

    def test_same_fragment_with_stale_loaded_command_does_not_verify(self):
        module = self.module()
        for replacement in ['/nix/store/old/bin/worker', '/nix/store/reviewed/bin/worker wrong-argument']:
            with self.subTest(command=replacement):
                self.provider.write_text(f'FragmentPath={self.target}\nNeedDaemonReload=no\nExecStart={{ path={replacement.split()[0]} ; argv[]={replacement} ; ignore_errors=no }}\n')
                with self.assertRaises(module.Conflict):
                    module.Services(self.manifest, self.home).verify_active()

    def test_missing_or_malformed_provider_fails_closed(self):
        module = self.module()
        valid = self.provider.read_text()
        for text in ['', valid.replace('ExecStart={', 'ExecStart=malformed {'), valid.replace('NeedDaemonReload=no', 'NeedDaemonReload=yes')]:
            with self.subTest(provider=text):
                self.provider.write_text(text)
                with self.assertRaises(module.Conflict):
                    module.Services(self.manifest, self.home).verify_active()

    def test_restoration_rejects_changed_selected_provider(self):
        module = self.module()
        manager = module.Services(self.manifest, self.home)
        before = manager.snapshot()
        self.provider.write_text(self.provider.read_text().replace('/nix/store/reviewed/bin/worker', '/nix/store/old/bin/worker'))
        with self.assertRaises(module.Conflict):
            manager.restore(before)

    def test_exact_selected_systemd_provider_verifies(self):
        self.module().Services(self.manifest, self.home).verify_active()

    def test_launchd_selected_configuration_is_verified(self):
        module = self.module()
        target = self.home / 'Library/LaunchAgents/fixture.plist'
        target.parent.mkdir(parents=True)
        source = self.root / 'fixture.plist'
        source.write_bytes(plistlib.dumps({'Label':'fixture.agent', 'ProgramArguments':['/nix/store/reviewed/bin/worker','supervise']}))
        target.write_bytes(source.read_bytes())
        service = {'manager':'launchd','name':'fixture.agent','kind':'agent','files':[{'target':'Library/LaunchAgents/fixture.plist','source':str(source)}]}
        manifest = {'services':[service], 'serviceManagerEffects':[{'manager':'launchd','launchctlPath':str(self.manager)}]}
        valid = f'gui/1000/fixture.agent = {{\n path = {target}\n state = running\n program = /nix/store/reviewed/bin/worker\n arguments = {{\n /nix/store/reviewed/bin/worker\n supervise\n }}\n}}\n'
        for text, accepted in [(valid, True), (valid.replace(str(target),'/old/fixture.plist'),False), (valid.replace('/nix/store/reviewed/bin/worker','/old/worker'),False), (valid.replace('supervise','wrong'),False), ('state = running\n',False)]:
            with self.subTest(output=text):
                self.manager.write_text('#!/bin/sh\ncase "$1" in\nprint-disabled) echo \'disabled services = { "fixture.agent" => false }\';;\nprint) printf %s '+shlex.quote(text)+';;\nesac\n')
                manager = module.Services(manifest, self.home)
                if accepted:
                    manager.verify_active()
                else:
                    with self.assertRaises(module.Conflict): manager.verify_active()

    def test_recovery_can_stop_known_loaded_provider_pending_reload(self):
        module = self.module()
        self.provider.write_text(self.provider.read_text().replace('NeedDaemonReload=no','NeedDaemonReload=yes'))
        manager = module.Services(self.manifest, self.home)
        with self.assertRaises(module.Conflict): manager.verify_active()
        manager.stop()
        self.assertEqual(self.state.read_text().strip(), 'inactive')
