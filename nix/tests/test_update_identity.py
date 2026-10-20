"""Real Nix evaluation of release identity and the private consumer template."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(os.environ.get('DOTFILES_IDENTITY_SOURCE_ROOT', Path(__file__).resolve().parents[2]))
NIX = shutil.which('nix')


@unittest.skipUnless(NIX, 'real Nix is required for deployment identity evaluation')
class UpdateIdentityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = Path(tempfile.mkdtemp(prefix='dotfiles-identity-'))
        cls.source = cls.root / 'upstream'
        shutil.copytree(ROOT, cls.source, ignore=shutil.ignore_patterns('.git', '__pycache__'))
        cls.env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
        cls.env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1')
        cls.commit(cls.source)
        cls.revision = cls.git(cls.source, 'rev-parse', 'HEAD')
        cls.reference = 'git+' + cls.source.as_uri() + '?rev=' + cls.revision
        cls.system = cls.evaluate('builtins.currentSystem')

    @classmethod
    def git(cls, cwd, *arguments):
        return subprocess.check_output(['git', '-c', 'user.name=Identity fixture', '-c',
            'user.email=identity@example.invalid', '-c', 'core.hooksPath=/dev/null', '-c',
            'commit.gpgSign=false', *arguments], cwd=cwd, env=cls.env, text=True).strip()

    @classmethod
    def commit(cls, directory):
        if not (directory / '.git').exists():
            cls.git(directory, 'init', '-q')
        cls.git(directory, 'add', '.')
        cls.git(directory, 'commit', '-qm', 'private identity fixture')

    @classmethod
    def nix(cls, *arguments):
        return subprocess.run([NIX, '--extra-experimental-features', 'nix-command flakes',
            *arguments], env=cls.env, text=True, capture_output=True, timeout=600)

    @classmethod
    def evaluate(cls, expression):
        result = cls.nix('eval', '--offline', '--no-update-lock-file', '--json', '--impure',
                         '--expr', expression)
        if result.returncode:
            raise AssertionError(result.stderr)
        return json.loads(result.stdout)

    def expression(self, body):
        return '''let
          source = builtins.getFlake %s;
          base = { system = %s; profile = %s; username = "identity-fixture";
            homeDirectory = "/home/identity-fixture"; };
          identity = { schema = 1; consumerSource = source.outPath; profile = "my-host";
            release = { repository = "ruohao1/dotfiles"; releaseId = 123;
              version = "v1.2.3"; commit = "%s"; }; };
          mkHome = source.lib.mkHome;
        in %s''' % (json.dumps(self.reference), json.dumps(self.system),
            json.dumps('darwin' if self.system.endswith('-darwin') else 'linux'), self.revision, body)

    def test_release_identity_changes_generation_without_home_target_changes(self):
        result = self.evaluate(self.expression('''let
          legacy = mkHome base;
          first = mkHome (base // { deploymentIdentity = identity; });
          second = mkHome (base // { deploymentIdentity = identity // {
            release = identity.release // { releaseId = 124; version = "v1.2.4"; };
          }; });
          view = home: { generation = toString home.activationPackage;
            targets = map (file: file.target) home.deploymentManifest.files;
            manifest = home.deploymentManifest;
            dependencies = map toString home.config.home.extraDependencies;
            stateVersion = home.config.home.stateVersion; };
        in { legacy = view legacy; first = view first; second = view second; }'''))
        first, second, legacy = (result[key] for key in ['first', 'second', 'legacy'])
        self.assertNotEqual(first['generation'], second['generation'])
        self.assertEqual(first['targets'], second['targets'])
        self.assertEqual(first['targets'], legacy['targets'])
        self.assertNotIn('deploymentIdentity', legacy['manifest'])
        self.assertEqual(first['manifest']['deploymentIdentity']['release']['version'], 'v1.2.3')
        self.assertEqual(second['manifest']['deploymentIdentity']['release']['version'], 'v1.2.4')
        self.assertEqual(first['stateVersion'], '26.05')
        self.assertNotEqual(first['dependencies'], second['dependencies'])

    def test_malformed_or_mutable_identity_is_rejected(self):
        result = self.evaluate(self.expression('''let
          rejects = value: !(builtins.tryEval (builtins.deepSeq
            (mkHome (base // { deploymentIdentity = value; })).deploymentManifest true)).success;
        in map rejects [
          (identity // { schema = 2; })
          (identity // { schema = 1.0; })
          (identity // { consumerSource = "/tmp/mutable-consumer"; })
          (identity // { profile = "check-x86_64-linux"; })
          (identity // { unexpected = "field"; })
          (identity // { release = identity.release // { releaseId = 0; }; })
          (identity // { release = identity.release // { releaseId = true; }; })
          (identity // { release = identity.release // { version = "v01.2.3"; }; })
          (identity // { release = identity.release // { repository = "someone/else"; }; })
          (identity // { release = identity.release // { commit = "not-a-revision"; }; })
        ]'''))
        self.assertEqual(result, [True] * 10)

    def test_host_module_cannot_drop_deployment_identity(self):
        result = self.evaluate(self.expression('''(builtins.tryEval (builtins.deepSeq
          (mkHome (base // { deploymentIdentity = identity;
            modules = [ ({ lib, ... }: { home.extraDependencies = lib.mkForce []; }) ];
          })).deploymentManifest true)).success'''))
        self.assertFalse(result)

    def consumer(self):
        target = self.root / ('consumer-' + self._testMethodName)
        self.assertTrue((self.source / 'nix/templates/host').is_dir(), 'consumer template is missing')
        shutil.copytree(self.source / 'nix/templates/host', target)
        flake = target / 'flake.nix'
        flake.write_text(flake.read_text().replace('"x86_64-linux"', json.dumps(self.system)))
        receipt = {'repository': 'ruohao1/dotfiles', 'releaseId': 123,
                   'version': 'v1.2.3', 'commit': self.revision}
        (target / 'dotfiles-release.json').write_text(json.dumps(receipt) + '\n')
        self.commit(target)
        locked = self.nix('flake', 'lock', '--offline', '--override-input', 'dotfiles',
                          self.reference, str(target))
        self.assertEqual(locked.returncode, 0, locked.stderr)
        self.commit(target)
        return target

    def test_packaged_path_evaluation_preserves_identity(self):
        consumer = self.consumer()
        reference = 'git+' + consumer.as_uri() + '?rev=' + self.git(consumer, 'rev-parse', 'HEAD')
        expression = '(builtins.getFlake %s).homeConfigurations.my-host.deploymentManifest.deploymentIdentity'
        original = self.evaluate(expression % json.dumps(reference))
        packaged = self.evaluate(expression % json.dumps('path:' + original['consumerSource']))
        self.assertEqual(original, packaged)
        self.assertEqual(original['release']['commit'], self.revision)
        self.assertEqual(original['profile'], 'my-host')
        self.assertTrue(original['consumerSource'].startswith('/nix/store/'))
        executor = self.evaluate('''let source = builtins.getFlake %s; in {
          package = toString source.packages.%s.dotfiles-executor;
          app = source.apps.%s.dotfiles.program;
        }''' % (json.dumps(reference), json.dumps(self.system), json.dumps(self.system)))
        self.assertEqual(executor['package'], executor['app'])

    def test_executor_retains_all_sources_needed_for_offline_recovery(self):
        consumer = self.consumer()
        reference = 'git+' + consumer.as_uri() + '?rev=' + self.git(consumer, 'rev-parse', 'HEAD')
        sources = self.evaluate('''let consumer = builtins.getFlake %s;
          dotfiles = consumer.inputs.dotfiles;
        in {
          consumer = consumer.outPath;
          dotfiles = dotfiles.outPath;
          nixpkgs = dotfiles.inputs.nixpkgs.outPath;
          homeManager = dotfiles.inputs.home-manager.outPath;
        }''' % json.dumps(reference))
        rooted = self.root / 'recovery-executor'
        built = self.nix('build', '--offline', '--no-update-lock-file', '--max-jobs', '1',
                         '--cores', '1', '--out-link', str(rooted), reference + '#dotfiles-executor')
        self.assertEqual(built.returncode, 0, built.stderr)
        self.assertTrue(rooted.is_symlink())
        # Store references, rather than current disk existence or an eval cache,
        # prove GC will keep the inputs needed by the executor's later Nix eval.
        closure = self.nix('path-info', '--offline', '--recursive', str(rooted.resolve()))
        self.assertEqual(closure.returncode, 0, closure.stderr)
        retained = set(closure.stdout.splitlines())
        for name, source in sources.items():
            with self.subTest(source=name):
                self.assertTrue(source in retained,
                                name + ' source is not retained for offline recovery: ' + source)

    def test_receipt_revision_must_match_input(self):
        consumer = self.consumer()
        receipt = json.loads((consumer / 'dotfiles-release.json').read_text())
        receipt['commit'] = '0' * 40
        (consumer / 'dotfiles-release.json').write_text(json.dumps(receipt) + '\n')
        self.commit(consumer)
        result = self.nix('eval', '--offline', '--no-update-lock-file', '--json',
            str(consumer) + '#homeConfigurations.my-host.deploymentManifest')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('receipt commit', result.stderr)


if __name__ == '__main__':
    unittest.main()
