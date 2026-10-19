"""Preview must enumerate conflicts without changing any home/source bytes."""
import importlib
import json
import os
from pathlib import Path
import platform
import pwd
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(os.environ.get('DOTFILES_MIGRATION_SOURCE_ROOT', Path(__file__).resolve().parents[2]))
sys.path.insert(0, str(ROOT / 'nix'))


def snapshot(root):
    return {str(p.relative_to(root)): (p.lstat().st_mode, os.readlink(p) if p.is_symlink()
            else p.read_bytes() if p.is_file() else None) for p in root.rglob('*')}


class MigrationPlanTests(unittest.TestCase):
    def setUp(self):
        parent = Path(os.environ.get('DOTFILES_MIGRATION_TEST_ROOT', '/tmp/dotfiles-isq317-tests'))
        parent.mkdir(exist_ok=True, mode=0o700)
        self.root = Path(tempfile.mkdtemp(prefix='preview-', dir=parent))
        self.home = self.root / 'home'
        self.home.mkdir(mode=0o700)
        self.source = self.root / 'source'
        self.source.write_text('new content\n')
        self.generation = self.root / 'generation'
        self.generation.mkdir()
        self.manifest = {'schema': 1, 'profile': 'linux' if sys.platform.startswith('linux') else 'darwin',
                         'system': ('aarch64' if platform.machine() in ['arm64', 'aarch64'] else 'x86_64')
                                   + ('-linux' if sys.platform.startswith('linux') else '-darwin'),
                         'username': 'fixture', 'homeDirectory': str(self.home),
                         'activationPackage': str(self.generation),
                         'files': [{'target': '.config/example', 'source': str(self.source), 'executable': False}],
                         'mutableSeeds': [], 'profilePaths': [], 'nativeDependencies': [],
                         'services': [], 'serviceManagerEffects': [], 'commandRequirements': []}
        self.plan = None

    def module(self):
        self.assertTrue((ROOT / 'nix/migration/plan.py').is_file(), 'migration inspector missing')
        return importlib.import_module('migration.plan')

    def inspect(self):
        before = snapshot(self.root)
        result = self.module().inspect(self.manifest, self.home)
        self.assertEqual(snapshot(self.root), before)
        json.dumps(result)
        return result

    def codes(self, result):
        return {c['code'] for c in result['conflicts']}

    def target(self, content=None):
        path = self.home / '.config/example'
        path.parent.mkdir()
        if content is not None:
            path.write_text(content)
        return path

    def test_held_lock_reconciles_only_its_created_scaffolding(self):
        from migration.model import HomeLock
        result = self.inspect()
        with HomeLock(self.home) as lock:
            self.module().verify_unchanged(result, lock=lock)
            (self.home / 'unrelated').write_text('new content')
            with self.assertRaisesRegex(self.module().Conflict, 'changed'):
                self.module().verify_unchanged(result, lock=lock)

    def test_held_lock_rejects_replaced_created_parent(self):
        from migration.model import HomeLock
        result = self.inspect()
        with HomeLock(self.home) as lock:
            root = self.home / '.local/state/dotfiles-ownership'
            root.rename(root.with_name('displaced'))
            root.mkdir(mode=0o700)
            (root / 'lock').mkdir(mode=0o700)
            with self.assertRaises(self.module().Conflict):
                self.module().verify_unchanged(result, lock=lock)

    def test_clean_and_equal_legacy_files_plan_without_mutation(self):
        result = self.inspect()
        self.assertEqual(result['conflicts'], [])
        self.assertEqual(result['files'][0]['action'], 'link')
        self.target(self.source.read_text())
        result = self.inspect()
        self.assertEqual(result['conflicts'], [])
        self.assertEqual(result['files'][0]['action'], 'backup-and-link')
        self.module().verify_unchanged(result)

    def test_modified_preserved_links_missing_sources_and_backup_collisions_all_reported(self):
        self.target('local edit')
        from unittest.mock import patch
        from types import SimpleNamespace
        reservation = self.home / '.local/state/dotfiles-ownership/transactions' / ('a' * 32)
        backup = reservation / 'originals/.config/example'
        backup.parent.mkdir(parents=True)
        backup.write_text('keep backup')
        absent = self.root / 'missing'
        linked = self.home / 'preserved'
        linked.symlink_to(self.source)
        self.manifest['files'] += [{'target': 'absent', 'source': str(absent), 'executable': False},
                                  {'target': 'preserved', 'source': str(self.source), 'executable': False}]
        with patch('uuid.uuid4', return_value=SimpleNamespace(hex='a' * 32)):
            result = self.inspect()
        self.assertTrue({'modified-file', 'preserved-symlink', 'missing-source', 'backup-collision'} <= self.codes(result))

    def test_identity_architecture_and_unsafe_home_parents_are_conflicts(self):
        self.manifest['homeDirectory'] = '/other-home'
        self.manifest['system'] = 'foreign-linux'
        (self.home / '.config').symlink_to(self.root)
        result = self.inspect()
        self.assertTrue({'home-mismatch', 'system-mismatch', 'unsafe-parent'} <= self.codes(result))

    def test_mutable_seeds_preserved_and_linux_service_leaves_normalized(self):
        self.manifest['mutableSeeds'] = [{'target': 'lazy-lock.json', 'source': str(self.source)}]
        (self.home / 'lazy-lock.json').write_text('user locks')
        self.manifest['services'] = [{'manager': 'systemd', 'name': 'example.service',
                                     'files': list(self.manifest['files'])}]
        # Explicit private fixture manager; never contact the host manager.
        manager = self.root / 'systemctl'
        manager.write_text('#!/bin/sh\nprintf "%s\\n" "LoadState=loaded" "ActiveState=inactive" "UnitFileState=disabled"\n')
        manager.chmod(0o700)
        self.manifest['serviceManagerEffects'] = [{'manager': 'systemd', 'systemctlPath': str(manager)}]
        result = self.inspect()
        self.assertEqual(len(result['files']), 1)
        self.assertEqual(result['mutableSeeds'][0]['action'], 'preserve')
        self.assertIn('ActiveState=inactive', result['services'][0]['state']['stdout'])

    def test_darwin_owned_copy_and_service_state_drift(self):
        manager = self.root / 'launchctl'
        state = self.root / 'manager-state'
        state.write_text('loaded')
        manager.write_text('#!/bin/sh\ncat "' + str(state) + '"\n')
        manager.chmod(0o700)
        self.manifest['services'] = [{'manager': 'launchd', 'name': 'fixture.agent', 'files': [
            {'target': 'Library/LaunchAgents/fixture.plist', 'source': str(self.source),
             'deployment': 'owned-copy', 'mode': '0444', 'executable': False}]}]
        self.manifest['serviceManagerEffects'] = [{'manager': 'launchd', 'launchctlPath': str(manager)}]
        result = self.inspect()
        self.assertEqual(result['files'][1]['action'], 'copy')
        state.write_text('unloaded')
        with self.assertRaises(self.module().Conflict):
            self.module().verify_unchanged(result)

    def test_profile_directories_dynamic_children_and_unrelated_deployment(self):
        profiles = self.home / '.local/state/nix/profiles'
        profiles.mkdir(parents=True)
        (profiles / 'home-manager-17-link').symlink_to(self.generation)
        (profiles / 'unrelated').write_text('keep')
        self.manifest['profilePaths'] = [str(profiles.parent), str(profiles), str(profiles / 'home-manager')]
        result = self.inspect()
        self.assertIn('unrelated-home-manager', self.codes(result))
        (profiles / 'home-manager-18-link').symlink_to(self.generation)
        with self.assertRaises(self.module().Conflict):
            self.module().verify_unchanged(result)

    def test_file_parent_source_provider_and_native_state_drift_are_detected(self):
        provider = self.root / 'provider/bin/tool'
        provider.parent.mkdir(parents=True)
        provider.write_text('#!/bin/sh\nexit 0\n')
        provider.chmod(0o700)
        self.manifest['commandRequirements'] = [{'command': 'tool', 'provider': str(provider.parent.parent)}]
        result = self.inspect()
        self.assertEqual(result['providers'][0]['executable'], str(provider))
        provider.write_text('#!/bin/sh\nexit 1\n')
        with self.assertRaises(self.module().Conflict):
            self.module().verify_unchanged(result)
        result = self.inspect()
        self.source.write_text('changed source')
        with self.assertRaises(self.module().Conflict):
            self.module().verify_unchanged(result)
        result = self.inspect()
        (self.home / '.config').mkdir()
        with self.assertRaises(self.module().Conflict):
            self.module().verify_unchanged(result)

    def test_old_taplo_and_unverified_native_prerequisites(self):
        artifact = self.home / '.local/opt/taplo-0.10.0-x86_64'
        artifact.mkdir(parents=True)
        (artifact / 'taplo').write_text('old native provider')
        self.manifest['nativeDependencies'] = [{'id': 'space-mono-nerd-font'}, {'id': 'notebook-uv-project'}]
        result = self.inspect()
        self.assertEqual(len(result['legacyTaplo']), 1)
        self.assertEqual(result['legacyTaplo'][0]['action'], 'preserve')
        self.assertIn('native-unverified', self.codes(result))
        (artifact / 'taplo').write_text('drift')
        with self.assertRaises(self.module().Conflict):
            self.module().verify_unchanged(result)

    def test_plan_reserves_exact_collision_resistant_transaction_without_creating_it(self):
        first = self.inspect()
        second = self.inspect()
        self.assertIn('transactionId', first, 'preview lacks transaction reservation')
        self.assertNotEqual(first['transactionId'], second['transactionId'])
        transaction = Path(first['journalPath'])
        self.assertFalse(transaction.exists())
        self.assertEqual(first['files'][0]['backupPath'], str(transaction / 'originals/.config/example'))
        transaction.mkdir(parents=True, mode=0o700)
        with self.assertRaises(self.module().Conflict):
            self.module().verify_unchanged(first)

    def test_caller_provider_selection_survives_pinned_runtime_path(self):
        from unittest.mock import patch
        native = self.root / 'native/tool'
        native.parent.mkdir()
        native.write_text('#!/bin/sh\nexit 0\n')
        native.chmod(0o700)
        pinned = self.root / 'pinned/bin/tool'
        pinned.parent.mkdir(parents=True)
        pinned.write_text('#!/bin/sh\nexit 0\n')
        pinned.chmod(0o700)
        self.manifest['commandRequirements'] = [{'command': 'tool', 'provider': str(pinned.parent.parent)}]
        with patch.dict(os.environ, {'PATH': str(pinned.parent), 'DOTFILES_CALLER_PATH': str(native.parent)}):
            result = self.inspect()
            self.assertEqual(result['providers'][0]['selectedExecutable'], str(native))
            self.assertIn('provider-shadowed', self.codes(result))
            self.assertEqual(result['providerPath'], str(native.parent))
            self.assertEqual(result['runtimePath'], str(pinned.parent))
            self.module().verify_unchanged(result)

    def test_native_provider_earlier_executable_with_same_caller_path_is_drift(self):
        from unittest.mock import patch
        for identity, command in [('ghostty', 'ghostty'), ('linux-bubblewrap', 'bwrap')]:
            with self.subTest(command=command):
                early = self.root / (command + '-early')
                late = self.root / (command + '-late')
                early.mkdir()
                late.mkdir()
                old = late / command
                old.write_text('#!/bin/sh\nexit 0\n')
                # Unsafe private bwrap is observed without running a namespace probe.
                old.chmod(0o777)
                self.manifest['nativeDependencies'] = [{'id': identity}]
                caller_path = str(early) + ':' + str(late)
                with patch.dict(os.environ, {'DOTFILES_CALLER_PATH': caller_path}):
                    result = self.inspect()
                    self.module().verify_unchanged(result)
                    new = early / command
                    new.write_text('#!/bin/sh\nexit 0\n')
                    new.chmod(0o700)
                    with self.assertRaisesRegex(self.module().Conflict, 'native provider selection'):
                        self.module().verify_unchanged(result)
                    self.assertEqual(result['nativePrerequisites'][0]['command'], command)
                    self.assertEqual(result['nativePrerequisites'][0]['selectedExecutable'], str(old))

    def test_native_provider_absent_to_present_with_same_caller_path_is_drift(self):
        from unittest.mock import patch
        for identity, command in [('ghostty', 'ghostty'), ('linux-bubblewrap', 'bwrap')]:
            with self.subTest(command=command):
                directory = self.root / (command + '-absent')
                directory.mkdir()
                self.manifest['nativeDependencies'] = [{'id': identity}]
                with patch.dict(os.environ, {'DOTFILES_CALLER_PATH': str(directory)}):
                    result = self.inspect()
                    self.module().verify_unchanged(result)
                    new = directory / command
                    new.write_text('#!/bin/sh\nexit 0\n')
                    new.chmod(0o700)
                    with self.assertRaisesRegex(self.module().Conflict, 'native provider selection'):
                        self.module().verify_unchanged(result)
                    self.assertIsNone(result['nativePrerequisites'][0]['selectedExecutable'])

    def test_provider_selection_path_drift_is_a_conflict(self):
        from unittest.mock import patch
        result = self.inspect()
        with patch.dict(os.environ, {'PATH': '/different/provider/path'}):
            with self.assertRaises(self.module().Conflict):
                self.module().verify_unchanged(result)

    def test_legacy_taplo_nested_binary_changes_are_detected(self):
        binary = self.home / '.local/opt/taplo-0.10.0-x86_64/bin/taplo'
        binary.parent.mkdir(parents=True)
        binary.write_text('old binary')
        result = self.inspect()
        binary.write_text('changed binary')
        with self.assertRaises(self.module().Conflict):
            self.module().verify_unchanged(result)

    def test_unsafe_bubblewrap_missing_ghostty_and_default_timeout_have_evidence(self):
        from unittest.mock import patch
        bwrap = self.root / 'bin/bwrap'
        bwrap.parent.mkdir()
        bwrap.write_text('#!/bin/sh\nexit 0\n')
        bwrap.chmod(0o777)
        self.manifest['nativeDependencies'] = [{'id': 'linux-bubblewrap'}, {'id': 'ghostty'},
                                               {'id': 'linux-default-timeout'}]
        with patch.dict(os.environ, {'PATH': str(bwrap.parent)}):
            result = self.inspect()
        states = {entry['id']: entry['status'] for entry in result['nativePrerequisites']}
        self.assertEqual(states['linux-bubblewrap'], 'unverified')
        self.assertEqual(states['ghostty'], 'missing')
        self.assertIn('linux-default-timeout', states)
        self.assertIn(str(bwrap), result['evidence'])
        bwrap.chmod(0o700)
        with self.assertRaises(self.module().Conflict):
            self.module().verify_unchanged(result)

    def test_unknown_schema_unsafe_targets_and_ambiguous_overlaps_fail_closed(self):
        self.manifest['schema'] = 2
        with self.assertRaises(self.module().Conflict):
            self.inspect()
        self.manifest['schema'] = 1
        self.manifest['files'][0]['target'] = '../escape'
        with self.assertRaises(self.module().Conflict):
            self.inspect()
        self.manifest['files'][0]['target'] = 'same'
        self.manifest['files'].append({'target': 'same', 'source': str(self.root / 'different'), 'executable': False})
        with self.assertRaises(self.module().Conflict):
            self.inspect()

    def run_cli_output(self, output):
        # Substitute only Nix eval/build; real CLI inspection and file creation run.
        from unittest.mock import patch
        cli = importlib.import_module('migration.cli')
        self.manifest['username'] = pwd.getpwuid(os.getuid()).pw_name
        def nix(arguments):
            return json.dumps(self.manifest) if arguments[0] == 'eval' else self.manifest['activationPackage'] + '\n'
        environment = {'HOME': str(self.home), 'PATH': os.environ.get('PATH', os.defpath),
                       'LANG': 'C', 'PYTHONDONTWRITEBYTECODE': '1'}
        with patch.dict(os.environ, environment, clear=True), patch.object(cli, 'nix_json', side_effect=nix):
            return cli.main(['plan', '--profile', 'fixture', '--output', str(output)])

    def test_cli_rejects_output_traversal_into_home_without_writes(self):
        outside = self.root / 'outside'
        outside.mkdir()
        before = snapshot(self.home)
        with self.assertRaisesRegex(self.module().Conflict, 'migration input'):
            self.run_cli_output(outside / '..' / 'home' / 'plan.json')
        self.assertEqual(snapshot(self.home), before)

    def test_cli_rejects_output_through_symlinked_ancestor_into_home_without_writes(self):
        alias = self.root / 'alias'
        alias.symlink_to(self.root, target_is_directory=True)
        before = snapshot(self.home)
        with self.assertRaisesRegex(self.module().Conflict, 'migration input'):
            self.run_cli_output(alias / 'home' / 'plan.json')
        self.assertEqual(snapshot(self.home), before)

    def test_cli_rejects_output_alias_into_recorded_generation_without_writes(self):
        alias = self.root / 'alias'
        alias.symlink_to(self.root, target_is_directory=True)
        before = snapshot(self.generation)
        with self.assertRaisesRegex(self.module().Conflict, 'migration input'):
            self.run_cli_output(alias / 'generation' / 'plan.json')
        self.assertEqual(snapshot(self.generation), before)

    def test_cli_rejects_output_into_canonically_aliased_recorded_input(self):
        alias = self.root / 'alias'
        alias.symlink_to(self.root, target_is_directory=True)
        self.manifest['activationPackage'] = str(alias / 'generation')
        before = snapshot(self.generation)
        with self.assertRaisesRegex(self.module().Conflict, 'migration input'):
            self.run_cli_output(self.generation / 'plan.json')
        self.assertEqual(snapshot(self.generation), before)

    def test_cli_preview_under_permissive_umask_is_readable_by_apply(self):
        from migration.transaction import read_json
        output = self.root / 'plan.json'
        previous_umask = os.umask(0o002)
        try:
            self.assertEqual(self.run_cli_output(output), 0)
        finally:
            os.umask(previous_umask)
        preview = read_json(output)
        self.assertEqual(preview['home'], str(self.home))
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)

    def test_cli_valid_output_with_outside_ancestor_alias_remains_exclusive(self):
        reviews = self.root / 'reviews/nested'
        reviews.mkdir(parents=True)
        alias = self.root / 'review-alias'
        alias.symlink_to(reviews.parent, target_is_directory=True)
        output = alias / 'nested/plan.json'
        before = snapshot(self.home)
        self.assertEqual(self.run_cli_output(output), 0)
        original = (reviews / 'plan.json').read_bytes()
        self.assertEqual(snapshot(self.home), before)
        with self.assertRaisesRegex(self.module().Conflict, 'Output already exists'):
            self.run_cli_output(output)
        self.assertEqual((reviews / 'plan.json').read_bytes(), original)

    def test_raw_cli_rejects_check_identity_then_missing_packaged_binding(self):
        cli = ROOT / 'nix/migration/cli.py'
        self.assertTrue(cli.is_file(), 'preview CLI missing')
        mock = self.root / 'bin/nix'
        mock.parent.mkdir()
        manifest_file = self.root / 'manifest.json'
        self.manifest['username'] = pwd.getpwuid(os.getuid()).pw_name
        manifest_file.write_text(json.dumps(self.manifest))
        log = self.root / 'nix-log'
        mock.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "' + str(log) + '"\ncase $1 in\n eval) cat "'
                        + str(manifest_file) + '";;\n build) printf "%s\\n" "' + str(self.generation) + '";;\n *) exit 99;;\nesac\n')
        mock.chmod(0o700)
        env = {'HOME': str(self.home), 'PATH': str(mock.parent) + ':' + os.environ.get('PATH', os.defpath),
               'PYTHONDONTWRITEBYTECODE': '1', 'LANG': 'C'}
        output = self.root / 'plan.json'
        command = [sys.executable, str(cli), 'plan', '--profile', 'check-x86_64-linux', '--output', str(output)]
        result = subprocess.run(command, env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn('check profiles are disposable identities', result.stderr)
        self.assertFalse(log.exists(), 'check identity must fail before Nix effects')
        command[4] = 'fixture'
        before = snapshot(self.home)
        result = subprocess.run(command, env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('packaged immutable source', result.stderr)
        self.assertFalse(log.exists(), 'unbound CLI must fail before Nix effects')
        self.assertFalse(output.exists())
        self.assertEqual(snapshot(self.home), before)



if __name__ == '__main__':
    unittest.main()
