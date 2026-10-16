{ pkgs, inventory }:
let
  manifest = pkgs.writeText "dotfiles-package-requirements.json" (builtins.toJSON {
    inherit (inventory) commandRequirements nativeDependencies;
    system = pkgs.stdenv.hostPlatform.system;
  });
in pkgs.runCommand "dotfiles-package-check" {
  nativeBuildInputs = [ pkgs.python3 ];
} ''
  export DOTFILES_TEST_CC="${pkgs.stdenv.cc}/bin/cc"
  export HOME="$TMPDIR/home"
  mkdir -p "$HOME"
  ${pkgs.python3}/bin/python3 ${../tests/check-packages.py} --self-test
  ${pkgs.python3}/bin/python3 ${../tests/check-packages.py} ${manifest}
  mkdir -p "$out"
  cp ${manifest} "$out/requirements.json"
''
