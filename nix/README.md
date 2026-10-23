# Locked package profiles

This experimental route builds packages and Home Manager generations. Explicit
reviewed migration transfers selected files and services; a build or preview does
not activate a home. Shell/Git identity files remain outside the transfer. Sources retain the repository's `.config/`, `.local/`, and
`Library/` layout.

## Explicit identities

`nix/hosts.nix` declares disposable `check-<system>` profiles for
`x86_64-linux`, `aarch64-linux`, `x86_64-darwin`, and `aarch64-darwin`.
The check username is `dotfiles`, with `/home/dotfiles` on Linux and
`/Users/dotfiles` on Darwin. These are build identities, never deployment defaults.

`lib.mkHome { profile, system, username, homeDirectory, modules ? [] }` composes
shared and matching platform modules. Every identity field is required; unknown
systems, mismatched platforms, invalid usernames, and relative/root home paths
fail evaluation. Add a real explicit host profile before any deployment.

The shared module initializes `home.stateVersion = "26.05"`. Preserve that value
for a profile after its first activation; changing package inputs does not require
changing stateVersion. A built generation has an activation script, but building
it does not run that script.

## Locked inputs and selected versions

The committed inputs are real revisions resolved by Nix:

- nixpkgs-unstable: `fb5801cc1be2e032e0bec07f2206e2cbe98fb3c6`
  (`2026-06-20`); NAR hash
  `sha256-1boJmgBroTFlzNlwuytgpseDHLqb4BjQgqewQpKDLDs=`.
- Home Manager master: `78e7d8b13ecd7f5256a5c11ce216876164099d9f`
  (`2026-06-20`); NAR hash
  `sha256-npfH7Zv7t1akX/ArqCNro4zU4ViPlghLaPnbEfHbCxk=`.
  Its nixpkgs input follows the root's locked nixpkgs.

The latest checked unstable revision, `c9fe7d12cd78d1adcd12dd15e24432dde5b155a0`,
rejects `x86_64-darwin` outright after upstream removed support. The earlier lock
preserves the approved four-system inventory and emits upstream's Intel macOS
limited-maintenance/deprecation warning. This pin is a compatibility decision;
it does not establish current upstream support or native macOS validation.

The older package set needs three bounded providers under `nix/pkgs/`:

- tmux 3.7c: source override from the official newer nixpkgs expression, retaining
  the locked build recipe and its dependencies, with upstream Darwin jemalloc
  setup. The older control-notify patch is already included upstream.
