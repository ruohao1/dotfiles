"""Keep personal sources untouched and delegate deployment to a pinned executor."""
import hashlib
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import pwd
import re
import subprocess
import shlex
import tempfile
import uuid
from urllib.parse import quote

from . import UpdateError, state
from migration import status as migration_status
from migration.model import Conflict, canonical_home, safe_directory
from migration.transaction import Runtime


def _validator():
    installed = Path(__file__).resolve().parent.parent / 'bootstrap_nix.py'
    source = installed if installed.is_file() else Path(__file__).resolve().parents[2] / '.config/dotfiles/bootstrap-nix'
    loader = importlib.machinery.SourceFileLoader('dotfiles_bootstrap_nix', str(source))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module.validate_source


def validate_source(root):
    return _validator()(Path(root))


def _run(command, environment, *, timeout=600):
    result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise UpdateError(result.stderr.strip() or 'update preparation command failed')
    return result.stdout.strip()


def _git(root, args, environment):
    return _run(['git', '-c', 'core.hooksPath=/dev/null', '-c', 'core.fsmonitor=false',
                 '-C', str(root), *args], environment, timeout=60)


def _nix(args, environment):
    return _run(['nix', *args], environment)


def reference(root, revision):
    return 'git+file://' + quote(str(root), safe='/') + '?rev=' + revision


def profile_name(value):
    if not isinstance(value, str) or not re.fullmatch(r'[A-Za-z0-9_-]+', value) or value.startswith('check-'):
        raise UpdateError('configure a real named host profile')
    return value


def _resolve(lock, reference, seen=()):
    if len(seen) > 64:
        raise UpdateError('cyclic or excessive flake input graph')
    if isinstance(reference, str) and reference in lock['nodes']:
        return reference
    if isinstance(reference, list) and all(isinstance(x, str) for x in reference):
        key = tuple(reference)
        if key in seen:
            raise UpdateError('cyclic flake input follows')
        node = lock['root']
        for part in reference:
            node = _resolve(lock, lock['nodes'][node]['inputs'][part], (*seen, key))
        return node
    raise UpdateError('unsupported flake input reference')


def _graph(lock, node, seen=()):
    if node in seen or len(seen) > 64:
        raise UpdateError('cyclic or excessive flake input graph')
    value = lock['nodes'][node]
    if set(value) - {'locked', 'original', 'inputs', 'flake'} or type(value.get('flake', True)) is not bool:
        raise UpdateError('unsupported flake node semantics')
    return {'locked': value.get('locked'), 'flake': value.get('flake', True), 'inputs': {
        name: _graph(lock, _resolve(lock, ref), (*seen, node))
        for name, ref in value.get('inputs', {}).items()}}


def _input(lock):
    try:
        if lock['version'] != 7 or set(lock['nodes'][lock['root']]['inputs']) != {'dotfiles'}:
            raise UpdateError('v1 requires the one-input dotfiles consumer template')
        node = _resolve(lock, lock['nodes'][lock['root']]['inputs']['dotfiles'])
        locked = lock['nodes'][node]['locked']
        if (lock['nodes'][node].get('flake', True) is not True
                or locked.get('type') != 'github' or str(locked.get('owner')).lower() != 'ruohao1'
                or locked.get('repo') != 'dotfiles' or not re.fullmatch('[0-9a-f]{40}', locked.get('rev', ''))):
            raise UpdateError('consumer must pin the public ruohao1/dotfiles input')
        return node, locked['rev']
    except (KeyError, TypeError, RecursionError) as error:
        raise UpdateError('malformed consumer lock graph') from error


