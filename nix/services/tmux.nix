{ config, lib, pkgs, sourceRoot, ... }:
let
  linux = pkgs.stdenv.hostPlatform.isLinux;
  deployment = import ../files.nix { inherit sourceRoot; system = pkgs.stdenv.hostPlatform.system; };
  helper = deployment.files.".config/tmux/scripts/workspace".source;
  inventory = import ../packages.nix { inherit pkgs; };
  # Complete selected shared-tool providers first; these native paths remain
  # fallbacks for Ghostty/Codex and other explicitly native resumed applications.
  dependencies = lib.makeBinPath inventory.packages;
  nativePath = "${config.home.homeDirectory}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin";
  path = "${dependencies}:${nativePath}";
  supervisor = pkgs.writeShellScript "tmux-workspace-supervisor" ''
    export PATH=${lib.escapeShellArg path}
    exec ${lib.escapeShellArg helper} "$@"
  '';
in {
  systemd.user.services = lib.mkIf linux {
    tmux-workspace = {
      Unit = {
        Description = "Restore and checkpoint the tmux workspace";
        Documentation = "man:tmux(1)";
      };
      Service = {
        Type = "simple";
        ExecStart = "${supervisor} supervise";
        Environment = [ "PATH=${path}" ];
        Restart = "on-failure";
        RestartSec = 5;
        TimeoutStopSec = 30;
      };
      Install.WantedBy = [ "default.target" ];
    };
  };
  launchd.agents = lib.mkIf (!linux) {
    tmux-workspace = {
      enable = true;
      config = {
        Label = "dev.ruohao.tmux-workspace";
        ProgramArguments = [ "${supervisor}" "supervise" ];
        EnvironmentVariables.PATH = path;
        RunAtLoad = true;
        KeepAlive.SuccessfulExit = false;
        ProcessType = "Background";
        ThrottleInterval = 5;
      };
    };
  };
}
