# Nix Release Updates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect stable dotfiles releases and offer reviewed, confirmed Nix/Home Manager updates with reliable rollback.

**Architecture:** Keep personal configuration in a consumer flake; prepare an isolated candidate pinned to an exact upstream release. A small packaged Python helper reuses the existing immutable migration executor and journals. Tmux runs its bounded metadata check asynchronously and displays cached status.

**Tech Stack:** Existing Nix/Home Manager, Git, Python standard library, unittest and tmux; public GitHub REST API.

**Spec:** [Release update design](../specs/2026-10-19-release-updates-design.md).

**Status:** Approved by the user’s “continue”; implementation and isolated validation are in progress. Base main `f758c1f540f850741ca52772f8c369fc7fa31da9`; branch `agent/release-updates-20261019`. Keep both documents in the implementation PR; no standalone plan PR.

## Global Constraints

- Nix/Home Manager updates first; native bootstrap and its ownership guard remain unchanged.
- No automatic Nix installation, native package update, unattended activation, input-wide upgrade, managed-target reconciliation, or cleanup.
- Stable public `ruohao1/dotfiles` releases only: strict `vMAJOR.MINOR.PATCH`, exact release ID and 40-character commit; no implicit downgrade.
- Background checks at most once per 86,400 seconds while tmux is attached; 20-second total metadata budget, 1 MiB response cap, maximum eight tag dereferences.
- Fixed `$HOME/.local/state/dotfiles-update`; directories 0700, regular state files 0600, no unsafe ownership or symlink traversal.
- The original consumer checkout stays unchanged. Only the candidate's dotfiles input closure and release receipt may change.
- Keep `owner.json` schema, exact-plan validation, `--no-update-lock-file`, existing HomeLock and changed-target refusal.
- Confirmation is interactive and defaults to no. Plan output stays outside HOME; executor roots and candidates are retained.
- Add no managed HOME targets; use package inventory and existing tmux status file. New tests belong in `nix/tests`.
- Existing `home.stateVersion = "26.05"` stays fixed.
- No live-home activation or release publication during implementation checks; macOS/ARM runtime support remains unverified until tested there.

## Review Focus

- A release with identical runtime files must still carry distinct generation provenance; test in Task 1.
- An old or malformed receipt, Git hook/submodule, or dependency override must never bypass exact candidate selection; test in Tasks 1 and 3.
- Process death between candidate preparation and activation must retain enough evidence to recover without reporting success; test in Task 4.
- Background state writes, clock rollback or simultaneous tmux clients must not cause repeated HTTP work or invalidate reviewed input unnoticed; test in Tasks 2 and 5.
- Manual Home Manager selection, malformed old state, or rollback must not leave the displayed release ahead of actual deployment; test in Tasks 1 and 4.

## File map and dependency order

| Area | Files |
| --- | --- |
| Consumer/executor/provenance | `flake.nix`, `nix/lib/mk-home.nix`, `nix/lib/deployment-manifest.nix`, new `nix/templates/host/{flake.nix,host.nix,dotfiles-release.json}` |
| Shared source validation | `.config/dotfiles/bootstrap-nix` (extract callable validator without CLI behavior change) |
| Updater | New `nix/update/{__init__.py,state.py,releases.py,deployment.py,cli.py,package.nix}` |
| Packaging/notification | `nix/packages.nix`, existing `.config/tmux/conf/status.conf` |
| Tests/checks | New `nix/tests/test_update_{identity,releases,candidate,cli,state}.py`, new `nix/tests/update-lock.nix`, existing entrypoint/migration/terminal suites and check definitions |
| Delivery/docs | `.github/workflows/nix-source-tests.yml`, `README.md`, `nix/README.md`, this plan and its spec |

