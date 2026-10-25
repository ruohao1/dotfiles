# Shared status bar implementation plan

**Goal:** Make project, window selection, zoom, and unsaved edits clear in the shared tmux/Neovim bar.

## Agreed design

- Keep the mode at the left. COPY, RESIZE, and PREFIX retain priority over editor mode.
- Show the project name without Editor or Terminal suffixes.
- Use a subtle dark background and bold text for the selected window. Use `1 nvim` normally and a rounded gray badge around the index when zoomed, including inactive zoomed windows.
- Keep `•` for background output and `!` for a terminal bell. These do not imply task completion or failure.
- Use no additional state labels, zoom icon, or italics.
- Show `[+]` for an unsaved editor buffer. Preserve file, diagnostics, and cursor context.
- Shorten optional text before losing essential mode/window information on narrow terminals.

## Implementation choices

Use the existing native tmux formats and Neovim bridge. Keep the TokyoNight palette and existing Git helper. No plugin or runtime dependency is needed. Project identity comes from the session starting directory, so changing a pane's directory does not change its project label. Add it after mode, retaining the existing Git segment position. Bound that segment to leave room for the project.

Keep the existing 80/100/120-column profiles and 48-cell side limits. Project caps are 8/10/12 cells; below 80 use 8 cells and hide it below 40. Window-name caps are 5/10/12 cells. Git display caps stay at 8/12/16 cells so change counters retain their space. Keep the original positions: mode/project/Git on the left, windows absolutely centered, and file context on the right. Keep the original one-cell padding on both sides of segments and tabs, with activity/bell symbols attached to the window name. Keep one space between the index and name; do not use a colon. Keep the current file or directory context on the right. Hide the shell clock below 80. Window indices remain outside truncated window names so zoom badges cannot be clipped. Unsaved state is a strict boolean, published as `@dotfiles_nvim_modified=0|1`; its marker remains available in the narrow profile.

Selection by a subtle background and bold text, and zoom by a rounded index badge, remain independent. The user preferred this quieter selection over the initial blue fill and smoother corners over square brackets. The badge uses the existing muted gray palette and the configured Nerd Font's rounded caps, with the same width as the previous brackets. Text labels and italic zoom were considered and rejected during design.

The compact-layout refinement shortens long labels while retaining the original positions and padding. Keep relative file paths: replacing them with basenames would make files such as `src/index.ts` and `tests/index.ts` indistinguishable.

## Work and verification

- [x] Extend private tmux tests for zoom toggling, selected style, activity/bell, stable escaped project labels, narrow widths, and modified state. Observe regressions before changing formats.
- [x] Extend the Neovim semantic snapshot, publisher, and native fallback with modified state and BufModifiedSet. Verify edit/save transitions without extra Git polling and preserve ownership acknowledgment/cleanup.
- [x] Update native tmux formats and the existing status safety/compatibility checker. Preserve exact helper jobs, escaped display values, and the release-update badge.
- [x] Run the relevant Python and headless Neovim suites, inspect private tmux rendering, and obtain an independent review.
- [x] Activate only reviewed changed runtime files with backups. Keep this plan with the implementation branch and PR. Do not merge without a user instruction.

Review focus: hostile project/window/file names, inactive zoomed windows, extreme widths and multi-digit indices, dirty-to-clean transitions, and tmux handoff failure/cleanup. Preserve unrelated local changes and the installed session picker.

## Results

- 14 private tmux status tests passed on tmux 3.7c and 3.6, with no skips. The nonempty Git test checks actual attached-terminal output at 120, 100, 80, and 60 columns.
- All eight standalone editor suites passed on the current main base. A real private Neovim/tmux run verified acknowledged ownership, edit/save publication, and native fallback when tmux status is disabled.
- Independent review found no issues. Shell syntax and whitespace checks passed. Native macOS and the complete terminal-stack checker were not run.
- Three runtime files were activated with backups. Five tmux status options were reloaded without restarting sessions. The existing local release-badge setting was preserved. Already-running editors use their loaded modules until restarted.
- The compact follow-up passed the same 14 tmux tests on both versions, plus attached rendering probes at 80/100/120 columns with empty Git. One status file and four options were updated with a separate backup. ShellCheck and independent review passed.

The user clarified that compactness must retain the original positions and padding. Windows stay absolutely centered; only the shorter names remain from the compact refinement.

The tab format is `1 nvim`, with a rounded gray index badge when zoomed. Activity/bell symbols still attach directly to the name, as in `codex•!`. Outer padding and original positions stay unchanged.
