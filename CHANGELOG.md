# Changelog

## Unreleased

- Open `dotfiles` without arguments to choose native setup, configuration updates,
  source downloads, or recovery. Nix installations use their existing updater.
  Existing Git arguments continue to work. Full setup verifies the previewed
  commit before installing packages; configuration updates preserve local edits
  and apply only the reviewed fast-forward commit.
- Reject unsafe native recovery journals before rollback. Recheck the displayed
  recovery records before applying, and reject ambiguous native upstreams.
