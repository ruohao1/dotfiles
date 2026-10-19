"""Bounded public GitHub metadata checks; no source download or code execution."""
from contextlib import contextmanager
from email.utils import parsedate_to_datetime
import math
import http.client
from pathlib import Path
import re
import signal
import time
import urllib.error
import urllib.request

from . import UpdateError, state

REPOSITORY = 'ruohao1/dotfiles'
API = 'https://api.github.com/repos/' + REPOSITORY
DAILY = 86400
HTTP_BUDGET = 20
MAX_BODY = 1024 * 1024
MAX_TAGS = 8
VERSION = re.compile(r'v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)')
COMMIT = re.compile(r'[a-f0-9]{40}')


class ReleaseError(UpdateError):
    """Release metadata is unavailable or malformed."""


class ReleaseConflict(ReleaseError):
    """A previously observed or reviewed release changed identity."""


def version_tuple(version):
    if not isinstance(version, str) or len(version) > 128 or not VERSION.fullmatch(version):
        raise ReleaseError('updates: invalid stable release version')
    return tuple(int(part) for part in version[1:].split('.'))


def validate_record(record):
    fields = {'repository', 'releaseId', 'version', 'commit'}
    if (not isinstance(record, dict) or set(record) != fields
            or record['repository'] != REPOSITORY or type(record['releaseId']) is not int
            or record['releaseId'] <= 0 or not isinstance(record['commit'], str)
            or not COMMIT.fullmatch(record['commit'])):
        raise ReleaseError('updates: invalid release identity')
    version_tuple(record['version'])
    return dict(record)


def parse_release(payload, commit):
    if (not isinstance(payload, dict) or payload.get('draft') is not False
            or payload.get('prerelease') is not False):
        raise ReleaseError('updates: release is not a published stable release')
    return validate_record({'repository': REPOSITORY, 'releaseId': payload.get('id'),
                            'version': payload.get('tag_name'), 'commit': commit})


def is_newer(available, installed):
    available = validate_record(available)
    if installed is None:
        return False  # An unversioned deployment needs explicit adoption, not a guessed upgrade.
    installed = validate_record(installed)
    return version_tuple(available['version']) > version_tuple(installed['version'])


def _empty_cache():
    return {'schema': 1, 'lastAttempt': None, 'lastSuccess': None, 'nextAttempt': 0,
            'rateLimitUntil': 0, 'etag': None, 'release': None}


def _timestamp(value):
    try:
        return type(value) in (int, float) and math.isfinite(value) and value >= 0
    except OverflowError:
        return False


def _etag(value):
    return (isinstance(value, str) and len(value) <= 1024
            and re.fullmatch(r'(?:W/)?"[\x21\x23-\x7e]*"', value) is not None)


def read_cache(root):
    """Malformed data is unknown; unsafe filesystem state always raises."""
    try:
        cache = state.read_json(Path(root) / 'cache.json')
        if set(cache) != set(_empty_cache()) or type(cache['schema']) is not int or cache['schema'] != 1:
            return _empty_cache()
        if any(cache[key] is not None and not _timestamp(cache[key]) for key in ('lastAttempt', 'lastSuccess')):
            return _empty_cache()
        if not all(_timestamp(cache[key]) for key in ('nextAttempt', 'rateLimitUntil')):
            return _empty_cache()
        if cache['etag'] is not None and not _etag(cache['etag']):
            return _empty_cache()
        if cache['release'] is not None:
            validate_record(cache['release'])
        return cache
    except (FileNotFoundError, state.InvalidJSON, ReleaseError):
        return _empty_cache()


def _history(root):
    try:
        history = state.read_json(root / 'identities.json')
    except FileNotFoundError:
        return []
    except state.InvalidJSON as error:
        raise ReleaseConflict('updates: release identity history is malformed or exceeds the state limit') from error
    if (set(history) != {'schema', 'records'} or type(history['schema']) is not int
            or history['schema'] != 1 or not isinstance(history['records'], list)):
        raise ReleaseConflict('updates: malformed release identity history')
    ids, versions = {}, {}
    for record in history['records']:
        try:
            validate_record(record)
        except ReleaseError as error:
            raise ReleaseConflict('updates: invalid retained release identity') from error
        if ((record['releaseId'] in ids and ids[record['releaseId']] != record)
                or (record['version'] in versions and versions[record['version']] != record)):
            raise ReleaseConflict('updates: conflicting retained release identities')
        ids[record['releaseId']] = record
        versions[record['version']] = record
    return history['records']


