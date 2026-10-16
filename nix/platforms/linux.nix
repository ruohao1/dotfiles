{ pkgs, ... }:
{
  assertions = [ {
    assertion = pkgs.stdenv.hostPlatform.isLinux;
    message = "The linux profile requires a Linux target system.";
  } ];
  # Native Bubblewrap, command -p GNU timeout, clipboard and desktop integration
  # are validated on the host; no activation or service changes in Task 1.
  targets.genericLinux.enable = true;
}
