"""Bounded current-user manager operations with explicit postconditions.

A failed command can have partial effects. Callers journal intent before invoking
these methods and never restore files until stop() has observed every unit safe.
"""
import configparser
import os
import plistlib
from pathlib import Path
import re
import shutil
import shlex

from .model import Conflict
from .plan import query


class Services:
    def __init__(self, manifest, home):
        self.home = Path(home)
        self.services = manifest['services']
        self.effects = {item['manager']: item for item in manifest['serviceManagerEffects']}

    def command(self, service, action, *arguments):
        manager = service['manager']
        if manager == 'systemd':
            executable = self.effects[manager].get('systemctlPath') or shutil.which('systemctl')
            command = [executable, '--user', action, *arguments]
        elif manager == 'launchd':
            executable = self.effects[manager].get('launchctlPath') or '/bin/launchctl'
            command = [executable, action, *arguments]
        else:
            raise Conflict('unsupported service manager: ' + manager)
        if not executable:
            raise Conflict('user service manager unavailable')
        return query(command, self.home)

    def checked(self, service, action, *arguments):
        result = self.command(service, action, *arguments)
        if result['status'] != 0:
            raise Conflict('service action failed (possibly partial): ' + ' '.join(result['command'])
                           + ': ' + result['stderr'])
        return result

    def state(self, service):
        name = service['name']
        if service['manager'] == 'systemd':
            result = self.command(service, 'show', name, '--property=LoadState,ActiveState,UnitFileState,FragmentPath,ExecStart,NeedDaemonReload')
            values = dict(line.split('=', 1) for line in result['stdout'].splitlines() if '=' in line)
            if (result['status'] not in [0, 4] or not {'LoadState', 'ActiveState', 'UnitFileState'} <= values.keys()
                    or values['LoadState'] not in ['loaded', 'not-found']
                    or values['ActiveState'] not in ['active', 'inactive', 'failed']):
                raise Conflict('unverified user service state: ' + name)
            installed = values['LoadState'] == 'loaded'
            provider = None
            if installed:
                fragment = values.get('FragmentPath', '')
                if not os.path.isabs(fragment) or values.get('NeedDaemonReload') not in ['yes', 'no']:
                    raise Conflict('unverified selected service definition: ' + name)
                provider = {'path': str(Path(fragment).resolve()), 'program': None, 'arguments': []}
                if service.get('kind') == 'service':
                    # Discard volatile process timestamps/PID, retaining the loaded command.
                    match = re.fullmatch(r'\{ path=([^;]+) ; argv\[\]=(.*?) ; ignore_errors=(?:yes|no)(?: ; [^{}]*)? \}', values.get('ExecStart', ''))
                    if not match or not os.path.isabs(match[1].strip()):
                        raise Conflict('unverified loaded service command: ' + name)
                    try:
                        arguments = shlex.split(match[2])
                    except ValueError as error:
                        raise Conflict('malformed loaded service arguments: ' + name) from error
                    if not arguments:
                        raise Conflict('missing loaded service arguments: ' + name)
                    provider.update(program=match[1].strip(), arguments=arguments)
            return {'installed': installed, 'enabled': values['UnitFileState'],
                    'active': values['ActiveState'] == 'active', 'provider': provider,
                    'needsReload': values.get('NeedDaemonReload') == 'yes'}
        domain = f'gui/{os.getuid()}'
        result = self.command(service, 'print', domain + '/' + name)
        disabled = self.checked(service, 'print-disabled', domain)
        if result['status'] == 0:
            installed = True
        elif result['status'] is not None and 'Could not find service' in result['stderr']:
            installed = False
        else:
            raise Conflict('unverified launchd state: ' + name)
        enabled = not bool(re.search(r'"' + re.escape(name) + r'"\s*=>\s*true', disabled['stdout']))
        provider = None
        if installed:
            text = result['stdout']
            path = re.search(r'^\s*path = (/[^\n]+)$', text, re.M)
            program = re.search(r'^\s*program = (/[^\n]+)$', text, re.M)
            arguments = re.search(r'^\s*arguments = \{\n(.*?)^\s*\}', text, re.M | re.S)
            if not path or not program or not arguments:
                raise Conflict('unverified selected launchd definition: ' + name)
            argv = [line.strip() for line in arguments[1].splitlines() if line.strip()]
            if not argv:
                raise Conflict('missing loaded launchd arguments: ' + name)
            provider = {'path': str(Path(path[1]).resolve()), 'program': program[1], 'arguments': argv}
        return {'installed': installed, 'enabled': enabled, 'provider': provider,
                'active': installed and bool(re.search(r'\bstate = running\b', result['stdout']))}

    def snapshot(self):
        return {service['name']: self.state(service) for service in self.services}

    def stop(self):
        for service in self.services:
            state = self.state(service)
            if service['manager'] == 'systemd':
                if state['active']:
                    self.checked(service, 'stop', service['name'])
            elif state['installed']:
                self.checked(service, 'bootout', f'gui/{os.getuid()}/{service["name"]}')
            after = self.state(service)
            if after['active'] or (service['manager'] == 'launchd' and after['installed']):
                raise Conflict('service did not stop safely: ' + service['name'])

    def restore(self, snapshot):
        for service in self.services:
            expected = snapshot[service['name']]
            name = service['name']
            if service['manager'] == 'systemd':
                self.checked(service, 'daemon-reload')
                current = self.state(service)
                if expected['installed']:
                    if expected['enabled'] in ['enabled', 'disabled'] and current['enabled'] != expected['enabled']:
                        self.checked(service, 'enable' if expected['enabled'] == 'enabled' else 'disable', name)
                    if expected['active'] and not current['active']:
                        self.checked(service, 'start', name)
                    elif current['active'] and not expected['active']:
                        self.checked(service, 'stop', name)
            else:
                domain = f'gui/{os.getuid()}'
                self.checked(service, 'enable' if expected['enabled'] else 'disable', domain + '/' + name)
                if expected['installed']:
                    self.checked(service, 'bootstrap', domain, str(self.home / service['files'][0]['target']))
                    if expected['active']:
                        self.checked(service, 'kickstart', domain + '/' + name)
            if self.state(service) != expected:
                raise Conflict('service restoration verification failed: ' + name)

    def expected_provider(self, service):
        # Compare the manager's loaded definition to the reviewed immutable source,
        # not merely to a pathname whose contents may have changed since loading.
        files = [item for item in service['files'] if
                 service['manager'] == 'launchd' or
                 item['target'] == '.config/systemd/user/' + service['name']]
        if len(files) != 1:
            raise Conflict('ambiguous selected service file: ' + service['name'])
        item = files[0]
        provider = {'path': str((self.home / item['target']).resolve()), 'program': None, 'arguments': []}
        try:
            if service['manager'] == 'launchd':
                with open(item['source'], 'rb') as stream:
                    configuration = plistlib.load(stream)
                arguments = configuration['ProgramArguments']
                program = configuration.get('Program', arguments[0])
                if not isinstance(arguments, list) or not arguments or not all(isinstance(arg, str) for arg in arguments):
                    raise ValueError('invalid ProgramArguments')
                provider.update(program=program, arguments=arguments)
            elif service.get('kind') == 'service':
                configuration = configparser.ConfigParser(interpolation=None, strict=False)
                configuration.read(item['source'])
                arguments = shlex.split(configuration['Service']['ExecStart'])
                if not arguments or not os.path.isabs(arguments[0]):
                    raise ValueError('invalid ExecStart')
                provider.update(program=arguments[0], arguments=arguments)
        except (OSError, KeyError, ValueError, IndexError, configparser.Error, plistlib.InvalidFileException) as error:
            raise Conflict('unverified reviewed service configuration: ' + service['name']) from error
        return provider

    def verify_active(self):
        for service in self.services:
            state = self.state(service)
            if not state['installed'] or (service.get('kind') in ['service', 'agent'] and not state['active']):
                raise Conflict('activated service is not ready: ' + service['name'])
            if state.get('needsReload') or state['provider'] != self.expected_provider(service):
                raise Conflict('activated manager selected an unexpected provider: ' + service['name'])
