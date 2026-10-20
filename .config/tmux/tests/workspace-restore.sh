#!/bin/sh
set -eu
unset TMUX TMUX_PANE
SHELL=/bin/sh
export SHELL

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

assert_equal() {
  expected=$1
  actual=$2
  label=$3
  [ "$expected" = "$actual" ] || fail "$label: expected <$expected>, got <$actual>"
}

assert_contains() {
  needle=$1
  file=$2
  label=$3
  grep -F "$needle" "$file" >/dev/null 2>&1 || fail "$label: missing <$needle>"
}

script_dir=$(CDPATH='' cd -P "$(dirname "$0")" && pwd -P)
workspace=$script_dir/../scripts/workspace
real_tmux=$(command -v tmux) || fail "tmux is required"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-workspace-restore.XXXXXX") \
  || fail "could not create test root"
socket=$test_root/tmux.sock
state=$test_root/state
runtime=$test_root/runtime
stdout=$test_root/stdout
stderr=$test_root/stderr
before=$test_root/before
after=$test_root/after
status=0

cleanup() {
  "$real_tmux" -S "$socket" kill-server >/dev/null 2>&1 || :
  case $test_root in
    "${TMPDIR:-/tmp}"/dotfiles-workspace-restore.*) rm -rf "$test_root" ;;
    *) printf 'refusing cleanup: %s\n' "$test_root" >&2 ;;
  esac
}
trap cleanup 0 HUP INT TERM

run_workspace() {
  set +e
  HOME=$test_root/home \
    SHELL=/bin/sh \
    XDG_STATE_HOME=$state \
    XDG_RUNTIME_DIR=$runtime \
    TMUX_WORKSPACE_TESTING=1 \
    TMUX_WORKSPACE_SOCKET=$socket \
    "$workspace" "$@" >"$stdout" 2>"$stderr"
  status=$?
  set -e
}

run_workspace_missing_executable() {
  missing_executable=$1
  shift
  set +e
  HOME=$test_root/home \
    SHELL=/bin/sh \
    XDG_STATE_HOME=$state \
    XDG_RUNTIME_DIR=$runtime \
    TMUX_WORKSPACE_TESTING=1 \
    TMUX_WORKSPACE_SOCKET=$socket \
    TMUX_WORKSPACE_TEST_MISSING_EXECUTABLE=$missing_executable \
    "$workspace" "$@" >"$stdout" 2>"$stderr"
  status=$?
  set -e
}

run_codex_hook() {
  hook_pane=$1
  hook_payload=$2
  set +e
  printf '%s\n' "$hook_payload" |
    HOME=$test_root/home \
      SHELL=/bin/sh \
      XDG_STATE_HOME=$state \
      XDG_RUNTIME_DIR=$runtime \
      TMUX_WORKSPACE_TESTING=1 \
      TMUX_WORKSPACE_SOCKET=$socket \
      TMUX_PANE=$hook_pane \
      "$workspace" codex-hook >"$stdout" 2>"$stderr"
  status=$?
  set -e
}

private_tmux() {
  "$real_tmux" -S "$socket" "$@"
}

stop_private_server() {
  server_pid=$(private_tmux display-message -p '#{pid}') \
    || fail "could not read private tmux server PID"
  private_tmux kill-server >/dev/null 2>&1 || :
  wait_attempt=0
  while kill -0 "$server_pid" >/dev/null 2>&1 && [ "$wait_attempt" -lt 200 ]; do
    sleep 0.01
    wait_attempt=$((wait_attempt + 1))
  done
  if kill -0 "$server_pid" >/dev/null 2>&1; then
    fail "private tmux server did not exit"
  fi
  if [ -S "$socket" ]; then
    rm -f "$socket"
  fi
}

wait_for_supervisor_lock_owner() {
  expected_supervisor_pid=$1
  supervisor_lock_label=$2
  supervisor_owner_file=$runtime/dotfiles-tmux/supervisor.lock/owner
  wait_attempt=0
  while [ "$wait_attempt" -lt 200 ]; do
    supervisor_owner=$(sed -n '1p' "$supervisor_owner_file" 2>/dev/null || :)
    supervisor_sleeper_pid=$(
      ps -eo pid=,ppid=,comm= 2>/dev/null | awk \
        -v parent="$expected_supervisor_pid" \
        '$2 == parent && $3 == "sleep" { print $1; exit }'
    )
    if [ "$supervisor_owner" = "$expected_supervisor_pid" ] \
      && [ -n "$supervisor_sleeper_pid" ]; then
      return 0
    fi
    kill -0 "$expected_supervisor_pid" >/dev/null 2>&1 || break
    sleep 0.01
    wait_attempt=$((wait_attempt + 1))
  done
  fail "$supervisor_lock_label"
}

write_generation_names() {
  generation_names_file=$1
  find "$state/dotfiles/tmux/snapshots" -mindepth 1 -maxdepth 1 -type d \
    ! -name '.staging-*' -exec basename {} \; | sort >"$generation_names_file"
}

assert_no_checkpoint_residue() {
  checkpoint_residue_label=$1
  [ ! -e "$runtime/dotfiles-tmux/checkpoint.lock" ] \
    || fail "$checkpoint_residue_label checkpoint lock remained"
  checkpoint_staging_count=$(
    find "$state/dotfiles/tmux/snapshots" -mindepth 1 -maxdepth 1 -type d \
      -name '.staging-*' | wc -l | tr -d '[:space:]'
  )
  assert_equal 0 "$checkpoint_staging_count" \
    "$checkpoint_residue_label staging generation count"
}

summarize() {
  private_tmux list-sessions \
    -F 's|#{session_name}|#{session_group}|#{session_path}|#{active_window_index}' |
    sort
  private_tmux list-windows -a \
    -F 'w|#{session_name}|#{window_index}|#{window_name}|#{window_zoomed_flag}|#{window_last_flag}' |
    sort
  private_tmux list-panes -a \
    -F 'p|#{session_name}|#{window_index}|#{pane_index}|#{pane_current_path}|#{pane_title}|#{pane_active}|#{pane_left}|#{pane_top}|#{pane_width}|#{pane_height}' |
    sort
}

mkdir -p "$test_root/home" "$test_root/projects/alpha" "$test_root/projects/beta"
# These editor fixtures model the configured stack, including restored servers.
cat "$script_dir/../conf/options.conf" >"$test_root/home/.tmux.conf"
printf '%s\n' 'set-option -g @dotfiles_foundation_loaded 1' >>"$test_root/home/.tmux.conf"
"$real_tmux" -f "$test_root/home/.tmux.conf" -S "$socket" \
  new-session -d -s alpha -c "$test_root/projects/alpha" -n editor
