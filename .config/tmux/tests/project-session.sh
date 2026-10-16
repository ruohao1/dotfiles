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
  assert_pattern=$1
  assert_file=$2
  assert_label=$3
  if ! grep -F "$assert_pattern" "$assert_file" >/dev/null 2>&1; then
    fail "$assert_label: missing <$assert_pattern>"
  fi
}

assert_empty() {
  assert_file=$1
  assert_label=$2
  if [ -s "$assert_file" ]; then
    fail "$assert_label: expected an empty file"
  fi
}

script_directory=$(CDPATH='' cd -P "$(dirname "$0")" && pwd -P)
repository_root=$(CDPATH='' cd -P "$script_directory/../../.." && pwd -P)
launcher=$repository_root/.local/bin/t

[ -x "$launcher" ] || fail "launcher is not executable: $launcher"

real_tmux=$(command -v tmux) || fail "tmux is required"
real_git=$(command -v git) || fail "git is required"

unset TMUX TMUX_PANE
unset TMUX_WORKSPACE_STATE_ROOT TMUX_WORKSPACE_RUNTIME_ROOT
export SHELL=/bin/sh

test_root=$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-t-test.XXXXXX") || fail "could not create a temporary directory"
socket_path=$test_root/tmux.sock
shim_directory=$test_root/bin
attach_log=$test_root/attach.log
native_log=$test_root/native.log
state_root=$test_root/state
runtime_root=$test_root/runtime
test_home=$test_root/home
ready_file=$runtime_root/dotfiles-tmux/ready
stdout_file=$test_root/stdout
stderr_file=$test_root/stderr
run_status=0
run_tmux_value=
reuse_session_name=
reuse_session_id=
reuse_replacement_root=
reuse_done_file=$test_root/session-reuse.done

cleanup() {
  "$real_tmux" -S "$socket_path" kill-server >/dev/null 2>&1 || :
  if [ -n "${test_root-}" ] && [ "$test_root" != / ]; then
    case ${test_root##*/} in
      dotfiles-t-test.*)
        rm -rf "$test_root"
        ;;
      *)
        printf 'refusing to remove unexpected test path: %s\n' "$test_root" >&2
        ;;
    esac
  fi
}

trap cleanup 0 HUP INT TERM

mkdir -p "$shim_directory" "$test_home/.config/tmux/scripts"
for helper in workspace project-session; do
  cp "$script_directory/../scripts/$helper" "$test_home/.config/tmux/scripts/$helper"
done

cat >"$shim_directory/tmux" <<'SHIM'
#!/bin/sh
set -eu

if [ "${1-}" = -S ]; then
  [ "${2-}" = "$T_TEST_SOCKET" ] || exit 91
  shift 2
fi

if [ "$#" -eq 0 ]; then
  [ -f "$T_TEST_READY_FILE" ] || {
    printf '%s\n' 'native tmux invoked before workspace readiness' >&2
    exit 90
  }
  printf '%s\n' native >>"$T_TEST_NATIVE_LOG"
  exit 0
fi

if [ "${1-}" = display-message ] \
  && [ -n "${T_TEST_REUSE_SESSION_NAME-}" ] \
  && [ ! -e "$T_TEST_REUSE_DONE_FILE" ]; then
  case ${4-} in
    "=$T_TEST_REUSE_SESSION_NAME:"|"$T_TEST_REUSE_SESSION_ID:")
      reuse_result=$("$T_TEST_REAL_TMUX" -f /dev/null -S "$T_TEST_SOCKET" "$@")
      "$T_TEST_REAL_TMUX" -f /dev/null -S "$T_TEST_SOCKET" kill-session -t "$T_TEST_REUSE_SESSION_ID"
      "$T_TEST_REAL_TMUX" -f /dev/null -S "$T_TEST_SOCKET" new-session -d -s "$T_TEST_REUSE_SESSION_NAME" -c "$T_TEST_REUSE_REPLACEMENT_ROOT"
      : >"$T_TEST_REUSE_DONE_FILE"
      printf '%s\n' "$reuse_result"
      exit 0
      ;;
  esac
fi

if [ "${1-}" = attach-session ]; then
  [ -f "$T_TEST_READY_FILE" ] || {
    printf '%s\n' 'attach invoked before workspace readiness' >&2
    exit 90
  }
  {
    printf '%s\n' attach
    shift
    for argument
    do
      printf '<%s>\n' "$argument"
    done
  } >>"$T_TEST_ATTACH_LOG"
  exit 0
