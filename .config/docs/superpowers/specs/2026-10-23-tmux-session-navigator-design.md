# Fuzzy tmux session navigation

Alt+Space, then `f` opens an fzf popup containing existing sessions, including
separate Neovim sessions. Search session names and their starting project paths;
Enter switches the invoking terminal client, while Escape or Ctrl+C cancels.
Other clients, sessions, and pane navigation keep their current behavior.

Replace the existing prefix-f tree picker. Reuse installed fzf and Python 3.9+,
with tmux 3.2-compatible popup options. A small helper receives the explicit
server socket and invoking client from tmux. Session IDs are selection identities;
names and paths are sanitized display text. NUL-delimited fzf records preserve
the identity boundary. Accept only a complete offered record and fail closed if
its session or invoking client disappears. No shell evaluation of session data.

The popup lists sessions on the invoking tmux server. It does not create, delete,
or rename sessions, and it does not preview pane contents. It uses fixed fzf
options so inherited fzf commands cannot alter the selection protocol.

Native bootstrap and Nix already include tmux scripts. The new helper adds a
managed Nix target: existing managed installations must use the documented
legacy restoration/re-adoption procedure because the current updater rejects
target-set changes. This feature does not change migration policy.

Acceptance: private-server tests cover two-client isolation, name/path search,
editor sessions, hostile labels, cancellation, vanished targets, malformed
selection, and the real prefix-f popup. Exact terminal binding audits must accept
only the intended command. Independently review the candidate before activating
the local helper and binding. Plans ship with the implementation PR.
