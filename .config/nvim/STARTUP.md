# Startup screen

The configuration supports Neovim 0.12 or newer on Linux and macOS. Its core
editor and startup screen work from the Neovim directory alone with the configured
plugins installed. Plugin preparation remains a separate first-install step.

Native editor status stays visible in ordinary tmux. The dotfiles tmux stack can
take over status only after a successful publication to the editor's originating
session; failures or a disabled session status row restore native status. The
starter hides the row while its screen is visible in either environment.

The native statusline's rich Git segment requires the optional sibling
`dotfiles/git-summary` executable. Without it, mode, path, diagnostics and cursor
information remain available, with no Git polling. The startup screen's direct
Git summary below does not require that helper.

Set `vim.g.dotfiles_tmux_integration = false` before integration setup to disable
dotfiles status, workspace registration and pins. Standard tmux clipboard and
split navigation still work. The configured stack opts in through
`@dotfiles_foundation_loaded=1`; if replacing its `status-left`, `status-right` or
`status-format` manually, clear that marker or use the opt-out. Workspace
registration is checked at startup; enabling the stack later requires restarting
Neovim. Status handoff can recover while the editor stays open.

A bare `nvim` launch opens a single MiniStarter buffer. Opening a file, reading
stdin, restoring a session, or using a remote invocation keeps the usual startup
behavior.

| Key | Action |
| --- | --- |
| `p` | Pick a project discovered from recent files |
| `r` | Pick a recent file |
| `q` | Quit with normal `:quit` behavior |
| `j` / `k`, down / up | Cycle through the three actions |
| Enter | Run the selected action |

Projects is selected initially. A pointer and highlight identify the selection.
Project selection validates that the directory still exists before changing into
it and opening its file picker.

Inside a conventional Git repository, the screen also shows its name, branch or
detached HEAD, upstream divergence when available, up to five recent commits with
graph connectors, and up to twelve changed paths grouped by directory. The two
status columns distinguish index and worktree changes; untracked and conflicted
paths remain distinct. Omitted entries have a count. The commit count describes
the collected recent history, not the repository's total history. Clean and
unborn repositories have explicit messages.

The menu appears immediately while Git loads asynchronously. Git commands only
read the repository and share a three-second deadline. Missing objects in partial
clones are never fetched; collection falls back to the menu when they are needed.
The summary requires Git 2.45 or newer; older versions use the menu-only fallback
because they lack the no-fetch option.
Results refresh on a directory change and when the visible startup screen regains
focus; terminal and split-window resizing reuse the cached result. Closing the
buffer cancels its request. A Git failure leaves the menu usable and reports at
most one warning per startup buffer.
Non-repository directories show the menu alone. Discovery does not fall back to
a bare dotfiles repository such as `~/.cfg`.

User-wide Git ignore rules are respected. Repositories that configure external
Git clean/process filters, including through user-wide configuration, or track
submodules use the menu-only fallback. Git status can run commands from those
configurations, so automatic collection declines them before inspecting changes.

At 92 columns or wider, the menu sits beside the Git summary. Narrower windows
stack them and use a horizontal menu when it fits. Optional detail is reduced
first in short windows. In very small windows, all actions and the essential
repository summary remain available as scrollable content.