private_tmux split-window -d -t '=alpha:1' -c "$test_root/projects/beta"
private_tmux select-layout -t '=alpha:1' even-horizontal
private_tmux resize-pane -t '=alpha:1.1' -x 29
private_tmux select-pane -t '=alpha:1.1' -T left
private_tmux select-pane -t '=alpha:1.2' -T right
private_tmux new-window -d -t '=alpha:2' -n shell -c "$test_root/projects/beta"
private_tmux select-pane -t '=alpha:2.1' -T secondary
private_tmux new-session -d -s mirror -t '=alpha'
private_tmux new-session -d -s linked -c "$test_root/projects/beta" -n local
private_tmux select-pane -t '=linked:1.1' -T local
private_tmux link-window -d -s '=alpha:2' -t '=linked:2'
private_tmux select-pane -t '=alpha:1.2'
private_tmux resize-pane -Z -t '=alpha:1.2'
private_tmux select-window -t '=alpha:1'
private_tmux select-window -t '=alpha:2'
private_tmux select-window -t '=mirror:1'
private_tmux select-window -t '=mirror:2'
private_tmux select-window -t '=linked:2'
private_tmux select-window -t '=linked:1'

pin_helper=$script_dir/../scripts/location-pins
session_pins() {
  pin_action=$1
  pin_name=$2
  pin_session=$(private_tmux display-message -p -t "=$pin_name:" '#{session_id}')
  pin_pid=$(private_tmux display-message -p -t "=$pin_name:" '#{pid}')
  "$pin_helper" "$pin_action" --socket "$socket" --session "$pin_session" --server-pid "$pin_pid"
}
jq -cn --arg path "$test_root/雪 #{session_name} quote'" '{path:$path,line:12,col:3}' \
  | session_pins add alpha >"$test_root/alpha-pin"
printf '%s\n' '{"path":"/mirror/location","line":4,"col":0}' \
  | session_pins add mirror >"$test_root/mirror-pin"
