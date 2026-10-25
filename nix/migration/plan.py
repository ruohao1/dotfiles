"""Read-only migration inspection; evidence is rechecked before later mutation."""
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import uuid

from .model import Conflict, canonical_home, fingerprint, manifest_fingerprint, ownership_root, read_owner, safe_directory


NATIVE_PATH_COMMANDS = {'ghostty': 'ghostty', 'linux-bubblewrap': 'bwrap'}


def current_system():
    architecture = {'AMD64': 'x86_64', 'arm64': 'aarch64'}.get(platform.machine(), platform.machine())
    operating_system = {'Linux': 'linux', 'Darwin': 'darwin'}.get(platform.system(), platform.system().lower())
    return f'{architecture}-{operating_system}'


def query(command, home, *, input_text=None):
    """Bounded read-only query with an explicit identity and no ambient manager bus."""
    environment = {'HOME': str(home), 'PATH': os.environ.get('PATH', os.defpath),
                   'LANG': 'C', 'LC_ALL': 'C', 'PYTHONDONTWRITEBYTECODE': '1',
                   'XDG_CONFIG_HOME': str(home / '.config'), 'XDG_DATA_HOME': str(home / '.local/share'),
                   'XDG_CACHE_HOME': str(home / '.cache'), 'XDG_STATE_HOME': str(home / '.local/state'),
                   'XDG_RUNTIME_DIR': f'/run/user/{os.getuid()}'}
    try:
        result = subprocess.run(command, input=input_text, capture_output=True, text=True,
                                timeout=10, env=environment, cwd=home)
        return {'command': command, 'status': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr}
    except (OSError, subprocess.TimeoutExpired) as error:
        return {'command': command, 'status': None, 'stdout': '', 'stderr': str(error)}


def relative_target(value):
    if (not isinstance(value, str) or not value or value.startswith('/')
            or any(part in ['', '.', '..'] for part in value.split('/'))
            or any(character in value for character in '\n\r\t')):
        raise Conflict(f'unsafe manifest target: {value!r}')
    return value


def normalized_files(manifest):
    entries = {}
    for file in manifest['files'] + [file for service in manifest['services'] for file in service['files']]:
        target = relative_target(file['target'])
        source = file.get('source')
        if not isinstance(source, str) or not Path(source).is_absolute():
            raise Conflict(f'invalid source for {target}')
        if file.get('deployment', 'symlink') not in ['symlink', 'owned-copy']:
            raise Conflict(f'unsupported deployment for {target}')
        normalized = dict(file, deployment=file.get('deployment', 'symlink'))
        if target in entries and entries[target] != normalized:
            raise Conflict(f'ambiguous overlapping manifest target: {target}')
        entries[target] = normalized
    targets = list(entries)
    for target in targets:
        if any(other != target and other.startswith(target + '/') for other in targets):
            raise Conflict(f'non-leaf deployment target: {target}')
    return list(entries.values())


def owned_provider_transition(manifest, home, prior, previous, requirement, selected):
    """Allow an old provider only through this home's proven owned profile."""
    from .transaction import Runtime, check_package_selection
    profile = home / '.nix-profile'
    command = requirement['command']
    old = next((item for item in previous.get('commandRequirements', [])
                if item['command'] == command and 'provider' in item), None)
    if (old is None or selected != str(profile / 'bin' / command)
            or str(profile) not in manifest['profilePaths']
            or str(profile) not in prior.data['profilesBefore'] or prior.data['phase'] != 'active'
            or prior.data.get('rollback', {}).get('state') == 'intent'):
        raise Conflict('provider is not selected through the owned package profile')
    before = str((Path(old['provider']) / 'bin' / command).resolve(strict=True))
    after = str((Path(requirement['provider']) / 'bin' / command).resolve(strict=True))
    if Path(selected).resolve(strict=True) != Path(before):
        raise Conflict('caller does not select the exact previous provider')
    runtime = Runtime(home)
    generation = str(Path(previous['activationPackage']).resolve())
    if runtime.selected_generation(previous) != generation:
        raise Conflict('selected generation differs from the owned previous generation')
    check_package_selection(runtime.profile_packages(profile), prior.data['nativePackagesBefore'],
                            {str((Path(generation) / 'home-path').resolve())})
    return dict(command=command, profile=str(profile), fromGeneration=previous['activationPackage'],
                toGeneration=manifest['activationPackage'], fromExecutable=before, toExecutable=after,
                fromState=fingerprint(before), toState=fingerprint(after))


