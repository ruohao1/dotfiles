"""Read-only native migration preflight, distinct from Task6 workflow acceptance."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import socket
import stat
import subprocess

from .model import fingerprint, manifest_fingerprint

CLAIMS = {
    'ghostty': ['native-version', 'effective-config'],
    'space-mono-nerd-font': ['ghostty-font-catalogue', 'configured-family'],
    'uv-visidata': ['immutable-runtime-external-uv-probe'],
    'notebook-uv-project': ['frozen-project-lock', 'compatible-python-exact-metadata'],
    'desktop-clipboard': ['current-user-manager', 'local-session-permissions', 'native-clipboard-providers'],
    'linux-bubblewrap': ['root-owned-executable', 'namespace-and-production-runner'],
    'linux-default-timeout': ['command-p-gnu-timeout', 'bounded-timeout-behavior'],
}
PENDING = ['Task6 native application/editor/window-manager workflows and manual preferences/permissions']


def inspect_native(manifest, home):
    if not manifest['nativeDependencies']:
        return []
    home = Path(home)
    caller = os.environ.get('DOTFILES_CALLER_PATH', os.environ.get('PATH', os.defpath))
    environment = {'HOME':str(home), 'PATH':os.environ.get('PATH',os.defpath), 'LANG':'C', 'LC_ALL':'C',
        'PYTHONDONTWRITEBYTECODE':'1', 'UV_PYTHON_DOWNLOADS':'never', 'UV_OFFLINE':'1',
        'XDG_CONFIG_HOME':str(home/'.config'), 'XDG_DATA_HOME':str(home/'.local/share'),
        'XDG_CACHE_HOME':str(home/'.cache'), 'XDG_STATE_HOME':str(home/'.local/state')}
    binding = {'home':str(home), 'uid':os.getuid(), 'system':manifest['system'],
        'generation':manifest['activationPackage'], 'manifest':manifest_fingerprint(manifest),
        'collector':hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
    observations = {}
    queries = {}

    def observe(path):
        path = str(path)
        value = fingerprint(path)
        try:
            info = Path(path).lstat()
            value = dict(value, device=info.st_dev, inode=info.st_ino)
        except OSError:
            pass
        observations[path] = value
        return value

    def run(command, *, extra=None):
        key = json.dumps([command, extra], sort_keys=True)
        if key in queries:
            return queries[key]
        if command:
            observe(command[0])
        try:
            result = subprocess.run(command,env=environment | (extra or {}),cwd=home,
                text=True,capture_output=True,timeout=20)
            value = {'command':command,'context':extra or {},'status':result.returncode,'stdout':result.stdout,'stderr':result.stderr}
        except (OSError,subprocess.TimeoutExpired) as error:
            value = {'command':command,'context':extra or {},'status':None,'stdout':'','stderr':str(error)}
        queries[key] = value
        return value

    def provider(command, pinned=False):
        if pinned:
            entry = next((item for item in manifest.get('commandRequirements',[]) if item['command']==command and 'provider' in item),None)
            selected = str(Path(entry['provider'])/'bin'/command) if entry else None
        else:
            selected = shutil.which(command,path=caller)
        if selected:
            observe(selected)
        return selected

    def runtime_probe():
        nvim = provider('nvim',True)
        record = next((item for item in manifest['files'] if item['target']=='.config/nvim/lua/data_query/tool.lua'),None)
        if not nvim or record is None:
            return None
        source = Path(record['source']).resolve()
        if not str(source).startswith('/nix/store/'):
            return None
        runtime = source.parents[2]
        for name in ['lua/parquet/tool.lua','lua/data_query/tool.lua','scripts/data-query-runner.py']:
            observe(runtime/name)
        lua = "local p=require('parquet.tool').probe({refresh=true}); local d=require('data_query.tool').probe({refresh=true}); io.write(vim.json.encode({parquet=p,data_query=d})); vim.cmd('qa!')"
        # Neovim opens its log even with -u NONE and -i NONE. Observation must
        # not create first-use state; preserve the actual HOME/XDG probe context.
        result = run([nvim,'--headless','-u','NONE','-i','NONE','--cmd','set runtimepath^='+str(runtime),'+lua '+lua],
                     extra={'NVIM_LOG_FILE':'/dev/null'})
        try:
            if result['status'] != 0:
                return None
            parsed = json.loads(result['stdout'])
            # Lua table iteration order is not evidence. Retain every returned
            # field with canonical JSON so equivalent real probes revalidate.
            result['stdout'] = json.dumps(parsed, sort_keys=True, separators=(',', ':'))
            return parsed if isinstance(parsed, dict) else None
        except ValueError:
            return None

    ghostty = provider('ghostty')
    ghostty_results = {}
    def ghostty_query(action):
        if action not in ghostty_results:
            retained = home / '.config/ghostty/config.ghostty'
            source = next((item['source'] for item in manifest['files'] if item['target']=='.config/ghostty/config.ghostty'),None)
            config = retained if retained.is_file() else Path(source).resolve() if source else None
            observe(retained)
            if config is not None:
                observe(config)
            if ghostty and action in [('--version',), ('+list-fonts',)]:
                ghostty_results[action] = run([ghostty, *action])
            elif ghostty and config is not None and config.is_file():
                # Action-specific interfaces in pinned Ghostty: validate-config
                # accepts config-file; show-config only accepts its own flags.
                # An absent destination is inspected through the immutable XDG
                # config tree. HOME and native font-catalogue context stay real.
                if action == ('+validate-config',):
                    ghostty_results[action] = run([ghostty,*action,'--config-file='+str(config)])
                else:
                    context = {} if retained.is_file() else {'XDG_CONFIG_HOME':str(config.parents[1])}
                    ghostty_results[action] = run([ghostty,*action],extra=context)
            else:
                ghostty_results[action] = {'status':None,'stdout':''}
        return ghostty_results[action]

    session_ok = False
    backend = None
    session = {}
    linux = manifest['system'].endswith('-linux')
    if linux:
        runtime = Path(f'/run/user/{os.getuid()}')
        display = os.environ.get('WAYLAND_DISPLAY','')
        xdisplay = os.environ.get('DISPLAY','')
        xmatch = re.fullmatch(r':([0-9]+)(?:\.[0-9]+)?',xdisplay)
        session_type = 'wayland' if display else 'x11'
        bus = 'unix:path='+str(runtime/'bus')
        environment['XDG_RUNTIME_DIR'] = str(runtime)
        if (os.environ.get('XDG_RUNTIME_DIR',str(runtime)) == str(runtime)
                and os.environ.get('DBUS_SESSION_BUS_ADDRESS',bus)==bus
                and not any(os.environ.get(name) for name in ['SSH_CONNECTION','SSH_CLIENT','SSH_TTY'])
                and os.environ.get('XDG_SESSION_TYPE',session_type)==session_type
                and (re.fullmatch(r'[A-Za-z0-9_-][A-Za-z0-9_.-]*',display) if display else xmatch)):
            try:
                info=runtime.lstat()
                if not stat.S_ISDIR(info.st_mode) or info.st_uid!=os.getuid() or info.st_mode&0o077:
                    raise OSError('unsafe runtime')
                observe(runtime)
                # Directory entries change with ordinary session traffic. Bind
                # identity/mode, then independently bind the exact local sockets.
                observations[str(runtime)].pop('entries',None)
                sockets = [(runtime/'bus', {os.getuid()})]
                if display:
                    sockets.append((runtime/display, {os.getuid()}))
                    backend = 'wl-copy'
                    session = {'WAYLAND_DISPLAY':display}
                else:
                    directory = Path('/tmp/.X11-unix')
                    info=directory.lstat()
                    if (not stat.S_ISDIR(info.st_mode) or info.st_uid!=0
                            or (info.st_mode&0o022 and not info.st_mode&stat.S_ISVTX)):
                        raise OSError('unsafe X11 socket directory')
                    observe(directory)
                    observations[str(directory)].pop('entries',None)
                    sockets.append((directory/('X'+xmatch[1]), {0,os.getuid()}))
                    # The editor/tmux use their existing OSC 52 fallback on X11.
                    backend = 'osc52'
                    session = {'DISPLAY':xdisplay}
                for path, owners in sockets:
                    info=path.lstat(); observe(path)
                    if not stat.S_ISSOCK(info.st_mode) or info.st_uid not in owners:
                        raise OSError('foreign session socket')
                    with socket.socket(socket.AF_UNIX) as connection:
                        connection.settimeout(2); connection.connect(str(path))
                session_ok=True
                environment.update(session,DBUS_SESSION_BUS_ADDRESS=bus)
            except OSError:
                pass
    else:
        result=run(['/bin/launchctl','print',f'gui/{os.getuid()}'])
        session_ok=result['status']==0

    records=[]
    production=None
    for dependency in manifest['nativeDependencies']:
        identity=dependency['id']
        expected=CLAIMS.get(identity,['unknown-required-claim'])
        claims={claim:False for claim in expected}
        selected=None
        command=None
        if identity=='ghostty':
            selected,command=ghostty,'ghostty'
            version=ghostty_query(('--version',)); config=ghostty_query(('+validate-config',))
            claims['native-version']=version['status']==0 and bool(re.search(r'(?i)ghostty\s+\d+\.',version['stdout']))
            claims['effective-config']=config['status']==0
        elif identity=='space-mono-nerd-font':
            fonts=ghostty_query(('+list-fonts',)); config=ghostty_query(('+show-config','--changes-only'))
            claims['ghostty-font-catalogue']=fonts['status']==0 and 'SpaceMono Nerd Font Mono' in [line.strip() for line in fonts['stdout'].splitlines()]
            claims['configured-family']=config['status']==0 and 'font-family=SpaceMonoNerdFontMono' in [''.join(line.split()) for line in config['stdout'].splitlines()]
        elif identity in ['uv-visidata','linux-bubblewrap']:
            production=production if production is not None else runtime_probe()
            if identity=='uv-visidata':
                provider('uv')  # caller identity is independent of pinned probe execution
                parquet=(production or {}).get('parquet',{})
                data=(production or {}).get('data_query',{})
                claims[expected[0]]=parquet.get('ok') is True and data.get('duckdb',{}).get('ok') is True
                for key in ['environment','python']:
                    if parquet.get(key): observe(parquet[key])
            else:
                selected,command=provider('bwrap'),'bwrap'
                if selected:
                    info=Path(selected).stat()
                    claims[expected[0]]=info.st_uid==0 and not info.st_mode&0o022 and os.access(selected,os.X_OK)
                claims[expected[1]]=(production or {}).get('data_query',{}).get('ok') is True
        elif identity=='linux-default-timeout':
            discovery=run(['/bin/sh','-c','command -p -v timeout'])
            executable=discovery['stdout'].strip()
            if discovery['status']==0 and Path(executable).is_absolute():
                version=run([executable,'--version'])
                claims[expected[0]]=version['status']==0 and 'GNU coreutils' in version['stdout']
                test=run([executable,'0.1','/bin/sh','-c','while :; do :; done'])
                claims[expected[1]]=test['status']==124
        elif identity=='notebook-uv-project':
            project=home/'.config/nvim/python'
            python=home/'.local/share/nvim/notebook-python/bin/python'
            uv=provider('uv',True)
            for path in [project/'pyproject.toml',project/'uv.lock',python,python.with_name('jupyter'),python.with_name('jupytext')]: observe(path)
            if uv and python.is_file():
                lock=run([uv,'--no-config','--quiet','lock','--check','--offline','--no-cache','--python',str(python),'--project',str(project)])
                claims[expected[0]]=lock['status']==0
                code="import importlib.metadata as m,json,sys; e={'pynvim':'0.6.0','jupyter-client':'8.9.1','nbformat':'5.11.0','jupytext':'1.19.5','ipykernel':'7.3.0'}; a={n:m.version(n) for n in e}; assert (3,10)<=sys.version_info[:2]<(3,15); assert a==e,(a,e); print(json.dumps(a,sort_keys=True))"
                metadata=run([str(python),'-I','-B','-c',code])
                claims[expected[1]]=metadata['status']==0 and all(os.access(python.with_name(name),os.X_OK) for name in ['python','jupyter','jupytext'])
        elif identity=='desktop-clipboard':
            if linux:
                manager=next((x.get('systemctlPath') for x in manifest.get('serviceManagerEffects',[]) if x['manager']=='systemd'),None) or provider('systemctl')
                state=run([manager,'--user','is-system-running']) if manager else {'status':None,'stdout':''}
                claims[expected[0]]=state['status'] in [0,1] and state['stdout'].strip() in ['running','degraded']
                # Native capture stays outside HM ownership, including partial installs.
                capture = [observe(home/'.config'/name)['type']!='absent' for name in [
                    'hypr/hyprland.lua','hypr/hyprland.conf','clipboard-history/store','cliphist/config',
                    'systemd/user/cliphist.service.d/override.conf','systemd/user/cliphist.service',
                    'systemd/user/default.target.wants/cliphist.service',
                    'systemd/user/graphical-session.target.wants/cliphist.service']]
                commands=[provider(name) for name in (['wl-copy','wl-paste'] if backend=='wl-copy' or any(capture) else [])]
                if any(capture):
                    commands.extend([provider('cliphist'), backend=='wl-copy'])
            else:
                state=run(['/bin/launchctl','print',f'gui/{os.getuid()}'])
                claims[expected[0]]=state['status']==0
                commands=[provider(name) for name in ['pbcopy','pbpaste']]
            claims[expected[1]]=session_ok
            claims[expected[2]]=all(commands) and session_ok
        declared=dependency.get('requiredClaims',expected)
        if declared!=expected:
            claims['claim-contract-mismatch']=False
        record=dict(dependency,status='observed' if all(claims.values()) else 'unverified',
            claims=[{'claim':name,'status':'observed' if passed else 'unverified'} for name,passed in claims.items()],
            pending=PENDING,binding=binding,observations=dict(observations),queries=list(queries.values()))
        if identity=='desktop-clipboard' and linux:
            record.update(backend=backend,session=session)
        if command:
            record.update(command=command,selectedExecutable=selected)
            if selected is None: record['status']='missing'
        records.append(record)
    return records
