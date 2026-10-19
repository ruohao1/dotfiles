"""Shared fixed-home ownership protocol and immutable filesystem evidence."""
from contextlib import AbstractContextManager
import hashlib
import fcntl
import json
import os
from pathlib import Path
import re
import stat
import subprocess


class Conflict(RuntimeError):
    """An unsafe deployment state or changed preview input."""


def canonical_home(home):
    path = Path(home)
    if not path.is_absolute() or path == Path('/') or '..' in path.parts:
        raise Conflict('ownership: HOME must be an absolute non-root path without traversal')
    for parent in [path, *path.parents]:
        if parent.is_symlink():
            raise Conflict(f'ownership: symlinked home parent: {parent}')
    safe_directory(path)
    return path.resolve(strict=True)


def safe_directory(path):
    try:
        info = Path(path).lstat()
    except OSError as error:
        raise Conflict(f'ownership: inaccessible directory: {path}') from error
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
        raise Conflict(f'ownership: unsafe directory: {path}')


def ownership_root(home):
    home = canonical_home(home)
    path = home / '.local/state/dotfiles-ownership'
    for parent in [home / '.local', home / '.local/state', path]:
        if parent.exists() or parent.is_symlink():
            safe_directory(parent)
    return path


def read_owner(home):
    root = ownership_root(home)
    path = root / 'owner.json'
    if not path.exists() and not path.is_symlink():
        return None
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd) as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
                raise Conflict('ownership: unsafe owner.json')
            owner = json.load(stream)
    except (OSError, ValueError) as error:
        raise Conflict('ownership: malformed or symlinked owner.json') from error
    fields = {'schema', 'phase', 'home', 'transactionId', 'manifestFingerprint', 'selectedGeneration', 'journalPath'}
    if (not isinstance(owner, dict) or set(owner) != fields or type(owner['schema']) is not int
            or owner['schema'] != 1 or owner['phase'] not in ['transferring', 'home-manager', 'recovering']
            or owner['home'] != str(canonical_home(home))
            or not isinstance(owner['transactionId'], str)
            or not re.fullmatch(r'[A-Za-z0-9._-]+', owner['transactionId'])
            or not isinstance(owner['manifestFingerprint'], str)
            or not re.fullmatch(r'[a-f0-9]{64}', owner['manifestFingerprint'])
            or not isinstance(owner['selectedGeneration'], str)
            or not owner['selectedGeneration'].startswith('/nix/store/')
            or not isinstance(owner['journalPath'], str)
            or not Path(owner['journalPath']).is_relative_to(root / 'transactions')
            or '..' in Path(owner['journalPath']).parts):
        raise Conflict('ownership: owner.json schema or identity mismatch')
    return owner


