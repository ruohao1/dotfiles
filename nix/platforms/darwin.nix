{ pkgs, ... }:
{
  assertions = [ {
    assertion = pkgs.stdenv.hostPlatform.isDarwin;
    message = "The darwin profile requires a Darwin target system.";
  } ];
  # OS preferences, desktop services and permissions remain native.
}
