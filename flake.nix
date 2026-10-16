{
  description = "Locked shared dotfiles packages and explicit Home Manager profiles";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    home-manager = {
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forSystems = nixpkgs.lib.genAttrs systems;
      mkHome = import ./nix/lib/mk-home.nix { inherit nixpkgs home-manager; };
      hosts = import ./nix/hosts.nix;
      homes = builtins.mapAttrs (_: identity: mkHome identity) hosts;
      mkDotfilesApp = { system, flakeSource }:
        let
          pkgs = import nixpkgs { inherit system; };
          inventory = import ./nix/packages.nix { inherit pkgs; };
          commands = pkgs.writeText "dotfiles-command-inventory.json"
            (builtins.toJSON inventory.commandRequirements);
          cliSource = pkgs.runCommand "dotfiles-migration-source" { } ''
            mkdir -p "$out/migration"
            cp ${./nix/migration}/*.py "$out/migration/"
            substituteInPlace "$out/migration/cli.py" \
              --replace-fail 'PACKAGED_FLAKE_SOURCE = None' \
              ${pkgs.lib.escapeShellArg ("PACKAGED_FLAKE_SOURCE = " + builtins.toJSON (toString flakeSource))}
          '';
          dotfiles = pkgs.writeShellApplication {
            name = "dotfiles";
            runtimeInputs = inventory.packages ++ [ pkgs.nix home-manager.packages.${system}.home-manager ];
            text = ''
              export PYTHONDONTWRITEBYTECODE=1
              export DOTFILES_PACKAGED_INVENTORY=${commands}
              exec ${pkgs.python3}/bin/python3 ${cliSource}/migration/cli.py "$@"
            '';
          };
          launcher = pkgs.writeShellScript "dotfiles" ''
            # Capture the caller view before the inner app prepends pinned tools.
            export DOTFILES_CALLER_PATH="$PATH"
            exec ${dotfiles}/bin/dotfiles "$@"
          '';
        in {
          type = "app";
          program = toString launcher;
          meta.description = "Inspect dotfiles ownership and preview Nix home migrations";
        };
    in {
      lib = { inherit mkHome mkDotfilesApp; };
      homeConfigurations = homes;
      apps = forSystems (system: {
        dotfiles = mkDotfilesApp { inherit system; flakeSource = self.outPath; };
      });
      checks = forSystems (system:
        let pkgs = import nixpkgs { inherit system; };
        in {
          packages = import ./nix/checks/packages.nix {
            inherit pkgs;
            inventory = import ./nix/packages.nix { inherit pkgs; };
          };
          entrypoint = pkgs.runCommand "dotfiles-entrypoint-check" {
            nativeBuildInputs = [ pkgs.python3 pkgs.git ];
          } ''
            export PYTHONDONTWRITEBYTECODE=1
            export DOTFILES_ENTRYPOINT_SOURCE_ROOT=${self.outPath}
            export DOTFILES_ENTRYPOINT_TEST_ROOT="$TMPDIR/entrypoint-fixtures"
            python3 -B -m unittest discover -s ${./nix/tests} -p test_entrypoint.py
            touch "$out"
          '';
          migration = import ./nix/checks/migration.nix { inherit pkgs; };
          home = homes."check-${system}".activationPackage;
          terminal = import ./nix/checks/terminal.nix { inherit pkgs; home = homes."check-${system}"; };
          files = import ./nix/checks/files.nix { inherit pkgs mkHome; home = homes."check-${system}"; };
        } // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
          migration-vm = import ./nix/tests/migration-vm.nix {
            inherit pkgs nixpkgs home-manager mkHome;
            inherit mkDotfilesApp;
          };
        });
    };
}
