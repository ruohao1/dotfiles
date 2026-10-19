{ pkgs, lib, sourceRoot, ... }:
let
  inventory = import ./packages.nix { inherit pkgs; };
  deployment = import ./files.nix { inherit sourceRoot; system = pkgs.stdenv.hostPlatform.system; };
  lockSeed = builtins.head deployment.mutableSeeds;

in {
  imports = [ ./services/tmux.nix ];
  # Pinned HM otherwise installs native macOS fonts through an onChange rsync
  # hook. Fonts stay native prerequisites and are outside this transfer.
  # disabledModules participates in import resolution, before pkgs is available.
  # The excluded module's own condition made it inert on Linux.
  disabledModules = [ "targets/darwin/fonts.nix" ];
  # App copying at this stateVersion otherwise performs native TCC checks and
  # rsync --delete. Applications and permissions retain their native ownership.
  targets.darwin.copyApps.enable = false;
  targets.darwin.linkApps.enable = false;
  # Initialization compatibility level, not the selected package-set version.
  # Keep this value after a profile's first activation.
  home.stateVersion = "26.05";
  home.packages = inventory.packages;
  home.file = deployment.files;
  home.activation.seedLazyLock = lib.hm.dag.entryAfter [ "writeBoundary" "linkGeneration" ] ''
    seedLock="$HOME"/${lib.escapeShellArg lockSeed.target}
    # Existing regular files, links (including dangling links), and extensions
    # retain user ownership. A dry run does not even create parent directories.
    if [[ ! -e "$seedLock" && ! -L "$seedLock" && ! -v DRY_RUN ]]; then
      seedHome=$(${pkgs.coreutils}/bin/realpath "$HOME")
      seedParent=$(${pkgs.coreutils}/bin/realpath -m "$HOME/.config/nvim")
      case "$seedParent" in
        "$seedHome"/*) ;;
        *) echo "lazy-lock seed parent resolves outside home" >&2; exit 1 ;;
      esac
      run ${pkgs.coreutils}/bin/mkdir -p "$HOME/.config/nvim"
      # Noclobber avoids overwriting a lock created since the absence check.
      # A fresh regular file gets writable mode 0600, not the store's mode.
      (umask 077; set -o noclobber; ${pkgs.coreutils}/bin/cat ${lib.escapeShellArg lockSeed.source} > "$seedLock")
    fi
  '';
  programs.home-manager.enable = true;
}