Tasks 1 and 2 can be developed independently. Task 3 uses both; Task 4 joins the transaction flow; Task 5 integrates packaging/tmux; Task 6 validates and documents the complete feature. Prefer one implementer through the dependent deployment tasks, with independent review at the end. Parallelizing shared mutation code would add coordination without useful isolation.

---

### Task 1: Consumer flake, rooted executor and generation identity

**Files:** Modify `flake.nix`, `nix/lib/mk-home.nix`, `nix/lib/deployment-manifest.nix`; create the three consumer template files and `nix/tests/test_update_identity.py`; extend `nix/tests/test_migration_transaction.py` and `nix/checks/files.nix`.

**Interfaces:**
- Export `lib.mkDotfilesExecutor { system; flakeSource; }` returning the current launcher derivation. Keep `lib.mkDotfilesApp` unchanged for callers.
- Add `deploymentIdentity ? null` to `mkHome`. Non-null identity: `{ schema = 1; release = { repository; releaseId; version; commit; }; consumerSource; profile; }`.
- Manifest gains optional `deploymentIdentity`; old manifests and owner schema do not change.
- Consumer exports `packages.SYSTEM.dotfiles-executor`, `apps.SYSTEM.dotfiles`, and its named home configuration. Assert receipt commit equals actual `dotfiles.rev`.

- [ ] Write failing identity/evaluation assertions:
  ```python
  self.assertNotEqual(generation_a, generation_b)  # same files, different release
  self.assertEqual(managed_targets_a, managed_targets_b)
  self.assertEqual(path_evaluated_identity, git_evaluated_identity)
  ```
  Test names: `test_release_identity_changes_generation_without_home_target_changes`, `test_packaged_path_evaluation_preserves_identity`, `test_receipt_revision_must_match_input`. Extend existing recovery fixture with a journal lacking identity.
- [ ] Run `python3 -B -m unittest discover -v -s nix/tests -p test_update_identity.py`; expect missing implementation to fail. Nix-level assertions run through the existing files check, not mocked evaluation.
- [ ] Extract the executor factory without changing its runtime. Bind identity through one `pkgs.writeText` file in `home.extraDependencies`, referenced by the manifest. Use immutable consumer source, not `self.rev`; exclude generated outputs from identity.
- [ ] Provide strict one-input consumer template and explicit adoption instructions beside the Nix setup docs. Preserve host modules and stateVersion. Do not automate rewriting an existing host declaration.
- [ ] Run identity tests and existing migration/entrypoint suites. With pinned Nix, evaluate all four target outputs and build the current-system files check; confirm old check profiles still evaluate and public activation still rejects them.
- [ ] Commit: `feat(nix): separate host configuration from release identity`.

### Task 2: Safe local state and bounded release discovery

**Files:** Create `nix/update/{__init__.py,state.py,releases.py}`, `nix/tests/test_update_state.py`, `nix/tests/test_update_releases.py`.

**Interfaces:**
- `state.open_state(home: Path, *, create: bool) -> Path`: fixed safe root; create only for explicitly configured operation.
- `state.lock(root: Path, *, blocking: bool)`: context manager around a retained advisory lock file; yields a boolean acquisition result, false on nonblocking contention.
- `state.read_json(path: Path) -> dict`, `state.write_json(path: Path, value: dict) -> None`: bounded regular-file reads and atomic private writes; strict per-record schema validated by consumers.
- `releases.parse_release(payload: dict, commit: str) -> dict`: validated release record from the spec.
- `releases.check(root: Path, *, force: bool = False) -> dict | None`: returns last valid release or none; caller holds updater lock. Updates attempt/cache/backoff; never invokes Git/Nix.
- Cache schema 1: `lastAttempt`, `lastSuccess`, `nextAttempt`, `rateLimitUntil`, `etag`, `release`. Preserve known release identity across transient errors.

