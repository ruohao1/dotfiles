"""Updater confirmation and recovery, with real retained plans and journals."""
import importlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'nix'))
from update import UpdateError, state
from update import deployment

RELEASE = {'repository': 'ruohao1/dotfiles', 'releaseId': 2,
           'version': 'v1.2.3', 'commit': 'b'*40}
OLD = dict(RELEASE, releaseId=1, version='v1.0.0', commit='a'*40)


class Commands(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix='update-cli-'))
        self.home = self.root/'home'
        self.home.mkdir(mode=0o700)
        self.addCleanup(patch.stopall)
        patch.dict(os.environ, HOME=str(self.home), DOTFILES_UPDATE_CALLER_PATH='/original/bin').start()
        self.state = state.open_state(self.home, create=True)
        state.write_json(self.state/'config.json', dict(schema=1, sourceRoot=str(self.root/'host'), profile='host'))
        self.directory = self.state/'candidates'/'1'
        self.directory.mkdir(parents=True, mode=0o700)
        self.candidate = dict(schema=1, sourceRoot=str(self.directory/'source'), sourceCommit='c'*40,
            originalRoot=str(self.root/'host'), originalCommit='d'*40, profile='host',
            consumerSource='/nix/store/'+'c'*32+'-source', release=RELEASE,
            executor='/nix/store/'+'e'*32+'-dotfiles', rootLink=str(self.directory/'executor'))
        self.plan = dict(transactionId='f'*32, home=str(self.home), manifestFingerprint='a'*64,
            selectedGeneration='/nix/store/'+'b'*32+'-generation', conflicts=[], nativePrerequisites=[],
            nativeManifest=dict(declaredProfile='host', deploymentIdentity=dict(schema=1,
                profile='host', consumerSource=self.candidate['consumerSource'], release=RELEASE)))
        self.calls = []

    def cli(self):
        self.assertTrue((ROOT/'nix/update/cli.py').exists(), 'updater CLI is missing')
        return importlib.import_module('update.cli')

    def execute(self, candidate, arguments):
        self.calls.append(arguments)
        self.assertEqual(candidate['callerPath'], '/original/bin')
        if arguments[0] == 'plan':
            output = Path(arguments[-1])
            self.assertFalse(output.is_relative_to(self.home))
            state.write_json(output, self.plan, limit=state.MAX_PLAN_BYTES)
        elif arguments[0] == 'apply':
            association = state.read_json(self.directory/'recovery.json')
            self.assertEqual(association['transactionId'], self.plan['transactionId'])
            self.assertEqual(state.read_json(Path(arguments[-1])), self.plan)

    def install(self, answer='yes', *, tty=True, recheck=None, exact_effect=None, phase='installed'):
        cli = self.cli()
        with patch.object(cli.sys.stdin, 'isatty', return_value=tty), \
             patch('builtins.input', side_effect=answer if isinstance(answer, Exception) else lambda _: answer), \
             patch.object(deployment, 'read_installed', return_value=dict(state=phase, release=OLD,
                 generation='/nix/store/old', retained=[])), \
             patch.object(deployment, 'prepare', return_value=self.candidate), \
             patch.object(deployment, '_execute', side_effect=self.execute), \
             patch.object(deployment, 'validate_source', side_effect=recheck or
                 (lambda _: (self.root/'host', 'd'*40, {}))), \
             patch.object(cli.releases, 'check', return_value=RELEASE), \
             patch.object(cli.releases, 'validate_exact', return_value=RELEASE, side_effect=exact_effect) as exact, \
             patch('sys.stdout', new_callable=io.StringIO):
            result = cli.main(['install'])
        return result, exact.call_args_list

    def test_decline_eof_and_nonterminal_never_apply(self):
        for answer, tty in [('', True), ('no', True), (EOFError(), True), ('yes', False)]:
            with self.subTest(answer=answer, tty=tty):
                self.calls.clear()
                result, _ = self.install(answer, tty=tty)
                self.assertFalse(any(call[0] == 'apply' for call in self.calls))
                if not tty:
                    self.assertEqual(self.calls, [])

    def test_confirmed_apply_retains_review_and_exact_release(self):
        result, exact = self.install()
        self.assertEqual(result, 0)
        self.assertEqual([call[0] for call in self.calls], ['plan', 'apply'])
        self.assertEqual([call.args[0] for call in exact], [RELEASE, RELEASE])
        self.assertEqual(state.read_json(self.directory/'recovery.json')['release'], RELEASE)

    def test_conflicts_and_changed_source_refuse_apply(self):
        self.plan['conflicts'] = ['native prerequisite missing']
        self.assertEqual(self.install()[0], 1)
        self.assertFalse(any(call[0] == 'apply' for call in self.calls))
        self.plan['conflicts'] = []
        self.calls.clear()
        self.assertEqual(self.install(recheck=lambda _: (self.root/'host', 'e'*40, {}))[0], 1)
        self.assertFalse(any(call[0] == 'apply' for call in self.calls))

    def test_apply_failure_keeps_offline_recovery_after_temporary_plan_is_lost(self):
        execute = self.execute
        def interrupted(candidate, arguments):
            execute(candidate, arguments)
            if arguments[0] == 'apply':
                raise UpdateError('activation interrupted')
        self.execute = interrupted
        self.assertEqual(self.install()[0], 1)
        temporary = Path(self.calls[0][-1])
        temporary.unlink()
        retained = state.read_json(self.directory/'recovery.json')
        with patch.object(deployment, '_executor', return_value=retained['executor']):
            recovered = deployment.recovery(self.state, self.plan['transactionId'])
        self.assertEqual(recovered['callerPath'], '/original/bin')
        self.assertEqual(state.read_json(Path(recovered['planPath'])), self.plan)
        self.assertNotEqual(Path(recovered['planPath']), temporary)
        state.write_json(Path(recovered['planPath']), dict(self.plan, conflicts=['changed']))
        with self.assertRaises(UpdateError):
            deployment.recovery(self.state, self.plan['transactionId'])

    def test_status_never_refreshes_network(self):
        cli = self.cli()
        with patch.object(cli.releases, 'check', side_effect=AssertionError('status used network')), \
             patch('sys.stdout', new_callable=io.StringIO) as output:
            self.assertEqual(cli.main(['status']), 0)
        self.assertIn('unmanaged', output.getvalue())

    def test_pending_transaction_and_changed_release_refuse_apply(self):
        self.assertEqual(self.install(phase='pending')[0], 1)
        self.assertEqual(self.calls, [])
        self.assertEqual(self.install(exact_effect=[RELEASE, UpdateError('release moved')])[0], 1)
        self.assertFalse(any(call[0] == 'apply' for call in self.calls))

    def test_rollback_uses_retained_executor_offline_and_rejects_unknown_target(self):
        self.assertEqual(self.install()[0], 0)
        cli = self.cli()
        target = '/nix/store/'+'a'*32+'-generation'
        with patch.object(deployment, 'read_installed', return_value=dict(state='installed', release=RELEASE,
                 transactionId=self.plan['transactionId'], retained=[dict(generation=target, release=OLD)])), \
             patch.object(deployment, '_executor', return_value=self.candidate['executor']), \
             patch.object(deployment, '_execute') as execute, \
             patch.object(cli.sys.stdin, 'isatty', return_value=True), patch('builtins.input', return_value='yes'), \
             patch.object(cli.releases, 'check', side_effect=AssertionError('rollback must be offline')), \
             patch('sys.stdout', new_callable=io.StringIO):
            self.assertEqual(cli.main(['rollback', '--generation', '/nix/store/foreign']), 1)
            execute.assert_not_called()
            self.assertEqual(cli.main(['rollback', '--generation', target]), 0)
            self.assertEqual(execute.call_args.args[1], ['rollback', '--generation', target])
            self.assertEqual(execute.call_args.args[0]['callerPath'], '/original/bin')

    def test_tmux_native_and_unconfigured_homes_never_fetch(self):
        cli = self.cli()
        with patch.object(cli.releases, 'check', side_effect=AssertionError('native home fetched')):
            self.assertEqual(cli.main(['status', '--tmux']), 0)
            (self.state/'config.json').unlink()
            self.assertEqual(cli.main(['status', '--tmux']), 0)

    def test_tmux_prints_cached_notice_before_refresh(self):
        cli = self.cli()
        state.write_json(self.state/'cache.json', dict(cli.releases.read_cache(self.state), release=RELEASE))
        with patch.object(deployment, 'read_installed', return_value=dict(state='installed', release=OLD)), \
             patch('sys.stdout', new_callable=io.StringIO) as output:
            def refresh(*args, **kwargs):
                self.assertEqual(output.getvalue().strip(), 'update v1.2.3')
                return RELEASE
            with patch.object(cli.releases, 'check', side_effect=refresh):
                self.assertEqual(cli.main(['status', '--tmux']), 0)

    def test_executor_preserves_desktop_and_remote_session_evidence(self):
        candidate = dict(self.candidate, callerPath='/original/bin')
        session = {'WAYLAND_DISPLAY': 'wayland-fixture', 'DISPLAY': ':3',
                   'SSH_CONNECTION': 'remote fixture', 'XDG_SESSION_TYPE': 'wayland'}
        with patch.dict(os.environ, session), patch.object(deployment, '_executor', return_value='/executor'), \
             patch.object(deployment.Runtime, 'run', autospec=True) as run:
            deployment._execute(candidate, ['plan'])
        environment = run.call_args.args[0].environment
        self.assertEqual({key: environment.get(key) for key in session}, session)
        self.assertEqual(environment['PATH'], '/original/bin')


