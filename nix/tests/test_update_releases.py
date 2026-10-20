"""Fake HTTPS at the transport boundary; real release/cache/state validation."""
import importlib
import http.client
import io
import json
import multiprocessing
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError, URLError

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'nix'))
COMMIT = 'a' * 40
OTHER = 'b' * 40
RECORD = {'repository': 'ruohao1/dotfiles', 'releaseId': 12, 'version': 'v1.2.3', 'commit': COMMIT}
PAYLOAD = {'id': 12, 'tag_name': 'v1.2.3', 'draft': False, 'prerelease': False,
           'target_commitish': 'main', 'body': '\x1b]0;malicious\x07', 'html_url': 'https://untrusted.invalid'}


class Response(io.BytesIO):
    def __init__(self, value, status=200, headers=None):
        super().__init__(value if isinstance(value, bytes) else json.dumps(value).encode())
        self.status = status
        self.headers = headers or {}


class Transport:
    def __init__(self, responses):
        self.responses = list(responses)
        self.requests = []

    def open(self, request, timeout):
        self.requests.append((request, timeout))
        if not self.responses:
            raise AssertionError('unexpected extra HTTP request')
        response = self.responses.pop(0)
        if isinstance(response, BaseException):
            raise response
        if callable(response):
            return response(request)
        return response


