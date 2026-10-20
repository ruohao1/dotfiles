"""Private fixed-home updater state, atomic JSON, and one retained process lock."""
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import secrets
import stat

from . import UpdateError

MAX_JSON_BYTES = 16 * 1024 * 1024
MAX_PLAN_BYTES = 64 * 1024 * 1024


class StateError(UpdateError):
    """State has unsafe ownership, permissions, or filesystem structure."""


class InvalidJSON(StateError):
    """A safe regular file does not contain a bounded JSON object."""


def _safe(info, *, directory=False):
    kind = stat.S_ISDIR if directory else stat.S_ISREG
    if not kind(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
        raise StateError('updates: unsafe state ownership, type, or permissions')
    if not directory and info.st_nlink != 1:
        raise StateError('updates: hard-linked state file')


@contextmanager
def _directory(path):
    path = Path(path)
    if not path.is_absolute() or '..' in path.parts:
        raise StateError('updates: state path must be absolute without traversal')
    descriptor = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        try:
            for part in path.parts[1:]:
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
                os.close(descriptor)
                descriptor = child
        except FileNotFoundError:
            raise
        except OSError as error:
            raise StateError('updates: inaccessible or symlinked state directory') from error
        _safe(os.fstat(descriptor), directory=True)
        yield descriptor
    finally:
        os.close(descriptor)


def open_state(home, *, create):
    home = Path(home)
    if home == Path('/'):
        raise StateError('updates: HOME must not be root')
    with _directory(home):
        pass
    path = home
    missing = False
    for part in ('.local', 'state', 'dotfiles-update'):
        path = path / part
        if create:
            try:
                path.mkdir(mode=0o700)
                os.chmod(path, 0o700, follow_symlinks=False)
            except FileExistsError:
                pass
            except OSError as error:
                raise StateError('updates: cannot create private state directory') from error
        elif missing or not os.path.lexists(path):
            missing = True
            continue
        with _directory(path) as descriptor:
            if part == 'dotfiles-update' and stat.S_IMODE(os.fstat(descriptor).st_mode) != 0o700:
                raise StateError('updates: updater state root must have mode 0700')
    return path


def _object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate JSON key')
        result[key] = value
    return result


def _invalid_constant(value):
    raise ValueError('non-finite JSON number')


def decode_json(data):
    try:
        value = json.loads(data, object_pairs_hook=_object, parse_constant=_invalid_constant)
        if not isinstance(value, dict):
            raise ValueError('JSON root must be an object')
        return value
    except (ValueError, UnicodeError, RecursionError) as error:
        raise InvalidJSON('updates: malformed JSON object') from error


def read_json(path, *, limit=MAX_JSON_BYTES):
    path = Path(path)
    with _directory(path.parent) as parent:
        try:
            fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
            with os.fdopen(fd, 'rb') as stream:
                info = os.fstat(stream.fileno())
                _safe(info)
                if info.st_size > limit:
                    raise InvalidJSON('updates: JSON exceeds size limit')
                data = stream.read(limit + 1)
        except FileNotFoundError:
            raise
        except OSError as error:
            raise StateError('updates: inaccessible or symlinked state file') from error
    if len(data) > limit:
        raise InvalidJSON('updates: JSON exceeds size limit')
    return decode_json(data)


def _check_target(parent, name):
    try:
        _safe(os.stat(name, dir_fd=parent, follow_symlinks=False))
    except FileNotFoundError:
        pass


def write_json(path, value, *, limit=MAX_JSON_BYTES):
    if not isinstance(value, dict):
        raise InvalidJSON('updates: JSON root must be an object')
    try:
        data = (json.dumps(value, sort_keys=True, indent=2, allow_nan=False) + '\n').encode('utf-8')
    except (ValueError, TypeError, UnicodeError, RecursionError) as error:
        raise InvalidJSON('updates: invalid JSON value') from error
    if len(data) > limit:
        raise InvalidJSON('updates: JSON exceeds size limit')
    path = Path(path)
    with _directory(path.parent) as parent:
        _check_target(parent, path.name)
        name = '.' + path.name + '-' + secrets.token_hex(12)
        try:
            fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent)
            with os.fdopen(fd, 'wb') as stream:
                os.fchmod(stream.fileno(), 0o600)
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
            _check_target(parent, path.name)
            os.replace(name, path.name, src_dir_fd=parent, dst_dir_fd=parent)
            os.fsync(parent)
        except OSError as error:
            raise StateError('updates: cannot publish private state') from error
        finally:
            try:
                os.unlink(name, dir_fd=parent)
            except FileNotFoundError:
                pass


@contextmanager
def lock(root, *, blocking):
    with _directory(root) as parent:
        if stat.S_IMODE(os.fstat(parent).st_mode) != 0o700:
            raise StateError('updates: updater state root must have mode 0700')
        flags = os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK
        try:
            try:
                fd = os.open('lock', flags | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=parent)
                created = True
            except FileExistsError:
                fd = os.open('lock', flags, dir_fd=parent)
                created = False
        except OSError as error:
            raise StateError('updates: cannot open retained updater lock') from error
        try:
            if created:
                os.fchmod(fd, 0o600)
            info = os.fstat(fd)
            _safe(info)
            if stat.S_IMODE(info.st_mode) != 0o600:
                raise StateError('updates: retained updater lock must have mode 0600')
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
            except BlockingIOError:
                yield False
                return
            named = os.stat('lock', dir_fd=parent, follow_symlinks=False)
            opened = os.fstat(fd)
            if (named.st_dev, named.st_ino) != (opened.st_dev, opened.st_ino):
                raise StateError('updates: updater lock was replaced')
            yield True
        finally:
            os.close(fd)
