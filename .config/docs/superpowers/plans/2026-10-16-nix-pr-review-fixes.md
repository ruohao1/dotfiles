# Nix PR review fixes implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development for the independent fixes and one integrated review.

**Goal:** Resolve the five PR #1 defects and the Linux desktop prerequisite gap identified at `da371e4`.

**Architecture:** Preserve the existing migration and source-validation boundaries. Correct file creation, deployment inventory, and desktop-dependent checks at their existing owners.

**Tech Stack:** Python standard library, Bash, Nix/Home Manager.

**Spec:** `../specs/2026-10-02-nix-dotfiles-design.md`; accepted review in the current user session.

## Global constraints

- Preserve local configuration and writable application state.
- Native desktop integration remains platform-specific; no operating-system replacement.
- No activation, VM startup, package installation, or merge in this repair.
- Plans and fixes travel together on the existing implementation PR.
- Keep trust checks for native capture files and migration evidence; do not bypass validation to make tests pass.

## Review focus

- Permissive umasks must not make a successful preview unreadable by apply.
- Examples must use output locations accepted by the drift guard.
- Home Manager links must resolve to trusted selected source; foreign links remain rejected.
- Native non-Hyprland homes must not require Hyprland capture assets.
- Local X11 and Wayland providers must be distinguished; remote or malformed sessions must fail closed.

## Task 1: Preview file contract and instructions

Files: `nix/migration/cli.py`, `nix/tests/test_migration_plan.py`, preview-command section of `nix/README.md`.

- [x] Add and run a failing regression: preview under umask `0002` remains readable by the actual journal reader.
- [x] Exclusively create preview files with mode `0600`; preserve no-overwrite behavior.
- [x] Document an absolute plan path in a private temporary directory outside HOME.
- [x] Run the migration-plan suite and inspect the documented commands.

## Task 2: Desktop-aware clipboard checker

Files: `.config/dotfiles/check-terminal-stack`, a focused test under `nix/tests/` if needed.

- [x] Reproduce legitimate Home Manager links and absent native Hyprland assets with private fixtures.
- [x] Use existing canonical-source validation for transferred Neovim files while retaining ordinary-file requirements for native capture assets.
- [x] Gate capture-specific requirements and runtime checks by the applicable native profile, retaining portable editor tests.
- [x] Run focused regressions and Bash syntax validation; report native runtime limits.

## Task 3: Linux desktop prerequisites

Files: `nix/migration/prerequisites.py`, `nix/tests/test_migration_prerequisites.py`.

- [x] Trace existing clipboard backend selection and all prerequisite consumers.
- [x] Add failing tests for supported local X11 without Cliphist, Wayland without capture, and invalid/remote sessions.
- [x] Match prerequisite observations to the actual supported backend; require capture tools only when that workflow is configured.
- [x] Preserve evidence binding and drift detection; run the prerequisite suite.

## Task 4: Deployment inventory and integration

Files: `nix/files.nix`, `nix/tests/test_files.py`, source CI only if needed, this plan and relevant Nix documentation.

- [x] Add `.config/nvim/.stylua.toml` to evaluated inventory expectations and include the selected leaf.
- [x] Include new source regressions in existing CI, if not already discovered.
- [x] Run isolated source suites, appropriate available inventory checks, and diff validation.
- [x] Independently review the complete repair, record actual evidence and remaining native acceptance, then update the existing draft PR.

## Validation record

The exact updated source workflow step passed locally in private HOME/TMPDIR
fixtures: 148 tests ran, 136 passed, 12 existing native/Nix-dependent skips,
and no failures. This includes seven new checker regressions and the expanded
preview and native prerequisite suites. Private Unix socket fixtures required
sandbox escalation; no host session sockets were used.

The preview regression and clipboard/backend regressions failed before their
fixes and passed afterward. The new evaluated-manifest expectation includes
`.config/nvim/.stylua.toml`; Nix is unavailable on this host, so its actual
evaluation/build is pending. No native activation or desktop/OS acceptance was
performed. Earlier broad test attempts without the workflow's umask 077 failed
existing private-fixture trust checks; the correct isolated run above passed.

Independent review found no must-fix defects in the combined repair. Bash/POSIX
shell syntax, ShellCheck, Python syntax, and diff whitespace checks passed.

## Review follow-up at `1b70ad1`

The follow-up review found that generic preview evidence restored the shared
X11 directory entries deliberately omitted by the native collector. An unrelated
display could therefore invalidate the selected session's preview.

- [x] Add an integration regression for unrelated X11 display creation/removal;
  retain failures for selected socket and directory identity/permission changes.
- [x] Keep shared session directories' filtered native evidence authoritative
  when collecting generic preview evidence.
- [x] Clarify that preview checks session/providers while the terminal checker
  validates capture-file completeness.
- [x] Run focused and isolated source checks, independently review the small
  follow-up, and update the existing draft PR.

Follow-up verification: the new integration regression failed before the fix and
passed afterward. The exact isolated source workflow then ran 149 tests:
137 passed, 12 existing native/Nix-dependent skips, and no failures. Independent
focused review found no issues; Python syntax and diff checks passed. Native
activation and Nix build acceptance remain pending.
