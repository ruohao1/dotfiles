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

assert_not_contains() {
  needle=$1
  file=$2
  label=$3
  if grep -F "$needle" "$file" >/dev/null 2>&1; then
    fail "$label: unexpectedly found <$needle>"
  fi
}

script_dir=$(CDPATH='' cd -P "$(dirname "$0")" && pwd -P)
workspace=$script_dir/../scripts/workspace
real_tmux=$(command -v tmux) || fail "tmux is required"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-workspace-state.XXXXXX") || fail "could not create test root"
socket=$test_root/tmux.sock
state=$test_root/state
runtime=$test_root/runtime
stdout=$test_root/stdout
stderr=$test_root/stderr
status=0

cleanup() {
  "$real_tmux" -S "$socket" kill-server >/dev/null 2>&1 || :
  case $test_root in
    "${TMPDIR:-/tmp}"/dotfiles-workspace-state.*) rm -rf "$test_root" ;;
    *) printf 'refusing cleanup: %s\n' "$test_root" >&2 ;;
  esac
}
trap cleanup 0 HUP INT TERM

run_workspace() {
  set +e
  HOME=$test_root/home \
    XDG_STATE_HOME=$state \
    XDG_RUNTIME_DIR=$runtime \
    TMUX_WORKSPACE_TESTING=1 \
    TMUX_WORKSPACE_SOCKET=$socket \
    TMUX_WORKSPACE_TEST_SERVICE_ENABLED=true \
    "$workspace" "$@" >"$stdout" 2>"$stderr"
  status=$?
  set -e
}

run_workspace_generation() {
  test_generation=$1
  shift
  set +e
  HOME=$test_root/home \
    XDG_STATE_HOME=$state \
    XDG_RUNTIME_DIR=$runtime \
    TMUX_WORKSPACE_TESTING=1 \
    TMUX_WORKSPACE_SOCKET=$socket \
    TMUX_WORKSPACE_TEST_GENERATION=$test_generation \
    "$workspace" "$@" >"$stdout" 2>"$stderr"
  status=$?
  set -e
}

run_workspace --help
assert_equal 0 "$status" "help status"
assert_contains 'tmux-workspace save' "$stdout" "help save command"
assert_contains 'tmux-workspace doctor' "$stdout" "help doctor command"

run_workspace unknown
assert_equal 2 "$status" "unknown command status"

run_workspace save
assert_equal 0 "$status" "empty-server checkpoint"
generation=$(cat "$state/dotfiles/tmux/current")
manifest=$state/dotfiles/tmux/snapshots/$generation/snapshot.json
jq -e '.schema == 1 and .sessions == [] and .windows == [] and .panes == []' \
  "$manifest" >/dev/null || fail "empty snapshot schema"
assert_equal 700 "$(stat -c %a "$state/dotfiles/tmux")" "Linux state directory mode"
assert_equal 600 "$(stat -c %a "$manifest")" "Linux manifest mode"
fallback_generation=$generation
fallback_manifest=$manifest

run_workspace status
assert_equal 0 "$status" "complete status report"
for status_label in \
  'Supervisor:' \
  'Current snapshot:' \
  'Last checkpoint:' \
  'Last restore:' \
  'Server state:' \
  'Warnings:'
do
  assert_contains "$status_label" "$stdout" "status label $status_label"
done
assert_not_contains 'transcript_path' "$stdout" "status excludes transcript metadata"
assert_not_contains 'TMUX_WORKSPACE_STATUS_SECRET' "$stdout" \
  "status excludes environment names"

ready_file=$runtime/dotfiles-tmux/ready
: >"$ready_file"
chmod 0600 "$ready_file"
run_workspace_generation empty-ready save
assert_equal 0 "$status" "empty ready-state checkpoint"
generation=$(cat "$state/dotfiles/tmux/current")
manifest=$state/dotfiles/tmux/snapshots/$generation/snapshot.json
run_workspace ensure
assert_equal 0 "$status" "empty ready-state ensure"
[ ! -e "$state/dotfiles/tmux/last-restore.json" ] \
  || fail "empty ready state performed a redundant restore"

chmod 0644 "$manifest"
run_workspace status
assert_equal 0 "$status" "world-readable snapshot fallback"
assert_contains "Current snapshot: $fallback_generation" "$stdout" \
  "world-readable snapshot fallback generation"
assert_contains 'a fallback snapshot was selected' "$stdout" \
  "world-readable snapshot warning"
chmod 0600 "$manifest"

printf '%s\n' broken >"$state/dotfiles/tmux/current"
printf '%s\n' '{' >"$manifest"
chmod 0644 "$fallback_manifest"
run_workspace status
assert_equal 1 "$status" "invalid current pointer status"
assert_contains 'no valid snapshot' "$stderr" "invalid current diagnostic"
chmod 0600 "$fallback_manifest"