- [ ] Write failing tests with patched clock and local fake HTTPS responses for stable version comparison, no releases (404), draft/prerelease rejection, lightweight/annotated tags, changed tag identity, 304, 403/429 backoff, oversized/invalid JSON, timeout, clock regression and unsafe state files:
  ```python
  self.assertEqual(request_count_after_two_background_checks, 1)
  self.assertEqual(cache_after_timeout["release"], last_good_release)
  self.assertGreaterEqual(cache_after_rate_limit["nextAttempt"], server_retry_time)
  self.assertEqual(subprocess_calls, [])  # metadata check cannot install/build
  ```
- [ ] Run `python3 -B -m unittest discover -v -s nix/tests -p 'test_update_state.py'` and the same command with `test_update_releases.py`; confirm the new behavior fails.
- [ ] Implement using stdlib `urllib.request`, `json`, `time`, `fcntl` and existing ownership validation patterns. Limit to fixed GitHub endpoints, deadline and body bounds. Use ETag only for the latest-release endpoint; retain the validated release record on 304, but resolve its tag afresh for identity validation on every due check.
- [ ] Persist attempt before requests; on clock regression rebase the daily window to now plus 86,400 seconds and keep `rateLimitUntil`. Explicit checks bypass the daily window only. Reject filesystem corruption; a malformed cache becomes a reported unknown status and a bounded retry, never installed-version evidence.
- [ ] Re-run both suites; concurrent processes must perform one due background check. Confirm cancellation releases the advisory lock without deleting recovery records.
- [ ] Commit: `feat(updates): cache bounded stable-release checks`.

### Task 3: Prepare an exact consumer candidate

**Files:** Create `nix/update/deployment.py`, `nix/tests/test_update_candidate.py`, `nix/tests/update-lock.nix`; modify `.config/dotfiles/bootstrap-nix` and `nix/tests/test_entrypoint.py`; add a corresponding check to `flake.nix`.

**Interfaces:**
- `deployment.prepare(source_root: Path, profile: str, release: dict, state_root: Path) -> dict`.
- Candidate schema 1: `sourceRoot` (retained clone), `sourceCommit`, `profile`, `release`, `executor` (resolved rooted launcher), `rootLink`, plus `transactionId`, `planPath`, `planSha256`, `manifestFingerprint` and `callerPath` after preview. Candidate layout is `candidates/ID/{source,executor,review.json,recovery.json}`; rootLink and retained plan sit outside the cloned source.
- Use Task 1's `#dotfiles-executor`; original source and registered configuration remain unchanged.
- Extract `validate_source(source_root: Path) -> tuple[Path, str, dict[str, str]]` inside existing `bootstrap-nix`: canonical root, full commit and sanitized environment. Its CLI calls that function; package the same file as `bootstrap_nix.py` in libexec for the updater. Preserve current validation and entrypoint behavior; do not silently invoke ambient source.

- [ ] Write failing tests: clean source preserved, dirty/shallow/submodule source refused, unsafe candidate path refused, Git hooks/config not copied, host file hash map unchanged, receipt/lock mismatch refused, executor rooted before preview.
  ```python
  self.assertEqual(original_head_after, original_head_before)
  self.assertEqual(candidate_host_hashes, source_host_hashes)
  self.assertEqual(changed_tracked_paths, {"flake.lock", "dotfiles-release.json"})
  self.assertEqual(candidate["release"]["commit"], resolved_dotfiles_commit)
  ```
  Add a pinned-Nix fixture with local input repositories, including a transitive pinned dependency; prove exact override persists through later `--no-update-lock-file` evaluation. This must exercise real Nix, not only command arguments.
