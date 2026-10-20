# Tests use explicit private homes, real Neovim first-use probes, and private mock service managers.
# The legacy regression suite is run separately by run-focused.py --suite bootstrap.
{ pkgs }:
pkgs.runCommand "dotfiles-migration-check" {
  nativeBuildInputs = [ pkgs.python3 pkgs.bash pkgs.coreutils pkgs.findutils pkgs.gnused pkgs.neovim pkgs.git pkgs.tmux ];
} ''
  export HOME="$TMPDIR/check-home"
  export PYTHONDONTWRITEBYTECODE=1
  export DOTFILES_MIGRATION_SOURCE_ROOT=${../..}
  export DOTFILES_MIGRATION_TEST_ROOT="$TMPDIR/migration-fixtures"
  mkdir -p "$HOME" "$DOTFILES_MIGRATION_TEST_ROOT"
  python3 -m unittest discover -s ${../tests} -p 'test_ownership.py'
  python3 -m unittest discover -s ${../tests} -p 'test_migration_*.py'
  for suite in state releases candidate cli tmux; do
    python3 -B -m unittest discover -s ${../..}/nix/tests -p "test_update_$suite.py"
  done
  mkdir -p "$out"
  printf '%s\n' 'ownership and read-only migration preview: passed' > "$out/result"
''