def _check_closure(lock, environment):
    node, revision = _input(lock)
    metadata = state.decode_json(_nix(['flake', 'metadata', '--json', '--no-update-lock-file',
                               'github:ruohao1/dotfiles/' + revision], environment))
    # Metadata can expose a lazy source path that is not materialized on disk.
    upstream = metadata.get('locks')
    if metadata.get('revision') != revision or not isinstance(upstream, dict):
        raise UpdateError('release metadata differs from the requested commit')
    try:
        actual = _graph(lock, node)['inputs']
        expected = _graph(upstream, upstream['root'])['inputs']
        if actual != expected:
            raise UpdateError('dotfiles transitive input overrides are unsupported')
    except (KeyError, TypeError, RecursionError) as error:
        raise UpdateError('malformed dependency closure') from error
    return revision


def _directory(path):
    try:
        path.mkdir(mode=0o700)
    except FileExistsError:
        pass
    safe_directory(path)


def prepare(source_root, profile, release, state_root):
    from .releases import validate_record
    release = validate_record(release)
    profile_name(profile)
    root, revision, environment = validate_source(source_root)
    if _git(root, ['rev-parse', '--show-superproject-working-tree'], environment):
        raise UpdateError('consumer source cannot be a Git submodule')
    if any(line.startswith('160000 ') for line in _git(root, ['ls-files', '--stage'], environment).splitlines()):
        raise UpdateError('consumer submodules are unsupported')
    lock = state.read_json(root/'flake.lock')
    _, old_revision = _input(lock)
    receipt = state.read_json(root/'dotfiles-release.json')
    if not re.fullmatch(r'100(644|755) [a-f0-9]+ 0\tdotfiles-release.json',
                        _git(root, ['ls-files', '--stage', '--', 'dotfiles-release.json'], environment)):
        raise UpdateError('consumer release receipt must be a tracked regular file')
    if validate_record(receipt)['commit'] != old_revision:
        raise UpdateError('consumer release receipt differs from its lock')
    _check_closure(lock, environment)
    state_root = Path(state_root)
    if state_root != state.open_state(canonical_home(os.environ.get('HOME', '')), create=False):
        raise UpdateError('candidate state must use the fixed private updater directory')
    safe_directory(state_root)
    parent = state_root/'candidates'
    _directory(parent)
    candidate = parent/uuid.uuid4().hex
    candidate.mkdir(mode=0o700)
    checkout = candidate/'source'
    _git(root, ['clone', '--quiet', '--no-local', '--no-hardlinks', '--no-checkout', '--template=',
                '--', str(root), str(checkout)], environment)
    _git(checkout, ['checkout', '--quiet', '--detach', revision], environment)
    _nix(['flake', 'update', 'dotfiles', '--flake', str(checkout), '--override-input',
          'dotfiles', 'github:ruohao1/dotfiles/'+release['commit']], environment)
    updated = state.read_json(checkout/'flake.lock')
    if _check_closure(updated, environment) != release['commit']:
        raise UpdateError('candidate lock did not select the reviewed release')
    state.write_json(checkout/'dotfiles-release.json', release)
    changed = set(_git(checkout, ['diff', '--name-only', revision], environment).splitlines())
    if changed - {'flake.lock', 'dotfiles-release.json'}:
        raise UpdateError('preparation changed personal host files')
    _git(checkout, ['add', '--', 'flake.lock', 'dotfiles-release.json'], environment)
    _git(checkout, ['-c', 'user.name=Dotfiles updater', '-c', 'user.email=dotfiles@localhost',
                    '-c', 'commit.gpgSign=false', 'commit', '--quiet', '--allow-empty',
                    '-m', 'Select dotfiles '+release['version']], environment)
    commit = _git(checkout, ['rev-parse', 'HEAD'], environment)
    ref = reference(checkout, commit)
    metadata = json.loads(_nix(['flake', 'metadata', '--json', '--no-update-lock-file', ref], environment))
    link = candidate/'executor'
    _nix(['build', '--no-update-lock-file', '--out-link', str(link), ref+'#dotfiles-executor'], environment)
    executor = str(link.resolve())
    value = {'schema': 1, 'sourceRoot': str(checkout), 'sourceCommit': commit,
             'originalRoot': str(root), 'originalCommit': revision, 'profile': profile,
             'consumerSource': metadata['path'], 'release': release,
             'executor': executor, 'rootLink': str(link)}
    _executor(value)
    state.write_json(candidate/'recovery.json', value)
    return value