def _remember(root, history, record):
    if record is None:
        return
    for previous in history:
        if previous['releaseId'] == record['releaseId'] or previous['version'] == record['version']:
            if previous != record:
                raise ReleaseConflict('updates: previously observed release identity changed')
            return
    history.append(record)
    try:
        state.write_json(root / 'identities.json', {'schema': 1, 'records': history})
    except state.InvalidJSON as error:
        raise ReleaseConflict('updates: release identity history exceeds the state limit; preserve it for recovery') from error


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class _HTTPFailure(ReleaseError):
    def __init__(self, status, headers):
        super().__init__('updates: GitHub metadata request failed (HTTP %s)' % status)
        self.status = status
        self.headers = headers


@contextmanager
def _budget():
    """Interrupt DNS and slow reads too; all command entrypoints run on the main thread."""
    def expired(_signum, _frame):
        raise ReleaseError('updates: release metadata deadline exceeded')
    started = time.monotonic()
    previous = signal.getsignal(signal.SIGALRM)
    timer = signal.getitimer(signal.ITIMER_REAL)
    signal.signal(signal.SIGALRM, expired)
    signal.setitimer(signal.ITIMER_REAL, min(HTTP_BUDGET, timer[0]) if timer[0] else HTTP_BUDGET)
    try:
        yield started + HTTP_BUDGET
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)
        if timer[0]:
            signal.setitimer(signal.ITIMER_REAL, max(0.000001, timer[0] - (time.monotonic() - started)), timer[1])


class _Client:
    def __init__(self, deadline):
        self.deadline = deadline
        self.opener = urllib.request.build_opener(_NoRedirect())

    def get(self, path, *, etag=None):
        # Never follow server-supplied URLs or redirects, including annotated-tag URLs.
        if not re.fullmatch(r'/releases/(?:latest|[1-9][0-9]*)|/git/ref/tags/v[0-9.]+|/git/tags/[a-f0-9]{40}', path):
            raise ReleaseError('updates: unsupported metadata endpoint')
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise ReleaseError('updates: release metadata deadline exceeded')
        headers = {'Accept': 'application/vnd.github+json', 'User-Agent': 'dotfiles-update',
                   'X-GitHub-Api-Version': '2026-03-10'}
        if etag is not None:
            if path != '/releases/latest' or not _etag(etag):
                raise ReleaseError('updates: invalid conditional request')
            headers['If-None-Match'] = etag
        request = urllib.request.Request(API + path, headers=headers)
        try:
            with self.opener.open(request, timeout=remaining) as response:
                status = response.status
                response_headers = response.headers
                if status == 304:
                    if path != '/releases/latest' or etag is None:
                        raise ReleaseError('updates: unsolicited conditional response')
                    return status, None, response_headers
                if status != 200:
                    raise _HTTPFailure(status, response_headers)
                data = response.read(MAX_BODY + 1)
        except urllib.error.HTTPError as error:
            with error:
                if error.code == 304:
                    if path != '/releases/latest' or etag is None:
                        raise ReleaseError('updates: unsolicited conditional response')
                    return 304, None, error.headers
                raise _HTTPFailure(error.code, error.headers) from error
        except (OSError, urllib.error.URLError, http.client.HTTPException) as error:
            raise ReleaseError('updates: release metadata unavailable') from error
        if len(data) > MAX_BODY:
            raise ReleaseError('updates: release metadata exceeds size limit')
        try:
            return 200, state.decode_json(data), response_headers
        except state.InvalidJSON as error:
            raise ReleaseError('updates: malformed release metadata') from error

    def resolve(self, version):
        version_tuple(version)
        _, payload, _ = self.get('/git/ref/tags/' + version)
        if 'ref' in payload and payload['ref'] != 'refs/tags/' + version:
            raise ReleaseConflict('updates: GitHub returned a different tag')
        seen = set()
        for depth in range(MAX_TAGS + 1):
            obj = payload.get('object')
            if (not isinstance(obj, dict) or not isinstance(obj.get('sha'), str)
                    or not COMMIT.fullmatch(obj['sha'])):
                raise ReleaseError('updates: malformed Git tag target')
            if obj.get('type') == 'commit':
                return obj['sha']
            if obj.get('type') != 'tag' or depth == MAX_TAGS or obj['sha'] in seen:
                raise ReleaseError('updates: unsupported or excessive annotated-tag chain')
            seen.add(obj['sha'])
            _, payload, _ = self.get('/git/tags/' + obj['sha'])
            if 'sha' in payload and payload['sha'] != obj['sha']:
                raise ReleaseConflict('updates: GitHub returned a different annotated tag')
        raise ReleaseError('updates: cannot resolve release tag')


