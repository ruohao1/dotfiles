"""Explicit release updates; local status never claims more than journal evidence."""
import argparse
import os
from pathlib import Path
import signal
import subprocess
import sys

from . import UpdateError, deployment, releases, state
from migration.model import Conflict, canonical_home


def _badge(observed, available):
    return ('update '+available['version']
            if available and observed['state'] == 'installed' and releases.is_newer(available, observed['release']) else '')


def _status(root, observed):
    print('Installation: '+observed['state'])
    if observed.get('release'):
        print('Installed: '+observed['release']['version'])
    if observed.get('generation'):
        print('Generation: '+observed['generation'])
    if observed.get('detail'):
        print(observed['detail'])
    for item in observed['retained']:
        print('Retained: '+(item['release']['version'] if item['release'] else 'unversioned')+' '+item['generation'])
    cache = releases.read_cache(root)
    if cache['release']:
        print('Available: '+cache['release']['version'])
        print('Release notes: https://github.com/ruohao1/dotfiles/releases/tag/'+cache['release']['version'])
    print('Last successful check: '+str(cache['lastSuccess'] or 'unknown'))
    if observed['state'] == 'pending' and observed.get('transactionId'):
        try:
            print('Pending recovery:\n'+deployment.recovery_commands(deployment.recovery(root, observed['transactionId'])))
        except (UpdateError, Conflict, OSError) as error:
            print('Recovery: '+str(error))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', action='version', version='dotfiles-update 1.0.0')
    commands = parser.add_subparsers(dest='command', required=True)
    configure = commands.add_parser('configure')
    configure.add_argument('--source-root', type=Path, required=True)
    configure.add_argument('--profile', required=True)
    status = commands.add_parser('status')
    status.add_argument('--tmux', action='store_true', help=argparse.SUPPRESS)
    commands.add_parser('check')
    commands.add_parser('install')
    rollback = commands.add_parser('rollback')
    rollback.add_argument('--generation', required=True)
    args = parser.parse_args(argv)
    tmux = args.command == 'status' and args.tmux
    try:
        home = canonical_home(os.environ.get('HOME', ''))
        if args.command in ('install', 'rollback') and not sys.stdin.isatty():
            raise UpdateError('interactive terminal required for confirmation')
        root = state.open_state(home, create=args.command == 'configure')
        observed = deployment.read_installed(home)
        if args.command == 'status' and not tmux:
            _status(root, observed)
            return 0
        if args.command == 'configure':
            config = deployment.validate_configuration(args.source_root, args.profile, home)
            with state.lock(root, blocking=True):
                state.write_json(root/'config.json', config)
            print('Configured consumer '+config['sourceRoot']+' ('+config['profile']+'). No activation performed.')
            return 0
        try:
            deployment.configuration(root)
        except FileNotFoundError:
            if tmux:
                return 0
            raise UpdateError('configure a clean consumer checkout first')
        if tmux:
            if observed['state'] != 'installed':
                return 0
            print(_badge(observed, releases.read_cache(root)['release']), flush=True)
        with state.lock(root, blocking=not tmux) as acquired:
            if not acquired:
                return 0
            identities = [observed.get('release'), *[item['release'] for item in observed['retained']]]
            if tmux:
                print(_badge(observed, releases.check(root, identities=identities)), flush=True)
            elif args.command == 'check':
                releases.check(root, force=True, identities=identities)
                _status(root, observed)
            elif args.command == 'install':
                return deployment.install(root)
            else:
                return deployment.rollback(root, args.generation)
        return 0
    except (UpdateError, Conflict, OSError, ValueError, KeyError, TypeError,
            subprocess.TimeoutExpired, InterruptedError, KeyboardInterrupt) as error:
        if tmux:
            print('', flush=True)
        else:
            print('dotfiles-update: '+str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    # Candidate Git files and temporary previews must remain privately writable.
    os.umask(0o077)
    def interrupted(number, frame):
        raise InterruptedError('interrupted; retained transaction recovery may be required')
    signal.signal(signal.SIGINT, interrupted)
    signal.signal(signal.SIGTERM, interrupted)
    sys.exit(main())
