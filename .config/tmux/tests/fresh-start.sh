#!/bin/sh
set -eu

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

assert_equal() {
  assert_expected=$1
  assert_actual=$2
  assert_label=$3
  if [ "$assert_expected" != "$assert_actual" ]; then
    fail "$assert_label: expected <$assert_expected>, got <$assert_actual>"
  fi
}

assert_contains() {
  assert_expected=$1
  assert_actual=$2
  assert_label=$3
  case $assert_actual in
    *"$assert_expected"*) ;;
    *)
      fail "$assert_label: expected <$assert_expected> in <$assert_actual>"
      ;;
  esac
}

assert_empty() {
  assert_file=$1
  assert_label=$2
  if [ -s "$assert_file" ]; then
    sed 's/^/      /' "$assert_file" >&2
    fail "$assert_label: expected no output"
  fi
}

script_directory=$(CDPATH='' cd -P "$(dirname "$0")" && pwd -P)
repository_root=$(CDPATH='' cd -P "$script_directory/../../.." && pwd -P)
config_root=$repository_root/.config
tmux_entry=$config_root/tmux/tmux.conf

[ -r "$tmux_entry" ] || fail "tmux entry is not readable: $tmux_entry"
real_tmux=$(command -v tmux) || fail "tmux is required"

case "$(uname -s)" in
  Darwin) expected_platform=macos ;;
  Linux) expected_platform=linux ;;
  *) fail "unsupported platform from uname -s" ;;
esac

test_root=
socket_path=
control_pid=
control_input_open=0

cleanup() {
  if [ "$control_input_open" = 1 ]; then
    exec 3>&-
    control_input_open=0
  fi
  if [ -n "$control_pid" ]; then
    kill "$control_pid" >/dev/null 2>&1 || :
    wait "$control_pid" >/dev/null 2>&1 || :
    control_pid=
  fi
  if [ -n "$socket_path" ]; then
    "$real_tmux" -S "$socket_path" kill-server >/dev/null 2>&1 || :
  fi
  if [ -n "$test_root" ] && [ "$test_root" != / ]; then
    case ${test_root##*/} in
      dotfiles-tmux-fresh-start.*)
        rm -rf "$test_root"
        ;;
      *)
        printf 'refusing to remove unexpected test path: %s\n' "$test_root" >&2
        ;;
    esac
  fi
}

trap cleanup 0 HUP INT TERM

test_root=$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-tmux-fresh-start.XXXXXX") \
  || fail "could not create a temporary directory"
socket_path=$test_root/tmux.sock
stdout_file=$test_root/stdout
stderr_file=$test_root/stderr
state_root=$test_root/state
cache_root=$test_root/cache
runtime_root=$test_root/runtime
mkdir -p "$state_root" "$cache_root" "$runtime_root"

if ! env -u TMUX -u TMUX_PANE -u NVIM_APPNAME \
  HOME="$repository_root" \
  SHELL=/bin/sh \
  XDG_CONFIG_HOME="$config_root" \
  XDG_DATA_HOME="${XDG_DATA_HOME:-$repository_root/.local/share}" \
  XDG_STATE_HOME="$state_root" \
  XDG_CACHE_HOME="$cache_root" \
  XDG_RUNTIME_DIR="$runtime_root" \
  TERM=xterm-ghostty \
  TERM_PROGRAM=ghostty \
  "$real_tmux" -S "$socket_path" -f "$tmux_entry" \
    new-session -d -s terminal-stack-fresh-start \
    >"$stdout_file" 2>"$stderr_file"; then
  sed 's/^/      /' "$stdout_file" >&2
  sed 's/^/      /' "$stderr_file" >&2
  fail "fresh tmux server did not start"
fi

assert_empty "$stdout_file" "fresh tmux stdout"
assert_empty "$stderr_file" "fresh tmux stderr"

foundation_loaded=
attempts=0
while [ "$attempts" -lt 5 ]; do
  foundation_loaded=$("$real_tmux" -S "$socket_path" \
    show-options -gqv @dotfiles_foundation_loaded 2>/dev/null || :)
  [ "$foundation_loaded" = 1 ] && break
  attempts=$((attempts + 1))
  sleep 1
done
assert_equal 1 "$foundation_loaded" "fresh foundation marker"

actual_platform=$("$real_tmux" -S "$socket_path" \
  show-options -gqv @dotfiles_platform 2>/dev/null || :)
assert_equal "$expected_platform" "$actual_platform" "fresh platform marker"

passthrough=$("$real_tmux" -S "$socket_path" \
  show-options -wgqv allow-passthrough 2>/dev/null) \
  || fail "could not read global allow-passthrough"
assert_equal on "$passthrough" "fresh global allow-passthrough"

