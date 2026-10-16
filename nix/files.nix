# The application transfer inventory. Only these paths are adopted; directories
# remain writable so local extensions and runtime state survive reactivation.
{ sourceRoot, system }:
let
  linux = builtins.match ".*-linux" system != null;
  walk = root: prefix:
    builtins.concatLists (map (name:
      let relative = if prefix == "" then name else "${prefix}/${name}";
          kind = (builtins.readDir (root + "/${prefix}" )).${name};
      in if kind == "directory" then walk root relative
      else if kind == "regular" then [ relative ]
      else throw "Non-regular application source: ${relative}"
    ) (builtins.attrNames (builtins.readDir (root + "/${prefix}"))));
  nvimPaths = builtins.filter (p:
    p == "init.lua" || builtins.match "[^/]+\\.md" p != null
    || builtins.match "(lua|lsp)/.*\\.lua" p != null
    || p == "scripts/data-query-runner.py"
    || builtins.elem p [ "python/pyproject.toml" "python/uv.lock" ]
    || (builtins.match "tests/.*" p != null
      && builtins.match ".*(__pycache__|/\\.[^/]+).*" p == null)
  ) (walk (sourceRoot + "/.config/nvim") "");
  tmuxPaths = builtins.filter (p:
    (builtins.match "(conf|scripts|tests)/.*" p != null || builtins.elem p [ "tmux.conf" "PROJECTS.md" ])
    && p != "conf/platform/${if linux then "macos" else "linux"}.conf"
    && builtins.match ".*(__pycache__|/\\.[^/]+).*" p == null
  ) (walk (sourceRoot + "/.config/tmux") "");
  dotfilesPaths = [ "check-terminal-stack" "git-summary" "lib/config-source.py" ] ++ builtins.filter (p:
    builtins.match "manifests/config-.*\\.paths" p != null
    || builtins.match "manifests/packages.*\\.list" p != null
    || builtins.elem p [ "manifests/packages-npm-language-servers.json" "manifests/packages-npm-language-servers-lock.json" ]
  ) (walk (sourceRoot + "/.config/dotfiles") "");
  # Preserve executable modes for all retained helpers and tests, so HM
  # links them into the tree rather than copying files to change their mode.
  executable = target:
    builtins.elem target [ ".local/bin/t" ".config/dotfiles/check-terminal-stack" ".config/dotfiles/git-summary" ]
    || (builtins.match "\\.config/(herdr|tmux)/scripts/.*" target != null && builtins.match ".*\\.jq" target == null)
    || builtins.match "\\.config/tmux/tests/.*\\.sh" target != null;
  singles = [
    ".config/herdr/config.toml" ".config/herdr/scripts/move-pane"
    ".config/ghostty/config.ghostty" ".config/ghostty/platform-linux.ghostty"
    ".local/bin/t"
  ] ++ (if linux then [ ] else [
    ".config/ghostty/platform-macos.ghostty"
    "Library/Application Support/com.mitchellh.ghostty/config.ghostty"
  ]);
  selectedPaths = map (p: ".config/nvim/${p}") nvimPaths
    ++ map (p: ".config/tmux/${p}") tmuxPaths
    ++ map (p: ".config/dotfiles/${p}") dotfilesPaths
    ++ singles;
  # One complete filtered checkout layout retains canonical ancestor/sibling
  # relationships, including tmux tests that locate .local/bin/t via __file__.
  # Home destinations are individual leaves, never whole-directory links.
  runtimeTree = builtins.path {
    name = "dotfiles-runtime";
    path = sourceRoot;
    filter = path: kind:
      let
        prefix = toString sourceRoot + "/";
        relative = builtins.substring (builtins.stringLength prefix) (-1) (toString path);
        isAncestor = relative == "" || builtins.any (target:
          builtins.substring 0 (builtins.stringLength relative + 1) target == "${relative}/"
        ) selectedPaths;
      in (kind == "directory" && isAncestor) || builtins.elem relative selectedPaths;
  };
  isRegularInput = target:
    (builtins.readDir (sourceRoot + "/${builtins.dirOf target}")).${builtins.baseNameOf target} == "regular";
  selected = map (target:
    assert isRegularInput target;
    { inherit target;
    source = "${runtimeTree}/${target}";
    executable = executable target;
  }) selectedPaths;
in {
  files = builtins.listToAttrs (map (file: { name = file.target; value = { inherit (file) source executable; }; }) selected);
  mutableSeeds = [ {
    target = ".config/nvim/lazy-lock.json";
    source = assert isRegularInput ".config/nvim/lazy-lock.json";
      toString (builtins.path { path = sourceRoot + "/.config/nvim/lazy-lock.json"; name = "dotfiles-lazy-lock-seed.json"; });
    executable = false;
  } ];
}
