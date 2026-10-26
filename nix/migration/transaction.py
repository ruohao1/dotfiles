"""Write-ahead handoff and explicit recovery. Failed operations retain evidence."""
import json
import copy
import os
from pathlib import Path
import pwd
import re
import shutil
import signal
import stat
import subprocess
import tempfile

from .model import Conflict, HomeLock, canonical_home, fingerprint, manifest_fingerprint, ownership_root, read_owner, safe_directory
from .plan import inspect, normalized_files, verify_unchanged
from .services import Services


def read_json(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd) as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
                raise Conflict('unsafe journal: ' + str(path))
            return json.load(stream)
    except (OSError, ValueError) as error:
        raise Conflict('unreadable or symlinked journal: ' + str(path)) from error


def directory(path, home):
    path = Path(path)
    if not path.is_relative_to(home):
        raise Conflict('transaction directory escapes home')
    for item in reversed([path, *path.parents]):
        if item == home or home in item.parents:
            try:
                item.mkdir(mode=0o700)
            except FileExistsError:
                pass
            safe_directory(item)


def write_json(path, value):
    path = Path(path)
    safe_directory(path.parent)
    if path.exists() or path.is_symlink():
        read_json(path)
    fd, name = tempfile.mkstemp(prefix='.' + path.name + '-', dir=path.parent)
    # Preserve an interrupted temporary journal instead of deleting evidence.
    with os.fdopen(fd, 'w') as stream:
        json.dump(value, stream, sort_keys=True, indent=2)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
    if path.is_symlink():
        raise Conflict('journal publication target became a symlink')
    os.replace(name, path)
    fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def leaf_state(path):
    state = fingerprint(path)
    if state['type'] == 'symlink':
        return {key: state[key] for key in ['type', 'mode', 'uid', 'gid', 'link']}
    if state['type'] == 'directory':
        # Taplo's inventoried installation can contain nested binary trees.
        # Snapshots must prove every retained byte without following symlinks.
        state['entries'] = {child.name: leaf_state(child) for child in sorted(Path(path).iterdir())}
    return state


def verify_deployed_files(manifest, home, *, allow_absent=False, alternatives=(), retained=()):
    choices = [{item['target']: item for item in normalized_files(other)} for other in [manifest, *alternatives]]
    targets = set().union(*(choice.keys() for choice in choices))
    inactive = {item['target'] for other in retained for item in normalized_files(other)} - targets
    for target in sorted(targets | inactive):
        path = home / target
        check_profile_parents(path, home)
        actual = fingerprint(path)
        if target in inactive:
            if actual['type'] != 'absent':
                raise Conflict('inactive managed file must be absent: ' + str(path))
            continue
        if allow_absent and actual['type'] == 'absent':
            continue
        def matches(item):
            expected = fingerprint(item['source'])
            if item['deployment'] == 'symlink':
                shape = path.is_symlink() and path.resolve() == Path(item['source']).resolve()
            else:
                shape = actual['type'] == 'file' and actual.get('mode') == int(item.get('mode', '0444'), 8)
            return shape and actual.get('sha256') == expected.get('sha256')
        if not any(matches(item) for item in [choice[target] for choice in choices if target in choice]):
            raise Conflict('activated file differs from reviewed source/type/mode: ' + str(path))


def profile_entries(value, modern):
    """Normalize explicit installed-profile queries, never store closure membership."""
    try:
        if not isinstance(value, dict) or (modern and value.get('version') != 3):
            raise ValueError('unknown profile query schema')
        packages = value['elements'] if modern else value
        if not isinstance(packages, dict):
            raise ValueError('missing profile entries')
        result = []
        for key, package in packages.items():
            name = key if modern else package['name']
            paths = package['storePaths'] if modern else list(package['outputs'].values())
            active = package['active'] if modern else True
            priority = package['priority'] if modern else None
            if (not isinstance(name, str) or not name or type(active) is not bool
                    or (modern and type(priority) is not int) or not isinstance(paths, list) or not paths
                    or any(not isinstance(path, str) or not re.fullmatch(r'/nix/store/[a-z0-9]{32}-[^/]+', path) for path in paths)):
                raise ValueError('unverified installed profile entry')
            result.append({'name': name, 'paths': sorted(paths), 'active': active, 'priority': priority})
        return sorted(result, key=lambda item: json.dumps(item, sort_keys=True))
    except (KeyError, TypeError, AttributeError, ValueError) as error:
        raise Conflict('unverified package profile query') from error


def is_home_package(entry):
    return entry['name'] == 'home-manager-path' or any(path.endswith('-home-manager-path') for path in entry['paths'])


def native_entries(entries):
    return [entry for entry in entries if not is_home_package(entry)]


def check_package_selection(entries, before, allowed, *, allow_missing=False):
    if native_entries(entries) != before:
        raise Conflict('native package profile entries changed; refusing to replace them')
    selected = [entry for entry in entries if is_home_package(entry)]
    if not selected and allow_missing:
        return
    if (len(selected) != 1 or not selected[0]['active'] or len(selected[0]['paths']) != 1
            or selected[0]['paths'][0] not in allowed):
        raise Conflict('package profile does not select the reviewed Home Manager package')


