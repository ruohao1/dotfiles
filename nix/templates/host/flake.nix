{
  description = "Personal host configuration for reviewed dotfiles releases";
  inputs.dotfiles.url = "github:ruohao1/dotfiles";

  outputs = { self, dotfiles }:
    let
      # Set actual host identity, then commit these files and the reviewed lock.
      system = "x86_64-linux";
      profileName = "my-host";
      release = builtins.fromJSON (builtins.readFile ./dotfiles-release.json);
      executorArguments = { inherit system; flakeSource = self.outPath; };
      home = dotfiles.lib.mkHome {
        inherit system;
        profile = if builtins.match ".*-darwin" system != null then "darwin" else "linux";
        username = "YOUR_ACCOUNT";
        homeDirectory = "/home/YOUR_ACCOUNT";
        modules = [ ./host.nix ];
        deploymentIdentity = {
          schema = 1;
          inherit release;
          consumerSource = self.outPath;
          profile = profileName;
        };
      };
    in
    assert (release.commit == (dotfiles.rev or null))
      || throw "The receipt commit must match the locked dotfiles input; select and verify a release first.";
    {
      homeConfigurations.${profileName} = home;
      packages.${system}.dotfiles-executor = dotfiles.lib.mkDotfilesExecutor executorArguments;
      apps.${system}.dotfiles = dotfiles.lib.mkDotfilesApp executorArguments;
    };
}
