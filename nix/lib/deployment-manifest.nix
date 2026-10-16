# Schema 1 is consumed by preview/recovery; evaluated HM outputs are included.
{ lib, pkgs, config, profile, system, nativeDependencies, mutableSeeds, selectedFiles }:
let
  home = config.home.homeDirectory;
  user = config.home.username;
  state = config.xdg.stateHome;
  safeTarget = target:
    target != "" && !lib.hasPrefix "/" target
    && builtins.match ".*[\n\r\t].*" target == null
    && builtins.all (part: part != "" && part != "." && part != "..") (lib.splitString "/" target);
  # Pure regular-leaf witnesses: no inspection or realization of derivation
  # outputs, so evaluation remains possible for all four target systems.
  # files.nix checks the original checkout leaf types before building its tree.
  selectedProofs = map (file: { source = toString file.source; executable = null; }) (lib.attrValues selectedFiles);
  # Pinned HM 78e7d8b modules/lib/file-type.nix sets this source with mkDefault.
  # Reconstruct the exact generator and compare the actual source; text metadata
  # alone is insufficient because a module may override source with a directory.
  # XDG forwarding retains its original submodule source names (xdg/default.nix).
  textProofs = lib.concatMap (entries:
    lib.mapAttrsToList (name: file: {
      source = toString (pkgs.writeTextFile {
        name = config.lib.strings.storeFileName name;
        inherit (file) text;
        executable = file.executable == true;
      });
      executable = file.executable == true;
    }) (lib.filterAttrs (_: file: file.text != null) entries)
  ) [ config.home.file config.xdg.cacheFile config.xdg.configFile config.xdg.dataFile config.xdg.stateFile ];
  # Pinned modules/systemd.nix:33-74 puts unit text at one named leaf in a
  # directory derivation. Reproduce only its regular-file producer, not service
  # activation. Exact source equality also covers .wants/.requires file links.
  unitTypes = { services = "service"; slices = "slice"; sockets = "socket"; targets = "target";
    timers = "timer"; paths = "path"; mounts = "mount"; automounts = "automount"; };
  unitProofs = lib.concatLists (lib.mapAttrsToList (plural: style:
    lib.mapAttrsToList (name: unit:
      let
        filename = "${name}.${style}";
        finalUnit = lib.filterAttrs (_: section: section != { })
          (lib.mapAttrs (_: section: lib.filterAttrs (_: value: value != null && value != [ ]) section) unit);
        text = lib.generators.toINI {
          listsAsDuplicateKeys = true;
          mkKeyValue = key: value:
            "${key}=${if lib.isBool value then (if value then "true" else "false") else toString value}";
        } finalUnit;
      in {
        source = assert safeTarget filename && !lib.hasInfix "/" filename;
          "${pkgs.writeTextFile {
            name = lib.replaceStrings [ "@" ":" "\\" "[" "]" ] [ "-" "-" "-" "" "" ] filename;
            inherit text;
            destination = "/${filename}";
          }}/${filename}";
        executable = false;
      }
    ) config.systemd.user.${plural}
  ) unitTypes);
  sourceProofs = selectedProofs ++ textProofs ++ unitProofs;
  proofFor = file:
    let matches = builtins.filter (proof: proof.source == toString file.source) sourceProofs;
    in if matches == [ ] then throw "Manifest source for '${file.target}' is not a proven immutable regular leaf"
    else builtins.head matches;
  files = map (file:
    assert safeTarget file.target;
    assert lib.hasPrefix "/nix/store/" (toString file.source);
    # HM links a directory wholesale even with recursive=false. Require a
    # regular-source producer witness as well as the leaf deployment policy.
    assert builtins.isAttrs (proofFor file);
    assert !file.recursive;
    assert !file.force;
    assert file.onChange == ""; # No unlisted file-triggered activation writes.
    { inherit (file) target;
      # Inherited modes are known only for the witnessed text generators.
      executable = if file.executable != null then file.executable else
        assert (proofFor file).executable != null; (proofFor file).executable;
      source = "${config.home-files}/${file.target}";
    }
  ) (lib.attrValues config.home.file);
  packageProfiles = [
    (toString config.home.profileDirectory)
    "${home}/.nix-profile"
    "${state}/nix/profile"
    "${state}/nix/profiles/profile"
    "/nix/var/nix/profiles/per-user/${user}/profile"
  ];
  generationDirs = [
    "${state}/nix/profiles"
    "${state}/home-manager/profiles"
    "/nix/var/nix/profiles/per-user/${user}"
  ];