class Runtime:
    def __init__(self, home):
        self.home = Path(home)
        user = pwd.getpwuid(os.getuid()).pw_name
        self.environment = {'HOME': str(home), 'USER': user, 'LOGNAME': user,
            'PATH': os.environ.get('PATH', os.defpath), 'LANG': 'C', 'LC_ALL': 'C',
            'XDG_CONFIG_HOME': str(home / '.config'), 'XDG_CACHE_HOME': str(home / '.cache'),
            'XDG_DATA_HOME': str(home / '.local/share'), 'XDG_STATE_HOME': str(home / '.local/state'),
            'XDG_RUNTIME_DIR': f'/run/user/{os.getuid()}', 'NIX_STATE_DIR': '/nix/var/nix',
            'PYTHONDONTWRITEBYTECODE': '1'}

    def run(self, command):
        process = subprocess.Popen(command, env=self.environment, cwd=self.home, start_new_session=True)
        try:
            status = process.wait(timeout=600)
        except BaseException:
            # Activation may have grandchildren. Terminate the entire owned
            # group before a caller can begin explicit recovery.
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=0.5)
            except subprocess.TimeoutExpired:
                pass
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
            raise
        if status:
            raise Conflict('transaction command failed (partial effects retained): ' + ' '.join(command))

    def retain(self, generation, destination):
        self.run(['nix-store', '--realise', generation, '--add-root', str(destination)])

    def activate(self, generation):
        self.run([str(Path(generation) / 'activate')])

    def profile_packages(self, path):
        path = Path(path)
        check_profile_parents(path, self.home)
        if not path.exists() and not path.is_symlink():
            return []
        try:
            resolved = path.resolve(strict=True)
            info = resolved.stat()
        except OSError as error:
            raise Conflict('package profile is unavailable: ' + str(path)) from error
        if (resolved.parent != Path('/nix/store') or not stat.S_ISDIR(info.st_mode)
                or info.st_uid != 0 or info.st_mode & 0o022):
            raise Conflict('package profile does not resolve to an immutable store environment')
        modern = (resolved / 'manifest.json').is_file()
        if not modern and not (resolved / 'manifest.nix').is_file():
            raise Conflict('package profile has no supported installed manifest')
        executable = shutil.which('nix' if modern else 'nix-env', path=self.environment['PATH'])
        if not executable:
            raise Conflict('Nix package profile query is unavailable')
        arguments = (['--extra-experimental-features', 'nix-command flakes', 'profile', 'list', '--offline', '--json']
                     if modern else ['--query', '--json', '--out-path', '--option', 'substitute', 'false'])
        before = leaf_state(path)
        result = subprocess.run([executable, *arguments, '--profile', str(path)], env=self.environment,
                                cwd=self.home, text=True, capture_output=True, timeout=60)
        if result.returncode or leaf_state(path) != before or path.resolve(strict=True) != resolved:
            raise Conflict('package profile query failed or selected profile changed: ' + str(path))
        try:
            return profile_entries(json.loads(result.stdout), modern)
        except ValueError as error:
            raise Conflict('package profile query returned invalid JSON') from error

    def selected_generation(self, manifest):
        local = self.home / '.local/state/nix/profiles'
        # Match the pinned activation script, not the GCroot (which is not a selector).
        check_profile_parents(local / 'home-manager', self.home)
        directory = local if local.is_dir() else Path('/nix/var/nix/profiles/per-user') / manifest['username']
        selected = directory / 'home-manager'
        check_profile_parents(selected, self.home)
        return str(selected.resolve()) if selected.is_symlink() else None

    def verify_profiles(self, manifest):
        for text in manifest['profilePaths']:
            check_profile_parents(Path(text), self.home)
        generation = Path(manifest['activationPackage'])
        if self.selected_generation(manifest) != str(generation.resolve()) or not generation.is_dir():
            raise Conflict('selected Home Manager profile differs from reviewed generation')
        entries = self.profile_packages(self.home / '.nix-profile')
        check_package_selection(entries, native_entries(entries), {str((generation / 'home-path').resolve())})

    def verify(self, manifest):
        verify_deployed_files(manifest, self.home)
        self.verify_profiles(manifest)
        for requirement in manifest.get('commandRequirements', []):
            if 'native' in requirement:
                continue
            executable = str(Path(requirement['provider']) / 'bin' / requirement['command'])
            if not os.access(executable, os.X_OK):
                raise Conflict('selected executable unavailable: ' + executable)
            if requirement['command'] == 'taplo':
                self.run([executable, '--version'])
                self.run([executable, 'lsp', 'stdio', '--help'])


def profile_snapshot(manifest):
    result = {}
    pointer = re.compile(r'(?:profile|home-manager|(?:new|current)-home|\.nix-profile)$')
    for text in manifest['profilePaths']:
        path = Path(text)
        check_profile_parents(path, Path(manifest['homeDirectory']))
        if pointer.fullmatch(path.name):
            state = leaf_state(path)
            if state['type'] not in ['absent', 'symlink']:
                raise Conflict('package profile is not a reversible pointer: ' + text)
            result[text] = state
    return result


