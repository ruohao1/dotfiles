#!/bin/sh
# shellcheck disable=SC2016 # Literal command-looking paths and tmux IDs are test data.
# Real private-server regressions: lost updates, scope leakage, unsafe literals,
# malformed persistence, and stale contexts must never silently change pins.
set -eu
unset TMUX TMUX_PANE
SHELL=/bin/sh
export SHELL
umask 077
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
script_dir=$(CDPATH='' cd -P "$(dirname "$0")" && pwd -P)
# The focused runner may exercise the deployed helper link (with its jq
# sibling individually deployed) while the test itself stays a store source.
helper=${DOTFILES_TEST_LOCATION_PINS:-$script_dir/../scripts/location-pins}
root=$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-location-pins-test.XXXXXX")
socket=$root/one.sock
second_socket=$root/two.sock
cleanup() {
  tmux -S "$socket" kill-server >/dev/null 2>&1 || :
  tmux -S "$second_socket" kill-server >/dev/null 2>&1 || :
  case $root in "${TMPDIR:-/tmp}"/dotfiles-location-pins-test.*) rm -rf "$root" ;; esac
}
trap cleanup 0
trap 'exit 130' INT
trap 'exit 143' HUP TERM
tmux -S "$socket" -f /dev/null new-session -d -s first
tmux -S "$socket" new-session -d -s second
session=$(tmux -S "$socket" display-message -p -t '=first:' '#{session_id}')
other_session=$(tmux -S "$socket" display-message -p -t '=second:' '#{session_id}')
pid=$(tmux -S "$socket" display-message -p -t "$session" '#{pid}')
run() { "$helper" "$@" --socket "$socket" --session "$session" --server-pid "$pid"; }
count() { run list | jq '.pins | length'; }
[ -x "$helper" ] || fail 'line-pin store must be available to share a session location'
[ "$(count)" = 0 ] || fail 'new sessions start empty'
# JSON numbers with equal values must name the same location and stay readable.
printf '%s\n' '{"path":"/numeric-equivalence","line":1,"col":0}' | run add >"$root/integer-pin"
for coordinates in '1.0,0.0' '1e0,-0' '1.00e+0,-0.0'; do
  printf '{"path":"/numeric-equivalence","line":%s,"col":%s}\n' "${coordinates%,*}" "${coordinates#*,}" \
    | run add >"$root/equivalent-pin"
  cmp "$root/integer-pin" "$root/equivalent-pin" || fail 'equivalent numbers change pin identity'
  [ "$(count)" = 1 ] || fail 'equivalent numbers corrupt the pin list'
done
run list >"$root/integer-state"
sed 's/"line":1,/"line":1.0,/;s/"col":0/"col":-0.0/' "$root/integer-state" >"$root/decimal-state"
"$helper" validate <"$root/decimal-state" >"$root/canonical-state"
cmp "$root/integer-state" "$root/canonical-state" || fail 'offline validation does not canonicalize coordinates'
run clear
run import <"$root/decimal-state"
run list >"$root/imported-state"
cmp "$root/integer-state" "$root/imported-state" || fail 'import does not canonicalize coordinates'
run clear
pass 'equivalent numeric coordinates share one canonical identity'
# Quotes, format syntax, tabs, newlines, Unicode and command-looking text are data.
path=$(printf '%s\t%s\n%s' "$root/雪 \"quote\" #{session_name}" '$(touch SENTINEL)' "last'")
jq -cn --arg path "$path" '{path:$path,line:12,col:3}' >"$root/location"
run add <"$root/location" >"$root/pin"
id=$(jq -r '.id' "$root/pin")
jq -e --arg path "$path" '.path == $path and .line == 12 and .col == 3' "$root/pin" >/dev/null || fail 'literal add'
[ "${#id}" = 64 ] || fail 'stable identity length'
run add <"$root/location" >"$root/repeated"
cmp "$root/pin" "$root/repeated" || fail 'repeated location changes identity'
[ "$(count)" = 1 ] || fail 'repeated add duplicates a pin'
[ ! -e SENTINEL ] || fail 'path was evaluated'
run list >"$root/state"
run validate <"$root/state" >"$root/validated" 2>"$root/error" && fail 'offline validation accepts context arguments'
"$helper" validate <"$root/state" >"$root/validated"
cmp "$root/state" "$root/validated" || fail 'canonical state validation'
tmux -S "$socket" rename-session -t "$session" renamed
[ "$(count)" = 1 ] || fail 'rename loses pins'
first_session=$session
session=$other_session
[ "$(count)" = 0 ] || fail 'pins leak between sessions'
tmux -S "$socket" set-option -g "@dotfiles_line_pin_$id" "$(cat "$root/pin")"
[ "$(count)" = 0 ] || fail 'global inherited options leak into session state'
run import <"$root/state"
[ "$(count)" = 1 ] || fail 'import does not restore exact pin'
session=$first_session
run delete <<EOF
{"id":"$id"}
EOF
[ "$(count)" = 0 ] || fail 'delete leaves a local pin or reads its inherited global value'
tmux -S "$socket" set-option -gu "@dotfiles_line_pin_$id"
run import <"$root/state"
tmux -S "$second_socket" -f /dev/null new-session -d -s first
second_pid=$(tmux -S "$second_socket" display-message -p '#{pid}')
[ "$("$helper" list --socket "$second_socket" --session '$0' --server-pid "$second_pid" | jq '.pins|length')" = 0 ] || fail 'pins leak between servers'
pass 'literal pins, idempotence, rename, import and session/server isolation'
# Independent editors add at once. A read-modify-write whole-list store loses pins.
i=1
pids=
while [ "$i" -le 16 ]; do
  (printf '{"path":"/concurrent/%s","line":1,"col":0}\n' "$i" | run add >"$root/add-$i") &
  pids="$pids $!"
  i=$((i + 1))
