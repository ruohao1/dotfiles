"""Candidate isolation uses real Git; Nix is substituted at its process boundary."""
import importlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'nix'))


class CandidateTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix='update-candidate-'))
        self.home = self.root / 'home'
        self.home.mkdir(mode=0o700)
        self.repo = self.root / 'personal host'
        self.repo.mkdir(mode=0o700)
        self.env = {**os.environ, 'HOME': str(self.home), 'GIT_CONFIG_GLOBAL': os.devnull,
                    'GIT_CONFIG_NOSYSTEM': '1'}
        self.release = {'repository': 'ruohao1/dotfiles', 'releaseId': 2,
                        'version': 'v1.2.3', 'commit': 'b' * 40}
        self.lock = {'version': 7, 'root': 'root', 'nodes': {
            'root': {'inputs': {'dotfiles': 'dotfiles'}},
            'dotfiles': {'locked': {'type': 'github', 'owner': 'ruohao1', 'repo': 'dotfiles',
                                     'rev': 'a' * 40}, 'inputs': {'nixpkgs': 'pkgs'}},
            'pkgs': {'locked': {'type': 'github', 'owner': 'NixOS', 'repo': 'nixpkgs', 'rev': 'c'*40}}}}
        (self.repo / 'flake.nix').write_text('{ outputs = _: {}; }\n')
        (self.repo / 'flake.lock').write_text(json.dumps(self.lock))
        (self.repo / 'host.nix').write_text('{ home.sessionVariables.PERSONAL = "keep"; }\n')
        (self.repo / 'dotfiles-release.json').write_text(json.dumps(dict(self.release, releaseId=1, version='v1.0.0', commit='a'*40)))
        self.git('init', '-q')
        self.git('add', '.')
        self.git('commit', '-qm', 'personal host')
        self.upstream = self.root / 'upstream'
        self.upstream.mkdir(mode=0o700)
        (self.upstream / 'flake.lock').write_text(json.dumps({'version': 7, 'root': 'root', 'nodes': {
            'root': {'inputs': {'nixpkgs': 'pkgs'}}, 'pkgs': self.lock['nodes']['pkgs']}}))

    def git(self, *args, root=None):
        return subprocess.check_output(['git', '-c', 'user.name=Fixture', '-c',
            'user.email=fixture@example.invalid', '-C', str(root or self.repo), *args],
            env=self.env, text=True).strip()

    def module(self):
        self.assertTrue((ROOT/'nix/update/deployment.py').exists(), 'candidate preparation is not implemented')
        return importlib.import_module('update.deployment')

    def fake_nix(self, args, environment):
        if args[:2] == ['flake', 'metadata']:
            return json.dumps({'path': '/nix/store/'+'a'*32+'-unmaterialized-source',
                'revision': args[-1].split('/')[-1],
                'locks': json.loads((self.upstream/'flake.lock').read_text())})
        if args[:2] == ['flake', 'update']:
            candidate = Path(args[args.index('--flake')+1])
            value = json.loads((candidate/'flake.lock').read_text())
            value['nodes']['dotfiles']['locked']['rev'] = 'b'*40
            (candidate/'flake.lock').write_text(json.dumps(value))
            return ''
        if args[0] == 'build':
            link = Path(args[args.index('--out-link')+1])
            link.symlink_to('/nix/store/'+'f'*32+'-dotfiles-executor')
            return str(link.readlink())+'\n'
        self.fail('unexpected Nix operation: '+repr(args))

    def test_preparation_preserves_host_and_original_checkout(self):
        module = self.module()
        from update.state import open_state
        before = self.git('rev-parse', 'HEAD')
        with patch.dict(os.environ, self.env, clear=True), patch.object(module, '_nix', self.fake_nix), \
             patch.object(module, '_executor', return_value='/nix/store/'+'f'*32+'-dotfiles-executor'):
            candidate = module.prepare(self.repo, 'myhost', self.release, open_state(self.home, create=True))
        checkout = Path(candidate['sourceRoot'])
        self.assertEqual(self.git('rev-parse', 'HEAD'), before)
        self.assertEqual(self.git('status', '--porcelain'), '')
        self.assertEqual((checkout/'host.nix').read_bytes(), (self.repo/'host.nix').read_bytes())
        self.assertEqual(set(self.git('diff', '--name-only', before, candidate['sourceCommit'], root=checkout).splitlines()),
                         {'flake.lock', 'dotfiles-release.json'})
        self.assertEqual(json.loads((checkout/'dotfiles-release.json').read_text()), self.release)
        self.assertTrue(Path(candidate['rootLink']).is_symlink())
        self.assertNotEqual(checkout, self.repo)

    def test_missing_executor_is_refused(self):
        module = self.module()
        from update.state import open_state
        with patch.dict(os.environ, self.env, clear=True), patch.object(module, '_nix', self.fake_nix):
            with self.assertRaises((OSError, RuntimeError)):
                module.prepare(self.repo, 'myhost', self.release, open_state(self.home, create=True))

    def test_flake_false_override_and_untracked_receipt_are_refused(self):
        module = self.module()
        from update import UpdateError
        from update.state import open_state
        self.lock['nodes']['pkgs']['flake'] = False
        (self.repo/'flake.lock').write_text(json.dumps(self.lock))
        self.git('add', '.')
        self.git('commit', '-qm', 'dependency semantics override')
        with patch.dict(os.environ, self.env, clear=True), patch.object(module, '_nix', self.fake_nix):
            with self.assertRaisesRegex(UpdateError, 'override'):
                module.prepare(self.repo, 'myhost', self.release, open_state(self.home, create=True))
        self.git('rm', '--cached', 'dotfiles-release.json')
        self.git('commit', '-qm', 'untracked receipt')
        with patch.dict(os.environ, self.env, clear=True), patch.object(module, '_nix', self.fake_nix):
            with self.assertRaisesRegex(UpdateError, 'tracked regular'):
                module.prepare(self.repo, 'myhost', self.release, open_state(self.home, create=True))

    def test_clone_does_not_copy_local_hooks_or_config(self):
        module = self.module()
        from update.state import open_state
        marker = self.root/'hook-ran'
        hook = self.repo/'.git/hooks/post-checkout'
        hook.write_text('#!/bin/sh\ntouch '+str(marker)+'\n')
        hook.chmod(0o700)
        self.git('config', 'fixture.private', 'not-for-candidate')
        with patch.dict(os.environ, self.env, clear=True), patch.object(module, '_nix', self.fake_nix), \
             patch.object(module, '_executor', return_value='/nix/store/'+'f'*32+'-dotfiles-executor'):
            candidate = module.prepare(self.repo, 'myhost', self.release, open_state(self.home, create=True))
        self.assertFalse(marker.exists())
        self.assertNotIn('not-for-candidate', (Path(candidate['sourceRoot'])/'.git/config').read_text())

    def test_submodules_and_unsafe_candidate_directory_are_refused(self):
        module = self.module()
        from update.state import open_state
        self.git('-c', 'protocol.file.allow=always', 'submodule', 'add', '--quiet', str(self.repo), 'component')
        self.git('commit', '-qm', 'unsupported submodule')
        with patch.dict(os.environ, self.env, clear=True), patch.object(module, '_nix', self.fake_nix):
            root = open_state(self.home, create=True)
            with self.assertRaisesRegex(RuntimeError, 'submodules'):
                module.prepare(self.repo, 'myhost', self.release, root)
        # Return to the already-retained clean pre-submodule commit in another
        # fixture, without changing or cleaning the submodule repository.
        self.setUp()
        outside = self.root/'outside'
        outside.mkdir(mode=0o700)
        with patch.dict(os.environ, self.env, clear=True), patch.object(module, '_nix', self.fake_nix):
            root = open_state(self.home, create=True)
            (root/'candidates').symlink_to(outside)
            with self.assertRaises(RuntimeError):
                module.prepare(self.repo, 'myhost', self.release, root)
        self.assertEqual(list(outside.iterdir()), [])

    def test_dirty_source_fails_before_candidate_or_nix(self):
        module = self.module()
        from update import UpdateError
        from update.state import open_state
        (self.repo/'host.nix').write_text('uncommitted personal changes')
        with patch.dict(os.environ, self.env, clear=True), patch.object(module, '_nix', side_effect=AssertionError('Nix must not run')):
            with self.assertRaises((ValueError, UpdateError)):
                module.prepare(self.repo, 'myhost', self.release, open_state(self.home, create=True))

    def test_transitive_override_is_refused_before_clone(self):
        module = self.module()
        from update import UpdateError
        from update.state import open_state
        changed = json.loads(json.dumps(self.lock))
        changed['nodes']['pkgs']['locked']['rev'] = 'd'*40
        (self.repo/'flake.lock').write_text(json.dumps(changed))
        self.git('add', 'flake.lock')
        self.git('commit', '-qm', 'override')
        with patch.dict(os.environ, self.env, clear=True), patch.object(module, '_nix', self.fake_nix):
            with self.assertRaisesRegex(UpdateError, 'override'):
                module.prepare(self.repo, 'myhost', self.release, open_state(self.home, create=True))

    def test_receipt_and_lock_must_agree(self):
        module = self.module()
        from update import UpdateError
        from update.state import open_state
        (self.repo/'dotfiles-release.json').write_text(json.dumps(self.release))
        self.git('add', '.')
        self.git('commit', '-qm', 'mismatched receipt')
        with patch.dict(os.environ, self.env, clear=True), patch.object(module, '_nix', self.fake_nix):
            with self.assertRaisesRegex(UpdateError, 'receipt'):
                module.prepare(self.repo, 'myhost', self.release, open_state(self.home, create=True))
