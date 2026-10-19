"""Real filesystem failure/retry tests; only Nix activation is substituted."""
import importlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(os.environ.get('DOTFILES_MIGRATION_SOURCE_ROOT', Path(__file__).resolve().parents[2]))
sys.path.insert(0, str(ROOT / 'nix'))
from migration.model import Conflict, read_owner
from migration.plan import inspect


class Runtime:
    def __init__(self, home, manifest):
        self.home, self.manifest = home, manifest
        self.calls = []

    def retain(self, generation, destination):
        Path(destination).symlink_to(generation)

    def activate(self, generation):
        self.calls.append(generation)
        for entry in self.manifest['files']:
            target = self.home / entry['target']
            target.parent.mkdir(parents=True, exist_ok=True)
            if target.is_symlink():
                target.unlink()
            target.symlink_to(entry['source'])

    def verify(self, manifest):
        for entry in manifest['files']:
            assert (self.home / entry['target']).resolve() == Path(entry['source']).resolve()

    def selected_generation(self, manifest):
        return self.calls[-1] if self.calls else None

    def profile_packages(self, path):
        # Native query parsing and exact real profile selection are tested separately.
        path = Path(path)
        if path.is_symlink() and str(path.resolve()) not in {str(p) for g in self.calls for p in [Path(g), Path(g) / 'home-path']}:
            return [{'name': 'native', 'paths': [str(path.resolve())], 'active': True, 'priority': None}]
        if not self.calls:
            return []
        return [{'name': 'home-manager-path', 'paths': [str(Path(self.calls[-1]) / 'home-path')], 'active': True, 'priority': None}]


