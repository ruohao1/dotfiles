# Dotfiles

A personal **Ghostty, tmux, and Neovim** setup for macOS and Linux, with optional
AeroSpace, i3, or Hyprland configuration.

## Install or update

You need macOS or Linux, `curl`, and Git 2.34+. Run as your normal user.
Paste this command to open the setup menu:

```sh
(
  set -eu
  launcher=$(mktemp)
  trap 'rm -f "$launcher"' 0
  curl --fail --location --show-error --silent \
    --output "$launcher" \
    https://raw.githubusercontent.com/ruohao1/dotfiles/main/.config/dotfiles/setup
  sh "$launcher"
)
```

After installation, open the same menu with:

```sh
dotfiles
```

| Action | What it does |
| --- | --- |
| Install or update configuration and tools | Preview packages, configuration, preferences, services, and backups; apply after confirmation. |
| Update configuration | Fast-forward an existing native installation. Keep its selected files, repository, and branch. Do not change packages or services. |
| Download source only | Create a separate checkout at a new destination. Do not install or activate it. |
| Restore a native installation backup | Restore a completed bootstrap transaction after confirmation. Installed packages remain. |

The menu shows the actions available for your installation. Enter `q`, press
Enter on an empty choice, or press Ctrl-C to exit. Apply confirmations default
to **No**. A changed source or local edit stops a configuration update; review
your changes with `dotfiles diff`. Existing Git commands such as `dotfiles status`
continue to work.

Full native setup asks for your window manager. `none` keeps your current one.

| System | Window-manager choices |
| --- | --- |
| macOS | `none`, `aerospace` |
| Arch, EndeavourOS, Manjaro | `none`, `i3`, `hypr` |
| Debian, Ubuntu, Linux Mint, Pop!_OS | `none`, `i3` |

On apt systems, the menu asks before permitting the pinned community Ghostty
installer. On Arch, bootstrap prints a `sudo pacman -Syu --needed …` command if
packages are missing; run it, then reopen the menu. The complete preview requires
Git; the menu does not install Git or Nix for you.

Full setup backs up conflicting configuration before replacing it. A
configuration-only update refuses local edits and does not create a bootstrap
backup. Restore applies to the last completed **full installation**, not the last
Git update.

After installation, reopen Ghostty. Reload affected applications after configuration
updates. If you selected a window manager, reload it or start a new desktop
session. For AeroSpace, enable Karabiner Elements background items and complete
its macOS permission setup.

For scripts or advanced native options, use the existing bootstrap directly:

```sh
# Preview; add --apply after reviewing the result.
"$HOME/.config/dotfiles/bootstrap" --window-manager none
```

## Start working

Make the installed commands available:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

Add this line to your shell configuration if needed; bootstrap leaves that
configuration unchanged.

From a project directory, outside tmux:

- **`t`** opens or resumes its shell session.
- **`t --editor`** opens Neovim in this terminal.
- **`t --with-editor`** opens the shell and a separate Ghostty editor window.

Neovim downloads its plugin manager on first use.

### Essential shortcuts

These bindings apply inside the configured Ghostty terminal.

| Action | Linux | macOS |
| --- | --- | --- |
| Find a project/session | Alt+Space, then `f` | Command+Space, then `f` |
| Move through Neovim splits and tmux panes | Alt+h/j/k/l | Command+h/j/k/l |
| New tmux tab | Alt+n | Command+n |
| Select a tmux tab | Alt+1–9 | Command+1–9 |
| Zoom or restore a pane | Alt+f | Command+f |

In Neovim, press **Space, f, f** to find a file or **Space, f, g** to search text.
Desktop window-manager shortcuts use **Super** on Linux and **Option** on macOS.

## Restore the previous configuration

To undo the latest completed native installation:

```sh
"$HOME/.config/dotfiles/bootstrap" --rollback latest
```

Rollback restores configuration, preferences, and service state. Installed
packages remain on the machine.

## Nix and Home Manager

For locked packages and Home Manager, follow the
[Nix migration guide](nix/README.md#installation-and-migration-experimental).
This route is **experimental**; platform and desktop/editor validation is
incomplete. It requires Nix, Git, and Python 3, plus separate preparation for
native apps, fonts, and OS permissions.

The menu detects Home Manager ownership and delegates updates and recovery to
`dotfiles-update`. It never falls back to native installation. Configure that
updater first as described in [release updates and rollback](nix/README.md#confirmed-release-updates).

When adopting this command, Nix can report an existing native
`~/.local/bin/dotfiles` symlink as `preserved-symlink` or `occupied-new-target`.
Review the reported path, move that exact command to an unused backup location,
then generate a new migration/update preview. The installer preserves this
conflict; it does not move or delete the native command automatically.

## More guides

- [Project sessions, multiple windows, and SSH](.config/tmux/PROJECTS.md)
- [Neovim start screen](.config/nvim/STARTUP.md)
- [Language tooling and health checks](.config/nvim/LANGUAGE-TOOLING.md)
- [Saved code locations](.config/nvim/LINE-PINS.md)

Native configuration lives in `~/.config/ghostty`, `~/.config/tmux`, and `~/.config/nvim`.
Bootstrap manages the bare Git repository in `~/.cfg` automatically.

For a fork, run `sh "$HOME/.config/dotfiles/setup" --repo URL --ref REF`, or pass
those options to the downloaded launcher. Native updates reuse the configured upstream. Use SSH keys or Git
credential helpers; keep credentials out of URLs retained in recovery records.
