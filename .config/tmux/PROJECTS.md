# Project and worktree windows

Run `t` from a project or a Git worktree to attach its shell session in the
current terminal. An editor session is created only when requested:

- `t` — attach the project's shell in the current terminal.
- `t --with-editor` — attach the shell and open its Neovim session in a separate
  Ghostty terminal.
- `t --editor` — attach the project's Neovim session in the current terminal.

Each physical worktree directory owns its sessions. Different worktrees of the
same repository have different Neovim instances, buffers, shells, and AI panes.
Opening a project leaves existing projects running. With `--with-editor`, put
the editor window on your code screen and keep the shell/AI window on the other.

Running `t` again reuses the project's shell. Running `t --with-editor` reuses
an already attached Neovim or opens a terminal for its detached session. If the
session survived, its buffers are retained; if Neovim exited, a new instance
starts. Plain `t` leaves a closed editor terminal closed. Run these commands
outside tmux.

The shell keeps the existing project session name. The editor uses a reserved
`nvim-<directory>-<directory-hash>` name. Both are independent tmux sessions, so
changing shell windows does not replace Neovim on the other screen. Automatic
workspace restoration keeps these names; the editor flags reconnect the pair
after restore.

The launcher requires Python 3.9+ and tmux. The editor flags require Neovim, and
separate desktop windows also require Ghostty. No AI provider starts
automatically. Run a CLI in the shell session, or use the native AI companion in
the development Neovim configuration. Its project-aware transport places the
managed AI window in the matching shell session and retains its owning Neovim
pane identity. The installed Neovim configuration does not yet activate the
development AI integration.

If a graphical window cannot open, `t` reports the error and leaves the sessions
available. Re-run `t --with-editor` from Ghostty to retry. Project selection still prefers an
existing session rooted at the exact current directory before the Git root.

## Switch between running sessions

Press **Alt+Space, then f** to open a fuzzy project picker. Each project appears
once, with its directory and session count. Type a project name or part of its
path, then press Enter. If the project has one session, this terminal switches
directly. If it has several, a second picker lets you search their names and
choose a session, including Neovim or any extra shell sessions.

The managed editor appears as **Editor · Neovim**. Other sessions appear as
**Terminal · name**, so extra terminals remain distinguishable. These are picker
labels; the actual tmux session names stay unchanged.

Escape or Ctrl+C at either step closes the picker without switching. Other
attached terminals keep their current sessions.

The picker groups sessions on the current tmux server by their exact starting
directory, even if a shell has since changed directories. Different worktrees
and different starting directories remain separate projects; it does not infer
Git roots or combine sessions with different paths. Every session remains
available within its project, and the picker never creates or closes sessions.
It requires tmux 3.2+, Python 3.9+, and fzf (included by both installation paths).
The picker uses its own fzf options; global fzf option overrides do not apply.

The helper is included automatically in fresh native and Nix installations.
Existing Nix-managed installations need the [documented restoration/re-adoption
procedure](../../nix/README.md#confirmed-release-updates) when adopting this new managed file; the current
updater does not handle changes to the managed target list.

## SSH and machines without a desktop

Install this configuration on the remote host. Open two local terminals, SSH to
the same host from both, and enter the same worktree directory. Run `t` in one
for its shells/AI, and `t --editor` in the other for its Neovim session. Both
processes and the files stay on that host. Repeat for each parallel worktree.

On SSH connections and Linux terminals without a display, `t --with-editor`
prepares the editor session and prints a reminder to attach it from another
terminal with `t --editor`. This also applies when SSH has X11 forwarding.
The remote host needs no graphical terminal. `t --editor` works on the desktop
too, to attach the editor in the current terminal explicitly.

Disconnecting the SSH terminals detaches their tmux clients; the server's
sessions keep running. Reconnect and run the same commands to resume them.
As with the desktop workflow, run these commands outside tmux. A server reboot
is a separate event handled by workspace restoration, not by SSH reconnection.

Running `t` from an existing SSH connection does not open additional windows on
your local machine. Each local window must establish its own SSH connection;
automatic local window creation would need a launcher running locally.

## Validate changes

From a complete repository checkout, run:

```sh
sh .config/tmux/tests/project-session.sh
python3 .config/tmux/tests/project-pairs.py
python3 -B nix/tests/test_session_navigator.py
sh .config/tmux/tests/workspace-state.sh
sh .config/tmux/tests/workspace-restore.sh
```

The launcher tests use private homes and tmux sockets with simulated graphical
windows. The workspace tests also exercise real Neovim checkpointing. The
terminal-stack checker includes these suites; native Ghostty behavior still
needs a desktop check.