def inspect(manifest, home, *, transaction_id=None):
    """Return a JSON plan including *all* observed conflicts, without writing home.

    Check identity profiles are useful in private fixtures only. The CLI rejects
    their names before invoking Nix; inspect retains the exact evaluated identity.
    Native declarations with no trustworthy current-home evidence are unverified.
    """
    required = {'schema', 'homeDirectory', 'username', 'system', 'activationPackage', 'files',
                'mutableSeeds', 'profilePaths', 'nativeDependencies', 'services', 'serviceManagerEffects'}
    if (not isinstance(manifest, dict) or not required <= set(manifest)
            or type(manifest['schema']) is not int or manifest['schema'] != 1):
        raise Conflict('unsupported or incomplete deployment manifest schema')
    home = canonical_home(home)
    transaction_id = transaction_id or uuid.uuid4().hex
    if not re.fullmatch(r"[a-f0-9]{32}", transaction_id):
        raise Conflict("invalid transaction reservation")
    journal = home / '.local/state/dotfiles-ownership/transactions' / transaction_id
    caller_path = os.environ.get('DOTFILES_CALLER_PATH', os.environ.get('PATH', os.defpath))
    plan = {'providerPath': caller_path, 'runtimePath': os.environ.get('PATH', os.defpath), 'uid': os.getuid(),
            'transactionId': transaction_id, 'journalPath': str(journal),
            'originalsRoot': str(journal / 'originals'), 'schema': 1, 'home': str(home), 'username': manifest['username'],
            'system': manifest['system'], 'profile': manifest.get('profile'),
            'manifestFingerprint': manifest_fingerprint(manifest),
            'selectedGeneration': manifest['activationPackage'],
            'files': [], 'mutableSeeds': [], 'providers': [], 'providerTransitions': [], 'packageProfiles': [],
            'services': [], 'serviceManagerEffects': manifest['serviceManagerEffects'],
            'nativePrerequisites': [], 'legacyTaplo': [], 'conflicts': [], 'evidence': {}, 'queries': []}

    def conflict(code, path, detail):
        plan['conflicts'].append({'code': code, 'path': str(path), 'detail': detail})

    def observe(path):
        path = str(Path(path))
        value = fingerprint(path)
        plan['evidence'][path] = value
        return value

    def command_state(command):
        if command:
            observe(command[0])
        result = query(command, home)
        plan['queries'].append(result)
        return result

    def parents(path):
        for parent in reversed(path.parents):
            if parent == home or home in parent.parents:
                state = observe(parent)
                if state['type'] not in ['directory', 'absent']:
                    conflict('unsafe-parent', parent, 'A deployed leaf would traverse a symlink or non-directory')
                    return False
                if state['type'] == 'directory':
                    try:
                        safe_directory(parent)
                    except Conflict as error:
                        conflict('unsafe-parent', parent, str(error))
                        return False
        return True

    if manifest['homeDirectory'] != str(home):
        conflict('home-mismatch', home, 'Declare a real profile with this canonical home before deployment')
    if manifest['system'] != current_system():
        conflict('system-mismatch', home, f"Manifest targets {manifest['system']}; host is {current_system()}")
    previous_files = {}
    retained_targets, retained_seeds = set(), set()
    selected_files = normalized_files(manifest)
    selected_targets = {item['target'] for item in selected_files}
    prior_journal = previous = None
    managed = False
    observe(home)
    generation = observe(manifest['activationPackage'])
    if generation['type'] not in ['directory', 'symlink']:
        conflict('missing-generation', manifest['activationPackage'], 'Selected activation generation is unavailable')
    try:
        root = ownership_root(home)
        observe(root)
        observe(root / 'owner.json')
        lock_state = observe(root / 'lock')
        owner = read_owner(home)
        plan['ownership'] = owner
        if owner is not None:
            if owner['phase'] == 'home-manager':
                from .transaction import Journal
                prior_journal = Journal(home, owner['transactionId'])
                previous = prior_journal.data['generations'][owner['selectedGeneration']]
                previous_files = {item['target']: item for item in normalized_files(previous)}
                retained_targets = {item['target'] for retained in prior_journal.data['generations'].values()
                                    for item in normalized_files(retained)}
                retained_seeds = {relative_target(item['target']) for retained in prior_journal.data['generations'].values()
                                  for item in retained['mutableSeeds']}
                managed = True
                if not set(previous_files) <= selected_targets:
                    conflict('changed-managed-targets', home, 'Removing or renaming owned targets requires explicit reversal before migration')
                service_targets = [{file['target'] for service in deployment['services'] for file in service['files']}
                                   for deployment in [previous, manifest]]
                if service_targets[0] != service_targets[1]:
                    conflict('changed-managed-services', home, 'Changing service targets requires explicit reversal before migration')
                observe(prior_journal.path)
            else:
                conflict('existing-ownership', root / 'owner.json', f"Home ownership phase: {owner['phase']}")
        if lock_state['type'] != 'absent':
            conflict('deployment-locked', root / 'lock', 'A deployer or interrupted transaction holds the home lock')
    except Conflict as error:
        plan['ownership'] = None
        conflict('unsafe-ownership', home / '.local/state/dotfiles-ownership', str(error))

    reservation_safe = parents(journal / 'originals')
    reservation = observe(journal) if reservation_safe else {'type': 'unsafe-parent'}
    observe(journal / 'originals') if reservation_safe else None
    if reservation['type'] != 'absent':
        conflict('transaction-collision', journal, 'Reserved transaction path is occupied; this exact reservation cannot be reused')

    for name in sorted(retained_targets - selected_targets):
        target = home / name
        if parents(target) and observe(target)['type'] != 'absent':
            conflict('inactive-managed-target', target, 'A retained generation reserves this inactive path; preserve it until explicitly resolved')

    for file in selected_files:
        target = home / file['target']
        safe_parents = parents(target)
        source = observe(file['source'])
        destination = observe(target) if safe_parents else {'type': 'unsafe-parent'}
        backup = journal / 'originals' / file['target']
        backup_safe = reservation_safe and parents(backup)
        backup_state = observe(backup) if backup_safe else {'type': 'unsafe-parent'}
        action = 'copy' if file['deployment'] == 'owned-copy' else 'link'
        record = dict(file, path=str(target), state=destination, sourceState=source, action=action, backupPath=str(backup))
        if source['type'] not in ['file', 'symlink'] or not source.get('sha256'):
            conflict('missing-source', file['source'], 'Source must resolve to an immutable regular file')
        prior = previous_files.get(file['target'])
        if managed and prior is None and any(file['target'] == name or file['target'].startswith(name + '/')
                                              for name in ['.config/systemd', 'Library/LaunchAgents']):
            conflict('changed-managed-services', target, 'Adding files in service directories requires explicit reversal before migration')
            record['action'] = 'preserve'
        if any(file['target'] != name and (file['target'].startswith(name + '/') or name.startswith(file['target'] + '/'))
               for name in retained_targets):
            conflict('retained-target-overlap', target, 'Managed leaves must not overlap paths reserved by retained generations')
        if any(file['target'] == name or file['target'].startswith(name + '/') or name.startswith(file['target'] + '/')
               for name in retained_seeds):
            conflict('mutable-seed-overlap', target, 'A retained mutable seed must remain user-owned')
            record['action'] = 'preserve'
        owned = prior is not None and ((destination['type'] == 'symlink' and Path(target).resolve() == Path(prior['source']).resolve())
            or (prior['deployment'] == 'owned-copy' and destination['type'] == 'file' and destination.get('sha256') == fingerprint(prior['source']).get('sha256')))
        if managed and prior is None and destination['type'] != 'absent':
            record['action'] = 'preserve'
            conflict('occupied-new-target', target, 'A newly managed path must be absent; existing contents will be preserved')
        elif owned:
            record['action'] = 'backup-and-' + action
        elif destination['type'] == 'symlink':
            record['action'] = 'preserve'
            conflict('preserved-symlink', target, 'Existing symlink is preserved; explicitly resolve this ownership conflict')
        elif destination['type'] == 'file':
            if destination.get('sha256') == source.get('sha256'):
                record['action'] = 'backup-and-' + action
            else:
                record['action'] = 'preserve'
                conflict('modified-file', target, 'Existing contents differ from selected source and will be preserved')
        elif destination['type'] != 'absent':
            record['action'] = 'preserve'
            conflict('file-type-conflict', target, f"Destination is {destination['type']}")
        if backup_state['type'] != 'absent':
            conflict('backup-collision', backup, 'Reserved backup name already exists and will be preserved')
        plan['files'].append(record)

    for seed in manifest['mutableSeeds']:
        target = home / relative_target(seed['target'])
        if any(seed['target'] == name or seed['target'].startswith(name + '/') or name.startswith(seed['target'] + '/')
               for name in retained_targets):
            conflict('retained-target-overlap', target, 'A mutable seed must not overlap paths reserved by retained generations')
        if any(record['target'] == seed['target'] for record in plan['files']):
            raise Conflict(f'mutable seed overlaps deployed leaf: {seed["target"]}')
        safe_parents = parents(target)
        state = observe(target) if safe_parents else {'type': 'unsafe-parent'}
        source = observe(seed['source'])
        if source['type'] not in ['file', 'symlink'] or not source.get('sha256'):
            conflict('missing-source', seed['source'], 'Mutable seed source is unavailable')
        plan['mutableSeeds'].append(dict(seed, state=state, action='seed' if state['type'] == 'absent' else 'preserve'))

    for path in sorted(set(manifest['profilePaths'])):
        if not isinstance(path, str) or not Path(path).is_absolute() or '..' in Path(path).parts:
            raise Conflict('unsafe package profile path')
        state = observe(path)
        plan['packageProfiles'].append({'path': path, 'state': state, 'action': 'preserve-unrelated-entries'})
        relevant = []
        if state['type'] == 'directory':
            relevant = [(name, item) for name, item in state['entries'].items()
                        if re.fullmatch(r'home-manager(?:-\d+-link)?|(?:new|current)-home', name)]
        elif re.fullmatch(r'home-manager(?:-\d+-link)?|(?:new|current)-home', Path(path).name) and state['type'] != 'absent':
            relevant = [(Path(path).name, state)]
        if relevant and not managed:
            conflict('unrelated-home-manager', path, 'Existing generation/profile evidence requires explicit recovery; never silently adopt it')

    for requirement in manifest.get('commandRequirements', []):
        if 'native' in requirement:
            continue
        command = requirement['command']
        if not re.fullmatch(r'[A-Za-z0-9._+-]+', command):
            raise Conflict('unsafe provider command name')
        executable = str(Path(requirement['provider']) / 'bin' / command)
        state = observe(executable)
        selected = shutil.which(command, path=caller_path)
        if selected:
            observe(selected)
        record = dict(requirement, executable=executable, state=state, selectedExecutable=selected)
        plan['providers'].append(record)
        if state['type'] not in ['file', 'symlink'] or not os.access(executable, os.X_OK):
            conflict('missing-provider', executable, 'Pinned provider executable is unavailable')
        # The packaged application supplies the pinned runtime PATH. Explicit
        # fixture providers may be absent from ambient PATH without becoming a
        # production bypass; activation will use this recorded exact path.
        owned_profile = managed and selected == str(home / '.nix-profile/bin' / command)
        generation_change = managed and previous['activationPackage'] != manifest['activationPackage']
        if selected and (Path(selected).resolve() != Path(executable).resolve() or (owned_profile and generation_change)):
            try:
                if not managed:
                    raise Conflict('caller has no owned previous generation')
                transition = owned_provider_transition(manifest, home, prior_journal, previous, requirement, selected)
                plan['providerTransitions'].append(transition)
                observe(transition['fromExecutable'])
                observe(transition['toExecutable'])
            except (Conflict, OSError, RuntimeError):
                conflict('provider-shadowed', selected,
                         f'Expected pinned provider {executable}; start a shell using the current canonical Nix profile')

    effects = {effect['manager']: effect for effect in manifest['serviceManagerEffects']}
    for service in manifest['services']:
        manager = service['manager']
        effect = effects.get(manager, {})
        if manager == 'systemd':
            executable = effect.get('systemctlPath') or shutil.which('systemctl')
            command = [executable, '--user', 'show', service['name'], '--property=LoadState,ActiveState,UnitFileState,FragmentPath,ExecStart,NeedDaemonReload'] if executable else []
        elif manager == 'launchd':
            executable = effect.get('launchctlPath') or shutil.which('launchctl')
            command = [executable, 'print', f'gui/{os.getuid()}/{service["name"]}'] if executable else []
        else:
            raise Conflict(f'unsupported service manager: {manager}')
        state = command_state(command) if command else {'command': [], 'status': None, 'stdout': '', 'stderr': 'manager unavailable'}
        if state['status'] is None or (manager == 'systemd' and state['status'] != 0):
            conflict('service-state-unverified', service['name'], state['stderr'] or 'User manager state could not be queried')
        elif manager == 'launchd' and state['status'] != 0 and not ('Could not find service' in state['stderr']):
            conflict('service-state-unverified', service['name'], 'launchctl failure does not prove the agent is absent')
        plan['services'].append(dict(service, state=state))

    # Retain old Taplo links, directories and journals verbatim, even when the
    # pinned provider will supersede them. Fingerprint children for later drift.
    opt = home / '.local/opt'
    parents(opt / 'taplo')
    observe(opt)
    artifacts = sorted(opt.glob('taplo-*')) if opt.is_dir() and not opt.is_symlink() else []
    for path in artifacts + [home / '.local/bin/taplo', home / '.local/state/dotfiles/taplo']:
        state = observe(path)
        if state['type'] != 'absent':
            plan['legacyTaplo'].append({'path': str(path), 'state': state, 'action': 'preserve'})
            if state['type'] == 'directory':
                for child in sorted(path.rglob('*')):
                    observe(child)

    from .prerequisites import inspect_native
    plan['nativeManifest'] = manifest
    plan['nativePrerequisites'] = inspect_native(manifest, home)
    for record in plan['nativePrerequisites']:
        for path, state in record['observations'].items():
            # Native session directories bind identity without unrelated entries.
            if state['type'] != 'directory' or 'entries' in state:
                observe(path)
        if record['status'] != 'observed':
            conflict('native-' + record['status'], record['id'],
                     record.get('description', 'Required native migration preflight claim is unverified'))
    return plan