class Journal:
    def __init__(self, home, transaction, *, data=None):
        if not re.fullmatch(r'[a-f0-9]{32}', transaction):
            raise Conflict('invalid transaction ID')
        self.home = canonical_home(home)
        self.root = ownership_root(home) / 'transactions' / transaction
        self.path = self.root / 'journal.json'
        if data is None:
            for parent in [self.root.parent, self.root]:
                safe_directory(parent)
            data = read_json(self.path)
        self.data = data
        if data.get('schema') != 1 or data.get('home') != str(self.home) or data.get('transactionId') != transaction:
            raise Conflict('journal identity mismatch')
        if manifest_fingerprint(data['manifest']) != data['plan']['manifestFingerprint']:
            raise Conflict('journal manifest fingerprint mismatch')
        plan = data['plan']
        if (plan.get('home') != str(self.home) or plan.get('transactionId') != transaction
                or plan.get('journalPath') != str(self.root)
                or plan.get('originalsRoot') != str(self.root / 'originals')
                or plan.get('nativeManifest') != data['manifest']):
            raise Conflict('journal reservation or manifest identity mismatch')
        expected_paths = {str(self.home / item['target']) for item in normalized_files(data['manifest'])}
        architecture = data['manifest']['system'].split('-')[0]
        taplo = {str(self.home / '.local/bin/taplo'),
                 str(self.home / ('.local/opt/taplo-0.10.0-' + architecture))}
        if not data.get('parentTransaction'):
            expected_paths.update(item['path'] for item in plan['legacyTaplo'] if item['path'] in taplo)
        if {item['path'] for item in data['records']} != expected_paths or len(data['records']) != len(expected_paths):
            raise Conflict('journal record destinations differ from the reviewed manifest')
        for record in data['records']:
            expected_backup = self.root / 'originals' / Path(record['path']).relative_to(self.home)
            if record['backupPath'] != str(expected_backup):
                raise Conflict('journal backup destination differs from reserved path')
        pointers = {text for text in data['manifest']['profilePaths']
                    if re.fullmatch(r'(?:profile|home-manager|(?:new|current)-home|\.nix-profile)', Path(text).name)}
        if set(data['profilesBefore']) != pointers:
            raise Conflict('journal profile inventory differs from reviewed manifest')

    def save(self):
        write_json(self.path, self.data)

    def step(self, name, action):
        if self.data['steps'].get(name) == 'complete':
            return
        self.data['steps'][name] = 'intent'
        self.save()
        action()
        self.data['steps'][name] = 'complete'
        self.save()

    def owner(self, phase, generation=None):
        plan = self.data['plan']
        value = {'schema': 1, 'phase': phase, 'home': str(self.home),
                 'transactionId': self.data['transactionId'], 'manifestFingerprint': plan['manifestFingerprint'],
                 'selectedGeneration': generation or self.data['selectedGeneration'], 'journalPath': str(self.path)}
        write_json(ownership_root(self.home) / 'owner.json', value)

    def archive(self, source, destination, expected):
        source, destination = Path(source), Path(destination)
        directory(source.parent, self.home)
        directory(destination.parent, self.home)
        if leaf_state(destination)['type'] != 'absent':
            if leaf_state(destination) != expected:
                raise Conflict('archive collision or modified original: ' + str(destination))
            return
        if leaf_state(source) != expected:
            raise Conflict('original changed before archival: ' + str(source))
        source.rename(destination)


def validate_plan(plan, manifest):
    if manifest_fingerprint(manifest) != plan.get('manifestFingerprint'):
        raise Conflict('preview does not match current declared generation')
    fresh = inspect(manifest, plan['home'], transaction_id=plan['transactionId'])
    if fresh != plan or fresh['conflicts']:
        raise Conflict('preview changed, was edited, or contains unresolved conflicts')



def validate_profile_inputs(journal, runtime, generations, *, allow_missing):
    allowed = set(generations)
    home_paths = {str((Path(generation) / 'home-path').resolve()) for generation in allowed}
    allowed.update(home_paths)
    for text, before in journal.data['profilesBefore'].items():
        path = Path(text)
        check_profile_parents(path, journal.home)
        current = leaf_state(path)
        if current == before or (allow_missing and current['type'] == 'absent'):
            continue
        if current['type'] == 'symlink' and str(path.resolve()) in allowed:
            continue
        if current['type'] == 'symlink' and path.name in ['profile', '.nix-profile']:
            entries = runtime.profile_packages(path)
            check_package_selection(entries, journal.data['nativePackagesBefore'], home_paths, allow_missing=allow_missing)
            continue
        raise Conflict('unreviewed profile appeared before activation: ' + text)


