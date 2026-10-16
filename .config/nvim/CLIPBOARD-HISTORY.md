# Shared clipboard history

Cliphist is the shared text history for Linux Wayland. Neovim reads the same
history captured by the user service; it does not keep a second database.

## Use it in Neovim

Press **Space p** in Normal mode or a characterwise/linewise Visual selection.
Type to filter the history, then use:

| Key | Action |
| --- | --- |
| Enter | Paste the selected entry into the original editing target |
| Ctrl-d | Delete the selected history entry and reload the picker |
| Esc | Cancel without editing the buffer |

Text keeps its whitespace, Unicode, and newlines. A final newline selects a
linewise clipboard register; a Normal-mode linewise paste inserts below the
current line. Visual mode replaces the selected text or whole lines in one undo
step. Blockwise selections are unsupported.

The picker remembers the original window, buffer, cursor, and selection. If that
target changes while the picker is open, reopen history before pasting.

| Command | Action |
| --- | --- |
| `:ClipboardHistoryClear` | Clear all retained history after confirmation |
| `:ClipboardHistoryPause` | Stop capture for the current user session |
| `:ClipboardHistoryResume` | Start capture again |

Pause and resume do not change service enablement. Pausing leaves existing
history available. Deleting or clearing history does not clear the current
system clipboard.

## Installation and capture

The Linux `hypr` bootstrap profile provisions Cliphist through its pacman package
manifest and deploys the capture helper, Cliphist policy, and systemd user-service
override. It requires Cliphist **0.7.0 or newer**, `wl-copy`, `wl-paste`, a Wayland
session, and the package's `cliphist.service` base unit. The Neovim picker also
requires Fzf 0.36 or newer and FzfLua.

Bootstrap enables `cliphist.service`. It starts capture immediately only when
`WAYLAND_DISPLAY` is set and `graphical-session.target` is active; otherwise
startup is deferred to the graphical session. Pre-existing service state is
preserved, and rollback undoes only service changes made by that transaction.

This recovery work produces a tested candidate. It does **not** install host
packages, integrate the candidate, or activate capture. Those are separate
integration and deployment steps.

## Storage and limits

- Only text clipboard changes are watched; images are excluded.
- At most **500 entries** are retained, with deduplication across all 500.
- Non-empty captures up to **1 MiB** are accepted; larger captures are discarded.
- Picker previews are limited to 100 characters. Decoding retrieves the original
  text, not the shortened preview.
- History lives at `$XDG_CACHE_HOME/cliphist/db`, or `~/.cache/cliphist/db` when
  `XDG_CACHE_HOME` is unset. The directory is mode `0700` and the database and
  capture temporary files are mode `0600`.

History is plaintext. Pause capture before copying text you do not want retained,
and use the confirmed clear command to remove existing entries. The helper
rejects unsafe history paths and removes its own temporary capture file on exit.

## Troubleshooting

An unavailable-history notification usually means Neovim selected a provider
other than `wl-copy`, a required executable is missing, or the session is not
Wayland. macOS, X11, tmux-only, and OSC 52 providers do not offer this picker.

For an empty history after deployment, check the current user's service with
`systemctl --user status cliphist.service` and verify the graphical session is
active. Capturing begins with subsequent clipboard changes. If configuration
was deployed manually, reload the user manager before restarting the service.
`store --prepare` uses the same XDG cache location as capture and secures existing
owned files; symlinked or foreign-owned history paths are rejected.

The terminal-stack checker uses synthetic text in private databases and never
reads the real clipboard by default. It reports live validation as skipped.
Setting `DOTFILES_CHECK_CLIPBOARD_HISTORY_LIVE=1` explicitly requests read-only
service-status checks; an end-to-end copy/paste check remains manual. On hosts
without Cliphist, its private runtime checks are reported as skipped. A synthetic
base unit can validate the override when the package unit is absent, without
claiming that live capture works.
