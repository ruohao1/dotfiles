{ lib, python3, git, nix, runCommand, writeShellApplication, writeShellScriptBin }:
let
  source = runCommand "dotfiles-update-source" { } ''
    mkdir -p "$out/update" "$out/migration"
    cp ${./.}/*.py "$out/update/"
    cp ${../migration}/*.py "$out/migration/"
    cp ${../../.config/dotfiles/bootstrap-nix} "$out/bootstrap_nix.py"
  '';
  runtime = writeShellApplication {
    name = "dotfiles-update-runtime";
    runtimeInputs = [ python3 git nix ];
    text = ''
      export PYTHONDONTWRITEBYTECODE=1
      exec ${python3}/bin/python3 -I -B -c ${lib.escapeShellArg ''
        import runpy, sys
        sys.path.insert(0, ${builtins.toJSON (toString source)})
        runpy.run_module("update.cli", run_name="__main__")
      ''} "$@"
    '';
  };
in writeShellScriptBin "dotfiles-update" ''
  # Preserve the caller's providers before the runtime prepends pinned tools.
  export DOTFILES_UPDATE_CALLER_PATH="$PATH"
  exec ${runtime}/bin/dotfiles-update-runtime "$@"
''
