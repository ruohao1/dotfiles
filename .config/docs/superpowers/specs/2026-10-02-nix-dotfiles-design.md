# Nix dotfiles migration design

Adopt Nix and standalone Home Manager for shared developer tools and dotfiles, with initial targets of Ubuntu/Debian, Arch, and macOS. Keep existing application configuration in its native format. The first milestone delivers buildable profiles and a tested, explicit ownership handoff; live activation follows validation on the target platform.

Status: proposed design for review. No Nix installation, package migration, or configuration activation has occurred.

## Current setup

The repository uses bare Git metadata at `~/.cfg` and the home directory as its working tree. Application sources live under `.config/`, with additional launchers under `.local/` and macOS files under `Library/`. A conventional checkout of this repository preserves those relative paths.

The existing `.config/dotfiles/bootstrap` combines package installation, configuration copying, service activation, preferences, backups, and rollback. Its `--window-manager none` option still configures the tmux workspace service. It therefore cannot serve as a configuration-only migration command.

The inspected baseline is commit `04fb472`. The live home also contains user edits to Ghostty's Linux configuration and Neovim's `lazy-lock.json`; those edits must be preserved. Nix and Home Manager were not found on the current PATH, so this document makes no claim that the proposed profiles have been evaluated or built.

## Scope and alternatives

Use one flake and reusable Home Manager modules. This replaces repeated user-package definitions and file deployment while retaining the existing Linux and macOS desktop choices. It is the recommended approach because the current bootstrap already maintains three native package providers and separate pinned downloads.

Keeping the current bootstrap would avoid a new configuration language but retain its package and deployment maintenance. Moving all machines to NixOS would allow deeper system management, but it would not meet the agreed Ubuntu/Debian, Arch, and macOS scope.

The first milestone covers shared CLI packages, language-server executables, Neovim, tmux, herdr, terminal configuration, and the tmux workspace user service. Native GUI installations, window-manager sessions, GPU integration, global keyboard settings, and macOS permissions keep their current platform-specific management. Ghostty configuration can move independently of the Ghostty application.

Shell and Git executables may be supplied by Nix, but this migration does not invent replacement shell startup files or Git identity settings. Existing startup files receive only the documented Nix/Home Manager environment integration needed by the selected shell.

## Supported profiles

| Target | Shared configuration | Platform responsibilities |
| --- | --- | --- |
| Ubuntu and Debian | Linux Home Manager module | Existing desktop packages and system integration |
| Arch | Same Linux Home Manager module | Existing desktop packages and system integration |
| macOS | Darwin Home Manager module | Existing GUI applications, permissions, and preferences |

Define builds for `x86_64-linux`, `aarch64-linux`, `x86_64-darwin`, and `aarch64-darwin`. A declared build target is not a verified installation: record evaluation, native build, and activation evidence separately. Linux distribution support requires disposable installation tests on Ubuntu, Debian, and Arch. Darwin support requires a native macOS build and activation test.

NixOS, native Windows, WSL-specific integration, BSD, and other distributions are outside the first milestone. The common module should remain reusable without claiming those targets are tested.

## Source layout and configuration

Use a normal source checkout outside deployed destinations, such as `~/src/dotfiles`. Add `flake.nix`, `flake.lock`, and a `nix/` directory at the repository root. Existing `.config/`, `.local/`, and `Library/` sources retain their layout.

The Nix directory contains a shared Home Manager module, a package module, Linux and Darwin modules, and explicit host definitions. Each host definition supplies the username, absolute home directory, target system, and selected platform. Do not derive these values from ambient environment variables during evaluation or hardcode the current sandbox user as the user's identity.

Pin `nixpkgs-unstable` and Home Manager `master` to exact revisions in `flake.lock`, with Home Manager following the same nixpkgs input. Select and verify those revisions during implementation against the version requirements below. Normal builds and activation use the committed lock; upgrades are deliberate lockfile changes. Preserve `home.stateVersion` after initial setup.

Expose named `homeConfigurations` for explicit hosts and build checks for the four target systems. Keep credentials, application databases, runtime state, and unrelated home files outside the flake source. Evaluate from the normal checkout, never by importing the entire live home directory into the Nix store.

## Package compatibility

The shared inventory includes Git, Python, Neovim, tmux, fzf, ripgrep, jq, shellcheck, StyLua, tree-sitter CLI, herdr, ImageMagick, uv, Node, and the Bash, Python, JSON, YAML, Lua, and TOML language servers. Preserve executable names consumed by the current editor and scripts.

Existing minimum requirements are Neovim 0.12.0, StyLua 2.5.0, tree-sitter CLI 0.26.1, uv 0.11.6, herdr 0.8.0, and Taplo 0.10.0 with a working `lsp stdio` entry point. The terminal check also requires tmux 3.7 for its URL behavior. Do not silently downgrade these requirements to fit a package set.

The npm manifest currently pins Bash LS 5.6.0, Pyright 1.1.411, `vscode-langservers-extracted` 4.10.0, and YAML LS 1.24.0. Preserve those pins initially, using a pinned npm derivation if the chosen nixpkgs packages do not match. Native-provider and direct-download versions are not currently identical; record the selected Nix versions and run capability checks rather than claiming exact parity across existing providers.

The existing VisiData workflow requires VisiData 3.4, pyarrow 25.0.0, and duckdb 1.5.5 in one uv tool environment discovered through `uv tool dir`. Retain that managed runtime as an explicit first-milestone exception; three unrelated Nix packages do not satisfy the current discovery contract. Preserve the notebook's frozen uv environment and its Python constraint of `>=3.10,<3.15`.