def validate_activation_inputs(journal, runtime):
    """Permit only unfinished or reviewed outputs before replaying activation."""
    home, manifest = journal.home, journal.data['manifest']
    for item in normalized_files(manifest):
        directory((home / item['target']).parent, home)
    verify_deployed_files(manifest, home, allow_absent=True, retained=journal.data['generations'].values())
    validate_profile_inputs(journal, runtime, journal.data['generations'], allow_missing=True)


def verify_provider_transition(transition, journal, runtime):
    """Prove only the old/new selection authorized by activation's journal phase."""
    plan, home = journal.data['plan'], journal.home
    profile = home / '.nix-profile'
    command = transition['command']
    if transition['profile'] != str(profile) or str(profile) not in journal.data['profilesBefore']:
        raise Conflict('provider transition does not name the owned canonical profile')
    for prefix in ['from', 'to']:
        generation = transition[prefix + 'Generation']
        manifest = journal.data['generations'].get(generation)
        requirement = next((item for item in (manifest or {}).get('commandRequirements', [])
                            if item['command'] == command and 'provider' in item), None)
        if (requirement is None or str(profile) not in manifest['profilePaths']
                or str((Path(requirement['provider']) / 'bin' / command).resolve(strict=True)) != transition[prefix + 'Executable']
                or fingerprint(transition[prefix + 'Executable']) != transition[prefix + 'State']):
            raise Conflict('reviewed provider transition changed')
    if transition['toGeneration'] != journal.data['manifest']['activationPackage']:
        raise Conflict('provider transition selects an unreviewed generation')
    phase = journal.data['steps'].get('activate')
    allowed = (['from', 'to'] if phase == 'intent' else ['to'] if phase == 'complete' else ['from'])
    generation = runtime.selected_generation(journal.data['manifest'])
    direction = next((prefix for prefix in allowed if str(Path(transition[prefix + 'Generation']).resolve()) == generation), None)
    selected = shutil.which(command, path=plan['providerPath'])
    if (direction is None or selected != str(profile / 'bin' / command)
            or str(Path(selected).resolve(strict=True)) != transition[direction + 'Executable']):
        raise Conflict('caller provider transition differs from the proven activation phase')
    check_profile_parents(profile, home)
    check_package_selection(runtime.profile_packages(profile), journal.data['nativePackagesBefore'],
                            {str((Path(generation) / 'home-path').resolve())})
    return direction


def verify_resumed_native(journal, lock, runtime):
    """Reobserve readiness; reconcile only journal-proven deployment effects."""
    from .prerequisites import inspect_native, normalize_observations
    plan, home, manifest = journal.data['plan'], journal.home, journal.data['manifest']
    lock.recheck()
    caller = os.environ.get('DOTFILES_CALLER_PATH', os.environ.get('PATH', os.defpath))
    if (plan['providerPath'] != caller or plan['runtimePath'] != os.environ.get('PATH', os.defpath)
            or plan['uid'] != os.getuid()):
        raise Conflict('native retry provider PATH or user identity changed')
    transitions = {item['command']: item for item in plan.get('providerTransitions', [])}
    directions = {command: verify_provider_transition(item, journal, runtime) for command, item in transitions.items()}
    introduced_routes = {}
    for provider in plan['providers']:
        if fingerprint(provider['executable']) != provider['state']:
            raise Conflict('reviewed executable changed before resumed handoff')
        if provider['command'] in transitions:
            continue
        selected = shutil.which(provider['command'], path=caller)
        if selected is not None and Path(selected).resolve(strict=True) != Path(provider['executable']).resolve(strict=True):
            raise Conflict('caller executable no longer resolves to reviewed provider')
        if selected == provider['selectedExecutable']:
            continue
        # Activation can introduce the canonical route for an absent command or
        # one previously selected directly from its exact pinned provider.
        profile = home / '.nix-profile'
        generation = Path(manifest['activationPackage'])
        if (provider['selectedExecutable'] not in [None, provider['executable']]
                or journal.data['steps'].get('activate') not in ['intent', 'complete']
                or str(profile) not in journal.data['profilesBefore']
                or selected != str(profile / 'bin' / provider['command'])):
            raise Conflict('provider selection changed before resumed handoff')
        check_profile_parents(profile, home)
        if runtime.selected_generation(manifest) != str(generation.resolve()):
            raise Conflict('new caller provider does not select reviewed generation')
        check_package_selection(runtime.profile_packages(profile), journal.data['nativePackagesBefore'],
                                {str((generation / 'home-path').resolve())})
        introduced_routes[selected] = provider
    owned = {str(home / item['target']): item for item in normalized_files(manifest)}
    originals = {item['path']: item for item in plan['files']}
    records = {item['path']: (index, item) for index, item in enumerate(journal.data['records'])}
    for path, item in owned.items():
        check_profile_parents(Path(path), home)
        if fingerprint(item['source']) != originals[path]['sourceState']:
            raise Conflict('reviewed native configuration source changed: ' + item['source'])
    previous = copy.deepcopy(plan['nativePrerequisites'])
    current = inspect_native(manifest, home)
    if len(current) != len(previous) or any(item['status'] != 'observed' for item in current):
        raise Conflict('required native claims unavailable before resumed handoff')

    def permitted_leaf(path):
        actual = fingerprint(path)
        if actual == originals[path]['state']:
            return
        index, record = records[path]
        check_profile_parents(Path(record['backupPath']), home)
        if (actual['type'] == 'absent' and journal.data['steps'].get('archive-' + str(index)) in ['intent', 'complete']
                and leaf_state(record['backupPath']) == record['state']):
            return
        if journal.data['steps'].get('activate') in ['intent', 'complete']:
            verify_deployed_files(dict(manifest, files=[owned[path]]), home)
            return
        raise Conflict('native observation changed outside journal-proven deployment: ' + path)

    normalize_observations(previous, current, home=home, owned=owned,
                           introduced_routes=introduced_routes, permitted_leaf=permitted_leaf)
    for old, new in zip(previous, current):
        for path in old['observations'].keys() | new['observations'].keys():
            if old['observations'].get(path) == new['observations'].get(path):
                continue
            transition = next((item for command, item in transitions.items()
                               if directions[command] == 'to' and path == str(Path(item['profile']) / 'bin' / command)), None)
            if transition is not None and path in old['observations'] and path in new['observations']:
                before = {key: value for key, value in old['observations'][path].items() if key not in ['device', 'inode']}
                info = Path(path).lstat()
                after = dict(fingerprint(path), device=info.st_dev, inode=info.st_ino)
                if before != plan['evidence'][path] or new['observations'][path] != after:
                    raise Conflict('native owned-provider observation differs from reviewed transition')
                new['observations'][path] = old['observations'][path]
                continue
            if path not in owned or path not in old['observations'] or path not in new['observations']:
                raise Conflict('native provider or session observation changed: ' + path)
            permitted_leaf(path)
            new['observations'][path] = old['observations'][path]
    if current != previous:
        raise Conflict('native claims, provider binding or query results changed')
    lock.recheck()