def _backoff(headers, now):
    deadlines = [0]
    retry = headers.get('Retry-After')
    reset = headers.get('X-RateLimit-Reset')
    if isinstance(retry, str) and len(retry) <= 128:
        try:
            deadlines.append(now + int(retry) if retry.isascii() and retry.isdecimal()
                             else parsedate_to_datetime(retry).timestamp())
        except (ValueError, TypeError, OverflowError):
            pass
    if isinstance(reset, str) and len(reset) <= 16 and reset.isascii() and reset.isdecimal():
        deadlines.append(int(reset))
    return max(deadline for deadline in deadlines if _timestamp(deadline))


def check(root, *, force=False):
    """Refresh metadata under the caller-held updater lock; transient errors retain cache."""
    root = Path(root)
    cache = read_cache(root)
    now = time.time()
    if cache['lastAttempt'] is not None and now < cache['lastAttempt']:
        cache['lastAttempt'] = now
        cache['nextAttempt'] = max(now + DAILY, cache['rateLimitUntil'])
        state.write_json(root / 'cache.json', cache)
    if now < cache['rateLimitUntil'] or (not force and now < cache['nextAttempt']):
        return cache['release']
    cache['lastAttempt'] = now
    cache['nextAttempt'] = max(now + DAILY, cache['rateLimitUntil'])
    state.write_json(root / 'cache.json', cache)
    history = _history(root)
    _remember(root, history, cache['release'])
    try:
        with _budget() as deadline:
            client = _Client(deadline)
            status, payload, headers = client.get('/releases/latest', etag=cache['etag'])
            if status == 304:
                if cache['release'] is None:
                    raise ReleaseError('updates: conditional response without a cached release')
                release = dict(cache['release'], commit=client.resolve(cache['release']['version']))
            else:
                # Validate before using even a tag name to construct another request.
                preliminary = parse_release(payload, '0' * 40)
                release = parse_release(payload, client.resolve(preliminary['version']))
            _remember(root, history, release)
            cache['release'] = release
            cache['lastSuccess'] = time.time()
            if status == 200:
                cache['etag'] = headers.get('ETag') if _etag(headers.get('ETag')) else None
    except _HTTPFailure as error:
        if error.status in (403, 429):
            cache['rateLimitUntil'] = max(cache['rateLimitUntil'], _backoff(error.headers, now))
            cache['nextAttempt'] = max(cache['nextAttempt'], cache['rateLimitUntil'])
    except ReleaseConflict:
        raise
    except ReleaseError:
        pass
    state.write_json(root / 'cache.json', cache)
    return cache['release']


def validate_exact(record):
    """Fresh identity/eligibility check for the reviewed release; never substitute Latest."""
    record = validate_record(record)
    with _budget() as deadline:
        client = _Client(deadline)
        try:
            _, payload, _ = client.get('/releases/' + str(record['releaseId']))
        except _HTTPFailure as error:
            if error.status == 404:
                raise ReleaseConflict('updates: reviewed release no longer exists') from error
            raise
        try:
            preliminary = parse_release(payload, record['commit'])
        except ReleaseError as error:
            raise ReleaseConflict('updates: reviewed release is no longer eligible') from error
        if preliminary != record:
            raise ReleaseConflict('updates: reviewed release ID or tag changed')
        try:
            commit = client.resolve(record['version'])
        except _HTTPFailure as error:
            if error.status == 404:
                raise ReleaseConflict('updates: reviewed tag no longer exists') from error
            raise
        if commit != record['commit']:
            raise ReleaseConflict('updates: reviewed release commit changed')
    return record
