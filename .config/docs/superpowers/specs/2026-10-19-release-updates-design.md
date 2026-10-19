# Nix release detection and confirmed updates

Status: implemented and validated in isolated environments, 2026-10-19. Delivery is local pending the implementation PR; live installation and release publication are separate tasks. See the [implementation evidence](../plans/2026-10-19-release-updates.md) for test boundaries and platform limits.
Tracking: [ISQ-471](https://linear.app/isqrd/issue/ISQ-471) / [ISQ-484](https://linear.app/isqrd/issue/ISQ-484).
Base: main `f758c1f540f850741ca52772f8c369fc7fa31da9`.
Delivery: keep this design and its implementation plan on the feature branch and include both in the implementation PR.

## Outcome and scope

A Nix/Home Manager installation notices a newer stable dotfiles release, shows installed/available versions and release notes, and applies a reviewed update only after confirmation. Personal host configuration survives updates. Rollback selects a retained generation and reports that generation's actual release.

Native bootstrap remains available, with its current ownership guard. This feature does not change today's default installer, install Nix, update native packages, provide native automatic updates, or certify untested platforms.

The first notification surface is tmux. While a client is attached, its asynchronous status job can check at most once per 24 hours. There is no scheduled check while tmux is closed. Outside tmux, use the explicit check command. This avoids new shell files and scheduler services. A system-wide notifier can be considered separately if needed.

## Approach

Use a small private consumer flake for host identity and custom modules, with the shared dotfiles repository as its pinned `dotfiles` input. Reuse the existing `lib.mkHome`, immutable migration application, plan/apply protocol and recovery journals.

Alternatives considered:
- Updating a customized upstream checkout requires merging personal edits into each release and makes upstream versus installed provenance ambiguous.
- Supporting native and Nix updates together adds a second deployment/rollback contract before the Nix path is established.
- A daily systemd/launchd service adds managed files and service transitions; current migration deliberately refuses changed target sets.

## User-facing commands

The installed command is `dotfiles-update`; `dotfiles` remains the existing Git passthrough.

| Command | Behavior |
| --- | --- |
| `configure --source-root PATH --profile NAME` | Validate and remember a clean committed consumer checkout and real profile; initialize private state. Does not activate anything. |
| `status` | Show locally observed installed generation/release, eligible retained rollback generations with version/store path, cached available release, last check and any pending recovery. No network. |
| `check` | Explicit bounded metadata refresh, respecting server backoff; show status and a release-notes link. |
| `install` | Prepare the selected release, build and show the migration preview and exact version change, then prompt `Apply this update? [y/N]`. |
| `rollback --generation STORE_PATH` | Show current/target release and prompt `Roll back to this generation? [y/N]`, then use retained recovery. |
| `status --tmux` | Internal asynchronous status job: emit safe cached badge immediately; refresh metadata only when due and configured. |

Install/rollback require a terminal and an affirmative response; no unattended `--yes` in v1. Closing stdin, declining or interruption before apply leaves deployment unchanged. Builds may populate the Nix store before confirmation. Native/unmanaged installations receive guidance instead of a mutation.

## Personal configuration and candidate preparation

Provide a consumer template under `nix/templates/host/`, with `flake.nix`, `host.nix` and `dotfiles-release.json`. Its only external input is `dotfiles`; use that input's existing pinned nixpkgs/Home Manager through its factories. Reject transitive overrides in v1 rather than silently changing a user's custom dependency graph.

The consumer exposes:
- `homeConfigurations.NAME = dotfiles.lib.mkHome { ...identity; modules = [ ./host.nix ]; deploymentIdentity = ...; }`.
- `packages.SYSTEM.dotfiles-executor = dotfiles.lib.mkDotfilesExecutor { system = SYSTEM; flakeSource = self.outPath; }`.
- `apps.SYSTEM.dotfiles = dotfiles.lib.mkDotfilesApp { system = SYSTEM; flakeSource = self.outPath; }`.

Extract `mkDotfilesExecutor` from the current app factory without changing its behavior; the app remains a wrapper around the resulting launcher. Extract the existing standalone `bootstrap-nix` source validation into a callable function within that same file; its CLI behavior stays unchanged. Package that file as a libexec Python module so the updater reuses the validator without duplicating its trust boundary.

Existing users move their real host declaration/custom modules to the consumer explicitly, commit it and review an ordinary migration preview. Never attempt to parse/rewrite arbitrary personal Nix code automatically. Missing release provenance is displayed as unversioned. Initial adoption is explicit and must satisfy all current migration checks.

For an update:
1. Validate the registered clean, non-shallow checkout and profile; refuse Git submodules and unsupported template input overrides. Never modify the original checkout.
2. Clone its exact committed contents into a private retained candidate under updater state; sanitize Git environment, disable hooks/signing for generated commits, and never copy credentials or local Git configuration.
3. Run the pinned Nix lock update for only `dotfiles`, overridden to the verified full upstream commit. Its release-pinned transitive closure may change. Verify the resolved commit and graph; unrelated inputs and all host files must remain unchanged.
4. Write verified `dotfiles-release.json` (repository, release ID, version, full upstream commit), then commit only that receipt and `flake.lock` with a fixed local tool identity.
5. Build `#dotfiles-executor` through an out-link inside the retained candidate directory. That GC root and source stay available for retry and recovery.
6. Use this exact candidate's packaged executor for both plan and apply, with `--no-update-lock-file`. Keep review JSON in a private temporary directory outside HOME, as required by the existing CLI.

The proposed lock command is `nix flake update dotfiles --flake CANDIDATE --override-input dotfiles github:ruohao1/dotfiles/FULL_SHA`. A fixture with the repository-pinned Nix must prove it writes the intended lock and a subsequent unmodified no-update evaluation selects that same commit. Do not hand-edit Nix's lock graph or relax validation if the command behaves differently.

## Release and deployment identity

Stable tags use `vMAJOR.MINOR.PATCH`, with no leading zeroes except zero itself. Compare numeric components; never offer equal versions or an implicit downgrade. The source is fixed to public `ruohao1/dotfiles`; v1 has no provider/fork/channel framework.

A release record contains `repository`, positive integer `releaseId`, validated `version`, and 40-character lowercase `commit`. Resolve lightweight and annotated tags to a commit with a bounded traversal. Drafts/prereleases are excluded. A changed commit for a previously observed release/tag is a conflict. Revalidate exact ID, tag, eligibility and commit after review, immediately before apply; if Latest changes, keep the reviewed release rather than substituting another one.

Add optional `deploymentIdentity` to `mkHome` and its manifest, containing schema 1, the verified release record, immutable consumer source store path and profile name. The consumer must assert receipt commit equals `dotfiles.rev`. Its source path binds host files, receipt and lock without relying on `self.rev`, which is absent when the executor reevaluates a store path.

Serialize this pre-build identity with `pkgs.writeText` and add it to `home.extraDependencies`. Exclude generation path, manifest fingerprint and executor output from its contents. This avoids a dependency cycle and makes two releases produce distinct generations even if their configuration files are identical.

Do not change the exact `owner.json` schema. Read identity from the validated journal's manifest for `owner.selectedGeneration`, confirm the actual Home Manager profile selector agrees, and display pending/recovery/unknown when evidence is incomplete or inconsistent. Do not derive installed version from checkout HEAD, newest cache, a candidate record or the journal's original manifest. Older manifests remain readable and recoverable without new fields.

## Background checks and mutable state

Use fixed `$HOME/.local/state/dotfiles-update` so changing XDG variables cannot select another installation. Create it before preview; private directories are 0700 and regular state files 0600. Reject symlinked, foreign-owned or group/world-writable state. Write JSON atomically; ordinary state reads are capped at 16 MiB and retained deployment plans at 64 MiB.

One updater lock serializes configure/check/install/rollback. Tmux uses a nonblocking lock; install holds it through preview, confirmation and apply. The existing deployment HomeLock remains solely for deployment/recovery.

Keep `config.json`, `cache.json`, lock and retained candidate directories inside that state root. Cache schema 1 records last attempt, last successful check, next allowed attempt, separate server backoff deadline, the latest-release endpoint's ETag and last valid release. Persist an attempt before fetching; failure still delays the next background attempt by 86,400 seconds. Respect a longer Retry-After or rate-limit reset, retain old valid data on failure/304, and resolve the tag afresh on a due check even after 304. If the local clock moves behind lastAttempt, rebase the local daily window to now plus 86,400 seconds while retaining server backoff; an explicit check can bypass only the daily window. A malformed cache shows unknown/stale status and permits a bounded retry.

Use Python's standard-library HTTPS/JSON support, a 20-second overall metadata budget, 1 MiB response limit, and at most eight tag dereferences. Request only fixed GitHub API endpoints; no authentication is required. Metadata requests never fetch source, invoke Nix, install packages or evaluate commands. Release notes are a locally constructed GitHub link, not remotely supplied terminal markup.

Tmux `#()` already runs asynchronously. Edit the existing status configuration to show a small `update vX.Y.Z` badge when space permits, or a compact `UPD` indicator. Emit only locally formatted validated versions; no API text or format sequences. No helper or no configured Nix installation means an empty badge and no background network work. The explicit status command always supplies full detail.

Directory evidence in the migration code is shallow, not recursive. Changing files inside the already existing updater directory does not alter its parent's evidence. Creating a new root after a manual preview can invalidate that preview and must require regeneration. Never exclude updater state from migration evidence or relax stale-plan refusal.

## Packaging, apply and recovery boundaries

Package the helper from `nix/update/` and add it through `nix/packages.nix`, so both home.packages and the tmux service's package-derived PATH include it. Do not add helper files or tests to auto-adopted tmux/Neovim directories. Modify only existing tmux status configuration; normalized managed target sets must remain identical across this feature.

Before apply, show release change, host/profile, release-notes link, conflicts/native prerequisites, retained prior generation and plan location. Abort on conflicts, local drift, unsupported target changes or missing provenance bindings. Confirmation authorizes only that exact candidate. The updater launcher captures the original caller PATH before adding its own pinned runtime. Run the candidate's rooted executor with that original caller PATH for both preview and apply; retain it for recovery. Do not filter PATH to conceal shadowing. Existing apply performs its own exact-plan, ownership and drift checks.

Ordinary package upgrades need one focused extension to existing provider checks: recognize a command selected through the journal-owned canonical Home Manager profile when it resolves to the active generation's exact old provider, then permit only the reviewed transition to the new provider after activation/profile proof. Apply the same rule in preview, resumed verification and native-prerequisite observations such as uv. Preserve actual native claims, query results and external environments. Direct store paths that remain bound to an old generation, foreign PATH shadows, changed user tools and unexplained drift still fail with instructions to start a shell using the current canonical Nix profile; never silently rewrite the caller's PATH. Tests must upgrade real provider versions, including uv, rather than only changing release labels.

Initial adoption may also introduce the canonical profile route for a previously absent command or the exact same pinned provider. Require the reviewed generation, activation journal phase, canonical profile and unchanged native package inventory before reconciling that route in comparison copies. The original plan, journal evidence, caller PATH and all unrelated observations remain unchanged.

Before invoking apply, atomically retain the exact reviewed plan bytes in the existing candidate directory and record transaction ID, plan SHA-256, manifest fingerprint, candidate commit, rooted executor and original caller PATH. Copying this plan inside a preexisting unobserved subtree must pass the unchanged-evidence regression; the public plan command still writes outside HOME. Recovery validates this retained copy against the journal when one exists, restores the recorded caller PATH and invokes the same rooted executor. Never regenerate a different preview for an interrupted transaction. If the temporary review file disappears before this association is committed and no transaction exists, require a new preview and confirmation.

Candidate bookkeeping is recovery information, not authoritative installed-version state. Retain executor roots and candidate sources after success, failure and rollback; no automatic cleanup. A process death releases the updater's advisory lock, but a subsequent install must detect a pending transaction and offer the existing explicit recovery path. Keep direct executor commands available if the installed helper becomes unavailable.

Rollback uses a retained executor associated with the active transaction, validates the selected retained generation and delegates to the existing rollback operation. It needs no network. Afterward status follows the selected generation. Older unversioned generations remain available. Missing candidate roots cause a clear recovery instruction, never an automatic source substitution.

Changing owned target sets remains outside v1: preserve the current refusal and document explicit restore-legacy/re-adoption for such a release. The updater never performs that migration automatically. Native prerequisites and packages remain outside Nix generation rollback.

## Release publication and acceptance

Start with a manual runbook in `nix/README.md`, not a release workflow: select an exact tested main commit, enable GitHub immutable releases before the first publication, create/verify its stable tag, draft reviewed notes, then publish and deliberately mark Latest. Settings/tag/publication changes require a separately authorized release task; none occur during planning or implementation tests.

Accept v1 only after:
- Cached/offline/concurrent/rate-limited checks, malicious metadata and immediate cached tmux output pass isolated tests.
- Personal modules survive preparation; dirty source, dependency-graph escape and tag drift fail before apply.
- Real pinned-Nix fixtures prove lock behavior, executor retention, distinct generation identity and unchanged managed target sets.
- A→B→rollback A, declined confirmation, interrupted apply, stale plans and older journals pass existing migration tests with new updater coverage.
- Disposable Linux integration exercises real candidate plan/apply/recovery. Evaluate all four declared targets; native macOS/ARM runtime claims require actual platform runs.

No live-home activation is part of validation. This plan does not upgrade current native macOS or ARM Linux evidence to “verified.”

## Source references

Repository evidence: `README.md`, `flake.nix`, `nix/lib/mk-home.nix`, `nix/lib/deployment-manifest.nix`, `nix/migration/{model,plan,transaction,cli}.py`, `nix/packages.nix`, `nix/services/tmux.nix`, and `.config/tmux/conf/status.conf`.

- [GitHub releases](https://docs.github.com/en/rest/releases/releases), [refs](https://docs.github.com/en/rest/git/refs#get-a-reference), [annotated tags](https://docs.github.com/en/rest/git/tags#get-a-tag).
- [Immutable releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases), [API best practices](https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api), [rate limits](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api).
- [Nix flake update](https://nix.dev/manual/nix/latest/command-ref/new-cli/nix3-flake-update), [Nix 2.35.2 command implementation](https://github.com/NixOS/nix/blob/2.35.2/src/nix/flake.cc), [locking implementation](https://github.com/NixOS/nix/blob/2.35.2/src/libflake/flake.cc).
- [gh release create](https://cli.github.com/manual/gh_release_create).
