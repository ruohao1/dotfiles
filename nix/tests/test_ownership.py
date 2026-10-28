"""Behavioral ownership checks; all deployer children use private identities."""
import importlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(os.environ.get('DOTFILES_MIGRATION_SOURCE_ROOT', Path(__file__).resolve().parents[2]))
sys.path.insert(0, str(ROOT / 'nix'))


def tree(root):
    return {str(p.relative_to(root)): (p.lstat().st_mode, os.readlink(p) if p.is_symlink()
            else p.read_bytes() if p.is_file() else None) for p in root.rglob('*')}


class OwnershipTests(unittest.TestCase):
    def setUp(self):
        parent = Path(os.environ.get('DOTFILES_MIGRATION_TEST_ROOT', '/tmp/dotfiles-isq317-tests'))
        parent.mkdir(exist_ok=True, mode=0o700)
        self.root = Path(tempfile.mkdtemp(prefix='ownership-', dir=parent))
        self.home = self.root / 'home'
        self.home.mkdir(mode=0o700)
        self.state = self.home / '.local/state/dotfiles-ownership'
        self.env = {'HOME': str(self.home), 'PATH': os.environ.get('PATH', os.defpath), 'LANG': 'C',
                    'XDG_STATE_HOME': str(self.root / 'alternate-state'),
                    'TMPDIR': str(self.root), 'DOTFILES_BOOTSTRAP_TESTING': '1',
                    'DOTFILES_BOOTSTRAP_TEST_PLATFORM': 'linux',
                    'DOTFILES_BOOTSTRAP_TEST_MANAGER': 'pacman',
                    'DOTFILES_BOOTSTRAP_TEST_SKIP_PACKAGES': '1'}
        self.standalone = self.root / 'bootstrap'
        self.standalone.write_bytes((ROOT / '.config/dotfiles/bootstrap').read_bytes())

    def module(self):
        self.assertTrue((ROOT / 'nix/migration/model.py').is_file(), 'shared Python ownership model missing')
        return importlib.import_module('migration.model')

    def deploy(self, args, standalone=False):
        script = self.standalone if standalone else ROOT / '.config/dotfiles/bootstrap'
        return subprocess.run(['/bin/sh', str(script), *args], env=self.env,
                              capture_output=True, text=True, timeout=10)

    def metadata(self, value):
        self.state.mkdir(parents=True, mode=0o700, exist_ok=True)
        (self.state / 'owner.json').write_text(json.dumps(value))

    def test_every_owner_phase_and_malformed_blocks_all_legacy_dispatches(self):
        for owner in [{'schema': 1, 'phase': phase} for phase in
                      ['transferring', 'home-manager', 'recovering']] + [{'schema': 99}, 'broken']:
            self.metadata(owner)
            before = tree(self.root)
            for standalone in [False, True]:
                for args in [['--apply', '--window-manager', 'none'],
                             ['--apply', '--window-manager', 'none', '--expected-commit', '0' * 40],
                             ['--apply', '--managed-tool', 'taplo'], ['--rollback', 'latest']]:
                    with self.subTest(owner=owner, args=args, standalone=standalone):
                        result = self.deploy(args, standalone)
                        self.assertEqual(result.returncode, 1)
                        self.assertIn('ownership', result.stderr)
                        self.assertEqual(tree(self.root), before)

    def test_help_and_read_only_inspection_are_usable_with_owner(self):
        self.metadata({'schema': 1, 'phase': 'home-manager'})
        before = tree(self.root)
        self.assertEqual(self.deploy(['--help']).returncode, 0)
        self.assertEqual(self.deploy(['--window-manager', 'none']).returncode, 0)
        self.assertEqual(tree(self.root), before)

    def test_symlinked_metadata_and_unsafe_parents_fail_without_mutation(self):
        self.state.mkdir(parents=True, mode=0o700)
        foreign = self.root / 'foreign'
        foreign.write_text('do not touch')
        (self.state / 'owner.json').symlink_to(foreign)
        before = tree(self.root)
        result = self.deploy(['--apply', '--managed-tool', 'taplo'])
        self.assertEqual(result.returncode, 1)
        self.assertIn('ownership', result.stderr)
        self.assertEqual(tree(self.root), before)
        (self.state / 'owner.json').unlink()
        self.state.chmod(0o777)
        before = tree(self.root)
        result = self.deploy(['--apply', '--window-manager', 'none'], True)
        self.assertEqual(result.returncode, 1)
        self.assertIn('ownership', result.stderr)
        self.assertEqual(tree(self.root), before)

    def test_symlinked_parent_rejected_by_both_implementations(self):
        foreign = self.root / 'foreign'
        foreign.mkdir(mode=0o700)
        (self.home / '.local').symlink_to(foreign)
        before = tree(self.root)
        result = self.deploy(['--rollback', 'latest'])
        self.assertEqual(result.returncode, 1)
        self.assertIn('ownership', result.stderr)
        model = self.module()
        with self.assertRaises(model.Conflict):
            with model.HomeLock(self.home):
                pass
        self.assertEqual(tree(self.root), before)

    def test_python_winner_blocks_local_and_standalone_legacy_without_changes(self):
        model = self.module()
        with model.HomeLock(self.home):
            before = tree(self.root)
            for standalone in [False, True]:
                result = self.deploy(['--apply', '--window-manager', 'none'], standalone)
                self.assertEqual(result.returncode, 1)
                self.assertIn('ownership', result.stderr)
                self.assertEqual(tree(self.root), before)
        self.assertFalse((self.state / 'lock').exists())

    def test_shell_winner_blocks_python_and_recheck_blocks_internal_rollback(self):
        model = self.module()
        library = ROOT / '.config/dotfiles/lib/ownership.sh'
        ready = self.root / 'ready'
        release = self.root / 'release'
        command = '. "$1"; ownership_acquire || exit 1; trap ownership_release 0; : > "$2"; while [ ! -e "$3" ]; do sleep 0.02; done; ownership_recheck'
        child = subprocess.Popen(['/bin/sh', '-c', command, 'sh', str(library), str(ready), str(release)], env=self.env,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            import time
            deadline = time.monotonic() + 5
            while not ready.exists() and child.poll() is None and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(ready.exists())
            before = tree(self.root)
            with self.assertRaises(model.Conflict):
                with model.HomeLock(self.home):
                    pass
            self.assertEqual(tree(self.root), before)
            self.metadata({'schema': 1, 'phase': 'transferring'})
            release.touch()
            output, error = child.communicate(timeout=5)
            self.assertEqual(child.returncode, 1, error.decode())
        finally:
            if child.poll() is None:
                child.kill()
                child.communicate()

    def test_internal_rollback_rechecks_owner_before_journal_status_write(self):
        library = ROOT / '.config/dotfiles/lib/ownership.sh'
        self.assertTrue(library.is_file(), 'portable ownership guard missing')
        bootstrap = (ROOT / '.config/dotfiles/bootstrap').read_text()
        prefix = bootstrap.split('\ntransaction_active=false\ntransaction_run=\n', 1)[0]
        harness = self.root / 'rollback-harness'
        harness.write_text(prefix + '\nownership_acquire || exit 99\nprintf broken > "$ownership_root/owner.json"\nrollback_transaction "$HOME/journal"\n')
        journal = self.home / 'journal'
        journal.mkdir()
        (journal / 'status').write_text('complete\n')
        result = subprocess.run(['/bin/sh', str(harness)], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn('ownership', result.stderr)
        self.assertEqual((journal / 'status').read_text(), 'complete\n')

    def test_home_traversal_and_shell_lock_replacement_fail_closed(self):
        library = ROOT / '.config/dotfiles/lib/ownership.sh'
        self.assertTrue(library.is_file())
        changed_env = dict(self.env, HOME=str(self.home / '..' / 'home'))
        result = subprocess.run(['/bin/sh', str(self.standalone), '--rollback', 'latest'],
                                env=changed_env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn('ownership', result.stderr)
        model = self.module()
        with self.assertRaises(model.Conflict):
            with model.HomeLock(changed_env['HOME']):
                pass
        command = '. "$1"; ownership_acquire || exit 99; rmdir "$ownership_lock_path"; mkdir "$ownership_lock_path"; ownership_recheck; result=$?; ownership_release; exit "$result"'
        result = subprocess.run(['/bin/sh', '-c', command, 'sh', str(library)], env=self.env,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('replaced', result.stderr)
        self.assertTrue((self.state / 'lock').exists(), 'release must preserve a replacement lock')

    def test_owner_schema_identity_and_lock_replacement_are_validated(self):
        model = self.module()
        valid = {'schema': 1, 'phase': 'home-manager', 'home': str(self.home),
                 'transactionId': 'abc', 'manifestFingerprint': 'a' * 64,
                 'selectedGeneration': '/nix/store/example-generation',
                 'journalPath': str(self.state / 'transactions/abc')}
        self.metadata(valid)
        self.assertEqual(model.read_owner(self.home), valid)
        for key in valid:
            altered = dict(valid)
            altered.pop(key)
            self.metadata(altered)
            with self.assertRaises(model.Conflict):
                model.read_owner(self.home)
        self.metadata(dict(valid, home='/other-home'))
        with self.assertRaises(model.Conflict):
            model.read_owner(self.home)
        (self.state / 'owner.json').unlink()
        with model.HomeLock(self.home) as lock:
            (self.state / 'lock').rmdir()
            (self.state / 'lock').mkdir(mode=0o700)
            with self.assertRaises(model.Conflict):
                lock.recheck()


if __name__ == '__main__':
    unittest.main()