fi

exec "$T_TEST_REAL_TMUX" -f /dev/null -S "$T_TEST_SOCKET" "$@"
SHIM

chmod +x "$shim_directory/tmux"

private_tmux() {
  "$real_tmux" -f /dev/null -S "$socket_path" "$@"
}

reset_logs() {
  : >"$attach_log"
  : >"$native_log"
  : >"$stdout_file"
  : >"$stderr_file"
}

run_t() {
  run_directory=$1
  shift
  reset_logs
  set +e
  (
    cd "$run_directory" || exit 125
    PATH="$shim_directory:$PATH" \
      HOME="$test_home" \
      XDG_CONFIG_HOME="$test_home/.config" \
      TMUX="$run_tmux_value" \
      T_TEST_REAL_TMUX="$real_tmux" \
      T_TEST_SOCKET="$socket_path" \
      T_TEST_ATTACH_LOG="$attach_log" \
      T_TEST_NATIVE_LOG="$native_log" \
      T_TEST_READY_FILE="$ready_file" \
      T_TEST_REUSE_SESSION_NAME="$reuse_session_name" \
      T_TEST_REUSE_SESSION_ID="$reuse_session_id" \
      T_TEST_REUSE_REPLACEMENT_ROOT="$reuse_replacement_root" \
      T_TEST_REUSE_DONE_FILE="$reuse_done_file" \
      XDG_STATE_HOME="$state_root" \
      XDG_RUNTIME_DIR="$runtime_root" \
      TMUX_WORKSPACE_TESTING=1 \
      TMUX_WORKSPACE_SOCKET="$socket_path" \
      "$launcher" "$@"
  ) >"$stdout_file" 2>"$stderr_file"
  run_status=$?
  set -e
}

init_repository() {
  init_path=$1
  mkdir -p "$init_path"
  "$real_git" init -q "$init_path"
  CDPATH='' cd -P "$init_path" && pwd -P
}

space_root=$(init_repository "$test_root/repositories/project alpha")
mkdir -p "$space_root/src/nested"

run_t "$space_root/src/nested"
assert_equal 0 "$run_status" "nested launch"
[ -f "$ready_file" ] || fail "workspace readiness precedes first attachment"
assert_equal "$space_root" "$(private_tmux display-message -p -t '=project_alpha:' '#{session_path}')" "space path session root"
assert_equal 1 "$(private_tmux list-windows -t '=project_alpha' -F '#{window_id}' | wc -l | tr -d '[:space:]')" "single window"
assert_equal 1 "$(private_tmux list-panes -t '=project_alpha' -F '#{pane_id}' | wc -l | tr -d '[:space:]')" "single pane"
space_session_id=$(private_tmux display-message -p -t '=project_alpha:' '#{session_id}')
expected_attach=$(printf 'attach\n<-c>\n<%s>\n<-t>\n<%s>' "$space_root" "$space_session_id")
assert_equal "$expected_attach" "$(cat "$attach_log")" "exact attach arguments"
assert_empty "$native_log" "Git launch native fallback"

run_t "$space_root"
assert_equal 0 "$run_status" "repeat launch"
assert_equal 1 "$(private_tmux list-sessions -F '#{session_name}' | wc -l | tr -d '[:space:]')" "repeat session count"
assert_contains "<$space_session_id>" "$attach_log" "repeat stable session target"

exact_root=$(init_repository "$test_root/exact/exact match")
private_tmux new-session -d -s manual_exact -c "$exact_root"
manual_exact_id=$(private_tmux display-message -p -t '=manual_exact:' '#{session_id}')
exact_session_count=$(private_tmux list-sessions -F '#{session_name}' | wc -l | tr -d '[:space:]')

run_t "$exact_root"
assert_equal 0 "$run_status" "exact-directory launch"
expected_exact_attach=$(printf 'attach\n<-c>\n<%s>\n<-t>\n<%s>' "$exact_root" "$manual_exact_id")
assert_equal "$expected_exact_attach" "$(cat "$attach_log")" "exact-directory attach arguments"
assert_equal "$exact_session_count" "$(private_tmux list-sessions -F '#{session_name}' | wc -l | tr -d '[:space:]')" "exact-directory session count"
assert_empty "$native_log" "exact-directory native fallback"
assert_empty "$stderr_file" "exact-directory diagnostics"
if private_tmux has-session -t '=exact_match' 2>/dev/null; then
  fail "exact-directory launch created generated-name duplicate"
