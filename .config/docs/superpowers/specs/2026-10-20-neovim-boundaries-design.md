# Self-contained Neovim with optional dotfiles integrations

Status: proposed design for user review; no implementation or runtime validation performed.
Tracking: [ISQ-512](https://linear.app/isqrd/issue/ISQ-512), planning [ISQ-513](https://linear.app/isqrd/issue/ISQ-513).
Base: main `00de4799fbc3c2f10b09fac50def55cdaec1cceb`.
Branch: `agent/nvim-boundaries-20261020`.
Delivery: keep this design and its [implementation plan](../plans/2026-10-20-neovim-boundaries.md) on the feature branch and include both with the implementation PR. No standalone planning PR.

## Intent and success

Make the existing editor usable from its own Neovim directory while retaining the richer experience when the surrounding dotfiles stack is available. The user accepted planning the recommendation to refactor inside dotfiles before considering a separate repository.

The first phase succeeds when:

- A Neovim-only configuration tree starts and retains normal editing, navigation, native status and starter behavior without sibling dotfiles or tmux directories.
- Ordinary tmux does not hide the editor's status or receive dotfiles-specific pane registrations.
- Configured dotfiles tmux still provides shared status, session pins and workspace checkpoint/restore.
- Missing optional helpers produce graceful feature absence, not startup failure or repeated failing subprocesses.
- Native bootstrap, Nix ownership/rollback and the writable plugin lock keep their current contracts.

“Self-contained” describes the configuration and core behavior, not a dependency-free application. Neovim >=0.12, Linux/macOS, installed plugins and feature-specific external tools remain requirements. Existing lazy.nvim first-install behavior is unchanged. Rich Git status, session pins, clipboard history and notebook/data tools may require their documented optional dependencies.

## Approach and alternatives

**Choose an in-place refactor.** Reuse existing modules and tests; make integration availability explicit at the existing calls. Add a Neovim-only test mode to the existing development runner.

An immediate repository split would also require source distribution, two-repository version coordination and changes to native/Nix deployment provenance. It does not solve the runtime assumptions by itself. Copying the shared Git or pin implementations into Neovim would create two implementations to maintain. Neither is part of this phase.

There is a release constraint beyond directory organization: `nix/files.nix` automatically adopts Neovim Lua, tests and root Markdown files, while `nix/migration/plan.py` rejects an upgrade that changes the owned target set. Therefore this phase adds, removes and renames **no deployed files**. It edits existing modules, tests and documentation. New development tests outside the deployed tree are allowed when useful.

Repository extraction becomes a separate decision after this phase, justified by independent installation, reuse or releases. Dotfiles would remain responsible for pinning and deploying the chosen editor version; a second updater must not own the same installed files.

## Behavior in each environment

| Environment | Editor status | Dotfiles integrations |
| --- | --- | --- |
| No tmux or invalid/unreachable tmux context | Native status; starter may temporarily suppress it | No automatic pane writes; pin actions explain unavailability |
| Ordinary tmux, foundation marker absent/0 | Native status | No status publisher, persistence registration or pin association writes |
| Configured dotfiles tmux, status enabled | Native until an acknowledged publication, then shared tmux status | Existing pins and workspace behavior retained |
| Configured dotfiles tmux, session status disabled | Native status | Persistence and pins remain usable |
| Opt-out `vim.g.dotfiles_tmux_integration = false` | Native status | Dotfiles-specific tmux integration disabled; standard clipboard/split integration unaffected |

The rich native Git segment is optional. Without executable `git-summary`, omit that segment and do not create its polling cache. Mode, path, diagnostics and cursor information remain. The starter's direct-Git implementation remains available.

## Existing modules and interfaces

### Platform discovery

Extend `lua/config/platform.lua`, which already resolves platform capabilities. Do not introduce a provider registry or new deployed module.

Internal functions shared by the concrete consumers:

| Function | Result and responsibility |
| --- | --- |
| `tmux_origin(environment)` | `{socket, pid, session, pane}` or `nil, reason`; parse absolute socket, numeric server/session identities and `%<digits>` pane without I/O |
| `tmux_probe_argv(origin)` | Argument vector for an explicit-socket, originating-session read; no default-server lookup |
| `parse_tmux_probe(origin, completed)` | `{configured, status_enabled}` or `nil, reason`; verify successful result and the matching server/session/pane before accepting capabilities |
| `dotfiles_helper(name, nvim_root)` | Executable absolute path or `nil, reason`; only `git_summary` and `location_pins` are supported |

Move the reusable identity parsing/verification out of `navigation/location_pin_context.lua` into these existing-file functions. Keep the pin module's `resolve`, `validate` and `remember` entrypoints and origin identity checks. Callers execute probe arguments using their own synchronous action or asynchronous controller; this avoids parallel synchronous/asynchronous discovery frameworks.

The probe reads `@dotfiles_foundation_loaded=1` and effective status for the originating session. A pane linked into several sessions must not inherit the wrong session's setting. Empty/malformed output, wrong identity, a nonzero exit or a timeout means unavailable. All background probe/publication subprocesses have a 1000 ms controller deadline. At expiry, invalidate the result and restore native ownership without waiting for the exit callback; kill the owned process and retain the in-flight slot until it is reaped. A subprocess timeout alone must not postpone fallback if the process ignores termination.

Helper discovery retains the current known sibling paths inside this one optional adapter: `../dotfiles/git-summary` and `../tmux/scripts/location-pins`. It checks executability and passes paths literally as argv. No scan of the working directory, arbitrary PATH provider selection, helper copying or new user path-override framework. Runtime roots use `stdpath("config")`; existing `DOTFILES_NVIM_ROOT` test inputs remain supported where currently used.

### Status ownership

Keep `ui.statusline` as the native renderer and `integrations.tmux_status` as the publisher. The native renderer starts installed. Replace “TMUX is set” as the row-hiding condition with acknowledged remote ownership:

`laststatus = (remote_available or startup_visible) and 0 or 3`

Extend `tmux_status.setup({pane?, snapshot?, on_available?})`, with `on_available(boolean)` reporting actual acknowledged ownership. Retain `request(snapshot)`, `start(snapshot)` and `stop()`; add `refresh()` and `set_focused(boolean)` for the lifecycle below. Snapshot fields, pane option names and existing text sanitization remain unchanged.

Before publication, verify the live origin and full-stack opt-in. The guarded write must recheck relevant capability/ownership and emit exactly `dotfiles-nvim-status:<owner>` only after a successful write. Exit zero alone is insufficient: current `if-shell` guards can succeed without writing. Give an owner-mismatch branch a distinct fixed response. Treat empty, unexpected or malformed responses as failed handoff; never execute response text.

Keep the current one-in-flight/coalescing/debounce behavior. A first claim may take ownership once, as today. After a failed/uncertain claim, retries may write only if the owner is absent or still this controller. An observed replacement owner makes this controller relinquish status permanently until explicit shutdown/setup; it must not repeatedly reclaim and fight another editor.

On unavailable capability or failed publication, restore native status and clear only this controller's guarded pane fields. Pause/stop the native Git cache during remote ownership; recreate/resume it on fallback only if its helper exists. Preserve semantic snapshots and starter visibility through every transition.

While focused, a publisher with a valid tmux origin rechecks at most once every 5000 ms, plus immediate checks on focus gain and explicit `refresh()`. Use a small publisher-owned timer; do not repurpose the native Git cache timer. Focus loss pauses periodic checks. On focus gain, make native status visible while availability is revalidated. Suspend also withdraws the editor publication and returns native ownership; resume uses the same revalidation path. Stop closes the timer and invalidates pending callbacks.

A focused capability loss is detected within the 5000 ms cadence plus the 1000 ms subprocess deadline, subject to event-loop scheduling. This is a testable design bound, not measured evidence. Repeated setup is idempotent; late completions after stop, replacement or loss cannot hide the native row or modify another owner's fields.

The foundation marker is an opt-in contract, not proof against arbitrary user edits. Replacing `status-left`, `status-right` or `status-format` manually must clear the marker or disable `dotfiles_tmux_integration`. Window tab labels/styles alone do not remove the main renderer. No new protocol version or renderer-template fingerprint is introduced here.

### Persistence and pins

Gate automatic persistence registration on a valid, configured origin and the opt-out flag. A disabled status row does not disable persistence. Preserve `integrations.tmux_persistence.checkpoint(path) -> "ok" | "error:..."`, safe staging-path validation, session options, pane fields and workspace storage formats. Target the explicit socket. Preserve owner-guarded cleanup and make repeated setup/shutdown safe.

This phase gates registration at setup; it does not add a second persistence supervisor or automatic hot-reload orchestration. Enabling the stack after Neovim startup requires restarting/reinitializing that integration. The status publisher can independently discover renderer availability while the editor is open.

Pins remain session-scoped. Before `context.remember()` or a helper call, require a configured validated origin, enabled integration and an executable pin helper. Setup must not write a session association when unavailable. Keep commands/mappings registered with an action-level explanation. Preserve stable IDs, JSON schema 1, list/add/delete/clear arguments, hostile-path handling, changed-session refusal and modified-buffer protection. No standalone pin backend is added.

### Assets and installation

Keep all existing runtime paths, including:

- `lua/integrations/tmux_persistence.lua`, used by workspace RPC/provenance checks.
- `lua/data_query/tool.lua` and `scripts/data-query-runner.py`, whose canonical relationship is validated.
- `python/pyproject.toml`, `python/uv.lock` and the existing notebook preparation boundary.
- Writable `stdpath("config")/lazy-lock.json`, seeded only when absent by Home Manager.

Native manifests continue selecting `.config/nvim`. Nix continues deploying individual leaves from its filtered canonical tree. No whole-directory symlink, second installer, package ownership change, protocol migration or updater change is needed.

## Verification and delivery

Use three distinct evidence levels:

1. **Source tests:** extend existing Lua tests and run them from a private copied Neovim-only tree using `-u NONE`; no sibling trees, live HOME or package downloads. Include platform, native status, publication, persistence and unavailable-pin regressions. Tests requiring the full stack stay in the full-stack suite.
2. **Configured editor matrix:** use pre-provisioned pinned plugins in isolated homes for standalone, ordinary private tmux and configured dotfiles tmux. Assert actual startup/UI ownership and integration behavior; source tests alone are not proof of plugin startup.
3. **Deployment compatibility:** compare normalized managed file/seed target inventories before/after on all four declared systems; run existing Linux files/terminal checks and affected native bootstrap checks. Preserve mutable-lock behavior and selected-source provenance.

Include marker loss/recovery, effective session `status off`, two linked sessions, owner replacement, failed/late acknowledgments, focus/suspend/exit, absent helpers, quoted paths and starter visibility. Preserve existing real workspace/pin restoration tests. No migration VM rerun is required solely for these UI/module changes; a deployment schema or ownership change would require a separate scope decision.

GitHub's current source workflow does not execute Neovim Lua suites. Record focused editor and configured-runtime results explicitly; a green Python job must not imply editor validation. Native macOS/ARM claims require actual platform runs.

Acceptance: existing workflows pass, ordinary tmux no longer hides native status, the Neovim-only tree passes its core gate, managed targets/seed semantics are unchanged, and independent review finds no ownership or provenance regression.

## Source evidence

Reviewed at the base commit: `init.lua`; `lua/config/platform.lua`; `lua/ui/statusline.lua`; `lua/integrations/tmux_{status,persistence}.lua`; `lua/navigation/location_pin_{context,store}.lua`; `lua/navigation/location_pins.lua`; `.config/tmux/tmux.conf`; `.config/tmux/scripts/workspace`; `nix/files.nix`; `nix/migration/plan.py`; `nix/tests/run-focused.py`; and connected existing tests. Source analysis: ISQ-511, ISQ-514 and ISQ-515.

Primary references: [Neovim subprocess API](https://neovim.io/doc/user/lua/#vim.system()), [Neovim configuration paths](https://neovim.io/doc/user/starting/#standard-path), and [tmux options and formats](https://man.openbsd.org/tmux.1). Keep existing version floors; validate behavior against the pinned tools during implementation.
