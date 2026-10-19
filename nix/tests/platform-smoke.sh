#!/usr/bin/env python3
"""Migration smoke for an administrator-assigned disposable account/manager.

Despite the historical .sh name, this harness requires Python 3. Provision the
root-owned /etc/dotfiles-platform-fixture.json assignment described in nix/README.md.
It never provisions accounts, installs prerequisites or authorizes a live manager.
"""
import argparse
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import stat
import subprocess
import sys
import tempfile

def assignment_path(parent=Path('/etc')):
    # macOS /etc is an administrator-owned alias to /private/etc. Canonicalize
    # parents, but keep the leaf visible so a symlinked lease is still refused.
    return parent.resolve(strict=True) / 'dotfiles-platform-fixture.json'


def query(*args):
    executable = Path(shutil.which(args[0]) or args[0]).resolve(strict=True)
    info = executable.stat()
    if info.st_uid != 0 or info.st_mode & 0o022 or not stat.S_ISREG(info.st_mode):
        raise ValueError('manager query executable must be administrator-owned and non-writable')
    return subprocess.check_output([str(executable), *args[1:]], text=True,
                                   stderr=subprocess.STDOUT, timeout=30).strip()


def context(profile, fixture):
    # This administrator-owned declaration is a lease, not a readiness receipt.
    # No environment variable or user-owned file may grant manager authority.
    try:
        assignment = assignment_path()
        for path in [assignment, *assignment.parents]:
            info = path.lstat()
            if info.st_uid != 0 or info.st_mode & 0o022 or stat.S_ISLNK(info.st_mode):
                raise ValueError('unsafe administrator assignment path')
        if not assignment.is_file():
            raise ValueError('assignment must be regular')
        lease = json.loads(assignment.read_text())
    except OSError as error:
        raise ValueError('administrator fixture assignment is required') from error
    uid = os.getuid()
    account = pwd.getpwuid(uid)
    home = Path(account.pw_dir).resolve(strict=True)
    if (lease.get('schema') != 1 or lease.get('scope') not in ['disposable-vm', 'dedicated-account']
            or uid == 0 or lease.get('uid') != uid or lease.get('username') != account.pw_name
            or lease.get('home') != str(home) or Path(os.environ.get('HOME', '')).resolve() != home
            or lease.get('profile') != profile or profile.startswith('check-')
            or lease.get('fixtureRoot') != str(fixture) or fixture == home or home in fixture.parents):
        raise ValueError('assignment does not match actual user, home, profile and fixture root')
    info = fixture.lstat()
    if fixture.is_symlink() or not fixture.is_dir() or info.st_uid != uid or info.st_mode & 0o077:
        raise ValueError('assigned fixture root must be an existing private account-owned directory')
    if sys.platform.startswith('linux'):
        if (lease.get('system') != 'linux' or lease.get('machineId') != Path('/etc/machine-id').read_text().strip()
                or lease.get('bootId') != Path('/proc/sys/kernel/random/boot_id').read_text().strip()):
            raise ValueError('assignment does not match this machine/boot')
        runtime = Path('/run/user') / str(uid)
        if (runtime.is_symlink() or runtime.stat().st_uid != uid or runtime.stat().st_mode & 0o077
                or os.environ.get('XDG_RUNTIME_DIR') != str(runtime)
                or os.environ.get('DBUS_SESSION_BUS_ADDRESS') != 'unix:path=' + str(runtime / 'bus')
                or not stat.S_ISSOCK((runtime / 'bus').stat().st_mode)
                or (runtime / 'bus').stat().st_uid != uid):
            raise ValueError('current bus/runtime does not belong to the assigned account')
        pid = int(query('systemctl', 'show', 'user@' + str(uid) + '.service', '--property=MainPID', '--value'))
        process = Path('/proc') / str(pid)
        if (pid <= 1 or lease.get('managerPID') != pid or process.stat().st_uid != uid
                or lease.get('managerStart') != (process / 'stat').read_text().rsplit(')', 1)[1].split()[19]):
            raise ValueError('actual user manager differs from administrator assignment')
        query('systemctl', '--user', 'show-environment')
    elif sys.platform == 'darwin':
        hardware = query('/usr/sbin/ioreg', '-rd1', '-c', 'IOPlatformExpertDevice')
        match = re.search(r'"IOPlatformUUID"\s*=\s*"([^"]+)"', hardware)
        if (lease.get('system') != 'darwin' or not match or lease.get('machineId') != match[1]
                or int(query('/bin/launchctl', 'manageruid')) != uid
                or int(query('/bin/launchctl', 'managerpid')) != lease.get('managerPID')):
            raise ValueError('actual native launchd manager differs from assignment')
        query('/bin/launchctl', 'print', 'gui/' + str(uid))
    else:
        raise ValueError('unsupported native platform')
    source = Path(lease['sourceRoot']).resolve(strict=True)
    environment = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
    environment.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1')
    revision = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'],
                                       env=environment, text=True, timeout=30).strip()
    if revision != lease.get('sourceRevision'):
        raise ValueError('assigned source revision changed')
    return lease, source


def smoke(lease, source, fixture, profile):
    evidence = Path(tempfile.mkdtemp(prefix='smoke-', dir=fixture))
    status = {'scope': 'migration smoke only; native workflow acceptance is separate', 'commands': []}

    def run(*arguments):
        command = [str(source / '.config/dotfiles/bootstrap-nix'), '--source-root', str(source), '--', *arguments]
        with (evidence / (str(len(status['commands'])) + '.log')).open('xb') as log:
            result = subprocess.run(command, cwd=evidence, stdout=log, stderr=subprocess.STDOUT)
        status['commands'].append({'argv': command, 'exit': result.returncode})
        if result.returncode:
            raise subprocess.CalledProcessError(result.returncode, command)

    try:
        (evidence / 'assignment.json').write_text(json.dumps(lease, indent=2) + '\n')
        run('plan', '--profile', profile, '--output', 'plan.json')
        plan = json.loads((evidence / 'plan.json').read_text())
        if plan['conflicts']:
            raise ValueError('preview has conflicts; inspect retained evidence before any activation')
        run('apply', '--plan', 'plan.json')
        run('apply', '--plan', 'plan.json')
        run('rollback', '--generation', plan['nativeManifest']['activationPackage'])
        run('restore-legacy', '--transaction', plan['transactionId'])
        run('restore-legacy', '--transaction', plan['transactionId'])
        status['exit'] = 0
    except subprocess.CalledProcessError as error:
        status['exit'] = error.returncode if error.returncode > 0 else 128 - error.returncode
    except (OSError, ValueError, KeyError) as error:
        status.update(exit=1, error=str(error))
    finally:
        (evidence / 'result.json').write_text(json.dumps(status, indent=2) + '\n')
        print('Retained smoke evidence: ' + str(evidence))
    return status['exit']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile', required=True)
    parser.add_argument('--fixture-root', required=True, type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_-]+', args.profile):
        parser.error('invalid profile')
    fixture = args.fixture_root.resolve(strict=True)
    lease, source = context(args.profile, fixture)
    return smoke(lease, source, fixture, args.profile)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print('platform-smoke: ' + str(error), file=sys.stderr)
        sys.exit(1)