# Run the real resolver inside a pane, inheriting its actual TMUX environment.
cat >"$test_root/pin-context.lua" <<'LUA'
vim.opt.runtimepath:prepend(vim.env.DOTFILES_NVIM_ROOT)
require("navigation.location_pins").setup()
local ctx, err = require("navigation.location_pin_context").resolve()
local pins = ctx and require("navigation.location_pin_store").list(ctx) or nil
vim.fn.writefile({ vim.json.encode({ context = ctx, error = err, pins = pins }) }, vim.env.PIN_CONTEXT_OUTPUT)
LUA
probe_pin_context() {
  probe_target=$1
  probe_output=$2
  probe_command=$(jq -nr \
    --arg home "$test_root/home" \
    --arg nvim_root "$(CDPATH='' cd "$script_dir/../../nvim" && pwd -P)" \
    --arg runtime "${XDG_RUNTIME_DIR:-$runtime}" \
    --arg output "$probe_output" --arg script "$test_root/pin-context.lua" '
      ["env", "HOME="+$home, "XDG_STATE_HOME="+$home+"/state",
       "XDG_CACHE_HOME="+$home+"/cache", "XDG_RUNTIME_DIR="+$runtime,
       "DOTFILES_NVIM_ROOT="+$nvim_root, "PIN_CONTEXT_OUTPUT="+$output,
       "nvim", "--clean", "--headless", "-u", "NONE", "-i", "NONE", "-l", $script] | @sh')
  private_tmux send-keys -t "$probe_target" -l "$probe_command"
  private_tmux send-keys -t "$probe_target" Enter
  probe_attempt=0
  while [ "$probe_attempt" -lt 500 ]; do
    probe_process=$(private_tmux display-message -p -t "$probe_target" '#{pane_current_command}')
    if [ -s "$probe_output" ] && [ "$probe_process" = sh ]; then return 0; fi
    sleep 0.01
    probe_attempt=$((probe_attempt + 1))
  done
  private_tmux capture-pane -p -t "$probe_target" >&2
  fail 'pin context probe did not finish in the actual pane'
}
# Give two linked panes distinct real originating sessions before checkpointing.
private_tmux respawn-pane -k -t '=alpha:1.1' /bin/sh
private_tmux respawn-pane -k -t '=mirror:1.2' /bin/sh
private_tmux select-pane -t '=alpha:1.1' -T left
private_tmux select-pane -t '=alpha:1.2' -T right
probe_pin_context '=alpha:1.1' "$test_root/alpha-context.before"
probe_pin_context '=mirror:1.2' "$test_root/mirror-context.before"
session_pins list alpha >"$test_root/alpha-pins.before"
session_pins list mirror >"$test_root/mirror-pins.before"
summarize >"$before"
run_workspace save
[ "$status" -eq 0 ] || sed -n '1,120p' "$stderr" >&2
assert_equal 0 "$status" "round-trip checkpoint"
generation=$(cat "$state/dotfiles/tmux/current")
stop_private_server

run_workspace restore
[ "$status" -eq 0 ] || sed -n '1,120p' "$stderr" >&2
assert_equal 0 "$status" "round-trip restore"
summarize >"$after"
if ! cmp -s "$before" "$after"; then
  diff -u "$before" "$after" >&2 || :
  fail "round-trip topology"
fi

session_pins list alpha >"$test_root/alpha-pins.after"
session_pins list mirror >"$test_root/mirror-pins.after"
cmp "$test_root/alpha-pins.before" "$test_root/alpha-pins.after" || fail 'alpha line-pin round trip'
cmp "$test_root/mirror-pins.before" "$test_root/mirror-pins.after" || fail 'grouped-session line-pin round trip'
assert_equal 0 "$(session_pins list linked | jq '.pins|length')" 'empty linked session pins'
pass 'workspace restores independent line pins to mapped sessions'
probe_pin_context '=alpha:1.1' "$test_root/alpha-context.after"
probe_pin_context '=mirror:1.2' "$test_root/mirror-context.after"
for probe_name in alpha mirror; do
  expected_session=$(private_tmux display-message -p -t "=$probe_name:" '#{session_id}')
  jq -e --arg session "$expected_session" --slurpfile expected "$test_root/$probe_name-pins.before" '
    .context.session == $session and .pins == $expected[0].pins
  ' "$test_root/$probe_name-context.after" >/dev/null \
    || { cat "$test_root/$probe_name-context.after" >&2; fail 'restored pane lost its explicit line-pin session'; }
done
pass 'real restored editors retain independent originating sessions in linked panes'

assert_equal "$generation" \
  "$(private_tmux show-options -gqv @dotfiles_workspace_generation)" \
  "restored generation marker"
assert_equal alpha "$(private_tmux display-message -p -t '=mirror:' '#{session_group}')" \
  "restored group name"
alpha_window=$(private_tmux display-message -p -t '=alpha:2' '#{window_id}')
linked_window=$(private_tmux display-message -p -t '=linked:2' '#{window_id}')
assert_equal "$alpha_window" "$linked_window" "restored linked window identity"

counts_before=$(printf '%s|%s|%s' \
  "$(private_tmux list-sessions -F '#{session_id}' | wc -l | tr -d '[:space:]')" \
  "$(private_tmux list-windows -a -F '#{window_id}' | sort -u | wc -l | tr -d '[:space:]')" \
  "$(private_tmux list-panes -a -F '#{pane_id}' | sort -u | wc -l | tr -d '[:space:]')")
run_workspace restore
assert_equal 0 "$status" "idempotent restore"
counts_after=$(printf '%s|%s|%s' \
  "$(private_tmux list-sessions -F '#{session_id}' | wc -l | tr -d '[:space:]')" \
  "$(private_tmux list-windows -a -F '#{window_id}' | sort -u | wc -l | tr -d '[:space:]')" \
  "$(private_tmux list-panes -a -F '#{pane_id}' | sort -u | wc -l | tr -d '[:space:]')")
assert_equal "$counts_before" "$counts_after" "idempotent topology counts"

# A detached layout round trip misses windows left at a fixed restore size.
# Real control-mode clients exercise attachment and subsequent terminal resizes.
python3 - "$real_tmux" "$socket" <<'PY'
import subprocess
import sys
import time

tmux_command = [sys.argv[1], "-S", sys.argv[2]]


def tmux(*args):
    return subprocess.check_output([*tmux_command, *args], text=True).strip()


for session in ("alpha", "linked"):
    client = subprocess.Popen(
        [*tmux_command, "-C", "attach-session", "-t", "=" + session],
        stdin=subprocess.PIPE,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        for size in ("94x42", "112x48", "70x30"):
            client.stdin.write("refresh-client -C " + size + "\n")
            client.stdin.flush()
            deadline = time.monotonic() + 5
            while True:
                windows = tmux(
                    "list-windows", "-t", "=" + session,
                    "-F", "#{window_index}:#{window_width}x#{window_height}",
                ).splitlines()
                if windows and all(window.split(":", 1)[1] == size for window in windows):
                    break
                if client.poll() is not None:
                    raise SystemExit("not ok - resize client exited: " + client.stderr.read())
                if time.monotonic() >= deadline:
                    raise SystemExit(
                        "not ok - restored windows must follow client size " + size
                        + " in " + session + ": " + ", ".join(windows)
                    )
                time.sleep(0.02)
    finally:
        client.terminate()
        client.communicate(timeout=5)
PY
pass 'restored windows follow attached clients as they grow and shrink'

stop_private_server
legacy_dir=$state/dotfiles/tmux/snapshots/legacy-no-pins
mkdir -m 700 "$legacy_dir"
jq 'del(.sessions[].line_pins, .panes[].line_pin_session_key)' "$state/dotfiles/tmux/snapshots/$generation/snapshot.json" >"$legacy_dir/snapshot.json"
chmod 600 "$legacy_dir/snapshot.json"
printf '%s\n' legacy-no-pins >"$state/dotfiles/tmux/current"
run_workspace restore
assert_equal 0 "$status" 'legacy snapshot without line pins restores'
assert_equal 0 "$(session_pins list alpha | jq '.pins|length')" 'legacy snapshot has empty pins'
probe_pin_context '=alpha:1.1' "$test_root/legacy-context"
legacy_origin=$(private_tmux display-message -p -t '=alpha:' '#{session_id}')
jq -e --arg origin "$legacy_origin" '.context.session == $origin and .pins == []' \
  "$test_root/legacy-context" >/dev/null || fail 'legacy pane lacks a valid explicit origin'
rm -rf "$legacy_dir"
pass 'legacy workspace snapshots remain readable'

stop_private_server
missing_generation=missing-cwd
missing_generation_dir=$state/dotfiles/tmux/snapshots/$missing_generation
mkdir -p "$missing_generation_dir"
chmod 0700 "$missing_generation_dir"
jq --arg path "$test_root/projects/removed" '
  (.sessions[].path) = $path
  | (.panes[].path) = $path
' "$state/dotfiles/tmux/snapshots/$generation/snapshot.json" \
  >"$missing_generation_dir/snapshot.json"
chmod 0600 "$missing_generation_dir/snapshot.json"
printf '%s\n' "$missing_generation" >"$state/dotfiles/tmux/current"
run_workspace restore
[ "$status" -eq 0 ] || sed -n '1,120p' "$stderr" >&2
assert_equal 0 "$status" "missing working directory fallback restore"
assert_equal "$test_root/home" \
  "$(private_tmux list-panes -a -F '#{pane_current_path}' | sort -u)" \
  "missing working directories fall back to HOME"
assert_contains 'a saved working directory is missing; HOME was used' \
  "$state/dotfiles/tmux/last-warning" \
  "missing working directory warning"
stop_private_server
rm -rf "$missing_generation_dir"

corrupt_generation=zz-corrupt
mkdir -p "$state/dotfiles/tmux/snapshots/$corrupt_generation"
chmod 0700 "$state/dotfiles/tmux/snapshots/$corrupt_generation"
printf '%s\n' '{' >"$state/dotfiles/tmux/snapshots/$corrupt_generation/snapshot.json"
chmod 0600 "$state/dotfiles/tmux/snapshots/$corrupt_generation/snapshot.json"
printf '%s\n' "$corrupt_generation" >"$state/dotfiles/tmux/current"
run_workspace restore
assert_equal 0 "$status" "corrupt-current fallback restore"
assert_equal "$generation" \
  "$(private_tmux show-options -gqv @dotfiles_workspace_generation)" \
  "fallback generation marker"

stop_private_server
"$real_tmux" -f "$test_root/home/.tmux.conf" -S "$socket" \
  new-session -d -s local-only
private_tmux rename-window -t '=local-only:1' local
private_tmux set-option -w -t '=local-only:1' automatic-rename off
printf '%s\n' '{"path":"/live/keep","line":2,"col":0}' \
  | session_pins add local-only >"$test_root/live-pin"
session_pins list local-only >"$test_root/live-pins.before"
session_count_before=$(private_tmux list-sessions -F '#{session_id}' | wc -l | tr -d '[:space:]')
run_workspace restore
assert_equal 0 "$status" "live server adoption"
session_pins list local-only >"$test_root/live-pins.after"
cmp "$test_root/live-pins.before" "$test_root/live-pins.after" || fail 'adoption overwrote live pins'
session_count_after=$(private_tmux list-sessions -F '#{session_id}' | wc -l | tr -d '[:space:]')
assert_equal "$session_count_before" "$session_count_after" "adoption session count"
assert_equal 1 "$(private_tmux show-options -gqv @dotfiles_workspace_adopted)" \
  "adoption marker"

supervisor_stdout=$test_root/supervisor.stdout
supervisor_stderr=$test_root/supervisor.stderr
HOME=$test_root/home \
  SHELL=/bin/sh \
  XDG_STATE_HOME=$state \
  XDG_RUNTIME_DIR=$runtime \
  TMUX_WORKSPACE_TESTING=1 \
  TMUX_WORKSPACE_SOCKET=$socket \
  TMUX_WORKSPACE_INTERVAL=1 \
  "$workspace" supervise >"$supervisor_stdout" 2>"$supervisor_stderr" &
supervisor_pid=$!
wait_attempt=0
while [ ! -f "$runtime/dotfiles-tmux/ready" ] && [ "$wait_attempt" -lt 200 ]; do
  sleep 0.01
  wait_attempt=$((wait_attempt + 1))
done
[ -f "$runtime/dotfiles-tmux/ready" ] || fail "supervisor ready marker"
kill -0 "$supervisor_pid" >/dev/null 2>&1 || fail "supervisor exited before ready"
wait_for_supervisor_lock_owner "$supervisor_pid" \
  "live-server supervisor lock ownership"
summarize >"$test_root/ready-summary"
sleep 2
summarize >"$test_root/periodic-summary"
if ! cmp -s "$test_root/ready-summary" "$test_root/periodic-summary"; then
  diff -u "$test_root/ready-summary" "$test_root/periodic-summary" >&2 || :
  fail "periodic checkpoint changed tmux topology"
fi
generation_before_stop=$(cat "$state/dotfiles/tmux/current")
if ! kill -0 "$supervisor_pid" >/dev/null 2>&1; then
  sed -n '1,120p' "$supervisor_stderr" >&2
  fail "supervisor exited before clean stop"
fi
kill -TERM "$supervisor_pid"
wait "$supervisor_pid"
generation_after_stop=$(cat "$state/dotfiles/tmux/current")
[ "$generation_before_stop" != "$generation_after_stop" ] \
  || fail "supervisor final checkpoint did not advance generation"
[ ! -e "$runtime/dotfiles-tmux/supervisor.lock" ] \
  || fail "supervisor lock remained after clean stop"

private_tmux set-option -s exit-empty off
private_tmux kill-session -t '=local-only'
assert_equal off "$(private_tmux show-options -sv exit-empty)" \
  "zero-session server exit-empty option"
assert_equal '' "$(private_tmux list-sessions -F '#{session_id}')" \
  "reachable zero-session server inventory"

zero_generation_before=$(cat "$state/dotfiles/tmux/current")
zero_manifest=$state/dotfiles/tmux/snapshots/$zero_generation_before/snapshot.json
zero_pointer_before=$test_root/zero-current.before
zero_manifest_before=$test_root/zero-manifest.before
zero_ready_before=$test_root/zero-ready.before
zero_generation_names_before=$test_root/zero-generation-names.before
zero_generation_names_after=$test_root/zero-generation-names.after
cp "$state/dotfiles/tmux/current" "$zero_pointer_before"
cp "$zero_manifest" "$zero_manifest_before"
cp "$runtime/dotfiles-tmux/ready" "$zero_ready_before"
write_generation_names "$zero_generation_names_before"

zero_supervisor_stdout=$test_root/zero-supervisor.stdout
zero_supervisor_stderr=$test_root/zero-supervisor.stderr
HOME=$test_root/home \
  SHELL=/bin/sh \
  XDG_STATE_HOME=$state \
  XDG_RUNTIME_DIR=$runtime \
  TMUX_WORKSPACE_TESTING=1 \
  TMUX_WORKSPACE_SOCKET=$socket \
  TMUX_WORKSPACE_INTERVAL=300 \
  "$workspace" supervise \
  >"$zero_supervisor_stdout" \
  2>"$zero_supervisor_stderr" &
zero_supervisor_pid=$!
wait_for_supervisor_lock_owner "$zero_supervisor_pid" \
  "zero-session supervisor lock ownership"
kill -0 "$zero_supervisor_pid" >/dev/null 2>&1 \
  || fail "zero-session supervisor exited before final checkpoint"
kill -TERM "$zero_supervisor_pid"
wait "$zero_supervisor_pid"

cmp -s "$zero_pointer_before" "$state/dotfiles/tmux/current" \
  || fail "zero-session final checkpoint changed current pointer bytes"
cmp -s "$zero_manifest_before" "$zero_manifest" \
  || fail "zero-session final checkpoint changed manifest bytes"
cmp -s "$zero_ready_before" "$runtime/dotfiles-tmux/ready" \
  || fail "zero-session final checkpoint changed ready marker bytes"
write_generation_names "$zero_generation_names_after"
cmp -s "$zero_generation_names_before" "$zero_generation_names_after" \
  || fail "zero-session final checkpoint changed retained generation names"
assert_no_checkpoint_residue "zero-session final checkpoint"
[ ! -e "$runtime/dotfiles-tmux/supervisor.lock" ] \
  || fail "zero-session supervisor lock remained after stop"

stop_private_server
run_workspace restore
assert_equal 0 "$status" "collision fixture restore"

collision_generation=$(cat "$state/dotfiles/tmux/current")
collision_pointer_before=$test_root/collision-current.before
collision_ready_before=$test_root/collision-ready.before
collision_generation_names_before=$test_root/collision-generation-names.before
collision_generation_names_after=$test_root/collision-generation-names.after
cp "$state/dotfiles/tmux/current" "$collision_pointer_before"
cp "$runtime/dotfiles-tmux/ready" "$collision_ready_before"
write_generation_names "$collision_generation_names_before"

collision_supervisor_stdout=$test_root/collision-supervisor.stdout
collision_supervisor_stderr=$test_root/collision-supervisor.stderr
HOME=$test_root/home \
  SHELL=/bin/sh \
  XDG_STATE_HOME=$state \
  XDG_RUNTIME_DIR=$runtime \
  TMUX_WORKSPACE_TESTING=1 \
  TMUX_WORKSPACE_SOCKET=$socket \
  TMUX_WORKSPACE_INTERVAL=300 \
  TMUX_WORKSPACE_TEST_GENERATION=$collision_generation \
  "$workspace" supervise \
  >"$collision_supervisor_stdout" \
  2>"$collision_supervisor_stderr" &
collision_supervisor_pid=$!
wait_for_supervisor_lock_owner "$collision_supervisor_pid" \
  "collision supervisor lock ownership"
kill -TERM "$collision_supervisor_pid"
set +e
wait "$collision_supervisor_pid"
collision_supervisor_status=$?
set -e
[ "$collision_supervisor_status" -ne 0 ] \
  || fail "final-save generation collision exited zero"
assert_contains "snapshot generation already exists: $collision_generation" \
  "$collision_supervisor_stderr" \
  "final-save generation collision diagnostic"
cmp -s "$collision_pointer_before" "$state/dotfiles/tmux/current" \
  || fail "final-save generation collision changed current pointer bytes"
cmp -s "$collision_ready_before" "$runtime/dotfiles-tmux/ready" \
  || fail "final-save generation collision changed ready marker bytes"
write_generation_names "$collision_generation_names_after"
cmp -s "$collision_generation_names_before" "$collision_generation_names_after" \
  || fail "final-save generation collision changed retained generation names"
assert_no_checkpoint_residue "final-save generation collision"
[ ! -e "$runtime/dotfiles-tmux/supervisor.lock" ] \
  || fail "collision supervisor lock remained after failure"

periodic_pointer_before=$test_root/periodic-current.before
periodic_generation=$(cat "$state/dotfiles/tmux/current")
periodic_manifest=$state/dotfiles/tmux/snapshots/$periodic_generation/snapshot.json
periodic_manifest_before=$test_root/periodic-manifest.before
periodic_ready_before=$test_root/periodic-ready.before
periodic_generation_names_before=$test_root/periodic-generation-names.before
periodic_generation_names_after=$test_root/periodic-generation-names.after
cp "$state/dotfiles/tmux/current" "$periodic_pointer_before"
cp "$periodic_manifest" "$periodic_manifest_before"
cp "$runtime/dotfiles-tmux/ready" "$periodic_ready_before"
write_generation_names "$periodic_generation_names_before"
periodic_sequence_before=$(sed -n '1p' \
  "$runtime/dotfiles-tmux/generation-sequence" 2>/dev/null || printf '0')

periodic_supervisor_stdout=$test_root/periodic-supervisor.stdout
periodic_supervisor_stderr=$test_root/periodic-supervisor.stderr
HOME=$test_root/home \
  SHELL=/bin/sh \
  XDG_STATE_HOME=$state \
  XDG_RUNTIME_DIR=$runtime \
  TMUX_WORKSPACE_TESTING=1 \
  TMUX_WORKSPACE_SOCKET=$socket \
  TMUX_WORKSPACE_INTERVAL=5 \
  "$workspace" supervise \
  >"$periodic_supervisor_stdout" \
  2>"$periodic_supervisor_stderr" &
periodic_supervisor_pid=$!
wait_for_supervisor_lock_owner "$periodic_supervisor_pid" \
  "periodic supervisor lock ownership"
stop_private_server

wait_attempt=0
periodic_sequence_after=$periodic_sequence_before
while [ "$periodic_sequence_after" = "$periodic_sequence_before" ] \
  && [ "$wait_attempt" -lt 800 ]; do
  kill -0 "$periodic_supervisor_pid" >/dev/null 2>&1 || break
  sleep 0.01
  periodic_sequence_after=$(sed -n '1p' \
    "$runtime/dotfiles-tmux/generation-sequence" 2>/dev/null || printf '0')
  wait_attempt=$((wait_attempt + 1))
done
[ "$periodic_sequence_after" != "$periodic_sequence_before" ] \
  || fail "unavailable-server periodic checkpoint was not attempted"
wait_attempt=0
while [ -e "$runtime/dotfiles-tmux/checkpoint.lock" ] \
  && [ "$wait_attempt" -lt 200 ]; do
  sleep 0.01
  wait_attempt=$((wait_attempt + 1))
done
kill -0 "$periodic_supervisor_pid" >/dev/null 2>&1 \
  || fail "unavailable-server supervisor exited after periodic checkpoint"
cmp -s "$periodic_pointer_before" "$state/dotfiles/tmux/current" \
  || fail "unavailable-server periodic checkpoint changed current pointer bytes"
cmp -s "$periodic_manifest_before" "$periodic_manifest" \
  || fail "unavailable-server periodic checkpoint changed manifest bytes"
cmp -s "$periodic_ready_before" "$runtime/dotfiles-tmux/ready" \
  || fail "unavailable-server periodic checkpoint changed ready marker bytes"
write_generation_names "$periodic_generation_names_after"
cmp -s "$periodic_generation_names_before" "$periodic_generation_names_after" \
  || fail "unavailable-server periodic checkpoint changed retained generation names"
assert_no_checkpoint_residue "unavailable-server periodic checkpoint"

kill -TERM "$periodic_supervisor_pid"
wait "$periodic_supervisor_pid"
cmp -s "$periodic_pointer_before" "$state/dotfiles/tmux/current" \
  || fail "unavailable-server final checkpoint changed current pointer bytes"
cmp -s "$periodic_manifest_before" "$periodic_manifest" \
  || fail "unavailable-server final checkpoint changed manifest bytes"
cmp -s "$periodic_ready_before" "$runtime/dotfiles-tmux/ready" \
  || fail "unavailable-server final checkpoint changed ready marker bytes"
write_generation_names "$periodic_generation_names_after"
cmp -s "$periodic_generation_names_before" "$periodic_generation_names_after" \
  || fail "unavailable-server final checkpoint changed retained generation names"
assert_no_checkpoint_residue "unavailable-server final checkpoint"
[ ! -e "$runtime/dotfiles-tmux/supervisor.lock" ] \
  || fail "unavailable-server supervisor lock remained after stop"

rm -f "$runtime/dotfiles-tmux/ready"
# Pause the winning mkdir before its owner PID is published. A second ensure
# must wait for this initializing lock, never reclaim it and restore in parallel.
ensure_bin=$test_root/ensure-bin
mkdir -p "$ensure_bin"
ENSURE_REAL_MKDIR=$(command -v gnumkdir || command -v gmkdir || command -v mkdir)
ENSURE_REAL_SLEEP=$(command -v sleep)
ENSURE_BARRIER=$test_root/ensure-barrier
ENSURE_LOCK=$runtime/dotfiles-tmux/restore.lock
export ENSURE_REAL_MKDIR ENSURE_REAL_SLEEP ENSURE_BARRIER ENSURE_LOCK
cat >"$ensure_bin/mkdir" <<'SHIM'
#!/bin/sh
"$ENSURE_REAL_MKDIR" "$@"
result=$?
if [ "$result" -eq 0 ] && [ "$#" -eq 1 ] && [ "$1" = "$ENSURE_LOCK" ] \
  && [ "${ENSURE_OWNER:-0}" = 1 ]; then
  : >"$ENSURE_BARRIER.started"
  attempt=0
  while [ ! -f "$ENSURE_BARRIER.release" ] && [ "$attempt" -lt 1000 ]; do
    "$ENSURE_REAL_SLEEP" 0.01
    attempt=$((attempt + 1))
  done
  [ -f "$ENSURE_BARRIER.release" ] || exit 1
fi
exit "$result"
SHIM
cat >"$ensure_bin/sleep" <<'SHIM'
#!/bin/sh
if [ "$#" -eq 1 ] && [ "$1" = 1 ] && [ "${ENSURE_OWNER:-0}" = 0 ]; then
  : >"$ENSURE_BARRIER.waiter"
fi
exec "$ENSURE_REAL_SLEEP" "$@"
SHIM
chmod 755 "$ensure_bin/mkdir" "$ensure_bin/sleep"
ln -s mkdir "$ensure_bin/gnumkdir"
ln -s mkdir "$ensure_bin/gmkdir"
set +e
HOME=$test_root/home SHELL=/bin/sh XDG_STATE_HOME=$state XDG_RUNTIME_DIR=$runtime \
  TMUX_WORKSPACE_TESTING=1 TMUX_WORKSPACE_SOCKET=$socket \
  PATH=$ensure_bin:$PATH ENSURE_OWNER=1 \
  "$workspace" ensure >"$test_root/ensure-one.stdout" 2>"$test_root/ensure-one.stderr" &
ensure_one_pid=$!
barrier_attempt=0
while [ ! -f "$ENSURE_BARRIER.started" ] && [ "$barrier_attempt" -lt 500 ]; do
  sleep 0.01
  barrier_attempt=$((barrier_attempt + 1))
done
HOME=$test_root/home SHELL=/bin/sh XDG_STATE_HOME=$state XDG_RUNTIME_DIR=$runtime \
  TMUX_WORKSPACE_TESTING=1 TMUX_WORKSPACE_SOCKET=$socket \
  PATH=$ensure_bin:$PATH ENSURE_OWNER=0 \
  "$workspace" ensure >"$test_root/ensure-two.stdout" 2>"$test_root/ensure-two.stderr" &
ensure_two_pid=$!
barrier_attempt=0
while [ ! -f "$ENSURE_BARRIER.waiter" ] && [ ! -f "$runtime/dotfiles-tmux/ready" ] \
  && [ "$barrier_attempt" -lt 500 ]; do
  sleep 0.01
  barrier_attempt=$((barrier_attempt + 1))
done
waiter_observed=0
[ ! -f "$ENSURE_BARRIER.waiter" ] || waiter_observed=1
: >"$ENSURE_BARRIER.release"
wait "$ensure_one_pid"
ensure_one_status=$?
wait "$ensure_two_pid"
ensure_two_status=$?
set -e
if [ "$ensure_one_status" -ne 0 ] || [ "$ensure_two_status" -ne 0 ]; then
  cat "$test_root/ensure-one.stderr" "$test_root/ensure-two.stderr" >&2
fi
assert_equal 0 "$ensure_one_status" "first concurrent ensure"
assert_equal 0 "$ensure_two_status" "second concurrent ensure"
assert_equal 1 "$waiter_observed" 'initializing restore lock is not stolen'
[ -f "$runtime/dotfiles-tmux/ready" ] || fail "concurrent ensure ready marker"
assert_equal 1 \
  "$(private_tmux list-sessions -F '#{session_id}' | wc -l | tr -d '[:space:]')" \
  "single restored session after concurrent ensure"
assert_equal "$(cat "$runtime/dotfiles-tmux/ready")" \
  "$(private_tmux show-options -gqv @dotfiles_workspace_generation)" \
  "ready marker matches restored generation"

stop_private_server
shim_directory=$test_root/bin
codex_log_directory=$test_root/codex-logs
mkdir -p "$shim_directory" "$codex_log_directory" \
  "$test_root/home/.config/tmux/scripts"
ln -s "$workspace" "$test_root/home/.config/tmux/scripts/workspace"
# A multicall sleep binary cannot be renamed to codex. Prefer GNU on those hosts.
fixture_sleep=$(command -v gnusleep || command -v sleep)
cp "$fixture_sleep" "$shim_directory/codex"
chmod 0755 "$shim_directory/codex"
PATH=$shim_directory:$PATH
CODEX_TEST_LOG_DIRECTORY=$codex_log_directory
export PATH CODEX_TEST_LOG_DIRECTORY

"$real_tmux" -f "$test_root/home/.tmux.conf" -S "$socket" \
  new-session -d -s codex-work -c "$test_root/projects/alpha" \
  -n conversations 'exec codex 300'
private_tmux split-window -d -t '=codex-work:1' \
  -c "$test_root/projects/alpha" 'exec codex 300'
codex_alpha_pane=$(private_tmux display-message -p -t '=codex-work:1.1' '#{pane_id}')
codex_beta_pane=$(private_tmux display-message -p -t '=codex-work:1.2' '#{pane_id}')
wait_attempt=0
alpha_command=
beta_command=
while [ "$wait_attempt" -lt 200 ]; do
  alpha_command=$(private_tmux display-message -p \
    -t "$codex_alpha_pane" '#{pane_current_command}')
  beta_command=$(private_tmux display-message -p \
    -t "$codex_beta_pane" '#{pane_current_command}')
  [ "$alpha_command" = codex ] && [ "$beta_command" = codex ] && break
  sleep 0.01
  wait_attempt=$((wait_attempt + 1))
done
assert_equal codex \
  "$alpha_command" \
  "alpha pane command"
assert_equal codex \
  "$beta_command" \
  "beta pane command"

alpha_payload='{"session_id":"thr_alpha","transcript_path":"/ignored/a.jsonl","cwd":"/same","hook_event_name":"SessionStart","model":"gpt-5.6-sol","source":"startup"}'
beta_payload='{"session_id":"thr_beta","transcript_path":"/ignored/b.jsonl","cwd":"/same","hook_event_name":"SessionStart","model":"gpt-5.6-sol","source":"resume"}'
run_codex_hook "$codex_alpha_pane" "$alpha_payload"
assert_equal 0 "$status" "alpha SessionStart hook"
[ ! -s "$stdout" ] || fail "SessionStart hook wrote model context"
run_codex_hook "$codex_beta_pane" "$beta_payload"
assert_equal 0 "$status" "beta SessionStart hook"
assert_equal thr_alpha \
  "$(private_tmux show-options -pqv -t "$codex_alpha_pane" @dotfiles_codex_session_id)" \
  "alpha pane exact session"
assert_equal thr_beta \
  "$(private_tmux show-options -pqv -t "$codex_beta_pane" @dotfiles_codex_session_id)" \
  "beta pane exact session"

stale_end='{"session_id":"thr_stale","transcript_path":"/ignored/stale.jsonl","cwd":"/same","hook_event_name":"SessionEnd","model":"gpt-5.6-sol","reason":"other"}'
run_codex_hook "$codex_alpha_pane" "$stale_end"
assert_equal 0 "$status" "stale SessionEnd hook"
assert_equal thr_alpha \
  "$(private_tmux show-options -pqv -t "$codex_alpha_pane" @dotfiles_codex_session_id)" \
  "stale SessionEnd preserves current conversation"
alpha_end='{"session_id":"thr_alpha","transcript_path":"/ignored/a.jsonl","cwd":"/same","hook_event_name":"SessionEnd","model":"gpt-5.6-sol","reason":"other"}'
run_codex_hook "$codex_alpha_pane" "$alpha_end"
assert_equal 0 "$status" "matching SessionEnd hook"
assert_equal '' \
  "$(private_tmux show-options -pqv -t "$codex_alpha_pane" @dotfiles_codex_session_id)" \
  "matching SessionEnd clears identifier"
run_codex_hook "$codex_alpha_pane" "$alpha_payload"
assert_equal 0 "$status" "alpha SessionStart re-registration"

run_workspace save
assert_equal 0 "$status" "Codex metadata checkpoint"
codex_generation=$(cat "$state/dotfiles/tmux/current")
codex_manifest=$state/dotfiles/tmux/snapshots/$codex_generation/snapshot.json
jq -e '
  any(.panes[]; .process.kind == "codex" and .process.codex_session_id == "thr_alpha")
  and any(.panes[]; .process.kind == "codex" and .process.codex_session_id == "thr_beta")
' "$codex_manifest" >/dev/null || fail "distinct same-cwd Codex metadata"

private_tmux set-option -pu -t "$codex_beta_pane" @dotfiles_codex_session_id
run_workspace save
assert_equal 0 "$status" "Codex picker fallback checkpoint"
codex_generation=$(cat "$state/dotfiles/tmux/current")
codex_manifest=$state/dotfiles/tmux/snapshots/$codex_generation/snapshot.json
jq -e '
  any(.panes[]; .process.kind == "codex" and .process.codex_session_id == "thr_alpha")
  and any(.panes[]; .process.kind == "codex" and .process.codex_session_id == null)
' "$codex_manifest" >/dev/null || fail "Codex picker fallback metadata"

stop_private_server
cat >"$shim_directory/codex" <<'SHIM'
#!/bin/sh
set -eu

case $* in
  'resume thr_alpha') output=$CODEX_TEST_LOG_DIRECTORY/alpha ;;
  'resume') output=$CODEX_TEST_LOG_DIRECTORY/picker ;;
  *) output=$CODEX_TEST_LOG_DIRECTORY/unexpected ;;
