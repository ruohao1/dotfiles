# Nix dotfiles migration implementation plan

This is the original [Linear implementation plan](https://linear.app/isqrd/document/nix-dotfiles-migration-implementation-plan-f1b9c35f9021), retained with the implementation. Links and machine-specific workspace paths have been normalized for repository readers; the technical steps below remain historical.

## Delivery status — 2026-10-16

The reviewed implementation ends at `cc2825595284c1a2c4f50e86b8f01bcf7993aece`. Tasks 1–5 and the Task 6 entrypoint are implemented; Task 6's full native-platform acceptance remains open. The original unchecked steps below must not be read as a fresh execution assignment.

| Plan task | Implementation commits |
| --- | --- |
| 1. Locked packages and explicit profiles | `fa03c51` |
| 2. Managed files and editor source validation | `d6d8cd7`, `3a65992` |
| 3. tmux helpers and services | `879358c`, `3ffb0bd` |
| 4. Ownership guard and migration preview | `7d5814b`, `db93bd1` |
| 5. Migration transactions and recovery | `49a64cc`, `9c10bf0` |
| 6. Entrypoint, documentation and validation | `054ddce`, `cc28255`; broader native acceptance pending |

These identifiers refer to the retained original development history. The delivery snapshot preserves its files; publishing a snapshot does not recreate those commit objects on GitHub.

The [current validation record](../../../../nix/validation/2026-10-16-ubuntu-smoke.md) records 119 passing isolated source tests (12 skipped) and the focused Ubuntu direct Home Manager activation smoke test. The Nix route remains experimental. Actual host installation is deferred, and no live dotfiles have been activated.

## Original plan

**Goal:** Build and validate portable Nix and Home Manager profiles, then transfer selected existing dotfiles without losing configuration or recovery state.

**Architecture:** Keep application sources in their existing repository layout. A pinned flake supplies packages, explicit host profiles, Home Manager generations, and a deployment manifest. A small migration command owns the initial handoff and recovery; Home Manager owns normal package/configuration generations.

**Tech stack:** Nix flakes, Home Manager, existing POSIX shell/Lua, and Python standard-library migration tests.

**Spec:** [User-approved design](<https://linear.app/isqrd/document/nix-dotfiles-migration-design-9bb567a20305>).

**Source baseline:** `d61ecaedc808caba4586c9e48704dcfac1002785`. Existing Ghostty and Neovim lockfile changes remain outside this baseline and must survive migration.

**Historical status:** Revision 1 was captured before execution. Its unchecked boxes are retained as the original plan, not a current completion ledger.

**Planning scope:** [ISQ-310](https://linear.app/isqrd/issue/ISQ-310/plan-the-nix-and-home-manager-migration) permits Linear documents and read-only source inspection. This plan does not authorize repository writes, installations, services, or live activation. Publish implementation assignments before execution; do not implement in the home worktree.

## Global constraints

* Initial targets: Ubuntu/Debian, Arch, and macOS. Build targets: `x86_64-linux`, `aarch64-linux`, `x86_64-darwin`, `aarch64-darwin`. Evaluation, native builds, and native activation are different evidence.
* Pin `nixpkgs-unstable` and Home Manager `master` in `flake.lock`; Home Manager follows the same nixpkgs. Choose exact revisions during the package task and record them; no automatic updates during activation.
* Minimum versions: Neovim 0.12.0, StyLua 2.5.0, tree-sitter CLI 0.26.1, uv 0.11.6, herdr 0.8.0, Taplo 0.10.0, and tmux 3.7.
* Preserve Bash LS 5.6.0, Pyright 1.1.411, vscode-langservers-extracted 4.10.0, and YAML LS 1.24.0 initially. The committed dependency lock also requires Node >=22.
* Preserve the external uv tool environment with VisiData 3.4, pyarrow 25.0.0, and duckdb 1.5.5. Preserve the frozen notebook uv project and Python `>=3.10,<3.15`.
* Native desktop applications, window managers, clipboard services, OS preferences, permissions, and `.codex/hooks.json` remain outside the initial transfer. Ghostty and its SpaceMono Nerd Font remain native prerequisites. Do not reuse ordinary bootstrap as a desktop-only installer after transfer.
* Linux data queries retain a root-owned, executable, non-group/world-writable Bubblewrap and a successful real namespace probe; keep GNU timeout available to the checker's `command -p` lookup. Declare these as Linux native prerequisites. Preserve the existing unsupported result for Darwin data queries; do not weaken sandbox checks for single-user Nix.
* Preserve writable `lazy-lock.json`, editor data/cache, tmux state, `~/.cfg`, bootstrap journals, unrelated local files, and native packages. No unconditional Home Manager `force`.
* Keep the tmux helper directory and filtered Neovim runtime as complete source trees. Individual deployed files link into those trees so sibling lookup and source containment remain meaningful.
* No assumed username or home directory. Check profiles use explicit disposable identities; a real profile is declared before deployment. Shell/Git identity files are not replaced.
* Preserve `home.stateVersion` after initialization. Package versions and host paths are recorded per profile.

## Review focus

1. Mixed real directories and store-linked files must work without weakening runner/source containment.
2. A writable lockfile, local extensions, and post-migration edits must survive repeated activation and reversal.
3. Legacy apply, scoped Taplo installation, and rollback must not race with or overwrite Home Manager ownership.
4. Supervisor PATH must select Nix tools in production, including when old native tools remain installed.
5. Interrupted activation and partially successful service-manager commands must retain recoverable state.

These cases are tested in Tasks 2 through 5. No live system is used as a test fixture.

## Assignment and source layout

Create one implementation issue per task below under [ISQ-309](https://linear.app/isqrd/issue/ISQ-309/migrate-dotfiles-to-nix-home-manager), after plan approval. Each issue pins its actual starting commit, branch, registered worktree, exact paths, checks, private test locations, and permitted external writes. Use sequential branches named `agent/nix-01-profiles` through `agent/nix-06-delivery`; the assigned worktree is a separate registered checkout under a dedicated worktree directory. These are proposed names, not created resources.

Task 1 starts from the recorded baseline. Later tasks start from the reviewed predecessor commit. Record those actual hashes when assigning them rather than inventing future hashes. A specification-review child gates an implementation revision; quality-review children target immutable candidates before integration. Shared paths such as the terminal checker and flake remain under one writer.

| Task | Deliverable | Depends on |
| -- | -- | -- |
| 1 | Locked packages and buildable check profiles | Approved plan and build-environment lease |
| 2 | Home Manager file deployment and Neovim compatibility | 1 |
| 3 | Nix-compatible tmux helpers and user service | 1, 2 |
| 4 | Shared ownership guard and read-only migration preview | 2, 3 |
| 5 | Explicit activation, generation rollback, and reverse handoff | 4 |
| 6 | Native platform evidence and installation entrypoint | 5 |

All paths below are relative to the repository root, which contains `.config/`, `.local/`, and `Library/`.

## Task 1 — Locked packages and buildable check profiles

**Files:** Create `flake.nix`, `flake.lock`, `nix/lib/mk-home.nix`, `nix/hosts.nix`, `nix/home.nix`, `nix/packages.nix`, `nix/platforms/linux.nix`, `nix/platforms/darwin.nix`, `nix/checks/packages.nix`, `nix/tests/check-packages.py`, and `nix/README.md`. Add custom derivations under `nix/pkgs/` only for the concrete required tools not supplied at compatible versions by the selected lock.

**Interfaces:**

- `mkHome { profile, system, username, homeDirectory, modules ? [] }` returns a Home Manager configuration; every identity value is explicit.
- `homeConfigurations."check-<system>"` uses username `dotfiles`, with `/home/dotfiles` on Linux or `/Users/dotfiles` on Darwin. These are test identities, not activation defaults.
- `nix/packages.nix` returns `{ packages, commandRequirements, nativeDependencies }`. Every required command has exactly one declared package provider or explicit native prerequisite; the coverage check rejects missing providers.
- `checks.<system>.packages` checks actual capabilities/version requirements for Nix-provided commands and complete inventory coverage. Native prerequisites are checked on the target host during preview and platform validation, never inferred from the build sandbox. `checks.<system>.home` builds the matching check generation.
- [ ] Write package checks for all minimum versions and exact npm versions. Require Git, Python, Neovim, tmux, fzf, ripgrep, jq, shellcheck, StyLua, tree-sitter, herdr, ImageMagick's `identify` and `convert`, uv, Node >=22, and all six language-server command names. Include `iconv` and the checksum utilities used by tmux helpers. Test stable Taplo's `lsp stdio --help`, not version text alone.
- [ ] On an assigned disposable Nix builder, run `nix build .#checks.x86_64-linux.packages --no-link` before implementation and record failure because the output is absent.
- [ ] Implement explicit hosts and module composition. Use the existing npm manifest/lock to build matching language servers when nixpkgs differs. Record any unavoidable per-platform native prerequisite; essential missing providers fail validation.
- [ ] Resolve and commit real input revisions. Record selected tool versions and native exceptions in `nix/README.md`; never fabricate hashes or silently substitute below-floor packages.
- [ ] Run `nix flake check --all-systems --no-build`, then native `nix build .#checks.x86_64-linux.packages .#checks.x86_64-linux.home --no-link`. Both native builds must pass. Other target evaluations do not count as native builds.
- [ ] Commit the exact Task 1 paths and freeze the candidate for independent review. This is the first working deliverable; no home is activated.

## Task 2 — File deployment and Neovim source compatibility

**Files:** Create `nix/files.nix`, `nix/lib/deployment-manifest.nix`, `nix/checks/files.nix`, `nix/tests/test_files.py`, and `nix/tests/run-focused.py`. Update `nix/home.nix`, `nix/lib/mk-home.nix`, `flake.nix`, `.config/nvim/lua/data_query/tool.lua`, `.config/nvim/tests/data_query_tool.lua`, and the runner-path assertion in `.config/dotfiles/check-terminal-stack`.

**Interfaces:**

- `nix/files.nix { sourceRoot, system }` produces selected file definitions and seed-only files; it is the single source of transferred application paths.
- Each home configuration exposes JSON-serializable `deploymentManifest`: `schema = 1`, `profile`, `system`, `username`, `homeDirectory`, `activationPackage`, `files`, `mutableSeeds`, `profilePaths`, `nativeDependencies`, and `services`.
- File records contain home-relative `target`, absolute immutable `source`, and `executable`. Include evaluated Home Manager file outputs in the inventory. `profilePaths` enumerates absolute package-profile and generation-link paths actually used by the pinned Home Manager implementation for that explicit home. Task 4 fingerprints them and Task 5 journals their mutation. Reject any unlisted activation effect during integration tests.
- Export with `nix eval --json '.#homeConfigurations.check-x86_64-linux.deploymentManifest'`. Task 4 consumes this schema.
- `run-focused.py --suite editor-sources|terminal|bootstrap --source-root PATH --fixture-root PATH` owns a previously absent, issue-assigned test root and runs the existing suites with explicit child environments. Task 2 implements editor-source cases; Tasks 3 and 4 extend the other named suites.
- [ ] Write file-manifest tests asserting that the normal source checkout alone supplies all inputs; targets cannot escape home; platform-specific services do not mix; and excluded desktop/hook/state paths are absent. Ghostty's shared file imports `platform-linux.ghostty` on both platforms, so retain that adapter on Darwin and test the complete import chain. Assert `lazy-lock.json` appears only in `mutableSeeds`.
- [ ] Add Neovim regressions for a real config directory whose Lua module and runner link into one source tree. Require success for that layout, and rejection for a runner in a different source tree, wrong module layout, unreadable file, or directory.
- [ ] Implement the focused runner with the existing Neovim command: `nvim --clean --headless -u NONE -i NONE -c 'lua vim.opt.runtimepath:prepend(vim.env.DOTFILES_NVIM_ROOT)' -l <test-file>`. Give it private config/data/cache/state/runtime/log paths and clear inherited TMUX/NVIM_APPNAME in the child environment. Run the data-query test and record the expected source-containment failure before changing `data_query/tool.lua`.
- [ ] Link selected runtime files from complete source trees. Keep Neovim Lua/LSP files, frozen Python project, runner paths, and tests/guides needed by the existing checker. Include herdr, Ghostty, tmux, `.local/bin/t`, and exact checker helpers/manifests/test dependencies. Keep tmux helper siblings intact; defer their service activation to Task 3.
- [ ] Resolve Neovim's trusted source root from its canonical module location and expected suffix, then enforce runner containment there. Make the terminal checker compare the canonical expected runner instead of the deployed lexical path. Do not accept arbitrary paths merely because they start with `/nix/store`.
- [ ] Seed `lazy-lock.json` only if absent, after Home Manager's write boundary, respecting dry run. Preserve an existing modified lock and unrelated extensions on reactivation. Retain the VisiData uv environment and notebook frozen-sync workflow; record their fresh-install preparation as explicit native runtime prerequisites.
- [ ] Run `nix build .#checks.x86_64-linux.files --no-link` and `python3 nix/tests/run-focused.py --suite editor-sources --source-root "$PWD" --fixture-root "$NIX_TEST_ROOT"`, where the implementation issue assigns NIX_TEST_ROOT. Assert no writes to store sources and no writes outside the private home. Commit and freeze for review.

## Task 3 — tmux helpers and platform services

**Files:** Create `nix/services/tmux.nix`, `nix/checks/terminal.nix`, `nix/tests/test_terminal.py`, and a narrowly scoped `.config/dotfiles/lib/config-source.py` validator. Update `.config/tmux/scripts/workspace`, `.config/tmux/tests/workspace-state.sh`, `.config/tmux/tests/location-pins.sh`, `.config/dotfiles/check-terminal-stack`, `nix/tests/run-focused.py`, `nix/home.nix`, and `flake.nix`. Preserve the existing native service templates as legacy sources.

**Interfaces:**

- `config-source.py --path PATH --expected SOURCE [--executable]` returns 0 only for the expected canonical regular source with required permissions; 1 for invalid assets and 2 for usage. The expected source is generated from the selected immutable profile, not arbitrary user input.
- The service module renders `tmux-workspace.service` on Linux and `dev.ruohao.tmux-workspace` on Darwin, preserving existing restart/stop behavior.
- Package the helper tree together, including `location-pins.jq`. The supervisor and its child tools receive a deterministic Nix-first dependency PATH plus documented native application paths.
- [ ] Add tests for a valid managed helper/source/service link, dangling link, cycle, unexpected target, ownership mismatch, and nonexecutable helper. Keep existing runtime state, snapshot, lock, and `.codex/hooks.json` protections unchanged.
- [ ] Add a production-PATH test with old native executables earlier in the inherited environment. Run without `TMUX_WORKSPACE_TESTING=1` and assert the selected Nix providers are used.
- [ ] Add a deployed-symlink test that invokes workspace location-pin operations, including the sibling helper and jq include. Add a private-socket save/restore test launched through the rendered supervisor environment.
- [ ] Run the new checks and record the existing PATH/symlink/sibling-discovery failures.
- [ ] Implement only the transferred-configuration validation changes and service environment. Keep doctor exit 0/1 and CLI usage exit 2. Keep systemd restart delay 5 seconds and stop timeout 30 seconds; keep launchd label, RunAtLoad, unsuccessful-exit restart, background process, and 5-second throttle.
- [ ] Run `nix build .#checks.x86_64-linux.terminal --no-link` and the focused workspace-state, restore, and location-pins suites through the isolated test runner. A successful doctor alone is insufficient. Commit and freeze for review.

## Task 4 — Ownership guard and migration preview

**Files:** Create `.config/dotfiles/lib/ownership.sh`, `nix/migration/model.py`, `nix/migration/plan.py`, `nix/migration/cli.py`, `nix/tests/test_ownership.py`, `nix/tests/test_migration_plan.py`, and `nix/checks/migration.nix`. Update `.config/dotfiles/bootstrap`, `.config/dotfiles/tests/bootstrap.sh`, `nix/tests/run-focused.py`, and `flake.nix`.

**Interfaces:**

- `apps.<system>.dotfiles` exposes the Python migration CLI with the pinned Home Manager CLI and explicit Nix/runtime dependencies.
- `nix run .#dotfiles -- plan --profile NAME --output FILE` builds/inspects the selected generation, checks providers and file conflicts, and writes a reviewable JSON plan only to FILE. No deployment or service mutation.
- Coordination lives at fixed-home `$HOME/.local/state/dotfiles-ownership`; an ambient change to `XDG_STATE_HOME` cannot bypass it.
- `owner.json` schema 1 records `phase` (transferring/home-manager/recovering), canonical home, transaction ID, manifest fingerprint, selected generation, and journal path. Use an atomic per-home lock shared by both deployers.
- `plan.py` exposes `inspect(manifest, home) -> plan` and `verify_unchanged(plan) -> None`; drift raises a conflict before mutation. Record file type, content/link fingerprint, executable provider, package-profile state, and original service state.
- [ ] Add failing tests that active, transitional, malformed, or symlinked ownership metadata blocks legacy full apply, scoped Taplo apply, and manual rollback with exit 1 before any package/probe/service/journal mutation. Help and nonmutating inspection remain usable.
- [ ] Add concurrency tests: legacy apply and handoff have one lock winner; the loser changes nothing. Test the alternate-XDG-state bypass and unsafe/symlinked parents.
- [ ] Add preview cases for clean and modified files, preserved symlinks, missing sources, home/architecture mismatch, old Taplo artifacts, native prerequisites, and backup-name collision. Output must identify every conflict and preserve inputs byte-for-byte.
- [ ] Implement the early shared guard before bootstrap's scoped-Taplo dispatch, rollback dispatch, and package tracking. Internal rollback rechecks ownership before journal status changes without reacquiring its own held lock.
- [ ] Implement explicit JSON inventory from Task 2 plus current-home evidence. Reject an existing unrelated Home Manager deployment rather than silently adopting it. Resolve real profile identity explicitly; never activate a check profile on the current user.
- [ ] Run `python3 -m unittest discover -s nix/tests -p 'test_ownership.py'`, `python3 -m unittest discover -s nix/tests -p 'test_migration_plan.py'`, and the relevant bootstrap regression suite in the assigned private test root. Commit and freeze for review.

## Task 5 — Activation and both recovery paths

**Files:** Create `nix/migration/transaction.py`, `nix/migration/services.py`, `nix/tests/test_migration_transaction.py`, and `nix/tests/test_migration_services.py`. Update `nix/migration/cli.py`, `nix/migration/model.py`, `nix/checks/migration.nix`, `nix/home.nix`, and `flake.nix`.

**Interfaces:**

- `dotfiles apply --plan FILE` revalidates the exact preview, takes the shared lock, and applies only the recorded generation and destinations.
- `dotfiles rollback --generation GENERATION` selects a retained Home Manager generation while keeping Home Manager ownership.
- `dotfiles restore-legacy --transaction ID` reverses the initial handoff; it never calls old bootstrap rollback.
- All three are exposed through `nix run .#dotfiles -- ...`. Usage exits 2; failed preconditions/recovery exit 1; success exits 0.
- Journal under the ownership directory: original fingerprints, backup paths, mutation intent/completion, previous package-profile generation, and service installed/enabled/active state. Markers/journals must not be symlinks. Retain generation references until recovery completes.
- [ ] Write failure-injection tests for each archive, marker publication, activation step, partial service action, signal, and final verification. Assert recoverable journals and guarded ownership remain after failure; retries are idempotent.
- [ ] Test normal and modified lockfiles, local Ghostty edits, unrelated extensions, conflicting parent directories, and changes between preview and apply. Modified transferred configuration must either be incorporated into the reviewed source/generation or remain an unresolved preview conflict; backing it up alone does not preserve its active behavior. No stale plan may overwrite newer content.
- [ ] Test service stop/unload failures, unavailable managers, and partial systemd/launchd effects. Restoration stops before replacing files if the current supervisor cannot be stopped safely.
- [ ] Implement write-ahead journaling and transitions: publish transferring before overlapping mutations; preserve originals; activate the built generation; verify tools/files/services; publish home-manager last. Preserve partial state for explicit recovery rather than pretending the operation was atomic.
- [ ] Handle Taplo by archiving only the inventoried old `~/.local/bin/taplo` and `~/.local/opt/taplo-0.10.0-<architecture>`. Verify selected Nix Taplo and LSP capability. Retain all other native packages.
- [ ] Implement generation rollback separately from reversal. Reverse handoff archives post-migration edits, restores originals/profile/service state, and releases ownership last. Never delete snapshots, `~/.cfg`, old bootstrap journals, or writable application state.
- [ ] Run `python3 -m unittest discover -s nix/tests -p 'test_migration_*.py'` and `nix build .#checks.x86_64-linux.migration --no-link`. Add real Home Manager activation/reversal in a disposable Linux VM; mocks alone do not establish compatibility. Commit and freeze for review.

## Task 6 — Platform validation and installation entrypoint

**Files:** Create `.config/dotfiles/bootstrap-nix`, `nix/tests/platform-smoke.sh`, and `nix/tests/test_entrypoint.py`. Update `README.md`, `nix/README.md`, `flake.nix`, and `nix/hosts.nix`. Record detailed evidence in a Linear document linked to this implementation task.

**Interfaces:**

- `bootstrap-nix --help` explains Nix prerequisites and the plan/apply workflow. With Nix installed, it delegates to the pinned flake application and propagates its status.
- Installation of Nix uses the official documented route under the task's explicit package/system lease; the entrypoint never performs a silent privileged installation.
- `platform-smoke.sh --profile NAME --fixture-root PATH` runs only in a disposable VM or dedicated test account with an explicitly assigned service-manager scope. A temporary HOME on the live user's service manager is not isolation.
- [ ] Write entrypoint tests for missing Nix, unknown profile, preserved argument quoting, missing runtime prerequisites, and propagation of plan/apply failures. Preview remains distinct from activation. Run `python3 -m unittest discover -s nix/tests -p 'test_entrypoint.py'` and record the missing-entrypoint failure; implement the thin delegating script, then require all cases to pass.
- [ ] Build all four target package/home outputs on matching native builders. Record exact OS, architecture, input lock, command, exit status, and tested generation.
- [ ] Exercise clean install, existing edited configuration, repeated activation, generation rollback, and reverse handoff on Ubuntu, Debian, Arch, and native macOS. Run Linux ARM and Intel/Apple Silicon macOS builds separately; report missing runners as pending evidence, not success.
- [ ] Exercise real terminal/editor/LSP workflows and the Linux namespace/timeout prerequisites. Prepare the VisiData environment with the existing pinned operation `uv tool install --with pyarrow==25.0.0 --with duckdb==1.5.5 --no-config visidata==3.4` only after resolving existing-runtime conflicts. Use `:NotebookBootstrap` for the frozen notebook sync and prepare tree-sitter parsers. Do not introduce network installs into ordinary Home Manager activation.
- [ ] Document adding an explicit real host, shell session-variable integration, native GUI/runtime prerequisites, updates, and recovery. Document that current legacy entrypoints enforce ownership; arbitrary old copies of bootstrap cannot be made safe retroactively.
- [ ] Make the Nix route the README default only when its advertised platform gates pass. Otherwise keep it marked experimental and list the exact verified subset. Native desktop installation remains a separate documented step.
- [ ] Run entrypoint tests, all relevant focused checks, and `git diff --check`; commit and freeze for independent review. Platform gaps keep the corresponding acceptance criteria open.

## Test execution and evidence rules

The test runner creates a private fixture home and data/cache/state directories without changing the process's real HOME variable convention in orchestration scripts. Commands that need a fixture environment run as child processes with an explicit environment map. Use private tmux sockets and command-owned test directories. Service integration tests run in isolated native accounts/VMs, not the active user's user manager.

The Nix checks expose `packages`, `home`, `files`, `terminal`, and `migration` under `checks.<system>`. Task 4 registers the ownership/preview checks in the migration check, which Task 5 extends. Python test modules use standard-library unittest; tests pin observable behavior and failure boundaries instead of copying implementation logic.

Real LSP attachment tests are `bashls.lua`, `jsonls.lua`, `lsp.lua`, `pyright.lua`, `taplo.lua`, and `yamlls.lua`. Each receives its own `DOTFILES_<NAME>_TEST_PARENT` and initially absent direct-child `DOTFILES_<NAME>_TEST_ROOT` (Lua uses LSP); Taplo receives the selected `DOTFILES_TAPLO_EXECUTABLE`. Success requires exit 0, expected success output, no error signatures/logs, and no surviving processes. The full checker requires prepared editor data and desktop dependencies; it is a native integration gate, not a pure package build.

A failed full terminal checker must be diagnosed and recorded. Do not weaken gates, treat known failures as passes, or infer macOS runtime behavior from mocked launchctl calls. No checks have been executed as part of this planning task.

## Deployment gate and completion

After all implementation candidates and reviews pass, create a separately scoped live-activation assignment identifying the actual machine, username/home, source commit, flake lock, built generation, reviewed migration inventory, backup location, and service/package leases. Preview first and preserve current local edits. The existing design approval is not a substitute for that concrete deployment record.

[ISQ-310](https://linear.app/isqrd/issue/ISQ-310/plan-the-nix-and-home-manager-migration) produces this reviewed plan and assignment proposals. [ISQ-309](https://linear.app/isqrd/issue/ISQ-309/migrate-dotfiles-to-nix-home-manager) completes only after its advertised native platform, migration, recovery, and review criteria pass. No plan step removes native packages or deletes retained recovery material.

## Documentation references

The constructor and explicit host model follow [Home Manager's standalone flake setup](<https://nix-community.github.io/home-manager/nix-flakes/standalone.html>). File collision checks and seed mutation must respect [Home Manager activation boundaries](<https://nix-community.github.io/home-manager/options/home-manager/home.html>). Cross-system evaluation and native checks follow the [Nix flake check manual](<https://nix.dev/manual/nix/2.34/command-ref/new-cli/nix3-flake-check>). Pin implementation behavior to the selected input revisions rather than assuming current upstream source remains unchanged.
