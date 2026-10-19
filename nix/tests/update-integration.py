"""Offline transport boundary; real retained executor, HM activation and rollback."""
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import uuid
from unittest.mock import patch


fixture = json.loads(Path(sys.argv[1]).read_text())
sys.path.insert(0, str(Path(fixture['source']) / 'nix'))
from migration.model import Conflict, fingerprint
from migration.prerequisites import inspect_native
from migration.transaction import Journal, Runtime, native_entries
from update import deployment, releases, state

home = Path(os.environ['HOME'])
assert home == Path('/home/migrator') and os.getuid() == 1000
profiles = json.loads(Path(fixture['profiles']).read_text())
review_root = Path('/var/tmp/isq318-reviews/release-update')
review_root.mkdir(mode=0o700)
root = state.open_state(home, create=True)
original = review_root / 'personal consumer'
original.mkdir(mode=0o700)


def git(directory, *arguments):
    return subprocess.check_output(['git', '-c', 'core.hooksPath=/dev/null',
        '-c', 'user.name=Release fixture', '-c', 'user.email=fixture@example.invalid',
        '-c', 'commit.gpgSign=false', '-C', str(directory), *arguments], text=True).strip()


git(original, 'init', '-q')
(original / 'host.nix').write_text('{ home.sessionVariables.PERSONAL = "retained"; }\n')
for name in ('flake.nix', 'flake.lock'):
    shutil.copyfile(Path(fixture['sources']['releaseA']) / name, original / name)
git(original, 'add', '.')
git(original, 'commit', '-qm', 'Personal fixture source')
original_commit = git(original, 'rev-parse', 'HEAD')
original_files = {name: (original / name).read_bytes() for name in ('host.nix', 'flake.nix', 'flake.lock')}
state.write_json(root / 'config.json', {'schema': 1, 'sourceRoot': str(original), 'profile': 'fixture-host'})
(root / 'candidates').mkdir(mode=0o700)


def manifest(name):
    result = dict(profiles[name]['manifest'])
    result['commandRequirements'] = fixture['inventories'][name]
    result['declaredProfile'] = 'fixture-host'
    return result


def execute(name, *arguments):
    subprocess.run([fixture['executors'][name], *arguments], check=True)


def native_snapshot():
    # Hash the genuine external runtimes, including their mutable uv receipts.
    result = {}
    for directory in (home / '.local/share/uv/tools', home / '.local/share/nvim/notebook-python'):
        for path in [directory, *sorted(directory.rglob('*'))]:
            result[str(path)] = fingerprint(path)
    return result


def observe(name, label):
    expected = manifest(name)
    installed = deployment.read_installed(home)
    assert installed['state'] == 'installed', installed
    assert installed['release'] == expected['deploymentIdentity']['release'], installed
    assert installed['generation'] == expected['activationPackage'], installed
    selected = shutil.which('uv')
    assert selected == str(home / '.nix-profile/bin/uv'), selected
    requirement = next(item for item in expected['commandRequirements'] if item['command'] == 'uv')
    assert Path(selected).resolve() == (Path(requirement['provider']) / 'bin/uv').resolve()
    version = subprocess.check_output([selected, '--version'], text=True).strip()
    assert version.split()[1] == fixture['versions'][name], version
    native = inspect_native(expected, home)
    assert native and all(item['status'] == 'observed' for item in native), native
    packages = Runtime(home).profile_packages(home / '.nix-profile')
    assert [item['paths'] for item in native_entries(packages)] == [[fixture['nativePackage']]], packages
    value = {'installed': installed, 'uv': {'selected': selected, 'resolved': str(Path(selected).resolve()),
             'version': version}, 'native': native, 'packages': packages}
    state.write_json(review_root / (label + '.json'), value)
    return value


def prepare_local(source, profile, release, state_root):
    # Only remote discovery/preparation is substituted: the projection contains
    # the real full HM generation and production packaged executor/inventory.
    assert Path(source) == original and profile == 'fixture-host' and Path(state_root) == root
    assert release == manifest('releaseB')['deploymentIdentity']['release']
    directory = root / 'candidates' / uuid.uuid4().hex
    directory.mkdir(mode=0o700)
    checkout = directory / 'source'
    git(original, 'clone', '--quiet', '--no-local', '--no-hardlinks', '--', str(original), str(checkout))
    for name in ('flake.nix', 'flake.lock'):
        shutil.copyfile(Path(fixture['sources']['releaseB']) / name, checkout / name)
    git(checkout, 'add', '.')
    git(checkout, 'commit', '-qm', 'Local release B projection')
    link = directory / 'executor'
    # Register a real indirect GC root for the prebuilt immutable executor.
    subprocess.run(['nix-store', '--realise', fixture['executors']['releaseB'],
                    '--add-root', str(link), '--indirect'], check=True)
    value = {'schema': 1, 'sourceRoot': str(checkout), 'sourceCommit': git(checkout, 'rev-parse', 'HEAD'),
             'originalRoot': str(original), 'originalCommit': original_commit, 'profile': profile,
             'consumerSource': manifest('releaseB')['deploymentIdentity']['consumerSource'],
             'release': release, 'executor': str(link.resolve()), 'rootLink': str(link)}
    state.write_json(directory / 'recovery.json', value)
    return value