esac
locale charmap >"$output.locale"
for argument
do
  printf '%s\n' "$argument"
done >"$output"
SHIM
chmod 0755 "$shim_directory/codex"
run_workspace restore
[ "$status" -eq 0 ] || sed -n '1,120p' "$stderr" >&2
assert_equal 0 "$status" "Codex process restore"
wait_attempt=0
while { [ ! -f "$codex_log_directory/alpha" ] \
  || [ ! -f "$codex_log_directory/picker" ]; } \
  && [ "$wait_attempt" -lt 200 ]; do
  sleep 0.01
  wait_attempt=$((wait_attempt + 1))
done
[ -f "$codex_log_directory/alpha" ] || fail "exact Codex resume call"
[ -f "$codex_log_directory/picker" ] || fail "Codex picker resume call"
assert_equal "$(printf 'resume\nthr_alpha')" \
  "$(cat "$codex_log_directory/alpha")" \
  "exact Codex resume argv"
assert_equal resume "$(cat "$codex_log_directory/picker")" \
  "Codex picker argv"
assert_equal UTF-8 "$(cat "$codex_log_directory/alpha.locale")" \
  "resumed Codex preserves a UTF-8 process locale"
assert_equal UTF-8 "$(cat "$codex_log_directory/picker.locale")" \
  "Codex picker preserves a UTF-8 process locale"