def verify_transaction(journal, manifest, runtime):
    verify_deployed_files(manifest, journal.home, retained=journal.data['generations'].values())
    runtime.verify(manifest)
    if native_entries(runtime.profile_packages(journal.home / '.nix-profile')) != journal.data['nativePackagesBefore']:
        raise Conflict('native package profile entries changed during activation')
    Services(manifest, journal.home).verify_active()


def apply(plan, manifest, *, runtime=None):
    home = canonical_home(plan['home'])
    runtime = runtime or Runtime(home)
    owner = read_owner(home)
    new_transaction = owner is None or owner['transactionId'] != plan['transactionId']
    if new_transaction:
        if owner is not None and (owner['phase'] != 'home-manager' or plan.get('ownership') != owner):
            raise Conflict('another transaction owns this home')
        validate_plan(plan, manifest)
    with HomeLock(home, allow_owner=True) as lock:
        if new_transaction:
            verify_unchanged(plan, lock=lock)
            if read_owner(home) != owner:
                raise Conflict('ownership changed before apply')
            if owner is not None:
                previous = Journal(home, owner['transactionId'])
                if previous.data['phase'] != 'active' or previous.data.get('rollback', {}).get('state') == 'intent':
                    raise Conflict('complete the prior handoff or rollback before another apply')
                verify_transaction(previous, previous.data['generations'][owner['selectedGeneration']], runtime)
            services = Services(manifest, home)
            profiles = profile_snapshot(manifest)
            packages = runtime.profile_packages(home / '.nix-profile')
            if owner is None and any(is_home_package(entry) for entry in packages):
                raise Conflict('unrelated Home Manager package profile requires explicit recovery')
            records = [dict(path=item['path'], backupPath=item['backupPath'], state=leaf_state(item['path']))
                       for item in plan['files']]
            for item in ([] if owner else plan['legacyTaplo']):
                path = Path(item['path'])
                if path == home / '.local/bin/taplo' or path == home / ('.local/opt/taplo-0.10.0-' + manifest['system'].split('-')[0]):
                    records.append(dict(path=str(path), backupPath=str(Path(plan['originalsRoot']) / path.relative_to(home)), state=leaf_state(path)))
            retained = Journal(home, owner['transactionId']).data['generations'] if owner else {}
            data = {'schema': 1, 'home': str(home), 'transactionId': plan['transactionId'], 'plan': plan,
                    'manifest': manifest, 'selectedGeneration': plan['selectedGeneration'],
                    'servicesBefore': services.snapshot(), 'profilesBefore': profiles,
                    'nativePackagesBefore': native_entries(packages), 'records': records,
                    'generations': retained | {plan['selectedGeneration']: manifest},
                    'parentTransaction': owner['transactionId'] if owner else None, 'steps': {}, 'phase': 'prepared'}
            directory(Path(plan['journalPath']), home)
            journal = Journal(home, plan['transactionId'], data=data)
            journal.save()
        else:
            journal = Journal(home, plan['transactionId'])
            if journal.data['plan'] != plan or journal.data['manifest'] != manifest:
                raise Conflict('retry must use the exact original reviewed plan')
            if journal.data['phase'] in ['restoring', 'restored']:
                raise Conflict('handoff is being reversed; continue restore-legacy')
            if (journal.data.get('rollback', {}).get('state') == 'intent'
                    or (owner['phase'] == 'transferring' and journal.data.get('rollback'))
                    or journal.data['selectedGeneration'] != plan['selectedGeneration']):
                raise Conflict('generation selection changed; continue explicit rollback or create a new preview')
            verify_resumed_native(journal, lock, runtime)
            if journal.data['phase'] == 'active':
                verify_transaction(journal, manifest, runtime)
                return journal.data['transactionId']
        journal.step('publish-transferring', lambda: journal.owner('transferring'))
        roots = journal.root / 'generations'
        directory(roots, home)
        generation = plan['selectedGeneration']
        journal.step('retain-generation', lambda: runtime.retain(generation, roots / 'initial'))
        for index, state in enumerate(journal.data['profilesBefore'].values()):
            if state['type'] == 'symlink':
                # Keep prior package generations live independently of mutable pointers.
                path = list(journal.data['profilesBefore'])[index]
                resolved = str(Path(path).resolve(strict=True))
                journal.step('retain-profile-' + str(index), lambda p=resolved, i=index: runtime.retain(p, roots / ('profile-' + str(i))))
        if journal.data['steps'].get('activate') != 'complete':
            # A completed stop from before an interruption is not a current observation.
            journal.data['steps'].pop('stop-services', None)
            journal.step('stop-services', lambda: Services(manifest, home).stop())
        for index, record in enumerate(journal.data['records']):
            if record['state']['type'] != 'absent':
                journal.step('archive-' + str(index), lambda r=record: journal.archive(r['path'], r['backupPath'], r['state']))
        if journal.data['steps'].get('activate') != 'complete':
            validate_activation_inputs(journal, runtime)
        journal.step('activate', lambda: runtime.activate(generation))
        # Reobserve native readiness after activation and before publication too.
        verify_resumed_native(journal, lock, runtime)
        # Never publish ownership using a verification from before an interruption.
        journal.data['steps'].pop('verify', None)
        journal.step('verify', lambda: verify_transaction(journal, manifest, runtime))
        journal.step('publish-active', lambda: journal.owner('home-manager'))
        journal.data['phase'] = 'active'
        journal.save()
        return plan['transactionId']


