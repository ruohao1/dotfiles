# Repository-aware Neovim Starter Implementation Plan

> **For agentic workers:** Use subagent-driven development for the independent Git and layout tasks, followed by controller integration and independent review. Check off completed tasks only after their checks pass.

**Goal:** Show the approved Projects / Recent files / Quit menu and a responsive, read-only Git summary without delaying or changing Neovim startup.

**Architecture:** Keep MiniStarter and its native item/action machinery. A Git module produces display data asynchronously; a pure layout module composes original item units with non-interactive Git content. The existing controller owns buffer lifetimes, requests and events.

**Tech stack:** Existing Neovim 0.12+, Lua, Git and locked MiniStarter. No new dependency or lock update.

**Spec:** [Approved starter design](https://linear.app/isqrd/document/neovim-repository-aware-starter-menu-design-fb83cb759daf). Assignment: [ISQ-92](https://linear.app/isqrd/issue/ISQ-92/implement-the-repository-aware-neovim-starter-menu), revision 3. This plan updates the retained August implementation plan for source `4427c2febfe7d40e1492f04a8ae7238e98339d22`.

## Global constraints

- Exactly `p  Projects`, `r  Recent files`, `q  Quit`, in that order; Projects initially selected. Empty header/footer, visible selected-item pointer, disabled query filtering. Buffer-local silent nonrecursive shortcuts; cyclic j/k/arrows; native Enter. Quit uses normal `:quit`.
- Preserve true-bare-launch detection, eager MiniStarter, project validation, pickers and statusline behavior. No new actions, real splits, plugin or shell command construction.
- Git discovers only conventional repositories from each buffer's captured directory, with no `$HOME/.cfg` fallback. Preserve raw paths for operations and sanitize only display strings.
- Read-only asynchronous `vim.system` argv calls; stable locale, absolute Git executable, cleared inherited Git environment, disabled pager/prompts/optional locks/fsmonitor. One 3000 ms request deadline; no polling.
- At most five commit entries and twelve changed file entries. History topology and path hierarchy remain visible. Show staged/unstaged XY states, conflict/untracked distinctions, clean and unborn states, and omitted counts.
- Wide layout starts at 92 cells, caps content at 112 cells, reserves 22 cells for the menu and a four-cell gap. Narrow layout stacks menu above Git. No repository/error means centered vertical menu; loading renders immediately.
- Resize recomposes cached data only. Directory changes invalidate old requests. Visible focus refresh debounces for 150 ms and never overlaps a request. Buffer closure cancels its requests/timer; stale callbacks cannot refresh another buffer. Warn at most once per starter buffer.
- Fresh `STARTUP.md` comes only from tracked source and approved behavior. Do not access the old untracked live README. Keep this plan with implementation on the feature branch and PR.
- No live activation, VM, package install, unrelated AI work, source lock changes, merge or destructive cleanup. Isolated tests use private HOME/XDG/temp roots and retained plugin copies.

## Current-source decisions

- Use `.config/nvim/STARTUP.md` instead of the absent README. This follows existing focused product documents and resolves the obsolete provenance assumption.
- Extend the actual `DOTFILES_STARTUP_LIVE` harness, including native MiniStarter mechanics. The old `NVIM_EXPECT_DASHBOARD`, `NVIM_FULL_SMOKE` and `tests/smoke.lua` instructions do not apply.
- Under impossibly small viewports, preserve all menu actions and essential identity/summary in scrollable content; omit optional detail first. Normal usable sizes must respect width/height budgets. Test this explicit fallback instead of silently dropping actions.
- A summary's commit count is collected history entries, not total repository history. All changed paths are counted before the twelve-file display limit.
- Independent review demonstrated that `git status` executes configured clean/process filters, including filters inside tracked submodules. Read-only configuration/index preflights share the request deadline; repositories with these helpers or gitlinks use the existing error/menu fallback before status runs. Do not disable filters or hide dirty submodules and then report inaccurate state. Status explicitly disables the unrelated optional stash-count header.
- Git and layout writers own disjoint files and use the model below. Coordinator alone changes Git metadata and integrates controller/test registration. Product modules may be developed in parallel; commits and final verification are serialized.

## Review focus

1. Git environment/configuration redirects, non-repository errors and unborn history failures must not leak external state or incorrectly hide a valid repository (Task 1).
2. NUL records, rename source paths, invalid UTF-8, control bytes and multibyte widths must remain correctly delimited and display safely (Tasks 1–2).
3. Closing or replacing a starter during delayed completion must not refresh another buffer or leave an owned child/timer running (Tasks 1, 3).
4. Narrow layouts share item rows: the pointer must use row and byte column, preserve native item identity and keep Git text out of navigation (Tasks 2–3).
5. Existing file/stdin/session/remote/tmux launches must never gain a dashboard; changing directories and resizing must retain selection and avoid extra Git processes (Task 3).

## Shared interfaces

`require("ui.startup.git").collect(directory, callback)` returns a request with `cancel() -> boolean`. Callback receives exactly one final view, unless canceled:

```lua
{ kind = "non_repository" }
{ kind = "error", message = "safe diagnostic" }
{
  kind = "repository", root = "raw absolute path", name = "display name",
  branch = { oid, head, upstream, ahead, behind, detached, unborn },
  changes = { { path, original_path, xy, index, worktree, kind } },
  counts = { total, modified, added, deleted, renamed, conflicted, untracked },
  history = { { graph, oid, subject } },
}
```

Absent upstream/count categories may be nil. Connector-only history rows omit oid/subject and do not consume the five-commit limit. Changes contain raw relative paths; layout sanitizes path segments through the public `git.sanitize` function. Display-only branch/name/history strings are sanitized by the collector. Neither consumer mutates the model.

`require("ui.startup.layout").compose(content, view, { width, height, display_width })` returns MiniStarter content. `view.kind` also accepts `loading`. Retain the exact three input item-unit objects and their actions; insert one two-cell `pointer` unit before each. Other content units are non-items. Controller updates the visible pointer using the selected item's row and byte column. The pinned MiniStarter exposes no refresh/select events: use controller-owned native navigation wrappers, CursorMoved reconciliation, and scheduled post-content-hook reconciliation for native refresh. Capture the selected action before repositioning and restore it after refresh, which otherwise resets selection when item coordinates change.

## Task 1: Git parsing and asynchronous collection

**Files:** create `.config/nvim/lua/ui/startup/git.lua` and `.config/nvim/tests/startup_git.lua`.

**Produces:** public `collect`, exported `sanitize`, and `_test` parser/collector seams. `_test.parse_status(root, output) -> model|nil, error|nil`; `_test.parse_history(output) -> rows|nil, error|nil`; `_test.new(dependencies)` builds an injected collector for deterministic process/timer tests.

- [x] Add failing parser tests for porcelain-v2 NUL headers and ordinary, rename, conflict and untracked records; branch divergence, detached/unborn state; tabs/newlines/control and invalid UTF-8; malformed records. Assert actual model values and preserved raw paths.
- [x] Capture the expected missing-module failure with the isolated test command below.
- [x] Implement strict parsers and single-line sanitization. Parse full status to count changes; render caps belong to layout. Run real temporary Git fixtures to confirm requested output formats.
- [x] Add failing collector tests: asynchronous discovery then concurrent status/history, successful exactly-once delivery, normal non-repository, unborn history failure, unexpected command/parse failure, shared deadline, cancellation, late callbacks and child/timer cleanup. Verify argv/env and absence of shell execution.
- [x] Implement the smallest collector. Resolve the Git executable once per collection; preserve runtime PATH needed by Git while clearing inherited GIT_* overrides and user-sensitive hooks. On error cancel unfinished siblings; schedule delivery safely. No arbitrary stderr goes to user notifications.
- [x] Pass focused tests and StyLua; record red/green evidence and return files for review. Coordinator commits after review.

## Task 2: Responsive pure composition

**Files:** create `.config/nvim/lua/ui/startup/layout.lua` and `.config/nvim/tests/startup_layout.lua`.

**Consumes:** exact shared view and original MiniStarter content. **Produces:** `compose` and only focused test seams needed for width/hierarchy verification.

- [x] Add failing tests for centered menu-only/error, loading, wide and narrow layouts using the same three item objects and a deterministic display-width function.
- [x] Capture expected missing-module failure. Implement base composition with 92/112/22/4 constants, all three items/actions, two-cell pointers, and compact navigation hint.
- [x] Add tests for clean, unborn, dirty, detached, upstream, five-commit/twelve-path limits, topology connector rows, grouped directory hierarchy, exact XY markers and omitted counts. Test dense short views and tiny fallback.
- [x] Add Unicode/wide/combining/control-byte cases. Assert input immutability, item identity, no additional navigable items, and width budgets at usable sizes.
- [x] Implement priority-based row allocation and display-cell truncation; preserve markers before descriptive text. Use semantic colorscheme highlights, no fixed theme colors.
- [x] Pass focused tests and StyLua; record evidence and return files for review. Coordinator commits after review.

## Task 3: Controller, native mechanics and documentation

**Files:** modify `.config/nvim/lua/ui/startup.lua`, `.config/nvim/tests/startup.lua`, `.config/dotfiles/check-terminal-stack`, `nix/tests/run-focused.py`; create `.config/nvim/STARTUP.md`.

**Consumes:** Tasks 1–2 interfaces. **Produces:** complete approved user flow and current test entrypoints.

- [x] Extend the existing controller harness first for exact p/r/q, native cyclic j/k/arrows/Enter, normal quit and three preserved actions. Capture old two-item failure.
- [x] Add per-buffer directory/generation/request/view/warned/focus-timer state. Render loading before collection; validate callbacks against current generation, directory, valid starter buffer and lifecycle. Cancel/invalidate on wipe/directory change; focus debounces 150 ms; resize only recomposes cached data.
- [x] Test repeated setup, concurrent buffers, closed/stale callback, rapid directory change, focus overlap, timeout/error one-warning fallback and pointer matching on shared narrow rows. With real MiniStarter, select Recent/Quit, complete cached async data and resize wide/narrow; assert the same action stays selected and the pointer matches row plus byte column. Preserve existing launch/project/statusline tests.
- [x] Adapt the real MiniStarter mechanics fixture to use actual composition. Add isolated clean/dirty/dense/detached/unborn/non-repository repositories and delayed Git output. Verify menu input remains usable while loading, actual output, selection, resizing and normal quit.
- [x] Add focused Git/layout suite registration to the existing checker and source runner, and include the controller's pure suite in the source runner. Nix already selects Lua/tests and top-level Markdown automatically; no deployment-input changes are needed.
- [x] Write concise STARTUP.md describing keys, Git display, refresh/failure behavior and conventional discovery limits. Document the tiny-viewport fallback.
- [x] Run focused tests, isolated configured startup matrix, adjacent source suites and formatting/shell/Python syntax checks appropriate to modified files. Run independent complete diff review, fix real findings, then commit scoped changes with this plan.

## Validation commands

Coordinator creates a private root outside source, with per-suite HOME/XDG/TMPDIR and `NVIM_LOG_FILE` under it. Use the installed pinned Neovim and read-only retained plugins; do not initialize the user's real configuration.

```sh
env -i PATH=/home/ubuntu/.local/bin:/usr/bin:/bin LANG=C.UTF-8 \
  HOME="$fixture/home" TMPDIR="$fixture/tmp" NVIM_LOG_FILE="$fixture/nvim.log" \
  XDG_CONFIG_HOME="$fixture/config" XDG_DATA_HOME="$fixture/data" \
  XDG_STATE_HOME="$fixture/state" XDG_CACHE_HOME="$fixture/cache" \
  DOTFILES_NVIM_ROOT="$worktree/.config/nvim" \
  nvim --clean --headless -u NONE -i NONE \
  -c 'lua vim.opt.runtimepath:prepend(vim.env.DOTFILES_NVIM_ROOT)' \
  -l "$worktree/.config/nvim/tests/startup_git.lua"
```

Repeat for `startup_layout.lua` and `startup.lua`. Their sole success markers are respectively `Startup Git assertions: ok`, `Startup layout assertions: ok`, and the existing startup marker. Configured tests additionally use `DOTFILES_STARTUP_LIVE=1`, explicit `DOTFILES_STARTUP_{DATA_HOME,ALLOWED_ROOT,TEST_ROOT}`, and retained copied plugin data; expect `Configured MiniStarter startup matrix: ok`. Evidence records actual commands, exits and skips.

## Delivery

The feature branch starts from the reviewed Nix branch at the pinned base; it does not modify or merge that branch. Keep the plan and implementation together. Publish only a scoped implementation PR after checks/review, with Linux runtime scope and remaining macOS manual acceptance explicit. Preserve private test/review evidence; leave no owned processes running and do not activate live dotfiles.

## Verification and review — 2026-10-17

- All 18 editor source suites passed using private HOME/XDG and short temporary paths; the runner confirmed source inputs unchanged.
- The complete configured MiniStarter startup matrix passed using private copies of all 16 locked plugins. Native regressions cover background-window status visibility, ordered resize/async completion, explicit navigation during restoration, and quitting during pending collection.
- Scoped StyLua, shell/Python syntax, and Git whitespace checks passed. Independent Git/layout and controller reviews passed after fixes, including actual clean-filter and submodule-filter execution regressions.
- No live activation, VM, package/input changes, or macOS runtime validation. Filter-configured and submodule repositories intentionally use the documented menu fallback.
- Keep this plan and the implementation in one feature-branch commit. Publication remains a separate final delivery step; preserve the worktree and evidence.

## PR review fixes — 2026-10-18

The user requested fixes for the three reproduced findings on PR #2 at `4dd32d8`.
Keep this follow-up on the existing feature branch and implementation PR.

- [x] Prevent partial-clone collection from fetching missing objects or running transport helpers, including after the request deadline. Add a real partial-clone regression that checks repository objects and helper execution.
- [x] Honor effective user Git ignore settings and detect global clean/process filters before status. Add private global-ignore and filter regressions while retaining inherited Git-environment isolation.
- [x] Refresh affected visible starter buffers on split-window resize using cached data. Test native layout width, preserved selection and unchanged Git request count.
- [x] Run focused suites, the complete isolated configured startup matrix, scoped formatting and independent review.

The explicit `--no-lazy-fetch` option requires Git 2.45+ for the summary; older
versions safely use the menu-only fallback. The alternative empty protocol
allowlist was rejected after a private helper-execution reproduction. Global
configuration remains effective while Trace2 output is disabled and history
encoding is fixed to UTF-8. Shared starter buffers fit their smallest window.

Validation passed on Neovim 0.12.4 and Git 2.53.0: all 18 editor source suites,
the complete configured startup matrix with 16 locked plugin copies, scoped
StyLua, whitespace checks and independent review. New regressions failed before
their fixes. Unsupported-option fallback was tested with a private wrapper;
actual older Git and macOS were not run. No live activation or dependency change.
Deliver this as a scoped follow-up commit on the existing draft PR.

## Visual acceptance polish — 2026-10-19

The accepted preview exposed a pointer without distinct selected-item styling.
Use TokyoNight's existing `on_highlights` hook to link `MiniStarterCurrent` to
the semantic `Visual` selection background, including after colorscheme reload.
Keep layout, navigation and dependencies unchanged. Extend the existing theme
options and configured startup checks, reproduce the failure before the fix,
then rerun those checks and capture the selected item in the isolated preview.
Keep this fix on the existing feature branch and draft PR; no merge or activation.

Validation: the configured regression failed on the missing selected background
before the fix. The complete configured startup matrix and focused TokyoNight /
Treesitter suite then passed, as did scoped StyLua, whitespace checks and an
independent read-only review. The seven-view Linux TUI preview confirmed the
highlight after theme reload, navigation and resizing. No macOS or live
activation was tested.