def _identity(manifest):
    from .releases import validate_record
    if not isinstance(manifest, dict):
        raise UpdateError('invalid generation manifest')
    identity = manifest.get('deploymentIdentity')
    if identity is None:
        return None
    if (not isinstance(identity, dict) or set(identity) != {'schema', 'release', 'consumerSource', 'profile'}
            or type(identity['schema']) is not int or identity['schema'] != 1
            or not isinstance(identity['consumerSource'], str)
            or not re.fullmatch(r'/nix/store/[a-z0-9]{32}-[^/]+', identity['consumerSource'])):
        raise UpdateError('invalid generation release identity')
    profile_name(identity['profile'])
    return validate_record(identity['release'])


def read_installed(home):
    """Only the validated selected generation can claim an installed release."""
    home = canonical_home(home)
    try:
        observed = migration_status.inspect_status(home)
        result = {key: value for key, value in observed.items() if key not in ('manifest', 'retained')}
        result.update(release=None, retained=[
            {'generation': item['generation'], 'release': _identity(item['manifest'])}
            for item in observed['retained']])
        if observed['state'] == 'active':
            release = _identity(observed['manifest'])
            result.update(state='installed' if release else 'unversioned', release=release)
        return result
    except (Conflict, UpdateError, OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        return {'state': 'inconsistent', 'release': None, 'retained': [], 'detail': str(error)}


def configuration(root):
    value = state.read_json(Path(root)/'config.json')
    if (set(value) != {'schema', 'sourceRoot', 'profile'} or type(value['schema']) is not int
            or value['schema'] != 1 or not isinstance(value['sourceRoot'], str)
            or not Path(value['sourceRoot']).is_absolute() or '..' in Path(value['sourceRoot']).parts):
        raise UpdateError('invalid updater configuration; configure the consumer again')
    profile_name(value['profile'])
    return value


def validate_configuration(source, profile, home):
    from migration.plan import current_system
    root, revision, environment = validate_source(source)
    profile_name(profile)
    _, locked = _input(state.read_json(root/'flake.lock'))
    from .releases import validate_record
    if validate_record(state.read_json(root/'dotfiles-release.json'))['commit'] != locked:
        raise UpdateError('consumer release receipt differs from its lock')
    manifest = state.decode_json(_nix(['eval', '--json', '--no-update-lock-file',
        reference(root, revision)+'#homeConfigurations.'+profile+'.deploymentManifest'], environment))
    identity = manifest.get('deploymentIdentity', {})
    if (manifest.get('homeDirectory') != str(home) or manifest.get('username') != pwd.getpwuid(os.getuid()).pw_name
            or manifest.get('system') != current_system() or _identity(manifest) is None
            or identity.get('profile') != profile):
        raise UpdateError('consumer profile must declare this HOME, user, system and release identity')
    return dict(schema=1, sourceRoot=str(root), profile=profile)


def _executor(candidate):
    link = Path(candidate['rootLink'])
    safe_directory(link.parent)
    executor = candidate['executor']
    try:
        valid = (isinstance(executor, str) and re.fullmatch(r'/nix/store/[a-z0-9]{32}-[^/]+', executor)
            and link.is_symlink() and str(link.resolve(strict=True)) == executor
            and Path(executor).is_file() and os.access(executor, os.X_OK))
    except OSError:
        valid = False
    if not valid:
        raise UpdateError('retained executor root is missing or changed; use the original bootstrap-nix recovery source')
    return executor


def _execute(candidate, arguments):
    # Reuse process-group cancellation so interruption cannot leave activation running.
    runtime = Runtime(canonical_home(os.environ.get('HOME', '')))
    runtime.environment['PATH'] = candidate['callerPath']
    # Desktop and SSH evidence must be the same evidence the caller presented.
    for name in ('WAYLAND_DISPLAY', 'DISPLAY', 'XAUTHORITY', 'XDG_RUNTIME_DIR', 'XDG_SESSION_TYPE',
                 'DBUS_SESSION_BUS_ADDRESS', 'SSH_CONNECTION', 'SSH_CLIENT', 'SSH_TTY', 'NIX_CONFIG'):
        if name in os.environ:
            runtime.environment[name] = os.environ[name]
    runtime.run([_executor(candidate), *arguments])


def recovery(root, transaction):
    """Resolve the exact retained plan/executor; no network or fresh preview."""
    home = canonical_home(os.environ.get('HOME', ''))
    parent = Path(root)/'candidates'
    safe_directory(parent)
    matches = []
    for directory in parent.iterdir():
        safe_directory(directory)
        try:
            value = state.read_json(directory/'recovery.json')
        except FileNotFoundError:
            continue
        if value.get('transactionId') != transaction:
            continue
        required = {'schema', 'sourceRoot', 'sourceCommit', 'originalRoot', 'originalCommit', 'profile',
                    'consumerSource', 'release', 'executor', 'rootLink', 'transactionId', 'planPath',
                    'planSha256', 'manifestFingerprint', 'callerPath'}
        if (set(value) != required or type(value['schema']) is not int or value['schema'] != 1
                or value['rootLink'] != str(directory/'executor') or value['sourceRoot'] != str(directory/'source')
                or value['planPath'] != str(directory/'review.json')
                or not isinstance(value['callerPath'], str) or '\0' in value['callerPath']):
            raise UpdateError('invalid candidate recovery association')
        plan = state.read_json(directory/'review.json', limit=state.MAX_PLAN_BYTES)
        encoded = (json.dumps(plan, sort_keys=True, indent=2)+'\n').encode()
        if (hashlib.sha256(encoded).hexdigest() != value['planSha256']
                or plan.get('home') != str(home) or plan.get('transactionId') != transaction
                or plan.get('manifestFingerprint') != value['manifestFingerprint']):
            raise UpdateError('retained plan hash or transaction identity changed')
        _validate_preview(value, plan, home)
        _executor(value)
        reviewed_plan = migration_status.retained_plan(home, transaction)
        if reviewed_plan is not None and reviewed_plan != plan:
            raise UpdateError('retained preview differs from transaction journal')
        matches.append(value)
    if len(matches) != 1:
        raise UpdateError('no unique retained executor for this transaction; use its original bootstrap-nix recovery source')
    return matches[0]


def recovery_commands(candidate):
    prefix = ['env', 'HOME='+os.environ['HOME'], 'PATH='+candidate['callerPath'], candidate['executor']]
    restore = ['restore-legacy', '--transaction', candidate['transactionId']]
    command = ['apply', '--plan', candidate['planPath']]
    action = migration_status.recovery_action(os.environ['HOME'], candidate['transactionId'])
    if action['command'] == 'rollback':
        command = ['rollback', '--generation', action['generation']]
    elif action['command'] == 'restore-legacy':
        command = restore
    commands = [command] if command == restore else [command, restore]
    return '\n'.join(shlex.join(prefix+args) for args in commands)


def _validate_preview(candidate, plan, home):
    manifest = plan.get('nativeManifest', {})
    if not isinstance(manifest, dict):
        raise UpdateError('invalid preview manifest')
    identity = manifest.get('deploymentIdentity', {})
    if (plan.get('home') != str(home) or manifest.get('declaredProfile') != candidate['profile']
            or _identity(manifest) != candidate['release'] or identity.get('profile') != candidate['profile']
            or identity.get('consumerSource') != candidate['consumerSource']
            or not re.fullmatch('[a-f0-9]{32}', plan.get('transactionId', ''))
            or not re.fullmatch('[a-f0-9]{64}', plan.get('manifestFingerprint', ''))):
        raise UpdateError('preview does not match the reviewed consumer and release')
    if not isinstance(plan.get('conflicts'), list) or plan['conflicts']:
        raise UpdateError('preview has unresolved conflicts: '+str(plan.get('conflicts')))


def _confirm(message):
    try:
        return input(message+' [y/N] ').strip().lower() in ('y', 'yes')
    except EOFError:
        return False


def install(root):
    from . import releases
    home = canonical_home(os.environ.get('HOME', ''))
    installed = read_installed(home)
    if installed['state'] != 'installed':
        raise UpdateError('installation is '+installed['state']+'; complete explicit consumer adoption or retained recovery first')
    config = configuration(root)
    release = releases.check(root, force=True, identities=[installed['release'],
        *[item['release'] for item in installed['retained']]])
    if not release or not releases.is_newer(release, installed['release']):
        print('No newer stable release is available.')
        return 0
    releases.validate_exact(release, root)
    candidate = prepare(config['sourceRoot'], config['profile'], release, root)
    candidate['callerPath'] = os.environ.get('DOTFILES_UPDATE_CALLER_PATH', os.environ.get('PATH', os.defpath))
    review = Path(tempfile.mkdtemp(prefix='dotfiles-update-review-', dir='/tmp'))/'review.json'
    _execute(candidate, ['plan', '--profile', candidate['profile'], '--output', str(review)])
    plan = state.read_json(review, limit=state.MAX_PLAN_BYTES)
    _validate_preview(candidate, plan, home)
    retained = Path(candidate['rootLink']).parent/'review.json'
    state.write_json(retained, plan, limit=state.MAX_PLAN_BYTES)
    candidate.update(transactionId=plan['transactionId'], planPath=str(retained),
        planSha256=hashlib.sha256((json.dumps(plan, sort_keys=True, indent=2)+'\n').encode()).hexdigest(),
        manifestFingerprint=plan['manifestFingerprint'])
    state.write_json(retained.parent/'recovery.json', candidate)
    print(f"{installed['release']['version']} -> {release['version']} for {candidate['profile']}")
    print('Release notes: https://github.com/ruohao1/dotfiles/releases/tag/'+release['version'])
    print('Prior generation: '+installed['generation'])
    print('Reviewed plan: '+str(retained))
    print('Conflicts: 0. Native prerequisites: '+json.dumps(plan.get('nativePrerequisites', []), ensure_ascii=True))
    if not _confirm('Apply this update?'):
        print('Update declined; candidate retained.')
        return 0
    _, revision, _ = validate_source(candidate['originalRoot'])
    if revision != candidate['originalCommit']:
        raise UpdateError('personal source changed during review; prepare a new candidate')
    releases.validate_exact(release, root)
    try:
        _execute(candidate, ['apply', '--plan', candidate['planPath']])
    except BaseException:
        print('Update interrupted. Retained recovery commands (restore-legacy cancels an unpublished update or reverses a published handoff):')
        print(recovery_commands(candidate))
        raise
    print('Update applied; status follows the selected Home Manager generation.')
    return 0


def rollback(root, generation):
    observed = read_installed(canonical_home(os.environ.get('HOME', '')))
    choices = {item['generation']: item['release'] for item in observed['retained']}
    if observed['state'] not in ('installed', 'unversioned', 'pending') or generation not in choices:
        raise UpdateError('rollback target is not a retained generation; inspect status')
    candidate = recovery(root, observed['transactionId'])
    release = choices[generation]
    print('Rollback to '+(release['version'] if release else 'unversioned')+': '+generation)
    if not _confirm('Roll back to this generation?'):
        print('Rollback declined.')
        return 0
    _execute(candidate, ['rollback', '--generation', generation])
    print('Rollback applied; status follows the selected generation.')
    return 0