fi

reuse_root=$(init_repository "$test_root/reuse/original")
reuse_replacement_root=$test_root/reuse/replacement
mkdir -p "$reuse_replacement_root"
reuse_session_name=replaceable
private_tmux new-session -d -s "$reuse_session_name" -c "$reuse_root"
reuse_session_id=$(private_tmux display-message -p -t "=$reuse_session_name:" '#{session_id}')

run_t "$reuse_root"
assert_equal 1 "$run_status" "reused-name exact-directory launch refuses a vanished target"
[ -f "$reuse_done_file" ] || fail "reused-name fixture did not replace the session"
assert_empty "$attach_log" "reused-name never attaches to the replacement session"
assert_contains 'could not resolve the shell session' "$stderr_file" "reused-name diagnostic"
assert_equal "$reuse_replacement_root" "$(private_tmux display-message -p -t "=$reuse_session_name:" '#{session_path}')" "reused-name replacement root"
if private_tmux has-session -t "$reuse_session_id" 2>/dev/null; then
  fail "reused-name fixture retained the original session ID"
fi
assert_empty "$native_log" "reused-name native fallback"
reuse_session_name=
reuse_session_id=
reuse_replacement_root=

newline_suffix=$(printf '\n.')
newline_suffix=${newline_suffix%.}
newline_directory=$test_root/trailing-newline/directory$newline_suffix
mkdir -p "$newline_directory"
private_tmux new-session -d -s trailing_newline -c "$newline_directory"
trailing_newline_id=$(private_tmux display-message -p -t '=trailing_newline:' '#{session_id}')

run_t "$newline_directory"
assert_equal 0 "$run_status" "trailing-newline exact-directory launch"
expected_newline_attach=$(printf 'attach\n<-c>\n<%s>\n<-t>\n<%s>' "$newline_directory" "$trailing_newline_id")
assert_equal "$expected_newline_attach" "$(cat "$attach_log")" "trailing-newline exact-directory attach"
assert_empty "$native_log" "trailing-newline exact-directory native fallback"
assert_empty "$stderr_file" "trailing-newline exact-directory diagnostics"

precedence_root=$(init_repository "$test_root/precedence/repository")
precedence_nested=$precedence_root/src/special
mkdir -p "$precedence_nested"
private_tmux new-session -d -s precedence_root -c "$precedence_root"
private_tmux new-session -d -s precedence_nested -c "$precedence_nested"
precedence_nested_id=$(private_tmux display-message -p -t '=precedence_nested:' '#{session_id}')

run_t "$precedence_nested"
assert_equal 0 "$run_status" "nested exact-directory launch"
expected_precedence_attach=$(printf 'attach\n<-c>\n<%s>\n<-t>\n<%s>' "$precedence_nested" "$precedence_nested_id")
assert_equal "$expected_precedence_attach" "$(cat "$attach_log")" "nested exact-directory precedence"
assert_empty "$native_log" "nested exact-directory native fallback"

outside_exact_directory=$test_root/outside-exact
mkdir -p "$outside_exact_directory"
private_tmux new-session -d -s outside_exact -c "$outside_exact_directory"
outside_exact_id=$(private_tmux display-message -p -t '=outside_exact:' '#{session_id}')

run_t "$outside_exact_directory"
assert_equal 0 "$run_status" "outside-Git exact-directory launch"
expected_outside_exact_attach=$(printf 'attach\n<-c>\n<%s>\n<-t>\n<%s>' "$outside_exact_directory" "$outside_exact_id")
assert_equal "$expected_outside_exact_attach" "$(cat "$attach_log")" "outside-Git exact-directory attach"
assert_empty "$native_log" "outside-Git exact-directory native fallback"

physical_directory=$test_root/physical-target
symbolic_directory=$test_root/symbolic-target
mkdir -p "$physical_directory"
ln -s "$physical_directory" "$symbolic_directory"
private_tmux new-session -d -s symbolic_exact -c "$physical_directory"
symbolic_exact_id=$(private_tmux display-message -p -t '=symbolic_exact:' '#{session_id}')

