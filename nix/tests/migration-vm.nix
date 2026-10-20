# Actual nonroot Home Manager integration. This is not native platform acceptance.
{ pkgs, nixpkgs, home-manager, mkHome, mkDotfilesApp }:
let
  lib = pkgs.lib;
  source = ../..;
  inventory = import ../packages.nix { inherit pkgs; };
  prerequisites = import ./migration-prerequisites.nix { inherit pkgs; };
  manager = prerequisites.manager;
  common = { systemd.user.systemctlPath = toString manager; };
  identity = { profile = "linux"; system = "x86_64-linux"; username = "migrator"; homeDirectory = "/home/migrator"; };
  first = mkHome (identity // { modules = [ common { home.sessionVariables.ISQ318_GENERATION = "first"; } ]; });
  secondModule = { lib, ... }: {
    home.sessionVariables.ISQ318_GENERATION = "second";
    home.activation.fixtureInterruptionWindow = lib.hm.dag.entryAfter [ "linkGeneration" ] "${pkgs.coreutils}/bin/sleep 12";
  };
  second = mkHome (identity // { modules = [ common secondModule ]; });
  # Official immutable uv release 338153758; GitHub's asset SHA256 pins the
  # actual older binary, rather than relabeling the locked package's version.
  releaseNixpkgs = nixpkgs // {
    outPath = builtins.toFile "fixture-release-nixpkgs.nix" ''
      args: let pkgs = import ${nixpkgs} args; in pkgs.extend (_: _: {
        uv = pkgs.stdenvNoCC.mkDerivation {
          pname = "uv"; version = "0.11.21";
          src = pkgs.fetchurl {
            url = "https://github.com/astral-sh/uv/releases/download/0.11.21/uv-x86_64-unknown-linux-musl.tar.gz";
            sha256 = "9dadff5b9e7b1d2d011e41852a1cbca713d9d5d88194f2eb6bd240fa4fb0a719";
          };
          sourceRoot = "uv-x86_64-unknown-linux-musl";
          preUnpack = "export TAR_OPTIONS=--no-same-owner";
          installPhase = "mkdir -p $out/bin; install -m755 uv uvx $out/bin/";
          dontStrip = true;
        };
      })
    '';
  };
  releaseLibA = ((import ../../flake.nix).outputs {
    self.outPath = source; nixpkgs = releaseNixpkgs; inherit home-manager;
  }).lib;
  releaseInventoryA = import ../packages.nix { pkgs = import releaseNixpkgs { system = identity.system; }; };
  releaseRecords = {
    releaseA = { repository = "ruohao1/dotfiles"; releaseId = 1001; version = "v1.0.0"; commit = lib.concatStrings (lib.replicate 40 "a"); };
    releaseB = { repository = "ruohao1/dotfiles"; releaseId = 1002; version = "v1.1.0"; commit = lib.concatStrings (lib.replicate 40 "b"); };
  };
  releaseSources = lib.mapAttrs (_: record: pkgs.writeTextDir "dotfiles-release.json" (builtins.toJSON record)) releaseRecords;
  releaseHome = name: factory: factory (identity // {
    modules = [ common ];
    deploymentIdentity = { schema = 1; release = releaseRecords.${name}; consumerSource = toString releaseSources.${name}; profile = "fixture-host"; };
  });
  releaseA = releaseHome "releaseA" releaseLibA.mkHome;
  releaseB = releaseHome "releaseB" mkHome;
  manifest = pkgs.writeText "fixture-manifest.json" (builtins.toJSON first.deploymentManifest);
  # Evaluate the full HM configurations here; the guest projects those exact
  # immutable manifests and output derivations instead of reevaluating modules.
  fixtureProfiles = pkgs.writeTextDir "profiles.json" (builtins.toJSON (lib.mapAttrs (_: profile: {
    manifest = profile.deploymentManifest;
    generation = toString profile.activationPackage;
    # Provenance only: guest realizes the exact already-built immutable output.
    drvPath = builtins.unsafeDiscardStringContext profile.activationPackage.drvPath;
  }) { inherit first second releaseA releaseB; }));
  mkFixtureFlake = selected: pkgs.writeText "flake.nix" ''
    {
      inputs.profiles = { url = "path:${fixtureProfiles}"; flake = false; };
      outputs = { profiles, ... }:
      let
        data = builtins.fromJSON (builtins.readFile (profiles + "/profiles.json"));
        configurations = builtins.mapAttrs (_: profile: {
          deploymentManifest = profile.manifest;
          activationPackage = builtins.appendContext profile.generation {
            "''${profile.generation}" = { path = true; };
          };
          activationDerivation = profile.drvPath;
        }) data;
      in {
        homeConfigurations = ${if selected == null then "configurations" else "{ fixture-host = configurations.${selected}; }"};
      };
    }
  '';
  # Hash the actual immutable payload, without daemon realization in a build.
  mkFixtureSource = selected: pkgs.runCommand "dotfiles-fixture-profile-source" {
    nativeBuildInputs = [ pkgs.nix pkgs.python3 ];
  } ''
    mkdir -p "$out"
    cp ${mkFixtureFlake selected} "$out/flake.nix"
    payloadHash=$(nix --extra-experimental-features nix-command hash path --sri ${fixtureProfiles})
    python3 - "$out/flake.lock" "$payloadHash" <<'PY'
    import json,sys
    source={"type":"path","path":"${fixtureProfiles}"}
    lock={"version":7,"root":"root","nodes":{
        "root":{"inputs":{"profiles":"profiles"}},
        "profiles":{"flake":False,"original":source,"locked":dict(source,narHash=sys.argv[2])}}}
    with open(sys.argv[1],'w') as stream:
        json.dump(lock,stream,sort_keys=True,indent=2); stream.write('\n')
    PY
  '';
  fixtureFlake = mkFixtureFlake null;
  fixtureSource = mkFixtureSource null;
  fixtureApp = mkDotfilesApp { system = "x86_64-linux"; flakeSource = fixtureSource; };
  releaseAppA = releaseLibA.mkDotfilesApp { system = identity.system; flakeSource = mkFixtureSource "releaseA"; };
  releaseAppB = mkDotfilesApp { system = identity.system; flakeSource = mkFixtureSource "releaseB"; };
  releaseFixture = pkgs.writeText "fixture-release-update.json" (builtins.toJSON {
    source = toString source;
    profiles = "${fixtureProfiles}/profiles.json";
    sources = { releaseA = toString (mkFixtureSource "releaseA"); releaseB = toString (mkFixtureSource "releaseB"); };
    executors = { releaseA = releaseAppA.program; releaseB = releaseAppB.program; };
    inventories = { releaseA = releaseInventoryA.commandRequirements; releaseB = inventory.commandRequirements; };
    versions = { releaseA = "0.11.21"; releaseB = pkgs.uv.version; };
    nativePackage = toString pkgs.weston;
  });
  # Separate facade avoids source -> app -> source recursion; the real outer
  # nix run remains covered, and nested evaluation selects fixtureSource.
  fixtureFacade = pkgs.runCommand "dotfiles-fixture-app-source" { } ''
    mkdir -p "$out"
    cat > "$out/flake.nix" <<'NIX'
    {
      outputs = _: {
        apps.x86_64-linux.dotfiles = {
          type = "app"; program = "${fixtureApp.program}";
          meta.description = "Disposable migration integration";
        };
      };
    }
    NIX
    printf '%s\n' '{"nodes":{"root":{}},"root":"root","version":7}' > "$out/flake.lock"
  '';
  userEnvironment = ''
    export HOME=/home/migrator USER=migrator LOGNAME=migrator
    export PATH=${lib.makeBinPath ((lib.filter (package: package != pkgs.neovim) inventory.packages) ++ [ pkgs.nix pkgs.systemd pkgs.ghostty pkgs.wl-clipboard pkgs.cliphist pkgs.bubblewrap ])}:"$HOME/.local/bin:$HOME/.nix-profile/bin"
    export XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share" XDG_STATE_HOME="$HOME/.local/state" XDG_CACHE_HOME="$HOME/.cache"
    export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-isq318
    export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
    export UV_PYTHON_DOWNLOADS=never
    export PYTHONDONTWRITEBYTECODE=1
  '';
  profileEvidence = pkgs.writeText "fixture-profile-evidence.py" ''
    import json,pathlib,sys
    sys.path.insert(0,'${source}/nix')
    from migration.transaction import Runtime,native_entries,is_home_package,leaf_state
    from migration.model import fingerprint
    home=pathlib.Path('/home/migrator')
    runtime=Runtime(home)
    label,generation=sys.argv[1:]
    profile=home/'.nix-profile'
    before={'pointer':fingerprint(profile),'manifest':fingerprint(profile/'manifest.nix')}
    entries=runtime.profile_packages(profile)
    assert before=={'pointer':fingerprint(profile),'manifest':fingerprint(profile/'manifest.nix')}
    native=native_entries(entries)
    assert len(native)==1 and native[0]['paths']==['${pkgs.weston}'], entries
    if generation=='legacy':
        assert not any(is_home_package(entry) for entry in entries),entries
    else:
        manifest=json.load(open('${fixtureProfiles}/profiles.json'))[generation]['manifest']
        runtime.verify_profiles(manifest)
    result={'entries':entries,'selectedEnvironment':str(profile.resolve()),'queryReadOnly':True}
    if label=='prepared':
        modern=pathlib.Path('/var/tmp/isq318-reviews/modern-profile')
        state=fingerprint(modern)
        modern_entries=runtime.profile_packages(modern)
        assert fingerprint(modern)==state
        assert len(modern_entries)==2 and native_entries(modern_entries)[0]['paths']==['${pkgs.weston}'],modern_entries
        result['modern']={'entries':modern_entries,'selectedEnvironment':str(modern.resolve()),'queryReadOnly':True}
    pathlib.Path('/var/tmp/isq318-reviews/'+label+'-packages.json').write_text(json.dumps(result,sort_keys=True,indent=2)+'\n')
    print(json.dumps(result,sort_keys=True))
  '';
  prepare = pkgs.writeShellScript "fixture-prepare" ''
    set -eu
    ${userEnvironment}
    mkdir -p "$HOME/fixture" /var/tmp/isq318-reviews "$HOME/.local/state/fixture"
    cp ${fixtureFacade}/flake.nix ${fixtureFacade}/flake.lock "$HOME/fixture/"
    # Home Manager prepends dirOf(systemctlPath) and invokes the literal name.
    test "$(PATH=${builtins.dirOf manager}:"$PATH" command -v systemctl)" = ${manager}
    managerState=$(PATH=${builtins.dirOf manager}:"$PATH" systemctl --user is-system-running || true)
    case "$managerState" in running|degraded) ;; *) printf '%s\n' "$managerState"; exit 1;; esac
    ${pkgs.python3}/bin/python3 - <<'PY'
    import json,pathlib,shutil
    home=pathlib.Path('/home/migrator')
    manifest=json.loads(pathlib.Path('${manifest}').read_text())
    for item in manifest['files']:
        if not item['target'].startswith('.config/nvim/python/'):
            continue
        target=home/item['target']; target.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(item['source'],target)
        target.chmod(0o755 if item['executable'] else 0o644)
    PY
    ${prerequisites.prepare}/bin/prepare-dotfiles-native-fixture
    # Fixture-owned payload only; preview never touches clipboard contents.
    printf '%s\n' 'Checking actual fixture clipboard roundtrip'
    printf '%s' 'isq318-fixture-roundtrip' | wl-copy
    test "$(wl-paste --no-newline)" = isq318-fixture-roundtrip
    printf '%s\n' 'Actual fixture clipboard roundtrip passed'
    nativeBefore=$(${pkgs.python3}/bin/python3 ${snapshot} /var/tmp/isq318-reviews/native-before.json)
    ${diagnose} > /var/tmp/isq318-reviews/native-preflight.json
    nativeAfter=$(${pkgs.python3}/bin/python3 ${snapshot} /var/tmp/isq318-reviews/native-after.json)
    ${pkgs.python3}/bin/python3 - <<'PY'
    import json
    records=json.load(open('/var/tmp/isq318-reviews/native-preflight.json'))
    before=json.load(open('/var/tmp/isq318-reviews/native-before.json'))
    after=json.load(open('/var/tmp/isq318-reviews/native-after.json'))
    changes={key:{'before':before.get(key),'after':after.get(key)} for key in before.keys()|after.keys() if before.get(key)!=after.get(key)}
    print('Native observation statuses:',json.dumps([{key:r[key] for key in ['id','status','claims']} for r in records],sort_keys=True))
    if changes or any(record['status']!='observed' for record in records):
        print('Native observation queries:',json.dumps(records[-1]['queries'],sort_keys=True))
    assert not changes, changes
    assert records and all(record['status']=='observed' for record in records), records
    PY
    printf 'Actual read-only native preflight passed: %s\n' "$nativeBefore"
    cd "$HOME/fixture"
    ${pkgs.python3}/bin/python3 - <<'PYTHON'
    import json,subprocess
    profiles=json.load(open('${fixtureProfiles}/profiles.json'))
    evidence={}
    for name,expected in profiles.items():
        prefix='path:${fixtureSource}#homeConfigurations.'+name
        def evaluate(attribute,raw=False):
            output=subprocess.check_output(['nix','eval','--offline','--no-update-lock-file','--raw' if raw else '--json',prefix+attribute],text=True)
            return output if raw else json.loads(output)
        generation=evaluate('.activationPackage',True)
        derivation=evaluate('.activationDerivation',True)
        actual=evaluate('.deploymentManifest')
        assert generation==expected['generation'], (generation,expected)
        assert derivation==expected['drvPath'], (derivation,expected)
        assert actual==expected['manifest'], name
        subprocess.run(['nix','build','--offline','--no-update-lock-file','--no-link',prefix+'.activationPackage'],check=True)
        evidence[name]={'generation':generation,'prebuildDerivation':derivation,'fullManifestEqual':True,'offlineBuild':True}
    with open('/var/tmp/isq318-reviews/projection.json','w') as stream:
        json.dump(evidence,stream,sort_keys=True)
    print('All actual profile projections verified:',json.dumps(evidence,sort_keys=True))
    PYTHON
    # Real native package baseline; all migration operations must preserve it.
    mkdir -p "$HOME/.local/state/nix/profiles"
    if test -L "$HOME/.nix-profile"; then
      mv "$HOME/.nix-profile" "$HOME/.local/state/fixture/original-profile-pointer"
    fi
    test ! -e "$HOME/.nix-profile"
    ln -s "$HOME/.local/state/nix/profiles/profile" "$HOME/.nix-profile"
    nix-env --profile "$HOME/.local/state/nix/profiles/profile" --option substitute false --install ${pkgs.weston}
    nix profile install --offline --profile /var/tmp/isq318-reviews/modern-profile ${pkgs.weston} "$(readlink -f ${first.activationPackage}/home-path)"
    ${pkgs.python3}/bin/python3 ${profileEvidence} prepared legacy
    /bin/sh -c 'command -p -v timeout'
  '';
  seedLegacy = pkgs.writeShellScript "fixture-seed-legacy" ''
    set -eu
    ${userEnvironment}
    ${pkgs.python3}/bin/python3 - <<'PY'
    import json,pathlib,shutil
    home=pathlib.Path('/home/migrator')
    manifest=json.loads(pathlib.Path('${manifest}').read_text())
    service_targets={item['target'] for service in manifest['services'] for item in service['files']}
    for item in manifest['files']:
        if item['target'] in service_targets:
            continue
        target=home/item['target']; target.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(item['source'],target)
        target.chmod(0o755 if item['executable'] else 0o644)
    for name,content in {'.config/nvim/lazy-lock.json':'{}\n','.config/nvim/local-extension.lua':'return {}\n','.cfg/retained':'keep repository\n','.local/state/dotfiles/legacy-journal':'keep journal\n'}.items():
        target=home/name;target.parent.mkdir(parents=True,exist_ok=True);target.write_text(content)
    PY
    # The real status command requires a valid snapshot, even for an empty workspace.
    "$HOME/.config/tmux/scripts/workspace" save
    systemctl --user daemon-reload
    systemctl --user start tmux-workspace.service
  '';
  snapshot = pkgs.writeText "fixture-home-snapshot.py" ''
    import hashlib,json,pathlib,stat,os,sys
    home=pathlib.Path('/home/migrator'); result={}
    for path in [home,*sorted(home.rglob('*'))]:
        relative=path.relative_to(home)
        if relative==pathlib.Path('.cache/nix') or pathlib.Path('.cache/nix') in relative.parents:
            continue  # Explicitly permitted Nix evaluator cache effects.
        info=path.lstat(); value={'mode':info.st_mode,'uid':info.st_uid,'gid':info.st_gid}
        if stat.S_ISLNK(info.st_mode): value['link']=os.readlink(path)
        elif stat.S_ISREG(info.st_mode): value['sha256']=hashlib.sha256(path.read_bytes()).hexdigest()
        result[str(relative)]=value
    serialized=json.dumps(result,sort_keys=True)
    if len(sys.argv)>1:
        pathlib.Path(sys.argv[1]).write_text(serialized)
    print(hashlib.sha256(serialized.encode()).hexdigest())
  '';
  commandInventory = pkgs.writeText "fixture-command-inventory.json" (builtins.toJSON inventory.commandRequirements);
  legacyNativeTools = pkgs.buildEnv {
    name = "fixture-legacy-native-tools";
    paths = inventory.packages ++ [ pkgs.coreutils pkgs.findutils pkgs.gnugrep pkgs.gnused pkgs.gawk pkgs.glibc.bin ];
    pathsToLink = [ "/bin" ];
  };
  legacyReady = pkgs.writeShellScript "fixture-legacy-ready" ''
    set -eu
    ${userEnvironment}
    systemctl --user is-active tmux-workspace.service
    "$HOME/.config/tmux/scripts/workspace" status | ${pkgs.gnugrep}/bin/grep -Fx 'Supervisor: running, ready'
  '';
  diagnose = pkgs.writeShellScript "fixture-preflight-diagnostics" ''
    ${userEnvironment}
    ${pkgs.python3}/bin/python3 - <<'PY'
    import json,pathlib,sys
    sys.path.insert(0,'${source}/nix')
    from migration.prerequisites import inspect_native
    manifest=json.loads(pathlib.Path('${manifest}').read_text())
    manifest['commandRequirements']=json.loads(pathlib.Path('${commandInventory}').read_text())
    print(json.dumps(inspect_native(manifest,pathlib.Path('/home/migrator')),sort_keys=True,indent=2))
    PY
  '';
  command = pkgs.writeShellScript "fixture-command" ''
    set -eu
    ${userEnvironment}
    exec nix run --offline --no-update-lock-file path:${fixtureFacade}#dotfiles -- "$@"
  '';
  releaseCommand = pkgs.writeShellScript "fixture-release-update" ''
    set -eu
    ${userEnvironment}
    # The owned canonical profile must win after adoption. The older fallback
    # supplies real native prerequisites before release A owns that profile.
    export PATH="$HOME/.nix-profile/bin:${lib.makeBinPath (releaseInventoryA.packages ++ [ pkgs.nix pkgs.systemd pkgs.ghostty pkgs.wl-clipboard pkgs.cliphist pkgs.bubblewrap ])}:$HOME/.local/bin"
    exec ${pkgs.python3}/bin/python3 -B ${./update-integration.py} ${releaseFixture}
  '';
