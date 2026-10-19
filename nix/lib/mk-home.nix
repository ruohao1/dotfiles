{ nixpkgs, home-manager }:
{ profile, system, username, homeDirectory, modules ? [ ], sourceRoot ? ../.. }:
let
  systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
  expectedProfile = if nixpkgs.lib.hasSuffix "-linux" system then "linux" else "darwin";
  platformModule = if profile == "linux" then ../platforms/linux.nix else ../platforms/darwin.nix;
  pkgs = import nixpkgs { inherit system; };
  inventory = import ../packages.nix { inherit pkgs; };
  deployment = import ../files.nix { inherit sourceRoot system; };
  home = home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    extraSpecialArgs = { inherit profile sourceRoot; };
    modules = [ ../home.nix platformModule { home = { inherit username homeDirectory; }; } ] ++ modules;
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
assert builtins.elem system systems;
assert builtins.elem profile [ "linux" "darwin" ];
assert profile == expectedProfile;
assert builtins.isString username && builtins.match "[a-zA-Z_][a-zA-Z0-9_-]*" username != null;
assert builtins.isString homeDirectory && nixpkgs.lib.hasPrefix "/" homeDirectory && homeDirectory != "/";
home // {
  deploymentManifest = import ./deployment-manifest.nix {
    lib = nixpkgs.lib;
    config = home.config;
    inherit pkgs profile system nativeDependencies;
    selectedFiles = deployment.files;
    inherit (deployment) mutableSeeds;
  };
}
