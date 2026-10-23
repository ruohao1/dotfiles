# Project-scoped Starter Actions Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans for this single bounded task.

**Goal:** Replace starter project switching with file actions for the current project.

**Architecture:** Reuse navigation.root.resolve and the current fzf-lua picker.
The starter passes its root explicitly; recent(cwd) filters only when given a root.

**Tech Stack:** Lua, Neovim 0.12, installed MiniStarter and fzf-lua.

**Spec:** ../specs/2026-10-23-starter-files-design.md

## Global Constraints

- No working-directory changes, new dependencies, or live editor reloads.
- Preserve global recent-files behavior, Alt navigation, Git panel and quit safety.
- Keep this plan with the implementation branch and PR.

## Review Focus

- Files from a similarly prefixed sibling directory must not enter scoped history.
- Empty history must not prevent Find files from opening.
- Repository subdirectories and ordinary directories must use the existing root policy.
- Actions must follow the current directory after a deliberate directory change.
- The slightly longer label must preserve layout, selection, and key navigation.

## Task 1: Replace the starter actions

**Files:** lua/ui/startup.lua, lua/navigation/pickers.lua, tests/startup.lua,
tests/navigation.lua, tests/startup_layout.lua, STARTUP.md (all under .config/nvim).

**Interfaces:** consume navigation.root.resolve(); retain files(cwd?); extend
recent(cwd?) with fzf-lua cwd_only when a root is supplied. Remove unused projects().

- [x] Add regression assertions for direct scoped file actions without cwd mutation,
  scoped/global recent dispatch, and real installed-provider filtering.
- [x] Run focused navigation/startup tests and observe the new assertions fail.
- [x] Replace Projects/p with Find files/f; remove orphaned discovery code; update
  focused fixtures and user documentation.
- [ ] Run focused tests, the standalone editor suite, configured startup matrix,
  installed-provider checks and formatting; require clean successful output.
- [ ] Commit the implementation and these documents; independently review the
  immutable candidate, then back up and activate changed runtime/docs files.
