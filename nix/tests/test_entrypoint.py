"""Entrypoint source selection and delegation; all homes are disposable."""
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from urllib.parse import parse_qs, unquote, urlsplit

ROOT = Path(os.environ.get('DOTFILES_ENTRYPOINT_SOURCE_ROOT', Path(__file__).resolve().parents[2]))
ENTRY = ROOT / '.config/dotfiles/bootstrap-nix'
PARENT = Path(os.environ.get('DOTFILES_ENTRYPOINT_TEST_ROOT', '/tmp/dotfiles-isq319-tests'))


class EntrypointTests(unittest.TestCase):
    def setUp(self):
        PARENT.mkdir(parents=True, exist_ok=True)
        self.root = Path(tempfile.mkdtemp(prefix='entry-', dir=PARENT))
        self.home = self.root / 'home'
        self.home.mkdir()
        self.cwd = self.root / 'foreign cwd'
        self.cwd.mkdir()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.env = {'HOME': str(self.home), 'PATH': str(self.bin), 'LANG': 'C.UTF-8',
                    'PYTHONDONTWRITEBYTECODE': '1', 'TMPDIR': str(self.root)}
        for name in ['git', 'python3']:
            (self.bin / name).symlink_to(sys.executable if name == 'python3' else shutil.which(name))
        self.log = self.root / 'nix.json'
        (self.bin / 'nix').write_text('#!' + sys.executable + '\nimport json,os,sys\n'
            + 'open(' + repr(str(self.log)) + ',"w").write(json.dumps({"argv":sys.argv[1:],"cwd":os.getcwd()}))\n'
            + 'sys.exit(int(os.environ.get("FIXTURE_EXIT","0")))\n')
        (self.bin / 'nix').chmod(0o755)
        self.repo = self.home / 'src' / 'dot files ü %?#\'$(false)'
        self.repo.mkdir(parents=True)
        self.git('init', '-q')
        (self.repo / 'flake.nix').write_text('{ outputs = _: {}; }\n')
        (self.repo / 'flake.lock').write_text('{"nodes":{"root":{}},"root":"root","version":7}\n')
        self.commit()

    def git(self, *args, cwd=None):
        env = {**self.env, 'GIT_CONFIG_GLOBAL': os.devnull, 'GIT_CONFIG_NOSYSTEM': '1'}
        return subprocess.check_output([str(self.bin / 'git'), '-c', 'user.name=Fixture', '-c',
            'user.email=fixture@example.invalid', *args], cwd=cwd or self.repo, env=env, text=True).strip()

    def commit(self):
        self.git('add', '.')
        self.git('commit', '-qm', 'fixture')

    def run_entry(self, *args, env=None):
        self.assertTrue(ENTRY.is_file(), 'bootstrap-nix entrypoint is missing')
        return subprocess.run([sys.executable, str(ENTRY), *map(str, args)], cwd=self.cwd,
            env=env or self.env, capture_output=True, text=True)

    def invoke(self, *args, root=None, env=None):
        return self.run_entry('--source-root', root or self.repo, '--', *args, env=env)

    def test_help_without_nix_documents_preview_and_explicit_apply(self):
        (self.bin / 'nix').unlink()
        result = self.run_entry('--help')
        self.assertEqual(result.returncode, 0, result.stderr)
        for word in ['Nix', '--source-root', 'plan', 'apply', 'https://nixos.org/download/',
                     'non-shallow', 'git fetch --unshallow']:
            self.assertIn(word, result.stdout)

    def test_missing_nix_never_installs(self):
        (self.bin / 'nix').unlink()
        result = self.invoke('plan', '--profile', 'host', '--output', 'review.json')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('https://nixos.org/download/', result.stderr)
        self.assertFalse(self.log.exists())

    def test_arguments_status_cwd_and_encoded_committed_source(self):
        arguments = ['plan', '--profile', 'unknown', '--output', 'review files/quo\'te $()` ü.json', '--override-input', 'x']
        for status in [0, 1, 2, 7, 42]:
            result = self.invoke(*arguments, env={**self.env, 'FIXTURE_EXIT': str(status)})
            self.assertEqual(result.returncode, status, result.stderr)
            record = json.loads(self.log.read_text())
            self.assertEqual(record['cwd'], str(self.cwd))
            self.assertEqual(record['argv'][:2], ['run', '--no-update-lock-file'])
            self.assertEqual(record['argv'][3:], ['--', *arguments])
            ref = urlsplit(record['argv'][2])
            self.assertEqual(ref.scheme, 'git+file')
            self.assertEqual(unquote(ref.path), str(self.repo))
            self.assertEqual(parse_qs(ref.query), {'rev': [self.git('rev-parse', 'HEAD')]})
            self.assertEqual(ref.fragment, 'dotfiles')

    def test_missing_explicit_root_and_separator_are_usage_errors(self):
        for args in [[], ['plan'], ['--source-root', self.repo, 'plan'], ['--source-root', self.repo, '--']]:
            with self.subTest(args=args):
                self.assertEqual(self.run_entry(*args).returncode, 2)
        self.assertFalse(self.log.exists())

    def test_unsafe_roots_never_reach_nix(self):
        bare = self.home / '.cfg'
        self.git('init', '--bare', '-q', str(bare))
        (self.home / 'secret-sentinel').write_text('synthetic only')
        alias = self.root / 'home-alias'
        alias.symlink_to(self.home)
        export = self.root / 'export'
        export.mkdir()
        (export / 'flake.nix').write_text('{}')
        (export / 'flake.lock').write_text('{}')
        subdir = self.repo / 'child'
        subdir.mkdir()
        for root in [self.home, self.root, bare, alias, export, subdir, self.root / 'missing']:
            with self.subTest(root=root):
                result = self.invoke('--help', root=root)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.log.exists(), result.stderr)
        self.assertEqual((self.home / 'secret-sentinel').read_text(), 'synthetic only')

    def test_alias_and_registered_linked_worktree_are_bounded(self):
        alias = self.root / 'safe-alias'
        alias.symlink_to(self.repo)
        self.assertEqual(self.invoke('--help', root=alias).returncode, 0)
        self.assertEqual(unquote(urlsplit(json.loads(self.log.read_text())['argv'][2]).path), str(self.repo))
        linked = self.root / 'linked ü?#'
        self.git('worktree', 'add', '-q', '-b', 'linked', str(linked))
        result = self.invoke('--help', root=linked)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(unquote(urlsplit(json.loads(self.log.read_text())['argv'][2]).path), str(linked))

    def test_shallow_source_refused_before_nix_without_plan_or_source_mutation(self):
        (self.repo / 'history').write_text('earlier revision exists\n')
        self.commit()
        shallow = self.root / 'shallow source'
        self.git('clone', '-q', '--depth=1', self.repo.as_uri(), str(shallow))
        self.assertEqual(self.git('rev-parse', '--is-shallow-repository', cwd=shallow), 'true')

        def snapshot():
            return {str(path.relative_to(shallow)): (path.lstat().st_mode, path.read_bytes())
                    for path in shallow.rglob('*') if path.is_file()}

        before = snapshot()
        plan = self.cwd / 'review.json'
        for existing in [False, True]:
            with self.subTest(existing_plan=existing):
                if existing:
                    plan.write_bytes(b'existing review must be preserved\n')
                result = self.invoke('plan', '--profile', 'host', '--output', plan, root=shallow)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('shallow', result.stderr.lower())
                self.assertIn('git fetch --unshallow', result.stderr)
                self.assertFalse(self.log.exists(), 'shallow source must never reach Nix')
                self.assertEqual(snapshot(), before)
                if existing:
                    self.assertEqual(plan.read_bytes(), b'existing review must be preserved\n')
                else:
                    self.assertFalse(plan.exists())
                print(json.dumps({'shallowSource': str(shallow), 'existingPlan': existing,
                                  'exit': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr,
                                  'nixDelegated': False, 'sourceUnchanged': True, 'planUnchanged': True}))

    def test_git_environment_cannot_spoof_source(self):
        result = self.invoke('--help', root=self.home, env={**self.env,
            'GIT_DIR': str(self.repo / '.git'), 'GIT_WORK_TREE': str(self.repo),
            'GIT_CONFIG_COUNT': '1', 'GIT_CONFIG_KEY_0': 'core.worktree', 'GIT_CONFIG_VALUE_0': str(self.repo)})
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.log.exists())
        result = self.invoke('--help', env={**self.env, 'GIT_DIR': '/missing', 'GIT_INDEX_FILE': '/missing'})
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_dirty_untracked_or_symlinked_lock_refused(self):
        lock = self.repo / 'flake.lock'
        original = lock.read_bytes()
        lock.write_bytes(original + b' ')
        self.assertNotEqual(self.invoke('--help').returncode, 0)
        self.assertFalse(self.log.exists())
        self.git('add', 'flake.lock')
        self.assertNotEqual(self.invoke('--help').returncode, 0)
        self.assertFalse(self.log.exists())
        self.git('reset', '-q', '--hard', 'HEAD')
        lock.unlink()
        lock.symlink_to(self.home / 'secret-sentinel')
        self.assertNotEqual(self.invoke('--help').returncode, 0)
        self.assertFalse(self.log.exists())
        lock.unlink()
        lock.write_bytes(original)
        self.git('rm', '--cached', '-q', 'flake.lock')
        self.git('commit', '-qm', 'untracked lock')
        self.assertNotEqual(self.invoke('--help').returncode, 0)
        self.assertFalse(self.log.exists())


