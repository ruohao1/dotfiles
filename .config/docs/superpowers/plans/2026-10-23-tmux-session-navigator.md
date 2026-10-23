# Fuzzy tmux session navigator implementation

Task: ISQ-559, feature ISQ-558. Branch: `agent/tmux-session-navigator-20261023`.
Base: `afdea30b8a9450a5dd34b9c476c7fcdd33dfb74f`.

1. Add focused private-server tests for the helper contract and verify failure
   before implementation. Include a real fzf popup driven through a private PTY.
2. Implement the session helper and replace prefix-f in `keys.conf`. Document
   search, selection, cancellation, and installation requirements in `PROJECTS.md`.
3. Update the exact terminal checker expectations and deployment coverage. Keep
   test files outside the deployed tmux tree and preserve unrelated bindings.
4. Run focused tests, inspect the diff, commit the candidate and independently
   review it. Include this plan and design in the implementation PR.
5. Back up local files, install only reviewed changes, and apply only prefix-f
   to the running tmux server. Verify installed bytes, permissions, and binding.

Ownership: coordinator writes runtime/config/docs; navigation_review writes the
focused navigator tests; nvim_deployment_plan writes checker/inventory/CI tests.
Validation uses synthetic sessions and private sockets, never user pane contents.
No session lifecycle operations, package changes, or Nix migration changes.