Any package unavailable on a target must have a tested derivation or remain a documented native dependency. Unsupported essential tools fail profile validation with a specific explanation rather than disappearing from the package list.

## File ownership and writable state

Home Manager links selected source files into their existing destinations. Do not translate Neovim Lua or tmux configuration into large generated Nix strings. Use file-level deployment for directories that mix configuration and writable state.

Keep `~/.config/nvim/lazy-lock.json` as a writable regular file while retaining lazy.nvim. Preserve it on migration. For a new home, seed it from the repository only when absent; later activations must not overwrite it. Plugin updates remain an explicit operation, and users can copy the updated lock back into the source checkout for review. This writable lock and downloaded plugin state are outside Home Manager generation rollback in the first milestone.

Neovim plugins and tree-sitter parsers remain in the editor data directory. Notebook environments, Jupyter cache, tmux snapshots, runtime files, and bootstrap journals retain their existing writable locations. Preserve unrelated local editor extensions; do not add machine-specific paths to shared configuration.

The tmux workspace service and its helper files transfer together. The helper currently replaces PATH without including Nix; adapt it so interactive shells, the editor, and background services resolve the selected Nix tools consistently. Update doctor and service preflight checks to accept validated Home Manager store links while still rejecting dangling links, inappropriate ownership, and missing executables.

Keep desktop launchers, clipboard services, window-manager configuration, macOS preferences, and `.codex/hooks.json` outside this initial ownership transfer. The migration inventory must enumerate exact destination paths instead of adopting all of `.config/`.

## Migration and recovery

1. Create the separate source checkout and account for local edits before building. Never reset, clean, or overwrite the live home worktree to produce a clean source tree.
2. Build the selected Home Manager generation and inspect its package and file lists without activation. A successful build alone does not establish runtime compatibility.
3. Produce an explicit migration inventory: destination paths, existing file types, executable providers, service state, retained native dependencies, and backup locations. Existing files or unexpected providers are conflicts to resolve, not reasons to use unconditional replacement.
4. Transfer only the inventoried paths. Preserve originals, local changes, and previous service state in a collision-resistant backup. Preserve the bare repository and existing bootstrap journals as recovery evidence.
5. Protect both directions of deployment. The supported legacy bootstrap apply and rollback entry points must refuse overlapping operations while Home Manager owns those paths, with instructions for the reverse handoff. Old bootstrap rollback is not the recovery mechanism for a Home Manager generation.
6. Activate the built generation, verify command resolution from shells/editor/services, and exercise the existing terminal workflows. Repeated activation must be stable.
7. Support two documented recovery procedures: select a previous Home Manager generation, or explicitly relinquish its transferred paths and restore the pre-migration files and services. Recovery must preserve modifications made after the migration for inspection.

The legacy scoped Taplo installer has a special handoff: it accepts an external Taplo only when its old architecture-specific installation and `~/.local/bin/taplo` are absent. Archive the inventoried old artifacts and verify the Nix executable before marking the handoff complete. Do not remove arbitrary executables found elsewhere on PATH.

Existing native packages remain installed during the initial migration. A later cleanup may remove confirmed duplicates after validation. Neither Home Manager rollback nor the legacy file backup restores the entire operating system or every native package change.

After the core profiles and reverse handoff are verified, replace the default installation route with a small Nix installer and activation entry point. Retain the legacy route only for explicit legacy installations during the transition; it must not run as the desktop half of a Home Manager installation.

## Acceptance evidence

- Evaluate every declared target with the committed lock and explicit host identity. Build each advertised target natively or on a matching builder; identify targets that have only evaluation evidence.
- Exercise disposable Ubuntu, Debian, and Arch homes and native macOS profiles. Build and activation evidence must name the OS and CPU architecture.
- Check tool versions, executable names, real LSP startup, the uv runtime contract, and Nix PATH availability inside the tmux user service.
- Verify file links and writable lock/state paths. Preserve an existing modified `lazy-lock.json`, unrelated local configuration, and local Ghostty edits through activation and recovery.
- Test first-activation conflicts, backup-name collisions, partial activation failure, repeated activation, previous-generation recovery, and restoration of pre-migration files and service state.
- Prove that legacy apply and rollback cannot overwrite Home Manager-owned paths and that the explicit reverse handoff restores legacy operation.
- Run relevant existing terminal/editor tests and the focused bootstrap ownership tests in isolated homes and private tmux sockets. Do not run tests that mutate the user's active session.

## Evidence and references

Local sources: `.config/dotfiles/bootstrap`, its package/config manifests, `.config/dotfiles/check-terminal-stack`, `.config/dotfiles/tests/bootstrap.sh`, `.config/nvim/lua/config/lazy.lua`, `.config/nvim/lua/notebook/python.lua`, `.config/nvim/lua/parquet/tool.lua`, and `.config/tmux/scripts/workspace`.

Home Manager supports a separate source directory and committed flake inputs: [standalone flake setup](https://nix-community.github.io/home-manager/nix-flakes/standalone.html). Its file and activation options define collision checks, backup behavior, and mutation boundaries: [home options](https://nix-community.github.io/home-manager/options/home-manager/home.html). Its generation recovery is distinct from restoring arbitrary pre-migration state: [rollback documentation](https://nix-community.github.io/home-manager/usage/rollbacks.html).