- [ ] Run `python3 -B -m unittest discover -v -s nix/tests -p test_update_candidate.py`; expect preparation assertions to fail before implementation.
- [ ] Reuse the extracted validator; clone exact committed source privately, sanitize Git environment and disable hooks/signing for generated commits. Reject unsupported consumer input graphs; apply only the targeted Nix update command from the spec. Validate graph/receipt and commit only allowed paths.
- [ ] Build/root the candidate executor before preview. Preserve candidate source and root on errors; do not modify the user's branch or copy user Git config into it.
- [ ] Run candidate tests and `nix build --no-update-lock-file .#checks.x86_64-linux.update-lock` on a suitable disposable Linux environment. The fixture must verify scoped lock changes, subsequent immutable evaluation, retained executor realization and all relevant path/space quoting. If the pinned CLI differs, revise the exact command and regression together; do not edit lock internals.
- [ ] Commit: `feat(updates): prepare pinned host-preserving candidates`.

### Task 4: Confirmed install, truthful status and rollback

**Files:** Create `nix/update/cli.py`, `nix/tests/test_update_cli.py`; extend `deployment.py`, `test_update_identity.py`, existing `nix/migration/{plan,transaction,prerequisites}.py` and `nix/tests/test_migration_{plan,transaction,prerequisites}.py`.

**Interfaces:**
- `cli.main(argv: list[str] | None = None) -> int` implements the command table in the spec.
- `deployment.read_installed(home: Path) -> dict`: `state` is unmanaged/unversioned/installed/pending/inconsistent; includes `generation` and `release` where proven, and `retained` entries with generation path and optional release so rollback targets are discoverable.
- `deployment.install(state_root: Path) -> int`, `deployment.rollback(state_root: Path, generation: str) -> int`: use the held updater lock and existing migration executor, with interactive default-no confirmation.
- Register configuration schema 1: canonical `sourceRoot`, validated `profile`; validate real current user/home/system through existing migration checks.
- Provider transition records bind command, canonical journal-owned profile path, exact prior provider and reviewed new provider. `plan.inspect`, `transaction.verify_resumed_native` and native observation reconciliation must consume the same proven transition; no PATH filtering or blanket drift allowance.
- Reuse `migration.model.read_owner`, `transaction.Journal`, and `Runtime.selected_generation` for status. Package these existing modules with the helper; do not invent a parallel ownership parser.

- [ ] Write failing end-to-end command tests for declined/EOF/non-TTY confirmation, conflicts, source changes during review, changed release identity, Latest moving during review, prior pending recovery and failed activation:
  ```python
  self.assertEqual(apply_calls_after_decline, [])
  self.assertEqual(applied_release, reviewed_release)  # never substitute new Latest
  self.assertEqual(status_after_failed_apply["state"], "pending")
  self.assertEqual(status_after_rollback["release"], release_a)
  ```
  Exercise a real provider upgrade, including uv: the canonical owned profile moves from the exact old provider to the reviewed new one; pre-activation retry, post-activation retry and native query evidence remain correct. Unrelated shadows and old direct-store PATH entries still fail with guidance. Exercise A→B→rollback A with old journals, same-files releases, manual profile drift, crash before/after owner publication and missing executor roots. Add `test_interrupted_apply_recovers_after_review_file_removal`: remove the temporary plan, invoke recovery from a different packaged helper, and assert the retained executor/plan/caller PATH are used without network.
- [ ] Run `python3 -B -m unittest discover -v -s nix/tests -p test_update_cli.py` and targeted added migration tests; confirm new cases fail.
- [ ] First extend preview and resumed/native verification for the narrowly proven owned-provider transition, with no change to foreign-shadow or native-environment checks. Then implement configure/status/check and install orchestration: validate registered source, prepare candidate, create private review directory outside HOME, plan with rooted executor, show reviewed data, retain exact reviewed plan bytes under candidate state, atomically record the full candidate→transaction association before mutation, ask confirmation, revalidate exact release, apply with unchanged original caller PATH passed into the candidate executor. Keep the resulting candidate runtime PATH identical between plan/apply/recovery.
- [ ] Never publish an installed receipt independently. Read selected-generation identity from existing ownership/journal evidence and actual profile selector; treat interrupted or inconsistent state explicitly. Keep cache fields out of the ownership file.
- [ ] Implement offline rollback through the retained active transaction executor. On interruption retain original plan/source/executor and print exact existing recovery commands with shell-safe quoting and recorded caller PATH. Verify the retained plan hash and journal agreement; never generate a new preview to resume an interrupted transaction. Missing evidence stops mutation.
- [ ] Re-run updater and migration suites. Verify status itself makes no network request or Nix build, and rollback needs no API access. Verify old `bootstrap-nix` plan/apply/recovery interface remains intact.
- [ ] Commit: `feat(updates): confirm activation and preserve recovery provenance`.

