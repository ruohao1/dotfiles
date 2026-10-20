# Self-contained Neovim Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run the existing Neovim configuration independently while preserving optional dotfiles tmux features and installation compatibility.

**Architecture:** Refactor existing modules in place. Native editor status is the default; a bounded, acknowledged tmux publisher may take ownership. Shared helpers remain optional adapters, and a copied Neovim-only test tree proves independence from sibling files.

**Tech Stack:** Lua, Neovim >=0.12, tmux, Python development tests, Nix/Home Manager, existing native bootstrap.

**Spec:** [Neovim boundaries design](../specs/2026-10-20-neovim-boundaries-design.md).

Status: accepted on 2026-10-20; execution and exact validation evidence are tracked in [ISQ-517](https://linear.app/isqrd/issue/ISQ-517).
Tracking: [ISQ-512](https://linear.app/isqrd/issue/ISQ-512) / [ISQ-513](https://linear.app/isqrd/issue/ISQ-513).
Base: `00de4799fbc3c2f10b09fac50def55cdaec1cceb`.
Branch: `agent/nvim-boundaries-20261020`. Keep both planning documents in the implementation PR.

## Global constraints

- Neovim >=0.12 and Linux/macOS remain the supported editor baseline.
- Native tmux support retains its current minimum 3.2; pinned Nix tmux remains unchanged.
- Add, remove and rename no deployed files; preserve exact managed target and mutable-seed sets.
- Preserve native bootstrap, Nix leaf deployment, source provenance and writable `lazy-lock.json`.
- Keep workspace RPC `integrations.tmux_persistence.checkpoint(path)`, pane fields and pin JSON schema 1.
- Background probe/publication deadline: 1000 ms; focused capability cadence: 5000 ms.
- Keep existing plugins, dependency versions, updater ownership and external helper implementations.
- Use private assigned test homes, sockets and pre-provisioned plugin inputs. No live activation or passive package downloads.
- No separate repository, push, release or standalone plan PR is part of planning.

## Review focus

1. Linked panes use their originating session's effective status, never another linked session's default — Tasks 1/2.
2. Exit-zero guarded no-ops, owner replacement and late callbacks cannot hide native status or erase a newer editor — Task 2.
3. Missing helpers, spaces in paths and custom `NVIM_APPNAME` keep core startup usable without repeated failures — Tasks 1/4.
4. Starter visibility, focus/suspend, reload and status-off transitions preserve one usable editor status surface — Task 2.
5. Neovim-only tests must not hide changes to Nix target ownership, canonical assets or writable plugin state — Task 4.

## Execution and ownership

Use four sequential implementation commits, each with focused tests and a review checkpoint. Tasks 2 and 3 share Task 1 interfaces; do not let separate writers edit `config/platform.lua`, `ui/statusline.lua` or their tests concurrently. Root coordinates commits and acceptance.

Recommended execution: one implementer handles the four dependent tasks; an independent reviewer checks the resulting branch and critical status-ownership changes. Source/deployment analysis has already been parallelized. Do not rerun the large migration VM unless implementation changes its actual ownership/schema scope.

Execution adjustment: after Task 1 fixed the common interfaces, Tasks 2 and 3
received disjoint file ownership and ran in parallel. The coordinator owns shared
APIs, runner/documentation changes, integration and final review. No deployed
files are added or moved.

Before implementation, create an exact active Linear writing assignment from this plan and assign private test roots. Preserve this planning branch and old release evidence. A new runtime or builder lease belongs in that assignment; this document alone does not authorize starting retained infrastructure.

## File responsibilities

| Existing file(s) | Planned responsibility |
| --- | --- |
| `.config/nvim/lua/config/platform.lua` | Shared concrete origin/probe parsing and optional helper lookup |
| `lua/navigation/location_pin_context.lua` | Pin context compatibility and guarded session association |
| `lua/integrations/tmux_status.lua` | Bounded capability checks, acknowledged publishing and lifecycle |
| `lua/ui/statusline.lua` | Native/remote row ownership and optional native Git cache |
| `lua/integrations/tmux_persistence.lua`, `lua/navigation/location_pin_store.lua`, `lua/navigation/location_pins.lua` | Optional registrations/actions; existing persistence and pin protocols |
| Existing Neovim `tests/*.lua` | Focused behavior and race regressions |
| `nix/tests/run-focused.py` | Neovim-only source fixture mode, retaining existing integration modes |
| `nix/checks/terminal.nix`, existing files/terminal tests and checker | Connect focused proof to existing Nix/full-stack gates |
| Existing `STARTUP.md`, `LINE-PINS.md`, `nix/README.md` | Explain optional features, opt-out and verification boundaries |

In this table, shortened Lua/test/document paths are relative to `.config/nvim`.

### Task 1: Concrete integration discovery

**Files:** modify `.config/nvim/lua/config/platform.lua`, `.config/nvim/lua/navigation/location_pin_context.lua`, `.config/nvim/lua/navigation/location_pin_store.lua`, `.config/nvim/lua/ui/statusline.lua`; extend existing `tests/platform.lua`, `tests/location_pins.lua`, `tests/statusline.lua`.

**Interfaces:**

- `platform.tmux_origin(environment) -> origin | nil, reason`, where origin has string `socket`, `pid`, `session`, `pane`.
- `platform.tmux_probe_argv(origin) -> string[]`; target explicit socket and originating session.
- `platform.parse_tmux_probe(origin, completed) -> {configured:boolean,status_enabled:boolean} | nil, reason`.
- `platform.dotfiles_helper("git_summary" | "location_pins", nvim_root) -> absolute_path | nil, reason`.
- Preserve pin `resolve()/validate(origin)/remember(origin)`. Resolve/validate share the new parsing while retaining exact identity verification. Consumers that write dotfiles state must also require configured availability.

- [ ] Add failing table-driven cases to `tests/platform.lua`: absent/malformed TMUX, relative socket, wrong pid/session/pane, linked-session status override, marker absent/0/1, disabled status, process error/timeout/malformed output and literal socket paths. Assert malformed/failed probes never return configured availability.
- [ ] Add helper cases to existing tests: absent/non-executable helper returns nil; both known names resolve the expected executable; quoted/space-containing paths are single argv values; unknown names are rejected. Explicitly preserve managed symlink and `DOTFILES_NVIM_ROOT` fixture behavior.
- [ ] Run the focused scripts using the private invocation below. Confirm failures exercise the new behavior rather than missing external tools.
- [ ] Move/reuse identity logic in `platform.lua`; retain pin origin checks. Keep the two known sibling mappings in this optional resolver, with no arbitrary provider discovery.
- [ ] Make native status cache creation conditional on `git_summary` availability. Assert mode/path/diagnostics/cursor still render, no helper process/timer is created when absent, and starter direct-Git tests remain unchanged.
- [ ] Re-run platform/statusline/location-pin and startup-Git tests. Commit `refactor(nvim): make integration discovery explicit`.

### Task 2: Acknowledge status handoff and recover native ownership

**Files:** modify `.config/nvim/lua/integrations/tmux_status.lua`, `.config/nvim/lua/ui/statusline.lua`; extend existing `.config/nvim/tests/statusline.lua` and `.config/nvim/tests/startup.lua`. Update only affected full-stack expectations in `.config/dotfiles/check-terminal-stack`.

**Consumes:** Task 1 origin/probe functions; optional native Git cache.

**Produces:** `tmux_status.setup({pane?,snapshot?,on_available?:function(boolean)}) -> publisher | nil`, retaining `request/start/stop` and adding `refresh()` and `set_focused(boolean)`.

- [ ] Add failing native-row cases: no tmux; ordinary tmux with helpers present but marker absent; failed probe/claim; configured stack awaiting acknowledgment. Each must retain `laststatus=3` unless the starter is visible.
- [ ] Add acknowledgment cases: exact `dotfiles-nvim-status:<owner>` switches to remote; empty/unexpected stdout despite exit zero does not; marker/status/identity change between probe and write prevents handoff.
- [ ] Add owner/race cases: replaced owner returns native without automatic reclaim; uncertain initial publication retries only for absent/own owner; stopped/replaced controller ignores delayed success; cleanup never deletes another owner's options.
- [ ] Add deterministic timer/event cases: one in-flight operation; 75 ms publication debounce retained; 5000 ms focused recheck and 1000 ms controller deadline. Even a process ignoring termination must trigger native fallback at expiry, with its late result ignored and no replacement process started until it is reaped. Pause on focus loss, immediate native/recheck on focus gain; suspend withdraws publication; resume revalidates; stop closes all handles. Repeated setup/shutdown remains safe.
- [ ] Add starter/status cases: marker 1→0→1, effective originating-session status off/on, linked sessions with different overrides, and starter visible through every transition. Native Git polling pauses remotely and resumes only when needed.
- [ ] Run the focused statusline/startup scripts and confirm the expected RED cases.
- [ ] Implement acknowledged guarded writes and availability callbacks in the existing publisher. Recheck live capability/identity in the write path, emit only fixed acknowledgments, retain sanitization and owner guards, and use explicit socket routing.
- [ ] Replace `inside_tmux` row ownership with availability state. Keep native render behavior and starter APIs; add the narrow opt-out `vim.g.dotfiles_tmux_integration=false`. Keep standard clipboard and smart-splits behavior independent.
- [ ] Run focused GREEN tests, then attached private ordinary/configured tmux checks on available supported versions, including the pinned version. Preserve exact status-job auditing; do not weaken checks to accept altered commands. Commit `fix(nvim): retain native status until tmux handoff succeeds`.

### Task 3: Make persistence and pins optional without changing their protocols

**Files:** modify `.config/nvim/lua/integrations/tmux_persistence.lua`, `.config/nvim/lua/navigation/location_pin_context.lua`, `.config/nvim/lua/navigation/location_pin_store.lua`, `.config/nvim/lua/navigation/location_pins.lua`; extend existing `tests/tmux_persistence.lua`, `tests/location_pins.lua`, `tests/location_pin_picker.lua`; adjust affected `.config/tmux/tests/workspace-restore.sh` fixtures only as needed.

**Consumes:** Task 1 configured origin and helper availability; Task 2 opt-out policy.

**Produces:** unchanged persistence `checkpoint(path) -> "ok" | "error:..."` and pin `list/add/delete/clear` behavior when enabled.

- [ ] Add failing cases proving generic tmux, opt-out and invalid/replaced origin cause no persistence registration or `@dotfiles_line_pin_session` write. A missing pin helper must prevent pin association writes without disabling persistence. Cover setup and each user pin action, with informative action-level failure.
- [ ] Retain and extend configured cases: status disabled still permits persistence/pins; exact socket routing; stable pin IDs/schema; changed session/server refusal; hostile literal paths; modified-buffer protection; guarded owner cleanup.
- [ ] Add persistence cases for repeated setup/shutdown, failed registration, preserved checkpoint staging-path security and unchanged session options. Do not introduce automatic persistence hot-reload.
- [ ] Run focused RED cases, then gate registration and pin `remember()` before writes. Reuse existing helper/storage implementations and public commands/mappings.
- [ ] Re-run focused GREEN tests and the real private workspace-restore/location-pins suites. Verify mixed old/new source compatibility because RPC/module paths, marker and pane fields are unchanged. Commit `refactor(nvim): gate optional workspace and pin integrations`.

### Task 4: Prove independence and preserve deployment

**Files:** modify `nix/tests/run-focused.py`, `nix/checks/terminal.nix`, existing `nix/tests/test_files.py` and `nix/tests/test_terminal.py` where needed; optionally add development-only `nix/tests/test_editor_runner.py`. Extend existing Neovim test files and existing `.config/nvim/STARTUP.md`, `.config/nvim/LINE-PINS.md`, `nix/README.md`. No new file under `.config/nvim`.

**Interfaces:**

- Add `--suite editor-standalone` to `run-focused.py`, retaining existing `editor-sources`, `terminal` and `bootstrap` behavior.
- Existing `--source-root` remains the complete source checkout; the new mode copies only its `.config/nvim` tree into a private fixture before invoking tests.
- Each child receives an isolated HOME/XDG/TMP/log environment and the copied Neovim root. No `dotfiles` or `tmux` sibling directory exists.

- [ ] Add runner regressions: reject preexisting/overlapping fixture roots; make a copied Neovim-only tree; scrub inherited TMUX/NVIM_APPNAME variables; preserve the existing source fingerprint; fail on child exit/log/marker errors. Copy regular files into the private fixture; do not retain symlinks that escape to source siblings.
- [ ] Curate the standalone source suite from existing tests. Include platform, statusline, persistence, startup Git/layout and unavailable-pin behavior; separate real tmux integration tests. Add an explicit standalone mode within existing pin tests where necessary, retaining their full configured cases in `editor-sources`. Keep `editing.lua`'s full-stack checker assertions in the configured suite. Do not silently skip required cases because their dependencies are absent.
- [ ] Run RED/GREEN for the runner, then add the standalone suite to the existing pinned terminal Nix check. Retain full-tree/source and real tmux suites as separate evidence.
- [ ] Exercise actual configured startup with pre-provisioned pinned plugins in three private homes: Neovim-only tree; generic tmux with a copied Neovim tree; complete dotfiles tmux. Include `NVIM_APPNAME` relocation, helper absence and the Task 2 lifecycle cases. Prevent downloads during these checks; record missing prerequisites instead of changing the host.
- [ ] Compare base/candidate evaluated managed file and mutable-seed target sets on all four systems. Require exact equality, unchanged service target identity and unchanged lazy-lock seed policy. Run files/terminal checks and affected native bootstrap regressions.
- [ ] Update existing user docs: core requirements, optional Git segment/pins, ordinary tmux behavior, marker/opt-out contract, no new updater, and current validation limits.
- [ ] Run independent code review and the existing source CI suite; distinguish Python-only CI from editor/runtime results. Commit `test(nvim): verify standalone configuration and deployment compatibility`.

## Verification commands and pass criteria

All commands below are implementation gates, not commands run during planning. Assign previously absent, private test roots in the active implementation issue before execution. Use selected Neovim >=0.12 and pinned tools without installing into the live host.

The existing runner establishes the safe focused child environment:

```sh
python3 -B nix/tests/run-focused.py \
  --suite editor-sources --source-root "$PWD" \
  --fixture-root "$NVIM_BOUNDARY_SOURCE_ROOT"
```

For RED/GREEN, invoke the affected existing script with that same private HOME/XDG/TMP/log environment and `DOTFILES_NVIM_ROOT`:

```sh
nvim --clean --headless -u NONE -i NONE \
  -c 'lua vim.opt.runtimepath:prepend(vim.env.DOTFILES_NVIM_ROOT)' \
  -l "$DOTFILES_NVIM_ROOT/tests/statusline.lua"
```

Run `platform.lua`, `startup.lua`, `startup_git.lua`, `tmux_persistence.lua`, `location_pins.lua` and `location_pin_picker.lua` as appropriate. Success requires exit zero, the script's expected success marker, no error output and an empty Neovim log. The direct child is not a substitute for isolating its environment.

After Task 4:

```sh
python3 -B nix/tests/run-focused.py \
  --suite editor-standalone --source-root "$PWD" \
  --fixture-root "$NVIM_BOUNDARY_STANDALONE_ROOT"
python3 -B nix/tests/run-focused.py \
  --suite terminal --source-root "$PWD" \
  --fixture-root "$NVIM_BOUNDARY_TMUX_ROOT"
nix build --no-update-lock-file --no-link \
  .#checks.x86_64-linux.files .#checks.x86_64-linux.terminal
```

Require all selected cases to pass, no source mutation and no remaining owned tmux/editor processes. Source-only and configured-plugin results must be reported separately. Run Nix builds only in an explicitly assigned build environment; planning does not authorize restarting the retained builder.

For `x86_64-linux`, `aarch64-linux`, `x86_64-darwin` and `aarch64-darwin`, evaluate this projection from immutable base and candidate:

```sh
nix eval --no-update-lock-file --json \
  ".#homeConfigurations.check-$system.deploymentManifest" \
  --apply 'm: {
    files = builtins.map (f: f.target) m.files;
    mutableSeeds = builtins.map (f: f.target) m.mutableSeeds;
  }'
```

Compare normalized sets exactly, not source store paths (which legitimately change). Existing files checks must retain the only mutable seed `.config/nvim/lazy-lock.json`, absent-only seeding, writable directories and canonical runner/RPC paths. Inventory differences stop this phase; do not relax updater ownership checks.

## Review and handoff

Self-review the implementation against the behavior table and five review-focus cases; then obtain an independent review of the exact final candidate. Record actual tool versions, case results/skips, private fixture cleanup and platform limits.

No repository split is required for acceptance. After the core and integration contracts are proven, a later extraction proposal can address independent versioning, native bootstrap sourcing, pinned Nix input and an explicit managed-target migration if needed.