adoption = review_root / 'adopt-a.json'
execute('releaseA', 'plan', '--profile', 'fixture-host', '--output', str(adoption))
execute('releaseA', 'apply', '--plan', str(adoption))
before = observe('releaseA', 'release-a')
native_before = native_snapshot()
release_b = manifest('releaseB')['deploymentIdentity']['release']
# An old direct-store PATH still refuses the upgrade; only the owned profile
# route may authorize the provider transition.
shadow_plan = review_root / 'direct-store-shadow.json'
old_uv = str(Path(before['uv']['resolved']).parent)
subprocess.run([fixture['executors']['releaseB'], 'plan', '--profile', 'fixture-host',
                '--output', str(shadow_plan)], check=True,
               env=dict(os.environ, PATH=old_uv + ':' + os.environ['PATH']))
shadow = state.read_json(shadow_plan, limit=state.MAX_PLAN_BYTES)
assert any(item['code'] == 'provider-shadowed' and item['path'] == old_uv + '/uv'
           for item in shadow['conflicts']), shadow['conflicts']
refused = subprocess.run([fixture['executors']['releaseB'], 'apply', '--plan', str(shadow_plan)],
                         env=dict(os.environ, PATH=old_uv + ':' + os.environ['PATH']),
                         capture_output=True, text=True)
assert refused.returncode == 1, refused
assert deployment.read_installed(home) == before['installed']
failure_marker = home / '.local/state/fixture/fail-after-stop'
failure_marker.touch()
with state.lock(root, blocking=True), \
        patch.object(releases, 'check', return_value=release_b), \
        patch.object(releases, 'validate_exact', side_effect=lambda record, state_root: releases.validate_record(record)), \
        patch.object(deployment, 'prepare', side_effect=prepare_local), \
        patch('sys.stdin', io.StringIO('yes\n')):
    try:
        deployment.install(root)
    except Conflict as error:
        assert 'transaction command failed' in str(error), error
    else:
        raise AssertionError('the genuine delegated service-stop failure must interrupt install')
pending = deployment.read_installed(home)
assert pending['state'] == 'pending' and pending['release'] is None, pending
interrupted = Journal(home, pending['transactionId']).data
assert interrupted['steps']['stop-services'] == 'intent', interrupted['steps']
assert not any(name == 'activate' or name.startswith('archive-') for name in interrupted['steps'])
stopped = subprocess.run(['systemctl', '--user', 'is-active', 'tmux-workspace.service'],
                         capture_output=True, text=True)
assert stopped.returncode == 3 and stopped.stdout.strip() in ('inactive', 'failed'), stopped
retained = deployment.recovery(root, pending['transactionId'])
state.write_json(review_root / 'interrupted-b.json', pending)
failure_marker.unlink()
# Resume the retained executor/preview without discovery or a new plan.
deployment._execute(retained, ['apply', '--plan', retained['planPath']])
after = observe('releaseB', 'release-b')
assert native_snapshot() == native_before, 'update mutated a retained external native runtime'
retained = deployment.recovery(root, after['installed']['transactionId'])
plan = state.read_json(retained['planPath'], limit=state.MAX_PLAN_BYTES)
transition = next(item for item in plan['providerTransitions'] if item['command'] == 'uv')
assert transition['profile'] == str(home / '.nix-profile'), transition
assert transition['fromExecutable'] == before['uv']['resolved'], transition
assert transition['toExecutable'] == after['uv']['resolved'], transition
assert transition['fromExecutable'] != transition['toExecutable'], transition
assert before['uv']['version'] != after['uv']['version']
assert retained['release'] == release_b and Path(retained['rootLink']).is_symlink()
assert hashlib.sha256((json.dumps(plan, sort_keys=True, indent=2) + '\n').encode()).hexdigest() == retained['planSha256']
# Reapply the exact retained preview after activation, with its original caller
# PATH. This exercises post-activation native/provider transition reconciliation.
deployment._execute(retained, ['apply', '--plan', retained['planPath']])
assert native_snapshot() == native_before
with state.lock(root, blocking=True), patch('sys.stdin', io.StringIO('yes\n')):
    assert deployment.rollback(root, profiles['releaseA']['generation']) == 0
rolled_back = observe('releaseA', 'rolled-back-a')
assert native_snapshot() == native_before, 'rollback mutated a retained external native runtime'
assert git(original, 'rev-parse', 'HEAD') == original_commit
assert git(original, 'status', '--porcelain=v1') == ''
assert original_files == {name: (original / name).read_bytes() for name in original_files}
state.write_json(review_root / 'summary.json', {
    'boundary': 'offline discovery and prepared projection; real install/preview/activation/recovery/rollback',
    'releases': [value['installed']['release'] for value in (before, after, rolled_back)],
    'providers': [value['uv'] for value in (before, after, rolled_back)],
    'nativeRuntimeUnchanged': True, 'originalConsumerUnchanged': True,
    'interruptedInstall': pending, 'recoveredWithoutNewPreview': True,
    'retainedPlan': retained['planPath'], 'retainedExecutor': retained['executor'],
    'providerTransition': transition,
})
print('Actual release A -> B -> rollback A, changed uv and retained native runtimes verified.')
