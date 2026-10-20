{ pkgs, home }:
let
  manifest = pkgs.writeText "dotfiles-terminal-manifest.json" (builtins.toJSON home.deploymentManifest);
  sourceRoot = ../..;
  # Container PID1 may not reap detached tmux servers. A private subreaper
  # preserves the existing process-exit assertions without weakening them.
  testPrefix = pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux "${pkgs.tini}/bin/tini -s --";
  # The retained restore fixture copies sleep to a fake codex executable.
  # Its existing gnusleep fallback must be a standalone binary: selected
  # production coreutils is multicall and dispatches by executable name.
  standaloneCoreutils = (pkgs.coreutils.override { singleBinary = false; }).overrideAttrs (old: {
    # Supported upstream configure option for the isolated root-run builder.
    env = (old.env or { }) // { FORCE_UNSAFE_CONFIGURE = "1"; };
    # The builder deliberately lacks ownership-changing capabilities. Run the
    # coreutils utility suite except upstream's named privileged root group.
    # This TESTS override does not exercise the separate gnulib component suite.
    preCheck = (old.preCheck or "") + ''
      checkFlagsArray+=('TESTS=$(filter-out $(all_root_tests),$(all_tests) $(factor_tests))')
    '';
  });
  fixtureSleep = pkgs.runCommand "dotfiles-terminal-fixture-sleep" { } ''
    mkdir -p "$out/bin"
    ln -s ${standaloneCoreutils}/bin/sleep "$out/bin/gnusleep"
  '';
in pkgs.runCommand "dotfiles-terminal-check" {
  nativeBuildInputs = [ pkgs.python3 pkgs.bash pkgs.coreutils ]
    ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.procps pkgs.tini fixtureSleep ]
    ++ home.config.home.packages;
} ''
  export HOME="$TMPDIR/check-home"
  export PYTHONDONTWRITEBYTECODE=1
  mkdir -p "$HOME"
  python3 -B ${sourceRoot}/nix/tests/test_editor_runner.py
  ${testPrefix} python3 ${../tests/run-focused.py} --suite editor-standalone \
    --source-root ${sourceRoot} \
    --fixture-root "$TMPDIR/e"
  ${testPrefix} python3 ${../tests/test_terminal.py} \
    --source-root ${sourceRoot} --generation ${home.activationPackage} \
    --fixture-root "$TMPDIR/t"
  ${pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
    ${testPrefix} python3 ${../tests/run-focused.py} --suite terminal \
      --source-root ${sourceRoot} --generation ${home.activationPackage} \
      --fixture-root "$TMPDIR/f"
  ''}
  mkdir -p "$out"
  cp ${manifest} "$out/deployment-manifest.json"
''
