# Changelog

## Unreleased

- Restore Codex and Claude conversations when session metadata matches the
  current agent process. Use the picker when metadata is missing or stale.
  Native Linux supervisor restarts keep tmux sessions running. Use epoll for
  Ghostty on Linux to avoid the shared io_uring memory limit.
- Open `dotfiles` without arguments to choose native setup, configuration updates,
  source downloads, or recovery. Nix installations use their existing updater.
  Existing Git arguments continue to work. Full setup verifies the previewed
  commit before installing packages; configuration updates preserve local edits
  and apply only the reviewed fast-forward commit.
- Reject unsafe native recovery journals before rollback. Recheck the displayed
  recovery records before applying, and reject ambiguous native upstreams.