def concurrent_check(root, queue):
    from update import releases, state
    transport = Transport([Response(PAYLOAD), Response({'object': {'type': 'commit', 'sha': COMMIT}})])
    with patch.object(releases.urllib.request, 'build_opener', return_value=transport):
        with state.lock(Path(root), blocking=True):
            record = releases.check(Path(root))
    queue.put((record, len(transport.requests)))


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue((ROOT / 'nix/update/releases.py').is_file(), 'release discovery module missing')
        self.releases = importlib.import_module('update.releases')
        self.state = importlib.import_module('update.state')
        home = Path(tempfile.mkdtemp(prefix='update-release-'))
        self.root = self.state.open_state(home, create=True)
        self.now = 100000.0
        self.clock = patch.object(self.releases.time, 'time', side_effect=lambda: self.now)
        self.clock.start()
        self.addCleanup(self.clock.stop)

    def run_check(self, responses, *, force=False, identities=()):
        transport = Transport(responses)
        with patch.object(self.releases.urllib.request, 'build_opener', return_value=transport), \
                patch.object(subprocess, 'run', side_effect=AssertionError('metadata ran code')):
            with self.state.lock(self.root, blocking=True):
                result = self.releases.check(self.root, force=force, identities=identities)
        return result, transport.requests

    def seed(self):
        return self.run_check([Response(PAYLOAD, headers={'ETag': '"known"'}),
                               Response({'ref': 'refs/tags/v1.2.3', 'object': {'type': 'commit', 'sha': COMMIT}})])

    def test_validated_record_numeric_versions_and_untrusted_text_excluded(self):
        self.assertEqual(self.releases.parse_release(PAYLOAD, COMMIT), RECORD)
        self.assertTrue(self.releases.is_newer(dict(RECORD, version='v1.10.0'), RECORD))
        self.assertFalse(self.releases.is_newer(dict(RECORD, version='v1.2.2'), RECORD))
        self.assertFalse(self.releases.is_newer(RECORD, RECORD))
        for version in ['v01.2.3', 'v1.2.3-rc1', 'v1.2.3\n', 'v1.2.3#(touch /tmp/bad)', '1.2.3']:
            with self.subTest(version=version), self.assertRaises(self.releases.ReleaseError):
                self.releases.parse_release(dict(PAYLOAD, tag_name=version), COMMIT)
        for changes in [{'draft': True}, {'prerelease': True}, {'draft': 0}, {'id': True}, {'id': 0}]:
            with self.subTest(changes=changes), self.assertRaises(self.releases.ReleaseError):
                self.releases.parse_release(dict(PAYLOAD, **changes), COMMIT)
        with self.assertRaises(self.releases.ReleaseError):
            self.releases.validate_record(dict(RECORD, commit=COMMIT.upper()))

    def test_background_throttling_and_attempt_persisted_before_fetch(self):
        def latest(_request):
            cache = self.state.read_json(self.root / 'cache.json')
            self.assertEqual(cache['lastAttempt'], 100000)
            self.assertEqual(cache['nextAttempt'], 186400)
            return Response(PAYLOAD, headers={'ETag': '"known"'})
        record, requests = self.run_check([latest, Response({'object': {'type': 'commit', 'sha': COMMIT}})])
        self.assertEqual(record, RECORD)
        self.assertEqual(len(requests), 2)
        self.assertTrue(all(0 < timeout <= 20 for _, timeout in requests))
        record, requests = self.run_check([])
        self.assertEqual(record, RECORD)
        self.assertEqual(requests, [])
        self.assertEqual(self.state.read_json(self.root / 'cache.json')['lastSuccess'], 100000)

    def test_annotated_tag_resolution_and_bounded_traversal(self):
        record, requests = self.run_check([Response(PAYLOAD),
            Response({'object': {'type': 'tag', 'sha': OTHER}}),
            Response({'sha': OTHER, 'object': {'type': 'commit', 'sha': COMMIT}})])
        self.assertEqual(record, RECORD)
        self.assertEqual(requests[-1][0].full_url, 'https://api.github.com/repos/ruohao1/dotfiles/git/tags/' + OTHER)
        self.now += 86400
        responses = [Response(PAYLOAD), Response({'object': {'type': 'tag', 'sha': OTHER}})]
        responses += [Response({'object': {'type': 'tag', 'sha': '%040x' % number}}) for number in range(1, 10)]
        record, requests = self.run_check(responses)
        self.assertEqual(record, RECORD)
        self.assertLessEqual(len(requests), 10)
        self.assertEqual(self.state.read_json(self.root / 'cache.json')['lastSuccess'], 100000)

    def test_304_reresolves_tag_and_conflict_keeps_prior_release(self):
        self.seed()
        self.now += 86400
        record, requests = self.run_check([Response(b'', 304), Response({'object': {'type': 'commit', 'sha': COMMIT}})])
        self.assertEqual(record, RECORD)
        self.assertEqual(requests[0][0].get_header('If-none-match'), '"known"')
        self.assertIsNone(requests[1][0].get_header('If-none-match'))
        self.now += 86400
        with self.assertRaises(self.releases.ReleaseConflict):
            self.run_check([Response(b'', 304), Response({'object': {'type': 'commit', 'sha': OTHER}})])
        cache = self.state.read_json(self.root / 'cache.json')
        self.assertEqual(cache['release'], RECORD)
        self.assertEqual(cache['lastSuccess'], 186400)
        self.assertEqual(cache['nextAttempt'], 359200)

    def test_network_failures_404_invalid_and_oversized_keep_cache_and_throttle(self):
        self.seed()
        for response in [Response(b'', 404), URLError('offline'), TimeoutError('timeout'),
                         Response(b'{'), Response(b'x' * (1024 * 1024 + 1)), Response({'id': 12}),
                         Response(dict(PAYLOAD, prerelease=True)), Response({'id': 12, 'draft': False}, 302)]:
            self.now += 86400
            with self.subTest(response=type(response).__name__):
                record, _ = self.run_check([response])
                self.assertEqual(record, RECORD)
                cache = self.state.read_json(self.root / 'cache.json')
                self.assertEqual(cache['lastSuccess'], 100000)
                self.assertEqual(cache['nextAttempt'], self.now + 86400)
                self.assertEqual(self.run_check([])[1], [])

    def test_truncated_chunked_http_body_retains_cache_and_attempt_throttle(self):
        self.seed()
        self.now += 86400
        class Socket:
            def makefile(self, *args):
                return io.BytesIO(b'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n10\r\nabc')
        response = http.client.HTTPResponse(Socket())
        response.begin()
        record, requests = self.run_check([response])
        self.assertEqual(record, RECORD)
        self.assertEqual(len(requests), 1)
        cache = self.state.read_json(self.root/'cache.json')
        self.assertEqual(cache['lastSuccess'], 100000)
        self.assertEqual(cache['nextAttempt'], self.now + 86400)
        self.assertEqual(self.run_check([])[1], [])

    def test_rate_limits_persist_backoff_and_explicit_check_cannot_bypass(self):
        self.seed()
        self.now += 86400
        error = HTTPError('https://api.github.com/', 429, 'limited', {'Retry-After': '200000'}, None)
        self.run_check([error])
        cache = self.state.read_json(self.root / 'cache.json')
        self.assertEqual(cache['rateLimitUntil'], 386400)
        self.assertEqual(cache['nextAttempt'], 386400)
        self.assertEqual(self.run_check([], force=True)[1], [])
        self.now = 386401
        self.run_check([Response(b'', 403, {'X-RateLimit-Reset': '600000'})], force=True)
        self.assertEqual(self.state.read_json(self.root / 'cache.json')['rateLimitUntil'], 600000)

    def test_clock_regression_rebases_daily_window_preserving_server_backoff(self):
        self.seed()
        self.now = 99900
        self.assertEqual(self.run_check([])[1], [])
        cache = self.state.read_json(self.root / 'cache.json')
        self.assertEqual(cache['lastAttempt'], 99900)
        self.assertEqual(cache['nextAttempt'], 186300)
        self.run_check([Response(b'', 429, {'Retry-After': '200000'})], force=True)
        self.now = 99000
        self.assertEqual(self.run_check([])[1], [])
        cache = self.state.read_json(self.root / 'cache.json')
        self.assertEqual(cache['rateLimitUntil'], 299900)
        self.assertEqual(cache['nextAttempt'], 299900)

    def test_malformed_cache_retries_but_unsafe_file_is_not_overwritten(self):
        cache = self.root / 'cache.json'
        cache.write_text('{')
        cache.chmod(0o600)
        self.assertIsNone(self.releases.read_cache(self.root)['release'])
        record, requests = self.run_check([Response(b'', 404)])
        self.assertIsNone(record)
        self.assertEqual(len(requests), 1)
        self.assertEqual(self.run_check([])[1], [])
        cache.unlink()
        target = self.root / 'untouched'
        target.write_text('{}')
        cache.symlink_to(target)
        with self.assertRaises(self.state.StateError):
            self.run_check([])
        self.assertEqual(target.read_text(), '{}')

    def test_malformed_cache_scalars_cannot_crash_or_supply_a_header(self):
        self.seed()
        original = self.state.read_json(self.root / 'cache.json')
        for changes in [{'nextAttempt': 10 ** 1000}, {'schema': True}, {'lastAttempt': True},
                        {'etag': '"ok"\r\nAuthorization: secret'}, {'release': dict(RECORD, version='v1.0.0\n')}]:
            with self.subTest(changes=list(changes)):
                self.state.write_json(self.root / 'cache.json', dict(original, **changes))
                record, requests = self.run_check([Response(b'', 404)])
                self.assertIsNone(record)
                self.assertIsNone(requests[0][0].get_header('If-none-match'))

    def test_two_processes_share_one_due_metadata_refresh(self):
        context = multiprocessing.get_context('fork')
        queue = context.Queue()
        children = [context.Process(target=concurrent_check, args=(str(self.root), queue)) for _ in range(2)]
        for child in children:
            child.start()
        results = [queue.get(timeout=3) for _ in children]
        for child in children:
            child.join(3)
            self.assertEqual(child.exitcode, 0)
        self.assertEqual(sorted(count for _, count in results), [0, 2])
        self.assertTrue(all(record == RECORD for record, _ in results))

    def test_redirects_and_malicious_tags_never_escape_fixed_api(self):
        self.assertIsNone(self.releases._NoRedirect().redirect_request(None, None, 302, '', {}, 'https://elsewhere.invalid'))
        for payload in [dict(PAYLOAD, tag_name='../../elsewhere'), dict(PAYLOAD, tag_name='v1.2.3?x=y')]:
            self.now += 86400
            record, requests = self.run_check([Response(payload)])
            self.assertIsNone(record)
            self.assertEqual(len(requests), 1)
        transport = Transport([Response(PAYLOAD), Response({'object': {'type': 'blob', 'sha': COMMIT,
                                                                 'url': 'https://elsewhere.invalid'}})])
        with patch.object(self.releases.urllib.request, 'build_opener', return_value=transport):
            self.assertIsNone(self.releases.check(self.root, force=True))
        self.assertEqual(len(transport.requests), 2)
        for response in [Response(b'', 304), HTTPError('https://api.github.com/', 304, '', {}, None)]:
            self.now += 86400
            record, requests = self.run_check([Response(PAYLOAD), response])
            self.assertIsNone(record)
            self.assertEqual(len(requests), 2)

    def test_http_date_backoff_and_previous_alarm_are_preserved(self):
        self.run_check([Response(b'', 429, {'Retry-After': 'Fri, 09 Jan 1970 00:00:00 GMT'})])
        self.assertEqual(self.state.read_json(self.root / 'cache.json')['rateLimitUntil'], 691200)
        previous = signal.getsignal(signal.SIGALRM)
        timer = signal.getitimer(signal.ITIMER_REAL)
        marker = lambda signum, frame: None
        signal.signal(signal.SIGALRM, marker)
        signal.setitimer(signal.ITIMER_REAL, 10, 2)
        try:
            self.now = 700000
            self.run_check([Response(b'', 404)])
            remaining, interval = signal.getitimer(signal.ITIMER_REAL)
            self.assertGreater(remaining, 9)
            self.assertLessEqual(remaining, 10)
            self.assertEqual(interval, 2)
            self.assertIs(signal.getsignal(signal.SIGALRM), marker)
        finally:
            signal.setitimer(signal.ITIMER_REAL, 0)
            signal.signal(signal.SIGALRM, previous)
            signal.setitimer(signal.ITIMER_REAL, *timer)

    def test_exact_validation_does_not_consult_latest_or_substitute_cached_data(self):
        self.seed()
        transport = Transport([Response(PAYLOAD), Response({'object': {'type': 'commit', 'sha': COMMIT}})])
        with patch.object(self.releases.urllib.request, 'build_opener', return_value=transport):
            self.assertEqual(self.releases.validate_exact(RECORD, self.root), RECORD)
        self.assertEqual(transport.requests[0][0].full_url, 'https://api.github.com/repos/ruohao1/dotfiles/releases/12')
        for payload in [dict(PAYLOAD, id=13), dict(PAYLOAD, tag_name='v1.2.4'), dict(PAYLOAD, draft=True)]:
            transport = Transport([Response(payload)])
            with patch.object(self.releases.urllib.request, 'build_opener', return_value=transport):
                with self.assertRaises(self.releases.ReleaseConflict):
                    self.releases.validate_exact(RECORD, self.root)
        transport = Transport([URLError('offline')])
        with patch.object(self.releases.urllib.request, 'build_opener', return_value=transport):
            with self.assertRaises(self.releases.ReleaseError):
                self.releases.validate_exact(RECORD, self.root)

    def test_exact_validation_respects_and_persists_server_backoff(self):
        self.seed()
        for status, during_tag in [(429, False), (403, True)]:
            self.now += 200000
            responses = [Response(PAYLOAD)] if during_tag else []
            responses.append(Response(b'', status, {'Retry-After': '120000'}))
            transport = Transport(responses)
            with patch.object(self.releases.urllib.request, 'build_opener', return_value=transport):
                with self.assertRaises(self.releases.ReleaseError):
                    self.releases.validate_exact(RECORD, self.root)
            cache = self.releases.read_cache(self.root)
            self.assertEqual(cache['release'], RECORD)
            self.assertEqual(cache['lastAttempt'], self.now)
            self.assertEqual(cache['rateLimitUntil'], self.now + 120000)
            self.assertEqual(cache['nextAttempt'], self.now + 120000)
            blocked = Transport([])
            with patch.object(self.releases.urllib.request, 'build_opener', return_value=blocked):
                with self.assertRaisesRegex(self.releases.ReleaseError, 'backoff'):
                    self.releases.validate_exact(RECORD, self.root)
            self.assertEqual(blocked.requests, [])

    def test_historical_release_identity_survives_latest_moving_away_and_back(self):
        self.seed()
        newer = dict(PAYLOAD, id=13, tag_name='v1.2.4')
        self.now += 86400
        record, _ = self.run_check([Response(newer), Response({'object': {'type': 'commit', 'sha': OTHER}})])
        self.assertEqual(record['version'], 'v1.2.4')
        for payload, commit in [(PAYLOAD, 'c' * 40), (dict(PAYLOAD, id=14), COMMIT),
                                (dict(PAYLOAD, tag_name='v2.0.0'), COMMIT)]:
            self.now += 86400
            with self.assertRaises(self.releases.ReleaseConflict):
                self.run_check([Response(payload), Response({'object': {'type': 'commit', 'sha': commit}})])
            self.assertEqual(self.state.read_json(self.root / 'cache.json')['release'], record)
        history = self.state.read_json(self.root / 'identities.json')
        self.assertEqual(history['records'], [RECORD, record])

    def test_first_check_rejects_changes_to_installed_and_retained_identities(self):
        older = dict(RECORD, releaseId=11, version='v1.0.0', commit='c' * 40)
        for payload, commit in [(dict(PAYLOAD, tag_name='v2.0.0'), OTHER),
                                (PAYLOAD, OTHER), (dict(PAYLOAD, id=13), COMMIT),
                                (dict(PAYLOAD, id=11, tag_name='v3.0.0'), OTHER)]:
            with self.subTest(payload=payload), self.assertRaises(self.releases.ReleaseConflict):
                self.run_check([Response(payload), Response({'object': {'type': 'commit', 'sha': commit}})],
                               force=True, identities=[RECORD, older, None])
        self.assertEqual(self.state.read_json(self.root / 'identities.json')['records'], [RECORD, older])

    def test_known_identity_collision_in_cache_refuses_even_during_backoff(self):
        cache = self.releases._empty_cache()
        cache.update(release=dict(RECORD, version='v2.0.0'), rateLimitUntil=self.now + 1000)
        self.state.write_json(self.root / 'cache.json', cache)
        with self.assertRaises(self.releases.ReleaseConflict):
            self.run_check([], identities=[RECORD])

    def test_corrupt_history_cannot_reset_known_identity_or_trigger_fetch(self):
        self.seed()
        history = self.root / 'identities.json'
        history.write_text('{')
        history.chmod(0o600)
        self.now += 86400
        with self.assertRaises(self.releases.ReleaseConflict):
            self.run_check([])
        self.assertEqual(history.read_text(), '{')
        self.assertEqual(self.state.read_json(self.root / 'cache.json')['nextAttempt'], 272800)

    def test_overall_deadline_interrupts_transport_and_restores_handler(self):
        previous = signal.getsignal(signal.SIGALRM)
        def blocked(_request):
            signal.pause()
            raise AssertionError('deadline failed')
        with patch.object(self.releases, 'HTTP_BUDGET', 0.03):
            record, requests = self.run_check([blocked])
        self.assertIsNone(record)
        self.assertEqual(len(requests), 1)
        self.assertEqual(signal.getsignal(signal.SIGALRM), previous)
        self.assertEqual(signal.getitimer(signal.ITIMER_REAL), (0.0, 0.0))


if __name__ == '__main__':
    unittest.main()
