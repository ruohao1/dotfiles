# Dotfiles

A personal **Ghostty, tmux, and Neovim** setup for macOS and Linux, with optional
AeroSpace, i3, or Hyprland configuration.

## Install

The native installer is the default. You need `curl`, internet access, and package
installation permissions. Run as your normal user; it uses `sudo` when needed.
Git 2.34+ is required for a complete preview.

### 1. Load the installer

Paste this helper into your terminal. It downloads the installer and removes the
temporary file after each run.

```sh
dotfiles_bootstrap() (
  set -eu
  installer=$(mktemp)
  trap 'rm -f "$installer"' 0 HUP INT TERM
  curl --fail --location --show-error --silent \
    --output "$installer" \
    https://raw.githubusercontent.com/ruohao1/dotfiles/main/.config/dotfiles/bootstrap
  sh "$installer" "$@"
)
```

### 2. Preview your installation

Choose your system. `none` keeps your current window manager.

| System | Preview command | Window-manager choices |
| --- | --- | --- |
| macOS | `dotfiles_bootstrap --window-manager none` | `none`, `aerospace` |
| Arch, EndeavourOS, Manjaro | `dotfiles_bootstrap --window-manager none` | `none`, `i3`, `hypr` |
| Debian, Ubuntu, Linux Mint, Pop!_OS | `dotfiles_bootstrap --window-manager none --allow-community-packages` | `none`, `i3` |

Replace `none` with another listed choice if wanted. Preview shows packages,
file changes, conflicts, and backups without applying them.

On apt systems, `--allow-community-packages` permits the pinned Ghostty installer
if Ghostty is unavailable from the configured repositories. On Arch systems,
bootstrap prints a `sudo pacman -Syu --needed …` command when packages are missing;
run that command, then rerun bootstrap.

### 3. Install

Repeat your preview command with `--apply`. For example, on Ubuntu:

```sh
dotfiles_bootstrap --apply --window-manager none --allow-community-packages
```

Conflicting files are backed up automatically. Reopen Ghostty after installation.
If you selected a window manager, reload it or start a new desktop session.

For AeroSpace, open Karabiner Elements, enable its background items, and complete
its macOS permission setup.

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

After Home Manager takes ownership, use the Nix migration and recovery commands
instead of the native installer. See [release updates and rollback](nix/README.md#confirmed-release-updates).

## More guides

- [Project sessions, multiple windows, and SSH](.config/tmux/PROJECTS.md)
- [Neovim start screen](.config/nvim/STARTUP.md)
- [Language tooling and health checks](.config/nvim/LANGUAGE-TOOLING.md)
- [Saved code locations](.config/nvim/LINE-PINS.md)

Native configuration lives in `~/.config/ghostty`, `~/.config/tmux`, and `~/.config/nvim`.
Bootstrap manages the bare Git repository in `~/.cfg` automatically.

For a fork, add `--repo URL` and optionally `--ref REF`. Use SSH keys or Git
credential helpers; keep credentials out of URLs retained in recovery records.