- herdr 0.8.0: official binaries for each declared OS/architecture. SHA-256 values
  come from the official release API; Linux values also match the committed direct
  download manifest. Linux binaries receive Nix ELF interpreter/library fixups.
  [Official release](https://github.com/herdrdev/herdr/releases/tag/v0.8.0).
- Lua LS 3.19.1: source/submodule override from the official newer nixpkgs
  expression. The retained build recipe is unchanged. This preserves the existing
  bootstrap minimum, which is additional to the design's enumerated floors.

Selected versions from real evaluation are identical across the four systems
except for the platform-specific iconv and C compiler providers. This table records selection;
only a matching native build establishes executable behavior.

| Provider | Selected version |
| --- | --- |
| git | 2.54.0 |
| python3 | 3.13.13 |
| neovim | 0.12.3 |
| fzf | 0.73.1 |
| ripgrep | 15.1.0 |
| jq | 1.8.1 |
| ShellCheck | 0.11.0 |
| stylua | 2.5.2 |
| tree-sitter | 0.26.8 |
| imagemagick | 7.1.2-23 |
| uv | 0.11.22 |
| nodejs | 24.15.0 (native Linux npm 11.12.1) |
| taplo | 0.10.0 |
| npm language servers | Bundle 1.0.0; exact individual pins below |
| iconv | Linux glibc 2.42-61 bin output; Darwin libiconv 113 |
| coreutils | 9.11 |
| perl | 5.42.0 |
| bash-interactive | 5.3p9 |
| curl | 8.20.0 |
| gawk | 5.4.0 |
| gnused | 4.9 |
| gnugrep | 3.12 |
| findutils | 4.10.0 |
| diffutils | 3.12 |
| gnutar | 1.35 |
| gzip | 1.14 |
| unzip | 6.0 |
| xz | 5.8.3 |
| cc compiler | Linux GCC 15.2.0; Darwin Clang 21.1.8 |
| herdr | 0.8.0 |
| tmux | 3.7c |
| lua-language-server | 3.19.1 |

## Package contract

`packages.nix` returns `{ packages, commandRequirements, nativeDependencies }`.
Each required command names exactly one store provider or a declared native
prerequisite. The package check independently requires the complete command
inventory, rejects missing/duplicate providers, and invokes each store executable
by its absolute provider path. Child processes resolve only the declared closure.

The native C compiler (`stdenv.cc`) preserves the existing apt `build-essential`
and Arch `base-devel` workflow, including writable tree-sitter parser builds. The
package check compiles and runs a tiny C program in a private temporary directory;
compiler version text alone cannot satisfy the check.

Checks enforce the minimum versions, exact npm dependency versions, and Python's
`>=3.10,<3.15` range. They start Neovim without user configuration, exercise
ImageMagick `identify` and `convert`, convert UTF-8 with `iconv`, and verify known
SHA-256 output from `sha256sum` and `shasum`. Linux iconv uses the real
`glibc.bin` command output; its `libiconv` compatibility marker supplies headers
and cannot provide the executable. Darwin uses the upstream libiconv command package. All six language-server command names
must answer a real LSP `initialize` request. Stable Taplo must additionally support
`lsp stdio --help`; version text alone is insufficient. Probe processes use private
sessions and temporary workspaces and are terminated/reaped on success or failure.

The npm derivation consumes the existing JSON manifest and full dependency lock
without changing either. It installs Bash LS 5.6.0, Pyright 1.1.411,
`vscode-langservers-extracted` 4.10.0, and YAML LS 1.24.0, with the command names
used by the editor. Its fixed-output dependency hash was obtained using
`prefetch-npm-deps` against the committed lock.

## Native prerequisites

Package checks report native prerequisites but do not claim to validate them from
a build sandbox. Preview and native platform validation must check them on the
target host before activation:

- Native Ghostty and its SpaceMono Nerd Font.
- The retained external uv tool environment returned by `uv tool dir`, containing
  VisiData 3.4, pyarrow 25.0.0, and duckdb 1.5.5 together. Separate Nix packages do
  not satisfy this runtime contract.
- The retained frozen notebook uv project, its dependency lock, and Python
  `>=3.10,<3.15`. Package installation does not recreate or overwrite that project.
- Clipboard services, desktop/window-manager integration, OS preferences, and
  permissions appropriate to the native host.
  Linux preview accepts a verified local Wayland or X11 session and current-user
  service manager. Wayland uses `wl-copy`/`wl-paste`; X11 retains the editor's
  tmux/OSC52 fallback. Cliphist and Wayland capture tools are required only when
  native Hyprland configuration or clipboard capture assets/services are present.
  Preview verifies the session and required providers; the separate terminal
  checker validates capture files and rejects partial capture installations.
  Remote/SSH sessions do not satisfy local desktop readiness, and full
  clipboard/terminal behavior still needs native workflow validation.
- Linux: root-owned, executable Bubblewrap without group/world write permissions,
  plus a successful real namespace probe. Installing a store binary alone cannot
  prove this requirement. Keep GNU `timeout` discoverable through `command -p`,
  independently of the Home Manager PATH. The coreutils package does not replace
  this host prerequisite.

Ubuntu 24.04 restricts unprivileged user namespaces through AppArmor. The
[Ubuntu validation fixture](validation/2026-10-17-ubuntu-wrapper.md) grants
`userns` to its exact immutable Bubblewrap executable while retaining the global
restriction. This follows [Ubuntu's per-application policy guidance](https://documentation.ubuntu.com/release-notes/24.04/#unprivileged-user-namespace-restrictions).
It is separate native preparation; migration does not install or change that policy.

Darwin data queries retain the existing unsupported result. No sandbox condition
is relaxed for single-user Nix. Essential missing native prerequisites must fail
preview/platform validation; listing them here does not make them optional.

## Verification

The [Nix source tests workflow](../.github/workflows/nix-source-tests.yml) runs
the package-checker self-test, entrypoint, ownership, clipboard checker, migration and updater source suites
on Ubuntu pull requests and pushes to `main`. It uses private fixture homes,
reports test results and skips, and needs no Nix installation. These checks substitute
activation and service managers; a passing CI job does not establish Nix builds
or native platform acceptance.

The terminal Nix check also runs a copied Neovim-only source suite. Its fixture
contains no sibling tmux or dotfiles tree, and each editor child has a private
HOME, data/cache directories, temporary directory and log. To run it directly
with installed Neovim 0.12 or newer and tmux, select a short, previously absent
fixture path:

```sh
python3 -B nix/tests/run-focused.py --suite editor-standalone \
  --source-root "$PWD" --fixture-root /tmp/nvim-standalone-check
```

This source gate uses `-u NONE`; it does not establish full plugin startup.
Configured-editor validation uses separate isolated homes and prepared pinned
plugins. Ordinary tmux keeps native editor status; dotfiles integrations remain
optional. This refactor retains the existing deployed target list, canonical
helper/RPC paths, writable `lazy-lock.json` and native bootstrap ownership.
It introduces no additional installer or updater.

From a normal source checkout, with the committed lock:

```sh
python3 nix/tests/check-packages.py --self-test
nix flake check --all-systems --no-build
nix build .#checks.x86_64-linux.packages .#checks.x86_64-linux.home --no-link
```

Use the corresponding target name on each matching native builder. All-system
evaluation is distinct from a native build, and a native build is distinct from
activation and terminal/editor runtime validation. The Ubuntu direct-activation
and prepared public-wrapper fixture results are recorded below. Remaining native
platform and application workflows are still pending.

Normal commands use `flake.lock`. Updates are deliberate reviewed lock changes;
no automatic input updates occur during activation. Never activate a disposable
check profile in a real home.

Recorded Task 1 validation on 2026-10-03:

| Target | Evaluation | Native package/home build | Activation |
| --- | --- | --- | --- |
| x86_64-linux | Passed | Passed on isolated Linux builder | Not run |
| aarch64-linux | Passed | Not run | Not run |
| x86_64-darwin | Passed, upstream maintenance warning | Not run | Not run |
| aarch64-darwin | Passed | Not run | Not run |

The Linux package build passed all five guard tests and every store command's
version/capability check. Native prerequisites remain host validation requirements.
The Linux builder ran Nix 2.35.2 using the official pinned image digest
`sha256:7a007c766426c1877758ddc5cb87a965ac131fc78c582ce0083d922d51ae945c`,
without host mounts or activation. These checks do not establish Linux-distribution
installation behavior or macOS runtime support.


## Installation and migration (experimental)

Install Git and Python 3, then follow the platform-specific [official Nix
installation instructions](https://nixos.org/download/). Installation is an
explicit machine-administration step; `bootstrap-nix` only delegates. Enable
`experimental-features = nix-command flakes` in your Nix configuration and open
a shell with the installed Nix environment loaded. Do not install another Nix
instance over an existing installation without reviewing its configuration.

Create a separate full-history (non-shallow) conventional checkout or registered
Git worktree. For a shallow clone, run `git fetch --unshallow` in its repository
to complete the history before retrying; the wrapper refuses shallow sources
before invoking Nix. Do not pass
HOME, a HOME ancestor, the bare `.cfg` metadata directory, a plain export or a
checkout subdirectory as the source root. The wrapper validates the canonical
root before invoking Nix, selects a percent-encoded Git file URL at the exact
committed revision, and requires tracked regular `flake.nix` and `flake.lock`.
Untracked files are excluded from the Git import. Review trusted source and
inputs before execution; arbitrary Nix expressions are code. This boundary
prevents accidental broad directory imports, not malicious reviewed expressions.

Add a profile to the attribute set returned by `nix/hosts.nix`, for example:

```nix
# Append to the existing expression. Replace every example identity explicitly.
// {
  your-host = {
    system = "aarch64-darwin";  # select the actual matching build target
    profile = "darwin";        # use "linux" for Linux
    username = "YOUR_ACCOUNT";
    homeDirectory = "/Users/YOUR_ACCOUNT";
  };
}
```

Use `/home/YOUR_ACCOUNT` only when that is the actual Linux account home; no home
path is inferred. Keep the initialized `home.stateVersion`. Review and commit the
profile and any selected configuration edits. The wrapper refuses tracked/index
drift. A linked worktree of the bare repository is supported; do not reset or
clean the legacy home to obtain a source checkout.

Before preview, separately prepare native Ghostty/SpaceMono Nerd Font, the native
clipboard and desktop session, window manager, OS preferences and application
permissions. On macOS this includes the desired AeroSpace/Karabiner and
Accessibility/Driver Extension permissions where applicable. On Linux prepare
Bubblewrap's required ownership/permissions and real namespace capability, and
GNU timeout in the default command search path. Missing observed prerequisites
appear as preview conflicts and cannot be overridden with a success receipt.

Preserve existing external environments. After resolving any conflicting uv tool
installation, the separate pinned VisiData preparation operation is:

```sh
uv tool install --with pyarrow==25.0.0 --with duckdb==1.5.5 --no-config visidata==3.4
```

Prepare the frozen notebook project with `:NotebookBootstrap` and its retained
lock; keep Python `>=3.10,<3.15`. Prepare the configured tree-sitter parsers in
writable editor data with the pinned compiler/parser CLI before testing editor
workflows. These preparation steps may need downloads; ordinary activation does
not run them. Preserve editor data/cache, writable `lazy-lock.json`, local
extensions, tmux state, `.cfg`, bootstrap journals, native packages and unrelated
files. The preview does not automatically adopt an unrelated Home Manager
installation or reconcile differing local service files.

From any caller directory, create a private temporary review directory outside
HOME and use an unused absolute plan path:

```sh
review_dir=$(mktemp -d /tmp/dotfiles-review.XXXXXX)
/path/to/checkout/.config/dotfiles/bootstrap-nix --source-root /path/to/checkout -- \
  plan --profile your-host --output "$review_dir/plan.json"
# Inspect the JSON, resolve every conflict and re-preview to an unused plan path.
/path/to/checkout/.config/dotfiles/bootstrap-nix --source-root /path/to/checkout -- \
  apply --plan "$review_dir/plan.json"
```

The preview observes all of HOME, so writing a plan anywhere inside HOME would
change a recorded migration input and is refused. Keep the review directory
outside HOME and every other recorded input (including the source and generation).
Preview builds/inspects the generation and writes only the chosen plan (plus Nix
store/evaluator cache effects). Existing output files are refused. Apply checks
exact reviewed evidence again under the ownership lock. Reapplying that plan is
idempotent only while its reviewed state still matches; drift requires review.
The packaged app embeds its immutable source for all nested eval/build calls;
cwd and ambient source variables cannot redirect it. Outer and nested calls
refuse lock-file updates. Neither wrapper nor app silently updates inputs.

Integrate Home Manager session variables explicitly into the appropriate existing
shell initialization, then open a fresh shell:

```sh
. "$HOME/.nix-profile/etc/profile.d/hm-session-vars.sh"
```

The migration does not replace your shell/Git identity files. Verify selected
providers in the new shell, then perform the real terminal/editor/LSP and desktop
workflow checks; successful activation alone is insufficient.

### Updates and two recovery routes

For an intentional update, edit the separate checkout, deliberately update its
lock with `nix flake update` if wanted, inspect revisions/versions and build on
matching native systems, then commit. Use the committed checkout for a new
preview and explicit apply. Never update `home.stateVersion` merely for packages.
Keep retained generations, journals and backup data until recovery is no longer
needed; these commands do not authorize cleanup.

`rollback` selects an already reviewed retained Home Manager generation and
keeps Home Manager ownership. `restore-legacy` reverses the handoff, preserves
post-migration edits in recovery storage, restores recorded profiles/services,
and releases ownership only after recovery completes:

```sh
/path/to/checkout/.config/dotfiles/bootstrap-nix --source-root /path/to/checkout -- \
  rollback --generation /nix/store/RETAINED-home-manager-generation
/path/to/checkout/.config/dotfiles/bootstrap-nix --source-root /path/to/checkout -- \
  restore-legacy --transaction TRANSACTION_ID_FROM_PLAN
```

After interruption inspect the retained ownership/journal state and retry the
appropriate explicit recovery command; do not delete the guard or run legacy
bootstrap around it. Native packages remain installed. Current legacy bootstrap
entrypoints enforce ownership, including scoped operations and rollback.
Arbitrary old copies cannot gain this guard retroactively. Do not use ordinary
bootstrap as a desktop-only installer after transfer.

### Assigned native smoke harness

`nix/tests/platform-smoke.sh --profile NAME --fixture-root PATH` requires Python3
and a separately provisioned disposable VM or dedicated account. A temporary HOME
on the live user's manager is refused. An administrator must first install a
regular root-owned, non-group/world-writable
`/etc/dotfiles-platform-fixture.json`, under equally protected real parents:

```json
{
  "schema": 1,
  "scope": "disposable-vm",
  "system": "linux",
  "uid": 1000,
  "username": "ASSIGNED_ACCOUNT",
  "home": "/home/ASSIGNED_ACCOUNT",
  "profile": "ASSIGNED_PROFILE",
  "fixtureRoot": "/var/tmp/ASSIGNED_PRIVATE_EVIDENCE",
  "sourceRoot": "/path/to/clean/committed/checkout",
  "sourceRevision": "EXACT_REVIEWED_COMMIT",
  "machineId": "ACTUAL_MACHINE_ID",
  "bootId": "ACTUAL_LINUX_BOOT_ID",
  "managerPID": 1234,
  "managerStart": "ACTUAL_LINUX_PROC_START_TICKS"
}
```

These are placeholders, never default account assignments. A dedicated account
uses `scope: dedicated-account`. Linux identifiers come from `/etc/machine-id`,
`/proc/sys/kernel/random/boot_id`, the actual `user@UID.service` MainPID and that
PID's `/proc/PID/stat` start time. Use the assigned account's real runtime and
local bus. Darwin uses `system: darwin`, actual IOPlatformUUID and the current
native `launchctl managerpid`; it additionally verifies manageruid and gui/UID
access. Linux boot/start fields do not apply to Darwin. No native Darwin harness
pass is claimed yet. Refresh the administrator assignment after manager restart.

The fixture root must already exist outside the account home with mode0700 and
that account's ownership. The harness independently checks actual passwd/home,
UID, profile, machine and manager before creating evidence or invoking the app.
Only a real administrator assignment authorizes that manager; a user-provided
environment variable cannot do so. The harness performs preview, apply, repeated
apply, rollback to the reviewed generation and repeatable reverse handoff. It
retains command logs, the original plan, assignment and result on failure, and
preserves command failure status. It does not provision prerequisites or certify
a second-generation update, edited-config scenario, or full GUI workflow; those
remain separate recorded platform gates. Never run it on a live user manager.

### Evidence boundaries

| Target / environment | Evaluation | Native package/home build | Distro migration | Full GUI/editor workflow |
| --- | --- | --- | --- | --- |
| x86_64 Linux | Passed | Passed in isolated builder | NixOS integration and prepared Ubuntu public-wrapper fixtures passed; Debian/Arch migration pending | Pending |
| aarch64 Linux | Passed | Pending matching runner | Pending | Pending |
| x86_64 Darwin | Passed with upstream warning | Pending matching runner | Pending native macOS | Pending |
| aarch64 Darwin | Passed | Pending matching runner | Pending native macOS | Pending |

On 2026-10-17, production source `c19c5810dc7d0eaba2e87e8f7f2ac6633d2dac50`,
with fixture-only host declarations, exercised the public migration wrapper on
an offline Ubuntu 24.04.5 x86_64 VM. Preview, apply, repeat, generation rollback
and legacy restoration passed across two VM runs with a guarded continuation.
Native prerequisites were prepared separately, including a scoped Bubblewrap
AppArmor policy. That fixture kept the same package inventory and did not test
actual package upgrades, preservation of a nonempty native Nix package profile
or full desktop workflows. See the [wrapper validation record](validation/2026-10-17-ubuntu-wrapper.md).

On 2026-10-19, production source `95e3bb9f3bf381ed417a64664200d94b7713f460`
with this branch's fixture additions passed the release updater's offline
x86_64 NixOS VM scenario: real uv
0.11.21 → 0.11.22 → 0.11.21, installed release A → B → A, interrupted
update recovery from the exact retained plan, and repeated apply. The original
consumer checkout, native package profile and seven native runtime observations
were preserved. A separate bounded run of the same snapshot passed the legacy
migration lifecycle, edited-file restoration, service-stop failure recovery and
interrupted-activation recovery. Discovery and candidate preparation use
prebuilt offline projections in this VM; separate real Git/Nix fixtures verify preparation.
This does not verify public release transport, full desktop workflows or other
platforms.

On 2026-10-17, source `6fd61bc335e5342b0c83811b658b6d526eb443cf` with the unchanged
lock evaluated all six non-VM check derivations on each of the four systems.
All six x86_64 Linux targets (`files`, `home`, `entrypoint`, `migration`,
`packages`, and `terminal`) built successfully offline in the isolated builder.
This includes the evaluated StyLua deployment and rendered terminal checks;
11 entrypoint cases remained explicitly skipped. No home was activated, and
native platform acceptance remains open. See the [build validation record](validation/2026-10-17-nix-builds.md).

On 2026-10-16, source `cc2825595284c1a2c4f50e86b8f01bcf7993aece` with an unchanged
lock passed 119 isolated source tests, with 12 skipped and no failures. A
disposable offline Ubuntu 24.04.5 x86_64 VM passed Nix installation and direct
Home Manager activation of generation A, a synthetic generation B, repeated B
activation, and rollback to A. An edited writable `lazy-lock.json` and an
unmanaged file survived. This did not exercise the public migration wrapper,
native prerequisites, full GUI/editor workflows, other Linux distributions, or
macOS. See the [validation record](validation/2026-10-16-ubuntu-smoke.md).

The retained NixOS integration covers actual two-generation migration, repeat,
rollback, reversal, partial-service and interrupted-activation recovery with real
native preflight observations. It uses an isolated headless fixture, not Ubuntu,
Debian, Arch or native macOS. Native Darwin directory-flock behavior is also
pending; unsupported arbitration fails closed. Each future native record must
include exact OS/architecture, source commit, lock, command/status, generation,
account/manager assignment and remaining workflow preparation. Keep this route
experimental until every gate for an advertised default subset actually passes.

## Confirmed release updates

`dotfiles-update` manages published stable `ruohao1/dotfiles` releases. Native
bootstrap remains the default installer and remains available. The updater does
not install Nix, update native applications, or change `home.stateVersion`.

Keep personal identity and modules in a separate consumer repository. To adopt
it, initialize the [host template](templates/host/flake.nix) from a reviewed
dotfiles checkout:

```sh
mkdir -m 700 my-dotfiles-host
cd my-dotfiles-host
nix flake init -t path:/absolute/path/to/dotfiles#host
git init
```

Set the actual system, username, HOME and profile name in `flake.nix`; put personal
options in `host.nix`. Replace **every placeholder** in `dotfiles-release.json`
with a reviewed published release's repository, numeric release ID, stable tag and
full commit. Verify the release ID/tag/commit against GitHub; the template's
placeholder receipt intentionally cannot activate. Initial adoption is manual;
an older installation without provenance is shown as `unversioned`.

```sh
git add flake.nix host.nix dotfiles-release.json
nix flake lock --override-input dotfiles github:ruohao1/dotfiles/FULL_COMMIT
git add flake.lock
git commit -m 'Declare personal dotfiles host and reviewed release'
# Use a private review directory outside HOME; replace PROFILE with your name.
/path/to/dotfiles/.config/dotfiles/bootstrap-nix --source-root "$PWD" -- \
  plan --profile PROFILE --output /private/review/adoption.json
# Inspect the JSON and resolve every conflict/native prerequisite before apply.
/path/to/dotfiles/.config/dotfiles/bootstrap-nix --source-root "$PWD" -- \
  apply --plan /private/review/adoption.json
dotfiles-update configure --source-root "$PWD" --profile PROFILE
```

The consumer has one external input, `dotfiles`. Submodules, additional consumer
inputs and transitive dependency overrides are refused by v1. `configure`
validates the clean committed checkout and the actual home/user/system/profile;
it performs no activation. It is also available before installation through
`nix run path:/absolute/path/to/dotfiles#dotfiles-update -- configure ...`.

```sh
dotfiles-update status
dotfiles-update check
dotfiles-update install
dotfiles-update rollback --generation /nix/store/RETAINED_GENERATION
```

`status` is local: it compares ownership/journal evidence with the actual selected
Home Manager generation. It lists release identity and retained rollback targets,
cached availability and pending recovery. Missing or inconsistent evidence never
claims a new release is installed. `check` performs a bounded metadata refresh.
Only strict `vMAJOR.MINOR.PATCH` releases are eligible; equal versions and implicit
downgrades are not offered.

`install` clones the registered committed consumer into a retained private
candidate, updates only its dotfiles closure and receipt, and builds an immutable
executor. The original checkout and personal files remain unchanged. It shows the
release change, notes link, prior generation and migration preview, then asks
`Apply this update? [y/N]`. Builds may populate the Nix store before confirmation.
Decline, EOF or interruption before apply leaves deployment unchanged; install
and rollback require a terminal. The reviewed release ID/tag/commit is checked
again immediately before apply; a newer Latest never replaces that selection.

An attached tmux client shows a cached notice while its asynchronous job checks
when due. Background attempts run at most daily, with a 20-second overall metadata
budget, a 1 MiB response cap and server backoff. No configured versioned Nix home
means no background request. There is no shell hook, scheduled service or check
while tmux is closed. Explicit checks bypass the daily interval but respect server
backoff; transient failures retain the last valid cached result.

State is fixed at `$HOME/.local/state/dotfiles-update`, independent of XDG
overrides. Configuration, cache and a process lock live there; candidates retain
their source, executor GC root, reviewed plan and transaction association. State
is created before preview. Cache changes inside that existing directory preserve
preview evidence; creating the directory after a separate preview invalidates it.

Rollback is offline and requires confirmation. It uses the retained executor for
the active transaction and only a journal-retained generation. Native packages,
desktop preferences and external uv environments stay outside Nix rollback.
For an interrupted apply or rollback, run `status` and inspect its exact retained
recovery commands. A pending rollback names its recorded target. `restore-legacy`
cancels an unpublished update or reverses a published handoff; it is not an update
retry. Do not regenerate a new preview to resume an interrupted transaction.
A missing executor root or changed retained plan stops recovery instead of
selecting different source code.

Keep candidate roots, journals and backups until you have separately reviewed
their retention. The updater performs no cleanup. Start updates from a shell
using the current canonical `$HOME/.nix-profile/bin`: an old direct store PATH or
foreign shadow is still refused. Releases that change the managed target set
require explicit legacy restoration/re-adoption; v1 does not automate that change.

## Manual release runbook

Publication is a separate authorized task; none of these actions happen during
update checks or feature validation.

1. Select an exact tested `main` commit. Record the source checks, Linux runtime
   evidence and remaining platform gaps in the notes; do not label evaluation as
   native macOS/ARM runtime verification.
2. Before the first publication, enable GitHub immutable releases for the
   repository. Verify the setting and the chosen stable `vMAJOR.MINOR.PATCH` tag
   points to that exact commit. Never move a previously observed release tag.
3. Prepare reviewed release notes and create a draft using the existing tag:

   ```sh
   gh release create vMAJOR.MINOR.PATCH --repo ruohao1/dotfiles \
     --verify-tag --draft --title vMAJOR.MINOR.PATCH --notes-file release-notes.md
   ```

4. Review the draft, its tag/commit and any assets. Publish and deliberately mark
   Latest only under the release task's authorization. Record the resulting
   numeric release ID and resolved commit for consumer adoption.

No release workflow or unattended activation is installed.
