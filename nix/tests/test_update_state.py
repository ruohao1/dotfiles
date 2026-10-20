"""Updater files never follow symlinks or turn a busy lock into parallel work."""
import importlib
import multiprocessing
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'nix'))


def attempt_lock(root, queue):
    from update import state
    with state.lock(Path(root), blocking=False) as acquired:
        queue.put(acquired)


class StateTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue((ROOT / 'nix/update/state.py').is_file(), 'updater state module missing')
        self.state = importlib.import_module('update.state')
        self.home = Path(tempfile.mkdtemp(prefix='update-state-'))

    def test_fixed_root_creation_read_only_lookup_and_private_atomic_json(self):
        with patch.dict(os.environ, {'XDG_STATE_HOME': '/unrelated'}):
            root = self.state.open_state(self.home, create=False)
            self.assertEqual(root, self.home / '.local/state/dotfiles-update')
            self.assertFalse(root.exists())
            self.state.open_state(self.home, create=True)
        self.assertEqual(stat.S_IMODE(root.stat().st_mode), 0o700)
        record = root / 'config.json'
        self.state.write_json(record, {'schema': 1})
        old = record.open()
        self.state.write_json(record, {'schema': 2})
        with old:
            self.assertIn('1', old.read())
        self.assertEqual(self.state.read_json(record), {'schema': 2})
        self.assertEqual(stat.S_IMODE(record.stat().st_mode), 0o600)
        self.assertEqual(sorted(p.name for p in root.iterdir()), ['config.json'])

    def test_unsafe_parent_and_symlinked_home_refused_without_creation(self):
        real = self.home / 'real'
        real.mkdir(mode=0o700)
        link = self.home / 'link'
        link.symlink_to(real, target_is_directory=True)
        with self.assertRaises(self.state.StateError):
            self.state.open_state(link, create=True)
        self.assertEqual(list(real.iterdir()), [])
        local = self.home / '.local'
        local.mkdir(mode=0o777)
        local.chmod(0o777)
        with self.assertRaises(self.state.StateError):
            self.state.open_state(self.home, create=True)
        self.assertFalse((local / 'state').exists())

    def test_reject_symlink_fifo_foreign_and_writable_state_files(self):
        root = self.state.open_state(self.home, create=True)
        target = self.home / 'target'
        target.write_text('untouched')
        path = root / 'cache.json'
        path.symlink_to(target)
        for action in [lambda: self.state.read_json(path), lambda: self.state.write_json(path, {})]:
            with self.assertRaises(self.state.StateError):
                action()
        self.assertEqual(target.read_text(), 'untouched')
        path.unlink()
        os.mkfifo(path)
        with self.assertRaises(self.state.StateError):
            self.state.read_json(path)
        path.unlink()
        path.write_text('{}')
        path.chmod(0o666)
        with self.assertRaises(self.state.StateError):
            self.state.write_json(path, {})
        path.chmod(0o600)
        with patch.object(self.state.os, 'getuid', return_value=os.getuid() + 1):
            with self.assertRaises(self.state.StateError):
                self.state.read_json(path)

    def test_bounded_strict_json_and_malformed_cache_can_be_replaced(self):
        root = self.state.open_state(self.home, create=True)
        path = root / 'cache.json'
        for data in ['[]', '{"x":1,"x":2}', '{"x":NaN}', '{']:
            path.write_text(data)
            path.chmod(0o600)
            with self.assertRaises(self.state.InvalidJSON):
                self.state.read_json(path)
        self.state.write_json(path, {'repaired': True})
        self.assertEqual(self.state.read_json(path), {'repaired': True})
        with self.assertRaises(self.state.InvalidJSON):
            self.state.read_json(path, limit=8)
        with self.assertRaises(self.state.InvalidJSON):
            self.state.write_json(path, {'bad': float('nan')})
        self.assertEqual(self.state.read_json(path), {'repaired': True})

    def test_restrictive_umask_still_creates_private_usable_directories(self):
        previous = os.umask(0o777)
        try:
            root = self.state.open_state(self.home, create=True)
        finally:
            os.umask(previous)
        for path in [self.home/'.local', self.home/'.local/state', root]:
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o700)
        self.state.write_json(root/'config.json', {'schema': 1})
        self.assertEqual(self.state.read_json(root/'config.json'), {'schema': 1})

    def test_restrictive_umask_still_publishes_readable_records_and_retained_lock(self):
        root = self.state.open_state(self.home, create=True)
        previous = os.umask(0o777)
        try:
            self.state.write_json(root/'cache.json', {'schema': 1})
            with self.state.lock(root, blocking=True) as acquired:
                self.assertTrue(acquired)
        finally:
            os.umask(previous)
        for path in [root/'cache.json', root/'lock']:
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(self.state.read_json(root/'cache.json'), {'schema': 1})
        with self.state.lock(root, blocking=False) as acquired:
            self.assertTrue(acquired)
        (root/'lock').chmod(0o644)
        with self.assertRaises(self.state.StateError):
            with self.state.lock(root, blocking=False):
                self.fail('accepted a preexisting public lock')
        self.assertEqual(stat.S_IMODE((root/'lock').stat().st_mode), 0o644)

    def test_private_updater_root_does_not_require_private_consumer_git_files(self):
        root = self.state.open_state(self.home, create=True)
        for path in [self.home, self.home/'.local', self.home/'.local/state']:
            path.chmod(0o755)
        consumer = self.home/'flake.lock'
        consumer.write_text('{"version":7}')
        consumer.chmod(0o644)
        self.assertEqual(self.state.read_json(consumer), {'version': 7})
        self.assertEqual(self.state.open_state(self.home, create=False), root)
        root.chmod(0o755)
        with self.assertRaises(self.state.StateError):
            self.state.open_state(self.home, create=True)
        self.assertEqual(stat.S_IMODE(root.stat().st_mode), 0o755)

    def test_lock_contention_and_cancellation_retain_lock_inode_and_release(self):
        root = self.state.open_state(self.home, create=True)
        context = multiprocessing.get_context('fork')
        queue = context.Queue()
        with self.state.lock(root, blocking=True) as acquired:
            self.assertTrue(acquired)
            inode = (root / 'lock').stat().st_ino
            child = context.Process(target=attempt_lock, args=(str(root), queue))
            child.start()
            self.assertFalse(queue.get(timeout=3))
            child.join(3)
            self.assertEqual(child.exitcode, 0)
        with self.assertRaises(KeyboardInterrupt):
            with self.state.lock(root, blocking=True):
                raise KeyboardInterrupt()
        with self.state.lock(root, blocking=False) as acquired:
            self.assertTrue(acquired)
        self.assertEqual((root / 'lock').stat().st_ino, inode)


if __name__ == '__main__':
    unittest.main()