class Installed(unittest.TestCase):
    def setUp(self):
        from test_migration_transaction import TransactionTests
        TransactionTests.setUp(self)
        self.addCleanup(patch.stopall)
        patch('update.deployment.Runtime.selected_generation', side_effect=self.runtime.selected_generation).start()

    def apply(self, identity=True):
        from migration.plan import inspect
        from migration.transaction import apply
        if identity:
            self.manifest['deploymentIdentity'] = dict(schema=1, release=OLD,
                consumerSource='/nix/store/'+'a'*32+'-source', profile='host')
        self.plan = inspect(self.manifest, self.home)
        apply(self.plan, self.manifest, runtime=self.runtime)

    def test_old_journal_and_manual_profile_drift_are_truthful(self):
        self.assertTrue(hasattr(deployment, 'read_installed'), 'installed state reader missing')
        self.apply(identity=False)
        with patch.object(Path, 'is_dir', return_value=True):
            self.assertEqual(deployment.read_installed(self.home)['state'], 'unversioned')
            self.runtime.calls.append('/nix/store/manual-generation')
            self.assertEqual(deployment.read_installed(self.home)['state'], 'inconsistent')

    def test_failed_activation_does_not_report_new_release_installed(self):
        self.assertTrue(hasattr(deployment, 'read_installed'), 'installed state reader missing')
        with patch.object(self.runtime, 'activate', side_effect=InterruptedError('crash')):
            with self.assertRaises(InterruptedError):
                self.apply()
        observed = deployment.read_installed(self.home)
        self.assertEqual(observed['state'], 'pending')
        self.assertIsNone(observed.get('release'))

    def test_status_tracks_second_generation_and_rollback_identity(self):
        from migration import plan, transaction
        self.apply()
        second = dict(self.manifest, activationPackage='/nix/store/'+'1'*32+'-generation',
            deploymentIdentity=dict(self.manifest['deploymentIdentity'], release=RELEASE))
        previous = plan.fingerprint
        with patch.object(plan, 'fingerprint', side_effect=lambda path:
            {'type': 'directory', 'mode': 0o555, 'uid': os.getuid(), 'gid': os.getgid(), 'entries': {}}
            if str(path) == second['activationPackage'] else previous(path)):
            proposal = plan.inspect(second, self.home)
            transaction.apply(proposal, second, runtime=self.runtime)
        with patch.object(Path, 'is_dir', return_value=True):
            self.assertEqual(deployment.read_installed(self.home)['release'], RELEASE)
            transaction.rollback(self.home, str(self.generation), runtime=self.runtime)
            self.assertEqual(deployment.read_installed(self.home)['release'], OLD)

    def test_existing_updater_cache_changes_preserve_preview_new_root_does_not(self):
        from migration.plan import inspect, verify_unchanged
        from migration.model import Conflict
        root = state.open_state(self.home, create=True)
        proposal = inspect(self.manifest, self.home)
        state.write_json(root/'cache.json', {'release': RELEASE})
        verify_unchanged(proposal)
        # A different home with no updater root records its missing directory.
        self.setUp()
        proposal = inspect(self.manifest, self.home)
        state.open_state(self.home, create=True)
        with self.assertRaises(Conflict):
            verify_unchanged(proposal)

    def test_journal_before_owner_publication_is_pending(self):
        from migration.transaction import Journal
        original = Journal.step
        def stop(journal, name, action):
            if name == 'publish-transferring':
                raise InterruptedError('before owner publication')
            return original(journal, name, action)
        with patch.object(Journal, 'step', stop):
            with self.assertRaises(InterruptedError):
                self.apply()
        self.assertEqual(deployment.read_installed(self.home)['state'], 'pending')

    def test_interrupted_rollback_recovery_names_recorded_target(self):
        from migration import transaction
        self.apply()
        with patch.object(self.runtime, 'activate', side_effect=InterruptedError('rollback interrupted')):
            with self.assertRaises(InterruptedError):
                transaction.rollback(self.home, str(self.generation), runtime=self.runtime)
        with patch.dict(os.environ, HOME=str(self.home)):
            commands = deployment.recovery_commands(dict(executor='/nix/store/executor', callerPath='/original/bin',
                planPath='/retained/review.json', transactionId=self.plan['transactionId']))
        self.assertIn('rollback --generation '+str(self.generation), commands)
        self.assertNotIn('apply --plan', commands)


if __name__ == '__main__':
    unittest.main()
