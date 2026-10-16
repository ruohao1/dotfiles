# Disposable build identities only; never activate check-* on the current user.
# Add an explicit host with `// { name = { ... }; }` as shown in nix/README.md,
# then review and commit its actual username/home/system before bootstrap-nix.
builtins.listToAttrs (map (system: {
  name = "check-${system}";
  value = {
    inherit system;
    profile = if builtins.match ".*-linux" system != null then "linux" else "darwin";
    username = "dotfiles";
    homeDirectory = if builtins.match ".*-linux" system != null
      then "/home/dotfiles" else "/Users/dotfiles";
  };
}) [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ])
