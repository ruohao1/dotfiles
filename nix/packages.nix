{ pkgs }:
let
  tmux = pkgs.callPackage ./pkgs/tmux.nix { };
  luaLanguageServer = pkgs.callPackage ./pkgs/lua-language-server.nix { };
  herdr = pkgs.callPackage ./pkgs/herdr.nix { };
  # On Linux libiconv is a headers-only compatibility marker, not the CLI.
  iconv = if pkgs.stdenv.hostPlatform.isLinux then pkgs.glibc.bin else pkgs.libiconv;
  npmServers = pkgs.callPackage ./pkgs/language-servers.nix { };
  command = name: package: extra: {
    command = name;
    provider = toString package;
    args = [ "--version" ];
  } // extra;
  npmCommand = name: npmPackage: exact: extra: command name npmServers ({
    inherit npmPackage exact;
    packageRoot = "${npmServers}/lib/dotfiles-language-servers/node_modules";
    lsp = [ "--stdio" ];
  } // extra);
  native = name: id: { command = name; native = id; };
in {
  packages = with pkgs; [
    git python3 neovim fzf ripgrep jq shellcheck stylua tree-sitter
    imagemagick uv nodejs taplo npmServers
    iconv coreutils perl bash curl gawk gnused gnugrep findutils
    diffutils gnutar gzip unzip xz stdenv.cc
  ] ++ [ herdr tmux luaLanguageServer ];
  commandRequirements = [
    (command "git" pkgs.git { minimum = "2.34.0"; })
    (command "python3" pkgs.python3 { minimum = "3.10.0"; maximumExclusive = "3.15.0"; })
    (command "nvim" pkgs.neovim { minimum = "0.12.0"; capability = [ "--headless" "-u" "NONE" "-i" "NONE" "+lua assert(vim.version().minor >= 12)" "+qa!" ]; })
    (command "tmux" tmux { args = [ "-V" ]; minimum = "3.7"; })
    (command "fzf" pkgs.fzf { })
    (command "rg" pkgs.ripgrep { })
    (command "jq" pkgs.jq { })
    (command "shellcheck" pkgs.shellcheck { })
    (command "stylua" pkgs.stylua { minimum = "2.5.0"; })
    (command "tree-sitter" pkgs.tree-sitter { minimum = "0.26.1"; })
    (command "herdr" herdr { minimum = "0.8.0"; })
    (command "identify" pkgs.imagemagick { args = [ "-version" ]; capability = [ "-format" "%wx%h" "xc:white" ]; output = "1x1"; })
    (command "convert" pkgs.imagemagick { args = [ "-version" ]; capability = [ "-size" "1x1" "xc:white" "txt:-" ]; outputPrefix = "# ImageMagick pixel enumeration: 1,1"; })
    (command "uv" pkgs.uv { minimum = "0.11.6"; })
    (command "node" pkgs.nodejs { minimum = "22.0.0"; })
    (command "npm" pkgs.nodejs { minimum = "10.0.0"; })
    (npmCommand "bash-language-server" "bash-language-server" "5.6.0" { lsp = [ "start" ]; })
    (command "pyright" npmServers { npmPackage = "pyright"; exact = "1.1.411"; packageRoot = "${npmServers}/lib/dotfiles-language-servers/node_modules"; })
    (npmCommand "pyright-langserver" "pyright" "1.1.411" { args = null; })
    (npmCommand "vscode-json-language-server" "vscode-langservers-extracted" "4.10.0" { args = null; })
    (npmCommand "yaml-language-server" "yaml-language-server" "1.24.0" { args = null; })
    (command "lua-language-server" luaLanguageServer { minimum = "3.19.1"; lsp = [ ]; })
    (command "taplo" pkgs.taplo { minimum = "0.10.0"; stable = true; lsp = [ "lsp" "stdio" ]; capability = [ "lsp" "stdio" "--help" ]; })
    (command "iconv" iconv { args = null; capability = [ "-f" "UTF-8" "-t" "UTF-8" ]; input = "dotfiles café\n"; output = "dotfiles café\n"; })
    (command "sha256sum" pkgs.coreutils { args = null; capability = [ ]; input = "abc"; outputPrefix = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"; })
    (command "shasum" pkgs.perl { args = null; capability = [ "-a" "256" ]; input = "abc"; outputPrefix = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"; })
    (command "bash" pkgs.bash { })
    (command "curl" pkgs.curl { })
    (command "awk" pkgs.gawk { })
    (command "sed" pkgs.gnused { })
    (command "grep" pkgs.gnugrep { })
    (command "find" pkgs.findutils { })
    (command "diff" pkgs.diffutils { })
    (command "tar" pkgs.gnutar { })
    (command "gzip" pkgs.gzip { })
    (command "unzip" pkgs.unzip { args = [ "-v" ]; })
    (command "xz" pkgs.xz { })
    (command "cc" pkgs.stdenv.cc { compileC = true; })
    (native "ghostty" "ghostty")
    (native "visidata" "uv-visidata")
  ] ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
    (native "bwrap" "linux-bubblewrap")
    (native "timeout" "linux-default-timeout")
  ];
  nativeDependencies = [
    { id = "ghostty"; requiredClaims = [ "native-version" "effective-config" ]; pending = [ "Task6 full native workflow and preferences/permissions" ]; description = "Native Ghostty application and desktop integration."; }
    { id = "space-mono-nerd-font"; requiredClaims = [ "ghostty-font-catalogue" "configured-family" ]; pending = [ "Task6 full native workflow and preferences/permissions" ]; description = "Native SpaceMono Nerd Font, verified by font/terminal checks."; }
    { id = "uv-visidata"; requiredClaims = [ "immutable-runtime-external-uv-probe" ]; pending = [ "Task6 full native workflow and preferences/permissions" ]; description = "Retained external uv tool environment: VisiData 3.4, pyarrow 25.0.0, duckdb 1.5.5 in the environment returned by uv tool dir."; }
    { id = "notebook-uv-project"; requiredClaims = [ "frozen-project-lock" "compatible-python-exact-metadata" ]; pending = [ "Task6 full native workflow and preferences/permissions" ]; description = "Retained frozen notebook uv project; Python >=3.10,<3.15 and committed notebook dependency lock."; }
    { id = "desktop-clipboard"; requiredClaims = [ "current-user-manager" "local-session-permissions" "native-clipboard-providers" ]; pending = [ "Task6 full native workflow and preferences/permissions" ]; description = "Native clipboard/window-manager services, OS preferences and permissions."; }
  ] ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
    { id = "linux-bubblewrap"; requiredClaims = [ "root-owned-executable" "namespace-and-production-runner" ]; pending = [ "Task6 full native workflow and preferences/permissions" ]; description = "Native root-owned executable Bubblewrap, no group/world write bits, with successful real namespace probe."; }
    { id = "linux-default-timeout"; requiredClaims = [ "command-p-gnu-timeout" "bounded-timeout-behavior" ]; pending = [ "Task6 full native workflow and preferences/permissions" ]; description = "Native GNU timeout discoverable through command -p, independently of the Nix profile PATH."; }
  ];
}