set +e
HOME=$test_root/home XDG_STATE_HOME=$state XDG_RUNTIME_DIR=$runtime \
  TMUX_WORKSPACE_TESTING=1 "$workspace" status >"$stdout" 2>"$stderr"
status=$?
set -e
assert_equal 2 "$status" "test mode requires private socket"
assert_contains 'TMUX_WORKSPACE_SOCKET is required in test mode' "$stderr" \
  "private socket guard"

doctor_bin=$test_root/doctor-bin
mkdir -p "$doctor_bin"
ln -s "$(command -v uname)" "$doctor_bin/uname"
ln -s "$(command -v stat)" "$doctor_bin/stat"
set +e
HOME=$test_root/home XDG_STATE_HOME=$state XDG_RUNTIME_DIR=$runtime \
  TMUX_WORKSPACE_TESTING=1 TMUX_WORKSPACE_SOCKET=$socket \
  TMUX_WORKSPACE_TEST_SERVICE_ENABLED=true PATH=$doctor_bin \
  /bin/sh "$workspace" doctor >"$stdout" 2>"$stderr"
status=$?
set -e
assert_equal 1 "$status" "doctor aggregates missing requirements"
assert_contains 'tmux dependency is missing' "$stdout" "doctor missing tmux"
assert_contains 'python3 dependency is missing' "$stdout" "doctor missing python3"
assert_contains 'jq dependency is missing' "$stdout" "doctor missing jq"
assert_contains 'Codex hook JSON is missing or invalid' "$stdout" \
  "doctor missing Codex hooks"
assert_contains 'workspace helper is missing or not executable' "$stdout" \
  "doctor missing helper"
assert_contains 'Neovim integration file is missing' "$stdout" \
  "doctor missing Neovim integration"
assert_contains 'platform service file is missing' "$stdout" \
  "doctor missing service file"

source_config_root=$(CDPATH='' cd -P "$script_dir/../.." && pwd -P)
mkdir -p \
  "$test_root/home/.codex" \
  "$test_root/home/.config/nvim/lua/integrations" \
  "$test_root/home/.config/systemd/user" \
  "$test_root/home/.config/tmux/scripts"
# Codex hooks and native service templates are intentionally not adopted by
# the selected runtime. These fixtures model their retained native contracts.
jq -n --arg command '"$HOME/.config/tmux/scripts/workspace" codex-hook' \
  '{hooks: {SessionStart: [{hooks: [{type:"command",command:$command}]}],
            SessionEnd: [{hooks: [{type:"command",command:$command}]}]}}' \
  >"$test_root/home/.codex/hooks.json"
cp "$source_config_root/nvim/lua/integrations/tmux_persistence.lua" \
  "$test_root/home/.config/nvim/lua/integrations/tmux_persistence.lua"
printf '%s\n' '[Service]' 'ExecStart=%h/.config/tmux/scripts/workspace supervise' \
  >"$test_root/home/.config/systemd/user/tmux-workspace.service"
cp "$workspace" "$test_root/home/.config/tmux/scripts/workspace"
chmod 0600 "$test_root/home/.codex/hooks.json"
chmod 0755 "$test_root/home/.config/tmux/scripts/workspace"
run_workspace doctor
assert_equal 0 "$status" "complete doctor status"
assert_equal "$(printf '%s\n%s' \
  'tmux-workspace doctor: ok' \
  'Codex hook trust: review with /hooks')" \
  "$(cat "$stdout")" \
  "complete doctor report"

mkdir -p \
  "$runtime/dotfiles-tmux/checkpoint.lock" \
  "$state/dotfiles/tmux/snapshots/.staging-99999999-interrupted"
printf '%s\n' 99999999 >"$runtime/dotfiles-tmux/checkpoint.lock/owner"
printf '%s\n' partial \
  >"$state/dotfiles/tmux/snapshots/.staging-99999999-interrupted/partial"
run_workspace_generation cleanup-pass save
assert_equal 0 "$status" "stale workspace artifact cleanup"
[ ! -e "$runtime/dotfiles-tmux/checkpoint.lock" ] \
  || fail "stale checkpoint lock remained"
[ ! -e "$state/dotfiles/tmux/snapshots/.staging-99999999-interrupted" ] \
  || fail "interrupted staging generation remained"

mkdir -p "$test_root/projects/alpha" "$test_root/projects/beta"
"$real_tmux" -f "$script_dir/../conf/options.conf" -S "$socket" \
  new-session -d -s alpha -c "$test_root/projects/alpha" -n editor
"$real_tmux" -S "$socket" split-window -d -t '=alpha:1' \
  -c "$test_root/projects/alpha"
"$real_tmux" -S "$socket" select-layout -t '=alpha:1' even-horizontal
"$real_tmux" -S "$socket" new-window -d -t '=alpha:2' -n shell \
  -c "$test_root/projects/beta"