class TransactionTests(unittest.TestCase):
    def setUp(self):
        parent = Path(os.environ.get('DOTFILES_MIGRATION_TEST_ROOT', '/tmp/dotfiles-isq318-tests'))
        parent.mkdir(exist_ok=True)
        self.root = Path(tempfile.mkdtemp(prefix='transaction-', dir=parent))
        self.home = self.root / 'home'
        self.home.mkdir(mode=0o700)
        self.source = self.root / 'source'
        self.source.write_text('reviewed configuration\n')
        self.generation = self.root / 'generation'
        self.generation.mkdir()
        from migration.model import fingerprint
        immutable = '/nix/store/00000000000000000000000000000000-fixture-generation'
        original_generation = self.generation
        self.addCleanup(patch.stopall)
        patch('migration.plan.fingerprint', side_effect=lambda path: fingerprint(original_generation if str(path) == immutable else path)).start()
        self.generation = Path(immutable)
        self.target = self.home / '.config/ghostty/config.ghostty'
        self.target.parent.mkdir(parents=True)
        self.target.write_bytes(self.source.read_bytes())
        self.target.chmod(0o600)
        from migration.plan import current_system
        self.manifest = dict(schema=1, profile='fixture', homeDirectory=str(self.home), username='fixture',
            system=current_system(), activationPackage=str(self.generation),
            files=[dict(target=str(self.target.relative_to(self.home)), source=str(self.source), executable=False)],
            mutableSeeds=[], profilePaths=[], nativeDependencies=[], services=[], serviceManagerEffects=[], commandRequirements=[])
        self.plan = inspect(self.manifest, self.home)
        self.runtime = Runtime(self.home, self.manifest)

    def module(self):
        self.assertTrue((ROOT / 'nix/migration/transaction.py').exists(), 'transaction implementation missing')
        return importlib.import_module('migration.transaction')

    def test_apply_and_repeat_preserve_legacy_original_and_release_owner_last(self):
        module = self.module()
        module.apply(self.plan, self.manifest, runtime=self.runtime)
        owner = read_owner(self.home)
        self.assertEqual(owner['phase'], 'home-manager')
        self.assertTrue(self.target.is_symlink())
        backup = Path(self.plan['files'][0]['backupPath'])
        self.assertEqual(backup.read_text(), 'reviewed configuration\n')
        module.apply(self.plan, self.manifest, runtime=self.runtime)
        self.assertEqual(len(self.runtime.calls), 1)
        module.restore_legacy(self.home, self.plan['transactionId'], runtime=self.runtime)
        self.assertIsNone(read_owner(self.home))
        self.assertFalse(self.target.is_symlink())
        self.assertEqual(self.target.stat().st_mode & 0o777, 0o600)
        module.restore_legacy(self.home, self.plan['transactionId'], runtime=self.runtime)
        self.assertEqual(self.target.read_text(), 'reviewed configuration\n')

    def unpublished_update(self, *, publish_intent=False):
        """Crash after a real child journal save while the active owner stays A."""
        module = self.module()
        module.apply(self.plan, self.manifest, runtime=self.runtime)
        owner = read_owner(self.home)
        source = self.root/'updated-source'
        source.write_text('reviewed updated configuration\n')
        generation = '/nix/store/' + '1'*32 + '-updated-generation'
        real_generation = self.root/'updated-generation'
        real_generation.mkdir()
        from migration import plan as inspection
        original = inspection.fingerprint
        patch.object(inspection, 'fingerprint', side_effect=lambda path:
                     original(real_generation if str(path) == generation else path)).start()
        profile = self.home/'.local/state/nix/profiles/home-manager'
        manifest = dict(self.manifest, activationPackage=generation, profilePaths=[str(profile)],
                        files=[dict(self.manifest['files'][0], source=str(source))])
        plan = inspect(manifest, self.home)
        self.assertEqual(plan['conflicts'], [])
        save = module.Journal.save
        def interrupt(journal):
            result = save(journal)
            boundary = {'publish-transferring': 'intent'} if publish_intent else {}
            if journal.data['transactionId'] == plan['transactionId'] and journal.data['steps'] == boundary:
                raise InterruptedError('unpublished prepared child')
            return result
        with patch.object(module.Journal, 'save', new=interrupt), self.assertRaises(InterruptedError):
            module.apply(plan, manifest, runtime=self.runtime)
        self.assertEqual(read_owner(self.home), owner)
        return owner, plan, manifest

    def test_unpublished_child_recovery_preserves_active_parent_and_is_idempotent(self):
        module = self.module()
        for publish_intent in [False, True]:
            with self.subTest(publish_intent=publish_intent):
                self.setUp()
                owner, plan, manifest = self.unpublished_update(publish_intent=publish_intent)
                owner_path = self.home/'.local/state/dotfiles-ownership/owner.json'
                owner_bytes = owner_path.read_bytes()
                with self.assertRaises(Conflict):
                    module.apply(plan, manifest, runtime=self.runtime)
                with patch.object(module.Services, 'stop', side_effect=AssertionError('stopped active parent service')):
                    module.restore_legacy(self.home, plan['transactionId'], runtime=self.runtime)
                    module.restore_legacy(self.home, plan['transactionId'], runtime=self.runtime)
                self.assertEqual(owner_path.read_bytes(), owner_bytes)
                self.assertEqual(read_owner(self.home), owner)
                self.assertEqual(self.target.resolve(), self.source)
                self.assertEqual(self.runtime.calls, [str(self.generation)])
                self.assertEqual(module.Journal(self.home, plan['transactionId']).data['phase'], 'restored')
                self.assertEqual(module.Journal(self.home, owner['transactionId']).data['phase'], 'active')
                self.runtime.manifest = manifest
                fresh = inspect(manifest, self.home)
                self.assertEqual(fresh['conflicts'], [])
                module.apply(fresh, manifest, runtime=self.runtime)
                self.assertEqual(self.target.resolve(), Path(manifest['files'][0]['source']))

    def test_unpublished_child_recovery_refuses_unproven_lineage_or_effects(self):
        module = self.module()
        for drift in ['parent', 'owner', 'phase', 'step', 'published-step', 'target', 'backup', 'profile', 'parent-phase']:
            with self.subTest(drift=drift):
                self.setUp()
                owner, plan, manifest = self.unpublished_update()
                child = module.Journal(self.home, plan['transactionId'])
                if drift == 'parent': child.data['parentTransaction'] = 'f'*32
                elif drift == 'owner': child.data['plan']['ownership'] = dict(owner, transactionId='f'*32)
                elif drift == 'phase': child.data['phase'] = 'active'
                elif drift == 'step': child.data['steps'] = {'archive-0': 'intent'}
                elif drift == 'published-step': child.data['steps'] = {'publish-transferring': 'complete'}
                elif drift == 'target':
                    self.target.unlink(); self.target.write_text('later local edit')
                elif drift == 'backup':
                    backup = Path(child.data['records'][0]['backupPath'])
                    backup.parent.mkdir(parents=True)
                    backup.write_text('unexplained retained original')
                elif drift == 'profile':
                    profile = Path(manifest['profilePaths'][0])
                    profile.parent.mkdir(parents=True)
                    profile.symlink_to('/nix/store/unreviewed-generation')
                else:
                    parent = module.Journal(self.home, owner['transactionId'])
                    parent.data['phase'] = 'prepared'; parent.save()
                child.save()
                with self.assertRaises(Conflict):
                    module.restore_legacy(self.home, plan['transactionId'], runtime=self.runtime)
                self.assertEqual(read_owner(self.home), owner)
                if drift == 'target': self.assertEqual(self.target.read_text(), 'later local edit')

    def test_stale_and_edited_plan_never_overwrite_newer_content(self):
        module = self.module()
        self.target.write_text('new local behavior')
        with self.assertRaises(Conflict):
            module.apply(self.plan, self.manifest, runtime=self.runtime)
        self.assertEqual(self.target.read_text(), 'new local behavior')
        self.plan = inspect(self.manifest, self.home)
        self.plan['conflicts'] = []
        with self.assertRaises(Conflict):
            module.apply(self.plan, self.manifest, runtime=self.runtime)

    def test_activation_failure_keeps_guard_and_restores_from_intent(self):
        module = self.module()
        def partial(generation):
            self.runtime.activate_original(generation)
            raise InterruptedError('signal during activation')
        self.runtime.activate_original = self.runtime.activate
        with patch.object(self.runtime, 'activate', side_effect=partial):
            with self.assertRaises(InterruptedError):
                module.apply(self.plan, self.manifest, runtime=self.runtime)
        self.assertEqual(read_owner(self.home)['phase'], 'transferring')
        journal = json.loads((Path(self.plan['journalPath']) / 'journal.json').read_text())
        self.assertEqual(journal['steps']['activate'], 'intent')
        module.restore_legacy(self.home, self.plan['transactionId'], runtime=self.runtime)
        self.assertEqual(self.target.read_text(), 'reviewed configuration\n')
        self.assertFalse(self.target.is_symlink())

    def test_modified_deployed_file_is_archived_on_reversal(self):
        module = self.module()
        module.apply(self.plan, self.manifest, runtime=self.runtime)
        self.target.unlink()
        self.target.write_text('post migration edit')
        module.restore_legacy(self.home, self.plan['transactionId'], runtime=self.runtime)
        edits = Path(self.plan['journalPath']) / 'post-migration' / self.target.relative_to(self.home)
        self.assertEqual(edits.read_text(), 'post migration edit')
        self.assertEqual(self.target.read_text(), 'reviewed configuration\n')

    def test_every_write_ahead_boundary_retains_recoverable_originals(self):
        module = self.module()
        # Inject after each real action but before its completion journal write.
        for boundary in ['publish-transferring', 'retain-generation', 'stop-services', 'archive-0', 'activate', 'verify', 'publish-active']:
            with self.subTest(boundary=boundary):
                self.setUp()
                original = module.Journal.step
                def interrupted(journal, name, action):
                    if name != boundary:
                        return original(journal, name, action)
                    def fail_after():
                        action()
                        raise InterruptedError(boundary)
                    return original(journal, name, fail_after)
                with patch.object(module.Journal, 'step', interrupted):
                    with self.assertRaises(InterruptedError):
                        module.apply(self.plan, self.manifest, runtime=self.runtime)
                self.assertIsNotNone(read_owner(self.home))
                module.restore_legacy(self.home, self.plan['transactionId'], runtime=self.runtime)
                self.assertEqual(self.target.read_text(), 'reviewed configuration\n')
                self.assertIsNone(read_owner(self.home))

    def test_original_archive_is_retained_after_reversal(self):
        module = self.module()
        module.apply(self.plan, self.manifest, runtime=self.runtime)
        module.restore_legacy(self.home, self.plan['transactionId'], runtime=self.runtime)
        self.assertEqual(Path(self.plan['files'][0]['backupPath']).read_text(), 'reviewed configuration\n')

    def test_generation_rollback_keeps_ownership_and_rejects_unknown_generation(self):
        module = self.module()
        module.apply(self.plan, self.manifest, runtime=self.runtime)
        self.assertTrue(hasattr(module, 'rollback'), 'generation rollback missing')
        module.rollback(self.home, str(self.generation), runtime=self.runtime)
        self.assertEqual(read_owner(self.home)['phase'], 'home-manager')
        with self.assertRaises(Conflict):
            module.rollback(self.home, '/nix/store/unknown-generation', runtime=self.runtime)

    def test_second_reviewed_generation_can_rollback_then_reverse_initial_handoff(self):
        module = self.module()
        module.apply(self.plan, self.manifest, runtime=self.runtime)
        second = dict(self.manifest, activationPackage='/nix/store/11111111111111111111111111111111-fixture-generation')
        from migration.model import fingerprint
        previous = importlib.import_module('migration.plan').fingerprint
        with patch('migration.plan.fingerprint', side_effect=lambda path: {'type':'directory','mode':0o555,'uid':os.getuid(),'gid':os.getgid(),'entries':{}} if str(path)==second['activationPackage'] else previous(path)):
            plan = inspect(second, self.home)
            self.assertEqual(plan['conflicts'], [])
            module.apply(plan, second, runtime=self.runtime)
        module.rollback(self.home, str(self.generation), runtime=self.runtime)
        self.assertEqual(read_owner(self.home)['selectedGeneration'],str(self.generation))
        module.restore_legacy(self.home, self.plan['transactionId'], runtime=self.runtime)
        self.assertIsNone(read_owner(self.home))
        self.assertFalse(self.target.is_symlink())
        self.assertEqual(self.target.read_text(),'reviewed configuration\n')

    @unittest.skipUnless(sys.platform.startswith('linux'), 'Linux process group evidence')
    def test_interruption_stops_activation_descendants_before_recovery(self):
        import signal, time
        module = self.module()
        runtime = module.Runtime(self.home)
        pidfile = self.root / 'descendant.pid'
        code = "import subprocess,time,pathlib; p=subprocess.Popen(['" + sys.executable + "','-c','import time; time.sleep(20)']); pathlib.Path(" + repr(str(pidfile)) + ").write_text(str(p.pid)); time.sleep(20)"
        def interrupt(number, frame): raise InterruptedError('fixture signal')
        previous = signal.signal(signal.SIGALRM, interrupt)
        signal.setitimer(signal.ITIMER_REAL, 0.3)
        try:
            with self.assertRaises(InterruptedError):
                runtime.run([sys.executable, '-c', code])
        finally:
            signal.setitimer(signal.ITIMER_REAL, 0)
            signal.signal(signal.SIGALRM, previous)
        pid = int(pidfile.read_text())
        time.sleep(0.1)
        status = Path('/proc') / str(pid) / 'stat'
        active = status.exists() and status.read_text().split()[2] != 'Z'
        if active:
            os.kill(pid, signal.SIGKILL)  # exact fixture-owned descendant only
        self.assertFalse(active, 'activation descendant survives interrupted parent')

    def test_explicit_recovery_reclaims_only_proven_dead_python_lock(self):
        import subprocess
        module = self.module()
        module.apply(self.plan, self.manifest, runtime=self.runtime)
        code = "import sys,os; sys.path.insert(0," + repr(str(ROOT/'nix')) + "); from migration.model import HomeLock; lock=HomeLock(" + repr(str(self.home)) + ",allow_owner=True); lock.__enter__(); os._exit(9)"
        result = subprocess.run([sys.executable,'-B','-c',code])
        self.assertEqual(result.returncode,9)
        self.assertTrue((self.home/'.local/state/dotfiles-ownership/lock').is_dir())
        module.restore_legacy(self.home,self.plan['transactionId'],runtime=self.runtime)
        self.assertIsNone(read_owner(self.home))

    def test_symlinked_journal_is_rejected_before_recovery(self):
        module = self.module()
        module.apply(self.plan, self.manifest, runtime=self.runtime)
        journal = Path(self.plan['journalPath']) / 'journal.json'
        saved = journal.with_name('saved.json')
        journal.rename(saved)
        journal.symlink_to(saved)
        with self.assertRaises(Conflict):
            module.restore_legacy(self.home, self.plan['transactionId'], runtime=self.runtime)
        self.assertTrue(self.target.is_symlink())

    def test_recovery_retry_preserves_edits_after_completed_file_restoration(self):
        module = self.module()
        module.apply(self.plan, self.manifest, runtime=self.runtime)
        with patch.object(module.Services, 'restore', side_effect=Conflict('partial manager restore')):
            with self.assertRaises(Conflict):
                module.restore_legacy(self.home, self.plan['transactionId'])
        self.target.write_text('edit between recovery attempts\n')
        module.restore_legacy(self.home, self.plan['transactionId'])
        self.assertEqual(self.target.read_text(), 'reviewed configuration\n')
        archives = Path(self.plan['journalPath']).rglob('*')
        self.assertTrue(any(p.is_file() and not p.is_symlink() and p.read_bytes() == b'edit between recovery attempts\n' for p in archives))

    def test_profile_recovery_does_not_require_same_filesystem_as_journal(self):
        import errno
        module = self.module()
        profile = self.home / '.nix-profile'
        self.manifest['profilePaths'] = [str(profile)]
        self.plan = inspect(self.manifest, self.home)
        activate = self.runtime.activate
        def activate_profile(generation):
            activate(generation)
            profile.symlink_to(generation)
        with patch.object(self.runtime, 'activate', side_effect=activate_profile):
            module.apply(self.plan, self.manifest, runtime=self.runtime)
        rename = Path.rename
        def cross_device(path, destination):
            if path == profile:
                raise OSError(errno.EXDEV, 'fixture profile and journal filesystems differ')
            return rename(path, destination)
        with patch.object(Path, 'rename', cross_device):
            module.restore_legacy(self.home, self.plan['transactionId'])
        self.assertFalse(profile.is_symlink())
        self.assertEqual(os.readlink(Path(self.plan['journalPath']) / 'profiles-after/0'), str(self.generation))

    def test_nested_taplo_snapshot_corruption_blocks_recovery_without_touching_other_versions(self):
        module = self.module()
        architecture = self.manifest['system'].split('-')[0]
        old = self.home / ('.local/opt/taplo-0.10.0-' + architecture)
        (old / 'bin').mkdir(parents=True)
        (old / 'bin/taplo').write_text('old binary')
        unrelated = self.home / '.local/opt/taplo-other'
        unrelated.mkdir()
        (unrelated / 'keep').write_text('unrelated')
        link = self.home / '.local/bin/taplo'
        link.parent.mkdir()
        link.symlink_to(old / 'bin/taplo')
        self.plan = inspect(self.manifest, self.home)
        module.apply(self.plan, self.manifest, runtime=self.runtime)
        self.assertEqual((unrelated / 'keep').read_text(), 'unrelated')
        backup = Path(self.plan['originalsRoot']) / old.relative_to(self.home)
        (backup / 'bin/taplo').write_text('corrupted retained binary')
        with self.assertRaises(Conflict):
            module.restore_legacy(self.home, self.plan['transactionId'])
        self.assertIsNotNone(read_owner(self.home))
        self.assertFalse(old.exists())

    def test_recovery_refuses_replaced_parent_without_archiving_foreign_files(self):
        module = self.module()
        module.apply(self.plan, self.manifest, runtime=self.runtime)
        foreign = self.root / 'foreign'
        foreign.mkdir()
        protected = foreign / self.target.name
        protected.write_text('outside home')
        self.target.parent.rename(self.target.parent.with_name('retained-ghostty'))
        self.target.parent.symlink_to(foreign)
        with self.assertRaises(Conflict):
            module.restore_legacy(self.home,self.plan['transactionId'])
        self.assertEqual(protected.read_text(),'outside home')
        self.assertIsNotNone(read_owner(self.home))

    def test_recovery_retry_restarts_services_after_completed_restore_was_interrupted(self):
        module = self.module()
        active = {'value':True}
        module.apply(self.plan,self.manifest,runtime=self.runtime)
        save = module.Journal.save
        def interrupted(journal):
            save(journal)
            if journal.data['phase'] == 'restoring' and journal.data['steps'].get('restore-services') == 'complete':
                raise InterruptedError('after durable service completion')
        with patch.object(module.Services,'stop',side_effect=lambda:active.update(value=False)), patch.object(module.Services,'restore',side_effect=lambda before:active.update(value=True)):
            with patch.object(module.Journal,'save',interrupted), self.assertRaises(InterruptedError):
                module.restore_legacy(self.home,self.plan['transactionId'])
            self.assertTrue(active['value'])
            module.restore_legacy(self.home,self.plan['transactionId'])
            self.assertTrue(active['value'])
        self.assertIsNone(read_owner(self.home))

    def test_edited_journal_cannot_redirect_a_record_to_an_unrelated_home_file(self):
        module = self.module()
        protected = self.home / '.cfg/retained'
        protected.parent.mkdir()
        protected.write_text('repository evidence')
        self.plan = inspect(self.manifest,self.home)
        module.apply(self.plan,self.manifest,runtime=self.runtime)
        path = Path(self.plan['journalPath']) / 'journal.json'
        journal = json.loads(path.read_text())
        journal['records'][0]['path'] = str(protected)
        path.write_text(json.dumps(journal))
        with self.assertRaises(Conflict):
            module.restore_legacy(self.home,self.plan['transactionId'])
        self.assertEqual(protected.read_text(),'repository evidence')
        self.assertTrue(self.target.is_symlink())

    def test_reversal_archives_created_numbered_profile_links_and_allows_new_preview(self):
        module = self.module()
        profiles = self.home / '.local/state/nix/profiles'
        profiles.mkdir(parents=True)
        (profiles/'unrelated').write_text('keep')
        self.manifest['profilePaths'] = [str(profiles),str(profiles/'home-manager')]
        self.plan = inspect(self.manifest,self.home)
        activate = self.runtime.activate
        def activate_profile(generation):
            activate(generation)
            (profiles/'home-manager-1-link').symlink_to(generation)
            (profiles/'home-manager').symlink_to('home-manager-1-link')
        with patch.object(self.runtime,'activate',side_effect=activate_profile):
            module.apply(self.plan,self.manifest,runtime=self.runtime)
        module.restore_legacy(self.home,self.plan['transactionId'])
        self.assertEqual(inspect(self.manifest,self.home)['conflicts'],[])
        self.assertEqual((profiles/'unrelated').read_text(),'keep')
        self.assertTrue(any(p.is_symlink() and os.readlink(p)==str(self.generation) for p in Path(self.plan['journalPath']).rglob('*')))

    def test_failed_rollback_requires_explicit_retry_not_old_apply_success(self):
        module = self.module()
        module.apply(self.plan,self.manifest,runtime=self.runtime)
        with patch.object(self.runtime,'activate',side_effect=InterruptedError('rollback activation')):
            with self.assertRaises(InterruptedError):
                module.rollback(self.home,str(self.generation),runtime=self.runtime)
        with self.assertRaises(Conflict):
            module.apply(self.plan,self.manifest,runtime=self.runtime)
        self.assertEqual(read_owner(self.home)['phase'],'transferring')
        module.rollback(self.home,str(self.generation),runtime=self.runtime)
        self.assertEqual(read_owner(self.home)['phase'],'home-manager')

    def test_apply_retry_revalidates_completed_verification_and_preserves_edits(self):
        module = self.module()
        for boundary in ['before-publication', 'after-publication', 'active-repeat']:
            with self.subTest(boundary=boundary):
                self.setUp()
                original = module.Journal.step
                def interrupted(journal, name, action):
                    if name == 'publish-active' and boundary == 'before-publication':
                        raise InterruptedError(boundary)
                    result = original(journal, name, action)
                    if name == 'publish-active' and boundary == 'after-publication':
                        raise InterruptedError(boundary)
                    return result
                # Use real deployed-file verification; only generation activation is substituted.
                with patch.object(self.runtime, 'verify', side_effect=lambda manifest: module.verify_deployed_files(manifest, self.home)):
                    if boundary == 'active-repeat':
                        module.apply(self.plan, self.manifest, runtime=self.runtime)
                    else:
                        with patch.object(module.Journal, 'step', interrupted):
                            with self.assertRaises(InterruptedError):
                                module.apply(self.plan, self.manifest, runtime=self.runtime)
                    self.target.unlink()
                    self.target.write_text('edit after interrupted verification')
                    with self.assertRaises(Conflict):
                        module.apply(self.plan, self.manifest, runtime=self.runtime)
                    self.assertEqual(self.target.read_text(), 'edit after interrupted verification')
                    self.assertIsNotNone(read_owner(self.home))
                    self.assertEqual(len(self.runtime.calls), 1)
                module.restore_legacy(self.home, self.plan['transactionId'], runtime=self.runtime)
                retained = Path(self.plan['journalPath']) / 'post-migration' / self.target.relative_to(self.home)
                self.assertEqual(retained.read_text(), 'edit after interrupted verification')

    def test_apply_retry_stops_restarted_service_before_remaining_mutations(self):
        module = self.module()
        original = module.Journal.step
        def interrupted(journal, name, action):
            result = original(journal, name, action)
            if name == 'stop-services':
                raise InterruptedError('after successful stop was journaled')
            return result
        with patch.object(module.Journal, 'step', interrupted):
            with self.assertRaises(InterruptedError):
                module.apply(self.plan, self.manifest, runtime=self.runtime)
        # A restarted external manager refuses its next stop: no archive/activation is safe.
        with patch.object(module.Services, 'stop', side_effect=Conflict('restarted service cannot stop')):
            with self.assertRaises(Conflict):
                module.apply(self.plan, self.manifest, runtime=self.runtime)
        self.assertFalse(self.target.is_symlink())
        self.assertEqual(self.target.read_text(), 'reviewed configuration\n')
        self.assertFalse(Path(self.plan['files'][0]['backupPath']).exists())
        self.assertEqual(self.runtime.calls, [])
        self.assertEqual(read_owner(self.home)['phase'], 'transferring')

    def test_partial_activation_retry_does_not_overwrite_an_edited_owned_copy(self):
        module = self.module()
        self.manifest['files'][0].update(deployment='owned-copy', mode='0444')
        self.plan = inspect(self.manifest, self.home)
        def activate(generation):
            self.target.write_bytes(self.source.read_bytes())
            self.target.chmod(0o444)
        def interrupted(generation):
            activate(generation)
            raise InterruptedError('partial owned-copy activation')
        with patch.object(self.runtime, 'activate', side_effect=interrupted):
            with self.assertRaises(InterruptedError):
                module.apply(self.plan, self.manifest, runtime=self.runtime)
        self.target.chmod(0o600)
        self.target.write_text('new user copy contents')
        with patch.object(self.runtime, 'activate', side_effect=activate), patch.object(self.runtime, 'verify', side_effect=lambda manifest: module.verify_deployed_files(manifest, self.home)):
            with self.assertRaises(Conflict):
                module.apply(self.plan, self.manifest, runtime=self.runtime)
        self.assertEqual(self.target.read_text(), 'new user copy contents')
        self.assertEqual(read_owner(self.home)['phase'], 'transferring')

    def test_partial_activation_retry_preserves_unreviewed_package_profile(self):
        module = self.module()
        profile = self.home / '.local/state/nix/profiles/profile'
        profile.parent.mkdir(parents=True)
        self.manifest['profilePaths'] = [str(profile)]
        self.plan = inspect(self.manifest, self.home)
        activate_original = self.runtime.activate
        def activate(generation):
            activate_original(generation)
            if profile.is_symlink(): profile.unlink()
            profile.symlink_to(str(self.generation / 'home-path'))
        def interrupted(generation):
            activate(generation)
            raise InterruptedError('partial profile selection')
        with patch.object(self.runtime, 'activate', side_effect=interrupted):
            with self.assertRaises(InterruptedError):
                module.apply(self.plan, self.manifest, runtime=self.runtime)
        profile.unlink()
        profile.symlink_to('/nix/store/unreviewed-native-package-profile')
        with patch.object(self.runtime, 'activate', side_effect=activate):
            with self.assertRaises(Conflict):
                module.apply(self.plan, self.manifest, runtime=self.runtime)
        self.assertEqual(os.readlink(profile), '/nix/store/unreviewed-native-package-profile')
        self.assertEqual(read_owner(self.home)['phase'], 'transferring')

    def test_partial_activation_retry_accepts_unchanged_reviewed_outputs(self):
        module = self.module()
        activate = self.runtime.activate
        def interrupted(generation):
            activate(generation)
            raise InterruptedError('after selected links were installed')
        with patch.object(self.runtime, 'activate', side_effect=interrupted):
            with self.assertRaises(InterruptedError):
                module.apply(self.plan, self.manifest, runtime=self.runtime)
        module.apply(self.plan, self.manifest, runtime=self.runtime)
        self.assertEqual(read_owner(self.home)['phase'], 'home-manager')
        self.assertEqual(self.target.resolve(), self.source.resolve())
        self.assertEqual(len(self.runtime.calls), 2)

    def test_recovery_rejects_replaced_profile_parent_on_first_attempt_and_retry(self):
        module = self.module()
        for retry in [False, True]:
            with self.subTest(retry=retry):
                self.setUp()
                parent = self.home / '.local/state/home-manager/gcroots'
                parent.mkdir(parents=True)
                pointer = parent / 'current-home'
                self.manifest['profilePaths'] = [str(pointer)]
                self.plan = inspect(self.manifest, self.home)
                activate = self.runtime.activate
                def activate_profile(generation):
                    activate(generation)
                    pointer.symlink_to(generation)
                with patch.object(self.runtime, 'activate', side_effect=activate_profile):
                    module.apply(self.plan, self.manifest, runtime=self.runtime)
                if retry:
                    with patch.object(module.Services, 'restore', side_effect=Conflict('interrupted restoration')), self.assertRaises(Conflict):
                        module.restore_legacy(self.home, self.plan['transactionId'])
                parent.rename(parent.with_name('gcroots-retained'))
                foreign = self.root / 'foreign'
                foreign.mkdir()
                leaf = foreign / 'current-home'
                leaf.symlink_to('foreign-retained-target')
                parent.symlink_to(foreign, target_is_directory=True)
                with self.assertRaises(Conflict):
                    module.restore_legacy(self.home, self.plan['transactionId'])
                self.assertEqual(os.readlink(leaf), 'foreign-retained-target')
                self.assertIsNotNone(read_owner(self.home))

    def test_recovery_rejects_unsafe_profile_directory_before_inventory(self):
        module = self.module()
        profiles = self.home / '.local/state/nix/profiles'
        profiles.mkdir(parents=True)
        self.manifest['profilePaths'] = [str(profiles), str(profiles / 'home-manager')]
        self.plan = inspect(self.manifest, self.home)
        module.apply(self.plan, self.manifest, runtime=self.runtime)
        profiles.parent.rename(profiles.parent.with_name('nix-retained'))
        foreign = self.root / 'foreign'
        (foreign / 'profiles').mkdir(parents=True)
        link = foreign / 'profiles/home-manager-1-link'
        link.symlink_to(self.generation)
        profiles.parent.symlink_to(foreign, target_is_directory=True)
        observed = []
        original = module.leaf_state
        def observe(path):
            if Path(path) == profiles:
                observed.append(str(path))
            return original(path)
        with patch.object(module, 'leaf_state', side_effect=observe), self.assertRaises(Conflict):
            module.restore_legacy(self.home, self.plan['transactionId'])
        self.assertEqual(observed, [], 'foreign profile directory was inspected before parent validation')
        self.assertEqual(os.readlink(link), str(self.generation))
        self.assertIsNotNone(read_owner(self.home))

    def test_recovery_accepts_missing_profile_parents_and_external_profile_roots(self):
        module = self.module()
        external = self.root / 'external-profile-root'
        external.mkdir()
        (external / 'retained-native-profile').mkdir()
        profile = external / '.nix-profile'
        profile.symlink_to('retained-native-profile')
        missing = self.home / '.local/state/home-manager/gcroots/current-home'
        self.manifest['profilePaths'] = [str(profile), str(missing)]
        self.plan = inspect(self.manifest, self.home)
        module.apply(self.plan, self.manifest, runtime=self.runtime)
        module.restore_legacy(self.home, self.plan['transactionId'])
        self.assertEqual(os.readlink(profile), 'retained-native-profile')
        self.assertFalse(missing.parent.exists())
        self.assertIsNone(read_owner(self.home))

    def test_rollback_refuses_incomplete_initial_archival(self):
        module = self.module()
        original = module.Journal.step
        def interrupted(journal, name, action):
            if name.startswith('archive-'):
                raise InterruptedError('before original archival')
            return original(journal, name, action)
        with patch.object(module.Journal, 'step', interrupted), self.assertRaises(InterruptedError):
            module.apply(self.plan, self.manifest, runtime=self.runtime)
        with patch.object(self.runtime, 'activate') as activate, patch.object(self.runtime, 'verify'):
            with self.assertRaises(Conflict):
                module.rollback(self.home, str(self.generation), runtime=self.runtime)
            activate.assert_not_called()
        self.assertEqual(self.target.read_text(), 'reviewed configuration\n')
        self.assertFalse(Path(self.plan['files'][0]['backupPath']).exists())
        self.assertEqual(read_owner(self.home)['phase'], 'transferring')

    def test_rollback_refuses_replaced_owned_and_profile_parents(self):
        module = self.module()
        for kind in ['owned', 'profile']:
            with self.subTest(kind=kind):
                self.setUp()
                profile = self.home / '.local/state/home-manager/gcroots/current-home'
                profile.parent.mkdir(parents=True)
                self.manifest['profilePaths'] = [str(profile)]
                self.plan = inspect(self.manifest, self.home)
                module.apply(self.plan, self.manifest, runtime=self.runtime)
                parent = self.target.parent if kind == 'owned' else profile.parent
                leaf_name = self.target.name if kind == 'owned' else profile.name
                parent.rename(parent.with_name(parent.name + '-retained'))
                foreign = self.root / 'foreign'
                foreign.mkdir()
                leaf = foreign / leaf_name
                leaf.symlink_to('foreign-retained-target')
                parent.symlink_to(foreign, target_is_directory=True)
                with patch.object(self.runtime, 'activate', wraps=self.runtime.activate) as activate:
                    with self.assertRaises(Conflict):
                        module.rollback(self.home, str(self.generation), runtime=self.runtime)
                    activate.assert_not_called()
                self.assertEqual(os.readlink(leaf), 'foreign-retained-target')
                self.assertIsNotNone(read_owner(self.home))

    def test_rollback_preserves_modified_owned_copy_and_unknown_profile(self):
        module = self.module()
        for kind in ['copy', 'profile']:
            with self.subTest(kind=kind):
                self.setUp()
                profile = self.home / '.local/state/nix/profiles/profile'
                profile.parent.mkdir(parents=True)
                self.manifest['profilePaths'] = [str(profile)]
                self.manifest['files'][0].update(deployment='owned-copy', mode='0444')
                self.plan = inspect(self.manifest, self.home)
                def activate(generation):
                    self.runtime.calls.append(generation)
                    if self.target.exists():
                        self.target.unlink()
                    self.target.write_bytes(self.source.read_bytes())
                    self.target.chmod(0o444)
                with patch.object(self.runtime, 'activate', side_effect=activate), patch.object(self.runtime, 'verify', side_effect=lambda manifest: module.verify_deployed_files(manifest, self.home)):
                    module.apply(self.plan, self.manifest, runtime=self.runtime)
                    if kind == 'copy':
                        self.target.chmod(0o600)
                        self.target.write_text('new local copy contents')
                    else:
                        profile.symlink_to('/nix/store/unreviewed-native-package-profile')
                    with self.assertRaises(Conflict):
                        module.rollback(self.home, str(self.generation), runtime=self.runtime)
                    self.assertEqual(len(self.runtime.calls), 1)
                if kind == 'copy':
                    self.assertEqual(self.target.read_text(), 'new local copy contents')
                else:
                    self.assertEqual(os.readlink(profile), '/nix/store/unreviewed-native-package-profile')
                self.assertIsNotNone(read_owner(self.home))

    def test_selected_generation_drift_blocks_publication_and_active_repeat(self):
        module = self.module()
        for boundary in ['publication', 'active-repeat']:
            with self.subTest(boundary=boundary):
                self.setUp()
                profile = self.home / '.local/state/nix/profiles/home-manager'
                profile.parent.mkdir(parents=True)
                self.plan = inspect(self.manifest, self.home)
                if boundary == 'active-repeat':
                    module.apply(self.plan, self.manifest, runtime=self.runtime)
                profile.symlink_to('/nix/store/11111111111111111111111111111111-unreviewed-generation')
                with patch.object(self.runtime, 'verify', side_effect=module.Runtime(self.home).verify):
                    with self.assertRaises(Conflict):
                        module.apply(self.plan, self.manifest, runtime=self.runtime)
                self.assertIsNotNone(read_owner(self.home))
                if boundary == 'publication':
                    self.assertEqual(read_owner(self.home)['phase'], 'transferring')

    def test_package_profile_queries_use_selected_active_entries_and_preserve_native_packages(self):
        module = self.module()
        expected = '/nix/store/' + 'a' * 32 + '-home-manager-path'
        stale = '/nix/store/' + 'b' * 32 + '-home-manager-path'
        native = '/nix/store/' + 'c' * 32 + '-weston'
        for modern in [False, True]:
            with self.subTest(modern=modern):
                def payload(home):
                    if modern:
                        return {'version': 3, 'elements': {'home-manager-path': {'active': True, 'priority': 5, 'storePaths': [home]}, 'weston': {'active': True, 'priority': 5, 'storePaths': [native]}}}
                    return {'0': {'name': 'home-manager-path', 'outputs': {'out': home}}, '1': {'name': 'weston', 'outputs': {'out': native}}}
                entries = module.profile_entries(payload(expected), modern)
                retained = module.native_entries(entries)
                module.check_package_selection(entries, retained, {expected})
                with self.assertRaises(Conflict):
                    module.check_package_selection(module.profile_entries(payload(stale), modern), retained, {expected})
                with self.assertRaises(Conflict):
                    module.check_package_selection([entry for entry in entries if entry not in retained], retained, {expected})
                if modern:
                    inactive = payload(expected)
                    inactive['elements']['home-manager-path']['active'] = False
                    with self.assertRaises(Conflict):
                        module.check_package_selection(module.profile_entries(inactive, True), retained, {expected})
        with self.assertRaises(Conflict):
            module.profile_entries({'version': 3, 'elements': {'bad': {'active': True, 'storePaths': ['/tmp/not-a-store-output']}}}, True)

    def test_rollback_refuses_missing_or_reverted_selected_hm_pointer(self):
        module = self.module()
        for selected in [None, '/nix/store/' + 'b' * 32 + '-old-generation']:
            with self.subTest(selected=selected):
                self.setUp()
                module.apply(self.plan, self.manifest, runtime=self.runtime)
                with patch.object(self.runtime, 'selected_generation', return_value=selected, create=True):
                    with self.assertRaises(Conflict):
                        module.rollback(self.home, str(self.generation), runtime=self.runtime)
                self.assertEqual(len(self.runtime.calls), 1)

    def test_interrupted_rollback_accepts_reviewed_union_and_refuses_unknown_leaf(self):
        module = self.module()
        extra = self.home / '.config/extra'
        extra.symlink_to(self.source)
        newer = dict(self.manifest, files=self.manifest['files'] + [dict(target='.config/extra', source=str(self.source), executable=False)])
        self.target.unlink()
        self.target.symlink_to(self.source)
        module.verify_deployed_files(newer, self.home, alternatives=[self.manifest], allow_absent=True)
        extra.unlink()
        extra.write_text('unreviewed edit')
        with self.assertRaises(Conflict):
            module.verify_deployed_files(self.manifest, self.home, alternatives=[newer], allow_absent=True)

    def test_recovery_preserves_changed_original_numbered_profile_and_keeps_guard(self):
        module = self.module()
        profiles = self.home / '.local/state/nix/profiles'
        profiles.mkdir(parents=True)
        original = self.root / 'original-native-environment'
        original.mkdir()
        changed = self.root / 'changed-native-environment'
        changed.mkdir()
        numbered = profiles / 'profile-1-link'
        numbered.symlink_to(original)
        pointer = profiles / 'profile'
        pointer.symlink_to(numbered.name)
        self.manifest['profilePaths'] = [str(profiles), str(pointer)]
        self.plan = inspect(self.manifest, self.home)
        module.apply(self.plan, self.manifest, runtime=self.runtime)
        numbered.unlink()
        numbered.symlink_to(changed)
        with self.assertRaises(Conflict):
            module.restore_legacy(self.home, self.plan['transactionId'], runtime=self.runtime)
        self.assertEqual(numbered.resolve(), changed)
        self.assertIsNotNone(read_owner(self.home))

    def test_rollback_retry_accepts_partial_reviewed_selection_and_rechecks_publication(self):
        module = self.module()
        for boundary in ['activate', 'publish']:
            with self.subTest(boundary=boundary):
                self.setUp()
                module.apply(self.plan, self.manifest, runtime=self.runtime)
                second = dict(self.manifest, activationPackage='/nix/store/' + '1' * 32 + '-fixture-generation')
                previous = importlib.import_module('migration.plan').fingerprint
                with patch('migration.plan.fingerprint', side_effect=lambda path: {'type':'directory','mode':0o555,'uid':os.getuid(),'gid':os.getgid(),'entries':{}} if str(path)==second['activationPackage'] else previous(path)):
                    plan = inspect(second, self.home)
                    module.apply(plan, second, runtime=self.runtime)
                activate = self.runtime.activate
                owner = module.Journal.owner
                def interrupted(generation):
                    activate(generation)
                    raise InterruptedError('partial reviewed rollback')
                def publish(journal, phase, generation=None):
                    if phase == 'home-manager':
                        raise InterruptedError('before ownership publication')
                    return owner(journal, phase, generation)
                context = patch.object(self.runtime, 'activate', side_effect=interrupted) if boundary == 'activate' else patch.object(module.Journal, 'owner', new=publish)
                with context, self.assertRaises(InterruptedError):
                    module.rollback(self.home, str(self.generation), runtime=self.runtime)
                calls = len(self.runtime.calls)
                module.rollback(self.home, str(self.generation), runtime=self.runtime)
                self.assertEqual(read_owner(self.home)['selectedGeneration'], str(self.generation))
                self.assertEqual(len(self.runtime.calls), calls + (boundary == 'activate'))

    def test_reversal_archives_reviewed_mixed_package_generation_but_preserves_native_generation(self):
        module = self.module()
        profiles = self.home / '.local/state/nix/profiles'
        profiles.mkdir(parents=True)
        self.manifest['profilePaths'] = [str(profiles)]
        self.plan = inspect(self.manifest, self.home)
        module.apply(self.plan, self.manifest, runtime=self.runtime)
        mixed = profiles / 'profile-1-link'
        unrelated = profiles / 'profile-2-link'
        mixed.symlink_to('/nix/store/' + 'a' * 32 + '-user-environment')
        unrelated.symlink_to('/nix/store/' + 'b' * 32 + '-user-environment')
        selected = self.runtime.profile_packages(self.home / '.nix-profile')
        def packages(path):
            return selected if Path(path) == mixed else [{'name': 'native', 'paths': ['/nix/store/' + 'c' * 32 + '-native'], 'active': True, 'priority': None}]
        with patch.object(self.runtime, 'profile_packages', side_effect=packages):
            module.restore_legacy(self.home, self.plan['transactionId'], runtime=self.runtime)
        self.assertFalse(mixed.is_symlink())
        self.assertTrue(unrelated.is_symlink())
        self.assertIsNone(read_owner(self.home))

    def test_profile_query_malformed_schemas_fail_closed(self):
        module = self.module()
        for modern, payload in [(False, []), (False, {'0': {'name': 'native', 'outputs': {}}}), (True, {'version': 2, 'elements': {}}), (True, {'version': 3, 'elements': []}), (True, {'version': 3, 'elements': {'native': {'active': 1, 'priority': 5, 'storePaths': ['/nix/store/' + 'a'*32 + '-native']}}})]:
            with self.subTest(modern=modern, payload=payload), self.assertRaises(Conflict):
                module.profile_entries(payload, modern)

    def test_new_generation_target_set_changes_require_explicit_reversal(self):
        module = self.module()
        module.apply(self.plan, self.manifest, runtime=self.runtime)
        for files in [[], self.manifest['files'] + [dict(target='.config/extra', source=str(self.source), executable=False)]]:
            changed = dict(self.manifest, files=files)
            plan = inspect(changed, self.home)
            self.assertIn('changed-managed-targets', [item['code'] for item in plan['conflicts']])
            with self.assertRaises(Conflict):
                module.apply(plan, changed, runtime=self.runtime)
            self.assertEqual(len(self.runtime.calls), 1)

    def test_competing_dead_lock_reclaimers_never_enter_two_protected_regions(self):
        import subprocess
        from migration.model import HomeLock
        code = "import sys,os; sys.path.insert(0," + repr(str(ROOT/'nix')) + "); from migration.model import HomeLock; HomeLock(" + repr(str(self.home)) + ",allow_owner=True).__enter__(); os._exit(9)"
        self.assertEqual(subprocess.run([sys.executable, '-B', '-c', code]).returncode, 9)
        slow = HomeLock(self.home, allow_owner=True, recover=True)
        fast = HomeLock(self.home, allow_owner=True, recover=True)
        original = Path.iterdir
        entered = []
        scheduled = False
        def interleave(path):
            nonlocal scheduled
            if path == slow.path and not scheduled:
                scheduled = True
                try:
                    fast.__enter__()
                    entered.append(fast)
                except Conflict:
                    pass
            return original(path)
        try:
            with patch.object(Path, 'iterdir', interleave):
                slow.__enter__()
                entered.append(slow)
            self.assertTrue(scheduled)
            self.assertEqual(len(entered), 1, 'two reclaimers entered the protected region')
            entered[0].recheck()
        finally:
            for lock in reversed(entered):
                try: lock.__exit__(None, None, None)
                except Conflict: pass

    def test_recovery_lock_arbitration_preserves_live_and_unknown_legacy_locks(self):
        from migration.model import HomeLock, fingerprint
        with HomeLock(self.home, allow_owner=True) as live:
            before = fingerprint(live.holder)
            with self.assertRaises(Conflict):
                with HomeLock(self.home, allow_owner=True, recover=True):
                    self.fail('entered a live protected region')
            live.recheck()
            self.assertEqual(fingerprint(live.holder), before)
        legacy = self.home / '.local/state/dotfiles-ownership/lock'
        legacy.mkdir(mode=0o700)
        identity = legacy.stat().st_ino
        with self.assertRaises(Conflict):
            with HomeLock(self.home, allow_owner=True, recover=True):
                self.fail('claimed unknown legacy lock')
        self.assertEqual(legacy.stat().st_ino, identity)
        self.assertEqual(list(legacy.iterdir()), [])

    def test_resumed_apply_reobserves_native_claims_before_work_and_publication(self):
        from migration.model import fingerprint
        module = self.module()
        for boundary in ['stop-services', 'activate', 'verify', 'publish-active']:
            for drift in [False, True]:
                with self.subTest(boundary=boundary, drift=drift):
                    self.setUp()
                    provider = self.root / 'native-provider'
                    provider.write_text('available')
                    self.manifest['nativeDependencies'] = [{'id': 'notebook-uv-project'}]
                    observations = []
                    def collector(manifest, home):
                        observations.append(provider.read_text())
                        return [{'id': 'notebook-uv-project', 'status': 'observed' if provider.read_text() == 'available' else 'unverified',
                                 'observations': {str(provider): fingerprint(provider), str(self.target): fingerprint(self.target)}, 'queries': []}]
                    step = module.Journal.step
                    def interrupted(journal, name, action):
                        value = step(journal, name, action)
                        if name == boundary:
                            raise InterruptedError('native retry boundary')
                        return value
                    with patch('migration.prerequisites.inspect_native', side_effect=collector):
                        self.plan = inspect(self.manifest, self.home)
                        with patch.object(module.Journal, 'step', new=interrupted), self.assertRaises(InterruptedError):
                            module.apply(self.plan, self.manifest, runtime=self.runtime)
                        calls = len(self.runtime.calls)
                        observations.clear()
                        if drift:
                            provider.write_text('unavailable')
                            with self.assertRaises(Conflict):
                                module.apply(self.plan, self.manifest, runtime=self.runtime)
                            self.assertEqual(len(self.runtime.calls), calls)
                            self.assertIsNotNone(read_owner(self.home))
                            # Native refusal cannot strand explicit restoration.
                            module.restore_legacy(self.home, self.plan['transactionId'], runtime=self.runtime)
                            self.assertIsNone(read_owner(self.home))
                        else:
                            module.apply(self.plan, self.manifest, runtime=self.runtime)
                            self.assertEqual(read_owner(self.home)['phase'], 'home-manager')
                        self.assertGreater(len(observations), 0, 'retry bypassed the native collector')

    def test_delayed_reclaimer_cannot_delete_reacquired_live_lock(self):
        import subprocess
        import migration.model as model
        code = "import sys,os; sys.path.insert(0," + repr(str(ROOT/'nix')) + "); from migration.model import HomeLock; HomeLock(" + repr(str(self.home)) + ",allow_owner=True).__enter__(); os._exit(9)"
        self.assertEqual(subprocess.run([sys.executable, '-B', '-c', code]).returncode, 9)
        slow = model.HomeLock(self.home, allow_owner=True, recover=True)
        fast = model.HomeLock(self.home, allow_owner=True, recover=True)
        flock = model.fcntl.flock
        scheduled = False
        def interleave(fd, operation):
            nonlocal scheduled
            if not scheduled:
                scheduled = True
                fast.__enter__()
            return flock(fd, operation)
        try:
            with patch.object(model.fcntl, 'flock', side_effect=interleave), self.assertRaises(Conflict):
                slow.__enter__()
            fast.recheck()
            self.assertEqual(fast.path.stat().st_ino, fast.identity[1])
        finally:
            fast.__exit__(None, None, None)
        with model.HomeLock(self.home, allow_owner=True, recover=True) as subsequent:
            subsequent.recheck()

    def test_unsupported_reclaimer_arbitration_retains_abandoned_evidence(self):
        import errno, subprocess
        import migration.model as model
        code = "import sys,os; sys.path.insert(0," + repr(str(ROOT/'nix')) + "); from migration.model import HomeLock; HomeLock(" + repr(str(self.home)) + ",allow_owner=True).__enter__(); os._exit(9)"
        self.assertEqual(subprocess.run([sys.executable, '-B', '-c', code]).returncode, 9)
        reclaim = model.HomeLock(self.home, allow_owner=True, recover=True)
        holder = reclaim.holder.read_bytes()
        identity = reclaim.path.stat().st_ino
        with patch.object(model.fcntl, 'flock', side_effect=OSError(errno.ENOTSUP, 'unsupported')), self.assertRaises(Conflict):
            reclaim.__enter__()
        self.assertEqual(reclaim.holder.read_bytes(), holder)
        self.assertEqual(reclaim.path.stat().st_ino, identity)
        with model.HomeLock(self.home, allow_owner=True, recover=True) as supported:
            supported.recheck()

    def test_native_retry_reconciles_only_archived_config_route_and_rejects_stable_drift(self):
        from migration.model import fingerprint
        module = self.module()
        for drift in ['none', 'provider', 'session', 'query', 'binding', 'source']:
            with self.subTest(drift=drift):
                self.setUp()
                provider = self.root / 'ghostty'
                provider.write_text('native provider')
                provider.chmod(0o755)
                session = self.root / 'native-session'
                session.write_text('session identity')
                native_state = {'query': 'SpaceMono', 'binding': 'same'}
                self.manifest['nativeDependencies'] = [{'id': 'ghostty'}]
                def observed(path):
                    result = fingerprint(path)
                    if path.exists() or path.is_symlink():
                        info = path.lstat(); result.update(device=info.st_dev, inode=info.st_ino)
                    return result
                def collector(manifest, home):
                    config = self.target if self.target.is_file() else self.source
                    observations = {str(p): observed(p) for p in [provider, session, self.target, config]}
                    return [{'id': 'ghostty', 'status': 'observed', 'command': 'ghostty', 'selectedExecutable': str(provider), 'binding': native_state['binding'],
                             'observations': observations, 'queries': [
                                 {'command': [str(provider), '+validate-config', '--config-file='+str(config)], 'context': {}, 'status': 0, 'stdout': '', 'stderr': ''},
                                 {'command': [str(provider), '+show-config', '--changes-only'], 'context': {} if config == self.target else {'XDG_CONFIG_HOME': str(self.source.parents[1])}, 'status': 0, 'stdout': native_state['query'], 'stderr': ''}]}]
                step = module.Journal.step
                def interrupt(journal, name, action):
                    result = step(journal, name, action)
                    if name == 'archive-0': raise InterruptedError('after actual archive')
                    return result
                with patch('migration.prerequisites.inspect_native', side_effect=collector), patch.dict(os.environ, {'DOTFILES_CALLER_PATH': str(self.root)}):
                    self.plan = inspect(self.manifest, self.home)
                    with patch.object(module.Journal, 'step', new=interrupt), self.assertRaises(InterruptedError):
                        module.apply(self.plan, self.manifest, runtime=self.runtime)
                    self.assertFalse(self.target.exists())
                    if drift in ['provider', 'session', 'source']:
                        {'provider': provider, 'session': session, 'source': self.source}[drift].write_text('replaced')
                    elif drift in ['query', 'binding']:
                        native_state[drift] = 'changed'
                    if drift == 'none':
                        module.apply(self.plan, self.manifest, runtime=self.runtime)
                        self.assertEqual(read_owner(self.home)['phase'], 'home-manager')
                    else:
                        with self.assertRaises(Conflict):
                            module.apply(self.plan, self.manifest, runtime=self.runtime)
                        self.assertEqual(self.runtime.calls, [])
                        self.assertEqual(read_owner(self.home)['phase'], 'transferring')

    def test_native_publication_retry_accepts_reviewed_owned_copy_from_fresh_or_retained_home(self):
        from migration.model import fingerprint
        module = self.module()
        for fresh in [False, True]:
            for edited in [False, True]:
                with self.subTest(fresh=fresh, edited=edited):
                    self.setUp()
                    if fresh: self.target.unlink()
                    self.manifest['files'][0].update(deployment='owned-copy', mode='0444')
                    self.manifest['nativeDependencies'] = [{'id': 'notebook-uv-project'}]
                    def collector(manifest, home):
                        return [{'id': 'notebook-uv-project', 'status': 'observed', 'observations': {str(self.target): fingerprint(self.target)}, 'queries': []}]
                    def activate(generation):
                        self.runtime.calls.append(generation)
                        self.target.write_bytes(self.source.read_bytes())
                        self.target.chmod(0o444)
                    step = module.Journal.step
                    def interrupt(journal, name, action):
                        result = step(journal, name, action)
                        if name == 'verify': raise InterruptedError('before publication')
                        return result
                    with patch('migration.prerequisites.inspect_native', side_effect=collector), patch.object(self.runtime, 'activate', side_effect=activate), patch.object(self.runtime, 'verify', side_effect=lambda manifest: module.verify_deployed_files(manifest, self.home)):
                        self.plan = inspect(self.manifest, self.home)
                        with patch.object(module.Journal, 'step', new=interrupt), self.assertRaises(InterruptedError):
                            module.apply(self.plan, self.manifest, runtime=self.runtime)
                        if edited:
                            self.target.chmod(0o600)
                            self.target.write_text('local change after interrupted verification')
                            with self.assertRaises(Conflict):
                                module.apply(self.plan, self.manifest, runtime=self.runtime)
                            self.assertEqual(self.target.read_text(), 'local change after interrupted verification')
                            self.assertEqual(read_owner(self.home)['phase'], 'transferring')
                        else:
                            module.apply(self.plan, self.manifest, runtime=self.runtime)
                            self.assertEqual(read_owner(self.home)['phase'], 'home-manager')
                        self.assertEqual(len(self.runtime.calls), 1)

    def provider_upgrade(self):
        """Real old/new uv commands with private models of Nix store selection."""
        patch.stopall()
        module = self.module()
        selected_generation = module.Runtime.selected_generation
        from migration.model import fingerprint
        profile = self.home / '.nix-profile'
        selected = self.home / '.local/state/nix/profiles/home-manager'
        selected.parent.mkdir(parents=True)
        old_generation = self.generation
        new_generation = Path('/nix/store/' + '1' * 32 + '-fixture-generation')
        generations = {str(old_generation): self.root / 'generation',
                       str(new_generation): self.root / 'new-generation'}
        generations[str(new_generation)].mkdir()
        original_resolve = Path.resolve
        def resolve(path, *args, **kwargs):
            actual = original_resolve(path, *args, **kwargs)
            if path == selected:
                # Model an immutable store selector without creating /nix.
                return next((Path(generation) for generation, fixture in generations.items()
                             if actual == fixture), actual)
            return actual
        patch.object(Path, 'resolve', new=resolve).start()
        original_fingerprint = fingerprint
        patch('migration.plan.fingerprint', side_effect=lambda path:
              original_fingerprint(generations.get(str(path), path))).start()
        providers = {}
        for version, generation in [('1.0.0', old_generation), ('2.0.0', new_generation)]:
            provider = self.root / ('uv-' + version)
            (provider / 'bin').mkdir(parents=True)
            executable = provider / 'bin/uv'
            executable.write_text('#!/bin/sh\nprintf "uv ' + version + '\\n"\n')
            executable.chmod(0o755)
            providers[str(generation)] = provider
        self.manifest['profilePaths'] = [str(profile), str(selected)]
        self.manifest['commandRequirements'] = [{'command': 'uv', 'provider': str(providers[str(old_generation)])}]
        self.runtime.manifest = self.manifest
        activate = self.runtime.activate
        def install(generation):
            activate(generation)
            for link, target in [(profile, providers[generation]), (selected, generations[generation])]:
                if link.is_symlink(): link.unlink()
                link.symlink_to(target)
        def packages(path):
            if not profile.is_symlink(): return []
            return [{'name': 'home-manager-path', 'paths': [str(selected.resolve() / 'home-path')],
                     'active': True, 'priority': None}]
        patch.object(self.runtime, 'activate', side_effect=install).start()
        patch.object(self.runtime, 'profile_packages', side_effect=packages).start()
        patch.object(self.runtime, 'selected_generation', side_effect=lambda manifest:
                     selected_generation(self.runtime, manifest)).start()
        patch('migration.transaction.Runtime', return_value=self.runtime).start()
        self.plan = inspect(self.manifest, self.home)
        module.apply(self.plan, self.manifest, runtime=self.runtime)
        newer = dict(self.manifest, activationPackage=str(new_generation), commandRequirements=[
            {'command': 'uv', 'provider': str(providers[str(new_generation)])}])
        self.runtime.manifest = newer
        return profile, selected, old_generation, new_generation, providers, newer

    def test_owned_provider_upgrade_preview_apply_and_retries(self):
        import subprocess
        module = self.module()
        for boundary in ['publish-transferring', 'archive-0', 'activate-before-action',
                         'activate-after-action', 'activate', 'publish-active']:
            with self.subTest(boundary=boundary):
                self.setUp()
                profile = self.home / '.nix-profile'
                with patch.dict(os.environ, {'DOTFILES_CALLER_PATH': str(profile / 'bin')}):
                    profile, selected, old, new, providers, newer = self.provider_upgrade()
                    self.assertEqual(subprocess.check_output([str(profile / 'bin/uv')], text=True), 'uv 1.0.0\n')
                    plan = inspect(newer, self.home)
                    self.assertEqual(plan['conflicts'], [])
                    self.assertEqual(len(plan['providerTransitions']), 1)
                    step = module.Journal.step
                    def interrupt(journal, name, action):
                        if name == 'activate' and boundary in ['activate-before-action', 'activate-after-action']:
                            journal.data['steps'][name] = 'intent'
                            journal.save()
                            if boundary == 'activate-after-action': action()
                            raise InterruptedError('upgrade activation intent')
                        result = step(journal, name, action)
                        if name == boundary: raise InterruptedError('upgrade boundary')
                        return result
                    with patch.object(module.Journal, 'step', new=interrupt), self.assertRaises(InterruptedError):
                        module.apply(plan, newer, runtime=self.runtime)
                    module.apply(plan, newer, runtime=self.runtime)
                    module.apply(plan, newer, runtime=self.runtime)
                    self.assertEqual(read_owner(self.home)['selectedGeneration'], str(new))
                    self.assertEqual(subprocess.check_output([str(profile / 'bin/uv')], text=True), 'uv 2.0.0\n')
                    self.assertEqual(self.runtime.calls, [str(old), str(new)]
                                     + ([str(new)] if boundary == 'activate-after-action' else []))

    def test_owned_uv_transition_preserves_native_observation_evidence(self):
        module = self.module()
        from migration.prerequisites import inspect_native
        import subprocess
        for same_provider in [False, True]:
            with self.subTest(same_provider=same_provider):
                self.setUp()
                profile = self.home / '.nix-profile'
                with patch.dict(os.environ, {'DOTFILES_CALLER_PATH': str(profile / 'bin')}):
                    profile, selected, old, new, providers, newer = self.provider_upgrade()
                    if same_provider:
                        package = self.root / 'new-package-environment'
                        (package / 'bin').mkdir(parents=True)
                        (package / 'bin/uv').symlink_to(providers[str(old)] / 'bin/uv')
                        newer['commandRequirements'][0]['provider'] = str(providers[str(old)])
                        providers[str(new)] = package
                    nvim = self.root / 'nvim/bin/nvim'
                    nvim.parent.mkdir(parents=True)
                    nvim.write_text('#!/bin/sh\nprintf \'%s\\n\' \'{"parquet":{"ok":true},"data_query":{"duckdb":{"ok":true}}}\'\n')
                    nvim.chmod(0o755)
                    newer['nativeDependencies'] = [{'id': 'uv-visidata'}]
                    newer['commandRequirements'].append({'command': 'nvim', 'provider': str(nvim.parent.parent)})
                    def collector(manifest, home):
                        # Real collector/provider fingerprints; immutable Lua execution
                        # is represented by a fixed Neovim process response in this source suite.
                        probe = dict(manifest, files=[{'target': '.config/nvim/lua/data_query/tool.lua',
                                     'source': '/nix/store/fixture-native-runtime/lua/data_query/tool.lua'}])
                        return inspect_native(probe, home)
                    with patch('migration.prerequisites.inspect_native', side_effect=collector):
                        plan = inspect(newer, self.home)
                        self.assertEqual(plan['conflicts'], [])
                        before = plan['nativePrerequisites'][0]['observations'][str(profile / 'bin/uv')]
                        self.assertEqual(before['sha256'], module.fingerprint(providers[str(old)] / 'bin/uv')['sha256'])
                        module.apply(plan, newer, runtime=self.runtime)
                        module.apply(plan, newer, runtime=self.runtime)
                        self.assertEqual(subprocess.check_output([str(profile / 'bin/uv')], text=True), 'uv 1.0.0\n' if same_provider else 'uv 2.0.0\n')
                        if not same_provider:
                            self.assertNotEqual(module.fingerprint(profile / 'bin/uv')['sha256'], before['sha256'])

    def test_provider_transition_rejects_wrong_phase_and_post_activation_drift(self):
        module = self.module()
        for boundary, drift in [('publish-transferring', 'early-new'), ('activate', 'old'),
                                ('activate', 'foreign'), ('activate', 'wrong-package')]:
            with self.subTest(boundary=boundary, drift=drift):
                self.setUp()
                profile = self.home / '.nix-profile'
                with patch.dict(os.environ, {'DOTFILES_CALLER_PATH': str(profile / 'bin')}):
                    profile, selected, old, new, providers, newer = self.provider_upgrade()
                    plan = inspect(newer, self.home)
                    self.assertEqual(plan['conflicts'], [])
                    step = module.Journal.step
                    def interrupt(journal, name, action):
                        result = step(journal, name, action)
                        if name == boundary: raise InterruptedError('provider phase boundary')
                        return result
                    with patch.object(module.Journal, 'step', new=interrupt), self.assertRaises(InterruptedError):
                        module.apply(plan, newer, runtime=self.runtime)
                    if drift == 'early-new':
                        self.runtime.activate(str(new))
                    elif drift == 'old':
                        self.runtime.activate(str(old))
                    elif drift == 'foreign':
                        profile.unlink(); profile.symlink_to(providers[str(old)])
                    else:
                        patch.object(self.runtime, 'profile_packages', return_value=[]).start()
                    with self.assertRaises(Conflict):
                        module.apply(plan, newer, runtime=self.runtime)

    def test_owned_provider_preview_rejects_foreign_shadow_and_unproven_selection(self):
        module = self.module()
        for scenario in ['direct-store', 'foreign-path', 'wrong-generation', 'wrong-package', 'undeclared-profile']:
            with self.subTest(scenario=scenario):
                self.setUp()
                profile = self.home / '.nix-profile'
                with patch.dict(os.environ, {'DOTFILES_CALLER_PATH': str(profile / 'bin')}):
                    profile, selected, old, new, providers, newer = self.provider_upgrade()
                    if scenario == 'direct-store':
                        os.environ['DOTFILES_CALLER_PATH'] = str(providers[str(old)] / 'bin')
                    elif scenario == 'foreign-path':
                        foreign = self.root / 'foreign-bin'; foreign.mkdir()
                        (foreign / 'uv').symlink_to(providers[str(old)] / 'bin/uv')
                        os.environ['DOTFILES_CALLER_PATH'] = str(foreign)
                    elif scenario == 'wrong-generation':
                        selected.unlink(); selected.symlink_to('/nix/store/unreviewed-generation')
                    elif scenario == 'wrong-package':
                        patch.object(self.runtime, 'profile_packages', return_value=[
                            {'name': 'home-manager-path', 'paths': ['/nix/store/unreviewed-home-manager-path'],
                             'active': True, 'priority': None}]).start()
                    else:
                        newer['profilePaths'] = [str(selected)]
                    plan = inspect(newer, self.home)
                    self.assertIn('provider-shadowed', [item['code'] for item in plan['conflicts']])
                    self.assertEqual(plan.get('providerTransitions', []), [])

    def adoption_routes(self, *, previous_alias=False, previous_absent=False):
        """Initial profile introduction, retaining real collector/provider I/O."""
        module = self.module()
        from migration.prerequisites import inspect_native
        profile = self.home / '.nix-profile'
        selected = self.home / '.local/state/nix/profiles/home-manager'
        selected.parent.mkdir(parents=True)
        provider = self.root / 'pinned-provider'
        (provider / 'bin').mkdir(parents=True)
        uv = provider / 'bin/uv'
        uv.write_text('#!/bin/sh\nprintf "uv 1.0.0\\n"\n'); uv.chmod(0o755)
        result = self.root / 'probe-result'
        result.write_text('{"parquet":{"ok":true},"data_query":{"duckdb":{"ok":true}}}')
        nvim = provider / 'bin/nvim'
        nvim.write_text('#!/bin/sh\n/bin/cat ' + str(result) + '\n'); nvim.chmod(0o755)
        caller_uv = uv
        if previous_alias:
            caller_uv = self.root / 'foreign-bin/uv'
            caller_uv.parent.mkdir()
            caller_uv.symlink_to(uv)
        self.manifest['profilePaths'] = [str(profile), str(selected)]
        self.manifest['commandRequirements'] = [{'command': command, 'provider': str(provider)} for command in ['uv', 'nvim']]
        self.manifest['nativeDependencies'] = [{'id': 'uv-visidata'}]
        actual_generation = self.root / 'generation'
        resolve = Path.resolve
        def resolve_selector(path, *args, **kwargs):
            actual = resolve(path, *args, **kwargs)
            return self.generation if path == selected and actual == actual_generation else actual
        patch.object(Path, 'resolve', new=resolve_selector).start()
        activate = self.runtime.activate
        def install(generation):
            activate(generation)
            for path, target in [(profile, provider), (selected, actual_generation)]:
                if path.is_symlink(): path.unlink()
                path.symlink_to(target)
        def packages(path):
            if not profile.is_symlink(): return []
            return [{'name': 'home-manager-path', 'paths': [str(selected.resolve() / 'home-path')],
                     'active': True, 'priority': None}]
        def collector(manifest, home):
            probe = dict(manifest, files=[{'target': '.config/nvim/lua/data_query/tool.lua',
                         'source': '/nix/store/fixture-native-runtime/lua/data_query/tool.lua'}])
            return inspect_native(probe, home)
        patch.object(self.runtime, 'activate', side_effect=install).start()
        patch.object(self.runtime, 'profile_packages', side_effect=packages).start()
        patch.object(self.runtime, 'selected_generation', side_effect=lambda manifest:
                     module.Runtime.selected_generation(self.runtime, manifest)).start()
        patch('migration.prerequisites.inspect_native', side_effect=collector).start()
        caller = [str(profile / 'bin'), str(self.root / 'foreign-bin')]
        if not previous_absent: caller.append(str(provider / 'bin'))
        patch.dict(os.environ, {'DOTFILES_CALLER_PATH': os.pathsep.join(caller)}).start()
        self.plan = inspect(self.manifest, self.home)
        self.assertEqual(self.plan['conflicts'], [])
        self.assertEqual(self.plan['providerTransitions'], [])
        self.assertEqual(self.plan['providers'][0]['selectedExecutable'], None if previous_absent else str(caller_uv))
        if previous_absent:
            self.assertNotIn(str(uv), self.plan['nativePrerequisites'][0]['observations'])
        else:
            self.assertIn(str(caller_uv), self.plan['nativePrerequisites'][0]['observations'])
        return profile, selected, provider, result

    def exercise_adoption_routes(self, *, previous_absent=False):
        module = self.module()
        for boundary in ['none', 'publish-transferring', 'activate-before-action',
                         'activate-after-action', 'activate', 'publish-active']:
            with self.subTest(boundary=boundary):
                patch.stopall()
                self.setUp()
                profile, selected, provider, result = self.adoption_routes(previous_absent=previous_absent)
                step = module.Journal.step
                def interrupt(journal, name, action):
                    if name == 'activate' and boundary in ['activate-before-action', 'activate-after-action']:
                        journal.data['steps'][name] = 'intent'; journal.save()
                        if boundary == 'activate-after-action': action()
                        raise InterruptedError('initial adoption activation intent')
                    value = step(journal, name, action)
                    if name == boundary: raise InterruptedError('initial adoption boundary')
                    return value
                if boundary != 'none':
                    with patch.object(module.Journal, 'step', new=interrupt), self.assertRaises(InterruptedError):
                        module.apply(self.plan, self.manifest, runtime=self.runtime)
                module.apply(self.plan, self.manifest, runtime=self.runtime)
                module.apply(self.plan, self.manifest, runtime=self.runtime)
                self.assertEqual(read_owner(self.home)['phase'], 'home-manager')
                self.assertEqual(self.runtime.calls, [str(self.generation)] * (2 if boundary == 'activate-after-action' else 1))
                saved = module.Journal(self.home, self.plan['transactionId']).data['plan']
                self.assertEqual(saved, self.plan, 'reconciliation must retain exact preview evidence')
                self.assertEqual((profile / 'bin/uv').resolve(), provider / 'bin/uv')

    def test_initial_adoption_reconciles_same_provider_route_and_real_uv_observations(self):
        self.exercise_adoption_routes()

    def test_initial_adoption_reconciles_absent_uv_route_with_real_collector(self):
        self.exercise_adoption_routes(previous_absent=True)

    def test_initial_adoption_route_reconciliation_refuses_unproven_changes(self):
        module = self.module()
        drifts = ['early', 'provider', 'provider-inode', 'previous-alias', 'foreign-route', 'missing', 'generation', 'package',
                  'native-package', 'undeclared-profile', 'caller-path', 'runtime-path', 'uid', 'query', 'binding', 'observation']
        cases = [(absent, drift) for absent in [False, True] for drift in drifts
                 if not (absent and drift in ['previous-alias', 'provider-inode'])]
        for previous_absent, drift in cases:
            with self.subTest(previous_absent=previous_absent, drift=drift):
                patch.stopall()
                self.setUp()
                profile, selected, provider, result = self.adoption_routes(
                    previous_alias=drift == 'previous-alias', previous_absent=previous_absent)
                boundary = 'publish-transferring' if drift == 'early' else 'activate'
                step = module.Journal.step
                def interrupt(journal, name, action):
                    value = step(journal, name, action)
                    if name == boundary: raise InterruptedError('adoption drift boundary')
                    return value
                with patch.object(module.Journal, 'step', new=interrupt), self.assertRaises(InterruptedError):
                    module.apply(self.plan, self.manifest, runtime=self.runtime)
                if drift == 'early':
                    profile.symlink_to(provider)
                    selected.symlink_to(self.root / 'generation')
                elif drift == 'provider': (provider / 'bin/uv').write_text('#!/bin/sh\nexit 9\n')
                elif drift == 'provider-inode':
                    uv = provider / 'bin/uv'
                    replacement = provider / 'bin/replacement'
                    replacement.write_bytes(uv.read_bytes()); replacement.chmod(0o755)
                    replacement.replace(uv)
                elif drift == 'foreign-route':
                    foreign = self.root / 'foreign-bin'; foreign.mkdir()
                    (foreign / 'uv').symlink_to(provider / 'bin/uv')
                    empty = self.root / 'empty-package'; empty.mkdir()
                    profile.unlink(); profile.symlink_to(empty)
                elif drift == 'missing': (provider / 'bin/uv').unlink()
                elif drift == 'generation': selected.unlink(); selected.symlink_to(self.root)
                elif drift in ['package', 'native-package']:
                    entry = {'name': 'home-manager-path' if drift == 'package' else 'native',
                             'paths': ['/nix/store/unreviewed-profile'], 'active': True, 'priority': None}
                    patch.object(self.runtime, 'profile_packages', return_value=[entry]).start()
                elif drift == 'undeclared-profile':
                    journal = module.Journal(self.home, self.plan['transactionId'])
                    journal.data['profilesBefore'].pop(str(profile)); journal.save()
                elif drift == 'caller-path': os.environ['DOTFILES_CALLER_PATH'] += os.pathsep + str(self.root)
                elif drift == 'runtime-path': os.environ['PATH'] += os.pathsep + str(self.root)
                elif drift == 'uid':
                    identity = patch.object(module.os, 'getuid', return_value=os.getuid() + 1)
                    identity.start()
                elif drift == 'query': result.write_text('{"parquet":{"ok":true,"changed":true},"data_query":{"duckdb":{"ok":true}}}')
                elif drift != 'previous-alias':
                    from migration import prerequisites
                    collector = prerequisites.inspect_native
                    def changed(manifest, home):
                        records = collector(manifest, home)
                        if drift == 'binding': records[0]['binding']['collector'] = 'changed'
                        else: records[0]['observations'][str(profile / 'bin/uv')]['inode'] += 1
                        return records
                    patch.object(prerequisites, 'inspect_native', side_effect=changed).start()
                with self.assertRaises(Conflict):
                    module.apply(self.plan, self.manifest, runtime=self.runtime)
                if drift == 'uid': identity.stop()
                self.assertEqual(read_owner(self.home)['phase'], 'transferring')

    def test_newly_available_caller_command_requires_exact_owned_profile_and_provider(self):
        module = self.module()
        for scenario in ['reviewed', 'foreign-command', 'foreign-profile', 'wrong-generation', 'undeclared-profile']:
            with self.subTest(scenario=scenario):
                self.setUp()
                provider = self.root / 'reviewed-provider'
                (provider / 'bin').mkdir(parents=True)
                executable = provider / 'bin/reviewed-command'
                executable.write_text('#!/bin/sh\nexit 0\n'); executable.chmod(0o755)
                profile = self.home / '.nix-profile'
                self.manifest['commandRequirements'] = [{'command': 'reviewed-command', 'provider': str(provider)}]
                if scenario != 'undeclared-profile': self.manifest['profilePaths'] = [str(profile)]
                activate = self.runtime.activate
                def install(generation):
                    activate(generation)
                    if scenario == 'foreign-command':
                        foreign = self.root / 'foreign-provider'
                        (foreign / 'bin').mkdir(parents=True)
                        (foreign / 'bin/reviewed-command').write_text('#!/bin/sh\nexit 7\n')
                        (foreign / 'bin/reviewed-command').chmod(0o755)
                        profile.symlink_to(foreign)
                    else:
                        profile.symlink_to(provider)
                def packages(path):
                    if not self.runtime.calls: return []
                    selected = '/nix/store/unreviewed-profile' if scenario == 'foreign-profile' else str(self.generation / 'home-path')
                    return [{'name': 'home-manager-path', 'paths': [selected], 'active': True, 'priority': None}]
                def selected(manifest):
                    return '/nix/store/unreviewed-generation' if scenario == 'wrong-generation' else str(self.generation)
                with patch.dict(os.environ, {'DOTFILES_CALLER_PATH': str(profile / 'bin')}), patch.object(self.runtime, 'activate', side_effect=install), patch.object(self.runtime, 'profile_packages', side_effect=packages), patch.object(self.runtime, 'selected_generation', side_effect=selected):
                    self.plan = inspect(self.manifest, self.home)
                    self.assertEqual(self.plan['conflicts'], [])
                    self.assertIsNone(self.plan['providers'][0]['selectedExecutable'])
                    if scenario == 'reviewed':
                        module.apply(self.plan, self.manifest, runtime=self.runtime)
                        module.apply(self.plan, self.manifest, runtime=self.runtime)
                        self.assertEqual(read_owner(self.home)['phase'], 'home-manager')
                    else:
                        with self.assertRaises(Conflict):
                            module.apply(self.plan, self.manifest, runtime=self.runtime)
                        self.assertEqual(read_owner(self.home)['phase'], 'transferring')
                    self.assertEqual(len(self.runtime.calls), 1)

    def test_resumed_native_rejects_same_caller_path_retargeted_to_foreign_executable(self):
        module = self.module()
        provider = self.root / 'pinned'
        (provider / 'bin').mkdir(parents=True)
        executable = provider / 'bin/reviewed-command'
        executable.write_text('#!/bin/sh\nexit 0\n'); executable.chmod(0o755)
        caller = self.root / 'caller'
        caller.mkdir()
        selected = caller / 'reviewed-command'
        selected.symlink_to(executable)
        foreign = self.root / 'foreign'
        foreign.write_text('#!/bin/sh\nexit 7\n'); foreign.chmod(0o755)
        self.manifest['commandRequirements'] = [{'command': 'reviewed-command', 'provider': str(provider)}]
        step = module.Journal.step
        def interrupt(journal, name, action):
            result = step(journal, name, action)
            if name == 'publish-transferring': raise InterruptedError('before first stop')
            return result
        with patch.dict(os.environ, {'DOTFILES_CALLER_PATH': str(caller)}):
            self.plan = inspect(self.manifest, self.home)
            self.assertEqual(self.plan['conflicts'], [])
            with patch.object(module.Journal, 'step', new=interrupt), self.assertRaises(InterruptedError):
                module.apply(self.plan, self.manifest, runtime=self.runtime)
            selected.unlink(); selected.symlink_to(foreign)
            with self.assertRaises(Conflict):
                module.apply(self.plan, self.manifest, runtime=self.runtime)
            self.assertEqual(self.runtime.calls, [])
            self.assertEqual(selected.resolve(), foreign)
            self.assertEqual(read_owner(self.home)['phase'], 'transferring')
            selected.unlink(); selected.symlink_to(executable)
            module.apply(self.plan, self.manifest, runtime=self.runtime)
            module.apply(self.plan, self.manifest, runtime=self.runtime)
            self.assertEqual(len(self.runtime.calls), 1)
            self.assertEqual(read_owner(self.home)['phase'], 'home-manager')

    def test_ghostty_effective_include_reconciles_only_reviewed_owned_transition(self):
        module = self.module()
        from migration.model import fingerprint
        for scenario in ['apply-repeat', 'publication-retry', 'foreign-include', 'unowned-include', 'changed-source', 'edited-include', 'setting-drift']:
            with self.subTest(scenario=scenario):
                self.setUp()
                include = self.target.with_name('platform-linux.ghostty')
                source = self.root / 'platform-linux.ghostty'
                source.write_text('gtk-single-instance = false\n')
                include.write_bytes(source.read_bytes())
                self.manifest['files'].append(dict(self.manifest['files'][0], target=str(include.relative_to(self.home)), source=str(source)))
                self.manifest['nativeDependencies'] = [{'id': 'ghostty'}]
                provider = self.root / 'ghostty'
                provider.write_text('native provider'); provider.chmod(0o755)
                def collector(manifest, home):
                    selected = source if include.is_symlink() else include
                    setting = 'false'
                    if self.runtime.calls:
                        if scenario == 'foreign-include': selected = self.root / 'unreviewed.ghostty'
                        if scenario == 'unowned-include': selected = self.target.with_name('unowned.ghostty')
                        if scenario == 'setting-drift': setting = 'true'
                    return [{'id': 'ghostty', 'status': 'observed', 'command': 'ghostty', 'selectedExecutable': str(provider),
                             'observations': {str(self.target): fingerprint(self.target)}, 'queries': [
                                 {'command': [str(provider), '+show-config', '--changes-only'], 'context': {}, 'status': 0,
                                  'stdout': 'config-file = '+str(selected)+'\ngtk-single-instance = '+setting+'\n', 'stderr': ''}]}]
                activate = self.runtime.activate
                def install(generation):
                    activate(generation)
                    if scenario == 'changed-source': source.write_text('changed immutable source\n')
                    if scenario == 'edited-include':
                        include.unlink(); include.write_text('unreviewed edit\n')
                step = module.Journal.step
                def interrupt(journal, name, action):
                    result = step(journal, name, action)
                    if name == 'verify': raise InterruptedError('before ownership publication')
                    return result
                with patch.dict(os.environ, {'DOTFILES_CALLER_PATH': str(self.root)}), patch('migration.prerequisites.inspect_native', side_effect=collector), patch.object(self.runtime, 'activate', side_effect=install):
                    self.plan = inspect(self.manifest, self.home)
                    self.assertEqual(self.plan['conflicts'], [])
                    if scenario in ['apply-repeat', 'publication-retry']:
                        if scenario == 'publication-retry':
                            with patch.object(module.Journal, 'step', new=interrupt), self.assertRaises(InterruptedError):
                                module.apply(self.plan, self.manifest, runtime=self.runtime)
                        module.apply(self.plan, self.manifest, runtime=self.runtime)
                        module.apply(self.plan, self.manifest, runtime=self.runtime)
                        self.assertEqual(read_owner(self.home)['phase'], 'home-manager')
                    else:
                        with self.assertRaises(Conflict):
                            module.apply(self.plan, self.manifest, runtime=self.runtime)
                        self.assertEqual(read_owner(self.home)['phase'], 'transferring')
                        if scenario == 'edited-include': self.assertEqual(include.read_text(), 'unreviewed edit\n')
                    self.assertEqual(len(self.runtime.calls), 1)