### Task 5: Package the helper and surface cached tmux notices

**Files:** Create `nix/update/package.nix`; modify `nix/packages.nix`, existing `.config/tmux/conf/status.conf`, `nix/tests/test_terminal.py`, `nix/tests/test_update_cli.py`; expose the helper through `flake.nix` package/app outputs for initial setup.

**Interfaces:**
- Its outer launcher captures original caller PATH before runtimeInputs are prepended; candidate invocation restores that captured value rather than inheriting old helper store paths.
- Package installs `bin/dotfiles-update`, updater modules, existing migration modules and the extracted libexec `bootstrap_nix.py`; pinned Python/Git/Nix runtime only.
- Add helper to inventory packages and commandRequirements using a harmless `--version` probe. This also makes it reachable through `nix/services/tmux.nix`'s existing inventory-derived PATH.
- `status --tmux` prints/flushes cached safe badge before any bounded HTTP work, takes a nonblocking updater lock, and emits updated badge if appropriate. Empty output for missing configuration/native ownership.
- Tmux checks helper availability and attached-client state; existing asynchronous `#()` owns job lifecycle.

- [ ] Extend existing terminal fixture and CLI tests: absent helper/config, fast cached first line despite blocked fake fetch, concurrent clients, long invalid API strings/control characters, widths 60/80/120, copy/resize/prefix modes, existing Neovim indicators and stopped tmux clients.
  ```python
  self.assertEqual(first_line_before_http_unblocks, "update v1.2.3")
  self.assertEqual(network_calls_for_native_home, [])
  self.assertEqual(normalized_targets_before, normalized_targets_after)
  ```
  Add a migration regression: writing cache inside a preexisting updater directory preserves preview evidence; creating that directory after preview causes the existing stale-plan refusal.
- [ ] Run added CLI tests and current-system terminal check; confirm failures before wiring the status segment.
- [ ] Implement package/inventory integration and one compact update segment in the existing status row. Preserve native Git wrapper semantics and current theme/state cues. Use validated local badge strings only.
- [ ] Run `nix build --no-update-lock-file .#checks.x86_64-linux.terminal .#checks.x86_64-linux.files` in the disposable Linux environment, plus updater CLI tests. Confirm helper executable/provider and service PATH, no added managed targets, and cached display does not wait for HTTP.
- [ ] Commit: `feat(tmux): show cached Nix release notices`.

### Task 6: Complete integration evidence and release/adoption instructions

**Files:** Modify `.github/workflows/nix-source-tests.yml`, `nix/checks/migration.nix`, `nix/tests/migration-vm.nix` only as needed to reuse its isolated fixture; `README.md`, `nix/README.md`, and plan checkboxes/evidence.

**Interfaces:** Existing isolated source-suite environment and disposable migration harness. No production activation, GitHub release workflow, external publication or live state writes.

