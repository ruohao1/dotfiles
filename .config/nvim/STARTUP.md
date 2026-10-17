# Startup screen

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
read the repository and share a three-second deadline. Results refresh on a
directory change and when the visible startup screen regains focus; resizing
reuses the cached result. Closing the buffer cancels its request. A Git failure
leaves the menu usable and reports at most one warning per startup buffer.
Non-repository directories show the menu alone. Discovery does not fall back to
a bare dotfiles repository such as `~/.cfg`.

Repositories that configure external Git clean/process filters or track
submodules use the menu-only fallback. Git status can run commands from those
configurations, so automatic collection declines them before inspecting changes.

At 92 columns or wider, the menu sits beside the Git summary. Narrower windows
stack them and use a horizontal menu when it fits. Optional detail is reduced
first in short windows. In very small windows, all actions and the essential
repository summary remain available as scrollable content.