in pkgs.testers.runNixOSTest {
  name = "dotfiles-migration-vm";
  requiredFeatures = { kvm = false; devnet = false; uid-range = false; };
  qemu.forceAccel = false;
  globalTimeout = 3600;
  enableDebugHook = false;
  sshBackdoor.enable = false;
  nodes.machine = { lib, ... }: {
    options.virtualisation.qemu.drives = lib.mkOption {
      apply = drives:
        assert lib.count (drive: drive.name == "nix-store") drives == 1;
        map (drive: if drive.name == "nix-store" then drive // {
          driveExtraOpts = drive.driveExtraOpts // { readonly = "on"; };
        } else drive) drives;
    };
    config = {
      users.users.migrator = { isNormalUser = true; uid = 1000; home = "/home/migrator"; linger = true; };
      services.dbus.enable = true;
      systemd.tmpfiles.rules = [
        "d /var/tmp/isq318-reviews 0700 migrator users -"
        "L /usr/local/bin - - - - ${legacyNativeTools}/bin"
      ];
      fonts.packages = [ pkgs.nerd-fonts.space-mono ];
      environment.systemPackages = [ pkgs.ghostty pkgs.wl-clipboard pkgs.cliphist pkgs.weston pkgs.bubblewrap pkgs.coreutils pkgs.nix prerequisites.python ];
      # A genuine pre-HM user supervisor, with the repository legacy entrypoint.
      # Its home unit leaves are absent; differing existing home units remain
      # migration conflicts and are not claimed to be handled by this fixture.
      systemd.user.services.tmux-workspace.serviceConfig = {
        Type = "simple";
        ExecStart = "%h/.config/tmux/scripts/workspace supervise";
        Environment = "TMUX_WORKSPACE_INTERVAL=86400";
        Restart = "on-failure";
        RestartSec = 5;
        TimeoutStopSec = 30;
      };
      nix.settings = { experimental-features = [ "nix-command" "flakes" ]; substituters = lib.mkForce [ ]; };
      systemd.user.services.fixture-weston = {
        wantedBy = [ "default.target" ];
        serviceConfig = {
          ExecStart = "${pkgs.weston}/bin/weston --backend=headless --renderer=pixman --fake-seat --socket=wayland-isq318 --idle-time=0";
          Environment = "XDG_RUNTIME_DIR=%t";
          Restart = "on-failure";
        };
      };
      virtualisation = {
        memorySize = 2048; cores = 1; diskSize = 8192;
        useNixStoreImage = true;
        mountHostNixStore = false;
        writableStore = true;
        writableStoreUseTmpfs = false;
        vlans = lib.mkForce [ ]; interfaces = lib.mkForce { };
        qemu.networkingOptions = lib.mkForce [ ];
        qemu.options = [ "-cpu max" "-nic none" ];
      };
      system.extraDependencies = [ first.activationPackage second.activationPackage releaseA.activationPackage releaseB.activationPackage prerequisites.wheelhouse prepare seedLegacy snapshot diagnose command releaseCommand fixtureFlake fixtureProfiles fixtureSource fixtureFacade ];
    };
  };
  testScript = ''
    import json, re, shlex, textwrap
    start_all()
    assert [link["ifname"] for link in json.loads(machine.succeed("ip -j link"))] == ["lo"], "guest must have no NIC"
    lower = json.loads(machine.succeed("findmnt --json -T /nix/.ro-store -o TARGET,FSTYPE,OPTIONS"))["filesystems"][0]
    assert lower["target"] == "/nix/.ro-store" and lower["fstype"] == "erofs" and "ro" in lower["options"].split(","), lower
    overlay = json.loads(machine.succeed("findmnt --json -T /nix/store -o TARGET,FSTYPE,OPTIONS"))["filesystems"][0]
    assert overlay["target"] == "/nix/store" and overlay["fstype"] == "overlay", overlay
    assert "rw" in overlay["options"].split(","), overlay
    assert any(all(value in overlay["options"].split(",") for value in ["lowerdir="+prefix+"/nix/.ro-store", "upperdir="+prefix+"/nix/.rw-store/upper", "workdir="+prefix+"/nix/.rw-store/work"]) for prefix in ["", "/sysroot"]), overlay
    assert machine.succeed("findmnt -n -T /nix/.rw-store -o FSTYPE").strip() != "tmpfs", "store upper must be disk-backed"
    assert "nix-store" not in machine.succeed("findmnt -rn -t 9p -o SOURCE"), "no container-store share"
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("user@1000.service")
    machine.wait_until_succeeds("test -S /run/user/1000/wayland-isq318")
    def user(script):
        script = ${builtins.toJSON userEnvironment} + "\n" + script
        return machine.succeed("su -l migrator -c " + shlex.quote(script))
    def app(args):
        try:
            return user("${command} " + args)
        except Exception:
            retain_reviews("failed-command")
            print("Native failure diagnostics:", user("${diagnose}"))
            raise
    def retain_reviews(label):
        # Guest-created profile symlinks cannot be dereferenced by the host.
        archive = "/var/tmp/" + label + ".tar"
        arguments = ["-C", "/var/tmp", "isq318-reviews"]
        for name in ["dotfiles-update", "dotfiles-ownership"]:
            parent = "/home/migrator/.local/state"
            if machine.execute("test -d " + shlex.quote(parent + "/" + name))[0] == 0:
                arguments += ["-C", parent, name]
        machine.succeed("${pkgs.gnutar}/bin/tar -cf " + shlex.quote(archive) + " " + shlex.join(arguments))
        machine.copy_from_machine(archive, label + ".tar")
    def plan_fields(name, *fields):
        # Full native observations can exceed the guest command channel's
        # reliable output size. Keep the full plan in the evidence archive.
        script = "import json,sys; p=json.load(open(sys.argv[1])); print(json.dumps({key:p[key] for key in sys.argv[2:]}))"
        arguments = ["/var/tmp/isq318-reviews/" + name + ".json", *fields]
        try:
            return json.loads(user("${pkgs.python3}/bin/python3 -c " + shlex.quote(script) + " " + shlex.join(arguments)))
        except Exception:
            retain_reviews("failed-plan-read")
            raise
    def service_selection():
        output = user("${pkgs.systemd}/bin/systemctl --user show tmux-workspace.service --property=FragmentPath,ExecStart,LoadState,ActiveState,UnitFileState")
        values = dict(line.split("=", 1) for line in output.splitlines() if "=" in line)
        selected = {key: values[key] for key in ["FragmentPath", "LoadState", "ActiveState", "UnitFileState"]}
        executable = re.search(r"\bpath=([^ ;]+)", values["ExecStart"])
        assert executable is not None, values
        selected["executable"] = executable.group(1)
        selected["resolvedFragment"] = user("${pkgs.coreutils}/bin/readlink -f " + shlex.quote(values["FragmentPath"])).strip()
        assert selected["LoadState"] == "loaded" and selected["ActiveState"] == "active", selected
        return selected
    def retain_transaction(label, transaction):
        script = textwrap.dedent(r"""
        import hashlib,json,os,pathlib,shutil,sys
        label,transaction=sys.argv[1:]
        root=pathlib.Path('/home/migrator/.local/state/dotfiles-ownership')
        review=pathlib.Path('/var/tmp/isq318-reviews')
        journal=root/'transactions'/transaction/'journal.json'
        data=json.loads(journal.read_text())
        owner=json.loads((root/'owner.json').read_text()) if (root/'owner.json').exists() else None
        shutil.copyfile(journal,review/(label+'-journal.json'))
        (review/(label+'-owner.json')).write_text(json.dumps(owner,sort_keys=True,indent=2)+'\n')
        profiles={text:os.readlink(text) if pathlib.Path(text).is_symlink() else None for text in data['manifest']['profilePaths']}
        summary={'owner':owner,'phase':data['phase'],'steps':data['steps'],'profiles':profiles,'journalSHA256':hashlib.sha256(journal.read_bytes()).hexdigest()}
        (review/(label+'-state.json')).write_text(json.dumps(summary,sort_keys=True,indent=2)+'\n')
        print(json.dumps(summary))
        """)
        return json.loads(user("${pkgs.python3}/bin/python3 -c " + shlex.quote(script) + " " + shlex.quote(label) + " " + shlex.quote(transaction)))
    user("${prepare}")
    retain_reviews("native-preparation")
    # Native project files are prepared explicitly; other transferred targets
    # are absent. The read-only collector must handle this fresh-home case.
    before = user("${pkgs.python3}/bin/python3 ${snapshot}")
    user("DOTFILES_TEST_PACKAGED_APP=path:${fixtureFacade}#dotfiles DOTFILES_TEST_PROFILE=first DOTFILES_TEST_PLAN=/var/tmp/isq318-reviews/fresh.json DOTFILES_TEST_PROFILES=${fixtureProfiles}/profiles.json DOTFILES_TEST_PROFILE_SOURCE=${fixtureSource} ${pkgs.python3}/bin/python3 -B -m unittest discover -s ${source}/nix/tests -p test_entrypoint.py -k PackagedEntrypointTests")
    assert before == user("${pkgs.python3}/bin/python3 ${snapshot}"), "preview changed prepared home"
    print("Fresh prepared home read-only SHA256:", before.strip())
    fresh = plan_fields("fresh", "conflicts")
    assert not fresh["conflicts"], fresh["conflicts"]
    user("test ! -e /home/migrator/.config/ghostty/config.ghostty")
    user("${seedLegacy}")
    machine.wait_until_succeeds("su -l migrator -c " + shlex.quote("${legacyReady}"), timeout=120)
    legacy_service = service_selection()
    assert legacy_service["executable"] == "/home/migrator/.config/tmux/scripts/workspace", legacy_service
    assert legacy_service["UnitFileState"] == "static", legacy_service
    assert legacy_service["resolvedFragment"] == user("${pkgs.coreutils}/bin/readlink -f /etc/systemd/user/tmux-workspace.service").strip(), legacy_service
    print("Actual legacy service provider:", legacy_service)
    before = user("${pkgs.python3}/bin/python3 ${snapshot}")
    app("plan --profile first --output /var/tmp/isq318-reviews/first.json")
    assert before == user("${pkgs.python3}/bin/python3 ${snapshot}"), "preview changed legacy home"
    print("Legacy prepared home read-only SHA256:", before.strip())
    user("${pkgs.python3}/bin/python3 -c \"import json; p=json.load(open('/var/tmp/isq318-reviews/first.json')); assert not p['conflicts'],p['conflicts']\"")
    first_plan = plan_fields("first", "providers")
    nvim_before = next(item for item in first_plan["providers"] if item["command"] == "nvim")
    assert nvim_before["selectedExecutable"] is None, nvim_before
    assert nvim_before["executable"] == "${pkgs.neovim}/bin/nvim", nvim_before
    user("! command -v nvim")
    machine.copy_from_machine("/var/tmp/isq318-reviews/first.json", "before-first-activation")
    app("apply --plan /var/tmp/isq318-reviews/first.json")
    nvim_selected = user("command -v nvim").strip()
    assert nvim_selected == "/home/migrator/.nix-profile/bin/nvim", nvim_selected
    nvim_resolved = user("${pkgs.coreutils}/bin/readlink -f " + shlex.quote(nvim_selected)).strip()
    assert nvim_resolved == user("${pkgs.coreutils}/bin/readlink -f ${pkgs.neovim}/bin/nvim").strip(), nvim_resolved
    provider_transition = {"before": nvim_before, "selectedAfter": nvim_selected, "resolvedAfter": nvim_resolved}
    user("printf '%s\\n' " + shlex.quote(json.dumps(provider_transition)) + " > /var/tmp/isq318-reviews/caller-provider-transition.json")
    user("${pkgs.python3}/bin/python3 ${profileEvidence} first-active first")
    managed_service = service_selection()
    assert managed_service["executable"] == "${builtins.head (lib.splitString " " (assert builtins.length first.config.systemd.user.services.tmux-workspace.Service.ExecStart == 1; builtins.head first.config.systemd.user.services.tmux-workspace.Service.ExecStart))}", managed_service
    assert managed_service["resolvedFragment"] == user("${pkgs.coreutils}/bin/readlink -f /home/migrator/.config/systemd/user/tmux-workspace.service").strip(), managed_service
    assert managed_service["resolvedFragment"] != legacy_service["resolvedFragment"], managed_service
    print("Actual Home Manager service provider:", managed_service)
    app("apply --plan /var/tmp/isq318-reviews/first.json")
    app("plan --profile second --output /var/tmp/isq318-reviews/second.json")
    app("apply --plan /var/tmp/isq318-reviews/second.json")
    user("${pkgs.python3}/bin/python3 ${profileEvidence} second-active second")
    app("rollback --generation ${first.activationPackage}")
    user("${pkgs.python3}/bin/python3 ${profileEvidence} rolled-back first")
    transaction = plan_fields("first", "transactionId")["transactionId"]
    second_transaction = plan_fields("second", "transactionId")["transactionId"]
    user("${pkgs.python3}/bin/python3 -c \"from pathlib import Path; p=Path('/home/migrator/.config/ghostty/config.ghostty'); content=p.read_text(); p.unlink(); p.write_text(content+'\\n# fixture postmigration edit\\n'); Path('/home/migrator/.config/nvim/lazy-lock.json').write_text('{}\\n')\"")
    assert retain_transaction("before-reversal", second_transaction)["owner"]["phase"] == "home-manager"
    app("restore-legacy --transaction " + transaction)
    app("restore-legacy --transaction " + transaction)
    for label, identifier in [("restored-first", transaction), ("restored-second", second_transaction)]:
        restored = retain_transaction(label, identifier)
        assert restored["owner"] is None and restored["phase"] == "restored", restored
    user("${pkgs.python3}/bin/python3 ${profileEvidence} restored legacy")
    restored_service = service_selection()
    assert restored_service == legacy_service, {"before": legacy_service, "restored": restored_service}
    print("Actual restored legacy service provider:", restored_service)
    user("test ! -L /home/migrator/.config/ghostty/config.ghostty; test ! -e /home/migrator/.local/state/dotfiles-ownership/owner.json")
    user("test -f /home/migrator/.cfg/retained; test -f /home/migrator/.local/state/dotfiles/legacy-journal; test -f /home/migrator/.config/nvim/local-extension.lua")
    user("${pkgs.systemd}/bin/systemctl --user is-active tmux-workspace.service")
    user("touch /home/migrator/.local/state/fixture/fail-after-stop")
    app("plan --profile first --output /var/tmp/isq318-reviews/partial.json")
    status, output = machine.execute("su -l migrator -c " + shlex.quote("${command} apply --plan /var/tmp/isq318-reviews/partial.json > /var/tmp/isq318-reviews/partial.log 2>&1"))
    assert status == 1, {"status": status, "output": output}
    assert "fixture: delegated stop succeeded; injected exit 73" in user("cat /var/tmp/isq318-reviews/partial.log")
    stopped = user("set +e; state=$(${pkgs.systemd}/bin/systemctl --user is-active tmux-workspace.service); status=$?; printf '%s %s\\n' \"$status\" \"$state\"").strip()
    assert stopped in ["3 inactive", "3 failed"], stopped
    user("printf '%s\\n' " + shlex.quote(json.dumps({"applyExit": status, "stopped": stopped})) + " > /var/tmp/isq318-reviews/partial-result.json")
    user("rm /home/migrator/.local/state/fixture/fail-after-stop")
    partial = plan_fields("partial", "transactionId")["transactionId"]
    partial_state = retain_transaction("partial-before-recovery", partial)
    assert partial_state["owner"]["phase"] == "transferring" and partial_state["steps"]["stop-services"] == "intent", partial_state
    assert not any(name.startswith("archive-") or name == "activate" for name in partial_state["steps"]), partial_state
    app("restore-legacy --transaction " + partial)
    partial_restored = retain_transaction("partial-restored", partial)
    assert partial_restored["owner"] is None and partial_restored["phase"] == "restored", partial_restored
    app("plan --profile second --output /var/tmp/isq318-reviews/interruption.json")
    interrupted = plan_fields("interruption", "transactionId")["transactionId"]
    launch = "set +e; ${command} apply --plan /var/tmp/isq318-reviews/interruption.json & child=$!; echo $child > /var/tmp/isq318-reviews/interruption.pid; wait $child; status=$?; printf '%s\\n' \"$status\" > /var/tmp/isq318-reviews/interruption.exit"
    user("(" + launch + ") > /var/tmp/isq318-reviews/interruption.log 2>&1 &")
    machine.wait_until_succeeds("test -L /home/migrator/.config/ghostty/config.ghostty")
    pid = user("cat /var/tmp/isq318-reviews/interruption.pid").strip()
    machine.succeed("kill -TERM " + pid)
    machine.wait_until_succeeds("test ! -e /home/migrator/.local/state/dotfiles-ownership/lock")
    machine.wait_until_succeeds("test -f /var/tmp/isq318-reviews/interruption.exit")
    assert user("cat /var/tmp/isq318-reviews/interruption.exit").strip() == "1"
    assert "interrupted by signal 15" in user("cat /var/tmp/isq318-reviews/interruption.log")
    interrupted_state = retain_transaction("interrupted-before-recovery", interrupted)
    assert interrupted_state["owner"]["phase"] == "transferring" and interrupted_state["steps"]["activate"] == "intent", interrupted_state
    assert "publish-active" not in interrupted_state["steps"] and "verify" not in interrupted_state["steps"], interrupted_state
    app("restore-legacy --transaction " + interrupted)
    app("restore-legacy --transaction " + interrupted)
    interrupted_restored = retain_transaction("interrupted-restored", interrupted)
    assert interrupted_restored["owner"] is None and interrupted_restored["phase"] == "restored", interrupted_restored
    user("${pkgs.systemd}/bin/systemctl --user is-active tmux-workspace.service")
    try:
        user("${releaseCommand} > /var/tmp/isq318-reviews/release-update.log 2>&1")
    finally:
        retain_reviews("release-attempt")
    print("Release transition evidence:", user("cat /var/tmp/isq318-reviews/release-update/summary.json"))
    print("Fixture source and lock hashes:", user("${pkgs.coreutils}/bin/sha256sum ${fixtureSource}/flake.nix ${fixtureSource}/flake.lock ${fixtureFacade}/flake.nix ${fixtureFacade}/flake.lock"))
    print("Reviewed generations: ${first.activationPackage} ${second.activationPackage}")
    retain_reviews("completed-reviews")
    print("Retained journal hashes:", user("${pkgs.coreutils}/bin/sha256sum /home/migrator/.local/state/dotfiles-ownership/transactions/*/journal.json"))
  '';
}