[ ! -e "$codex_log_directory/unexpected" ] || fail "unexpected Codex resume argv"
if grep -R -F '/ignored/a.jsonl' "$state/dotfiles/tmux" >/dev/null 2>&1 \
  || grep -R -F '/ignored/b.jsonl' "$state/dotfiles/tmux" >/dev/null 2>&1; then
  fail "Codex transcript path entered persistence state"
fi

stop_private_server
rm -f "$codex_log_directory/alpha" "$codex_log_directory/picker"
run_workspace_missing_executable codex restore
[ "$status" -eq 0 ] || sed -n '1,120p' "$stderr" >&2
assert_equal 0 "$status" "missing Codex executable restore"
assert_equal sh \
  "$(private_tmux list-panes -a -F '#{pane_current_command}' | sort -u)" \
  "missing Codex leaves restored shells open"
assert_contains 'codex is unavailable; the restored shell was left open' \
  "$state/dotfiles/tmux/last-warning" \
  "missing Codex warning"
[ ! -e "$codex_log_directory/alpha" ] \
  && [ ! -e "$codex_log_directory/picker" ] \
  || fail "missing Codex restore dispatched a process"

stop_private_server
real_nvim=$(command -v nvim) || fail "nvim is required"
nvim_project=$test_root/projects/nvim
mkdir -p "$nvim_project"
printf '%s\n' "return 'first'" >"$nvim_project/first.lua"
printf '%s\n' "return 'second'" >"$nvim_project/second.lua"
NVIM_TEST_REAL=$real_nvim
NVIM_TEST_CONFIG=$script_dir/../../nvim
NVIM_TEST_FIRST=$nvim_project/first.lua
NVIM_TEST_SECOND=$nvim_project/second.lua
NVIM_TEST_SOCKET=$socket.nvim
export NVIM_TEST_REAL NVIM_TEST_CONFIG NVIM_TEST_FIRST NVIM_TEST_SECOND NVIM_TEST_SOCKET
cat >"$shim_directory/nvim-source" <<'SHIM'
#!/bin/sh
set -eu
exec "$NVIM_TEST_REAL" --listen "$NVIM_TEST_SOCKET" -i NONE -u NONE \
  --cmd "set runtimepath^=$NVIM_TEST_CONFIG" \
  --cmd "lua require('integrations.tmux_persistence').setup()" \
  -c "edit $NVIM_TEST_FIRST" \
  -c "vsplit $NVIM_TEST_SECOND"