class HomeLock(AbstractContextManager):
    """Atomic mkdir lock; a crashed transaction requires explicit recovery.

    allow_owner is only for a future explicit activation/recovery operation.
    Legacy deployment never sets it. No stale lock is silently removed.
    """
    def __init__(self, home, *, allow_owner=False, recover=False):
        self.home = canonical_home(home)
        self.root = ownership_root(self.home)
        self.path = self.root / 'lock'
        self.allow_owner = allow_owner
        self.recover = recover
        self.holder = self.root / "lock-holder.json"
        self.holder_state = None
        self.identity = None
        self.descriptor = None
        self.scaffolding = {}
        self.created = set()

    def __enter__(self):
        try:
            return self._acquire()
        except BaseException:
            self.__exit__(None, None, None)
            raise

    def _acquire(self):
        owner = read_owner(self.home)
        if owner is not None and not self.allow_owner:
            raise Conflict('ownership: Home Manager owns this home')
        for directory in [self.home / '.local', self.home / '.local/state', self.root]:
            try:
                directory.mkdir(mode=0o700)
                self.created.add(str(directory))
            except FileExistsError:
                pass
            safe_directory(directory)
            fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            info = os.fstat(fd)
            self.scaffolding[str(directory)] = (fd, info.st_dev, info.st_ino)
        try:
            self.path.mkdir(mode=0o700)
            self.created.add(str(self.path))
        except FileExistsError as error:
            if not self.recover:
                raise Conflict('ownership: another deployer holds the per-home lock') from error
            self._reclaim_dead_lock()
            self.path.mkdir(mode=0o700)
            self.created.add(str(self.path))
        # Keep the directory inode alive even if its name is replaced.
        self.descriptor = os.open(self.path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        info = os.fstat(self.descriptor)
        self.identity = (info.st_dev, info.st_ino)
        self.scaffolding[str(self.path)] = (self.descriptor, *self.identity)
        payload = {'schema': 1, 'home': str(self.home), 'uid': os.getuid(),
                   'pid': os.getpid(), 'start': self._process_start(os.getpid()),
                   'device': info.st_dev, 'inode': info.st_ino}
        fd = os.open(self.holder, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'w') as stream:
            json.dump(payload, stream, sort_keys=True)
            stream.flush()
            os.fsync(stream.fileno())
        self.created.add(str(self.holder))
        self.holder_state = fingerprint(self.holder)
        try:
            self.recheck()
        except Exception:
            self.__exit__(None, None, None)
            raise
        return self

    @staticmethod
    def _process_start(pid):
        if Path('/proc').is_dir():
            try:
                return Path(f'/proc/{pid}/stat').read_text().split(') ', 1)[1].split()[19]
            except FileNotFoundError:
                return None
        result = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'lstart='], capture_output=True, text=True, timeout=5)
        if result.returncode not in [0, 1]:
            raise Conflict('ownership: cannot establish process identity')
        return result.stdout.strip() or None

    def _reclaim_dead_lock(self):
        # Arbitrate on the original inode: a stale contender must never delete
        # a replacement live mkdir lock. Legacy callers keep the same protocol.
        descriptor = os.open(self.path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError as error:
                raise Conflict('ownership: abandoned-lock arbitration unavailable or held') from error
            self._reclaim_dead_lock_held(descriptor)
        finally:
            os.close(descriptor)

    def _reclaim_dead_lock_held(self, descriptor):
        safe_directory(self.path)
        before = os.fstat(descriptor)
        named = self.path.lstat()
        if (named.st_dev, named.st_ino) != (before.st_dev, before.st_ino):
            raise Conflict('ownership: recovery lock was replaced before arbitration')
        try:
            fd = os.open(self.holder, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(fd) as stream:
                info = os.fstat(stream.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                    raise Conflict('ownership: unsafe recovery holder metadata')
                holder = json.load(stream)
        except (OSError, ValueError) as error:
            raise Conflict('ownership: cannot prove abandoned lock; retain for inspection') from error
        if (not isinstance(holder, dict) or holder.get('schema') != 1
                or holder.get('home') != str(self.home) or holder.get('uid') != os.getuid()
                or holder.get('device') != before.st_dev or holder.get('inode') != before.st_ino
                or type(holder.get('pid')) is not int or holder['pid'] <= 0
                or not isinstance(holder.get('start'), str)):
            raise Conflict('ownership: abandoned lock identity mismatch')
        if self._process_start(holder['pid']) == holder['start']:
            raise Conflict('ownership: another deployer still holds the per-home lock')
        current = self.path.lstat()
        if (current.st_dev, current.st_ino) != (before.st_dev, before.st_ino):
            raise Conflict('ownership: recovery lock was replaced')
        # Explicit recovery alone may release the proven-dead Python lock.
        # Unknown legacy locks and locks with extra entries remain untouched.
        if any(self.path.iterdir()):
            raise Conflict('ownership: unexpected abandoned lock contents')
        named_holder = self.holder.lstat()
        if (named_holder.st_dev, named_holder.st_ino) != (info.st_dev, info.st_ino):
            raise Conflict('ownership: recovery holder was replaced')
        self.holder.unlink()
        self.path.rmdir()

    def recheck(self):
        if ownership_root(self.home) != self.root or self.identity is None:
            raise Conflict('ownership: deployment requires its held per-home lock')
        for path, (_, device, inode) in self.scaffolding.items():
            safe_directory(path)
            info = Path(path).lstat()
            if (info.st_dev, info.st_ino) != (device, inode):
                raise Conflict("ownership: held lock scaffolding was replaced")
        safe_directory(self.path)
        info = self.path.lstat()
        if (info.st_dev, info.st_ino) != self.identity:
            raise Conflict('ownership: held lock was replaced')
        if self.holder_state is not None and fingerprint(self.holder) != self.holder_state:
            raise Conflict('ownership: held lock metadata changed')
        owner = read_owner(self.home)
        if owner is not None and not self.allow_owner:
            raise Conflict('ownership: ownership changed while lock was held')

    def reconcile(self, path, observed):
        """Subtract only directory entries created by this still-held lock."""
        self.recheck()
        value = dict(observed)
        if value.get('type') == 'directory':
            value['entries'] = dict(value['entries'])
            for created in self.created:
                child = Path(created)
                if child.parent == Path(path):
                    value['entries'].pop(child.name, None)
            if str(path) in self.created:
                if value['entries']:
                    raise Conflict('preview inputs changed inside lock scaffolding: ' + str(path))
                return {'type': 'absent'}
        return value

    def __exit__(self, *args):
        try:
            if self.identity is not None:
                info = self.path.lstat()
                if stat.S_ISDIR(info.st_mode) and (info.st_dev, info.st_ino) == self.identity:
                    if self.holder_state is not None:
                        if fingerprint(self.holder) != self.holder_state:
                            raise Conflict('ownership: held lock metadata changed at release')
                        self.holder.unlink()
                    self.path.rmdir()
        except FileNotFoundError:
            pass
        finally:
            if self.descriptor is not None:
                os.close(self.descriptor)
                self.descriptor = None
            self.identity = None
            for fd, _, _ in self.scaffolding.values():
                if fd != self.descriptor:
                    try:
                        os.close(fd)
                    except OSError:
                        pass
            self.scaffolding.clear()


def fingerprint(path):
    """Record type, mode, content/link and shallow directory entry evidence."""
    path = Path(path)
    try:
        info = path.lstat()
    except FileNotFoundError:
        return {'type': 'absent'}
    except OSError as error:
        return {'type': 'inaccessible', 'error': str(error)}
    result = {'mode': stat.S_IMODE(info.st_mode), 'uid': info.st_uid, 'gid': info.st_gid}
    if stat.S_ISLNK(info.st_mode):
        result.update(type='symlink', link=os.readlink(path))
        try:
            resolved = path.resolve(strict=True)
            result['resolved'] = str(resolved)
            resolved_info = resolved.stat()
            result['resolvedMode'] = stat.S_IMODE(resolved_info.st_mode)
            result['resolvedUid'] = resolved_info.st_uid
            result['resolvedGid'] = resolved_info.st_gid
            if resolved.is_file():
                result['sha256'] = hashlib.sha256(resolved.read_bytes()).hexdigest()
        except (OSError, RuntimeError):
            result['broken'] = True
    elif stat.S_ISREG(info.st_mode):
        result.update(type='file', sha256=hashlib.sha256(path.read_bytes()).hexdigest())
    elif stat.S_ISDIR(info.st_mode):
        result.update(type='directory', entries={child.name: fingerprint_leaf(child) for child in sorted(path.iterdir())})
    else:
        result['type'] = 'special'
    return result


def fingerprint_leaf(path):
    info = path.lstat()
    if stat.S_ISDIR(info.st_mode):
        return {'type': 'directory', 'mode': stat.S_IMODE(info.st_mode), 'uid': info.st_uid}
    return fingerprint(path)


def manifest_fingerprint(manifest):
    return hashlib.sha256(json.dumps(manifest, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
