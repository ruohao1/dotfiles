# Project-scoped starter actions

The user approved replacing Projects with `f Find files` and restricting the
starter's `r Recent files` to the current project. Tmux owns project selection.

Use the existing `navigation.root.resolve()` policy: the starter's effective
working directory selects the nearest Git/Jujutsu root, or the directory itself
outside a repository. This follows the editor's current context; it does not
query or force tmux's original `session_path`. Both actions resolve at invocation
time and never change Neovim's working directory.

## Approaches

- Selected: reuse the file picker and add an optional root to the recent picker.
  This removes redundant project switching and works without tmux.
- Relabeling the old action would still switch projects, so does not meet intent.
- Querying tmux for a fixed root adds coupling and can disagree with the editor's
  directory and Git panel after an intentional directory change.

Keep the existing global recent-files shortcut unfiltered. Preserve starter Git
information, responsive layout, Alt navigation, and normal `q`/Ctrl+C behavior.
Remove project-discovery code and its picker once no callers remain. No new
plugins, root resolver, tmux configuration, or deployment changes.

Validate scoped versus global recent-file dispatch, actual filtering with the
installed fzf-lua, empty history, repository subdirectories, ordinary directories,
and starter navigation/selection. Review before installing changed runtime files
for new sessions, retaining backups and unrelated local configuration.