root_bindings=$(
  "$real_tmux" -S "$socket_path" list-keys -T root 2>/dev/null
) || fail "could not read root key bindings"
# Parse the standard output so this also works with tmux 3.6.
m_q_binding=$(printf '%s\n' "$root_bindings" | sed -n \
  's/^bind-key[[:space:]][[:space:]]*-T[[:space:]][[:space:]]*root[[:space:]][[:space:]]*M-q[[:space:]][[:space:]]*//p')
[ -n "$m_q_binding" ] || fail "root M-q binding is missing"
assert_contains 'confirm-before' "$m_q_binding" \
  "root M-q uses confirm-before"
assert_contains 'Kill pane #P? (y/n)' "$m_q_binding" \
  "root M-q prompt"
assert_contains 'kill-pane' "$m_q_binding" \
  "root M-q command"

prefix_bindings=$(
  "$real_tmux" -S "$socket_path" list-keys -T prefix 2>/dev/null
) || fail "could not read prefix key bindings"
prefix_key_names=$(printf '%s\n' "$prefix_bindings" | awk '
  $1 == "bind-key" {
    table_flag = ($2 == "-r" ? 3 : 2)
    if ($table_flag == "-T" && $(table_flag + 1) == "prefix")
      print ":" $(table_flag + 2) ":"
  }')
case $prefix_key_names in
  *':x:'*) fail "prefix x must remain unbound" ;;
esac

test_window=$(
  "$real_tmux" -S "$socket_path" list-windows \
    -t '=terminal-stack-fresh-start' -F '#{window_id}'
) || fail "could not resolve private test window"
[ -n "$test_window" ] || fail "private test window id is empty"

"$real_tmux" -S "$socket_path" split-window -d -t "$test_window" \
  || fail "could not create second private pane"
pane_count=$(
  "$real_tmux" -S "$socket_path" display-message \
    -p -t "$test_window" '#{window_panes}'
) || fail "could not count private panes before confirmation checks"
assert_equal 2 "$pane_count" "private pane setup"

control_fifo=$test_root/control.fifo
control_stdout=$test_root/control.stdout
control_stderr=$test_root/control.stderr
mkfifo "$control_fifo" || fail "could not create control-client FIFO"

"$real_tmux" -C -S "$socket_path" \
  attach-session -t '=terminal-stack-fresh-start' \
  <"$control_fifo" >"$control_stdout" 2>"$control_stderr" &
control_pid=$!
exec 3>"$control_fifo"
control_input_open=1

control_client=
attempts=0
while [ "$attempts" -lt 5 ]; do
  control_client=$(
    "$real_tmux" -S "$socket_path" list-clients \
      -F '#{client_name}' 2>/dev/null | sed -n '1p'
  )
  [ -n "$control_client" ] && break
  attempts=$((attempts + 1))
  sleep 1
done
if [ -z "$control_client" ]; then
  sed 's/^/      /' "$control_stderr" >&2
  fail "private control client did not attach"
fi

"$real_tmux" -S "$socket_path" send-keys \
  -K -c "$control_client" M-q \
  || fail "could not trigger private M-q cancellation prompt"
sleep 1
"$real_tmux" -S "$socket_path" send-keys \
  -K -c "$control_client" n \
  || fail "could not reject private M-q prompt"
sleep 1
pane_count=$(
  "$real_tmux" -S "$socket_path" display-message \
    -p -t "$test_window" '#{window_panes}'
) || fail "could not count private panes after cancellation"
assert_equal 2 "$pane_count" "M-q cancellation preserves pane"

"$real_tmux" -S "$socket_path" send-keys \
  -K -c "$control_client" M-q \
  || fail "could not trigger private M-q confirmation prompt"
sleep 1
"$real_tmux" -S "$socket_path" send-keys \
  -K -c "$control_client" y \
  || fail "could not accept private M-q prompt"

pane_count=
attempts=0
while [ "$attempts" -lt 5 ]; do
  pane_count=$(
    "$real_tmux" -S "$socket_path" display-message \
      -p -t "$test_window" '#{window_panes}' 2>/dev/null || :
  )
  [ "$pane_count" = 1 ] && break
  attempts=$((attempts + 1))
  sleep 1
done
assert_equal 1 "$pane_count" "M-q confirmation kills pane"

"$real_tmux" -S "$socket_path" detach-client -t "$control_client" \
  || fail "could not detach private control client"
exec 3>&-
control_input_open=0
if ! wait "$control_pid"; then
  sed 's/^/      /' "$control_stderr" >&2
  fail "private control client exited unsuccessfully"
fi
control_pid=

"$real_tmux" -S "$socket_path" kill-server \
  || fail "fresh private tmux server did not stop"
case "$socket_path" in
  "$test_root"/tmux.sock)
    rm -f "$socket_path"
    ;;
  *)
    fail "refusing to remove unexpected tmux socket: $socket_path"
    ;;
esac
[ ! -e "$socket_path" ] \
  || fail "fresh private tmux socket remained after shutdown"
socket_path=

pass "tmux fresh-start foundation and pane confirmation"