SHIM
chmod 0755 "$shim_directory/nvim-source"
HOME=$test_root/home XDG_STATE_HOME=$state XDG_RUNTIME_DIR=$runtime \
  PATH=$PATH "$real_tmux" -f "$test_root/home/.tmux.conf" -S "$socket" \
  new-session -d -s nvim-work -c "$nvim_project" -n editor 'exec nvim-source'
nvim_pane=$(private_tmux display-message -p -t '=nvim-work:1.1' '#{pane_id}')
wait_attempt=0
nvim_server=
while [ "$wait_attempt" -lt 300 ]; do
  nvim_server=$(private_tmux show-options -pqv -t "$nvim_pane" \
    @dotfiles_nvim_server 2>/dev/null || :)
  [ -n "$nvim_server" ] && break
  sleep 0.01
  wait_attempt=$((wait_attempt + 1))
done
[ -n "$nvim_server" ] || fail "Neovim RPC registration"
assert_equal nvim \
  "$(private_tmux display-message -p -t "$nvim_pane" '#{pane_current_command}')" \
  "Neovim pane command"

run_workspace save
[ "$status" -eq 0 ] || sed -n '1,120p' "$stderr" >&2
assert_equal 0 "$status" "Neovim metadata checkpoint"
nvim_generation=$(cat "$state/dotfiles/tmux/current")
nvim_manifest=$state/dotfiles/tmux/snapshots/$nvim_generation/snapshot.json
nvim_relative=$(jq -er '
  .panes[]
  | select(.process.kind == "nvim")
  | .process.nvim_session
' "$nvim_manifest") || fail "native Neovim session metadata"
nvim_session_file=$state/dotfiles/tmux/snapshots/$nvim_generation/$nvim_relative
[ -s "$nvim_session_file" ] || fail "native Neovim session file"
assert_equal 600 "$(stat -c %a "$nvim_session_file")" "native Neovim session mode"

private_tmux set-option -pt "$nvim_pane" \
  @dotfiles_nvim_server "$test_root/missing-nvim.sock"
run_workspace save
assert_equal 0 "$status" "failed Neovim RPC checkpoint"
failed_nvim_generation=$(cat "$state/dotfiles/tmux/current")
failed_nvim_manifest=$state/dotfiles/tmux/snapshots/$failed_nvim_generation/snapshot.json
jq -e '
  any(.panes[];
    .process.kind == "nvim" and .process.nvim_session == null)
' "$failed_nvim_manifest" >/dev/null \
  || fail "failed Neovim RPC fallback metadata"
assert_contains 'a Neovim checkpoint RPC failed; a clean editor will be restored' \
  "$state/dotfiles/tmux/last-warning" \
  "failed Neovim RPC warning"
printf '%s\n' "$nvim_generation" >"$state/dotfiles/tmux/current"

stop_private_server
cat >"$shim_directory/nvim" <<'SHIM'
#!/bin/sh
set -eu
locale charmap >"$CODEX_TEST_LOG_DIRECTORY/nvim.locale"
for argument
do
  printf '%s\n' "$argument"
done >"$CODEX_TEST_LOG_DIRECTORY/nvim"
SHIM
chmod 0755 "$shim_directory/nvim"
run_workspace restore
[ "$status" -eq 0 ] || sed -n '1,120p' "$stderr" >&2
assert_equal 0 "$status" "Neovim process restore"
wait_attempt=0
while [ ! -f "$codex_log_directory/nvim" ] && [ "$wait_attempt" -lt 200 ]; do
  sleep 0.01
  wait_attempt=$((wait_attempt + 1))
done
[ -f "$codex_log_directory/nvim" ] || fail "Neovim restore argv"
assert_equal "$(printf '%s\n%s' -S "$nvim_session_file")" \
  "$(cat "$codex_log_directory/nvim")" \
  "native Neovim restore argv"
assert_equal UTF-8 "$(cat "$codex_log_directory/nvim.locale")" \
  "restored Neovim preserves a UTF-8 process locale"

nvim_pane_key=$(jq -er '
  .panes[] | select(.process.kind == "nvim") | .key
' "$nvim_manifest")
mv "$nvim_session_file" "$nvim_session_file.private"
ln -s "$nvim_session_file.private" "$nvim_session_file"
rm -f "$codex_log_directory/nvim"
LC_ALL=C LANG=C LC_CTYPE=C run_workspace resume-pane "$nvim_generation" "$nvim_pane_key"
assert_equal 0 "$status" "symlinked Neovim session fallback"
[ -f "$codex_log_directory/nvim" ] || fail "symlink fallback Neovim invocation"
assert_equal '' "$(cat "$codex_log_directory/nvim")" \
  "symlinked Neovim session starts a clean editor"
assert_equal UTF-8 "$(cat "$codex_log_directory/nvim.locale")" \
  "clean Neovim falls back to an available UTF-8 locale from C"
rm -f "$nvim_session_file"
mv "$nvim_session_file.private" "$nvim_session_file"

chmod 0644 "$nvim_session_file"
rm -f "$codex_log_directory/nvim"
run_workspace resume-pane "$nvim_generation" "$nvim_pane_key"
assert_equal 0 "$status" "world-readable Neovim session fallback"
[ -f "$codex_log_directory/nvim" ] \
  || fail "world-readable fallback Neovim invocation"
assert_equal '' "$(cat "$codex_log_directory/nvim")" \
  "world-readable Neovim session starts a clean editor"
chmod 0600 "$nvim_session_file"

pass "workspace structural restore"
