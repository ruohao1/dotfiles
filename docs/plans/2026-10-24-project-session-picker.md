# Project Session Picker Implementation Plan

**Goal:** Show one row per project in the Alt+Space, then f picker.

**Design:** The user chose grouped projects over separate rows with role labels.
A project is an exact tmux session starting directory, consistent with the existing
picker. Select a project with one session to switch directly. If it has several
sessions, show a second picker containing all their names. Escape or Ctrl+C at
either step cancels without switching. Separate worktrees stay separate.

**Architecture:** Extend the existing Python helper and reuse fzf for both steps.
Keep canonical session IDs as targets, validate complete offered records, and
switch only the invoking client. No session creation, renaming, closing, new
dependencies, key-binding changes, or Git-root discovery.

## Implementation and validation

- [x] Extend `nix/tests/test_session_navigator.py` with shared-directory sessions,
  distinct directories with the same basename, direct singleton selection,
  cancellation and invalid/stale selections at the second step, and real fzf
  keyboard interaction. Observe the grouped-project regression fail first.
- [x] Update `.config/tmux/scripts/session-navigator` to group by the raw starting
  directory, display a safe project name/path, and select an explicit session
  only when needed. Preserve hostile-label escaping and client identity checks.
- [x] Update `.config/tmux/PROJECTS.md` with both selection steps and the directory
  grouping rule. Keep this plan with the implementation PR.
- [x] Run the navigator and binding checker suites, including installed fzf and
  the previously validated fzf 0.44.1 when available. Obtain an independent review.

**Delivery:** After review, activate only the helper with a checked preimage and
backup, then commit and open a PR. Do not merge without a further instruction.

## Review focus

Keep every session in a shared directory reachable. Preserve non-UTF-8 path
identity and do not merge different paths because their display labels match.
Reject forged fzf output at both steps. A closed session or client must not
redirect selection to another session. Preserve
unrelated client positions and all ignored local Superpowers documents.
