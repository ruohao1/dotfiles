#!/usr/bin/env python3
"""Build an explicitly declared generation and write a read-only JSON preview."""
import argparse
import json
import os
from pathlib import Path
import re
import pwd
import subprocess
import sys
import signal

if __package__ in [None, '']:
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from migration.model import Conflict, canonical_home
from migration.plan import current_system, inspect, verify_unchanged


# Replaced only by the flake app factory in its immutable packaged copy.
PACKAGED_FLAKE_SOURCE = None


def nix_json(arguments):
    if PACKAGED_FLAKE_SOURCE is None:
        raise Conflict('Invoke the application with its packaged immutable source')
    arguments = [argument.replace('.#', 'path:' + PACKAGED_FLAKE_SOURCE + '#', 1)
                 if argument.startswith('.#') else argument for argument in arguments]
    arguments = [*arguments, '--no-update-lock-file']
    result = subprocess.run(['nix', *arguments], capture_output=True, text=True, timeout=600)
    if result.returncode:
        raise Conflict(result.stderr.strip() or 'Nix inspection/build failed')
    return result.stdout


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    plan_parser = commands.add_parser('plan', help='write a preview; no activation or service mutation')
    plan_parser.add_argument('--profile', required=True)
    plan_parser.add_argument('--output', required=True, type=Path)
    apply_parser = commands.add_parser('apply', help='apply exactly a reviewed preview')
    apply_parser.add_argument('--plan', required=True, type=Path)
    rollback_parser = commands.add_parser('rollback', help='select a retained reviewed generation')
    rollback_parser.add_argument('--generation', required=True)
    restore_parser = commands.add_parser('restore-legacy', help='reverse handoff, preserving recovery data')
    restore_parser.add_argument('--transaction', required=True)
    args = parser.parse_args(argv)
    if args.command != 'plan':
        from migration.transaction import apply, read_json, restore_legacy, rollback
        home = canonical_home(os.environ.get('HOME', ''))
        if args.command == 'apply':
            plan = read_json(args.plan)
            profile = plan.get('nativeManifest', {}).get('declaredProfile')
            if not isinstance(profile, str) or not re.fullmatch(r'[A-Za-z0-9_-]+', profile) or profile.startswith('check-'):
                raise Conflict('preview does not name a declared real profile')
            manifest = json.loads(nix_json(['eval', '--json', f'.#homeConfigurations.{profile}.deploymentManifest']))
            manifest['declaredProfile'] = profile
            inventory = os.environ.get('DOTFILES_PACKAGED_INVENTORY')
            if not inventory:
                raise Conflict('apply requires the packaged immutable command inventory')
            manifest['commandRequirements'] = json.loads(Path(inventory).read_text())
            if (plan.get('home') != str(home) or manifest['homeDirectory'] != str(home)
                    or manifest['username'] != pwd.getpwuid(os.getuid()).pw_name
                    or manifest['system'] != current_system()):
                raise Conflict('preview/profile does not match current home, user and system')
            apply(plan, manifest)
        elif args.command == 'rollback':
            rollback(home, args.generation)
        else:
            restore_legacy(home, args.transaction)
        print(args.command + ' completed')
        return 0
    if not re.fullmatch(r'[A-Za-z0-9_-]+', args.profile) or args.profile.startswith('check-'):
        raise Conflict('Declare a real profile in nix/hosts.nix; check profiles are disposable identities')
    home = canonical_home(os.environ.get('HOME', ''))
    output = args.output.absolute()
    if output.exists() or output.is_symlink():
        raise Conflict('Output already exists; choose an unused explicit output file')
    if output.parent.is_symlink() or not output.parent.is_dir():
        raise Conflict('Output parent must be an existing real directory')
    output = output.parent.resolve(strict=True) / output.name
    reference = f'.#homeConfigurations.{args.profile}'
    manifest = json.loads(nix_json(['eval', '--json', reference + '.deploymentManifest']))
    if manifest.get('homeDirectory') != str(home):
        raise Conflict('Profile home does not match canonical HOME; declare the actual identity before building')
    if manifest.get('username') != pwd.getpwuid(os.getuid()).pw_name:
        raise Conflict('Profile username does not match the current user')
    if manifest.get('system') != current_system():
        raise Conflict('Profile system does not match the current architecture/platform')
    # No out-link and no switch: only Nix store/cache effects and FILE are written.
    generation = nix_json(['build', '--no-link', '--print-out-paths', reference + '.activationPackage']).strip().splitlines()
    if generation != [manifest.get('activationPackage')]:
        raise Conflict('Built generation does not match evaluated deployment manifest')
    inventory_file = os.environ.get('DOTFILES_PACKAGED_INVENTORY')
    if inventory_file:
        manifest['commandRequirements'] = json.loads(Path(inventory_file).read_text())
    elif 'commandRequirements' not in manifest:
        raise Conflict('Pinned executable inventory is unavailable; invoke the packaged dotfiles application')
    manifest['declaredProfile'] = args.profile
    plan = inspect(manifest, home)
    # Prevent output from overwriting or changing any recorded migration input.
    for path, state in plan['evidence'].items():
        try:
            observed = Path(path).resolve()
        except (OSError, RuntimeError):
            # Broken/unsafe inputs remain reportable conflicts; no output can
            # traverse them because its existing parent was resolved strictly.
            observed = Path(path).absolute()
        directory = state['type'] == 'directory' or (state['type'] == 'symlink' and observed.is_dir())
        if output == observed or (directory and observed in output.parents):
            raise Conflict('Output would change a migration input; choose a separate review directory')
    verify_unchanged(plan)
    fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as stream:
        json.dump(plan, stream, indent=2, sort_keys=True)
        stream.write('\n')
    print(f'Preview written to {output}: {len(plan["conflicts"])} conflict(s)')
    return 0


if __name__ == '__main__':
    def interrupted(number, frame):
        raise InterruptedError('interrupted by signal ' + str(number) + '; explicit recovery may be required')
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        sys.exit(main())
    except (Conflict, OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(f'dotfiles: {error}', file=sys.stderr)
        sys.exit(1)
