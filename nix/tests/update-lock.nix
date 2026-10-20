{ pkgs }:
pkgs.runCommand "dotfiles-update-lock-check" {
  nativeBuildInputs = [ pkgs.python3 pkgs.git pkgs.nix ];
  DOTFILES_LOCK_NIX = "${pkgs.nix}/bin/nix";
  DOTFILES_LOCK_SHELL = "${pkgs.bash}/bin/bash";
  DOTFILES_LOCK_CHMOD = "${pkgs.coreutils}/bin/chmod";
} ''
  export PYTHONDONTWRITEBYTECODE=1
  python3 -B ${./test_update_lock.py} -v
  touch "$out"
''