- [ ] Add `python3 -B -m unittest discover -v -s nix/tests -p "test_update_*.py"` to isolated source CI and corresponding Nix source check with its actual fixture dependencies. Keep real Nix lock tests separate from mocked/source tests; no skipped integration check may be described as passing.
- [ ] Run all existing source checks plus updater suites once after final changes. Run current-system Nix files/terminal/update-lock checks and the existing disposable Linux integration extended for real release A→B→rollback A including changed provider derivations and uv, refusal on local drift and interruption recovery.
- [ ] Evaluate all four declared target configurations. Record runtime evidence separately: Ubuntu x86_64 integration does not verify native macOS, ARM Linux, native desktop prerequisites or other Linux distributions.
- [ ] Document one-time consumer adoption, configure/check/install/rollback, tmux-only background scope, network/cache behavior, unversioned state, target-set limitations and retained recovery commands. Keep native bootstrap available and current experimental labels accurate.
- [ ] Add the manual release runbook: tested exact main commit, immutable-releases setting, verified stable tag, draft notes, explicit publication/Latest. Include `gh release create --verify-tag --draft`; do not execute publication or repository-setting commands.
- [ ] Perform whole-branch review against the spec, especially candidate trust boundaries, exact confirmation binding, old-journal compatibility and unchanged target inventory. Fix material findings and rerun affected checks only.
- [ ] Commit: `docs(updates): document release adoption and verified recovery`. Include the design/plan in the eventual implementation PR; no plan-only PR.

## Planning self-review and handoff

Coverage maps as follows: host preservation/executor/identity → Task 1; discovery/state/offline behavior → Task 2; immutable candidate → Task 3; confirmation/status/recovery → Task 4; package/notification/no target growth → Task 5; platform evidence/runbook/CI → Task 6.

The original planning pass changed no product code or runtime state. The approved implementation now uses an isolated retained Nix builder; the evidence below supersedes the planning-only status. No live-home activation, release publication or repository-setting change is authorized by this implementation task.

Execution: the coordinator owns coupled candidate/CLI integration; delegated tasks cover identity, release/state checks, owned-provider transitions, packaging and independent reviews. The user approved implementation before these tasks began. The design and plan stay with the implementation branch.


## Implementation evidence — 2026-10-19

- Tracking: coordinator [ISQ-486](https://linear.app/isqrd/issue/ISQ-486); foundations ISQ-487/488/489; packaging ISQ-492; real lock fixture ISQ-493; disposable Linux integration ISQ-494; reviews ISQ-495/496.
- Isolated source run: 211 tests, 19 skips, no failures; the skips are recorded unavailable Nix/prepared-native cases. Later affected tests are rerun after review fixes. Native bootstrap: all 561 regressions pass, with its source tree unchanged.
- Real identity suite: 6 tests pass. Release identity changes the generation without changing targets or stateVersion; Git/path evaluation agrees; the rooted executor retains consumer, dotfiles, nixpkgs and Home Manager evaluation sources.
- Real lock fixture passes with repository-pinned Nix 2.34.7 and builder Nix 2.35.2. It proves exact targeted and transitive revisions, untouched original/unrelated inputs, paths with spaces, immutable reevaluation and executable/source GC roots. Nix 2.35’s cold metadata exposes an unmaterialized source path: preparation now consumes the returned lock graph.
- Linux files and terminal checks build; all four platform manifests/package derivations evaluate. Actual attached tmux tests cover cached output before HTTP completes, widths, missing/malformed helper output, editor/keytable cues and detached clients. The full package contract caught a helper version-format mismatch, now corrected and awaiting its build rerun.
- Review fixes include dependency-node semantics, realized executor validation, interrupted rollback instructions, desktop/SSH evidence preservation, and retained evaluation-source closure. State/transport review additionally covers truncated HTTP responses and restrictive umask handling.
- The Linux release integration remains a required gate: real uv 0.11.21 → 0.11.22 → rollback, native runtime preservation and interrupted install recovery. It substitutes remote discovery and candidate preparation with immutable offline projections; separate real Git/Nix tests cover preparation. Public release transport and native macOS/ARM activation are not claimed by that fixture.

Current local evidence is retained under `/tmp/dotfiles-updates-20261019`; immutable commits and the final gate result will be recorded here before delivery. No cleanup, live adoption, publication, push or merge has run.