in
assert builtins.all (seed: safeTarget seed.target && lib.hasPrefix "/nix/store/" seed.source) mutableSeeds;
{
  schema = 1;
  inherit profile system mutableSeeds nativeDependencies;
  inherit (config.home) username homeDirectory;
  activationPackage = toString config.home.activationPackage;
  inherit files;
  # Pinned HM 78e7d8b: activation-init.sh selects/migrates these exact dirs.
  # Directory entries cover their dynamically numbered *-N-link children;
  # preview/activation must constrain XDG_STATE_HOME and NIX_STATE_DIR to these
  # explicit profile values and reject unrelated existing deployments.
  # The XDG nix directory also covers profile-N-link package siblings. Later
  # consumers normalize overlapping directory entries and preserve unrelated
  # children; this is an inventory, not permission to replace a whole directory.
  profilePaths = lib.unique (packageProfiles ++ [ "${state}/nix" ] ++ generationDirs
    ++ map (directory: "${directory}/home-manager") generationDirs ++ [
      "${state}/home-manager/gcroots/new-home"
      "${state}/home-manager/gcroots/current-home"
      "/nix/var/nix/gcroots/per-user/${user}/current-home"
    ]);
  # Service files and service-manager effects are distinct ownership surfaces.
  # launchd installs user-owned regular copies outside home.file; systemd units
  # remain the exact proven leaf links already included in files above.
  services = if pkgs.stdenv.hostPlatform.isLinux then
    lib.concatLists (lib.mapAttrsToList (plural: kind:
      lib.mapAttrsToList (name: unit: {
        manager = "systemd";
        name = "${name}.${kind}";
        inherit kind;
        files = builtins.filter (file:
          lib.hasPrefix ".config/systemd/user/" file.target
          && builtins.baseNameOf file.target == "${name}.${kind}"
        ) files;
        wantedBy = unit.Install.WantedBy or [ ];
        requiredBy = unit.Install.RequiredBy or [ ];
        activationNode = "reloadSystemd";
      }) config.systemd.user.${plural}
    ) unitTypes)
  else lib.mapAttrsToList (_: agent:
    assert safeTarget agent.config.Label && !lib.hasInfix "/" agent.config.Label;
    {
    manager = "launchd";
    name = agent.config.Label;
    kind = "agent";
    files = [ {
      target = "Library/LaunchAgents/${agent.config.Label}.plist";
      source = "${config.home.activationPackage}/LaunchAgents/${agent.config.Label}.plist";
      executable = false;
      deployment = "owned-copy";
      mode = "0444";
    } ];
    activationNode = "setupLaunchAgents";
  }) (lib.filterAttrs (_: agent: agent.enable) config.launchd.agents);
  serviceManagerEffects = if pkgs.stdenv.hostPlatform.isLinux then [ {
    manager = "systemd";
    activationNode = "reloadSystemd";
    after = config.home.activation.reloadSystemd.after;
    startServices = config.systemd.user.startServices;
    systemctlPath = config.systemd.user.systemctlPath;
    actions = [ "query-user-manager" "reload-changed-user-units" "start-wanted-units" "stop-obsolete-user-units" ];
    unitDirectories = [ "old-generation/home-files/.config/systemd/user" "new-generation/home-files/.config/systemd/user" ];
    conditional = "Only when the user manager is running or degraded; otherwise skipped";
    partialFailure = "sd-switch and user-manager effects require transaction recovery";
  } ] else [ {
    manager = "launchd";
    activationNode = "setupLaunchAgents";
    after = config.home.activation.setupLaunchAgents.after;
    destinationDirectory = "${home}/Library/LaunchAgents";
    generationDirectory = "LaunchAgents";
    domain = "gui/user-uid";
    actions = [ "bootout-changed-agents" "install-owned-plist-copies" "bootstrap-agents" "bootout-and-remove-obsolete-matching-copies" ];
    partialFailure = "Pinned HM disables errexit and continues after agent failures; activation success alone does not prove manager success";
    preservation = "Unchanged copies skipped; diverged obsolete copies retained";
  } ];
}