def restore_legacy(home, transaction, *, runtime=None):
    home = canonical_home(home)
    runtime = runtime or Runtime(home)
    with HomeLock(home, allow_owner=True, recover=True) as lock:
        owner = read_owner(home)
        if owner is None:
            journal = Journal(home, transaction)
            if journal.data['phase'] == 'restored':
                return
            chain = [journal]
        else:
            chain = []
            selected = owner['transactionId']
            while selected is not None:
                if selected in [item.data['transactionId'] for item in chain]:
                    raise Conflict('cyclic recovery journal chain')
                journal = Journal(home, selected)
                chain.append(journal)
                selected = journal.data.get('parentTransaction')
            if transaction not in [item.data['transactionId'] for item in chain]:
                _cancel_unpublished_child(Journal(home, transaction), chain[0], owner, lock, runtime)
                return
        for journal in chain:
            if journal.data['phase'] != 'restored':
                _restore_frame(journal, lock, runtime)
        lock.recheck()
        owner = read_owner(home)
        if owner is not None:
            if owner['transactionId'] not in [item.data['transactionId'] for item in chain]:
                raise Conflict('ownership changed during recovery')
            (ownership_root(home) / 'owner.json').unlink()


def _cancel_unpublished_child(child, parent, owner, lock, runtime):
    # The initial journal save can precede ownership publication. Reversing
    # that frame must not restore or stop the still-active parent deployment.
    if (owner['phase'] != 'home-manager' or parent.data['phase'] != 'active'
            or parent.data.get('rollback', {}).get('state') == 'intent'
            or owner['journalPath'] != str(parent.path)
            or owner['manifestFingerprint'] != parent.data['plan']['manifestFingerprint']
            or owner['selectedGeneration'] != parent.data['selectedGeneration']
            or child.data.get('parentTransaction') != owner['transactionId']
            or child.data['plan'].get('ownership') != owner
            or child.data['phase'] not in ['prepared', 'restored']
            or child.data['steps'] not in [{}, {'publish-transferring': 'intent'}]
            or child.data.get('rollback')
            or child.data['selectedGeneration'] != child.data['plan']['selectedGeneration']
            or child.data['nativePackagesBefore'] != parent.data['nativePackagesBefore']):
        raise Conflict('another transaction owns this home; child is not provably unpublished')
    for record in child.data['records']:
        path, backup = Path(record['path']), Path(record['backupPath'])
        check_profile_parents(path, child.home)
        check_profile_parents(backup, child.home)
        if leaf_state(path) != record['state'] or leaf_state(backup)['type'] != 'absent':
            raise Conflict('unpublished child files changed; retaining recovery guard')
    for text, before in child.data['profilesBefore'].items():
        check_profile_parents(Path(text), child.home)
        if leaf_state(text) != before:
            raise Conflict('unpublished child profile changed; retaining recovery guard')
    verify_transaction(parent, parent.data['generations'][owner['selectedGeneration']], runtime)
    lock.recheck()
    if read_owner(child.home) != owner:
        raise Conflict('ownership changed during unpublished child recovery')
    if child.data['phase'] != 'restored':
        child.data['phase'] = 'restored'
        child.save()


