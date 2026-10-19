{ nixpkgs, home-manager }:
{ profile, system, username, homeDirectory, modules ? [ ], sourceRoot ? ../.., deploymentIdentity ? null }:
let
  lib = nixpkgs.lib;
  validIdentity = value:
    builtins.isAttrs value
    && builtins.attrNames value == [ "consumerSource" "profile" "release" "schema" ]
    && builtins.isInt value.schema && value.schema == 1
    && builtins.isString value.consumerSource
    && builtins.match "/nix/store/[0-9a-df-np-sv-z]{32}-[^/]+" value.consumerSource != null
    && builtins.isString value.profile
    && builtins.match "[A-Za-z0-9_-]+" value.profile != null
    && !lib.hasPrefix "check-" value.profile
    && builtins.isAttrs value.release
    && builtins.attrNames value.release == [ "commit" "releaseId" "repository" "version" ]
    && value.release.repository == "ruohao1/dotfiles"
    && builtins.isInt value.release.releaseId && value.release.releaseId > 0
    && builtins.isString value.release.version
    && builtins.match "v(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)" value.release.version != null
    && builtins.isString value.release.commit
    && builtins.match "[0-9a-f]{40}" value.release.commit != null;
  systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
  expectedProfile = if nixpkgs.lib.hasSuffix "-linux" system then "linux" else "darwin";
  platformModule = if profile == "linux" then ../platforms/linux.nix else ../platforms/darwin.nix;
  pkgs = import nixpkgs { inherit system; };
  inventory = import ../packages.nix { inherit pkgs; };
  deployment = import ../files.nix { inherit sourceRoot system; };
  identityFile = pkgs.writeText "dotfiles-deployment-identity.json" (builtins.toJSON deploymentIdentity);
  home = home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    extraSpecialArgs = { inherit profile sourceRoot; };
    modules = [ ../home.nix platformModule { home = { inherit username homeDirectory; }; } ] ++ modules
      ++ lib.optional (deploymentIdentity != null) { home.extraDependencies = [ identityFile ]; };
  };
  nativeDependencies = map (dependency:
    dependency // (if dependency.id == "uv-visidata" then {
      preparation = { command = [ "uv" "tool" "install" "--with" "pyarrow==25.0.0" "--with" "duckdb==1.5.5" "visidata==3.4" ]; };
    } else if dependency.id == "notebook-uv-project" then {
      preparation = {
        command = [ "uv" "sync" "--frozen" "--no-dev" "--no-install-project" "--project" "${homeDirectory}/.config/nvim/python" ];
        environment.UV_PROJECT_ENVIRONMENT = "${home.config.xdg.dataHome}/nvim/notebook-python";
      };
    } else { })
  ) inventory.nativeDependencies;
in
assert deploymentIdentity == null || validIdentity deploymentIdentity;
assert deploymentIdentity == null || builtins.elem (toString identityFile) (map toString home.config.home.extraDependencies);
assert builtins.elem system systems;
assert builtins.elem profile [ "linux" "darwin" ];
assert profile == expectedProfile;
assert builtins.isString username && builtins.match "[a-zA-Z_][a-zA-Z0-9_-]*" username != null;
assert builtins.isString homeDirectory && nixpkgs.lib.hasPrefix "/" homeDirectory && homeDirectory != "/";
home // {
  deploymentManifest = import ./deployment-manifest.nix {
    lib = nixpkgs.lib;
    config = home.config;
    inherit pkgs profile system nativeDependencies deploymentIdentity;
    selectedFiles = deployment.files;
    inherit (deployment) mutableSeeds;
  };
}
