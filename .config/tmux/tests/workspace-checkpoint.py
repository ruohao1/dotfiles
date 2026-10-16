#!/usr/bin/env python3
"""A blocked real Neovim must not hold the workspace checkpoint lock forever."""

import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time


def main():
    scripts = Path(__file__).resolve().parent.parent / 'scripts'
    nvim_root = scripts.parent.parent / 'nvim'
    tmux_binary = shutil.which('tmux')
    nvim_binary = shutil.which('nvim')
    assert tmux_binary and nvim_binary, 'tmux and Neovim are required'
    root = Path(tempfile.mkdtemp(prefix='rpc-', dir=os.environ.get('TMPDIR', '/tmp')))
    socket_path = root / 'tmux.sock'
    state = root / "state ' 雪"
    runtime = root / 'runtime'
    home = root / 'home'
    for directory in (home, state, runtime, root / 'cache', root / 'data', home / '.config'):
        directory.mkdir(mode=0o700)
    env = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(home / '.config'),
               XDG_STATE_HOME=str(state), XDG_RUNTIME_DIR=str(runtime),
               XDG_CACHE_HOME=str(root / 'cache'), XDG_DATA_HOME=str(root / 'data'),
               NVIM_LOG_FILE=str(root / 'nvim.log'), SHELL='/bin/sh',
               LANG='C.UTF-8', LC_ALL='C.UTF-8', TERM='xterm-256color',
               RPC_TEST_CONFIGURATION=str(nvim_root),
               TMUX_WORKSPACE_TESTING='1', TMUX_WORKSPACE_SOCKET=str(socket_path))
    for key in ('TMUX', 'TMUX_PANE', 'NVIM', 'NVIM_APPNAME'):
        env.pop(key, None)
    for key in tuple(env):
        if key.startswith('TMUX_WORKSPACE_') and key not in ('TMUX_WORKSPACE_TESTING', 'TMUX_WORKSPACE_SOCKET'):
            env.pop(key)
    init = root / 'init.lua'
    init.write_text('vim.opt.runtimepath:prepend(vim.env.RPC_TEST_CONFIGURATION)\nvim.o.more = true\n')
    rpc_script = root / 'rpc.lua'
    rpc_script.write_text('''local channel = vim.fn.sockconnect("pipe", arg[1], { rpc = true })
assert(channel > 0, "could not connect to test editor")
local result = vim.rpcrequest(channel, arg[2], unpack(vim.json.decode(arg[3])))
io.write(vim.json.encode(result))
vim.fn.chanclose(channel)
''')

    def tmux(*args):
        return subprocess.check_output([tmux_binary, '-S', str(socket_path), *args],
                                       env=env, text=True, stderr=subprocess.PIPE).strip()

    def rpc(address, method, *args):
        result = subprocess.run([nvim_binary, '--headless', '-u', 'NONE', '-i', 'NONE',
                                 '-n', '-l', str(rpc_script), str(address), method,
                                 json.dumps(args)], env=env, capture_output=True,
                                text=True, timeout=3, check=True)
        return json.loads(result.stdout)

    def wait_for(predicate, label):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.03)
        raise AssertionError(label)

    def checkpoint():
        process = subprocess.Popen([str(scripts / 'workspace'), 'save'], env=env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, start_new_session=True)
        try:
            stdout, stderr = process.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.communicate(timeout=2)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate()
            raise AssertionError('a message pager blocked the entire workspace checkpoint past 10 seconds') from None
        assert process.returncode == 0, stderr
        generation = stdout.strip()
        assert generation == (state / 'dotfiles/tmux/current').read_text().strip()
        assert not (runtime / 'dotfiles-tmux/checkpoint.lock').exists(), 'checkpoint lock leaked'
        snapshot = state / 'dotfiles/tmux/snapshots' / generation
        manifest = json.loads((snapshot / 'snapshot.json').read_text())
        assert len(manifest['panes']) == 2, 'checkpoint lost an editor pane'
        return snapshot, {pane['key']: pane for pane in manifest['panes']}

    def has_session(snapshot, pane):
        relative = pane['process']['nvim_session']
        if relative is None:
            return False
        session = snapshot / relative
        assert session.is_file() and not session.is_symlink() and session.stat().st_size > 0
        assert session.stat().st_mode & 0o777 == 0o600
        return True

    def rpc_clients():
        processes = subprocess.check_output(['ps', '-axo', 'pid=,args='], text=True)
        return [line for line in processes.splitlines()
                if str(root) in line and '--remote-expr' in line]

    editors = []
    try:
        for index, name in enumerate(('blocked', 'healthy'), start=1):
            address = root / (name + '.sock')
            document = root / (name + ' file.txt')
            document.write_text('saved text\n')
            command = 'exec ' + shlex.join([nvim_binary, '-u', str(init), '-i', 'NONE',
                                           '-n', '--listen', str(address), str(document)])
            if index == 1:
                tmux('-f', str(scripts.parent / 'conf/options.conf'), 'new-session',
                     '-d', '-x', '80', '-y', '24', '-s', 'rpc', '-n', name, command)
            else:
                tmux('new-window', '-d', '-t', '=rpc:' + str(index), '-n', name, command)
            target = '=rpc:' + str(index)
            wait_for(address.exists, 'test editor did not open its socket')
            wait_for(lambda: not rpc(address, 'nvim_get_mode')['blocking'], 'test editor started blocked')
            pane = tmux('display-message', '-p', '-t', target, '#{pane_id}')
            pid = int(tmux('display-message', '-p', '-t', pane, '#{pane_pid}'))
            tmux('set-option', '-pt', pane, '@dotfiles_nvim_server', str(address))
            rpc(address, 'nvim_buf_set_lines', 0, 0, -1, True, ['unsaved test text'])
            tick = rpc(address, 'nvim_buf_get_changedtick', 0)
            editors.append({'pane': pane, 'pid': pid, 'address': address,
                            'document': document, 'tick': tick})

        blocked, healthy = editors
        snapshot, panes = checkpoint()
        assert all(has_session(snapshot, panes[e['pane']]) for e in editors), 'healthy editor checkpoint failed'
        print('ok - healthy editor sessions survive spaces, quotes, and Unicode in the state path', flush=True)

        tmux('send-keys', '-t', blocked['pane'], '-l', ':echo join(repeat(["checkpoint pager"], 80), "\\n")')
        tmux('send-keys', '-t', blocked['pane'], 'Enter')
        wait_for(lambda: rpc(blocked['address'], 'nvim_get_mode') == {'mode': 'rm', 'blocking': True},
                 'test did not reproduce the real message pager')
        snapshot, panes = checkpoint()
        assert not has_session(snapshot, panes[blocked['pane']]), 'blocked editor was reported as saved'
        assert has_session(snapshot, panes[healthy['pane']]), 'one blocked editor prevented a healthy editor checkpoint'
        warning = (state / 'dotfiles/tmux/last-warning').read_text()
        assert 'timed out' in warning and blocked['pane'] in warning, 'timeout warning does not identify the affected pane'
        assert rpc(blocked['address'], 'nvim_get_mode') == {'mode': 'rm', 'blocking': True}, 'checkpoint sent editor input'
        wait_for(lambda: not rpc_clients(), 'timed-out RPC client remained alive')
        for editor in editors:
            assert int(tmux('display-message', '-p', '-t', editor['pane'], '#{pane_pid}')) == editor['pid']
            assert editor['document'].read_text() == 'saved text\n', 'checkpoint wrote an unsaved buffer'
        print('ok - a real message pager times out without blocking other panes or leaking its client', flush=True)

        rpc(blocked['address'], 'nvim_input', '<Esc>')
        wait_for(lambda: not rpc(blocked['address'], 'nvim_get_mode')['blocking'], 'test pager did not close')
        snapshot, panes = checkpoint()
        assert all(has_session(snapshot, panes[e['pane']]) for e in editors), 'later checkpoint did not recover'
        for editor in editors:
            assert rpc(editor['address'], 'nvim_buf_get_changedtick', 0) == editor['tick'], 'checkpoint changed editor text'
        print('ok - the next checkpoint succeeds with editor processes and unsaved text preserved', flush=True)

        tmux('set-option', '-pt', blocked['pane'], '@dotfiles_nvim_server', str(root / 'missing.sock'))
        snapshot, panes = checkpoint()
        assert not has_session(snapshot, panes[blocked['pane']])
        assert has_session(snapshot, panes[healthy['pane']]), 'failed RPC blocked another editor'
        assert 'RPC failed' in (state / 'dotfiles/tmux/last-warning').read_text()
        assert not rpc_clients(), 'failed RPC client remained alive'
        print('ok - a missing editor socket reports failure and releases the checkpoint lock', flush=True)
    finally:
        subprocess.run([tmux_binary, '-S', str(socket_path), 'kill-server'], env=env,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3)
        wait_for(lambda: not rpc_clients(), 'test-owned RPC clients remained after cleanup')
        shutil.rmtree(root)


if __name__ == '__main__':
    try:
        main()
    except AssertionError as error:
        print('not ok - ' + str(error), file=sys.stderr)
        raise SystemExit(1)