def archive_profile(journal, path, current, label):
    check_profile_parents(path, journal.home)
    destination = journal.root / 'profiles-after' / label
    directory(destination.parent, journal.home)
    attempt = 0
    while leaf_state(destination)['type'] != 'absent' and leaf_state(destination) != current:
        attempt += 1
        destination = journal.root / 'profiles-after' / (label + '-' + str(attempt))
    if leaf_state(destination)['type'] == 'absent':
        destination.symlink_to(current['link'])
    if leaf_state(destination) != current or leaf_state(path) != current:
        raise Conflict('profile changed during recovery archival')
    # /nix profile pointers and the home journal can be on different filesystems.
    check_profile_parents(path, journal.home)
    path.unlink()


def check_profile_parents(path, home):
    """Reject redirected traversal without requiring ownership of /nix or /tmp."""
    for parent in reversed(Path(path).parents):
        try:
            info = parent.lstat()
        except FileNotFoundError:
            continue
        except OSError as error:
            raise Conflict('profile parent is inaccessible: ' + str(parent)) from error
        if not stat.S_ISDIR(info.st_mode):
            raise Conflict('profile parent is not a real directory: ' + str(parent))
        if parent == home or home in parent.parents:
            safe_directory(parent)


def restore_numbered_profiles(journal, runtime):
    allowed = set(journal.data['generations'])
    allowed.update(str((Path(generation) / 'home-path').resolve()) for generation in journal.data['generations'])
    for index, original in enumerate(journal.data['plan']['packageProfiles']):
        path = Path(original['path'])
        check_profile_parents(path, journal.home)
        if leaf_state(path)['type'] != 'directory':
            continue
        for parent in [path, *path.parents]:
            if parent.is_symlink():
                raise Conflict('profile directory parent became a symlink: ' + str(parent))
        safe_directory(path)
        before = original['state'].get('entries', {})
        for name, expected in before.items():
            if re.fullmatch(r'(?:home-manager|profile)-[0-9]+-link', name) and fingerprint(path / name) != expected:
                raise Conflict('original numbered profile changed; retaining recovery guard: ' + str(path / name))
        for child in sorted(path.iterdir()):
            if child.name in before or not re.fullmatch(r'(?:home-manager|profile)-[0-9]+-link', child.name):
                continue
            current = leaf_state(child)
            if current['type'] != 'symlink':
                raise Conflict('created numbered profile is not a symlink: ' + str(child))
            if str(child.resolve()) not in allowed:
                if child.name.startswith('home-manager-'):
                    raise Conflict('unreviewed Home Manager generation appeared during handoff')
                entries = runtime.profile_packages(child)
                selected = [entry for entry in entries if is_home_package(entry)]
                if (len(selected) != 1 or not selected[0]['active'] or len(selected[0]['paths']) != 1
                        or selected[0]['paths'][0] not in allowed
                        or native_entries(entries) != journal.data['nativePackagesBefore']):
                    continue  # Preserve unrelated native/package-manager generations.
            name = 'restore-numbered-' + str(index) + '-' + child.name
            journal.data['steps'].pop(name, None)
            journal.step(name, lambda p=child, s=current, label=name: archive_profile(journal,p,s,label))


