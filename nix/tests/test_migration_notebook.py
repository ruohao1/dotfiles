"""Exercise the notebook contract without installing or importing real packages."""
import ast
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(os.environ.get('DOTFILES_MIGRATION_SOURCE_ROOT', Path(__file__).resolve().parents[2]))
PROJECT = ROOT / '.config/nvim/python'
READER = PROJECT / 'dependencies.py'
spec = importlib.util.spec_from_file_location('notebook_dependencies', READER)
reader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reader)


class NotebookDependencyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='notebook-contract-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.project = self.root / 'project with spaces'
        self.project.mkdir()
        self.write_project()

    def write_project(self, dependencies=None, python='>=3.10,<3.15'):
        dependencies = ['pynvim==0.6.0'] if dependencies is None else dependencies
        (self.project / 'pyproject.toml').write_text('[project]\nrequires-python = '
            + json.dumps(python) + '\ndependencies = ' + json.dumps(dependencies) + '\n')

    def run_cli(self, *args, versions=None, main=None):
        stdout, stderr = io.StringIO(), io.StringIO()
        versions = {'pynvim': '0.6.0'} if versions is None else versions
        with patch.object(reader.metadata, 'version', side_effect=versions.__getitem__), \
                contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            status = (main or reader.main)(list(args))
        return status, stdout.getvalue(), stderr.getvalue()

    def test_project_pins_and_range_drive_readiness(self):
        self.write_project(['pynvim==9.8.7'], '>=3.14,<3.16')
        with patch.object(reader.sys, 'version_info', (3, 14, 0)):
            status, output, error = self.run_cli('--project', str(self.project), '--check')
        self.assertEqual(status, 1)
        self.assertFalse(error)
        result = json.loads(output)
        self.assertEqual(result, {'expected': {'pynvim': '9.8.7'}, 'actual': {'pynvim': '0.6.0'},
                                 'requires_python': '>=3.14,<3.16', 'python_compatible': True})
        status, output, error = self.run_cli('--project', str(self.project), versions={'pynvim': '9.8.7'})
        self.assertEqual(status, 0, error)
        self.assertEqual(json.loads(output)['actual'], {'pynvim': '9.8.7'})

    def test_python_minor_boundaries_and_reporting_mode(self):
        for version, compatible in [((3, 9, 9), False), ((3, 10, 0), True),
                                    ((3, 14, 9), True), ((3, 15, 0), False)]:
            with self.subTest(version=version), patch.object(reader.sys, 'version_info', version):
                status, output, error = self.run_cli('--project', str(self.project), '--check')
                self.assertEqual(status, 0 if compatible else 1, error)
                self.assertEqual(json.loads(output)['python_compatible'], compatible)
                status, _, error = self.run_cli('--project', str(self.project))
                self.assertEqual(status, 0, error)

    def test_distribution_names_are_canonical_and_duplicates_fail(self):
        self.write_project(['Jupyter_Client==8.9.1'])
        self.assertEqual(reader.load_contract(self.project)[0], {'jupyter-client': '8.9.1'})
        self.write_project(['Jupyter_Client==8.9.1', 'jupyter.client==8.9.1'])
        with self.assertRaisesRegex(ValueError, 'duplicate'):
            reader.load_contract(self.project)

    def test_unsupported_declarations_fail_without_a_success_payload(self):
        declarations = [
            'not toml', '[project]\n', '[project]\ndependencies = "pynvim==0.6.0"\n',
            '[project]\nrequires-python = ">=3.10,<3.15"\ndependencies = []\n',
        ]
        for dependencies in [['pynvim>=0.6.0'], ['pynvim==0.6.*'], ['pynvim==0.6.0; python_version > "3"'],
                             ['pynvim[extra]==0.6.0'], [42], ['bad/name==1.0'], ['pynvim==1.0==2.0']]:
            self.write_project(dependencies)
            declarations.append((self.project / 'pyproject.toml').read_text())
        for constraint in ['>=3.10', '>=3.10.0,<3.15', '>=3.15,<3.10', '>=3.10,<3.10']:
            self.write_project(python=constraint)
            declarations.append((self.project / 'pyproject.toml').read_text())
        for declaration in declarations:
            with self.subTest(declaration=declaration):
                (self.project / 'pyproject.toml').write_text(declaration)
                status, output, error = self.run_cli('--project', str(self.project), '--check')
                self.assertEqual(status, 1)
                self.assertFalse(output)
                self.assertIn('Notebook dependency probe failed:', error)

    def test_missing_metadata_and_import_fail_cleanly(self):
        for target, failure, flags in [
            ('version', reader.metadata.PackageNotFoundError('pynvim'), []),
            ('import_module', ModuleNotFoundError('missing notebook module'), ['--imports']),
        ]:
            owner = reader.metadata if target == 'version' else reader.importlib
            stdout, stderr = io.StringIO(), io.StringIO()
            with self.subTest(target=target), patch.object(owner, target, side_effect=failure), \
                    contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                self.assertEqual(reader.main(['--project', str(self.project), *flags]), 1)
            self.assertFalse(stdout.getvalue())
            self.assertIn('Notebook dependency probe failed:', stderr.getvalue())

    def test_import_mode_preserves_all_five_imports(self):
        with patch.object(reader.importlib, 'import_module') as imports:
            status, _, error = self.run_cli('--project', str(self.project))
            self.assertEqual(status, 0, error)
            imports.assert_not_called()
            status, _, error = self.run_cli('--project', str(self.project), '--imports')
            self.assertEqual(status, 0, error)
            self.assertEqual([call.args[0] for call in imports.call_args_list],
                             ['ipykernel', 'jupyter_client', 'jupytext', 'nbformat', 'pynvim'])

    def test_python310_parser_fallback_and_missing_parser(self):
        import tomllib
        with patch.dict(sys.modules, {'tomllib': None, 'tomli': tomllib}):
            self.assertEqual(reader.load_contract(self.project)[0], {'pynvim': '0.6.0'})
        with patch.dict(sys.modules, {'tomllib': None, 'tomli': None}):
            status, output, error = self.run_cli('--project', str(self.project))
            self.assertEqual(status, 1)
            self.assertFalse(output)
            self.assertIn('tomli', error)

    def test_portable_copy_and_symlink_use_canonical_sibling_project(self):
        copied = self.project / 'dependencies.py'
        shutil.copyfile(READER, copied)
        self.write_project(['pynvim==8.7.6'])
        deployed = self.root / 'deployed'
        deployed.mkdir()
        (deployed / 'dependencies.py').symlink_to(copied)
        (deployed / 'pyproject.toml').write_text('invalid and must not be read')
        module = runpy.run_path(str(deployed / 'dependencies.py'))
        status, output, error = self.run_cli('--check', main=module['main'], versions={'pynvim': '8.7.6'})
        self.assertEqual(status, 0, error)
        self.assertEqual(json.loads(output)['expected'], {'pynvim': '8.7.6'})

    def test_real_cli_rejects_missing_project_without_traceback(self):
        result = subprocess.run([sys.executable, '-I', '-B', str(READER), '--project', str(self.root / 'absent')],
                                cwd=self.root, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 1)
        self.assertFalse(result.stdout)
        self.assertIn('Notebook dependency probe failed:', result.stderr)
        self.assertNotIn('Traceback', result.stderr)

    def test_project_lock_consistency_and_existing_python310_parser(self):
        import tomllib
        with (PROJECT / 'uv.lock').open('rb') as stream:
            lock = tomllib.load(stream)
        expected, requires_python, _, _ = reader.load_contract(PROJECT)
        self.assertEqual(''.join(lock['requires-python'].split()), ''.join(requires_python.split()))
        packages = {package['name']: package for package in lock['package']}
        declaration = packages['dotfiles-neovim-notebook']['metadata']['requires-dist']
        self.assertEqual({item['name']: item['specifier'] for item in declaration},
                         {name: '==' + version for name, version in expected.items()})
        self.assertEqual({name: packages[name]['version'] for name in expected}, expected)
        self.assertIn({'name': 'tomli', 'marker': "python_full_version < '3.11'"},
                      packages['jupytext']['dependencies'])
        self.assertIn('tomli', packages)
        ast.parse(READER.read_text(), feature_version=(3, 10))


if __name__ == '__main__':
    unittest.main()