def verify_unchanged(plan, *, lock=None):
    """Raise before mutation if any recorded file/provider/profile/service drifts."""
    if not isinstance(plan, dict) or plan.get('schema') != 1:
        raise Conflict('unsupported preview schema')
    home = canonical_home(plan['home'])
    caller_path = os.environ.get('DOTFILES_CALLER_PATH', os.environ.get('PATH', os.defpath))
    if (plan.get('providerPath') != caller_path or plan.get('uid') != os.getuid()
            or plan.get('runtimePath') != os.environ.get('PATH', os.defpath)):
        raise Conflict('preview provider selection PATH or user identity changed')
    if lock is not None:
        if lock.home != home:
            raise Conflict('held lock belongs to a different home')
        lock.recheck()
    changed = []
    for path, value in plan['evidence'].items():
        current = fingerprint(path)
        if lock is not None:
            current = lock.reconcile(path, current)
        if current != value:
            changed.append(path)
    for provider in plan['providers']:
        if shutil.which(provider['command'], path=caller_path) != provider['selectedExecutable']:
            changed.append('provider selection: ' + provider['command'])
    for native in plan['nativePrerequisites']:
        command = NATIVE_PATH_COMMANDS.get(native['id'])
        if command and (native.get('command') != command
                        or shutil.which(command, path=caller_path) != native.get('selectedExecutable')):
            changed.append('native provider selection: ' + command)
    from .prerequisites import inspect_native
    if inspect_native(plan['nativeManifest'], home) != plan['nativePrerequisites']:
        changed.append('native prerequisite claims or session changed')
    for old in plan['queries']:
        new = query(old['command'], home)
        if new != old:
            changed.append('service/provider query: ' + ' '.join(old['command']))
    if changed:
        raise Conflict('preview inputs changed: ' + ', '.join(changed))
