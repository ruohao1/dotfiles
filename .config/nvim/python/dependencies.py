#!/usr/bin/env python3
"""Probe the notebook environment against its authoritative frozen project."""
import argparse
import importlib
from importlib import metadata
import json
from pathlib import Path
import re
import sys


def load_contract(project):
    try:
        import tomllib
    except ModuleNotFoundError:
        # Jupytext already locks tomli for Python versions without tomllib.
        import tomli as tomllib

    with (Path(project) / 'pyproject.toml').open('rb') as stream:
        declaration = tomllib.load(stream).get('project', {})
    if not isinstance(declaration, dict):
        raise ValueError('missing notebook project declaration')
    requires_python = declaration.get('requires-python')
    bounds = re.fullmatch(r'\s*>=\s*(\d+)\.(\d+)\s*,\s*<\s*(\d+)\.(\d+)\s*',
                          requires_python) if isinstance(requires_python, str) else None
    if not bounds:
        raise ValueError('notebook requires-python must use >=major.minor,<major.minor')
    minimum, maximum = tuple(map(int, bounds.groups()[:2])), tuple(map(int, bounds.groups()[2:]))
    if minimum >= maximum:
        raise ValueError('notebook Python range is empty')
    dependencies = declaration.get('dependencies')
    if not isinstance(dependencies, list) or not dependencies:
        raise ValueError('notebook project must declare dependencies')
    expected = {}
    for dependency in dependencies:
        pin = re.fullmatch(r'([A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?)==([0-9]+(?:\.[0-9]+)*)',
                           dependency.strip()) if isinstance(dependency, str) else None
        if not pin:
            raise ValueError('notebook dependencies must use exact numeric version pins')
        name = re.sub(r'[-_.]+', '-', pin[1]).lower()
        if name in expected:
            raise ValueError('duplicate notebook dependency: ' + name)
        expected[name] = pin[2]
    return expected, requires_python, minimum, maximum


def probe(project, imports=False):
    expected, requires_python, minimum, maximum = load_contract(project)
    if imports:
        for name in ('ipykernel', 'jupyter_client', 'jupytext', 'nbformat', 'pynvim'):
            importlib.import_module(name)
    actual = {name: metadata.version(name) for name in expected}
    return {'expected': expected, 'actual': actual, 'requires_python': requires_python,
            'python_compatible': minimum <= sys.version_info[:2] < maximum}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project', type=Path, default=Path(__file__).resolve().parent)
    parser.add_argument('--imports', action='store_true')
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args(argv)
    try:
        result = probe(args.project, args.imports)
    except (OSError, ValueError, ImportError) as error:
        print('Notebook dependency probe failed: ' + str(error), file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True))
    return int(args.check and (not result['python_compatible'] or result['actual'] != result['expected']))


if __name__ == '__main__':
    sys.exit(main())
