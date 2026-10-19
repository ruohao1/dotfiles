"""Characterize the targeted-update CLI with real, offline, repository-pinned Nix."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest
from urllib.parse import quote, urlencode


NIX = os.environ.get('DOTFILES_LOCK_NIX')


@unittest.skipUnless(NIX, 'requires DOTFILES_LOCK_NIX; run the update-lock Nix check')
class UpdateLockTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix='update-lock-'))
        self.home = self.root / 'home'
        self.home.mkdir()
        # A distinct logical store avoids a daemon, mount namespaces, and writes
        # to the enclosing build's store. Only this tiny fixture is built here.
        self.store = 'local?' + urlencode({
            'store': str(self.root / 'store'), 'state': str(self.root / 'state'),
            'log': str(self.root / 'log')}, safe='/')
        self.environment = {
            'PATH': os.environ['PATH'], 'HOME': str(self.home),
            'TMPDIR': str(self.root), 'XDG_CACHE_HOME': str(self.root / 'cache'),
            'GIT_CONFIG_GLOBAL': os.devnull, 'GIT_CONFIG_NOSYSTEM': '1',
            'NIX_REMOTE': self.store,
            'NIX_CONFIG': '\n'.join([
                'experimental-features = nix-command flakes', 'sandbox = false',
                'build-users-group =', 'substituters =', 'flake-registry =',
                'accept-flake-config = false', 'max-jobs = 1', 'cores = 1']),
        }
        self.shell = os.environ.get('DOTFILES_LOCK_SHELL', shutil.which('bash'))
        self.chmod = os.environ.get('DOTFILES_LOCK_CHMOD', shutil.which('chmod'))

    def run_command(self, command, *, environment=None):
        result = subprocess.run(command, env=environment or self.environment,
                                capture_output=True, text=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def nix(self, *arguments, environment=None):
        return self.run_command([NIX, '--offline', *arguments], environment=environment)

    def git(self, repository, *arguments):
        return self.run_command(['git', '-c', 'core.hooksPath=/dev/null',
            '-c', 'user.name=Lock fixture', '-c', 'user.email=fixture@example.invalid',
            '-c', 'commit.gpgSign=false', '-C', str(repository), *arguments])

    def repository(self, name):
        repository = self.root / name
        repository.mkdir()
        self.git(repository, 'init', '-q')
        return repository

    def commit(self, repository):
        self.git(repository, 'add', '.')
        self.git(repository, 'commit', '-qm', 'fixture revision')
        return self.git(repository, 'rev-parse', 'HEAD')

    @staticmethod
    def reference(repository, revision=None):
        return 'git+file://' + quote(str(repository), safe='/') + (
            '?rev=' + revision if revision else '')

    @staticmethod
    def input_node(lock, name, parent=None):
        parent = parent or lock['root']
        return lock['nodes'][lock['nodes'][parent]['inputs'][name]]

    def test_targeted_override_survives_immutable_evaluation_and_roots_executor(self):
        dependency = self.repository('transitive dependency')
        (dependency / 'flake.nix').write_text('{ outputs = _: { value = "dependency-A"; }; }')
        dependency_a = self.commit(dependency)
        upstream = self.repository('dotfiles upstream')

        def upstream_release(version, dependency_revision):
            (upstream / 'flake.nix').write_text('''{
  inputs.dependency.url = %s;
  outputs = { dependency, ... }: {
    release = %s;
    dependency = dependency.value;
  };
}''' % (json.dumps(self.reference(dependency, dependency_revision)), json.dumps(version)))
            self.git(upstream, 'add', 'flake.nix')
            self.nix('flake', 'lock', str(upstream))
            return self.commit(upstream)

        release_a = upstream_release('release-A', dependency_a)
        unrelated = self.repository('unrelated dependency')
        (unrelated / 'flake.nix').write_text('{ outputs = _: { value = "unrelated-A"; }; }')
        unrelated_a = self.commit(unrelated)
        original = self.repository('personal host')
        system = json.loads(self.nix('eval', '--impure', '--json', '--expr', 'builtins.currentSystem'))
        # The extra consumer input deliberately stresses the CLI's targeted
        # scope; v1 updater adoption remains restricted to its one-input template.
        (original / 'flake.nix').write_text('''{
  inputs.dotfiles.url = %s;
  inputs.unrelated.url = %s;
  outputs = { self, dotfiles, unrelated }: {
    fixture = {
      release = dotfiles.release;
      dependency = dotfiles.dependency;
      unrelated = unrelated.value;
      selected = dotfiles.rev;
      source = self.outPath;
    };
    packages.%s.dotfiles-executor = builtins.derivation {
      name = "dotfiles-lock-fixture-executor";
      system = %s;
      builder = %s;
      args = [ "-c" "printf '%%s' \\"$payload\\" > \\"$out\\"; %s +x \\"$out\\"" ];
      payload = "#!%s\\nprintf '%%s\\\\n' '${dotfiles.release}:${dotfiles.dependency}' '${self.outPath}'\\n";
    };
  };
}''' % (json.dumps(self.reference(upstream)), json.dumps(self.reference(unrelated)),
        system, json.dumps(system), json.dumps(self.shell), self.chmod, self.shell))
        (original / 'host.nix').write_text('{ home.sessionVariables.PERSONAL = "retained"; }\n')
        self.git(original, 'add', '.')
        self.nix('flake', 'lock', str(original))
        original_commit = self.commit(original)
        original_files = {name: (original / name).read_bytes()
                          for name in ('flake.nix', 'flake.lock', 'host.nix')}
        original_lock = json.loads(original_files['flake.lock'])
        self.assertEqual(self.input_node(original_lock, 'dotfiles')['locked']['rev'], release_a)

        (dependency / 'flake.nix').write_text('{ outputs = _: { value = "dependency-B"; }; }')
        dependency_b = self.commit(dependency)
        release_b = upstream_release('release-B', dependency_b)
        (unrelated / 'flake.nix').write_text('{ outputs = _: { value = "unrelated-B"; }; }')
        self.commit(unrelated)

        # A fresh fetcher cache must provide the lock graph even when modern
        # Nix lazily leaves metadata.path unmaterialized. Never open that path.
        metadata = json.loads(self.nix('flake', 'metadata', '--json', '--no-update-lock-file',
            self.reference(upstream, release_b), environment={
                **self.environment, 'XDG_CACHE_HOME': str(self.root / 'cold-cache')}))
        self.assertEqual(self.input_node(metadata['locks'], 'dependency')['locked']['rev'], dependency_b)
        metadata_path_exists = Path(metadata['path']).exists()

        candidate = self.root / 'candidate source'
        self.git(original, 'clone', '--quiet', '--no-local', '--no-hardlinks', '--',
                 str(original), str(candidate))
        self.nix('flake', 'update', 'dotfiles', '--flake', str(candidate),
                 '--override-input', 'dotfiles', self.reference(upstream, release_b))
        updated = json.loads((candidate / 'flake.lock').read_text())
        dotfiles = self.input_node(updated, 'dotfiles')
        self.assertEqual(dotfiles['locked']['rev'], release_b)
        self.assertEqual(updated['nodes'][dotfiles['inputs']['dependency']]['locked'],
                         self.input_node(metadata['locks'], 'dependency')['locked'])
        self.assertEqual(self.input_node(updated, 'unrelated'), self.input_node(original_lock, 'unrelated'))
        self.assertEqual(self.input_node(updated, 'unrelated')['locked']['rev'], unrelated_a)
        self.assertEqual(self.git(candidate, 'diff', '--name-only'), 'flake.lock')
        candidate_commit = self.commit(candidate)
        candidate_lock = (candidate / 'flake.lock').read_bytes()
        reference = self.reference(candidate, candidate_commit)
        selected = json.loads(self.nix('eval', '--json', '--no-update-lock-file', reference + '#fixture'))
        self.assertEqual({key: selected[key] for key in ('release', 'dependency', 'unrelated', 'selected')},
                         {'release': 'release-B', 'dependency': 'dependency-B',
                          'unrelated': 'unrelated-A', 'selected': release_b})

        root_link = self.root / 'retained executor'
        self.nix('build', '--no-update-lock-file', '--out-link', str(root_link),
                 reference + '#dotfiles-executor')
        self.assertTrue(root_link.is_symlink())
        self.assertTrue(root_link.is_file())
        self.assertEqual(self.run_command([str(root_link)]).splitlines(),
                         ['release-B:dependency-B', selected['source']])
        immutable = json.loads(self.nix('eval', '--json', '--no-update-lock-file',
                               'path:' + selected['source'] + '#fixture'))
        self.assertEqual(immutable, selected)
        nix_store = str(Path(NIX).with_name('nix-store'))
        roots = self.run_command([nix_store, '--gc', '--print-roots']).splitlines()
        self.assertIn([str(root_link), '->', str(root_link.resolve())],
                      [shlex.split(line) for line in roots])
        live = self.run_command([nix_store, '--gc', '--print-live']).splitlines()
        self.assertIn(str(root_link.resolve()), live)
        self.assertIn(selected['source'], live)
        self.assertEqual((candidate / 'flake.lock').read_bytes(), candidate_lock)
        self.assertEqual(self.git(original, 'rev-parse', 'HEAD'), original_commit)
        self.assertEqual(self.git(original, 'status', '--porcelain'), '')
        for name, content in original_files.items():
            self.assertEqual((original / name).read_bytes(), content)
        print(json.dumps({'nix': self.nix('--version'), 'release': release_b,
            'dependency': dependency_b, 'coldMetadataSourceExists': metadata_path_exists,
            'executor': str(root_link.resolve()), 'rootLink': str(root_link),
            'consumerSource': selected['source'], 'originalUnchanged': True}))


if __name__ == '__main__':
    unittest.main()