"$real_tmux" -S "$socket" new-session -d -s mirror -t '=alpha'
"$real_tmux" -S "$socket" new-session -d -s linked \
  -c "$test_root/projects/beta" -n local
"$real_tmux" -S "$socket" link-window -d -s '=alpha:2' -t '=linked:2'
"$real_tmux" -S "$socket" select-pane -t '=alpha:1.2'
"$real_tmux" -S "$socket" select-window -t '=alpha:2'
"$real_tmux" -S "$socket" set-option -wu -t '=alpha:1' automatic-rename

run_workspace save
if [ "$status" -ne 0 ]; then
  sed -n '1,80p' "$stderr" >&2
  "$real_tmux" -S "$socket" list-windows -a -F '#{window_id} #{window_layout}' >&2
fi
assert_equal 0 "$status" "topology checkpoint"
generation=$(cat "$state/dotfiles/tmux/current")
manifest=$state/dotfiles/tmux/snapshots/$generation/snapshot.json
assert_equal "$generation" \
  "$("$real_tmux" -S "$socket" show-options -gqv \
    @dotfiles_workspace_generation)" \
  "checkpoint marks the live server generation"
jq -e '
  (.sessions | length) == 3
  and ([.sessions[].name] | sort) == ["alpha", "linked", "mirror"]
  and ([.windows[].links | length] | max) >= 2
  and ([.windows[].panes | length] | max) == 2
  and any(.sessions[]; .group != null)
  and any(.sessions[]; .active_window_index == 2)
  and all(.panes[]; .process.kind == "shell")
' "$manifest" >/dev/null || fail "captured topology"

jq -e 'all(.sessions[]; .line_pins == {version:1,pins:[]})' "$manifest" >/dev/null \
  || fail 'checkpoint omits empty per-session line-pin state'
valid_generation=$generation
valid_pin_manifest=$manifest
TMUX_WORKSPACE_TEST_FAIL_CAPTURE=1
export TMUX_WORKSPACE_TEST_FAIL_CAPTURE
run_workspace_generation bad-capture save
unset TMUX_WORKSPACE_TEST_FAIL_CAPTURE
assert_equal 1 "$status" "interrupted capture rejection"
assert_equal "$valid_generation" "$(cat "$state/dotfiles/tmux/current")" \
  "failed capture preserves current pointer"
[ ! -e "$state/dotfiles/tmux/snapshots/bad-capture" ] \
  || fail "failed capture published a completed generation"
[ ! -e "$state/dotfiles/tmux/snapshots/.staging-bad-capture" ] \
  || fail "failed capture retained its staging generation"

"$real_tmux" -S "$socket" kill-server
original_state=$state
state=$test_root/invalid-pin-state
invalid_snapshot=$state/dotfiles/tmux/snapshots/invalid/snapshot.json
mkdir -p "$(dirname "$invalid_snapshot")"
chmod 700 "$state/dotfiles/tmux" "$state/dotfiles/tmux/snapshots" "$state/dotfiles/tmux/snapshots/invalid"
printf '%s\n' invalid >"$state/dotfiles/tmux/current"
for pin_filter in \
  '.panes[0].line_pin_session_key=null' \
  '.panes[0].line_pin_session_key="\u0024999999"' \
  '.panes[0].line_pin_session_key=1' \
  '.sessions[0].line_pins=null' \
  '.sessions[0].line_pins={version:2,pins:[]}' \
  '.sessions[0].line_pins={version:1,pins:[{id:("0"*64),path:"/x",line:1,col:0}]}' \
  '.sessions[0].line_pins={version:1,pins:[],extra:true}'
do
  jq "$pin_filter" "$valid_pin_manifest" >"$invalid_snapshot"
  chmod 600 "$invalid_snapshot"
  run_workspace restore
  assert_equal 1 "$status" "invalid line-pin snapshot rejection: $pin_filter"
  if "$real_tmux" -S "$socket" list-sessions >/dev/null 2>&1; then
    fail 'invalid pin snapshot created a server before validation'
  fi
done
state=$original_state
pass 'invalid and future pin snapshots fail before restore'
generation_number=1
while [ "$generation_number" -le 12 ]; do
  padded=$(printf '%02d' "$generation_number")
  run_workspace_generation "gen-$padded" save
  assert_equal 0 "$status" "retention generation $padded"
  generation_number=$((generation_number + 1))
done
actual_generations=$(
  find "$state/dotfiles/tmux/snapshots" -mindepth 1 -maxdepth 1 -type d \
    -name 'gen-*' -exec basename {} \; | sort | tr '\n' ' '
)
assert_equal \
  'gen-03 gen-04 gen-05 gen-06 gen-07 gen-08 gen-09 gen-10 gen-11 gen-12 ' \
  "$actual_generations" \
  "ten-generation retention"

pass "workspace state boundary"

python3 "$script_dir/workspace-checkpoint.py"