run_t "$symbolic_directory"
assert_equal 0 "$run_status" "symbolic exact-directory launch"
expected_symbolic_attach=$(printf 'attach\n<-c>\n<%s>\n<-t>\n<%s>' "$physical_directory" "$symbolic_exact_id")
assert_equal "$expected_symbolic_attach" "$(cat "$attach_log")" "symbolic exact-directory normalization"
assert_empty "$native_log" "symbolic exact-directory native fallback"

duplicate_root=$(init_repository "$test_root/duplicates/duplicate project")
private_tmux new-session -d -s duplicate_one -c "$duplicate_root"
private_tmux new-session -d -s duplicate_two -c "$duplicate_root"
duplicate_session_count=$(private_tmux list-sessions -F '#{session_name}' | wc -l | tr -d '[:space:]')

run_t "$duplicate_root"
assert_equal 1 "$run_status" "duplicate exact-directory launch"
assert_contains "t: multiple sessions use directory '$duplicate_root':" "$stderr_file" "duplicate exact-directory diagnostic"
assert_contains "'duplicate_one'" "$stderr_file" "first duplicate session name"
assert_contains "'duplicate_two'" "$stderr_file" "second duplicate session name"
assert_empty "$attach_log" "duplicate exact-directory attach"
assert_empty "$native_log" "duplicate exact-directory native fallback"
assert_equal "$duplicate_session_count" "$(private_tmux list-sessions -F '#{session_name}' | wc -l | tr -d '[:space:]')" "duplicate exact-directory session count"
if private_tmux has-session -t '=duplicate_project' 2>/dev/null; then
  fail "duplicate exact-directory launch created another session"
fi

shared_one_root=$(init_repository "$test_root/one/shared")
shared_two_root=$(init_repository "$test_root/two/shared")

run_t "$shared_one_root"
assert_equal 0 "$run_status" "first shared launch"
assert_equal "$shared_one_root" "$(private_tmux display-message -p -t '=shared:' '#{session_path}')" "first shared root"

shared_hash=$(printf '%s' "$shared_two_root" | "$real_git" hash-object --stdin | cut -c 1-8)
shared_collision=shared-$shared_hash
run_t "$shared_two_root"
assert_equal 0 "$run_status" "second shared launch"
assert_equal "$shared_two_root" "$(private_tmux display-message -p -t "=$shared_collision:" '#{session_path}')" "collision-safe shared root"
shared_collision_id=$(private_tmux display-message -p -t "=$shared_collision:" '#{session_id}')
assert_contains "<$shared_collision_id>" "$attach_log" "collision-safe attach target"

conflict_target_root=$(init_repository "$test_root/target/conflict")
conflict_base_root=$test_root/occupants/base
conflict_hash_root=$test_root/occupants/hash
mkdir -p "$conflict_base_root" "$conflict_hash_root"
conflict_hash=$(printf '%s' "$conflict_target_root" | "$real_git" hash-object --stdin | cut -c 1-8)
conflict_session=conflict-$conflict_hash
private_tmux new-session -d -s conflict -c "$conflict_base_root"
private_tmux new-session -d -s "$conflict_session" -c "$conflict_hash_root"

run_t "$conflict_target_root"
assert_equal 1 "$run_status" "conflicting collision-safe session"
assert_empty "$attach_log" "conflicting session attach"
assert_contains "t: session '$conflict_session' belongs to another project" "$stderr_file" "conflicting session diagnostic"

outside_directory=$test_root/outside
mkdir -p "$outside_directory"
run_t "$outside_directory"
assert_equal 0 "$run_status" "outside Git fallback"
assert_equal native "$(cat "$native_log")" "native tmux fallback"
assert_empty "$attach_log" "outside Git attach"

run_tmux_value=$test_root/live-looking.sock,1,0
run_t "$space_root"
run_tmux_value=
assert_equal 1 "$run_status" "inside tmux rejection"
assert_contains 't: already inside tmux' "$stderr_file" "inside tmux diagnostic"
assert_empty "$attach_log" "inside tmux attach"
assert_empty "$native_log" "inside tmux native fallback"

run_t "$space_root" --name custom
assert_equal 2 "$run_status" "argument rejection"
assert_contains 'usage: t' "$stderr_file" "argument usage"
assert_empty "$attach_log" "argument attach"
assert_empty "$native_log" "argument native fallback"

pass "project session launcher"