def _restore_frame(journal, lock, runtime):
    home = journal.home
    manifest = journal.data['manifest']
    journal.data['phase'] = 'restoring'
    journal.save()
    journal.owner('recovering')
    # Always reobserve and stop, including on recovery retry. A past completed
    # stop is no proof that a manager has not restarted a process meanwhile.
    journal.data['steps'].pop('restore-stop-services', None)
    journal.data['steps'].pop('restore-services', None)
    journal.step('restore-stop-services', lambda: Services(manifest, home).stop())
    for index, record in reversed(list(enumerate(journal.data['records']))):
        path, backup = Path(record['path']), Path(record['backupPath'])
        # Recovery may follow a long interruption. Never traverse replacement
        # parents while reading originals or archiving the current leaf.
        directory(path.parent, home)
        directory(backup.parent, home)
        step = 'restore-file-' + str(index)
        # Completed file restoration is not evidence about later user edits.
        # Reconcile each retry before releasing the guard, retaining new edits.
        if leaf_state(path) != record['state']:
            journal.data['steps'].pop(step, None)
        def restore(record=record, path=path, backup=backup):
            archived = leaf_state(backup)['type'] != 'absent'
            if not archived and record['state']['type'] != 'absent':
                if leaf_state(path) == record['state']:
                    return
                raise Conflict('original unavailable for recovery: ' + str(path))
            if archived and leaf_state(backup) != record['state']:
                raise Conflict('retained original changed: ' + str(backup))
            edits = journal.root / 'post-migration' / path.relative_to(home)
            current = leaf_state(path)
            if current == record['state']:
                return
            if current['type'] != 'absent':
                attempt = 0
                while leaf_state(edits)['type'] != 'absent':
                    attempt += 1
                    edits = journal.root / ('post-migration-' + str(attempt)) / path.relative_to(home)
                directory(edits.parent, home)
                path.rename(edits)
            if archived:
                directory(path.parent, home)
                if record['state']['type'] == 'symlink':
                    path.symlink_to(record['state']['link'])
                elif record['state']['type'] == 'directory':
                    shutil.copytree(backup, path, symlinks=True)
                else:
                    shutil.copy2(backup, path, follow_symlinks=False)
            if leaf_state(path) != record['state']:
                raise Conflict('original restoration verification failed: ' + str(path))
        journal.step(step, restore)
    restore_numbered_profiles(journal, runtime)
    for index, (text, expected) in enumerate(journal.data['profilesBefore'].items()):
        check_profile_parents(Path(text), home)
        step = 'restore-profile-' + str(index)
        if leaf_state(Path(text)) != expected:
            journal.data['steps'].pop(step, None)
        def restore_profile(text=text, expected=expected, index=index):
            path = Path(text)
            check_profile_parents(path, home)
            if leaf_state(path) == expected:
                return
            current = leaf_state(path)
            if current['type'] not in ['absent', 'symlink']:
                raise Conflict('profile pointer changed to unsafe type: ' + text)
            if current['type'] != 'absent':
                archive_profile(journal,path,current,str(index))
            if expected['type'] == 'symlink':
                path.symlink_to(expected['link'])
            if leaf_state(path) != expected:
                raise Conflict('profile restoration verification failed: ' + text)
        journal.step(step, restore_profile)
    for original in journal.data['plan']['packageProfiles']:
        if original['state']['type'] == 'symlink':
            check_profile_parents(Path(original['path']), home)
            if fingerprint(original['path']) != original['state']:
                raise Conflict('restored profile resolves differently from retained original: ' + original['path'])
    journal.step('restore-services', lambda: Services(manifest, home).restore(journal.data['servicesBefore']))
    lock.recheck()
    journal.data['phase'] = 'restored'
    journal.save()


def rollback(home, generation, *, runtime=None):
    """Select a retained reviewed generation without releasing HM ownership."""
    home = canonical_home(home)
    runtime = runtime or Runtime(home)
    with HomeLock(home, allow_owner=True, recover=True) as lock:
        owner = read_owner(home)
        if owner is None or owner['phase'] not in ['home-manager', 'transferring']:
            raise Conflict('generation rollback requires Home Manager ownership')
        journal = Journal(home, owner['transactionId'])
        if generation not in journal.data['generations']:
            raise Conflict('generation was not retained by this handoff')
        if journal.data['phase'] != 'active':
            raise Conflict('rollback cannot bypass an unfinished original handoff or recovery')
        prior = journal.data.get('rollback', {})
        retry = prior.get('state') == 'intent' or owner['phase'] == 'transferring'
        if retry:
            if (prior.get('state') not in ['intent', 'complete'] or prior.get('generation') != generation
                    or prior.get('fromGeneration') not in journal.data['generations']):
                raise Conflict('continue the exact recorded rollback or restore legacy')
            source_generation = prior['fromGeneration']
        else:
            source_generation = journal.data['selectedGeneration']
        manifest = journal.data['generations'][generation]
        current = journal.data['generations'][source_generation]
        if retry and prior['state'] == 'complete':
            verify_transaction(journal, manifest, runtime)
            lock.recheck()
            journal.owner('home-manager', generation)
            return
        choices = [manifest] if retry else []
        for text in manifest['profilePaths']:
            check_profile_parents(Path(text), home)
        verify_deployed_files(current, home, allow_absent=retry and prior['state'] == 'intent',
                              alternatives=choices, retained=journal.data['generations'].values())
        allowed = {source_generation, generation} if retry else {source_generation}
        selected = runtime.selected_generation(current)
        if selected not in allowed and not (retry and prior['state'] == 'intent' and selected is None):
            raise Conflict('selected Home Manager profile changed before rollback')
        validate_profile_inputs(journal, runtime, allowed, allow_missing=retry)
        check_package_selection(runtime.profile_packages(home / '.nix-profile'), journal.data['nativePackagesBefore'],
                                {str((Path(item) / 'home-path').resolve()) for item in allowed}, allow_missing=retry)
        # A rollback attempt is itself recoverable from the original handoff.
        journal.data['rollback'] = {'generation': generation, 'fromGeneration': source_generation, 'state': 'intent'}
        journal.save()
        journal.owner('transferring', generation)
        Services(journal.data['manifest'], home).stop()
        runtime.activate(generation)
        verify_transaction(journal, manifest, runtime)
        journal.data['selectedGeneration'] = generation
        journal.data['rollback']['state'] = 'complete'
        journal.save()
        lock.recheck()
        journal.owner('home-manager', generation)