class PlatformHarnessTests(unittest.TestCase):
    def test_unassigned_account_refused_without_fixture_writes(self):
        root = Path(tempfile.mkdtemp(prefix='unassigned-', dir=PARENT))
        script = ROOT / 'nix/tests/platform-smoke.sh'
        self.assertTrue(script.is_file(), 'platform harness is missing')
        result = subprocess.run([sys.executable, str(script), '--profile', 'fixture', '--fixture-root', str(root)],
                                env={'HOME': str(root), 'PATH': os.defpath}, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('assignment', result.stderr)
        self.assertEqual(list(root.iterdir()), [])

    def test_administrator_parent_alias_is_canonical_but_leaf_alias_stays_visible(self):
        from importlib.machinery import SourceFileLoader
        loader = SourceFileLoader('platform_assignment', str(ROOT / 'nix/tests/platform-smoke.sh'))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        module = importlib.util.module_from_spec(spec)
        loader.exec_module(module)
        root = Path(tempfile.mkdtemp(prefix='assignment-alias-', dir=PARENT))
        canonical = root / 'private/etc'
        canonical.mkdir(parents=True)
        alias = root / 'etc'
        alias.symlink_to(canonical)
        leaf = canonical / 'dotfiles-platform-fixture.json'
        leaf.symlink_to(root / 'must-not-follow')
        self.assertTrue(hasattr(module, 'assignment_path'), 'administrator parent aliases need canonical validation')
        selected = module.assignment_path(alias)
        self.assertEqual(selected.parent, canonical)
        self.assertTrue(selected.is_symlink(), 'leaf symlink must remain visible to the refusal guard')

    def test_failed_apply_preserves_status_plan_and_logs(self):
        from importlib.machinery import SourceFileLoader
        loader = SourceFileLoader('platform_smoke', str(ROOT / 'nix/tests/platform-smoke.sh'))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        module = importlib.util.module_from_spec(spec)
        loader.exec_module(module)
        root = Path(tempfile.mkdtemp(prefix='smoke-failure-', dir=PARENT))
        source = root / 'source'
        entry = source / '.config/dotfiles/bootstrap-nix'
        entry.parent.mkdir(parents=True)
        entry.write_text('#!' + sys.executable + '\nimport json,sys\n'
            + 'if sys.argv[4] == "plan":\n'
            + ' open("plan.json","w").write(json.dumps({"conflicts":[],"nativeManifest":{"activationPackage":"/fixture-generation"},"transactionId":"fixture"}))\n'
            + ' print("preview retained")\n'
            + 'else:\n print("assigned command failed")\n sys.exit(42)\n')
        entry.chmod(0o755)
        evidence = root / 'evidence'
        evidence.mkdir()
        output = io.StringIO()
        with redirect_stdout(output):
            self.assertEqual(module.smoke({'scope': 'test-double'}, source, evidence, 'fixture'), 42)
        run = next(evidence.iterdir())
        self.assertEqual(output.getvalue(), 'Retained smoke evidence: ' + str(run) + '\n')
        result = json.loads((run / 'result.json').read_text())
        self.assertEqual(result['exit'], 42)
        self.assertEqual([item['exit'] for item in result['commands']], [0, 42])
        self.assertEqual(json.loads((run / 'plan.json').read_text())['transactionId'], 'fixture')
        self.assertIn('assigned command failed', (run / '1.log').read_text())


@unittest.skipUnless(os.environ.get('DOTFILES_TEST_REAL_NIX'), 'requires leased Nix store')
class RealSourceImportTests(EntrypointTests):
    def test_real_git_import_excludes_sentinels_and_pins_commit(self):
        (self.bin / 'nix').unlink()
        (self.bin / 'nix').symlink_to(os.environ['DOTFILES_TEST_REAL_NIX'])
        self.env['NIX_CONFIG'] = os.environ.get('NIX_CONFIG', '')
        self.env['PATH'] += ':' + os.environ['PATH']
        (self.home / 'secret-sentinel').write_text('synthetic-home-secret')
        (self.repo / 'untracked-secret').write_text('synthetic-untracked-secret')
        (self.repo / '.git/metadata-secret').write_text('synthetic-metadata-secret')
        (self.repo / 'probe.py').write_text('#!' + sys.executable + '\nimport json,os,sys\nfrom pathlib import Path\nprint(json.dumps({"source":str(Path(__file__).parent),"cwd":os.getcwd(),"args":sys.argv[1:]}))\n')
        (self.repo / 'probe.py').chmod(0o755)
        (self.repo / 'flake.nix').write_text('{ outputs = { self }: { apps.x86_64-linux.dotfiles = { type = "app"; program = "${self.outPath}/probe.py"; }; }; }\n')
        # Only selected tracked files: never add the synthetic untracked secret.
        self.git('add', 'flake.nix', 'probe.py')
        self.git('commit', '-qm', 'source probe')
        alias = self.root / 'real-alias'
        alias.symlink_to(self.repo)
        result = self.invoke('quoted ü %?#', root=alias)
        self.assertEqual(result.returncode, 0, result.stderr)
        record = json.loads(result.stdout)
        imported = Path(record['source'])
        self.assertEqual(record['cwd'], str(self.cwd))
        self.assertEqual(record['args'], ['quoted ü %?#'])
        self.assertEqual(sorted(p.name for p in imported.iterdir()), ['flake.lock', 'flake.nix', 'probe.py'])
        self.assertEqual((imported / 'flake.lock').read_bytes(), (self.repo / 'flake.lock').read_bytes())
        original = (imported / 'probe.py').read_bytes()
        (self.repo / 'probe.py').write_text('changed original checkout')
        self.assertEqual((imported / 'probe.py').read_bytes(), original)
        # Restore only this owned test file; test the registered bare-worktree case.
        (self.repo / 'probe.py').write_bytes(original)
        bare = self.root / 'bare metadata'
        self.git('clone', '--bare', '-q', str(self.repo), str(bare))
        linked = self.root / 'bare linked ü %?#'
        self.git('--git-dir=' + str(bare), 'worktree', 'add', '-q', str(linked), 'HEAD')
        (linked / 'untracked-secret').write_text('synthetic linked secret')
        result = self.invoke('linked', root=linked)
        self.assertEqual(result.returncode, 0, result.stderr)
        imported_linked = Path(json.loads(result.stdout)['source'])
        self.assertEqual(sorted(p.name for p in imported_linked.iterdir()), ['flake.lock', 'flake.nix', 'probe.py'])
        # A stale lock must fail without in-memory reconciliation or a lock write.
        payload = self.root / 'payload'
        payload.mkdir()
        (payload / 'value').write_text('owned fixture')
        (self.repo / 'flake.nix').write_text('{ inputs.payload = { url = "path:' + str(payload) + '"; flake = false; }; outputs = { self, ... }: { apps.x86_64-linux.dotfiles = { type = "app"; program = "${self.outPath}/probe.py"; }; }; }\n')
        self.git('add', 'flake.nix')
        self.git('commit', '-qm', 'stale lock')
        before = (self.repo / 'flake.lock').read_bytes()
        result = self.invoke('must-not-run')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('lock', result.stderr.lower())
        self.assertEqual((self.repo / 'flake.lock').read_bytes(), before)
        print(json.dumps({'ordinarySource': str(imported), 'linkedSource': str(imported_linked),
                          'trackedFiles': ['flake.lock', 'flake.nix', 'probe.py'],
                          'sentinelsExcluded': True, 'staleLockExit': result.returncode}))


@unittest.skipUnless(os.environ.get('DOTFILES_TEST_PACKAGED_APP'), 'requires prepared disposable native fixture')
class PackagedEntrypointTests(unittest.TestCase):
    def test_real_packaged_plan_foreign_cwd_exclusive_output_and_failures(self):
        home = Path(os.environ['HOME'])
        output = Path(os.environ['DOTFILES_TEST_PLAN'])
        cwd = output.parent / 'foreign cwd ü'
        cwd.mkdir()
        (cwd / 'flake.nix').write_text('throw "caller flake must never be evaluated"')
        app = os.environ['DOTFILES_TEST_PACKAGED_APP']
        profile = os.environ['DOTFILES_TEST_PROFILE']
        expected = json.loads(Path(os.environ['DOTFILES_TEST_PROFILES']).read_text())[profile]
        source = Path(os.environ['DOTFILES_TEST_PROFILE_SOURCE'])

        def snapshot(root):
            result = {}
            for path in root.rglob('*'):
                relative = path.relative_to(root)
                if relative == Path('.cache/nix') or Path('.cache/nix') in relative.parents:
                    continue  # Nix's evaluator cache is explicitly permitted.
                info = path.lstat()
                result[str(relative)] = (info.st_mode, os.readlink(path) if path.is_symlink()
                                         else path.read_bytes() if path.is_file() else None)
            return result

        def run(*args, env=None):
            env = {**os.environ, 'DOTFILES_FLAKE_SOURCE': str(cwd),
                   'DOTFILES_SOURCE_ROOT': str(cwd), **(env or {})}
            return subprocess.run(['nix', 'run', '--offline', '--no-update-lock-file', app, '--', *args],
                                  cwd=cwd, env=env, capture_output=True, text=True)

        before = snapshot(home)
        source_before = snapshot(source)
        relative = '../' + output.name
        result = run('plan', '--profile', profile, '--output', relative)
        self.assertEqual(result.returncode, 0, result.stderr)
        original = output.read_bytes()
        plan = json.loads(original)
        self.assertEqual(plan['home'], str(home))
        self.assertEqual(plan['conflicts'], [])
        self.assertEqual(plan['nativeManifest']['activationPackage'], expected['generation'])
        self.assertEqual(snapshot(home), before, 'preview must not activate or switch')
        self.assertEqual(snapshot(source), source_before)
        result = run('plan', '--profile', profile, '--output', relative)
        self.assertEqual(result.returncode, 1)
        self.assertIn('Output already exists', result.stderr)
        self.assertEqual(output.read_bytes(), original)
        result = run('plan', '--profile', 'unknown-profile', '--output', 'unknown.json')
        self.assertEqual(result.returncode, 1)
        self.assertFalse((cwd / 'unknown.json').exists())
        result = run('apply', '--plan', 'absent plan.json')
        self.assertEqual(result.returncode, 1)
        # Native readiness failure is a conflictful preview, then a refused apply.
        result = run('plan', '--profile', profile, '--output', 'missing-runtime.json',
                     env={**os.environ, 'WAYLAND_DISPLAY': 'missing-owned-fixture-display'})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(json.loads((cwd / 'missing-runtime.json').read_text())['conflicts'])
        result = run('apply', '--plan', 'missing-runtime.json')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(snapshot(home), before)
        self.assertEqual(snapshot(source), source_before)
        self.assertFalse((home / '.local/state/dotfiles-ownership/owner.json').exists())


if __name__ == "__main__":
    unittest.main()
