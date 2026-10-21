# Line pins

Save a file location for later while working inside tmux. Neovim panes that originate in the same tmux session share their pins. Different sessions and servers keep separate lists; renaming a session preserves its pins. A pane linked into several sessions keeps its originating session as its scope. If that session disappears or the pane moves out of it, reopen Neovim in the intended session.

Pins require the configured dotfiles tmux stack and executable sibling
`tmux/scripts/location-pins` helper. Ordinary tmux, a missing helper, or
`vim.g.dotfiles_tmux_integration = false` leaves commands available to explain
the missing integration, without writing a pane association. Disabling the
session's status row alone does not disable pins or workspace persistence.

| Key | Command | Action |
| --- | --- | --- |
| `<leader>ha` | `:LinePinAdd` | Pin the current file, line, and column |
| `<leader>hh` | `:LinePins` | Search pins and preview current contents |
| `<leader>hd` | `:LinePinDelete` | Delete the pin at the current location |
| `<leader>hc` | `:LinePinsClear` | Confirm and clear the session's pins |

In the finder, press Enter to open a pin or Ctrl-x to delete it and refresh the list. Repeatedly adding the same location keeps one pin. Pins use fixed coordinates; after edits, jumping clamps the location to the file's current bounds. Missing files remain in the list and can be deleted.

Jumping never writes a buffer. Modified buffers stay available when `hidden` permits it; otherwise save the current buffer before switching. Buffers configured to disappear when hidden also require saving first. Preview tabs use eight display cells, regardless of the editor's tab width. File contents are read for previews but are not stored in pins.

Pins live in tmux and are included in normal workspace checkpoints. Restore brings them back in the corresponding sessions and restarts panes with their saved originating session. For older snapshots or panes where no editor has recorded an origin, restore uses the first saved session link. Old workspace snapshots without pins still restore. Killing a server before its next checkpoint loses changes since the last checkpoint. Outside tmux, pin actions explain that a session is required.

The helper requires tmux, jq, system iconv, and either sha256sum or shasum. Existing packages provide these tools; no additional Neovim plugin is needed. Malformed pin data produces an error instead of resetting the list.
