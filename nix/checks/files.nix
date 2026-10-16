{ pkgs, home, mkHome }:
let
  rejectsDirectory = withText:
    let
      injected = mkHome {
        inherit (home.deploymentManifest) profile system username homeDirectory;
        modules = [ {
          home.file.directoryInjection = {
            source = ../tests;
            executable = false;
            recursive = false;
          } // pkgs.lib.optionalAttrs withText { text = "spoofed source metadata"; };
        } ];
      };
    in !(builtins.tryEval (builtins.deepSeq injected.deploymentManifest true)).success;
  acceptsGeneratedText =
    let
      generated = mkHome {
        inherit (home.deploymentManifest) profile system username homeDirectory;
        modules = [ {
          home.file.generatedText.text = "regular generated leaf";
          xdg.configFile."manifest-test.conf".text = "XDG generated leaf";
        } ];
      };
    in (builtins.tryEval (builtins.deepSeq generated.deploymentManifest true)).success;
  manifest = pkgs.writeText "dotfiles-deployment-manifest.json" (builtins.toJSON home.deploymentManifest);
  activation = home.config.home.activation;
  activationNodes = pkgs.writeText "dotfiles-activation-nodes.json" (builtins.toJSON (builtins.attrNames activation));
  seed = activation.seedLazyLock;
  seedScript = pkgs.writeText "dotfiles-seed-lazy-lock.sh" seed.data;
in
# These defaults would mutate native applications/permissions outside the inventory.
# Nonrecursive directory sources and spoofed text/source pairs must not export
# one nominal leaf that silently adopts a whole mutable destination directory.
assert rejectsDirectory false;
assert rejectsDirectory true;
assert acceptsGeneratedText;
assert !(activation ? copyApps);
assert !(activation ? checkAppManagementPermission);
pkgs.runCommand "dotfiles-file-check" {
  nativeBuildInputs = [ pkgs.python3 pkgs.bash pkgs.coreutils ];
} ''
  export HOME="$TMPDIR/home"
  mkdir -p "$HOME"
  ${pkgs.python3}/bin/python3 ${../tests/test_files.py} \
    --manifest ${manifest} --activation-nodes ${activationNodes} --seed-script ${seedScript} \
    --seed-after ${pkgs.lib.escapeShellArgs seed.after} \
    --fixture-root "$TMPDIR/file-tests"
  mkdir -p "$out"
  cp ${manifest} "$out/deployment-manifest.json"
''