done
for child in $pids; do wait "$child" || fail 'concurrent add failed'; done
[ "$(count)" = 17 ] || fail 'concurrent adds lost locations'
(run delete <<EOF
{"id":"$id"}
EOF
) &
delete_pid=$!
printf '%s\n' '{"path":"/concurrent/new","line":1,"col":0}' | run add >"$root/new"
wait "$delete_pid"
[ "$(count)" = 17 ] || fail 'independent delete/add lost updates'
run clear
[ "$(count)" = 0 ] || fail 'clear retained observed pins'
session=$other_session
[ "$(count)" = 1 ] || fail 'clear affected another session'
session=$first_session
pass 'concurrent mutations retain independent pins'
# Each invalid shape must fail before changing a real session.
for input in \
  '{"path":"relative","line":1,"col":0}' \
  '{"path":"/x","line":0,"col":0}' \
  '{"path":"/x","line":1.5,"col":0}' \
  '{"path":"/x","line":1,"col":-1}' \
  '{"path":"/x","line":1,"col":2147483648}' \
  '{"path":"/x","line":1,"col":0,"extra":true}' \
  '{"path":"/x\u0000y","line":1,"col":0}' \
  '{} {}'
do
  if printf '%s\n' "$input" | run add >"$root/output" 2>"$root/error"; then fail "invalid location accepted: $input"; fi
done
printf '{"path":"/\377","line":1,"col":0}' >"$root/invalid-utf8"
if run add <"$root/invalid-utf8" >"$root/output" 2>"$root/error"; then fail 'invalid UTF-8 silently changed a path'; fi
jq -cn '{path:("/"+("x"*8192)),line:1,col:0}' >"$root/long-path"
if run add <"$root/long-path" >"$root/output" 2>"$root/error"; then fail 'overlong path accepted'; fi
for filter in '.version=2' '.extra=true' '.pins += .pins' '.pins[0].id=("0"*64)' '.pins[0].extra=true'; do
  jq "$filter" "$root/state" >"$root/invalid"
  if run import <"$root/invalid" >"$root/output" 2>"$root/error"; then fail "invalid state accepted: $filter"; fi
  [ "$(count)" = 0 ] || fail 'invalid import partially mutated state'
done
tmux -S "$socket" set-option -t "$session" @dotfiles_line_pin_bad '{}'
if run list >"$root/output" 2>"$root/error"; then fail 'malformed option silently became empty'; fi
tmux -S "$socket" set-option -u -t "$session" @dotfiles_line_pin_bad
tmux -S "$socket" set-option -t "$session" "@dotfiles_line_pin_$id" '{}'
if run list >"$root/output" 2>"$root/error"; then fail 'malformed record silently became empty'; fi
tmux -S "$socket" set-option -t "$session" "@dotfiles_line_pin_$id" ''
if run list >"$root/output" 2>"$root/error"; then fail 'empty option silently became empty state'; fi
tmux -S "$socket" set-option -u -t "$session" "@dotfiles_line_pin_$id"
if "$helper" list --socket "$socket" --session "$session" --server-pid 1 >"$root/output" 2>"$root/error"; then fail 'stale PID accepted'; fi
if "$helper" list --socket "$socket" --session renamed --server-pid "$pid" >"$root/output" 2>"$root/error"; then fail 'session-name targeting accepted'; fi
if "$helper" list >"$root/output" 2>"$root/error"; then fail 'implicit default server accepted'; fi
[ "$(count)" = 0 ] || fail 'invalid operations changed the session'
pass 'invalid state and stale context fail without mutations'
