#!/bin/sh

set -eu

LC_ALL=C
export LC_ALL

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
dotfiles_dir=$(CDPATH='' cd -- "$script_dir/.." && pwd)
workspace_root=$(CDPATH='' cd -- "$dotfiles_dir/../.." && pwd)
bootstrap=$dotfiles_dir/bootstrap
DOTFILES_BOOTSTRAP_TEST_WINDOW_MANAGER=none
export DOTFILES_BOOTSTRAP_TEST_WINDOW_MANAGER

failures=0
tests=0

pass() {
  tests=$((tests + 1))
  printf 'ok %d - %s\n' "$tests" "$1"
}

fail() {
  tests=$((tests + 1))
  failures=$((failures + 1))
  printf 'not ok %d - %s\n' "$tests" "$1" >&2
}

require_contains() {
  haystack=$1
  needle=$2
  label=$3

  case "$haystack" in
    *"$needle"*) pass "$label" ;;
    *)
      fail "$label"
      printf '  missing: %s\n' "$needle" >&2
      ;;
  esac
}

require_excludes() {
  haystack=$1
  needle=$2
  label=$3

  case "$haystack" in
    *"$needle"*)
      fail "$label"
      printf '  unexpected: %s\n' "$needle" >&2
      ;;
    *) pass "$label" ;;
  esac
}

prepare_private_capture_home() {
  capture_home=
  capture_mutating=false
  for capture_argument do
    case "$capture_argument" in
      HOME=*) capture_home=${capture_argument#HOME=} ;;
      --apply|--rollback) capture_mutating=true ;;
    esac
  done
  # Real deployments require an existing identity. Only private positive fixture
  # homes are prepared here; parser rejections and dry-run absence stay intact.
  if [ "$capture_mutating" = true ] && [ -n "$capture_home" ]; then
    case "$capture_home" in
      "$test_tmp"/*)
        if [ ! -e "$capture_home" ] && [ ! -L "$capture_home" ]; then
          mkdir -p -- "$capture_home"
        fi
        ;;
    esac
  fi
}

only_ownership_coordination() {
  [ ! -e "$1/.local" ] && return 0
  [ ! -L "$1/.local" ] && [ -d "$1/.local/state/dotfiles-ownership" ] || return 1
  coordination_entries=$(find "$1/.local" -mindepth 1 -print | LC_ALL=C sort)
  [ "$coordination_entries" = "$(printf '%s\n' "$1/.local/state" "$1/.local/state/dotfiles-ownership")" ]
}

run_capture() {
  output_file=$1
  shift
  prepare_private_capture_home "$@"
  set +e
  "$@" >"$output_file" 2>&1
  run_status=$?
  set -e
}

run_capture_in_directory() {
  output_file=$1
  capture_directory=$2
  shift 2
  prepare_private_capture_home "$@"
  set +e
  (
    CDPATH='' cd -- "$capture_directory"
    "$@"
  ) >"$output_file" 2>&1
  run_status=$?
  set -e
}

resolve_test_executable() {
  resolved_test_name=$1
  resolved_test_path=$(command -v "$resolved_test_name" 2>/dev/null || true)
  case $resolved_test_path in
    /*) [ -x "$resolved_test_path" ] || return 1 ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$resolved_test_path"
}

make_version_command() {
  command_path=$1
  version_text=$2
  mkdir -p "$(dirname "$command_path")"
  printf '%s\n' \
    '#!/bin/sh' \
    "printf '%s\\n' '$version_text'" \
    >"$command_path"
  chmod 0755 "$command_path"
}

make_failing_version_command() {
  command_path=$1
  version_text=$2
  version_status=$3
  mkdir -p "$(dirname "$command_path")"
  printf '%s\n' \
    '#!/bin/sh' \
    "printf '%s\\n' '$version_text'" \
    "exit '$version_status'" \
    >"$command_path"
  chmod 0755 "$command_path"
}

make_stdio_command() {
  command_path=$1
  command_behavior=$2
  mkdir -p "$(dirname "$command_path")"
  case "$command_behavior" in
    wait)
      printf '%s\n' '#!/bin/sh' 'exec sleep 30' >"$command_path"
      ;;
    fail)
      printf '%s\n' '#!/bin/sh' 'exit 1' >"$command_path"
      ;;
    *)
      return 1
      ;;
  esac
  chmod 0755 "$command_path"
}

make_taplo_command() {
  command_path=$1
  version_text=$2
  lsp_behavior=$3
  mkdir -p "$(dirname "$command_path")"
  case "$lsp_behavior" in
    success) lsp_command='exit 0' ;;
    fail) lsp_command='exit 1' ;;
    hang) lsp_command='exec sleep 30' ;;
    *) return 1 ;;
  esac
  # shellcheck disable=SC2016 # The generated fixture expands its arguments at runtime.
  printf '%s\n' \
    '#!/bin/sh' \
    'if [ "${1:-}" = --version ]; then' \
    "  printf '%s\\n' '$version_text'" \
    '  exit 0' \
    'fi' \
    'if [ "${1:-}" = lsp ] && [ "${2:-}" = stdio ] && [ "${3:-}" = --help ]; then' \
    '  if [ -n "${DOTFILES_BOOTSTRAP_TEST_TAPLO_PROBE_PID_FILE:-}" ]; then' \
    '    printf "%s\\n" "$$" >"$DOTFILES_BOOTSTRAP_TEST_TAPLO_PROBE_PID_FILE"' \
    '  fi' \
    "  $lsp_command" \
    'fi' \
    'exit 1' \
    >"$command_path"
  chmod 0755 "$command_path"
}

make_term_ignoring_stdio_command() {
  command_path=$1
  probe_pid_file=$2
  probe_ready_file=$3
  mkdir -p "$(dirname "$command_path")"
  printf '%s\n' \
    '#!/bin/sh' \
    "trap '' TERM" \
    "printf '%s\\n' \"\$\$\" >'$probe_pid_file'" \
    "printf '%s\\n' ready >'$probe_ready_file'" \
    "kill -TERM \"\${DOTFILES_BOOTSTRAP_TEST_PROBE_OWNER_PID:-\$PPID}\"" \
    'while :; do :; done' \
    >"$command_path"
  chmod 0755 "$command_path"
}

kill_matching_test_process() {
  matching_test_pid=$1
  matching_test_path=$2
  matching_test_command=$(
    ps -p "$matching_test_pid" -o command= 2>/dev/null || true
  )
  case "$matching_test_command" in
    *"$matching_test_path"*)
      kill -KILL "$matching_test_pid" >/dev/null 2>&1 || true
      ;;
  esac
}

test_process_is_matching() {
  matching_test_pid=$1
  matching_test_path=$2
  matching_test_command=$(ps -p "$matching_test_pid" -o command= 2>/dev/null || true)
  case "$matching_test_command" in
    *"$matching_test_path"*) return 0 ;;
    *) return 1 ;;
  esac
}

make_direct_probe_bootstrap() {
  direct_probe_source=$1
  direct_probe_target=$2
  awk '
    $0 == "platform=$(detect_platform)" {
      print "if ! command -v require_debian_probe_runtime >/dev/null 2>&1; then"
      print "  require_debian_probe_runtime() {"
      print "    direct_probe_setsid_candidate=$(command -v setsid 2>/dev/null || true)"
      print "    case $direct_probe_setsid_candidate in"
      print "      /*) [ -x \"$direct_probe_setsid_candidate\" ] ;;"
      print "      *) false ;;"
      print "    esac || {"
      print "      printf \"%s\\n\" \"bootstrap: util-linux setsid -f -w is required for Debian language-server probes\" >&2"
      print "      return 1"
      print "    }"
      print "    direct_probe_env_candidate=$(command -v env 2>/dev/null || true)"
      print "    case $direct_probe_env_candidate in"
      print "      /*) [ -x \"$direct_probe_env_candidate\" ] ;;"
      print "      *) false ;;"
      print "    esac || {"
      print "      printf \"%s\\n\" \"bootstrap: GNU env --default-signal=HUP,INT,TERM is required for Debian language-server probes\" >&2"
      print "      return 1"
      print "    }"
      print "    if ! \"$direct_probe_setsid_candidate\" -f -w /bin/sh -c \"exit 0\"; then"
      print "      printf \"%s\\n\" \"bootstrap: util-linux setsid -f -w is required for Debian language-server probes\" >&2"
      print "      return 1"
      print "    fi"
      print "    if ! \"$direct_probe_env_candidate\" --default-signal=HUP,INT,TERM /bin/sh -c \"exit 0\"; then"
      print "      printf \"%s\\n\" \"bootstrap: GNU env --default-signal=HUP,INT,TERM is required for Debian language-server probes\" >&2"
      print "      return 1"
      print "    fi"
      print "    debian_probe_setsid_command=$direct_probe_setsid_candidate"
      print "    debian_probe_env_command=$direct_probe_env_candidate"
      print "  }"
      print "fi"
      print "if [ \"${DOTFILES_BOOTSTRAP_TEST_DIRECT_PROBE:-0}\" = 1 ]; then"
      print "  require_debian_probe_runtime || exit 42"
      print "  case ${debian_probe_setsid_command:-} in"
      print "    /*) [ -x \"$debian_probe_setsid_command\" ] || exit 42 ;;"
      print "    *) exit 42 ;;"
      print "  esac"
      print "  case ${debian_probe_env_command:-} in"
      print "    /*) [ -x \"$debian_probe_env_command\" ] || exit 42 ;;"
      print "    *) exit 42 ;;"
      print "  esac"
      print "  if [ -n \"${DOTFILES_BOOTSTRAP_TEST_DIRECT_PROBE_RUNTIME_AUDIT:-}\" ]; then"
      print "    printf \"setsid|%s\\nenv|%s\\n\" \"$debian_probe_setsid_command\" \"$debian_probe_env_command\" >\"$DOTFILES_BOOTSTRAP_TEST_DIRECT_PROBE_RUNTIME_AUDIT\" || exit 42"
      print "  fi"
      print "  if [ -n \"${DOTFILES_BOOTSTRAP_TEST_DIRECT_PROBE_EXPECTED_SETSID:-}\" ]; then"
      print "    [ \"$debian_probe_setsid_command\" = \"$DOTFILES_BOOTSTRAP_TEST_DIRECT_PROBE_EXPECTED_SETSID\" ] || exit 42"
      print "  fi"
      print "  if [ -n \"${DOTFILES_BOOTSTRAP_TEST_DIRECT_PROBE_EXPECTED_ENV:-}\" ]; then"
      print "    [ \"$debian_probe_env_command\" = \"$DOTFILES_BOOTSTRAP_TEST_DIRECT_PROBE_EXPECTED_ENV\" ] || exit 42"
      print "  fi"
      print "  if [ -n \"${DOTFILES_BOOTSTRAP_TEST_DIRECT_PROBE_POST_GATE_PATH:-}\" ]; then"
      print "    PATH=$DOTFILES_BOOTSTRAP_TEST_DIRECT_PROBE_POST_GATE_PATH"
      print "    export PATH"
      print "  fi"
      print "  if bounded_command_succeeds \"$DOTFILES_BOOTSTRAP_TEST_DIRECT_PROBE_COMMAND\"; then"
      print "    exit 0"
      print "  fi"
      print "  exit 42"
      print "fi"
      injected += 1
    }
    { print }
    END {
      if (injected != 1) exit 1
    }
  ' "$direct_probe_source" >"$direct_probe_target"
  chmod 0755 "$direct_probe_target"
}

make_probe_tree_command() {
  probe_tree_path=$1
  probe_tree_mode=$2
  probe_tree_pid_file=$3
  probe_tree_child_pid_file=$4
  probe_tree_auxiliary_file=$5
  mkdir -p "$(dirname "$probe_tree_path")"
  # shellcheck disable=SC2016 # These snippets are expanded by the generated fixture.
  case "$probe_tree_mode" in
    exit-zero-child)
      probe_tree_body='"$0" child & child_pid=$!; printf "%s\n" "$child_pid" >"$probe_child_pid_file"; printf "%s|%s\n" "$$" "$child_pid" >"$probe_auxiliary_file"; exit 0'
      ;;
    exit-nonzero-child)
      probe_tree_body='"$0" child & child_pid=$!; printf "%s\n" "$child_pid" >"$probe_child_pid_file"; printf "%s|%s\n" "$$" "$child_pid" >"$probe_auxiliary_file"; exit 23'
      ;;
    ignore-term-tree)
      probe_tree_body='trap "" TERM; "$0" child-ignore-term & child_pid=$!; printf "%s\n" "$child_pid" >"$probe_child_pid_file"; while [ ! -s "$probe_auxiliary_file" ]; do sleep 1; done; while :; do sleep 1; done'
      ;;
    wait-for-release)
      probe_tree_body='trap "" TERM; while [ ! -e "$probe_auxiliary_file" ]; do sleep 1; done; exit 1'
      ;;
    exit-seven)
      probe_tree_body='exit 7'
      ;;
    self-hup)
      probe_tree_body='kill -HUP "$$"; exit 0'
      ;;
    self-int)
      probe_tree_body='kill -INT "$$"; exit 0'
      ;;
    self-term)
      probe_tree_body='kill -TERM "$$"; exit 0'
      ;;
    marker-success)
      probe_tree_body='[ -z "$probe_auxiliary_file" ] || printf "%s\n" started >"$probe_auxiliary_file"; exit 0'
      ;;
    *) return 1 ;;
  esac
  # shellcheck disable=SC2016 # The generated fixture expands private paths at runtime.
  printf '%s\n' \
    '#!/bin/sh' \
    "probe_pid_file='$probe_tree_pid_file'" \
    "probe_child_pid_file='$probe_tree_child_pid_file'" \
    "probe_auxiliary_file='$probe_tree_auxiliary_file'" \
    'case "${1:-}" in' \
    '  child) printf "%s\n" ready >"$probe_auxiliary_file.ready"; while :; do sleep 1; done ;;' \
    '  child-ignore-term) trap "" TERM; printf "%s|%s\n" "$PPID" "$$" >"$probe_auxiliary_file"; while :; do sleep 1; done ;;' \
    'esac' \
    'printf "%s\n" "$$" >"$probe_pid_file"' \
    "$probe_tree_body" \
    >"$probe_tree_path"
  chmod 0755 "$probe_tree_path"
}

run_direct_probe_case() {
  direct_probe_name=$1
  direct_probe_command=$2
  direct_probe_harness=$3
  shift 3
  direct_probe_root=$test_tmp/direct-probe-$direct_probe_name
  direct_probe_tmp=$direct_probe_root/tmp
  direct_probe_home=$direct_probe_root/home
  direct_probe_state=$direct_probe_root/state
  direct_probe_output=$direct_probe_root/output
  mkdir -p "$direct_probe_tmp" "$direct_probe_home" "$direct_probe_state"
  run_capture "$direct_probe_output" "$test_real_env" \
    TMPDIR="$direct_probe_tmp" \
    HOME="$direct_probe_home" \
    XDG_STATE_HOME="$direct_probe_state" \
    DOTFILES_BOOTSTRAP_TESTING=1 \
    DOTFILES_BOOTSTRAP_TEST_DIRECT_PROBE=1 \
    DOTFILES_BOOTSTRAP_TEST_DIRECT_PROBE_COMMAND="$direct_probe_command" \
    "$@" \
    "$direct_probe_harness" --apply
}

make_signal_boundary_command() {
  boundary_command_path=$1
  boundary_real_command=$2
  mkdir -p "$(dirname "$boundary_command_path")"
  # shellcheck disable=SC2016 # The generated wrapper expands these values at runtime.
  printf '%s\n' \
    '#!/bin/sh' \
    "real_command='$boundary_real_command'" \
    'command_target=' \
    'for command_argument do' \
    '  command_target=$command_argument' \
    'done' \
    '"$real_command" "$@"' \
    'command_status=$?' \
    '[ "$command_status" -eq 0 ] || exit "$command_status"' \
    'if [ "${DOTFILES_BOOTSTRAP_TEST_SIGNAL_COMMAND:-}" = "${0##*/}" ] \
      && [ "${DOTFILES_BOOTSTRAP_TEST_SIGNAL_TARGET:-}" = "$command_target" ]; then' \
    '  boundary_signal=${DOTFILES_BOOTSTRAP_TEST_MANAGED_SIGNAL:-TERM}' \
    '  case "$boundary_signal" in' \
    '    HUP|INT|TERM) ;;' \
    '    *) exit 2 ;;' \
    '  esac' \
    '  kill -s "$boundary_signal" "$PPID" || exit 1' \
    'fi' \
    'exit 0' \
    >"$boundary_command_path"
  chmod 0755 "$boundary_command_path"
}

make_managed_type_mutation_command() {
  mutation_command_path=$1
  mutation_real_command=$2
  mutation_real_move=$3
  mutation_real_mkdir=$4
  mkdir -p "$(dirname "$mutation_command_path")"
  # shellcheck disable=SC2016 # The generated wrapper expands its test environment.
  printf '%s\n' \
    '#!/bin/sh' \
    "real_command='$mutation_real_command'" \
    "real_move='$mutation_real_move'" \
    "real_mkdir='$mutation_real_mkdir'" \
    'command_target=' \
    'for command_argument do' \
    '  command_target=$command_argument' \
    'done' \
    '"$real_command" "$@"' \
    'command_status=$?' \
    '[ "$command_status" -eq 0 ] || exit "$command_status"' \
    'if [ "$command_target" = "$DOTFILES_BOOTSTRAP_TEST_MUTATION_TARGET" ]; then' \
    '  "$real_move" -- "$command_target" "$command_target.original" || exit 1' \
    '  case "$DOTFILES_BOOTSTRAP_TEST_MUTATION_KIND" in' \
    '    directory-to-file)' \
    "      printf '%s\\n' 'mutated Taplo directory' >\"\$command_target\" || exit 1" \
    '      ;;' \
    '    link-to-regular)' \
    "      printf '%s\\n' 'mutated Taplo link bytes' >\"\$command_target\" || exit 1" \
    '      ;;' \
    '    link-to-directory)' \
    '      "$real_mkdir" "$command_target" || exit 1' \
    "      printf '%s\\n' 'mutated Taplo link' >\"\$command_target/sentinel\" || exit 1" \
    '      ;;' \
    '    *) exit 2 ;;' \
    '  esac' \
    'fi' \
    'exit 0' \
    >"$mutation_command_path"
  chmod 0755 "$mutation_command_path"
}

make_link_result_command() {
  link_result_command_path=$1
  link_result_real_command=$2
  link_result_kind=$3
  mkdir -p "$(dirname "$link_result_command_path")"
  # shellcheck disable=SC2016 # This snippet is expanded by the generated fixture.
  case "$link_result_kind" in
    no-link)
      link_result_body='exit 0'
      ;;
    wrong-link)
      link_result_body='target=; for argument do target=$argument; done; "$real_command" -s /wrong/managed-link-target "$target"'
      ;;
    *) return 1 ;;
  esac
  # shellcheck disable=SC2016 # The generated fixture expands its arguments at runtime.
  printf '%s\n' \
    '#!/bin/sh' \
    "real_command='$link_result_real_command'" \
    "$link_result_body" \
    >"$link_result_command_path"
  chmod 0755 "$link_result_command_path"
}

make_managed_link_control_bootstrap() {
  control_bootstrap_source=$1
  control_bootstrap_target=$2
  awk '
    $0 == "platform=$(detect_platform)" {
      print "if [ \"${DOTFILES_BOOTSTRAP_TEST_CONTROL_LINK:-0}\" = 1 ]; then"
      print "  managed_created_paths_file=$DOTFILES_BOOTSTRAP_TEST_CONTROL_LINK_JOURNAL"
      print "  : >\"$managed_created_paths_file\""
      print "  managed_publish_active=true"
      print "  publish_managed_link \"$DOTFILES_BOOTSTRAP_TEST_CONTROL_LINK_SOURCE\" \"$DOTFILES_BOOTSTRAP_TEST_CONTROL_LINK_TARGET\""
      print "  exit 0"
      print "fi"
      injected += 1
    }
    { print }
    END {
      if (injected != 1) exit 1
    }
  ' "$control_bootstrap_source" >"$control_bootstrap_target"
  chmod 0755 "$control_bootstrap_target"
}

make_link_audit_command() {
  link_audit_command_path=$1
  link_audit_real_command=$2
  mkdir -p "$(dirname "$link_audit_command_path")"
  # shellcheck disable=SC2016 # The generated fixture expands its test environment.
  printf '%s\n' \
    '#!/bin/sh' \
    "real_command='$link_audit_real_command'" \
    'printf "%s\n" called >>"$DOTFILES_BOOTSTRAP_TEST_LINK_AUDIT_FILE"' \
    'exec "$real_command" "$@"' \
    >"$link_audit_command_path"
  chmod 0755 "$link_audit_command_path"
}

make_probe_spawn_signal_bootstrap() {
  probe_spawn_source=$1
  probe_spawn_target=$2
  awk '
    { print }
    $0 == "  active_probe_waiter_pid=$!" {
      print "  printf \"%s\\n\" \"$active_probe_waiter_pid\" >\"$DOTFILES_BOOTSTRAP_TEST_PROBE_RACE_PID_FILE\""
      print "  kill -TERM \"$$\""
      injected += 1
    }
    END {
      if (injected != 1) exit 1
    }
  ' "$probe_spawn_source" >"$probe_spawn_target"
  chmod 0755 "$probe_spawn_target"
}

make_probe_temp_signal_bootstrap() {
  probe_temp_source=$1
  probe_temp_target=$2
  awk '
    $0 == "  active_probe_tmp=$(temporary_directory) || {" {
      registering_probe_tmp = 1
    }
    { print }
    registering_probe_tmp && $0 == "  }" {
      print "  printf \"%s\\n\" \"$active_probe_tmp\" >\"$DOTFILES_BOOTSTRAP_TEST_PROBE_TEMP_RACE_PATH_FILE\""
      print "  kill -TERM \"$$\""
      injected += 1
      registering_probe_tmp = 0
    }
    END {
      if (injected != 1) exit 1
    }
  ' "$probe_temp_source" >"$probe_temp_target"
  chmod 0755 "$probe_temp_target"
}

make_managed_stage_signal_bootstrap() {
  managed_stage_source=$1
  managed_stage_target=$2
  awk '
    $0 == "install_debian_language_servers() {" { in_installer = 1 }
    in_installer && $0 == "}" { in_installer = 0 }
    in_installer && $0 == "  active_package_tmp=$managed_stage_root" {
      print "  printf \"%s\\n\" \"$managed_stage_root\" >\"$DOTFILES_BOOTSTRAP_TEST_MANAGED_STAGE_RACE_PATH_FILE\""
      print "  kill -TERM \"$$\""
      injected += 1
    }
    { print }
    END {
      if (injected != 1) exit 1
    }
  ' "$managed_stage_source" >"$managed_stage_target"
  chmod 0755 "$managed_stage_target"
}

make_exit_repeat_signal_bootstrap() {
  exit_repeat_source=$1
  exit_repeat_target=$2
  awk '
    { print }
    $0 == "  trap - 0" || $0 == "  trap \047\047 0 HUP INT TERM" {
      print "  kill -TERM \"$$\""
      injected += 1
    }
    END {
      if (injected != 1) exit 1
    }
  ' "$exit_repeat_source" >"$exit_repeat_target"
  chmod 0755 "$exit_repeat_target"
}

make_parquet_function_bootstrap() {
  parquet_function_source=$1
  parquet_function_target=$2
  awk '
    $0 == "platform=$(detect_platform)" {
      print "case ${DOTFILES_BOOTSTRAP_TEST_PARQUET_FUNCTION:-} in"
      print "  uv-executable)"
      print "    parquet_uv_executable"
      print "    exit $?"
      print "    ;;"
      print "  viewer-satisfied)"
      print "    parquet_viewer_is_satisfied"
      print "    exit $?"
      print "    ;;"
      print "  install)"
      print "    package_actions_file=${DOTFILES_BOOTSTRAP_TEST_PARQUET_ACTIONS:-}"
      print "    install_parquet_viewer"
      print "    exit $?"
      print "    ;;"
      print "  install-preserves-environment)"
      print "    package_actions_file=${DOTFILES_BOOTSTRAP_TEST_PARQUET_ACTIONS:-}"
      print "    parquet_install_status=0"
      print "    install_parquet_viewer || parquet_install_status=$?"
      print "    {"
      print "      printf \"UV_BUILD_CONSTRAINT=%s\\n\" \"${UV_BUILD_CONSTRAINT-<unset>}\""
      print "      printf \"UV_CONSTRAINT=%s\\n\" \"${UV_CONSTRAINT-<unset>}\""
      print "      printf \"UV_DEFAULT_INDEX=%s\\n\" \"${UV_DEFAULT_INDEX-<unset>}\""
      print "      printf \"UV_EXCLUDE=%s\\n\" \"${UV_EXCLUDE-<unset>}\""
      print "      printf \"UV_EXCLUDE_NEWER=%s\\n\" \"${UV_EXCLUDE_NEWER-<unset>}\""
      print "      printf \"UV_EXTRA_INDEX_URL=%s\\n\" \"${UV_EXTRA_INDEX_URL-<unset>}\""
      print "      printf \"UV_FIND_LINKS=%s\\n\" \"${UV_FIND_LINKS-<unset>}\""
      print "      printf \"UV_FORK_STRATEGY=%s\\n\" \"${UV_FORK_STRATEGY-<unset>}\""
      print "      printf \"UV_INDEX=%s\\n\" \"${UV_INDEX-<unset>}\""
      print "      printf \"UV_INDEX_STRATEGY=%s\\n\" \"${UV_INDEX_STRATEGY-<unset>}\""
      print "      printf \"UV_INDEX_URL=%s\\n\" \"${UV_INDEX_URL-<unset>}\""
      print "      printf \"UV_OVERRIDE=%s\\n\" \"${UV_OVERRIDE-<unset>}\""
      print "      printf \"UV_PRERELEASE=%s\\n\" \"${UV_PRERELEASE-<unset>}\""
      print "      printf \"UV_RESOLUTION=%s\\n\" \"${UV_RESOLUTION-<unset>}\""
      print "      printf \"UV_TORCH_BACKEND=%s\\n\" \"${UV_TORCH_BACKEND-<unset>}\""
      print "    } >\"$DOTFILES_BOOTSTRAP_TEST_PARQUET_CALLER_ENV_LOG\""
      print "    exit \"$parquet_install_status\""
      print "    ;;"
      print "esac"
      injected += 1
    }
    { print }
    END {
      if (injected != 1) exit 1
    }
  ' "$parquet_function_source" >"$parquet_function_target"
  chmod 0755 "$parquet_function_target"
}

make_parquet_uv_tool_command() {
  parquet_uv_command=$1
  mkdir -p "$(dirname "$parquet_uv_command")"
  # shellcheck disable=SC2016 # The generated fixture expands these values when invoked.
  printf '%s\n' \
    '#!/bin/sh' \
    'case "${1:-}" in' \
    '  --version)' \
    '    printf "%s\n" "${DOTFILES_BOOTSTRAP_TEST_PARQUET_UV_VERSION:-uv 0.12.5}"' \
    '    exit 0' \
    '    ;;' \
    '  tool)' \
    '    case "${2:-}" in' \
    '      dir)' \
    '        [ "${UV_OFFLINE:-}" = 1 ] || exit 92' \
    '        if [ "$#" -eq 3 ] && [ "${3:-}" = --no-config ]; then' \
    '          [ "${DOTFILES_BOOTSTRAP_TEST_PARQUET_TOOL_PROBE_FAIL:-0}" != 1 ] || exit 61' \
    '          printf "%s\n" "${UV_TOOL_DIR-${DOTFILES_BOOTSTRAP_TEST_PARQUET_TOOL_ROOT:-}}"' \
    '        elif [ "$#" -eq 4 ] && [ "${3:-}" = --bin ] && [ "${4:-}" = --no-config ]; then' \
    '          [ "${DOTFILES_BOOTSTRAP_TEST_PARQUET_BIN_PROBE_FAIL:-0}" != 1 ] || exit 62' \
    '          printf "%s\n" "${UV_TOOL_BIN_DIR-${DOTFILES_BOOTSTRAP_TEST_PARQUET_TOOL_BIN_ROOT:-$HOME/.local/bin}}"' \
    '        else' \
    '          exit 90' \
    '        fi' \
    '        exit 0' \
    '        ;;' \
    '      install)' \
    '        [ "$#" -eq 9 ] || exit 93' \
    '        [ "${3:-}" = --force ] || exit 94' \
    '        [ "${4:-}" = --with ] || exit 95' \
    '        [ "${5:-}" = pyarrow==25.0.0 ] || exit 96' \
    '        [ "${6:-}" = --with ] || exit 97' \
    '        [ "${7:-}" = duckdb==1.5.5 ] || exit 98' \
    '        [ "${8:-}" = --no-config ] || exit 99' \
    '        [ "${9:-}" = visidata==3.4 ] || exit 100' \
    '        if [ -n "${DOTFILES_BOOTSTRAP_TEST_PARQUET_INSTALL_MARKER:-}" ]; then' \
    '          : >"$DOTFILES_BOOTSTRAP_TEST_PARQUET_INSTALL_MARKER"' \
    '        fi' \
    '        case "${DOTFILES_BOOTSTRAP_TEST_PARQUET_INSTALL_BEHAVIOR:-succeed}" in' \
    '          fail) exit 42 ;;' \
    '          repair)' \
    '            : >"$DOTFILES_BOOTSTRAP_TEST_PARQUET_PROBE_MARKER"' \
    '            exit 0' \
    '            ;;' \
    '          repair-if-sanitized)' \
    '            [ "${UV_BUILD_CONSTRAINT+x}" != x ] || exit 70' \
    '            [ "${UV_CONSTRAINT+x}" != x ] || exit 71' \
    '            [ "${UV_EXCLUDE+x}" != x ] || exit 72' \
    '            [ "${UV_EXCLUDE_NEWER+x}" != x ] || exit 73' \
    '            [ "${UV_FORK_STRATEGY+x}" != x ] || exit 74' \
    '            [ "${UV_INDEX_STRATEGY+x}" != x ] || exit 79' \
    '            [ "${UV_INDEX+x}" != x ] || exit 69' \
    '            [ "${UV_DEFAULT_INDEX+x}" != x ] || exit 68' \
    '            [ "${UV_INDEX_URL+x}" != x ] || exit 67' \
    '            [ "${UV_EXTRA_INDEX_URL+x}" != x ] || exit 66' \
    '            [ "${UV_FIND_LINKS+x}" != x ] || exit 65' \
    '            [ "${UV_OVERRIDE+x}" != x ] || exit 75' \
    '            [ "${UV_PRERELEASE+x}" != x ] || exit 76' \
    '            [ "${UV_RESOLUTION+x}" != x ] || exit 77' \
    '            [ "${UV_TORCH_BACKEND+x}" != x ] || exit 78' \
    '            : >"$DOTFILES_BOOTSTRAP_TEST_PARQUET_PROBE_MARKER"' \
    '            exit 0' \
    '            ;;' \
    '          succeed) exit 0 ;;' \
    '          *) exit 99 ;;' \
    '        esac' \
    '        ;;' \
    '      *) exit 89 ;;' \
    '    esac' \
    '    ;;' \
    '  *) exit 88 ;;' \
    'esac' \
    >"$parquet_uv_command"
  chmod 0755 "$parquet_uv_command"
}

prepare_parquet_tool_environment() {
  parquet_environment_root=$1
  mkdir -p "$parquet_environment_root/visidata/bin"
  # shellcheck disable=SC2016 # The generated fixture expands these values when invoked.
  printf '%s\n' \
    '#!/bin/sh' \
    '[ "${PYTHONDONTWRITEBYTECODE:-}" = 1 ] || exit 80' \
    '[ "$#" -eq 4 ] || exit 81' \
    '[ "${1:-}" = -I ] || exit 82' \
    '[ "${2:-}" = -B ] || exit 83' \
    '[ "${3:-}" = -c ] || exit 84' \
    '[ -n "${4:-}" ] || exit 85' \
    '[ -n "${DOTFILES_BOOTSTRAP_TEST_PARQUET_PROBE_MARKER:-}" ] || exit 86' \
    'case "${4:-}" in *"\"visidata\":\"3.4\""*) ;; *) exit 87 ;; esac' \
    'case "${4:-}" in *"\"pyarrow\":\"25.0.0\""*) ;; *) exit 88 ;; esac' \
    'case "${4:-}" in *"\"duckdb\":\"1.5.5\""*) ;; *) exit 89 ;; esac' \
    'case "${4:-}" in *"import importlib.metadata as m,duckdb,pyarrow"*) ;; *) exit 90 ;; esac' \
    'case "${4:-}" in *"duckdb.__version__ == expected[\"duckdb\"]"*) ;; *) exit 91 ;; esac' \
    '[ -e "$DOTFILES_BOOTSTRAP_TEST_PARQUET_PROBE_MARKER" ]' \
    >"$parquet_environment_root/visidata/bin/python"
  printf '%s\n' '#!/bin/sh' 'exit 0' \
    >"$parquet_environment_root/visidata/bin/vd"
  chmod 0755 \
    "$parquet_environment_root/visidata/bin/python" \
    "$parquet_environment_root/visidata/bin/vd"
}

run_parquet_unsafe_target_case() {
  parquet_unsafe_name=$1
  parquet_unsafe_tool_root=$2
  parquet_unsafe_bin_root=$3
  parquet_unsafe_tool_probe_fail=$4
  parquet_unsafe_bin_probe_fail=$5
  parquet_unsafe_marker=$parquet_probe_root/$parquet_unsafe_name-install.invoked
  parquet_unsafe_actions=$parquet_probe_root/$parquet_unsafe_name.actions
  : >"$parquet_unsafe_actions"
  run_capture "$parquet_probe_root/$parquet_unsafe_name.output" env \
    PATH="$parquet_probe_bin:$test_utilities_bin" \
    HOME="$parquet_probe_root/home" \
    UV_TOOL_DIR="$parquet_unsafe_tool_root" \
    UV_TOOL_BIN_DIR="$parquet_unsafe_bin_root" \
    DOTFILES_BOOTSTRAP_TEST_PARQUET_TOOL_PROBE_FAIL="$parquet_unsafe_tool_probe_fail" \
    DOTFILES_BOOTSTRAP_TEST_PARQUET_BIN_PROBE_FAIL="$parquet_unsafe_bin_probe_fail" \
    DOTFILES_BOOTSTRAP_TEST_PARQUET_FUNCTION=install \
    DOTFILES_BOOTSTRAP_TEST_PARQUET_PROBE_MARKER="$parquet_probe_root/missing.marker" \
    DOTFILES_BOOTSTRAP_TEST_PARQUET_INSTALL_BEHAVIOR=succeed \
    DOTFILES_BOOTSTRAP_TEST_PARQUET_INSTALL_MARKER="$parquet_unsafe_marker" \
    DOTFILES_BOOTSTRAP_TEST_PARQUET_ACTIONS="$parquet_unsafe_actions" \
    "$parquet_function_bootstrap"
  if [ "$run_status" -ne 0 ] \
    && [ ! -e "$parquet_unsafe_marker" ] \
    && [ ! -s "$parquet_unsafe_actions" ]; then
    pass "Parquet installation rejects $parquet_unsafe_name before invocation"
  else
    fail "Parquet installation rejects $parquet_unsafe_name before invocation"
  fi
}

run_parquet_trailing_slash_target_case() {
  parquet_trailing_name=$1
  parquet_trailing_tool_root=$2
  parquet_trailing_bin_root=$3
  parquet_trailing_install_marker=$parquet_probe_root/$parquet_trailing_name-install.invoked
  parquet_trailing_probe_marker=$parquet_probe_root/$parquet_trailing_name-validation.succeeded
  parquet_trailing_actions=$parquet_probe_root/$parquet_trailing_name.actions
  : >"$parquet_trailing_actions"
  run_capture "$parquet_probe_root/$parquet_trailing_name.output" env \
    PATH="$parquet_probe_bin:$test_utilities_bin" \
    HOME="$parquet_probe_root/home" \
    UV_TOOL_DIR="$parquet_trailing_tool_root" \
    UV_TOOL_BIN_DIR="$parquet_trailing_bin_root" \
    DOTFILES_BOOTSTRAP_TEST_PARQUET_FUNCTION=install \
    DOTFILES_BOOTSTRAP_TEST_PARQUET_PROBE_MARKER="$parquet_trailing_probe_marker" \
    DOTFILES_BOOTSTRAP_TEST_PARQUET_INSTALL_BEHAVIOR=repair \
    DOTFILES_BOOTSTRAP_TEST_PARQUET_INSTALL_MARKER="$parquet_trailing_install_marker" \
    DOTFILES_BOOTSTRAP_TEST_PARQUET_ACTIONS="$parquet_trailing_actions" \
    "$parquet_function_bootstrap"
  if [ "$run_status" -eq 0 ] \
    && [ -e "$parquet_trailing_install_marker" ] \
    && [ -e "$parquet_trailing_probe_marker" ] \
    && [ "$(cat "$parquet_trailing_actions" 2>/dev/null || true)" \
      = 'uv-tool visidata@3.4+pyarrow@25.0.0+duckdb@1.5.5' ]; then
    pass "Parquet installation accepts $parquet_trailing_name"
  else
    fail "Parquet installation accepts $parquet_trailing_name"
  fi
}

make_probe_parent_hold_bootstrap() {
  probe_hold_source=$1
  probe_hold_target=$2
  awk '
    $0 == "bounded_command_succeeds() {" { in_bounded_probe = 1 }
    { print }
    in_bounded_probe && $0 == "  sleep 1" {
      print "  if [ \"${DOTFILES_BOOTSTRAP_TEST_PROBE_PARENT_HOLD:-0}\" = 1 ]; then"
      print "    : >\"$DOTFILES_BOOTSTRAP_TEST_PROBE_PARENT_HOLD_READY\""
      print "    probe_parent_hold_attempt=0"
      print "    while [ \"$probe_parent_hold_attempt\" -lt 80 ] && [ ! -e \"$DOTFILES_BOOTSTRAP_TEST_PROBE_PARENT_HOLD_RELEASE\" ]; do"
      print "      sleep 0.05"
      print "      probe_parent_hold_attempt=$((probe_parent_hold_attempt + 1))"
      print "    done"
      print "    if [ ! -e \"$DOTFILES_BOOTSTRAP_TEST_PROBE_PARENT_HOLD_RELEASE\" ]; then"
      print "      : >\"$DOTFILES_BOOTSTRAP_TEST_PROBE_PARENT_HOLD_FAILED\""
      print "      return 1"
      print "    fi"
      print "  fi"
      injected += 1
    }
    in_bounded_probe && $0 == "}" { in_bounded_probe = 0 }
    END {
      if (injected != 1) exit 1
    }
  ' "$probe_hold_source" >"$probe_hold_target"
  chmod 0755 "$probe_hold_target"
}

make_package_tracking_audit_bootstrap() {
  package_tracking_source=$1
  package_tracking_target=$2
  awk '
    $0 == "start_package_tracking() {" {
      print
      print "  if [ \"${DOTFILES_BOOTSTRAP_TESTING:-0}\" = 1 ] && [ -n \"${DOTFILES_BOOTSTRAP_TEST_PACKAGE_TRACKING_MARKER:-}\" ]; then"
      print "    : >\"$DOTFILES_BOOTSTRAP_TEST_PACKAGE_TRACKING_MARKER\" || exit 97"
      print "  fi"
      injected += 1
      next
    }
    { print }
    END {
      if (injected != 1) exit 1
    }
  ' "$package_tracking_source" >"$package_tracking_target"
  chmod 0755 "$package_tracking_target"
}

make_failing_runtime_capability_command() {
  runtime_capability_kind=$1
  runtime_capability_path=$2
  runtime_capability_log=$3
  runtime_capability_real_command=$4
  mkdir -p "$(dirname "$runtime_capability_path")"
  # shellcheck disable=SC2016 # The generated fixture expands its test environment.
  printf '%s\n' \
    '#!/bin/sh' \
    "runtime_capability_kind='$runtime_capability_kind'" \
    "runtime_capability_log='$runtime_capability_log'" \
    "runtime_capability_real_command='$runtime_capability_real_command'" \
    'runtime_capability_match=false' \
    'case "$runtime_capability_kind:$#" in' \
    '  setsid:5)' \
    '    [ "$1" = -f ] && [ "$2" = -w ] && [ "$3" = /bin/sh ] && [ "$4" = -c ] && [ "$5" = "exit 0" ] && runtime_capability_match=true' \
    '    ;;' \
    '  env:4)' \
    '    [ "$1" = --default-signal=HUP,INT,TERM ] && [ "$2" = /bin/sh ] && [ "$3" = -c ] && [ "$4" = "exit 0" ] && runtime_capability_match=true' \
    '    ;;' \
    'esac' \
    'if [ "$runtime_capability_match" = true ]; then' \
    '  for runtime_capability_argument do' \
    '    printf "%s\n" "$runtime_capability_argument" >>"$runtime_capability_log"' \
    '  done' \
    '  exit 64' \
    'fi' \
    'exec "$runtime_capability_real_command" "$@"' \
    >"$runtime_capability_path"
  chmod 0755 "$runtime_capability_path"
}

make_direct_runtime_command() {
  direct_runtime_kind=$1
  direct_runtime_path=$2
  direct_runtime_log=$3
  direct_runtime_real_command=$4
  direct_runtime_mode=$5
  mkdir -p "$(dirname "$direct_runtime_path")"
  # shellcheck disable=SC2016 # The generated fixture expands its arguments.
  printf '%s\n' \
    '#!/bin/sh' \
    "direct_runtime_kind='$direct_runtime_kind'" \
    "direct_runtime_log='$direct_runtime_log'" \
    "direct_runtime_real_command='$direct_runtime_real_command'" \
    "direct_runtime_mode='$direct_runtime_mode'" \
    'direct_runtime_capability=false' \
    'case "$direct_runtime_kind:$#" in' \
    '  setsid:5)' \
    '    [ "$1" = -f ] && [ "$2" = -w ] && [ "$3" = /bin/sh ] && [ "$4" = -c ] && [ "$5" = "exit 0" ] && direct_runtime_capability=true' \
    '    ;;' \
    '  env:4)' \
    '    [ "$1" = --default-signal=HUP,INT,TERM ] && [ "$2" = /bin/sh ] && [ "$3" = -c ] && [ "$4" = "exit 0" ] && direct_runtime_capability=true' \
    '    ;;' \
    'esac' \
    'if [ "$direct_runtime_capability" = true ]; then' \
    '  printf "%s|%s|%s" capability "$direct_runtime_kind" "$0" >>"$direct_runtime_log"' \
    'else' \
    '  printf "%s|%s|%s" launch "$direct_runtime_kind" "$0" >>"$direct_runtime_log"' \
    'fi' \
    'for direct_runtime_argument do' \
    '  printf "|%s" "$direct_runtime_argument" >>"$direct_runtime_log"' \
    'done' \
    'printf "\n" >>"$direct_runtime_log"' \
    'if [ "$direct_runtime_capability" = true ]; then' \
    '  exec "$direct_runtime_real_command" "$@"' \
    'fi' \
    'case "$direct_runtime_mode" in' \
    '  delegate) exec "$direct_runtime_real_command" "$@" ;;' \
    '  reject-launch) exit 64 ;;' \
    '  *) exit 2 ;;' \
    'esac' \
    >"$direct_runtime_path"
  chmod 0755 "$direct_runtime_path"
}

make_post_gate_poison_command() {
  post_gate_poison_path=$1
  post_gate_poison_log=$2
  mkdir -p "$(dirname "$post_gate_poison_path")"
  # shellcheck disable=SC2016 # The generated fixture expands its arguments.
  printf '%s\n' \
    '#!/bin/sh' \
    "post_gate_poison_log='$post_gate_poison_log'" \
    'printf "%s" "${0##*/}" >>"$post_gate_poison_log"' \
    'for post_gate_poison_argument do' \
    '  printf "|%s" "$post_gate_poison_argument" >>"$post_gate_poison_log"' \
    'done' \
    'printf "\n" >>"$post_gate_poison_log"' \
    'exit 65' \
    >"$post_gate_poison_path"
  chmod 0755 "$post_gate_poison_path"
}

expected_runtime_capability_args() {
  runtime_capability_kind=$1
  printf '%s\n' runtime-capability-baseline
  case "$runtime_capability_kind" in
    setsid)
      printf '%s\n' -f -w /bin/sh -c 'exit 0'
      ;;
    env)
      printf '%s\n' \
        '--default-signal=HUP,INT,TERM' \
        /bin/sh \
        -c \
        'exit 0'
      ;;
    *) return 1 ;;
  esac
}

runtime_capability_diagnostic() {
  case "$1" in
    setsid)
      printf '%s\n' \
        'bootstrap: util-linux setsid -f -w is required for Debian language-server probes'
      ;;
    env)
      printf '%s\n' \
        'bootstrap: GNU env --default-signal=HUP,INT,TERM is required for Debian language-server probes'
      ;;
    *) return 1 ;;
  esac
}

make_runtime_git_command() {
  runtime_git_path=$1
  runtime_git_log=$2
  runtime_git_mutation_marker=$3
  runtime_git_mode=$4
  runtime_real_git=$5
  mkdir -p "$(dirname "$runtime_git_path")"
  # shellcheck disable=SC2016 # The generated fixture expands its arguments.
  printf '%s\n' \
    '#!/bin/sh' \
    "runtime_git_log='$runtime_git_log'" \
    "runtime_git_mutation_marker='$runtime_git_mutation_marker'" \
    "runtime_git_mode='$runtime_git_mode'" \
    "runtime_real_git='$runtime_real_git'" \
    'printf "%s" git >>"$runtime_git_log"' \
    'for runtime_git_argument do' \
    '  printf "|%s" "$runtime_git_argument" >>"$runtime_git_log"' \
    'done' \
    'printf "\n" >>"$runtime_git_log"' \
    'case "$runtime_git_mode" in' \
    '  missing)' \
    '    if [ "$#" -eq 1 ] && [ "$1" = --version ]; then exit 1; fi' \
    '    exit 64' \
    '    ;;' \
    '  present)' \
    '    if [ "$#" -eq 1 ] && [ "$1" = --version ]; then' \
    '      exec "$runtime_real_git" "$@"' \
    '    fi' \
    '    case "${1:-}" in' \
    '      rev-parse|show|show-ref|cat-file|status|version)' \
    '        exec "$runtime_real_git" "$@"' \
    '        ;;' \
    '      config)' \
    '        case "${2:-}" in' \
    '          --get|--get-all|--get-regexp|--list)' \
    '            exec "$runtime_real_git" "$@"' \
    '            ;;' \
    '        esac' \
    '        ;;' \
    '    esac' \
    '    printf "%s\n" "git-mutation|$*" >"$runtime_git_mutation_marker"' \
    '    exit 64' \
    '    ;;' \
    '  *) exit 2 ;;' \
    'esac' \
    >"$runtime_git_path"
  chmod 0755 "$runtime_git_path"
}

seed_runtime_bytes() {
  runtime_seed_root=$1
  runtime_seed_home=$2
  runtime_seed_state=$3
  printf '%s\n' 'seeded HOME bytes' >"$runtime_seed_home/sentinel"
  printf '%s\n' 'seeded state bytes' >"$runtime_seed_state/sentinel"
  cp "$runtime_seed_home/sentinel" "$runtime_seed_root/home.expected"
  cp "$runtime_seed_state/sentinel" "$runtime_seed_root/state.expected"
}

runtime_seed_bytes_are_preserved() {
  runtime_seed_root=$1
  runtime_seed_home=$2
  runtime_seed_state=$3
  cmp -s "$runtime_seed_root/home.expected" "$runtime_seed_home/sentinel" \
    && cmp -s "$runtime_seed_root/state.expected" "$runtime_seed_state/sentinel"
}

runtime_probe_residue_is_absent() {
  runtime_probe_tmp=$1
  ! find "$runtime_probe_tmp" -mindepth 1 -maxdepth 1 \
    -name 'dotfiles-bootstrap.*' -print -quit | grep -q .
}

run_debian_runtime_apply_case() {
  runtime_apply_name=$1
  runtime_apply_kind=$2
  runtime_apply_root=$test_tmp/runtime-apply-$runtime_apply_name
  runtime_apply_bin=$runtime_apply_root/bin
  runtime_apply_home=$runtime_apply_root/home
  runtime_apply_state=$runtime_apply_root/state
  runtime_apply_tmp=$runtime_apply_root/tmp
  runtime_apply_output_path=$runtime_apply_root/output
  runtime_apply_command_log=$runtime_apply_root/commands
  runtime_apply_capability_log=$runtime_apply_root/capability.args
  runtime_apply_tracking_marker=$runtime_apply_root/package-tracking.started
  runtime_apply_harness=$runtime_apply_root/harness
  runtime_apply_bootstrap=$runtime_apply_harness/bootstrap
  mkdir -p \
    "$runtime_apply_bin" \
    "$runtime_apply_home" \
    "$runtime_apply_state" \
    "$runtime_apply_tmp" \
    "$runtime_apply_harness"
  cp -R "$dotfiles_dir/manifests" "$runtime_apply_harness/manifests"
  make_package_tracking_audit_bootstrap \
    "$bootstrap" "$runtime_apply_bootstrap"
  seed_runtime_bytes \
    "$runtime_apply_root" "$runtime_apply_home" "$runtime_apply_state"
  printf '%s\n' runtime-command-baseline >"$runtime_apply_command_log"
  printf '%s\n' runtime-capability-baseline \
    >"$runtime_apply_capability_log"
  make_failing_runtime_capability_command \
    "$runtime_apply_kind" \
    "$runtime_apply_bin/$runtime_apply_kind" \
    "$runtime_apply_capability_log" \
    "$(case "$runtime_apply_kind" in
      setsid) printf '%s\n' "$test_real_setsid" ;;
      env) printf '%s\n' "$test_real_env" ;;
    esac)"

  run_capture "$runtime_apply_output_path" "$test_real_env" \
    PATH="$runtime_apply_bin:$test_utilities_bin" \
    TMPDIR="$runtime_apply_tmp" \
    HOME="$runtime_apply_home" \
    XDG_STATE_HOME="$runtime_apply_state" \
    DOTFILES_BOOTSTRAP_TESTING=1 \
    DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
    DOTFILES_BOOTSTRAP_TEST_MANAGER=apt \
    DOTFILES_BOOTSTRAP_TEST_ARCH=x86_64 \
    DOTFILES_BOOTSTRAP_TEST_ALL_PACKAGES_MISSING=1 \
    DOTFILES_BOOTSTRAP_TEST_SATISFIED_TOOLS= \
    DOTFILES_BOOTSTRAP_TEST_APT_GHOSTTY_OFFICIAL=1 \
    DOTFILES_BOOTSTRAP_TEST_STOP_AFTER_PACKAGES=1 \
    DOTFILES_BOOTSTRAP_TEST_COMMAND_LOG="$runtime_apply_command_log" \
    DOTFILES_BOOTSTRAP_TEST_PACKAGE_TRACKING_MARKER="$runtime_apply_tracking_marker" \
    "$runtime_apply_bootstrap" --apply
  runtime_apply_status=$run_status
  runtime_apply_output=$(cat "$runtime_apply_output_path" 2>/dev/null || true)
  runtime_apply_commands=$(cat "$runtime_apply_command_log" 2>/dev/null || true)
  runtime_apply_capability_args=$(
    cat "$runtime_apply_capability_log" 2>/dev/null || true
  )
  runtime_apply_residue=false
  runtime_probe_residue_is_absent "$runtime_apply_tmp" \
    && runtime_apply_residue=true
  runtime_apply_tracking_started=false
  [ ! -e "$runtime_apply_tracking_marker" ] \
    || runtime_apply_tracking_started=true
  runtime_apply_seed_preserved=false
  runtime_seed_bytes_are_preserved \
    "$runtime_apply_root" "$runtime_apply_home" "$runtime_apply_state" \
    && runtime_apply_seed_preserved=true
}

run_debian_runtime_boundary_case() {
  runtime_boundary_name=$1
  runtime_boundary_kind=$2
  runtime_boundary=$3
  runtime_boundary_root=$test_tmp/runtime-boundary-$runtime_boundary_name
  runtime_boundary_bin=$runtime_boundary_root/bin
  runtime_boundary_home=$runtime_boundary_root/home
  runtime_boundary_state=$runtime_boundary_root/state
  runtime_boundary_tmp=$runtime_boundary_root/tmp
  runtime_boundary_output_path=$runtime_boundary_root/output
  runtime_boundary_command_log=$runtime_boundary_root/commands
  runtime_boundary_git_log=$runtime_boundary_root/git.args
  runtime_boundary_git_mutation_marker=$runtime_boundary_root/git.mutation
  runtime_boundary_capability_log=$runtime_boundary_root/capability.args
  runtime_boundary_tracking_marker=$runtime_boundary_root/package-tracking.started
  runtime_boundary_bootstrap=$runtime_boundary_root/bootstrap
  mkdir -p \
    "$runtime_boundary_bin" \
    "$runtime_boundary_home" \
    "$runtime_boundary_state" \
    "$runtime_boundary_tmp"
  make_package_tracking_audit_bootstrap \
    "$bootstrap" "$runtime_boundary_bootstrap"
  seed_runtime_bytes \
    "$runtime_boundary_root" "$runtime_boundary_home" "$runtime_boundary_state"
  printf '%s\n' runtime-command-baseline >"$runtime_boundary_command_log"
  printf '%s\n' runtime-git-baseline >"$runtime_boundary_git_log"
  printf '%s\n' runtime-capability-baseline \
    >"$runtime_boundary_capability_log"
  make_failing_runtime_capability_command \
    "$runtime_boundary_kind" \
    "$runtime_boundary_bin/$runtime_boundary_kind" \
    "$runtime_boundary_capability_log" \
    "$(case "$runtime_boundary_kind" in
      setsid) printf '%s\n' "$test_real_setsid" ;;
      env) printf '%s\n' "$test_real_env" ;;
    esac)"
  case "$runtime_boundary" in
    standalone) runtime_boundary_git_mode=missing ;;
    remote) runtime_boundary_git_mode=present ;;
    *) return 1 ;;
  esac
  make_runtime_git_command \
    "$runtime_boundary_bin/git" \
    "$runtime_boundary_git_log" \
    "$runtime_boundary_git_mutation_marker" \
    "$runtime_boundary_git_mode" \
    "$test_real_git"

  case "$runtime_boundary" in
    standalone)
      run_capture "$runtime_boundary_output_path" "$test_real_env" \
        PATH="$runtime_boundary_bin:$test_utilities_bin" \
        TMPDIR="$runtime_boundary_tmp" \
        HOME="$runtime_boundary_home" \
        XDG_STATE_HOME="$runtime_boundary_state" \
        DOTFILES_BOOTSTRAP_TESTING=1 \
        DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
        DOTFILES_BOOTSTRAP_TEST_MANAGER=apt \
        DOTFILES_BOOTSTRAP_TEST_ARCH=x86_64 \
        DOTFILES_BOOTSTRAP_TEST_ALL_PACKAGES_MISSING=1 \
        DOTFILES_BOOTSTRAP_TEST_SATISFIED_TOOLS= \
        DOTFILES_BOOTSTRAP_TEST_APT_GHOSTTY_OFFICIAL=1 \
        DOTFILES_BOOTSTRAP_TEST_COMMAND_LOG="$runtime_boundary_command_log" \
        DOTFILES_BOOTSTRAP_TEST_PACKAGE_TRACKING_MARKER="$runtime_boundary_tracking_marker" \
        /bin/sh "$runtime_boundary_bootstrap" --apply
      ;;
    remote)
      run_capture "$runtime_boundary_output_path" "$test_real_env" \
        PATH="$runtime_boundary_bin:$test_utilities_bin" \
        TMPDIR="$runtime_boundary_tmp" \
        HOME="$runtime_boundary_home" \
        XDG_STATE_HOME="$runtime_boundary_state" \
        DOTFILES_BOOTSTRAP_TESTING=1 \
        DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
        DOTFILES_BOOTSTRAP_TEST_MANAGER=apt \
        DOTFILES_BOOTSTRAP_TEST_ARCH=x86_64 \
        DOTFILES_BOOTSTRAP_TEST_ALL_PACKAGES_MISSING=1 \
        DOTFILES_BOOTSTRAP_TEST_SATISFIED_TOOLS= \
        DOTFILES_BOOTSTRAP_TEST_APT_GHOSTTY_OFFICIAL=1 \
        DOTFILES_BOOTSTRAP_TEST_COMMAND_LOG="$runtime_boundary_command_log" \
        DOTFILES_BOOTSTRAP_TEST_PACKAGE_TRACKING_MARKER="$runtime_boundary_tracking_marker" \
        /bin/sh "$runtime_boundary_bootstrap" \
        --repo https://example.invalid/dotfiles.git --ref main
      ;;
  esac
  runtime_boundary_status=$run_status
  runtime_boundary_output=$(
    cat "$runtime_boundary_output_path" 2>/dev/null || true
  )
  runtime_boundary_commands=$(
    cat "$runtime_boundary_command_log" 2>/dev/null || true
  )
  runtime_boundary_capability_args=$(
    cat "$runtime_boundary_capability_log" 2>/dev/null || true
  )
  runtime_boundary_git_mutated=false
  [ ! -e "$runtime_boundary_git_mutation_marker" ] \
    || runtime_boundary_git_mutated=true
  runtime_boundary_residue=false
  runtime_probe_residue_is_absent "$runtime_boundary_tmp" \
    && runtime_boundary_residue=true
  runtime_boundary_tracking_started=false
  [ ! -e "$runtime_boundary_tracking_marker" ] \
    || runtime_boundary_tracking_started=true
  runtime_boundary_seed_preserved=false
  runtime_seed_bytes_are_preserved \
    "$runtime_boundary_root" "$runtime_boundary_home" "$runtime_boundary_state" \
    && runtime_boundary_seed_preserved=true
}

wait_for_probe_record() {
  probe_record_tmp=$1
  probe_record_name=$2
  probe_record_owner=${3:-}
  probe_record_attempt=0
  observed_probe_record=
  while [ "$probe_record_attempt" -lt 80 ]; do
    observed_probe_record=$(
      find "$probe_record_tmp" -mindepth 2 -maxdepth 2 \
        -path "*/dotfiles-bootstrap.*/$probe_record_name" \
        -print -quit 2>/dev/null || true
    )
    [ -z "$observed_probe_record" ] || return 0
    if [ -n "$probe_record_owner" ]; then
      probe_record_owner_state=$(
        ps -p "$probe_record_owner" -o state= 2>/dev/null \
          | awk 'NR == 1 { print $1 }'
      )
      case "$probe_record_owner_state" in
        ''|Z) return 1 ;;
      esac
    fi
    sleep 0.05
    probe_record_attempt=$((probe_record_attempt + 1))
  done
  return 1
}

probe_process_state_and_ticks() {
  observed_probe_pid=$1
  [ -r "/proc/$observed_probe_pid/stat" ] || return 1
  awk '{ print $3 "|" ($14 + $15) }' "/proc/$observed_probe_pid/stat"
}

probe_group_member_count() {
  observed_probe_group=$1
  ps -e -o pid= -o pgid= 2>/dev/null | awk \
    -v group_id="$observed_probe_group" '
      $1 ~ /^[0-9]+$/ && $2 == group_id { members += 1 }
      END { print members + 0 }
    '
}

probe_group_identity_snapshot() {
  observed_probe_group=$1
  ps -e \
    -o pid= \
    -o ppid= \
    -o pgid= \
    -o sid= \
    -o state= \
    2>/dev/null | awk -v group_id="$observed_probe_group" '
      $1 ~ /^[0-9]+$/ && $3 == group_id {
        print $1 "|" $2 "|" $3 "|" $4 "|" $5
      }
    '
}

probe_child_count() {
  observed_probe_parent=$1
  ps -e -o pid= -o ppid= 2>/dev/null | awk \
    -v parent_id="$observed_probe_parent" '
      $1 ~ /^[0-9]+$/ && $2 == parent_id { children += 1 }
      END { print children + 0 }
    '
}

test_pid_is_safe() {
  case $1 in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -gt 1 ]
}

test_process_id_field_is_valid() {
  case $1 in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 1 ]
}

capture_test_process() {
  captured_process_pid=$1
  captured_process_match=$2
  captured_process_expected_parent=${3:-}
  test_pid_is_safe "$captured_process_pid" || return 1
  captured_process_line=$(
    ps -p "$captured_process_pid" \
      -o pid= -o ppid= -o pgid= -o sid= -o command= 2>/dev/null \
      | awk 'NR == 1 { print; exit }'
  )
  [ -n "$captured_process_line" ] || return 1
  captured_process_command=
  IFS=' ' read -r \
    captured_process_observed_pid \
    captured_process_parent \
    captured_process_group \
    captured_process_session \
    captured_process_command <<CAPTURED_PROCESS
$captured_process_line
CAPTURED_PROCESS
  test_pid_is_safe "$captured_process_observed_pid" || return 1
  test_pid_is_safe "$captured_process_parent" || return 1
  test_process_id_field_is_valid "$captured_process_group" || return 1
  test_process_id_field_is_valid "$captured_process_session" || return 1
  [ "$captured_process_observed_pid" = "$captured_process_pid" ] \
    || return 1
  if [ -n "$captured_process_expected_parent" ]; then
    [ "$captured_process_parent" = "$captured_process_expected_parent" ] \
      || return 1
  fi
  case $captured_process_command in
    *"$captured_process_match"*) ;;
    *) return 1 ;;
  esac
  captured_process_identity=$captured_process_observed_pid\|$captured_process_parent\|$captured_process_group\|$captured_process_session
}

capture_test_process_bounded() {
  bounded_capture_pid=$1
  bounded_capture_match=$2
  bounded_capture_parent=${3:-}
  bounded_capture_attempt=0
  while [ "$bounded_capture_attempt" -lt 80 ]; do
    if capture_test_process \
      "$bounded_capture_pid" "$bounded_capture_match" "$bounded_capture_parent"; then
      bounded_capture_identity=$captured_process_identity
      bounded_capture_command=$captured_process_command
      sleep 0.05
      if capture_test_process \
        "$bounded_capture_pid" "$bounded_capture_match" "$bounded_capture_parent" \
        && [ "$captured_process_identity" = "$bounded_capture_identity" ] \
        && [ "$captured_process_command" = "$bounded_capture_command" ]; then
        return 0
      fi
    fi
    sleep 0.05
    bounded_capture_attempt=$((bounded_capture_attempt + 1))
  done
  return 1
}

test_process_identity_matches() {
  matching_identity_pid=$1
  matching_identity_expected=$2
  matching_identity_command=$3
  test_pid_is_safe "$matching_identity_pid" || return 1
  [ -n "$matching_identity_expected" ] || return 1
  matching_identity_line=$(
    ps -p "$matching_identity_pid" \
      -o pid= -o ppid= -o pgid= -o sid= -o command= 2>/dev/null \
      | awk 'NR == 1 { print; exit }'
  )
  [ -n "$matching_identity_line" ] || return 1
  matching_identity_observed_command=
  IFS=' ' read -r \
    matching_identity_observed_pid \
    matching_identity_parent \
    matching_identity_group \
    matching_identity_session \
    matching_identity_observed_command <<MATCHING_IDENTITY
$matching_identity_line
MATCHING_IDENTITY
  matching_identity_observed=$matching_identity_observed_pid\|$matching_identity_parent\|$matching_identity_group\|$matching_identity_session
  [ "$matching_identity_observed" = "$matching_identity_expected" ] \
    && [ "$matching_identity_observed_command" = "$matching_identity_command" ]
}

signal_verified_test_process() {
  verified_signal_name=$1
  verified_signal_pid=$2
  verified_signal_identity=$3
  verified_signal_command=$4
  case $verified_signal_name in
    CONT|HUP|INT|TERM|KILL) ;;
    *) return 1 ;;
  esac
  test_pid_is_safe "$verified_signal_pid" || return 1
  test_process_identity_matches \
    "$verified_signal_pid" \
    "$verified_signal_identity" \
    "$verified_signal_command" \
    || return 1
  kill -"$verified_signal_name" "$verified_signal_pid"
}

test_process_identity_has_state() {
  identity_state_pid=$1
  identity_state_expected=$2
  identity_state_value=$3
  test_pid_is_safe "$identity_state_pid" || return 1
  identity_state_line=$(
    ps -p "$identity_state_pid" \
      -o pid= -o ppid= -o pgid= -o sid= -o state= 2>/dev/null \
      | awk 'NR == 1 { print; exit }'
  )
  [ -n "$identity_state_line" ] || return 1
  identity_state_observed_state=
  IFS=' ' read -r \
    identity_state_observed_pid \
    identity_state_parent \
    identity_state_group \
    identity_state_session \
    identity_state_observed_state <<IDENTITY_STATE
$identity_state_line
IDENTITY_STATE
  identity_state_observed=$identity_state_observed_pid\|$identity_state_parent\|$identity_state_group\|$identity_state_session
  [ "$identity_state_observed" = "$identity_state_expected" ] \
    && [ "$identity_state_observed_state" = "$identity_state_value" ]
}

wait_for_test_process_exit() {
  observed_process_pid=$1
  observed_process_identity=$2
  observed_process_command=$3
  observed_process_attempt=0
  while [ "$observed_process_attempt" -lt 80 ]; do
    observed_process_state=$(ps -p "$observed_process_pid" -o state= 2>/dev/null \
      | awk 'NR == 1 { print $1 }')
    case "$observed_process_state" in
      ''|Z) return 0 ;;
    esac
    if [ -n "$observed_process_identity" ] \
      && [ -n "$observed_process_command" ] \
      && ! test_process_identity_matches \
        "$observed_process_pid" \
        "$observed_process_identity" \
        "$observed_process_command"; then
      return 0
    fi
    sleep 0.05
    observed_process_attempt=$((observed_process_attempt + 1))
  done
  return 1
}

wait_for_test_process_state() {
  observed_process_pid=$1
  observed_process_identity=$2
  expected_process_state=$3
  observed_process_attempt=0
  while [ "$observed_process_attempt" -lt 80 ]; do
    test_process_identity_has_state \
      "$observed_process_pid" \
      "$observed_process_identity" \
      "$expected_process_state" \
      && return 0
    sleep 0.05
    observed_process_attempt=$((observed_process_attempt + 1))
  done
  return 1
}

probe_fd_access_mode() {
  probe_fd_pid=$1
  probe_fd_number=$2
  test_pid_is_safe "$probe_fd_pid" || return 1
  case $probe_fd_number in
    ''|*[!0-9]*) return 1 ;;
  esac
  awk '
    $1 == "flags:" && $2 ~ /^[0-7]+$/ {
      print substr($2, length($2), 1)
      found = 1
      exit
    }
    END { if (!found) exit 1 }
  ' "/proc/$probe_fd_pid/fdinfo/$probe_fd_number"
}

private_probe_process_ids() {
  private_probe_path=$1
  ps -e -o pid= -o command= 2>/dev/null \
    | while IFS=' ' read -r private_probe_list_pid private_probe_list_command; do
        case $private_probe_list_command in
          *"$private_probe_path"*)
            printf '%s\n' "$private_probe_list_pid"
            ;;
        esac
      done
}

private_probe_processes_are_absent() {
  [ -z "$(private_probe_process_ids "$1")" ]
}

kill_private_probe_processes() {
  private_probe_path=$1
  private_probe_cleanup_attempt=0
  while [ "$private_probe_cleanup_attempt" -lt 40 ]; do
    private_probe_pids=$(private_probe_process_ids "$private_probe_path")
    [ -n "$private_probe_pids" ] || return 0
    for private_probe_pid in $private_probe_pids; do
      if test_pid_is_safe "$private_probe_pid" \
        && capture_test_process "$private_probe_pid" "$private_probe_path"; then
        private_probe_identity=$captured_process_identity
        private_probe_command=$captured_process_command
        signal_verified_test_process \
          CONT "$private_probe_pid" \
          "$private_probe_identity" "$private_probe_command" \
          >/dev/null 2>&1 || true
        signal_verified_test_process \
          KILL "$private_probe_pid" \
          "$private_probe_identity" "$private_probe_command" \
          >/dev/null 2>&1 || true
      fi
    done
    sleep 0.05
    private_probe_cleanup_attempt=$((private_probe_cleanup_attempt + 1))
  done
  private_probe_processes_are_absent "$private_probe_path"
}

finish_async_probe_case() {
  async_probe_owner=$1
  async_probe_owner_identity=$2
  async_probe_owner_command=$3
  async_probe_anchor=$4
  async_probe_anchor_identity=$5
  async_probe_anchor_command=$6
  async_probe_waiter=$7
  async_probe_waiter_identity=$8
  async_probe_waiter_command=$9
  async_probe_private_root=${10}
  async_probe_owner_match=${11}
  async_probe_was_forced=false
  async_probe_reaped=false
  async_probe_status=125
  if { [ -z "$async_probe_owner_identity" ] \
    || [ -z "$async_probe_owner_command" ]; } \
    && capture_test_process_bounded \
      "$async_probe_owner" "$async_probe_owner_match" "$$"; then
    async_probe_owner_identity=$captured_process_identity
    async_probe_owner_command=$captured_process_command
  fi
  if ! wait_for_test_process_exit \
    "$async_probe_owner" \
    "$async_probe_owner_identity" \
    "$async_probe_owner_command"; then
    async_probe_was_forced=true
    signal_verified_test_process \
      CONT "$async_probe_anchor" \
      "$async_probe_anchor_identity" "$async_probe_anchor_command" \
      >/dev/null 2>&1 || true
    signal_verified_test_process \
      CONT "$async_probe_owner" \
      "$async_probe_owner_identity" "$async_probe_owner_command" \
      >/dev/null 2>&1 || true
    signal_verified_test_process \
      TERM "$async_probe_owner" \
      "$async_probe_owner_identity" "$async_probe_owner_command" \
      >/dev/null 2>&1 || true
  fi
  if ! wait_for_test_process_exit \
    "$async_probe_owner" \
    "$async_probe_owner_identity" \
    "$async_probe_owner_command"; then
    async_probe_was_forced=true
    signal_verified_test_process \
      CONT "$async_probe_anchor" \
      "$async_probe_anchor_identity" "$async_probe_anchor_command" \
      >/dev/null 2>&1 || true
    signal_verified_test_process \
      KILL "$async_probe_anchor" \
      "$async_probe_anchor_identity" "$async_probe_anchor_command" \
      >/dev/null 2>&1 || true
    signal_verified_test_process \
      CONT "$async_probe_waiter" \
      "$async_probe_waiter_identity" "$async_probe_waiter_command" \
      >/dev/null 2>&1 || true
    signal_verified_test_process \
      KILL "$async_probe_waiter" \
      "$async_probe_waiter_identity" "$async_probe_waiter_command" \
      >/dev/null 2>&1 || true
    signal_verified_test_process \
      KILL "$async_probe_owner" \
      "$async_probe_owner_identity" "$async_probe_owner_command" \
      >/dev/null 2>&1 || true
    kill_private_probe_processes "$async_probe_private_root"
  fi
  if wait_for_test_process_exit \
    "$async_probe_owner" \
    "$async_probe_owner_identity" \
    "$async_probe_owner_command" \
    && {
      async_probe_terminal_state=$(
        ps -p "$async_probe_owner" -o state= 2>/dev/null \
          | awk 'NR == 1 { print $1 }'
      )
      case $async_probe_terminal_state in
        ''|Z) true ;;
        *) false ;;
      esac
    }; then
    set +e
    wait "$async_probe_owner" >/dev/null 2>&1
    async_probe_status=$?
    set -e
    async_probe_reaped=true
  fi
  if test_process_identity_matches \
    "$async_probe_anchor" \
    "$async_probe_anchor_identity" \
    "$async_probe_anchor_command"; then
    async_probe_was_forced=true
    signal_verified_test_process \
      CONT "$async_probe_anchor" \
      "$async_probe_anchor_identity" "$async_probe_anchor_command" \
      >/dev/null 2>&1 || true
    signal_verified_test_process \
      KILL "$async_probe_anchor" \
      "$async_probe_anchor_identity" "$async_probe_anchor_command" \
      >/dev/null 2>&1 || true
  fi
  if test_process_identity_matches \
    "$async_probe_waiter" \
    "$async_probe_waiter_identity" \
    "$async_probe_waiter_command"; then
    async_probe_was_forced=true
    signal_verified_test_process \
      CONT "$async_probe_waiter" \
      "$async_probe_waiter_identity" "$async_probe_waiter_command" \
      >/dev/null 2>&1 || true
    signal_verified_test_process \
      KILL "$async_probe_waiter" \
      "$async_probe_waiter_identity" "$async_probe_waiter_command" \
      >/dev/null 2>&1 || true
  fi
  if ! private_probe_processes_are_absent "$async_probe_private_root"; then
    async_probe_was_forced=true
    kill_private_probe_processes "$async_probe_private_root"
  fi
}

prepare_satisfaction_commands() {
  satisfaction_bin=$1
  satisfaction_node_version=$2
  satisfaction_npm_version=$3
  satisfaction_bash_version=$4
  satisfaction_json_behavior=$5
  satisfaction_lua_version=$6
  satisfaction_pyright_behavior=$7
  satisfaction_pyright_version=$8
  satisfaction_yaml_version=$9
  satisfaction_uv_version=${10}
  satisfaction_taplo_version=${11-taplo 0.10.0}
  satisfaction_taplo_behavior=${12:-success}

  mkdir -p "$satisfaction_bin"
  make_version_command "$satisfaction_bin/node" "$satisfaction_node_version"
  make_version_command "$satisfaction_bin/npm" "$satisfaction_npm_version"
  make_version_command "$satisfaction_bin/bash-language-server" "$satisfaction_bash_version"
  make_stdio_command "$satisfaction_bin/vscode-json-language-server" \
    "$satisfaction_json_behavior"
  make_version_command "$satisfaction_bin/lua-language-server" "$satisfaction_lua_version"
  make_stdio_command "$satisfaction_bin/pyright-langserver" \
    "$satisfaction_pyright_behavior"
  make_version_command "$satisfaction_bin/pyright" "$satisfaction_pyright_version"
  make_taplo_command "$satisfaction_bin/taplo" \
    "$satisfaction_taplo_version" "$satisfaction_taplo_behavior"
  make_version_command "$satisfaction_bin/yaml-language-server" "$satisfaction_yaml_version"
  make_version_command "$satisfaction_bin/uv" "$satisfaction_uv_version"
  make_version_command "$satisfaction_bin/nvim" '0.12.4'
  make_version_command "$satisfaction_bin/stylua" '2.5.2'
  make_version_command "$satisfaction_bin/tree-sitter" '0.26.9'
  make_version_command "$satisfaction_bin/herdr" '0.8.0'
  printf '%s\n' '#!/bin/sh' "printf '%s\\n' 'install ok installed'" \
    >"$satisfaction_bin/dpkg-query"
  printf '%s\n' '#!/bin/sh' 'exit 0' >"$satisfaction_bin/apt-cache"
  printf '%s\n' '#!/bin/sh' "printf '%s\\n' 'SpaceMono Nerd Font Mono'" \
    >"$satisfaction_bin/fc-list"
  chmod 0755 \
    "$satisfaction_bin/dpkg-query" \
    "$satisfaction_bin/apt-cache" \
    "$satisfaction_bin/fc-list"
}

run_satisfaction_case() {
  satisfaction_name=$1
  shift
  satisfaction_root=$test_tmp/satisfaction-$satisfaction_name
  satisfaction_bin=$satisfaction_root/bin
  satisfaction_log=$satisfaction_root/commands
  mkdir -p "$satisfaction_root"
  prepare_satisfaction_commands "$satisfaction_bin" "$@"
  run_capture "$satisfaction_root/output" env \
    PATH="$satisfaction_bin:$test_utilities_bin" \
    HOME="$satisfaction_root/home" \
    XDG_STATE_HOME="$satisfaction_root/state" \
    DOTFILES_BOOTSTRAP_TESTING=1 \
    DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
    DOTFILES_BOOTSTRAP_TEST_MANAGER=apt \
    DOTFILES_BOOTSTRAP_TEST_APT_GHOSTTY_OFFICIAL=1 \
    DOTFILES_BOOTSTRAP_TEST_STOP_AFTER_PACKAGES=1 \
    DOTFILES_BOOTSTRAP_TEST_TAPLO_PROBE_PID_FILE="$satisfaction_root/taplo-probe.pid" \
    DOTFILES_BOOTSTRAP_TEST_COMMAND_LOG="$satisfaction_log" \
    "$bootstrap" --apply
  satisfaction_case_status=$run_status
  satisfaction_case_commands=$(cat "$satisfaction_log" 2>/dev/null || true)
}

create_fake_node_archive() {
  fake_download_root=$1
  fake_source_root=$2
  fake_architecture=$3
  case "$fake_architecture" in
    x86_64)
      fake_node_archive_root=node-v24.19.0-linux-x64
      fake_node_asset=node-v24.19.0-linux-x64.tar.xz
      ;;
    arm64)
      fake_node_archive_root=node-v24.19.0-linux-arm64
      fake_node_asset=node-v24.19.0-linux-arm64.tar.xz
      ;;
    *) return 1 ;;
  esac
  fake_node_root=$fake_source_root/$fake_node_archive_root
  mkdir -p "$fake_node_root/bin" "$fake_node_root/lib/node_modules/npm/bin"
  system_node=$(command -v node)
  # shellcheck disable=SC2016 # Generated fixtures expand these values when invoked.
  printf '%s\n' \
    '#!/bin/sh' \
    'if [ "${1:-}" = --version ]; then' \
    "  printf '%s\\n' 'v24.19.0'" \
    '  exit 0' \
    'fi' \
    "exec '$system_node' \"\$@\"" \
    >"$fake_node_root/bin/node"
  # shellcheck disable=SC2016 # Generated fixtures expand these values when invoked.
  printf '%s\n' \
    '#!/bin/sh' \
    'if [ "${1:-}" = --version ]; then' \
    "  printf '%s\\n' '11.17.0'" \
    '  exit 0' \
    'fi' \
    '[ "${1:-}" = ci ] || exit 1' \
    'shift' \
    'if [ -n "${DOTFILES_BOOTSTRAP_TEST_COMMAND_LOG:-}" ]; then' \
    "  printf '%s' 'npm-ci' >>\"\$DOTFILES_BOOTSTRAP_TEST_COMMAND_LOG\"" \
    '  for npm_argument do' \
    "    printf ' %s' \"\$npm_argument\" >>\"\$DOTFILES_BOOTSTRAP_TEST_COMMAND_LOG\"" \
    '  done' \
    "  printf '\\n' >>\"\$DOTFILES_BOOTSTRAP_TEST_COMMAND_LOG\"" \
    'fi' \
    '[ "${DOTFILES_BOOTSTRAP_TEST_NPM_FAIL:-0}" != 1 ] || exit 42' \
    'mkdir -p node_modules/.bin' \
    'for package_name in bash-language-server pyright vscode-langservers-extracted yaml-language-server; do' \
    '  mkdir -p "node_modules/$package_name"' \
    "  printf '%s\\n' '{}' >\"node_modules/\$package_name/package.json\"" \
    'done' \
    'for command_name in bash-language-server vscode-json-language-server pyright-langserver yaml-language-server vscode-css-language-server vscode-html-language-server vscode-eslint-language-server pyright npx corepack; do' \
    '  [ "$command_name" != "${DOTFILES_BOOTSTRAP_TEST_NPM_MISSING_COMMAND:-}" ] || continue' \
    "  printf '%s\\n' '#!/bin/sh' 'exit 0' >\"node_modules/.bin/\$command_name\"" \
    '  chmod 0755 "node_modules/.bin/$command_name"' \
    'done' \
    >"$fake_node_root/bin/npm"
  chmod 0755 "$fake_node_root/bin/node" "$fake_node_root/bin/npm"
  : >"$fake_node_root/lib/node_modules/npm/bin/npm-cli.js"
  tar -cJf "$fake_download_root/$fake_node_asset" \
    -C "$fake_source_root" "$fake_node_archive_root"
  fake_node_sha=$(file_sha256_for_test "$fake_download_root/$fake_node_asset")
}

create_fake_lua_archive() {
  fake_download_root=$1
  fake_source_root=$2
  fake_architecture=$3
  case "$fake_architecture" in
    x86_64) fake_lua_asset=lua-language-server-3.19.1-linux-x64.tar.gz ;;
    arm64) fake_lua_asset=lua-language-server-3.19.1-linux-arm64.tar.gz ;;
    *) return 1 ;;
  esac
  fake_lua_root=$fake_source_root/lua-$fake_architecture
  mkdir -p \
    "$fake_lua_root/bin" \
    "$fake_lua_root/locale" \
    "$fake_lua_root/meta" \
    "$fake_lua_root/script"
  printf '%s\n' '#!/bin/sh' 'exit 0' >"$fake_lua_root/bin/lua-language-server"
  chmod 0755 "$fake_lua_root/bin/lua-language-server"
  : >"$fake_lua_root/LICENSE"
  : >"$fake_lua_root/changelog.md"
  : >"$fake_lua_root/debugger.lua"
  : >"$fake_lua_root/main.lua"
  : >"$fake_lua_root/bin/main.lua"
  : >"$fake_lua_root/locale/.keep"
  : >"$fake_lua_root/meta/.keep"
  : >"$fake_lua_root/script/.keep"
  (
    cd "$fake_lua_root"
    tar -czf "$fake_download_root/$fake_lua_asset" \
      LICENSE bin changelog.md debugger.lua locale main.lua meta script
  )
  fake_lua_sha=$(file_sha256_for_test "$fake_download_root/$fake_lua_asset")
}

create_fake_taplo_asset() {
  fake_download_root=$1
  fake_source_root=$2
  fake_architecture=$3
  case "$fake_architecture" in
    x86_64) fake_taplo_asset=taplo-linux-x86_64.gz ;;
    arm64) fake_taplo_asset=taplo-linux-aarch64.gz ;;
    *) return 1 ;;
  esac
  fake_taplo_path=$fake_source_root/taplo-$fake_architecture
  make_taplo_command "$fake_taplo_path" 'taplo 0.10.0' success
  gzip -c "$fake_taplo_path" >"$fake_download_root/$fake_taplo_asset"
  fake_taplo_sha=$(file_sha256_for_test \
    "$fake_download_root/$fake_taplo_asset")
}

create_fake_rishot_asset_variant() {
  fake_rishot_download_root=$1
  fake_rishot_source_root=$2
  fake_rishot_variant=$3
  fake_rishot_revision=28c273b1b573725e03ef12989451f48009dabc83
  fake_rishot_root_name=rishot-$fake_rishot_revision
  fake_rishot_root=$fake_rishot_source_root/$fake_rishot_root_name
  mkdir -p "$fake_rishot_download_root" "$fake_rishot_source_root"

  if [ "$fake_rishot_variant" = traversal ]; then
    printf '%s\n' payload >"$fake_rishot_source_root/payload"
    tar -czf "$fake_rishot_download_root/$fake_rishot_revision" \
      --transform="s|^payload$|$fake_rishot_root_name/../escape|" \
      -C "$fake_rishot_source_root" payload
  else
    mkdir -p "$fake_rishot_root/bin" "$fake_rishot_root/src"
    case "$fake_rishot_variant" in
      normal)
        printf '%s\n' '#!/bin/sh' 'exit 0' \
          >"$fake_rishot_root/bin/rishot"
        chmod 0755 "$fake_rishot_root/bin/rishot"
        printf '%s\n' 'import QtQuick' \
          >"$fake_rishot_root/src/shell.qml"
        ;;
      symlink)
        ln -s ../../escape "$fake_rishot_root/bin/rishot"
        printf '%s\n' 'import QtQuick' \
          >"$fake_rishot_root/src/shell.qml"
        ;;
      missing-launcher)
        printf '%s\n' 'import QtQuick' \
          >"$fake_rishot_root/src/shell.qml"
        ;;
      missing-qml)
        printf '%s\n' '#!/bin/sh' 'exit 0' \
          >"$fake_rishot_root/bin/rishot"
        chmod 0755 "$fake_rishot_root/bin/rishot"
        ;;
      *) return 1 ;;
    esac
    tar -czf "$fake_rishot_download_root/$fake_rishot_revision" \
      -C "$fake_rishot_source_root" "$fake_rishot_root_name"
  fi
  fake_rishot_sha=$(file_sha256_for_test \
    "$fake_rishot_download_root/$fake_rishot_revision")
}

create_fake_rishot_asset() {
  create_fake_rishot_asset_variant "$1" "$2" normal
}

rewrite_rishot_fixture_sha() {
  rishot_rewrite_manifest=$1
  rishot_rewrite_sha=$2
  awk -F '\t' -v OFS='\t' -v sha256="$rishot_rewrite_sha" '
    $1 == "rishot" && $2 == "linux" && $3 == "any" { $7 = sha256 }
    { print }
  ' "$rishot_rewrite_manifest" >"$rishot_rewrite_manifest.new"
  mv "$rishot_rewrite_manifest.new" "$rishot_rewrite_manifest"
}

file_sha256_for_test() {
  test_checksum_path=$1
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$test_checksum_path" | awk '{ print $1 }'
  else
    shasum -a 256 "$test_checksum_path" | awk '{ print $1 }'
  fi
}

project_state_fingerprint() {
  project_state_root=$1
  (
    CDPATH='' cd -- "$project_state_root"
    find . -print | LC_ALL=C sort | while IFS= read -r project_state_entry; do
      if [ -L "$project_state_entry" ]; then
        printf 'link %s %s\n' \
          "$project_state_entry" "$(readlink "$project_state_entry")"
      elif [ -d "$project_state_entry" ]; then
        printf 'directory %s\n' "$project_state_entry"
      elif [ -f "$project_state_entry" ]; then
        printf 'file %s %s\n' \
          "$project_state_entry" \
          "$(file_sha256_for_test "$project_state_entry")"
      else
        printf 'other %s\n' "$project_state_entry"
      fi
    done
  )
}

run_managed_architecture_case() {
  managed_case_architecture=$1
  managed_case_home=$test_tmp/managed-$managed_case_architecture-home
  managed_case_state=$test_tmp/managed-$managed_case_architecture-state
  managed_case_log=$test_tmp/managed-$managed_case_architecture.commands
  mkdir -p "$managed_case_home"
  run_capture "$test_tmp/managed-$managed_case_architecture.output" env \
    HOME="$managed_case_home" \
    XDG_STATE_HOME="$managed_case_state" \
    DOTFILES_BOOTSTRAP_TESTING=1 \
    DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
    DOTFILES_BOOTSTRAP_TEST_MANAGER=apt \
    DOTFILES_BOOTSTRAP_TEST_ARCH="$managed_case_architecture" \
    DOTFILES_BOOTSTRAP_TEST_ALL_PACKAGES_MISSING=1 \
    DOTFILES_BOOTSTRAP_TEST_SATISFIED_TOOLS= \
    DOTFILES_BOOTSTRAP_TEST_APT_GHOSTTY_OFFICIAL=1 \
    DOTFILES_BOOTSTRAP_TEST_REAL_MANAGED_INSTALL=1 \
    DOTFILES_BOOTSTRAP_TEST_DOWNLOAD_ROOT="$managed_fixture_download" \
    DOTFILES_BOOTSTRAP_TEST_STOP_AFTER_PACKAGES=1 \
    DOTFILES_BOOTSTRAP_TEST_COMMAND_LOG="$managed_case_log" \
    "$managed_fixture_root/bootstrap" --apply
  managed_case_status=$run_status
  managed_case_commands=$(cat "$managed_case_log" 2>/dev/null || true)
}

path_exists_for_test() {
  [ -e "$1" ] || [ -L "$1" ]
}

managed_outputs_are_absent_except() {
  managed_absence_home=$1
  managed_absence_allowed=${2:-}

  for managed_absence_path in \
    "$managed_absence_home/.local/bin/node" \
    "$managed_absence_home/.local/bin/npm" \
    "$managed_absence_home/.local/bin/lua-language-server" \
    "$managed_absence_home/.local/bin/bash-language-server" \
    "$managed_absence_home/.local/bin/vscode-json-language-server" \
    "$managed_absence_home/.local/bin/pyright-langserver" \
    "$managed_absence_home/.local/bin/taplo" \
    "$managed_absence_home/.local/bin/yaml-language-server" \
    "$managed_absence_home/.local/opt"/node-* \
    "$managed_absence_home/.local/opt"/lua-language-server-* \
    "$managed_absence_home/.local/opt"/taplo-* \
    "$managed_absence_home/.local/opt"/dotfiles-lsp-node-*
  do
    if path_exists_for_test "$managed_absence_path" \
      && [ "$managed_absence_path" != "$managed_absence_allowed" ]; then
      return 1
    fi
  done
  return 0
}

prepare_managed_failure_case() {
  managed_failure_name=$1
  managed_failure_root=$test_tmp/managed-failure-$managed_failure_name
  managed_failure_harness=$managed_failure_root/harness
  managed_failure_download=$managed_failure_root/downloads
  managed_failure_source=$managed_failure_root/source
  managed_failure_home=$managed_failure_root/home
  managed_failure_state=$managed_failure_root/state
  managed_failure_tmp=$managed_failure_root/tmp
  managed_failure_log=$managed_failure_root/commands
  managed_failure_bin=$managed_failure_root/bin
  mkdir -p \
    "$managed_failure_bin" \
    "$managed_failure_harness" \
    "$managed_failure_download" \
    "$managed_failure_source" \
    "$managed_failure_home" \
    "$managed_failure_tmp"
  cp -R "$managed_fixture_root/." "$managed_failure_harness/"
  cp -R "$managed_fixture_download/." "$managed_failure_download/"
  cp -R "$managed_fixture_source/x86_64/." "$managed_failure_source/"
}

set_failure_case_direct_asset() {
  failure_asset_tool=$1
  failure_asset_url=$2
  failure_asset_sha256=$3
  failure_asset_manifest=$managed_failure_harness/manifests/packages-direct.tsv
  awk -F '\t' -v OFS='\t' \
    -v tool="$failure_asset_tool" \
    -v url="$failure_asset_url" \
    -v sha256="$failure_asset_sha256" '
    $1 == tool && $2 == "linux" && $3 == "x86_64" {
      $6 = url
      $7 = sha256
    }
    { print }
  ' "$failure_asset_manifest" >"$failure_asset_manifest.new"
  mv "$failure_asset_manifest.new" "$failure_asset_manifest"
}

set_failure_case_taplo_field() {
  failure_taplo_field=$1
  failure_taplo_value=$2
  failure_asset_manifest=$managed_failure_harness/manifests/packages-direct.tsv
  awk -F '\t' -v OFS='\t' \
    -v field="$failure_taplo_field" \
    -v value="$failure_taplo_value" '
    $1 == "taplo" && $2 == "linux" && $3 == "x86_64" {
      $field = value
    }
    { print }
  ' "$failure_asset_manifest" >"$failure_asset_manifest.new"
  mv "$failure_asset_manifest.new" "$failure_asset_manifest"
}

remove_failure_case_taplo_record() {
  failure_asset_manifest=$managed_failure_harness/manifests/packages-direct.tsv
  awk -F '\t' '
    !($1 == "taplo" && $2 == "linux" && $3 == "x86_64") { print }
  ' "$failure_asset_manifest" >"$failure_asset_manifest.new"
  mv "$failure_asset_manifest.new" "$failure_asset_manifest"
}

duplicate_failure_case_taplo_record() {
  failure_asset_manifest=$managed_failure_harness/manifests/packages-direct.tsv
  awk -F '\t' '
    { print }
    $1 == "taplo" && $2 == "linux" && $3 == "x86_64" { print }
  ' "$failure_asset_manifest" >"$failure_asset_manifest.new"
  mv "$failure_asset_manifest.new" "$failure_asset_manifest"
}

refresh_failure_case_lock_hash() {
  failure_lock_path=$managed_failure_harness/manifests/packages-npm-language-servers-lock.json
  failure_lock_sha256=$(file_sha256_for_test "$failure_lock_path")
  awk -v sha256="$failure_lock_sha256" '
    /^npm_language_servers_lock_sha256=/ {
      print "npm_language_servers_lock_sha256=" sha256
      next
    }
    { print }
  ' "$managed_failure_harness/bootstrap" \
    >"$managed_failure_harness/bootstrap.new"
  mv "$managed_failure_harness/bootstrap.new" \
    "$managed_failure_harness/bootstrap"
  chmod 0755 "$managed_failure_harness/bootstrap"
}

run_managed_failure_case() {
  managed_failure_expected=$1
  managed_failure_publish_token=${2:-}
  managed_failure_npm_fail=${3:-0}
  managed_failure_missing_command=${4:-}
  managed_failure_architecture=${5:-x86_64}
  managed_failure_signal_token=${6:-}

  managed_failure_signal_command=
  managed_failure_signal_target=
  case "$managed_failure_signal_token" in
    '')
      ;;
    parent-directory)
      managed_failure_signal_command='mkdir'
      # .local is now created by the ownership guard before provisioning.
      # Interrupt the original pre-journal package-parent creation instead.
      managed_failure_signal_target=$managed_failure_home/.local/opt
      ;;
    managed-directory)
      managed_failure_signal_command='mv'
      managed_failure_signal_target=$managed_failure_home/.local/opt/node-24.19.0-$managed_failure_architecture
      ;;
    managed-link)
      managed_failure_signal_command='ln'
      managed_failure_signal_target=$managed_failure_home/.local/bin/node
      ;;
    lua-wrapper)
      managed_failure_signal_command='mv'
      managed_failure_signal_target=$managed_failure_home/.local/bin/lua-language-server
      ;;
    taplo-directory)
      managed_failure_signal_command='mv'
      managed_failure_signal_target=$managed_failure_home/.local/opt/taplo-0.10.0-$managed_failure_architecture
      ;;
    taplo-link)
      managed_failure_signal_command='ln'
      managed_failure_signal_target=$managed_failure_home/.local/bin/taplo
      ;;
    *)
      return 1
      ;;
  esac
  if [ -n "$managed_failure_signal_command" ]; then
    managed_failure_real_command=$(command -v "$managed_failure_signal_command")
    make_signal_boundary_command \
      "$managed_failure_bin/$managed_failure_signal_command" \
      "$managed_failure_real_command"
  fi

  run_capture "$managed_failure_root/output" env \
    PATH="$managed_failure_bin:$PATH" \
    TMPDIR="$managed_failure_tmp" \
    HOME="$managed_failure_home" \
    XDG_STATE_HOME="$managed_failure_state" \
    DOTFILES_BOOTSTRAP_TESTING=1 \
    DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
    DOTFILES_BOOTSTRAP_TEST_MANAGER=apt \
    DOTFILES_BOOTSTRAP_TEST_ARCH="$managed_failure_architecture" \
    DOTFILES_BOOTSTRAP_TEST_ALL_PACKAGES_MISSING=1 \
    DOTFILES_BOOTSTRAP_TEST_SATISFIED_TOOLS= \
    DOTFILES_BOOTSTRAP_TEST_APT_GHOSTTY_OFFICIAL=1 \
    DOTFILES_BOOTSTRAP_TEST_REAL_MANAGED_INSTALL=1 \
    DOTFILES_BOOTSTRAP_TEST_DOWNLOAD_ROOT="$managed_failure_download" \
    DOTFILES_BOOTSTRAP_TEST_PUBLISH_FAIL_AFTER="$managed_failure_publish_token" \
    DOTFILES_BOOTSTRAP_TEST_SIGNAL_COMMAND="$managed_failure_signal_command" \
    DOTFILES_BOOTSTRAP_TEST_SIGNAL_TARGET="$managed_failure_signal_target" \
    DOTFILES_BOOTSTRAP_TEST_NPM_FAIL="$managed_failure_npm_fail" \
    DOTFILES_BOOTSTRAP_TEST_NPM_MISSING_COMMAND="$managed_failure_missing_command" \
    DOTFILES_BOOTSTRAP_TEST_STOP_AFTER_PACKAGES=1 \
    DOTFILES_BOOTSTRAP_TEST_COMMAND_LOG="$managed_failure_log" \
    "$managed_failure_harness/bootstrap" --apply
  managed_failure_status=$run_status
  managed_failure_output=$(cat "$managed_failure_root/output")
  managed_failure_commands=$(cat "$managed_failure_log" 2>/dev/null || true)
  managed_failure_pass=true
  [ "$managed_failure_status" -ne 0 ] || managed_failure_pass=false
  printf '%s\n' "$managed_failure_output" \
    | grep -Fq "$managed_failure_expected" \
    || managed_failure_pass=false
  managed_outputs_are_absent_except "$managed_failure_home" \
    || managed_failure_pass=false
  if find "$managed_failure_tmp" -mindepth 1 -maxdepth 1 \
    -name 'dotfiles-bootstrap.*' -print -quit \
    | grep -q .; then
    managed_failure_pass=false
  fi

  if [ "$managed_failure_pass" = true ]; then
    pass "$managed_failure_name rejects invalid managed provisioning without publication"
  else
    fail "$managed_failure_name rejects invalid managed provisioning without publication"
    sed "s/^/  $managed_failure_name output: /" \
      "$managed_failure_root/output" >&2
  fi
}

run_managed_type_mutation_case() {
  mutation_name=$1
  mutation_kind=$2
  mutation_label=${3:-$mutation_name cleanup refuses a changed Taplo path type}
  prepare_managed_failure_case "type-mutation-$mutation_name"
  mkdir -p \
    "$managed_failure_home/.local/bin" \
    "$managed_failure_home/.local/opt"
  printf '%s\n' 'type mutation sentinel' \
    >"$managed_failure_home/preexisting-sentinel"

  case "$mutation_kind" in
    directory-to-file)
      mutation_command='mv'
      mutation_target=$managed_failure_home/.local/opt/taplo-0.10.0-x86_64
      mutation_publish_token=
      mutation_diagnostic='refusing unjournaled managed directory cleanup for changed path'
      ;;
    link-to-regular)
      mutation_command='ln'
      mutation_target=$managed_failure_home/.local/bin/taplo
      mutation_publish_token=taplo-link
      mutation_diagnostic='refusing unjournaled managed link cleanup for changed path'
      ;;
    link-to-directory)
      mutation_command='ln'
      mutation_target=$managed_failure_home/.local/bin/taplo
      mutation_publish_token=taplo-link
      mutation_diagnostic='refusing unjournaled managed link cleanup for changed path'
      ;;
    *) return 1 ;;
  esac

  make_managed_type_mutation_command \
    "$managed_failure_bin/$mutation_command" \
    "$(command -v "$mutation_command")" \
    "$(command -v mv)" \
    "$(command -v mkdir)"

  run_capture "$managed_failure_root/output" env \
    PATH="$managed_failure_bin:$PATH" \
    TMPDIR="$managed_failure_tmp" \
    HOME="$managed_failure_home" \
    XDG_STATE_HOME="$managed_failure_state" \
    DOTFILES_BOOTSTRAP_TESTING=1 \
    DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
    DOTFILES_BOOTSTRAP_TEST_MANAGER=apt \
    DOTFILES_BOOTSTRAP_TEST_ARCH=x86_64 \
    DOTFILES_BOOTSTRAP_TEST_ALL_PACKAGES_MISSING=1 \
    DOTFILES_BOOTSTRAP_TEST_SATISFIED_TOOLS= \
    DOTFILES_BOOTSTRAP_TEST_APT_GHOSTTY_OFFICIAL=1 \
    DOTFILES_BOOTSTRAP_TEST_REAL_MANAGED_INSTALL=1 \
    DOTFILES_BOOTSTRAP_TEST_DOWNLOAD_ROOT="$managed_failure_download" \
    DOTFILES_BOOTSTRAP_TEST_PUBLISH_FAIL_AFTER="$mutation_publish_token" \
    DOTFILES_BOOTSTRAP_TEST_MUTATION_TARGET="$mutation_target" \
    DOTFILES_BOOTSTRAP_TEST_MUTATION_KIND="$mutation_kind" \
    DOTFILES_BOOTSTRAP_TEST_STOP_AFTER_PACKAGES=1 \
    DOTFILES_BOOTSTRAP_TEST_COMMAND_LOG="$managed_failure_log" \
    "$managed_failure_harness/bootstrap" --apply
  mutation_status=$run_status
  mutation_pass=true
  [ "$mutation_status" -ne 0 ] || mutation_pass=false
  grep -Fq "$mutation_diagnostic" "$managed_failure_root/output" \
    || mutation_pass=false
  path_exists_for_test "$mutation_target.original" \
    || mutation_pass=false
  [ "$(cat "$managed_failure_home/preexisting-sentinel" 2>/dev/null || true)" \
    = 'type mutation sentinel' ] || mutation_pass=false
  case "$mutation_kind" in
    directory-to-file)
      [ -f "$mutation_target" ] && [ ! -L "$mutation_target" ] \
        || mutation_pass=false
      ;;
    link-to-regular)
      [ -f "$mutation_target" ] && [ ! -L "$mutation_target" ] \
        && [ "$(cat "$mutation_target" 2>/dev/null || true)" \
          = 'mutated Taplo link bytes' ] \
        || mutation_pass=false
      ;;
    link-to-directory)
      [ -d "$mutation_target" ] && [ ! -L "$mutation_target" ] \
        && [ "$(cat "$mutation_target/sentinel" 2>/dev/null || true)" \
          = 'mutated Taplo link' ] \
        || mutation_pass=false
      ;;
  esac
  if find "$managed_failure_tmp" -mindepth 1 -maxdepth 1 \
    -name 'dotfiles-bootstrap.*' -print -quit | grep -q .; then
    mutation_pass=false
  fi

  if [ "$mutation_pass" = true ]; then
    pass "$mutation_label"
  else
    fail "$mutation_label"
    sed "s/^/  $mutation_name output: /" \
      "$managed_failure_root/output" >&2
  fi
}

run_journaled_link_mutation_case() {
  journaled_mutation_name=$1
  journaled_mutation_kind=$2
  prepare_managed_failure_case "journaled-$journaled_mutation_name"
  mkdir -p \
    "$managed_failure_home/.local/bin" \
    "$managed_failure_home/.local/opt"
  journaled_mutation_target=$managed_failure_home/.local/bin/taplo
  run_capture "$managed_failure_root/output" env \
    PATH="$managed_failure_bin:$PATH" \
    TMPDIR="$managed_failure_tmp" \
    HOME="$managed_failure_home" \
    XDG_STATE_HOME="$managed_failure_state" \
    DOTFILES_BOOTSTRAP_TESTING=1 \
    DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
    DOTFILES_BOOTSTRAP_TEST_MANAGER=apt \
    DOTFILES_BOOTSTRAP_TEST_ARCH=x86_64 \
    DOTFILES_BOOTSTRAP_TEST_ALL_PACKAGES_MISSING=1 \
    DOTFILES_BOOTSTRAP_TEST_SATISFIED_TOOLS= \
    DOTFILES_BOOTSTRAP_TEST_APT_GHOSTTY_OFFICIAL=1 \
    DOTFILES_BOOTSTRAP_TEST_REAL_MANAGED_INSTALL=1 \
    DOTFILES_BOOTSTRAP_TEST_DOWNLOAD_ROOT="$managed_failure_download" \
    DOTFILES_BOOTSTRAP_TEST_PUBLISH_FAIL_AFTER=taplo-link \
    DOTFILES_BOOTSTRAP_TEST_LINK_MUTATION_PHASE=after-journal \
    DOTFILES_BOOTSTRAP_TEST_LINK_MUTATION_KIND="$journaled_mutation_kind" \
    DOTFILES_BOOTSTRAP_TEST_LINK_MUTATION_TARGET="$journaled_mutation_target" \
    DOTFILES_BOOTSTRAP_TEST_STOP_AFTER_PACKAGES=1 \
    DOTFILES_BOOTSTRAP_TEST_COMMAND_LOG="$managed_failure_log" \
    "$managed_failure_harness/bootstrap" --apply
  journaled_mutation_status=$run_status
  journaled_mutation_pass=true
  [ "$journaled_mutation_status" -ne 0 ] || journaled_mutation_pass=false
  grep -Fq 'refusing managed link cleanup for changed path' \
    "$managed_failure_root/output" || journaled_mutation_pass=false
  case "$journaled_mutation_kind" in
    regular)
      [ -f "$journaled_mutation_target" ] \
        && [ ! -L "$journaled_mutation_target" ] \
        && [ "$(cat "$journaled_mutation_target" 2>/dev/null || true)" \
          = 'mutated Taplo link bytes' ] \
        || journaled_mutation_pass=false
      ;;
    directory)
      [ -d "$journaled_mutation_target" ] \
        && [ ! -L "$journaled_mutation_target" ] \
        && [ "$(cat "$journaled_mutation_target/sentinel" \
          2>/dev/null || true)" = 'mutated Taplo link directory' ] \
        || journaled_mutation_pass=false
      ;;
    *) return 1 ;;
  esac
  if find "$managed_failure_tmp" -mindepth 1 -maxdepth 1 \
    -name 'dotfiles-bootstrap.*' -print -quit | grep -q .; then
    journaled_mutation_pass=false
  fi
  if [ "$journaled_mutation_pass" = true ]; then
    pass "$journaled_mutation_name"
  else
    fail "$journaled_mutation_name"
  fi
}

run_link_result_case() {
  link_result_name=$1
  link_result_kind=$2
  link_result_diagnostic=$3
  prepare_managed_failure_case "$link_result_name"
  mkdir -p \
    "$managed_failure_home/.local/bin" \
    "$managed_failure_home/.local/opt"
  make_link_result_command \
    "$managed_failure_bin/ln" "$(command -v ln)" "$link_result_kind"
  run_capture "$managed_failure_root/output" env \
    PATH="$managed_failure_bin:$PATH" \
    TMPDIR="$managed_failure_tmp" \
    HOME="$managed_failure_home" \
    XDG_STATE_HOME="$managed_failure_state" \
    DOTFILES_BOOTSTRAP_TESTING=1 \
    DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
    DOTFILES_BOOTSTRAP_TEST_MANAGER=apt \
    DOTFILES_BOOTSTRAP_TEST_ARCH=x86_64 \
    DOTFILES_BOOTSTRAP_TEST_ALL_PACKAGES_MISSING=1 \
    DOTFILES_BOOTSTRAP_TEST_SATISFIED_TOOLS= \
    DOTFILES_BOOTSTRAP_TEST_APT_GHOSTTY_OFFICIAL=1 \
    DOTFILES_BOOTSTRAP_TEST_REAL_MANAGED_INSTALL=1 \
    DOTFILES_BOOTSTRAP_TEST_DOWNLOAD_ROOT="$managed_failure_download" \
    DOTFILES_BOOTSTRAP_TEST_STOP_AFTER_PACKAGES=1 \
    DOTFILES_BOOTSTRAP_TEST_COMMAND_LOG="$managed_failure_log" \
    "$managed_failure_harness/bootstrap" --apply
  link_result_status=$run_status
  link_result_pass=true
  [ "$link_result_status" -ne 0 ] || link_result_pass=false
  grep -Fq "$link_result_diagnostic" "$managed_failure_root/output" \
    || link_result_pass=false
  managed_outputs_are_absent_except "$managed_failure_home" \
    || link_result_pass=false
  if find "$managed_failure_tmp" -mindepth 1 -maxdepth 1 \
    -name 'dotfiles-bootstrap.*' -print -quit | grep -q .; then
    link_result_pass=false
  fi
  if [ "$link_result_pass" = true ]; then
    pass "$link_result_name"
  else
    fail "$link_result_name"
  fi
}

create_failure_node_archive() {
  failure_node_variant=$1
  failure_node_root=$managed_failure_source/node-v24.19.0-linux-x64
  failure_node_asset=node-$managed_failure_name.tar.xz
  failure_node_path=$managed_failure_download/$failure_node_asset

  case "$failure_node_variant" in
    absolute)
      tar -cJf "$failure_node_path" --transform='s,^,/,' \
        -C "$managed_failure_source" node-v24.19.0-linux-x64
      ;;
    parent-traversal)
      tar -cJf "$failure_node_path" \
        --transform='s,^node-v24.19.0-linux-x64,../node-v24.19.0-linux-x64,' \
        -C "$managed_failure_source" node-v24.19.0-linux-x64
      ;;
    outside-root)
      : >"$managed_failure_source/outside-node-root"
      tar -cJf "$failure_node_path" -C "$managed_failure_source" \
        node-v24.19.0-linux-x64 outside-node-root
      ;;
    missing-node)
      chmod 0644 "$failure_node_root/bin/node"
      tar -cJf "$failure_node_path" -C "$managed_failure_source" \
        node-v24.19.0-linux-x64
      ;;
    missing-npm-cli)
      mv "$failure_node_root/lib/node_modules/npm/bin/npm-cli.js" \
        "$managed_failure_source/npm-cli.js.omitted"
      tar -cJf "$failure_node_path" -C "$managed_failure_source" \
        node-v24.19.0-linux-x64
      ;;
    wrong-version)
      make_version_command "$failure_node_root/bin/node" 'v24.20.0'
      tar -cJf "$failure_node_path" -C "$managed_failure_source" \
        node-v24.19.0-linux-x64
      ;;
    *) return 1 ;;
  esac
  failure_node_sha256=$(file_sha256_for_test "$failure_node_path")
  set_failure_case_direct_asset node \
    "https://fixtures.invalid/$failure_node_asset" "$failure_node_sha256"
}

create_failure_lua_archive() {
  failure_lua_variant=$1
  failure_lua_root=$managed_failure_source/lua-x86_64
  failure_lua_asset=lua-$managed_failure_name.tar.gz
  failure_lua_path=$managed_failure_download/$failure_lua_asset

  case "$failure_lua_variant" in
    absolute)
      (
        cd "$failure_lua_root"
        tar -czf "$failure_lua_path" --transform='s,^,/,' \
          LICENSE bin changelog.md debugger.lua locale main.lua meta script
      )
      ;;
    parent-traversal)
      (
        cd "$failure_lua_root"
        tar -czf "$failure_lua_path" --transform='s,^,../,' \
          LICENSE bin changelog.md debugger.lua locale main.lua meta script
      )
      ;;
    unexpected-root)
      : >"$failure_lua_root/unexpected-root"
      (
        cd "$failure_lua_root"
        tar -czf "$failure_lua_path" \
          LICENSE bin changelog.md debugger.lua locale main.lua meta script \
          unexpected-root
      )
      ;;
    missing-executable)
      chmod 0644 "$failure_lua_root/bin/lua-language-server"
      (
        cd "$failure_lua_root"
        tar -czf "$failure_lua_path" \
          LICENSE bin changelog.md debugger.lua locale main.lua meta script
      )
      ;;
    missing-main)
      mv "$failure_lua_root/main.lua" "$managed_failure_source/main.lua.omitted"
      mkdir "$failure_lua_root/main.lua"
      (
        cd "$failure_lua_root"
        tar -czf "$failure_lua_path" \
          LICENSE bin changelog.md debugger.lua locale main.lua meta script
      )
      ;;
    missing-script-directory)
      mv "$failure_lua_root/script" "$managed_failure_source/script.omitted"
      : >"$failure_lua_root/script"
      (
        cd "$failure_lua_root"
        tar -czf "$failure_lua_path" \
          LICENSE bin changelog.md debugger.lua locale main.lua meta script
      )
      ;;
    *) return 1 ;;
  esac
  failure_lua_sha256=$(file_sha256_for_test "$failure_lua_path")
  set_failure_case_direct_asset lua-language-server \
    "https://fixtures.invalid/$failure_lua_asset" "$failure_lua_sha256"
}

create_failure_taplo_asset() {
  failure_taplo_variant=$1
  failure_taplo_asset=taplo-$managed_failure_name.gz
  failure_taplo_path=$managed_failure_download/$failure_taplo_asset
  failure_taplo_source=$managed_failure_source/taplo-$managed_failure_name

  case "$failure_taplo_variant" in
    malformed-gzip)
      printf '%s\n' 'not a gzip stream' >"$failure_taplo_path"
      ;;
    empty)
      : >"$failure_taplo_source"
      gzip -c "$failure_taplo_source" >"$failure_taplo_path"
      ;;
    wrong-version)
      make_taplo_command "$failure_taplo_source" 'taplo 0.9.9' success
      gzip -c "$failure_taplo_source" >"$failure_taplo_path"
      ;;
    missing-lsp)
      make_taplo_command "$failure_taplo_source" 'taplo 0.10.0' fail
      gzip -c "$failure_taplo_source" >"$failure_taplo_path"
      ;;
    *) return 1 ;;
  esac

  failure_taplo_sha256=$(file_sha256_for_test "$failure_taplo_path")
  set_failure_case_direct_asset taplo \
    "https://fixtures.invalid/$failure_taplo_asset" \
    "$failure_taplo_sha256"
}

mutate_failure_npm_manifest() {
  failure_npm_mutation=$1
  failure_package_path=$managed_failure_harness/manifests/packages-npm-language-servers.json
  failure_package_lock_path=$managed_failure_harness/manifests/packages-npm-language-servers-lock.json
  case "$failure_npm_mutation" in
    malformed-package)
      printf '%s\n' '{' >"$failure_package_path"
      ;;
    private-false)
      node -e '
const fs = require("fs");
const path = process.argv[1];
const value = JSON.parse(fs.readFileSync(path, "utf8"));
value.private = false;
fs.writeFileSync(path, JSON.stringify(value, null, 2) + "\n");
' "$failure_package_path"
      ;;
    ranged-version)
      node -e '
const fs = require("fs");
const path = process.argv[1];
const value = JSON.parse(fs.readFileSync(path, "utf8"));
value.dependencies["bash-language-server"] = "^5.6.0";
fs.writeFileSync(path, JSON.stringify(value, null, 2) + "\n");
' "$failure_package_path"
      ;;
    lock-root-mismatch)
      node -e '
const fs = require("fs");
const path = process.argv[1];
const value = JSON.parse(fs.readFileSync(path, "utf8"));
value.packages[""].dependencies["bash-language-server"] = "5.5.0";
fs.writeFileSync(path, JSON.stringify(value, null, 2) + "\n");
' "$failure_package_lock_path"
      refresh_failure_case_lock_hash
      ;;
    lockfile-version)
      node -e '
const fs = require("fs");
const path = process.argv[1];
const value = JSON.parse(fs.readFileSync(path, "utf8"));
value.lockfileVersion = 2;
fs.writeFileSync(path, JSON.stringify(value, null, 2) + "\n");
' "$failure_package_lock_path"
      refresh_failure_case_lock_hash
      ;;
    missing-resolved)
      node -e '
const fs = require("fs");
const path = process.argv[1];
const value = JSON.parse(fs.readFileSync(path, "utf8"));
delete value.packages["node_modules/bash-language-server"].resolved;
fs.writeFileSync(path, JSON.stringify(value, null, 2) + "\n");
' "$failure_package_lock_path"
      refresh_failure_case_lock_hash
      ;;
    invalid-resolved)
      node -e '
const fs = require("fs");
const path = process.argv[1];
const value = JSON.parse(fs.readFileSync(path, "utf8"));
value.packages["node_modules/bash-language-server"].resolved = "http://registry.npmjs.org/bash-language-server.tgz";
fs.writeFileSync(path, JSON.stringify(value, null, 2) + "\n");
' "$failure_package_lock_path"
      refresh_failure_case_lock_hash
      ;;
    missing-integrity)
      node -e '
const fs = require("fs");
const path = process.argv[1];
const value = JSON.parse(fs.readFileSync(path, "utf8"));
delete value.packages["node_modules/bash-language-server"].integrity;
fs.writeFileSync(path, JSON.stringify(value, null, 2) + "\n");
' "$failure_package_lock_path"
      refresh_failure_case_lock_hash
      ;;
    malformed-integrity)
      node -e '
const fs = require("fs");
const path = process.argv[1];
const value = JSON.parse(fs.readFileSync(path, "utf8"));
value.packages["node_modules/bash-language-server"].integrity = "sha512-not valid";
fs.writeFileSync(path, JSON.stringify(value, null, 2) + "\n");
' "$failure_package_lock_path"
      refresh_failure_case_lock_hash
      ;;
    *) return 1 ;;
  esac
}

run_managed_collision_case() {
  managed_collision_name=$1
  managed_collision_relative=$2
  managed_collision_type=$3
  prepare_managed_failure_case "collision-$managed_collision_name"
  managed_collision_path=$managed_failure_home/$managed_collision_relative
  managed_collision_marker="occupied-$managed_collision_name"
  mkdir -p "$(dirname "$managed_collision_path")"
  case "$managed_collision_type" in
    directory)
      mkdir "$managed_collision_path"
      printf '%s\n' "$managed_collision_marker" \
        >"$managed_collision_path/sentinel"
      ;;
    file)
      printf '%s\n' "$managed_collision_marker" >"$managed_collision_path"
      ;;
    symlink)
      managed_collision_source=$managed_failure_root/symlink-target
      mkdir "$managed_collision_source"
      ln -s "$managed_collision_source" "$managed_collision_path"
      ;;
    *) return 1 ;;
  esac

  run_capture "$managed_failure_root/output" env \
    HOME="$managed_failure_home" \
    XDG_STATE_HOME="$managed_failure_state" \
    DOTFILES_BOOTSTRAP_TESTING=1 \
    DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
    DOTFILES_BOOTSTRAP_TEST_MANAGER=apt \
    DOTFILES_BOOTSTRAP_TEST_ARCH=x86_64 \
    DOTFILES_BOOTSTRAP_TEST_ALL_PACKAGES_MISSING=1 \
    DOTFILES_BOOTSTRAP_TEST_SATISFIED_TOOLS= \
    DOTFILES_BOOTSTRAP_TEST_APT_GHOSTTY_OFFICIAL=1 \
    DOTFILES_BOOTSTRAP_TEST_REAL_MANAGED_INSTALL=1 \
    DOTFILES_BOOTSTRAP_TEST_DOWNLOAD_ROOT="$managed_failure_download" \
    DOTFILES_BOOTSTRAP_TEST_STOP_AFTER_PACKAGES=1 \
    DOTFILES_BOOTSTRAP_TEST_COMMAND_LOG="$managed_failure_log" \
    "$managed_failure_harness/bootstrap" --apply
  managed_collision_status=$run_status
  managed_collision_output=$(cat "$managed_failure_root/output")
  managed_collision_pass=true
  [ "$managed_collision_status" -ne 0 ] || managed_collision_pass=false
  printf '%s\n' "$managed_collision_output" \
    | grep -Fq "$managed_collision_path" \
    || managed_collision_pass=false
  [ ! -e "$managed_failure_log" ] || managed_collision_pass=false
  managed_outputs_are_absent_except \
    "$managed_failure_home" "$managed_collision_path" \
    || managed_collision_pass=false
  case "$managed_collision_type" in
    directory)
      [ "$(cat "$managed_collision_path/sentinel" 2>/dev/null || true)" \
        = "$managed_collision_marker" ] || managed_collision_pass=false
      ;;
    file)
      [ "$(cat "$managed_collision_path" 2>/dev/null || true)" \
        = "$managed_collision_marker" ] || managed_collision_pass=false
      ;;
    symlink)
      [ "$(readlink "$managed_collision_path" 2>/dev/null || true)" \
        = "$managed_collision_source" ] || managed_collision_pass=false
      ;;
  esac

  if [ "$managed_collision_pass" = true ]; then
    pass "$managed_collision_name collision fails before every package mutation"
  else
    fail "$managed_collision_name collision fails before every package mutation"
    sed "s/^/  $managed_collision_name output: /" \
      "$managed_failure_root/output" >&2
  fi
}

run_selective_managed_case() {
  selective_name=$1
  selective_satisfied_tools=$2
  selective_expected_links=$3
  selective_kind=$4
  selective_root=$test_tmp/managed-selective-$selective_name
  selective_home=$selective_root/home
  selective_state=$selective_root/state
  selective_bin=$selective_root/bin
  selective_log=$selective_root/commands
  mkdir -p "$selective_home" "$selective_bin"
  printf '%s\n' '#!/bin/sh' "printf '%s\\n' 'install ok installed'" \
    >"$selective_bin/dpkg-query"
  printf '%s\n' '#!/bin/sh' 'exit 0' >"$selective_bin/apt-cache"
  chmod 0755 "$selective_bin/dpkg-query" "$selective_bin/apt-cache"
  selective_node_bin=$managed_fixture_source/x86_64/node-v24.19.0-linux-x64/bin
  selective_taplo_target=$selective_home/.local/opt/taplo-0.10.0-x86_64
  selective_external_taplo=$selective_bin/taplo
  make_taplo_command "$selective_external_taplo" 'taplo 0.10.0' success
  selective_external_taplo_before=$(file_sha256_for_test \
    "$selective_external_taplo")

  run_capture "$selective_root/output" env \
    PATH="$selective_bin:$selective_node_bin:$test_utilities_bin" \
    HOME="$selective_home" \
    XDG_STATE_HOME="$selective_state" \
    DOTFILES_BOOTSTRAP_TESTING=1 \
    DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
    DOTFILES_BOOTSTRAP_TEST_MANAGER=apt \
    DOTFILES_BOOTSTRAP_TEST_ARCH=x86_64 \
    DOTFILES_BOOTSTRAP_TEST_SATISFIED_TOOLS="$selective_satisfied_tools" \
    DOTFILES_BOOTSTRAP_TEST_APT_GHOSTTY_OFFICIAL=1 \
    DOTFILES_BOOTSTRAP_TEST_REAL_MANAGED_INSTALL=1 \
    DOTFILES_BOOTSTRAP_TEST_DOWNLOAD_ROOT="$managed_fixture_download" \
    DOTFILES_BOOTSTRAP_TEST_STOP_AFTER_PACKAGES=1 \
    DOTFILES_BOOTSTRAP_TEST_COMMAND_LOG="$selective_log" \
    "$managed_fixture_root/bootstrap" --apply
  selective_status=$run_status
  selective_pass=true
  [ "$selective_status" -eq 0 ] || selective_pass=false
  selective_npm_target=$selective_home/.local/opt/dotfiles-lsp-node-$actual_npm_lock_sha256
  selective_lua_target=$selective_home/.local/opt/lua-language-server-3.19.1-x86_64
  [ ! -e "$selective_home/.local/opt/node-24.19.0-x86_64" ] \
    || selective_pass=false
  [ ! -e "$selective_home/.local/bin/node" ] \
    && [ ! -L "$selective_home/.local/bin/node" ] \
    || selective_pass=false
  [ ! -e "$selective_home/.local/bin/npm" ] \
    && [ ! -L "$selective_home/.local/bin/npm" ] \
    || selective_pass=false

  case "$selective_kind" in
    lua)
      [ -d "$selective_lua_target" ] || selective_pass=false
      [ -x "$selective_home/.local/bin/lua-language-server" ] \
        && [ ! -L "$selective_home/.local/bin/lua-language-server" ] \
        || selective_pass=false
      [ ! -e "$selective_taplo_target" ] || selective_pass=false
      [ ! -e "$selective_npm_target" ] || selective_pass=false
      ;;
    npm)
      [ ! -e "$selective_lua_target" ] || selective_pass=false
      [ ! -e "$selective_taplo_target" ] || selective_pass=false
      [ -d "$selective_npm_target" ] || selective_pass=false
      for selective_package in \
        bash-language-server \
        vscode-langservers-extracted \
        pyright \
        yaml-language-server
      do
        [ -d "$selective_npm_target/node_modules/$selective_package" ] \
          || selective_pass=false
      done
      ;;
    taplo)
      [ ! -e "$selective_lua_target" ] || selective_pass=false
      [ -d "$selective_taplo_target" ] || selective_pass=false
      [ -x "$selective_taplo_target/taplo" ] || selective_pass=false
      [ ! -e "$selective_npm_target" ] || selective_pass=false
      ;;
    *) selective_pass=false ;;
  esac

  for selective_command in \
    bash-language-server \
    vscode-json-language-server \
    lua-language-server \
    pyright-langserver \
    taplo \
    yaml-language-server
  do
    case ",$selective_expected_links," in
      *,"$selective_command",*)
        path_exists_for_test "$selective_home/.local/bin/$selective_command" \
          || selective_pass=false
        ;;
      *)
        if path_exists_for_test "$selective_home/.local/bin/$selective_command"; then
          selective_pass=false
        fi
        ;;
    esac
  done

  selective_external_taplo_after=$(file_sha256_for_test \
    "$selective_external_taplo")
  [ "$selective_external_taplo_before" = "$selective_external_taplo_after" ] \
    || selective_pass=false

  if [ "$selective_pass" = true ]; then
    pass "$selective_name publishes only its selected managed server commands"
  else
    fail "$selective_name publishes only its selected managed server commands"
    sed "s/^/  $selective_name output: /" "$selective_root/output" >&2
  fi
}

managed_tree_digest() {
  python3 - "$1" <<'MANAGED_TREE_DIGEST'
import hashlib
import json
import os
from pathlib import Path
import stat
import sys

home = Path(sys.argv[1])
root = home / '.local'
coordination = root / 'state/dotfiles-ownership'
paths = [root]
for parent, directories, files in os.walk(root, followlinks=False):
    paths.extend(Path(parent) / name for name in directories + files)
entries = []
for path in sorted(paths):
    info = path.lstat()
    # Atomic lock mkdir/rmdir changes only this real directory's mtime.
    mtime = 0 if path == coordination and stat.S_ISDIR(info.st_mode) else info.st_mtime_ns
    content = hashlib.sha256(path.read_bytes()).hexdigest() if stat.S_ISREG(info.st_mode) else None
    link = os.readlink(path) if stat.S_ISLNK(info.st_mode) else None
    entries.append([str(path.relative_to(home)), info.st_mode, info.st_uid,
                    info.st_gid, info.st_ino, mtime, content, link])
print(hashlib.sha256(json.dumps(entries, separators=(',', ':')).encode()).hexdigest())
MANAGED_TREE_DIGEST
}

retained_language_server_actions_are_present() {
  retained_language_server_text=$1
  for retained_language_server_action in \
    'direct node' \
    'direct lua-language-server' \
    'direct taplo' \
    'npm bash-language-server@5.6.0' \
    'npm vscode-langservers-extracted@4.10.0' \
    'npm pyright@1.1.411' \
    'npm yaml-language-server@1.24.0'
  do
    printf '%s\n' "$retained_language_server_text" \
      | grep -Fqx "$retained_language_server_action" \
      || return 1
  done
}

managed_probe_root_set() {
  managed_probe_tmp=$1
  find "$managed_probe_tmp" -mindepth 1 -maxdepth 1 \
    -name 'dotfiles-bootstrap.*' -print | LC_ALL=C sort
}

managed_probe_process_set() {
  managed_probe_tmp=$1
  private_probe_process_ids "$managed_probe_tmp" | LC_ALL=C sort
}

managed_probe_state_matches() {
  managed_probe_tmp=$1
  managed_probe_expected_roots=$2
  managed_probe_expected_processes=$3
  managed_probe_pid_file=$4

  [ "$(managed_probe_root_set "$managed_probe_tmp")" \
    = "$managed_probe_expected_roots" ] || return 1
  [ "$(managed_probe_process_set "$managed_probe_tmp")" \
    = "$managed_probe_expected_processes" ] || return 1

  if [ -s "$managed_probe_pid_file" ]; then
    managed_probe_pid=$(cat "$managed_probe_pid_file") || return 1
    case $managed_probe_pid in
      ''|*[!0-9]*) return 1 ;;
    esac
    [ "$managed_probe_pid" -gt 1 ] || return 1
    [ ! -e "/proc/$managed_probe_pid" ] || return 1
  fi
}

prepare_managed_scope_case() {
  prepare_managed_failure_case "scope-$1"
  scope_home=$managed_failure_home
  scope_tmp=$managed_failure_tmp
  scope_bin=$managed_failure_bin
  scope_output=$managed_failure_root/output
  scope_pid_file=$managed_failure_root/probe.pid
  scope_target=$scope_home/.local/opt/taplo-0.10.0-x86_64
  scope_link=$scope_home/.local/bin/taplo
  scope_path=$scope_bin:$scope_home/.local/bin:$test_utilities_bin
  scope_arch=x86_64
  scope_platform=linux
  scope_publish_failure=
  scope_mutation_phase=
  scope_mutation_kind=
  scope_device_case=target
  scope_signal_parent=
  scope_bootstrap=$managed_failure_harness/bootstrap
}

prepare_managed_scope_snapshot() {
  scope_snapshot_mutating=false
  for scope_snapshot_argument do
    [ "$scope_snapshot_argument" != --apply ] || scope_snapshot_mutating=true
  done
  [ "$scope_snapshot_mutating" = true ] || return 0
  # Establish only the expected empty coordination fixture before a strict tree
  # snapshot; an unsafe existing parent must still be rejected by production.
  for scope_snapshot_directory in "$scope_home/.local" "$scope_home/.local/state" \
      "$scope_home/.local/state/dotfiles-ownership"; do
    [ ! -L "$scope_snapshot_directory" ] || return 0
    if [ -e "$scope_snapshot_directory" ] && [ ! -d "$scope_snapshot_directory" ]; then
      return 0
    fi
  done
  mkdir -p "$scope_home/.local/state/dotfiles-ownership"
}

managed_scope_tree() {
  find -P "$scope_home" -printf '%P|%y|%m|%i|%l\n' | LC_ALL=C sort
  find -P "$scope_home" -type f -exec sha256sum {} + | LC_ALL=C sort
}

run_managed_scope() {
  run_capture "$scope_output" env \
    PATH="$scope_path" HOME="$scope_home" TMPDIR="$scope_tmp" \
    DOTFILES_BOOTSTRAP_TESTING=1 \
    DOTFILES_BOOTSTRAP_TEST_PLATFORM="$scope_platform" \
    DOTFILES_BOOTSTRAP_TEST_ARCH="$scope_arch" \
    DOTFILES_BOOTSTRAP_TEST_MANAGER=must-not-be-detected \
    DOTFILES_BOOTSTRAP_TEST_WINDOW_MANAGER=must-not-be-selected \
    DOTFILES_BOOTSTRAP_TEST_REAL_MANAGED_INSTALL=1 \
    DOTFILES_BOOTSTRAP_TEST_DOWNLOAD_ROOT="$managed_failure_download" \
    DOTFILES_BOOTSTRAP_TEST_COMMAND_LOG="$managed_failure_log" \
    DOTFILES_BOOTSTRAP_TEST_TAPLO_PROBE_PID_FILE="$scope_pid_file" \
    DOTFILES_BOOTSTRAP_TEST_PUBLISH_FAIL_AFTER="$scope_publish_failure" \
    DOTFILES_BOOTSTRAP_TEST_LINK_MUTATION_PHASE="$scope_mutation_phase" \
    DOTFILES_BOOTSTRAP_TEST_LINK_MUTATION_KIND="$scope_mutation_kind" \
    DOTFILES_BOOTSTRAP_TEST_LINK_MUTATION_TARGET="$scope_link" \
    "$scope_bootstrap" "$@"
}

managed_scope_is_clean() {
  managed_probe_state_matches "$scope_tmp" '' '' "$scope_pid_file"
}

assert_managed_scope_readonly() {
  scope_expected_status=$1
  scope_expected_text=$2
  scope_label=$3
  shift 3
  prepare_managed_scope_snapshot "$@"
  scope_tree_before=$(managed_scope_tree)
  scope_commands_before=$(cat "$managed_failure_log" 2>/dev/null || true)
  run_managed_scope "$@"
  if [ "$run_status" -eq "$scope_expected_status" ] \
    && grep -Fq -- "$scope_expected_text" "$scope_output" \
    && [ "$(managed_scope_tree)" = "$scope_tree_before" ] \
    && managed_scope_is_clean \
    && [ "$(cat "$managed_failure_log" 2>/dev/null || true)" = "$scope_commands_before" ]; then
    pass "$scope_label"
  else
    fail "$scope_label"
    sed 's/^/  scoped output: /' "$scope_output" >&2
  fi
}

make_exact_managed_scope_layout() {
  mkdir -p "$scope_target" "$scope_home/.local/bin"
  make_taplo_command "$scope_target/taplo" 'taplo 0.10.0' success
  ln -s "$scope_target/taplo" "$scope_link"
}

make_scoped_registration_signal_fixture() {
  # Record the real owner in the copied harness; interrupt mktemp before its
  # result can be assigned to the journal/staging cleanup variable.
  registration_bash=
  if [ "$scope_registration_shell" = bash ]; then
    registration_bash=$(resolve_test_executable bash) || return 1
  fi
  awk -v registration_shell="$scope_registration_shell" \
    -v registration_bash="$registration_bash" '
    NR == 1 && registration_shell == "bash" {
      print "#!" registration_bash " --posix"
      next
    }
    $0 == "platform=$(detect_platform)" {
      print "DOTFILES_BOOTSTRAP_TEST_SCOPE_OWNER_PID=$$"
      print "export DOTFILES_BOOTSTRAP_TEST_SCOPE_OWNER_PID"
      injected += 1
    }
    { print }
    END { if (injected != 1) exit 1 }
  ' "$scope_bootstrap" >"$scope_bootstrap.new"
  mv "$scope_bootstrap.new" "$scope_bootstrap"
  chmod 0755 "$scope_bootstrap"
  {
    printf '%s\n' '#!/bin/sh' "real_mktemp='$test_real_mktemp'"
    printf '%s\n' "counter='$managed_failure_root/mktemp.count'"
    printf '%s\n' "path_file='$managed_failure_root/interrupted.path'"
    printf '%s\n' "signal_at='$scope_signal_at'" "signal_name='$scope_signal'"
    printf '%s\n' "signal_parent='$scope_signal_parent'"
    cat <<'SCOPE_MKTEMP'
created_root=$("$real_mktemp" "$@") || exit 1
count=0
[ ! -s "$counter" ] || count=$(cat "$counter")
count=$((count + 1))
printf '%s\n' "$count" >"$counter"
signal_this_root=false
if [ -n "$signal_parent" ]; then
  case $created_root in "$signal_parent"/dotfiles-bootstrap.*) signal_this_root=true ;; esac
elif [ "$count" -eq "$signal_at" ]; then
  signal_this_root=true
fi
if [ "$signal_this_root" = true ]; then
  printf '%s\n' "$created_root" >"$path_file"
  kill -"$signal_name" "$DOTFILES_BOOTSTRAP_TEST_SCOPE_OWNER_PID"
fi
printf '%s\n' "$created_root"
SCOPE_MKTEMP
  } >"$scope_bin/mktemp"
  chmod 0755 "$scope_bin/mktemp"
}

make_scoped_publication_race_fixture() {
  awk -v race="$scope_race" -v marker="$managed_failure_root/race.reached" '
    $0 == "publish_managed_directory() {" { in_directory = 1 }
    $0 == "publish_managed_link() {" { in_link = 1 }
    $0 == "}" { in_directory = 0; in_link = 0 }
    { print }
    (in_directory && race == "target-collision" || in_link && race == "link-collision") \
      && $0 == "  begin_managed_publication_critical" {
      path = in_directory ? "$publish_target" : "$link_target"
      print "  mkdir \"" path "\""
      print "  printf replacement >\"" path "/sentinel\""
      print "  printf reached >\"" marker "\""
      injected += 1
    }
    $0 == "mutate_managed_link_for_test() {" && race ~ /^replace-/ {
      phase = race ~ /before$/ ? "before-journal" : "after-journal"
      print "  if [ \"$1\" = \"" phase "\" ]; then"
      if (race ~ /^replace-directory/) {
        print "    mv \"$managed_taplo_target\" \"$HOME/original-target\""
        print "    mkdir \"$managed_taplo_target\""
        print "    printf replacement >\"$managed_taplo_target/sentinel\""
      } else {
        print "    mv \"$managed_taplo_link\" \"$HOME/original-link\""
        print "    ln -s \"$HOME/replacement\" \"$managed_taplo_link\""
      }
      print "    printf reached >\"" marker "\""
      print "    die \"forced replacement failure\""
      print "  fi"
      injected += 1
    }
    END { if (injected != 1) exit 1 }
  ' "$scope_bootstrap" >"$scope_bootstrap.new"
  mv "$scope_bootstrap.new" "$scope_bootstrap"
  chmod 0755 "$scope_bootstrap"
}

make_scoped_cross_device_commands() {
  # Model TMPDIR on a different device; only the external stat/mv boundary
  # is replaced, while staging, publication and cleanup run unchanged.
  case $scope_device_case in
    target)
      scope_foreign_root=$scope_tmp
      scope_device_target=$scope_target
      scope_device_parent=$scope_home/.local/opt
      ;;
    link)
      scope_foreign_root=$scope_home/.local/bin
      scope_device_target=$scope_link
      scope_device_parent=$scope_home/.local/bin
      ;;
  esac
  {
    printf '%s\n' '#!/bin/sh' "real_stat='$(command -v stat)'"
    printf '%s\n' "foreign_tmp='$scope_foreign_root'"
    cat <<'SCOPE_STAT'
if [ "$1" = -c ] && [ "$2" = '%d' ]; then
  case $3 in "$foreign_tmp"|"$foreign_tmp"/*) printf '%s\n' different-device; exit 0 ;; esac
fi
exec "$real_stat" "$@"
SCOPE_STAT
  } >"$scope_bin/stat"
  {
    printf '%s\n' '#!/bin/sh' "real_mv='$(command -v mv)'"
    printf '%s\n' "expected_parent='$scope_device_parent'" "final_target='$scope_device_target'"
    printf '%s\n' "fallback_marker='$managed_failure_root/copy-fallback'"
    cat <<'SCOPE_MV'
if [ "$#" -eq 4 ] && [ "$4" = "$final_target" ]; then
  case $3 in
    "$expected_parent"/*) ;;
    *)
      printf '%s\n' copied >"$fallback_marker"
      cp -R "$3" "$4" && rm -r "$3"
      exit $?
      ;;
  esac
fi
exec "$real_mv" "$@"
SCOPE_MV
  } >"$scope_bin/mv"
  chmod 0755 "$scope_bin/stat" "$scope_bin/mv"
}

# Clipboard tests run real capture code with only the Cliphist boundary replaced.
run_clipboard_capture_tests() {
  if python3 - "$workspace_root" "$test_tmp" <<'CLIPBOARD_CAPTURE_TEST'
from pathlib import Path
import os, signal, stat, subprocess, sys, time, shlex

source, scratch = map(Path, sys.argv[1:])
store = source / '.config/clipboard-history/store'
assert store.is_file() and os.access(store, os.X_OK), 'bounded clipboard store helper is missing'
root = scratch / 'clipboard-capture'
root.mkdir(mode=0o700)
for name in ('bin', 'cache', 'home', 'config'):
    (root / name).mkdir(mode=0o700)
history = root / 'cache/cliphist'
history.mkdir(mode=0o700)
fake = root / 'bin/cliphist'
fake.write_text('''#!/bin/sh
[ "$1" = -db-path ] && [ "$2" = "$XDG_CACHE_HOME/cliphist/db" ] && [ "$3" = store ] || exit 91
stat -Lc '%a' /proc/self/fd/0 > "$CLIP_TEST_MODE"
cat > "$CLIP_TEST_CAPTURE"
exit "${CLIP_TEST_EXIT:-0}"
''')
fake.chmod(0o700)
captured = root / 'captured'
env = dict(os.environ, HOME=str(root/'home'), XDG_CACHE_HOME=str(root/'cache'),
           XDG_CONFIG_HOME=str(root/'config'), PATH=str(root/'bin')+':' + os.environ['DOTFILES_BOOTSTRAP_TEST_UTILITY_PATH'],
           CLIP_TEST_CAPTURE=str(captured), CLIP_TEST_MODE=str(root/'mode'),
           CLIPHIST_CONFIG_PATH=str(root/'config/empty'), CLIPHIST_DB_PATH=str(history/'db'))
(root/'config/empty').write_text('')

def run(payload, changes=None):
    captured.unlink(missing_ok=True)
    result = subprocess.run([str(store)], input=payload, env=env | (changes or {}), capture_output=True, timeout=5)
    assert not result.stdout and not result.stderr, 'capture emitted content or diagnostics'
    assert not list(history.glob('.store.*')), 'capture left a temporary payload'
    return result.returncode, captured.read_bytes() if captured.exists() else None

for payload in (b'x', b' leading and trailing \t ', b'first\nsecond\n', 'é中🙂\n'.encode(), b'x'*1048575, b'x'*1048576):
    assert run(payload) == (0, payload), 'capture changed valid text bytes'
    assert (root/'mode').read_text().strip() == '600', 'capture temporary file is not private'
for payload in (b'', b'x'*1048577):
    assert run(payload) == (0, None), 'empty or over-limit payload reached Cliphist'
assert run(b'child status', {'CLIP_TEST_EXIT':'42'}) == (42, b'child status'), 'child status was lost'

history.chmod(0o755)
assert run(b'unsafe mode')[0] != 0 and not captured.exists(), 'public history directory accepted'
history.chmod(0o700)
history.rename(root/'real-history')
history.symlink_to(root/'real-history', target_is_directory=True)
assert run(b'symlink')[0] != 0 and not captured.exists(), 'symlinked history directory accepted'
history.unlink()
history.write_text('not a directory')
assert run(b'file')[0] != 0 and not captured.exists(), 'regular file accepted as history directory'
history.unlink()
(root/'real-history').rename(history)

# Reject a foreign owner without requiring privileged chown in the test suite.
fake_stat = root/'bin/stat'
fake_stat.write_text('#!/bin/sh\nif [ "$2" = %u ]; then printf "999999\\n"; else exec ' + shlex.quote(os.environ['DOTFILES_BOOTSTRAP_TEST_REAL_STAT']) + ' "$@"; fi\n')
fake_stat.chmod(0o700)
assert run(b'foreign owner')[0] != 0 and not captured.exists(), 'foreign history owner accepted'
fake_stat.unlink()

db = history/'db'
db.symlink_to(root/'unrelated')
assert run(b'symlink db')[0] != 0 and not captured.exists(), 'symlinked database accepted'
db.unlink()
db.write_bytes(b'existing')
db.chmod(0o600)
os.link(db, root/'linked-db')
assert run(b'hardlink db')[0] != 0 and not captured.exists(), 'multiply linked database accepted'
(root/'linked-db').unlink()
db.chmod(0o644)
assert run(b'public db')[0] != 0 and not captured.exists(), 'public database accepted'
prepared = subprocess.run([str(store), '--prepare'], env=env, capture_output=True)
assert prepared.returncode == 0 and stat.S_IMODE(db.stat().st_mode) == 0o600, 'prepare did not secure existing database'
history.chmod(0o755)
prepared = subprocess.run([str(store), '--prepare'], env=env, capture_output=True)
assert prepared.returncode == 0 and stat.S_IMODE(history.stat().st_mode) == 0o700, 'prepare did not secure existing directory'
db.unlink()
history.rmdir()
prepared = subprocess.run([str(store), '--prepare'], env=env, capture_output=True)
assert prepared.returncode == 0 and stat.S_IMODE(history.stat().st_mode) == 0o700, 'prepare did not create private directory'
assert subprocess.run([str(store), '--unknown'], env=env, capture_output=True).returncode != 0, 'unknown capture argument accepted'

default = root/'home/.cache/cliphist'
default.mkdir(mode=0o700, parents=True)
default_env = dict(env)
default_env.pop('XDG_CACHE_HOME')
result = subprocess.run([str(store)], input=b'fallback', env=default_env, capture_output=True)
assert result.returncode == 0 and captured.read_bytes() == b'fallback', 'unset XDG cache fallback failed'
assert not list(default.glob('.store.*'))

# Signal the owned process while its reader is waiting for more input.
process = subprocess.Popen([str(store)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
try:
    deadline = time.monotonic()+3
    while not list(history.glob('.store.*')) and time.monotonic() < deadline:
        time.sleep(.01)
    assert list(history.glob('.store.*')), 'capture reader never started'
    process.send_signal(signal.SIGTERM)
    process.wait(timeout=3)
    assert process.returncode != 0 and not list(history.glob('.store.*')), 'TERM leaked a capture payload'
finally:
    if process.poll() is None:
        process.kill()
        process.wait()
    process.stdin.close()

print('Clipboard capture behavior assertions: ok')
CLIPBOARD_CAPTURE_TEST
  then
    pass 'clipboard capture bounds, exact bytes, private paths, child failures, and cleanup'
  else
    fail 'clipboard capture bounds, exact bytes, private paths, child failures, and cleanup'
  fi

  run_capture "$test_tmp/clipboard-plan.output" env \
    DOTFILES_BOOTSTRAP_TESTING=1 DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
    DOTFILES_BOOTSTRAP_TEST_MANAGER=pacman \
    "$bootstrap" --window-manager hypr
  clipboard_plan=$(cat "$test_tmp/clipboard-plan.output")
  require_contains "$clipboard_plan" 'cliphist' 'Hyprland plan provisions clipboard history'
  require_contains "$clipboard_plan" '.config/clipboard-history/store' 'Hyprland deploys bounded capture'
  require_contains "$clipboard_plan" '.config/cliphist/config' 'Hyprland deploys history policy'
  require_contains "$clipboard_plan" '.config/systemd/user/cliphist.service.d/override.conf' 'Hyprland deploys text watcher override'
}

run_clipboard_service_tests() {
  if python3 - "$bootstrap" "$test_tmp" <<'CLIPBOARD_SERVICE_TEST'
from pathlib import Path
import os, subprocess, sys
source, scratch = map(Path, sys.argv[1:])
root = scratch/'clipboard-services'
root.mkdir(mode=0o700)
# Load the real function definitions, without the CLI's process-wide traps.
text = source.read_text().split('\ntransaction_active=false\ntransaction_run=\n', 1)[0]
text = text[:text.index('mode=dry-run\n')] + text[text.index('detect_platform() {\n'):]
# Direct harnesses strip CLI parsing; include the same coordination library.
text += (source.parent/'lib/ownership.sh').read_text()
text += '\nownership_acquire || exit 98\ntrap ownership_release 0\n'
harness = root/'service-harness'
harness.write_text(text + r'''
transaction_run=$SERVICE_TEST_ROOT/journal
mkdir -p "$transaction_run"
case $1 in
  select) emit_selected_services "$2" "$3" ;;
  identifier) validate_service_identifier "$2" "$3" ;;
  inventory) validate_service_inventory "$2" "$SERVICE_TEST_ROOT/inventory" ;;
  apply)
    record_initial_service_state "$2" "$3"
    trap 'service_exit=$?; trap - 0; if [ "$service_exit" -ne 0 ]; then preflight_transaction_service && stop_deployed_service && restore_previous_service_state; fi; ownership_release; exit "$service_exit"' 0
    activate_login_service "$2"
    ;;
  rollback) preflight_transaction_service && stop_deployed_service && restore_previous_service_state ;;
esac
''')
harness.chmod(0o700)
base_env = dict(os.environ, DOTFILES_BOOTSTRAP_TESTING='1', WAYLAND_DISPLAY='',
    DOTFILES_BOOTSTRAP_TEST_SERVICE_ENABLED='false', DOTFILES_BOOTSTRAP_TEST_SERVICE_ACTIVE='false',
    DOTFILES_BOOTSTRAP_TEST_SERVICE_LOADED='false')

def fixture(name):
    path=root/name
    home=path/'home'
    assets={'.config/tmux/scripts/workspace':'#!/bin/sh\n',
        '.config/systemd/user/tmux-workspace.service':'[Service]\nExecStart=/bin/true\n',
        '.config/clipboard-history/store':'#!/bin/sh\n', '.config/cliphist/config':'max-items 500\n',
        '.config/systemd/user/cliphist.service.d/override.conf':'[Service]\n',
        'Library/LaunchAgents/dev.ruohao.tmux-workspace.plist':'fixture'}
    for relative,data in assets.items():
        p=home/relative;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(data);p.chmod(0o700)
    unit=path/'cliphist.service';unit.write_text('[Service]\nExecStart=/bin/true\n')
    return path, dict(base_env, HOME=str(home), SERVICE_TEST_ROOT=str(path),
        DOTFILES_BOOTSTRAP_TEST_CLIPHIST_UNIT_PATH=str(unit), DOTFILES_BOOTSTRAP_TEST_COMMAND_LOG=str(path/'commands'))

def run(env, *args):
    return subprocess.run([str(harness),*args],env=env,capture_output=True,text=True,timeout=5)

def actions(path):
    p=path/'commands'
    return p.read_text().splitlines() if p.exists() else []

def state(path, service, key):
    return (path/'journal/services'/service/key).read_text().strip()

p,e=fixture('selection')
for platform,profile,expected in [('linux','hypr',['tmux-workspace.service','cliphist.service']),
    ('linux','none',['tmux-workspace.service']),('linux','i3',['tmux-workspace.service']),
    ('macos','aerospace',['dev.ruohao.tmux-workspace'])]:
    r=run(e,'select',platform,profile)
    assert r.returncode==0 and r.stdout.splitlines()==expected, 'service selection is not profile-specific'
for platform,identifier in [('linux','cliphist.service'),('linux','tmux-workspace.service'),('macos','dev.ruohao.tmux-workspace')]:
    assert run(e,'identifier',platform,identifier).returncode==0
for platform,identifier in [('linux',''),('linux','../cliphist.service'),('linux','other.service'),('macos','cliphist.service'),('other','tmux-workspace.service')]:
    assert run(e,'identifier',platform,identifier).returncode!=0, 'unsupported service identifier accepted'
for inventory in ['', 'tmux-workspace.service\ntmux-workspace.service\n','tmux-workspace.service\n\n','../cliphist.service\n']:
    (p/'inventory').write_text(inventory)
    assert run(e,'inventory','linux').returncode!=0, 'invalid inventory accepted'

p,e=fixture('deferred')
r=run(e,'apply','linux','hypr');assert r.returncode==0, 'Hyprland service apply failed'
assert (p/'journal/services.list').read_text().splitlines()==['tmux-workspace.service','cliphist.service']
assert state(p,'cliphist.service','enabled-by-transaction')=='true'
assert state(p,'cliphist.service','started-by-transaction')=='false'
assert 'systemctl --user enable cliphist.service' in actions(p)
assert 'systemctl --user start cliphist.service' not in actions(p), 'headless apply started capture'
assert run(e,'rollback').returncode==0
assert actions(p)[-4:]==['systemctl --user disable cliphist.service','systemctl --user stop tmux-workspace.service',
    'systemctl --user disable tmux-workspace.service','systemctl --user daemon-reload'], 'rollback order is not reversed'

p,e=fixture('wayland')
e.update(WAYLAND_DISPLAY='test-wayland',DOTFILES_BOOTSTRAP_TEST_GRAPHICAL_ACTIVE='true')
assert run(e,'apply','linux','hypr').returncode==0
assert 'systemctl --user start cliphist.service' in actions(p), 'active Wayland session did not start capture'
(p/'commands').write_text('')
assert run(e,'rollback').returncode==0
assert actions(p)==['systemctl --user stop cliphist.service','systemctl --user disable cliphist.service',
    'systemctl --user stop tmux-workspace.service','systemctl --user disable tmux-workspace.service',
    'systemctl --user daemon-reload']
# Repeating service rollback must not repeat owned actions.
(p/'commands').write_text('');assert run(e,'rollback').returncode==0
assert actions(p)==[]

p,e=fixture('inactive-graphical')
e['WAYLAND_DISPLAY']='test-wayland'
assert run(e,'apply','linux','hypr').returncode==0
assert 'systemctl --user start cliphist.service' not in actions(p)

for tmux_enabled,tmux_active,clip_enabled,clip_active in [(True,True,False,False),(False,True,True,False),(True,False,False,True),(True,True,True,True)]:
    p,e=fixture('mixed-'+''.join(str(int(v)) for v in (tmux_enabled,tmux_active,clip_enabled,clip_active)))
    e.update(WAYLAND_DISPLAY='test-wayland', DOTFILES_BOOTSTRAP_TEST_GRAPHICAL_ACTIVE='true',
        DOTFILES_BOOTSTRAP_TEST_SERVICE_ENABLED=str(tmux_enabled).lower(),DOTFILES_BOOTSTRAP_TEST_SERVICE_ACTIVE=str(tmux_active).lower(),
        DOTFILES_BOOTSTRAP_TEST_CLIPHIST_ENABLED=str(clip_enabled).lower(),DOTFILES_BOOTSTRAP_TEST_CLIPHIST_ACTIVE=str(clip_active).lower())
    assert run(e,'apply','linux','hypr').returncode==0
    (p/'commands').write_text('');assert run(e,'rollback').returncode==0
    for service,enabled,active in [('tmux-workspace.service',tmux_enabled,tmux_active),('cliphist.service',clip_enabled,clip_active)]:
        assert ('systemctl --user disable '+service in actions(p)) != enabled, 'rollback changed pre-existing enablement'
        assert ('systemctl --user stop '+service in actions(p)) != active, 'rollback stopped a pre-existing service'

for missing in ['cliphist.service','home/.config/clipboard-history/store','home/.config/cliphist/config',
    'home/.config/systemd/user/cliphist.service.d/override.conf','home/.config/tmux/scripts/workspace']:
    p,e=fixture('missing-'+str(len(list(root.iterdir()))));(p/missing).unlink()
    assert run(e,'apply','linux','hypr').returncode!=0, 'missing service asset accepted'
    assert not actions(p), 'asset preflight mutated service manager'

for operation in ['enable','start']:
    p,e=fixture('failed-'+operation)
    e.update(WAYLAND_DISPLAY='test-wayland',DOTFILES_BOOTSTRAP_TEST_GRAPHICAL_ACTIVE='true',
        DOTFILES_BOOTSTRAP_TEST_SERVICE_FAIL=operation,DOTFILES_BOOTSTRAP_TEST_SERVICE_FAIL_UNIT='cliphist.service')
    assert run(e,'apply','linux','hypr').returncode!=0, 'manager failure ignored'
    assert 'systemctl --user disable cliphist.service' in actions(p), 'partial enable failure not unwound'
    assert 'systemctl --user stop tmux-workspace.service' in actions(p), 'earlier service start not unwound'
    if operation=='start':
        assert 'systemctl --user stop cliphist.service' in actions(p), 'partial start failure not unwound'

p,e=fixture('macos')
e['DOTFILES_BOOTSTRAP_TEST_SERVICE_LOADED']='true'
assert run(e,'apply','macos','aerospace').returncode==0
assert state(p,'dev.ruohao.tmux-workspace','was-active')=='true'
(p/'commands').write_text('');assert run(e,'rollback').returncode==0
assert 'bootout' in actions(p)[0] and 'bootstrap' in actions(p)[1] and 'kickstart' in actions(p)[2], 'macOS service restoration changed'

# Stateful manager failures exercise full file/service rollback, before and after effects.
mac_harness=root/'macos-failure-harness'
mac_harness.write_text(text + r"""
transaction_run=$SERVICE_TEST_ROOT/journal
run_service_command() {
  [ "$1" = launchctl ] || return 97
  printf '%s\n' "$*" >>"$SERVICE_TEST_ROOT/commands"
  case $2 in
    print)
      [ "${MAC_QUERY_UNAVAILABLE:-0}" != 1 ] || return 5
      case $3 in
        gui/*/dev.ruohao.tmux-workspace) [ -f "$SERVICE_TEST_ROOT/loaded" ] ;;
        gui/*) return 0 ;;
        *) return 97 ;;
      esac
      return $?
      ;;
  esac
  fail_this_call=false
  selected_failure=${MAC_FAIL_OPERATION:-}
  if [ "$selected_failure" = rollback-bootout ] && [ "$2" = bootout ] \
    && [ "$(cat "$SERVICE_TEST_ROOT/loaded" 2>/dev/null)" = new ]; then
    selected_failure=bootout
  fi
  if [ "$2" = "$selected_failure" ] && [ ! -e "$SERVICE_TEST_ROOT/failed-once" ]; then
    : >"$SERVICE_TEST_ROOT/failed-once"
    fail_this_call=true
    [ "$MAC_FAIL_PHASE" != before ] || return 5
  fi
  case $2 in
    bootout)
      [ -f "$SERVICE_TEST_ROOT/loaded" ] || return 5
      rm "$SERVICE_TEST_ROOT/loaded"
      ;;
    bootstrap)
      [ ! -f "$SERVICE_TEST_ROOT/loaded" ] || return 5
      cp "$4" "$SERVICE_TEST_ROOT/loaded"
      ;;
    kickstart) [ -f "$SERVICE_TEST_ROOT/loaded" ] || return 5 ;;
    *) return 97 ;;
  esac
  [ "$fail_this_call" = false ] || return 5
}
if [ "$1" = rollback ]; then
  rollback_transaction "$transaction_run"
  exit $?
fi
record_initial_service_state macos aerospace
trap 'service_exit=$?; trap - 0; rollback_transaction "$transaction_run"; printf "%s\n" "$?" >"$SERVICE_TEST_ROOT/rollback-exit"; ownership_release; exit "$service_exit"' 0
activate_login_service macos
die 'fixture failure after activation'
""")
mac_harness.chmod(0o700)

def mac_fixture(name, loaded=True):
    p,e=fixture(name)
    e['DOTFILES_BOOTSTRAP_TEST_SERVICE_LOADED']=str(loaded).lower()
    relative='Library/LaunchAgents/dev.ruohao.tmux-workspace.plist'
    (p/'home'/relative).write_text('new')
    j=p/'journal';j.mkdir()
    backup=j/'backup'/relative;backup.parent.mkdir(parents=True);backup.write_text('old')
    for key,value in {'status':'active','platform':'macos','managed.paths':relative,'backed-up.paths':relative}.items():
        (j/key).write_text(value+'\n')
    if loaded: (p/'loaded').write_text('old')
    return p,e,relative

def mac_run(env, mode='apply'):
    return subprocess.run([str(mac_harness),mode],env=env,capture_output=True,text=True,timeout=5)

for loaded in [True,False]:
    operations=['bootstrap','kickstart'] + (['bootout'] if loaded else [])
    for operation in operations:
        for phase in ['before','after']:
            name=f'macos-{loaded}-{operation}-{phase}'
            p,e,relative=mac_fixture(name,loaded)
            e.update(MAC_FAIL_OPERATION=operation,MAC_FAIL_PHASE=phase)
            assert mac_run(e).returncode!=0, name+': manager failure ignored'
            assert (p/'rollback-exit').read_text().strip()=='0', name+': automatic rollback failed'
            assert (p/'journal/status').read_text().strip()=='rolled-back', name+': rollback incomplete'
            assert (p/'home'/relative).read_text()=='old', name+': old configuration not restored'
            if loaded:
                assert (p/'loaded').read_text()=='old', name+': previous service not restored'
            else:
                assert not (p/'loaded').exists(), name+': new service remained loaded'
            before=actions(p)
            assert mac_run(e,'rollback').returncode==0 and actions(p)==before, name+': retry was not idempotent'

for phase,unavailable in [('before',False),('after',False),('after',True)]:
    p,e,relative=mac_fixture(f'macos-cleanup-{phase}-{unavailable}')
    e.update(MAC_FAIL_OPERATION='rollback-bootout',MAC_FAIL_PHASE=phase)
    if unavailable: e['MAC_QUERY_UNAVAILABLE']='1'
    assert mac_run(e).returncode!=0
    if phase=='before' or unavailable:
        assert (p/'rollback-exit').read_text().strip()!='0', 'rollback ignored loaded/unknown manager state'
        assert (p/'home'/relative).read_text()=='new', 'configuration restored before safe service cleanup'
        e.pop('MAC_QUERY_UNAVAILABLE',None)
        assert mac_run(e,'rollback').returncode==0, 'rollback retry failed'
    else:
        assert (p/'rollback-exit').read_text().strip()=='0', 'verified absent service prevented rollback'
    assert (p/'home'/relative).read_text()=='old' and (p/'loaded').read_text()=='old', 'retry did not restore previous state'

p,e=fixture('legacy')
j=p/'journal';j.mkdir()
for key,value in {'service-platform':'linux','service-was-installed':'true','service-was-enabled':'true',
    'service-was-active':'true','service-new-loaded':'false'}.items(): (j/key).write_text(value+'\n')
assert run(e,'rollback').returncode==0
assert actions(p)==['systemctl --user disable --now tmux-workspace.service','systemctl --user daemon-reload',
    'systemctl --user enable tmux-workspace.service','systemctl --user start tmux-workspace.service'], 'legacy rollback compatibility broke'

p,e=fixture('corrupt')
assert run(e,'apply','linux','hypr').returncode==0
(p/'commands').write_text('');(p/'journal/services.list').write_text('../other.service\n')
assert run(e,'rollback').returncode!=0 and not actions(p), 'corrupt journal reached service manager'
print('Clipboard service transaction assertions: ok')
CLIPBOARD_SERVICE_TEST
  then
    pass 'clipboard service inventory, private injection, asset preflight, ownership, failures, and rollback'
  else
    fail 'clipboard service inventory, private injection, asset preflight, ownership, failures, and rollback'
  fi
}

run_repository_url_tests() {
  if python3 - "$bootstrap" "$test_tmp/repository-urls" <<'REPOSITORY_URL_TEST'
import os
from pathlib import Path
import shutil
import subprocess
import sys

bootstrap = Path(sys.argv[1]).resolve()
root = Path(sys.argv[2])
root.mkdir()
standalone = root / 'standalone' / 'bootstrap'
standalone.parent.mkdir()
shutil.copyfile(bootstrap, standalone)
guard = root / 'guard'
guard.mkdir()
for command in ('dirname', 'uname', 'git', 'mktemp', 'id'):
    stub = guard / command
    stub.write_text('#!/bin/sh\nprintf "external command\\n" >>"$REPO_URL_TEST_COMMAND_LOG"\nexit 97\n')
    stub.chmod(0o700)

marker = 'repo-url-synthetic-secret'
rejected = [
    ('password', f'https://user:{marker}@example.invalid/dotfiles.git'),
    ('username', f'http://{marker}@example.invalid/dotfiles.git'),
    ('mixed-case', f'hTtPs://user:{marker}@example.invalid/dotfiles.git'),
    ('empty-user', f'HTTPS://:{marker}@example.invalid/dotfiles.git'),
    ('encoded-user', f'https://user%40mail:{marker}@example.invalid/dotfiles.git'),
    ('query', f'https://example.invalid/dotfiles.git?token={marker}'),
    ('fragment', f'http://example.invalid/dotfiles.git#{marker}'),
    ('root-query', f'https://example.invalid?token={marker}'),
    ('empty-query', 'https://example.invalid/dotfiles.git?'),
    ('empty-fragment', 'https://example.invalid/dotfiles.git#'),
    ('empty-userinfo', 'https://@example.invalid/dotfiles.git'),
    ('http-helper', f'http::http://user:{marker}@example.invalid/dotfiles.git'),
    ('https-helper', f'https::https://user:{marker}@example.invalid/dotfiles.git'),
    ('helper-query', f'http::https://example.invalid/dotfiles.git?token={marker}'),
    ('helper-fragment', f'https::https://example.invalid/dotfiles.git#{marker}'),
]
for name, prefix in [
    ('http-one-slash', 'http:/'),
    ('https-one-slash', 'https:/'),
    ('http-three-slashes', 'http:///'),
    ('https-three-slashes-mixed-case', 'HtTpS:///'),
]:
    rejected.extend([
        (f'{name}-userinfo', f'{prefix}user:{marker}@example.invalid/dotfiles.git'),
        (f'{name}-query', f'{prefix}example.invalid/dotfiles.git?token={marker}'),
        (f'{name}-fragment', f'{prefix}example.invalid/dotfiles.git#{marker}'),
    ])
accepted = [
    'https://example.invalid/dotfiles.git',
    'http://example.invalid/dotfiles.git',
    'hTtPs://example.invalid/dotfiles.git',
    'https://example.invalid:8443/dotfiles.git',
    'https://[::1]:8443/dotfiles.git',
    'https://example.invalid/team@work/dotfiles.git',
    'https://example.invalid/team%40work/repo%3Fname%23tag.git',
    'ssh://git@example.invalid/dotfiles.git',
    'git@example.invalid:team/dotfiles.git',
    'file:///tmp/dotfiles.git',
    '/tmp/dotfiles.git',
    './dotfiles.git',
    '../team@work/dotfiles.git',
    '/tmp/dotfiles?copy#local.git',
]

def environment(case_root, platform, manager):
    env = os.environ.copy()
    env.update(
        HOME=str(case_root / 'home'),
        XDG_STATE_HOME=str(case_root / 'state'),
        TMPDIR=str(case_root / 'tmp'),
        DOTFILES_BOOTSTRAP_TESTING='1',
        DOTFILES_BOOTSTRAP_TEST_PLATFORM=platform,
        DOTFILES_BOOTSTRAP_TEST_MANAGER=manager,
        DOTFILES_BOOTSTRAP_TEST_SKIP_PACKAGES='1',
        DOTFILES_BOOTSTRAP_TEST_PREPARE_DRY_RUN='0',
    )
    return env

rejection_count = 0
acceptance_count = 0
errors = []
for platform, manager in [('linux', 'pacman'), ('macos', 'homebrew')]:
    for entrypoint in (bootstrap, standalone):
        for mode in ('dry-run', 'apply'):
            for name, url in rejected:
                case = root / f'rejected-{rejection_count}'
                case.mkdir()
                env = environment(case, platform, manager)
                command_log = case / 'commands'
                env.update(PATH=str(guard), REPO_URL_TEST_COMMAND_LOG=str(command_log))
                args = ['/bin/sh', str(entrypoint), '--window-manager', 'none', '--repo', url]
                if mode == 'apply':
                    args.append('--apply')
                result = subprocess.run(args, env=env, capture_output=True, timeout=10)
                output = result.stdout + result.stderr
                label = f'{platform}/{entrypoint.parent.name}/{mode}/{name}'
                if result.returncode != 2:
                    errors.append(f'{label}: expected usage rejection')
                if result.stdout or b'repository URL' not in result.stderr:
                    errors.append(f'{label}: expected only a repository-input diagnostic')
                if marker.encode() in output or url.encode() in output:
                    errors.append(f'{label}: repository input leaked into output')
                if command_log.exists():
                    errors.append(f'{label}: reached an external command')
                if any((case / path).exists() for path in ('home', 'state', 'tmp')):
                    errors.append(f'{label}: created persistent or temporary state')
                rejection_count += 1

    for url in accepted:
        case = root / f'accepted-{acceptance_count}'
        case.mkdir()
        result = subprocess.run(
            ['/bin/sh', str(bootstrap), '--window-manager', 'none', '--repo', url],
            env=environment(case, platform, manager), capture_output=True, timeout=10,
        )
        expected = f'Repository: {url}\n'.encode()
        if result.returncode or expected not in result.stdout or result.stderr:
            errors.append(f'{platform}/accepted-{acceptance_count}: supported repository form rejected or changed')
        if any((case / path).exists() for path in ('home', 'state', 'tmp')):
            errors.append(f'{platform}/accepted-{acceptance_count}: dry-run created state')
        acceptance_count += 1

for error in errors:
    print(error, file=sys.stderr)
print(f'Repository URL cases: {rejection_count} rejected, {acceptance_count} accepted, {len(errors)} failures')
sys.exit(bool(errors))
REPOSITORY_URL_TEST
  then
    pass 'repository URLs reject credentials before output, commands, or state and preserve supported forms'
  else
    fail 'repository URLs reject credentials before output, commands, or state and preserve supported forms'
  fi
}

test_real_env=$(resolve_test_executable env) \
  || { printf '%s\n' 'test harness requires an absolute executable env' >&2; exit 1; }
test_real_setsid=$(resolve_test_executable setsid) \
  || { printf '%s\n' 'test harness requires an absolute executable setsid' >&2; exit 1; }
test_real_git=$(resolve_test_executable git) \
  || { printf '%s\n' 'test harness requires an absolute executable git' >&2; exit 1; }
test_real_mktemp=$(resolve_test_executable mktemp) \
  || { printf '%s\n' 'test harness requires an absolute executable mktemp' >&2; exit 1; }

test_tmp=$("$test_real_mktemp" -d "${TMPDIR:-/tmp}/dotfiles-bootstrap-test.XXXXXX")
# Discover standard utilities from the runner before fixture PATH overrides.
# Exclude all application/version providers (uv/node/Taplo/LSPs/etc.) so negative
# provider cases keep their original restricted resolution semantics.
test_utilities_bin=$test_tmp/utilities
mkdir -p "$test_utilities_bin"
for test_utility in awk basename cat chmod cmp cp cut date dd dirname env find git \
  grep gzip head id kill ln ls mkdir mkfifo mktemp mv od paste perl printf ps pwd readlink \
  realpath rm rmdir sed setsid sha256sum shasum sleep sort stat tail tar timeout \
  touch tr uname unzip wc xargs xz; do
  test_utility_source=$(resolve_test_executable "$test_utility") || continue
  ln -s "$test_utility_source" "$test_utilities_bin/$test_utility"
done
DOTFILES_BOOTSTRAP_TEST_UTILITY_PATH=$test_utilities_bin
DOTFILES_BOOTSTRAP_TEST_REAL_STAT=$(resolve_test_executable stat)
export DOTFILES_BOOTSTRAP_TEST_UTILITY_PATH DOTFILES_BOOTSTRAP_TEST_REAL_STAT
cleanup() {
  [ "${DOTFILES_BOOTSTRAP_TEST_KEEP_FIXTURES:-0}" != 1 ] || return 0
  case "$test_tmp" in
    "${TMPDIR:-/tmp}"/dotfiles-bootstrap-test.*) rm -rf "$test_tmp" ;;
  esac
}
trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

run_repository_url_tests
if [ "${DOTFILES_BOOTSTRAP_TEST_FOCUS:-}" = repository-url ]; then
  printf '1..%s\n' "$tests"
  [ "$failures" -eq 0 ]
  exit $?
fi

run_clipboard_capture_tests
run_clipboard_service_tests
# Synthetic package unit is used only by test-mode service resolution.
DOTFILES_BOOTSTRAP_TEST_CLIPHIST_UNIT_PATH=$test_tmp/cliphist.service
export DOTFILES_BOOTSTRAP_TEST_CLIPHIST_UNIT_PATH
printf '%s\n' '[Service]' 'ExecStart=/bin/true' >"$DOTFILES_BOOTSTRAP_TEST_CLIPHIST_UNIT_PATH"
if [ "${DOTFILES_BOOTSTRAP_TEST_FOCUS:-}" = clipboard ]; then
  printf '1..%s\n' "$tests"
  [ "$failures" -eq 0 ]
  exit $?
fi

direct_probe_bootstrap=$test_tmp/direct-probe-bootstrap
make_direct_probe_bootstrap "$bootstrap" "$direct_probe_bootstrap"

if [ -x "$bootstrap" ]; then
  pass 'bootstrap is executable'
else
  fail 'bootstrap is executable'
fi

parquet_function_bootstrap=$test_tmp/parquet-function-bootstrap
make_parquet_function_bootstrap "$bootstrap" "$parquet_function_bootstrap"
parquet_uv_selection_root=$test_tmp/parquet-uv-selection
parquet_uv_selection_home=$parquet_uv_selection_root/home
parquet_uv_selection_bin=$parquet_uv_selection_root/bin
mkdir -p "$parquet_uv_selection_home/.local/bin" "$parquet_uv_selection_bin"
make_version_command "$parquet_uv_selection_bin/uv" 'uv 0.10.0'
make_version_command "$parquet_uv_selection_home/.local/bin/uv" 'uv 0.12.5'
run_capture "$parquet_uv_selection_root/output" env \
  PATH="$parquet_uv_selection_bin:$test_utilities_bin" \
  HOME="$parquet_uv_selection_home" \
  DOTFILES_BOOTSTRAP_TEST_PARQUET_FUNCTION=uv-executable \
  "$parquet_function_bootstrap"
parquet_uv_selection_output=$(cat "$parquet_uv_selection_root/output")
if [ "$run_status" -eq 0 ] \
  && [ "$parquet_uv_selection_output" = "$parquet_uv_selection_home/.local/bin/uv" ]; then
  pass 'Parquet tooling rejects an old PATH uv for the supported managed fallback'
else
  fail 'Parquet tooling rejects an old PATH uv for the supported managed fallback'
fi

make_version_command "$parquet_uv_selection_bin/uv" 'not a uv version'
run_capture "$parquet_uv_selection_root/malformed.output" env \
  PATH="$parquet_uv_selection_bin:$test_utilities_bin" \
  HOME="$parquet_uv_selection_home" \
  DOTFILES_BOOTSTRAP_TEST_PARQUET_FUNCTION=uv-executable \
  "$parquet_function_bootstrap"
parquet_uv_malformed_output=$(cat "$parquet_uv_selection_root/malformed.output")
if [ "$run_status" -eq 0 ] \
  && [ "$parquet_uv_malformed_output" = "$parquet_uv_selection_home/.local/bin/uv" ]; then
  pass 'Parquet tooling rejects a malformed PATH uv version'
else
  fail 'Parquet tooling rejects a malformed PATH uv version'
fi

make_version_command "$parquet_uv_selection_bin/uv" 'release 99.0.0'
run_capture "$parquet_uv_selection_root/arbitrary-numeric.output" env \
  PATH="$parquet_uv_selection_bin:$test_utilities_bin" \
  HOME="$parquet_uv_selection_home" \
  DOTFILES_BOOTSTRAP_TEST_PARQUET_FUNCTION=uv-executable \
  "$parquet_function_bootstrap"
parquet_uv_arbitrary_numeric_output=$(cat "$parquet_uv_selection_root/arbitrary-numeric.output")
if [ "$run_status" -eq 0 ] \
  && [ "$parquet_uv_arbitrary_numeric_output" = "$parquet_uv_selection_home/.local/bin/uv" ]; then
  pass 'Parquet tooling rejects arbitrary numeric uv version output'
else
  fail 'Parquet tooling rejects arbitrary numeric uv version output'
fi

make_failing_version_command "$parquet_uv_selection_bin/uv" 'uv 99.0.0' 42
run_capture "$parquet_uv_selection_root/nonzero-version.output" env \
  PATH="$parquet_uv_selection_bin:$test_utilities_bin" \
  HOME="$parquet_uv_selection_home" \
  DOTFILES_BOOTSTRAP_TEST_PARQUET_FUNCTION=uv-executable \
  "$parquet_function_bootstrap"
parquet_uv_nonzero_version_output=$(cat "$parquet_uv_selection_root/nonzero-version.output")
if [ "$run_status" -eq 0 ] \
  && [ "$parquet_uv_nonzero_version_output" = "$parquet_uv_selection_home/.local/bin/uv" ]; then
  pass 'Parquet tooling rejects uv version output from a failing command'
else
  fail 'Parquet tooling rejects uv version output from a failing command'
fi

make_version_command \
  "$parquet_uv_selection_bin/uv" \
  '  uv 0.11.6 (x86_64-unknown-linux-gnu)  '
run_capture "$parquet_uv_selection_root/suffixed-version.output" env \
  PATH="$parquet_uv_selection_bin:$test_utilities_bin" \
  HOME="$parquet_uv_selection_home" \
  DOTFILES_BOOTSTRAP_TEST_PARQUET_FUNCTION=uv-executable \
  "$parquet_function_bootstrap"
parquet_uv_suffixed_version_output=$(cat "$parquet_uv_selection_root/suffixed-version.output")
if [ "$run_status" -eq 0 ] \
  && [ "$parquet_uv_suffixed_version_output" = "$parquet_uv_selection_bin/uv" ]; then
  pass 'Parquet tooling accepts trimmed official uv version output with a platform suffix'
else
  fail 'Parquet tooling accepts trimmed official uv version output with a platform suffix'
fi

parquet_probe_root=$test_tmp/parquet-production-probe
parquet_probe_bin=$parquet_probe_root/bin
parquet_probe_tools=$parquet_probe_root/tools
parquet_probe_marker=$parquet_probe_root/exact.marker
mkdir -p "$parquet_probe_root/home"
make_parquet_uv_tool_command "$parquet_probe_bin/uv"
prepare_parquet_tool_environment "$parquet_probe_tools"
: >"$parquet_probe_marker"
run_capture "$parquet_probe_root/exact.output" env \
  PATH="$parquet_probe_bin:$test_utilities_bin" \
  HOME="$parquet_probe_root/home" \
  DOTFILES_BOOTSTRAP_TEST_PARQUET_FUNCTION=viewer-satisfied \
  DOTFILES_BOOTSTRAP_TEST_PARQUET_TOOL_ROOT="$parquet_probe_tools" \
  DOTFILES_BOOTSTRAP_TEST_PARQUET_PROBE_MARKER="$parquet_probe_marker" \
  "$parquet_function_bootstrap"
if [ "$run_status" -eq 0 ]; then
  pass 'Parquet tooling accepts an exact isolated managed environment'
else
  fail 'Parquet tooling accepts an exact isolated managed environment'
fi

run_capture "$parquet_probe_root/mismatch.output" env \
  PATH="$parquet_probe_bin:$test_utilities_bin" \
  HOME="$parquet_probe_root/home" \
  DOTFILES_BOOTSTRAP_TEST_PARQUET_FUNCTION=viewer-satisfied \
  DOTFILES_BOOTSTRAP_TEST_PARQUET_TOOL_ROOT="$parquet_probe_tools" \
  DOTFILES_BOOTSTRAP_TEST_PARQUET_PROBE_MARKER="$parquet_probe_root/missing.marker" \
  "$parquet_function_bootstrap"
if [ "$run_status" -ne 0 ]; then
  pass 'Parquet tooling rejects a mismatched managed environment'
else
  fail 'Parquet tooling rejects a mismatched managed environment'
fi

run_capture "$parquet_probe_root/malformed.output" env \
  PATH="$parquet_probe_bin:$test_utilities_bin" \
  HOME="$parquet_probe_root/home" \
  DOTFILES_BOOTSTRAP_TEST_PARQUET_FUNCTION=viewer-satisfied \
  DOTFILES_BOOTSTRAP_TEST_PARQUET_TOOL_ROOT=relative/tool-root \
  DOTFILES_BOOTSTRAP_TEST_PARQUET_PROBE_MARKER="$parquet_probe_marker" \
  "$parquet_function_bootstrap"
if [ "$run_status" -ne 0 ]; then
  pass 'Parquet tooling rejects a malformed uv tool directory'
else
  fail 'Parquet tooling rejects a malformed uv tool directory'
fi

for parquet_missing_executable in python vd; do
  parquet_missing_root=$parquet_probe_root/missing-$parquet_missing_executable
  mkdir -p "$parquet_missing_root/visidata/bin"
  case "$parquet_missing_executable" in
    python)
      cp "$parquet_probe_tools/visidata/bin/vd" \
        "$parquet_missing_root/visidata/bin/vd"
      ;;
    vd)
      cp "$parquet_probe_tools/visidata/bin/python" \
        "$parquet_missing_root/visidata/bin/python"
      ;;
  esac
  run_capture "$parquet_probe_root/missing-$parquet_missing_executable.output" env \
    PATH="$parquet_probe_bin:$test_utilities_bin" \
    HOME="$parquet_probe_root/home" \
    DOTFILES_BOOTSTRAP_TEST_PARQUET_FUNCTION=viewer-satisfied \
    DOTFILES_BOOTSTRAP_TEST_PARQUET_TOOL_ROOT="$parquet_missing_root" \
    DOTFILES_BOOTSTRAP_TEST_PARQUET_PROBE_MARKER="$parquet_probe_marker" \
    "$parquet_function_bootstrap"
  if [ "$run_status" -ne 0 ]; then
    pass "Parquet tooling rejects a managed environment missing bin/$parquet_missing_executable"
  else
    fail "Parquet tooling rejects a managed environment missing bin/$parquet_missing_executable"
  fi
done

parquet_install_actions=$parquet_probe_root/install.actions
: >"$parquet_install_actions"
run_capture "$parquet_probe_root/install-failure.output" env \
  PATH="$parquet_probe_bin:$test_utilities_bin" \
  HOME="$parquet_probe_root/home" \
  DOTFILES_BOOTSTRAP_TEST_PARQUET_FUNCTION=install \
  DOTFILES_BOOTSTRAP_TEST_PARQUET_TOOL_ROOT="$parquet_probe_tools" \
  DOTFILES_BOOTSTRAP_TEST_PARQUET_PROBE_MARKER="$parquet_probe_root/missing.marker" \
  DOTFILES_BOOTSTRAP_TEST_PARQUET_INSTALL_BEHAVIOR=fail \
  DOTFILES_BOOTSTRAP_TEST_PARQUET_ACTIONS="$parquet_install_actions" \
  "$parquet_function_bootstrap"
if [ "$run_status" -eq 42 ] && [ ! -s "$parquet_install_actions" ]; then
  pass 'Parquet installation propagates a real uv command failure before journaling'
else
  fail 'Parquet installation propagates a real uv command failure before journaling'
fi

: >"$parquet_install_actions"
run_capture "$parquet_probe_root/install-mismatch.output" env \
  PATH="$parquet_probe_bin:$test_utilities_bin" \
  HOME="$parquet_probe_root/home" \
  DOTFILES_BOOTSTRAP_TEST_PARQUET_FUNCTION=install \
  DOTFILES_BOOTSTRAP_TEST_PARQUET_TOOL_ROOT="$parquet_probe_tools" \
  DOTFILES_BOOTSTRAP_TEST_PARQUET_PROBE_MARKER="$parquet_probe_root/missing.marker" \
  DOTFILES_BOOTSTRAP_TEST_PARQUET_INSTALL_BEHAVIOR=succeed \
  DOTFILES_BOOTSTRAP_TEST_PARQUET_ACTIONS="$parquet_install_actions" \
  "$parquet_function_bootstrap"
if [ "$run_status" -ne 0 ] && [ ! -s "$parquet_install_actions" ]; then
  pass 'Parquet installation verifies the exact environment before journaling'
else
  fail 'Parquet installation verifies the exact environment before journaling'
fi

parquet_unsafe_install_marker=$parquet_probe_root/unsafe-install.invoked
: >"$parquet_install_actions"
run_capture "$parquet_probe_root/unsafe-tool-root.output" env \
  PATH="$parquet_probe_bin:$test_utilities_bin" \
  HOME="$parquet_probe_root/home" \
  UV_TOOL_DIR=/ \
  DOTFILES_BOOTSTRAP_TEST_PARQUET_FUNCTION=install \
  DOTFILES_BOOTSTRAP_TEST_PARQUET_TOOL_ROOT="$parquet_probe_tools" \
  DOTFILES_BOOTSTRAP_TEST_PARQUET_PROBE_MARKER="$parquet_probe_root/missing.marker" \
  DOTFILES_BOOTSTRAP_TEST_PARQUET_INSTALL_BEHAVIOR=succeed \
  DOTFILES_BOOTSTRAP_TEST_PARQUET_INSTALL_MARKER="$parquet_unsafe_install_marker" \
  DOTFILES_BOOTSTRAP_TEST_PARQUET_ACTIONS="$parquet_install_actions" \
  "$parquet_function_bootstrap"
if [ "$run_status" -ne 0 ] \
  && [ ! -e "$parquet_unsafe_install_marker" ] \
  && [ ! -s "$parquet_install_actions" ]; then
  pass 'Parquet installation rejects a root uv tool directory before invocation'
else
  fail 'Parquet installation rejects a root uv tool directory before invocation'
fi

run_parquet_unsafe_target_case \
  'a root uv tool executable directory' \
  "$parquet_probe_tools" / 0 0
run_parquet_unsafe_target_case \
  'a relative uv tool directory' \
  relative/tools "$parquet_probe_root/custom-bin" 0 0
run_parquet_unsafe_target_case \
  'a non-normalized uv tool executable directory' \
  "$parquet_probe_tools" "$parquet_probe_root/custom/../bin" 0 0
run_parquet_unsafe_target_case \
  'a failing uv tool directory probe' \
  "$parquet_probe_tools" "$parquet_probe_root/custom-bin" 1 0
run_parquet_unsafe_target_case \
  'a failing uv tool executable directory probe' \
  "$parquet_probe_tools" "$parquet_probe_root/custom-bin" 0 1

mkdir -p "$parquet_probe_root/custom-bin"
run_parquet_trailing_slash_target_case \
  'a trailing slash in a custom uv tool directory' \
  "$parquet_probe_tools/" "$parquet_probe_root/custom-bin"
run_parquet_trailing_slash_target_case \
  'a trailing slash in a custom uv tool executable directory' \
  "$parquet_probe_tools" "$parquet_probe_root/custom-bin/"

: >"$parquet_install_actions"
parquet_caller_env_log=$parquet_probe_root/caller-uv-environment.log
parquet_project_root=$parquet_probe_root/project-state
mkdir -p "$parquet_project_root/.venv/bin" "$parquet_project_root/venv/bin"
printf '%s\n' '[project]' 'name = "sentinel"' \
  >"$parquet_project_root/pyproject.toml"
printf '%s\n' 'uv lock sentinel' >"$parquet_project_root/uv.lock"
printf '%s\n' 'poetry lock sentinel' >"$parquet_project_root/poetry.lock"
printf '%s\n' 'managed .venv sentinel' \
  >"$parquet_project_root/.venv/bin/python"
printf '%s\n' 'managed venv sentinel' \
  >"$parquet_project_root/venv/bin/python"
parquet_project_before=$(project_state_fingerprint "$parquet_project_root")
run_capture_in_directory \
  "$parquet_probe_root/install-sanitized.output" "$parquet_project_root" env \
  PATH="$parquet_probe_bin:$test_utilities_bin" \
  HOME="$parquet_probe_root/home" \
  UV_TOOL_DIR="$parquet_probe_tools" \
  UV_TOOL_BIN_DIR="$parquet_probe_root/custom-bin" \
  UV_BUILD_CONSTRAINT="$parquet_probe_root/build-constraints.txt" \
  UV_CONSTRAINT="$parquet_probe_root/constraints.txt" \
  UV_DEFAULT_INDEX=https://default-index.invalid/simple \
  UV_EXCLUDE=visidata \
  UV_EXCLUDE_NEWER=2020-01-01T00:00:00Z \
  UV_EXTRA_INDEX_URL=https://extra-index.invalid/simple \
  UV_FIND_LINKS=https://find-links.invalid/packages \
  UV_FORK_STRATEGY=fewest \
  UV_INDEX=https://named-index.invalid/simple \
  UV_INDEX_STRATEGY=unsafe-best-match \
  UV_INDEX_URL=https://index-url.invalid/simple \
  UV_OVERRIDE="$parquet_probe_root/overrides.txt" \
  UV_PRERELEASE=disallow \
  UV_RESOLUTION=lowest \
  UV_TORCH_BACKEND=cpu \
  DOTFILES_BOOTSTRAP_TEST_PARQUET_FUNCTION=install-preserves-environment \
  DOTFILES_BOOTSTRAP_TEST_PARQUET_TOOL_ROOT="$parquet_probe_tools" \
  DOTFILES_BOOTSTRAP_TEST_PARQUET_PROBE_MARKER="$parquet_probe_root/sanitized.marker" \
  DOTFILES_BOOTSTRAP_TEST_PARQUET_INSTALL_BEHAVIOR=repair-if-sanitized \
  DOTFILES_BOOTSTRAP_TEST_PARQUET_ACTIONS="$parquet_install_actions" \
  DOTFILES_BOOTSTRAP_TEST_PARQUET_CALLER_ENV_LOG="$parquet_caller_env_log" \
  "$parquet_function_bootstrap"
parquet_project_after=$(project_state_fingerprint "$parquet_project_root")
parquet_expected_caller_env="UV_BUILD_CONSTRAINT=$parquet_probe_root/build-constraints.txt
UV_CONSTRAINT=$parquet_probe_root/constraints.txt
UV_DEFAULT_INDEX=https://default-index.invalid/simple
UV_EXCLUDE=visidata
UV_EXCLUDE_NEWER=2020-01-01T00:00:00Z
UV_EXTRA_INDEX_URL=https://extra-index.invalid/simple
UV_FIND_LINKS=https://find-links.invalid/packages
UV_FORK_STRATEGY=fewest
UV_INDEX=https://named-index.invalid/simple
UV_INDEX_STRATEGY=unsafe-best-match
UV_INDEX_URL=https://index-url.invalid/simple
UV_OVERRIDE=$parquet_probe_root/overrides.txt
UV_PRERELEASE=disallow
UV_RESOLUTION=lowest
UV_TORCH_BACKEND=cpu"
if [ "$run_status" -eq 0 ] \
  && grep -Fqx 'uv-tool visidata@3.4+pyarrow@25.0.0+duckdb@1.5.5' "$parquet_install_actions" \
  && [ "$(cat "$parquet_caller_env_log" 2>/dev/null || true)" = "$parquet_expected_caller_env" ] \
  && [ "$parquet_project_after" = "$parquet_project_before" ]; then
  pass 'Parquet installation clears resolver variables without mutating its caller'
else
  fail 'Parquet installation clears resolver variables without mutating its caller'
fi
if [ "$parquet_project_after" = "$parquet_project_before" ]; then
  pass 'data-query tool repair preserves project and virtual-environment state'
else
  fail 'data-query tool repair preserves project and virtual-environment state'
fi

if [ "${DOTFILES_BOOTSTRAP_TEST_FOCUS:-}" = parquet ]; then
  printf '1..%s\n' "$tests"
  [ "$failures" -eq 0 ]
  exit $?
fi

run_capture "$test_tmp/help" "$bootstrap" --help
if [ "$run_status" -eq 0 ]; then
  pass '--help exits successfully'
else
  fail '--help exits successfully'
fi
help_output=$(cat "$test_tmp/help")
require_contains "$help_output" 'bootstrap [--apply]' '--help documents apply mode'
require_contains "$help_output" '--rollback (latest|RUN_ID)' '--help documents rollback mode'
require_contains "$help_output" '--allow-community-packages' '--help documents community package gate'

run_capture "$test_tmp/invalid" "$bootstrap" --unknown-option
if [ "$run_status" -eq 2 ]; then
  pass 'unknown options use the usage exit status'
else
  fail 'unknown options use the usage exit status'
fi

remote_manifest_block=$(sed -n '/load_remote_manifests() {/,/^}/p' "$bootstrap")
for manifest_name in \
  packages-npm-language-servers.json \
  packages-npm-language-servers-lock.json
do
  if [ "$(printf '%s\n' "$remote_manifest_block" | grep -Fxc "    $manifest_name \\")" -eq 1 ]; then
    pass "standalone allowlist includes $manifest_name exactly once"
  else
    fail "standalone allowlist includes $manifest_name exactly once"
  fi
done

if node -e '
const fs = require("fs");
const root = process.argv[1];
const manifest = JSON.parse(fs.readFileSync(root + "/packages-npm-language-servers.json", "utf8"));
const lock = JSON.parse(fs.readFileSync(root + "/packages-npm-language-servers-lock.json", "utf8"));
const expected = {"bash-language-server":"5.6.0","pyright":"1.1.411","vscode-langservers-extracted":"4.10.0","yaml-language-server":"1.24.0"};
if (!manifest.private || JSON.stringify(manifest.dependencies) !== JSON.stringify(expected)) process.exit(1);
if (lock.lockfileVersion !== 3 || JSON.stringify(lock.packages[""].dependencies) !== JSON.stringify(expected)) process.exit(1);
' "$dotfiles_dir/manifests"; then
  pass 'npm language-server manifests contain the exact private locked dependency root'
else
  fail 'npm language-server manifests contain the exact private locked dependency root'
fi

embedded_npm_lock_sha256=$(
  sed -n 's/^npm_language_servers_lock_sha256=\([0-9a-f][0-9a-f]*\)$/\1/p' "$bootstrap"
)
if command -v sha256sum >/dev/null 2>&1; then
  actual_npm_lock_sha256=$(
    sha256sum "$dotfiles_dir/manifests/packages-npm-language-servers-lock.json" \
      | awk '{ print $1 }'
  )
else
  actual_npm_lock_sha256=$(
    shasum -a 256 "$dotfiles_dir/manifests/packages-npm-language-servers-lock.json" \
      | awk '{ print $1 }'
  )
fi
if [ "${#embedded_npm_lock_sha256}" -eq 64 ] \
  && [ "$embedded_npm_lock_sha256" = "$actual_npm_lock_sha256" ] \
  && [ "$(grep -Ec '^npm_language_servers_lock_sha256=[0-9a-f]{64}$' "$bootstrap")" -eq 1 ]; then
  pass 'embedded npm lock SHA-256 matches the committed lockfile exactly once'
else
  fail 'embedded npm lock SHA-256 matches the committed lockfile exactly once'
fi

actual_taplo_records=$(
  awk -F '\t' '
    $1 == "taplo" {
      print $2 "|" $3 "|" $4 "|" $5 "|" $6 "|" $7
    }
  ' "$dotfiles_dir/manifests/packages-direct.tsv"
)
expected_taplo_records='linux|x86_64|0.10.0|gzip|https://github.com/tamasfe/taplo/releases/download/0.10.0/taplo-linux-x86_64.gz|8fe196b894ccf9072f98d4e1013a180306e17d244830b03986ee5e8eabeb6156
linux|arm64|0.10.0|gzip|https://github.com/tamasfe/taplo/releases/download/0.10.0/taplo-linux-aarch64.gz|033681d01eec8376c3fd38fa3703c79316f5e14bb013d859943b60a07bccdcc3'
if [ "$actual_taplo_records" = "$expected_taplo_records" ]; then
  pass 'direct manifest locks the exact two Taplo 0.10.0 artifacts'
else
  fail 'direct manifest locks the exact two Taplo 0.10.0 artifacts'
fi

actual_rishot_records=$(
  awk -F '\t' '
    $1 == "rishot" {
      print $2 "|" $3 "|" $4 "|" $5 "|" $6 "|" $7
    }
  ' "$dotfiles_dir/manifests/packages-direct.tsv"
)
expected_rishot_records='linux|any|28c273b1b573725e03ef12989451f48009dabc83|tar.gz|https://codeload.github.com/Gakuseei/rishot/tar.gz/28c273b1b573725e03ef12989451f48009dabc83|ea72430cd8f207a8e0143749fd5b764074d60f9461e0f9aa4226c269cd3afcf6'
if [ "$actual_rishot_records" = "$expected_rishot_records" ]; then
  pass 'direct manifest locks the exact Rishot source archive'
else
  fail 'direct manifest locks the exact Rishot source archive'
fi

for rishot_dependency in qt6-5compat quickshell; do
  if [ "$(grep -Fxc "$rishot_dependency" \
      "$dotfiles_dir/manifests/packages-pacman-hypr.list" || true)" -eq 1 ]; then
    pass "Hyprland owns exactly one $rishot_dependency dependency"
  else
    fail "Hyprland owns exactly one $rishot_dependency dependency"
  fi
done

linux_output=$(
  HOME="$test_tmp/linux-home" \
    XDG_STATE_HOME="$test_tmp/linux-state" \
    DOTFILES_BOOTSTRAP_TESTING=1 \
    DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
    DOTFILES_BOOTSTRAP_TEST_MANAGER=pacman \
    "$bootstrap"
)
require_contains "$linux_output" 'Mode: dry-run' 'no arguments select dry-run mode'
require_contains "$linux_output" 'Platform: linux' 'Linux platform is reported'
require_contains "$linux_output" 'Package manager: pacman' 'pacman backend is reported'
require_contains "$linux_output" '.config/tmux/conf/platform/linux.conf' 'Linux plan includes Linux tmux adapter'
require_contains "$linux_output" '.config/tmux/conf/persistence.conf' \
  'common plan includes tmux persistence binding'
require_contains "$linux_output" '.codex/hooks.json' \
  'common plan includes Codex lifecycle hooks'
require_contains "$linux_output" '.config/systemd/user/tmux-workspace.service' \
  'Linux plan includes the tmux workspace user service'
require_contains "$linux_output" 'systemctl --user daemon-reload' \
  'Linux dry-run reports the user daemon reload'
require_contains "$linux_output" 'systemctl --user enable tmux-workspace.service' \
  'Linux dry-run reports service enablement and startup'
require_excludes "$linux_output" '.config/tmux/conf/platform/macos.conf' 'Linux plan excludes macOS tmux adapter'
require_excludes "$linux_output" 'Library/Application Support/com.mitchellh.ghostty/config.ghostty' 'Linux plan excludes macOS Ghostty entrypoint'

require_contains "$linux_output" 'install pacman neovim' 'pacman plan includes Neovim'
require_contains "$linux_output" 'install pacman ghostty' 'pacman plan includes Ghostty'
require_contains "$linux_output" 'install pacman ttf-space-mono-nerd' 'pacman plan includes the configured font'
require_contains "$linux_output" 'install pacman imagemagick' \
  'pacman plan includes ImageMagick'
require_contains "$linux_output" 'install pacman uv' \
  'pacman plan includes uv'
require_contains "$linux_output" 'install pacman bubblewrap' \
  'pacman plan includes Bubblewrap for sandboxed data queries'
require_contains "$linux_output" \
  'ensure uv-tool visidata==3.4 with pyarrow==25.0.0 and duckdb==1.5.5' \
  'pacman plan includes the exact data-query tool environment'
require_contains "$linux_output" 'manual sudo pacman -Syu --needed' 'pacman plan requires an explicit full upgrade'
require_contains "$linux_output" 'install upstream herdr' 'pacman plan uses the official Herdr installer'
for provider in \
  bash-language-server \
  vscode-json-languageserver \
  lua-language-server \
  pyright \
  taplo-cli \
  yaml-language-server
do
  require_contains "$linux_output" "install pacman $provider" \
    "pacman plan includes $provider"
done

apt_output=$(
  HOME="$test_tmp/apt-home" \
    XDG_STATE_HOME="$test_tmp/apt-state" \
    DOTFILES_BOOTSTRAP_TESTING=1 \
    DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
    DOTFILES_BOOTSTRAP_TEST_MANAGER=apt \
    DOTFILES_BOOTSTRAP_TEST_APT_GHOSTTY_OFFICIAL=0 \
    "$bootstrap"
)
require_contains "$apt_output" 'install apt git' 'apt plan includes Git'
require_contains "$apt_output" 'install apt imagemagick' \
  'apt plan includes ImageMagick'
require_contains "$apt_output" 'install upstream neovim >=0.12.0' 'apt plan preserves the Neovim version floor'
require_contains "$apt_output" 'install upstream herdr' 'apt plan uses the official Herdr installer'
require_contains "$apt_output" \
  'ensure upstream uv >=0.11.6 (fallback uv 0.12.5)' \
  'apt plan preserves the uv version floor and pinned fallback'
require_contains "$apt_output" 'install apt bubblewrap' \
  'apt plan includes Bubblewrap for sandboxed data queries'
require_contains "$apt_output" \
  'ensure uv-tool visidata==3.4 with pyarrow==25.0.0 and duckdb==1.5.5' \
  'apt plan includes the exact data-query tool environment'
require_contains "$apt_output" 'blocked community ghostty' 'apt plan blocks community Ghostty without consent'
apt_lsp_plan=$(printf '%s\n' "$apt_output" | sed -n '/ensure upstream node >=22.0.0/,/ensure npm yaml-language-server@1.24.0/p')
expected_apt_lsp_plan='  ensure upstream node >=22.0.0 with npm >=10.0.0 (fallback node 24.19.0)
  ensure upstream lua-language-server >=3.19.1
  ensure upstream taplo >=0.10.0 (fallback taplo 0.10.0)
  ensure npm bash-language-server@5.6.0
  ensure npm vscode-langservers-extracted@4.10.0
  ensure npm pyright@1.1.411
  ensure npm yaml-language-server@1.24.0'
if [ "$apt_lsp_plan" = "$expected_apt_lsp_plan" ]; then
  pass 'apt plan preserves the exact ordered language-server fallback contract'
else
  fail 'apt plan preserves the exact ordered language-server fallback contract'
fi

apt_community_output=$(
  HOME="$test_tmp/apt-community-home" \
    XDG_STATE_HOME="$test_tmp/apt-community-state" \
    DOTFILES_BOOTSTRAP_TESTING=1 \
    DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
    DOTFILES_BOOTSTRAP_TEST_MANAGER=apt \
    DOTFILES_BOOTSTRAP_TEST_APT_GHOSTTY_OFFICIAL=0 \
    "$bootstrap" --allow-community-packages
)
require_contains "$apt_community_output" 'install community ghostty' 'apt plan includes community Ghostty after explicit consent'

apt_official_output=$(
  HOME="$test_tmp/apt-official-home" \
    XDG_STATE_HOME="$test_tmp/apt-official-state" \
    DOTFILES_BOOTSTRAP_TESTING=1 \
    DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
    DOTFILES_BOOTSTRAP_TEST_MANAGER=apt \
    DOTFILES_BOOTSTRAP_TEST_APT_GHOSTTY_OFFICIAL=1 \
    "$bootstrap"
)
if printf '%s\n' "$apt_official_output" | grep -Fq 'install apt ghostty' \
  && ! printf '%s\n' "$apt_official_output" | grep -Fq 'blocked community ghostty'; then
  pass 'apt plan prefers an available official Ghostty package'
else
  fail 'apt plan prefers an available official Ghostty package'
fi

macos_output=$(
  HOME="$test_tmp/macos-home" \
    XDG_STATE_HOME="$test_tmp/macos-state" \
    DOTFILES_BOOTSTRAP_TESTING=1 \
    DOTFILES_BOOTSTRAP_TEST_PLATFORM=macos \
    DOTFILES_BOOTSTRAP_TEST_MANAGER=homebrew \
    "$bootstrap"
)
require_contains "$macos_output" '.config/tmux/conf/platform/macos.conf' 'macOS plan includes macOS tmux adapter'
require_contains "$macos_output" 'Library/LaunchAgents/dev.ruohao.tmux-workspace.plist' \
  'macOS plan includes the tmux workspace LaunchAgent'
require_contains "$macos_output" "launchctl bootstrap gui/$(id -u)" \
  'macOS dry-run reports LaunchAgent bootstrap'
require_contains "$macos_output" \
  "launchctl kickstart -k gui/$(id -u)/dev.ruohao.tmux-workspace" \
  'macOS dry-run reports LaunchAgent kickstart'
require_contains "$macos_output" 'install homebrew-formula neovim' 'Homebrew plan includes Neovim formula'
require_contains "$macos_output" 'install homebrew-formula tree-sitter-cli' \
  'Homebrew plan includes the Tree-sitter CLI formula'
require_contains "$macos_output" 'install homebrew-cask ghostty' 'Homebrew plan includes Ghostty cask'
require_contains "$macos_output" \
  'ensure uv-tool visidata==3.4 with pyarrow==25.0.0 and duckdb==1.5.5' \
  'Homebrew plan keeps the shared editor tool environment exact'
require_excludes "$macos_output" 'bubblewrap' \
  'Homebrew plan excludes the Linux-only Bubblewrap dependency'
for provider in \
  bash-language-server \
  vscode-langservers-extracted \
  lua-language-server \
  pyright \
  taplo \
  yaml-language-server
do
  require_contains "$macos_output" "install homebrew-formula $provider" \
    "Homebrew plan includes $provider"
done
require_excludes "$macos_output" '.config/tmux/conf/platform/linux.conf' 'macOS plan excludes Linux tmux adapter'
require_contains "$macos_output" \
  'backup and set Spotlight shortcut Command+Shift+semicolon' \
  'macOS dry-run reports the transactional Spotlight shortcut change'
require_excludes "$macos_output" 'NSWindowShouldDragOnGesture' \
  'macOS none dry-run excludes the AeroSpace window-drag preference'
require_excludes "$macos_output" 'required macOS setup' \
  'macOS none dry-run excludes the Karabiner permission step'
workspace_launch_agent=$workspace_root/Library/LaunchAgents/dev.ruohao.tmux-workspace.plist
if grep -Fq '<key>RunAtLoad</key>' "$workspace_launch_agent" \
  && grep -Fq '<key>KeepAlive</key>' "$workspace_launch_agent" \
  && grep -Fq '<string>/bin/sh</string>' "$workspace_launch_agent" \
  && ! grep -Fq '/home/ruohao' "$workspace_launch_agent"; then
  pass 'workspace LaunchAgent is portable and starts automatically'
else
  fail 'workspace LaunchAgent is portable and starts automatically'
fi

if [ ! -e "$test_tmp/linux-home" ] && [ ! -e "$test_tmp/linux-state" ]; then
  pass 'dry-run creates no persistent home or state paths'
else
  fail 'dry-run creates no persistent home or state paths'
fi

apt_blocked_log=$test_tmp/apt-blocked.commands
run_capture "$test_tmp/apt-blocked.output" env \
  HOME="$test_tmp/apt-blocked-home" \
  XDG_STATE_HOME="$test_tmp/apt-blocked-state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=apt \
  DOTFILES_BOOTSTRAP_TEST_ALL_PACKAGES_MISSING=1 \
  DOTFILES_BOOTSTRAP_TEST_APT_GHOSTTY_OFFICIAL=0 \
  DOTFILES_BOOTSTRAP_TEST_STOP_AFTER_PACKAGES=1 \
  DOTFILES_BOOTSTRAP_TEST_COMMAND_LOG="$apt_blocked_log" \
  "$bootstrap" --apply
if [ "$run_status" -eq 4 ]; then
  pass 'apt apply blocks before changes when community consent is missing'
else
  fail 'apt apply blocks before changes when community consent is missing'
fi
apt_blocked_output=$(cat "$test_tmp/apt-blocked.output")
require_contains "$apt_blocked_output" '--allow-community-packages' 'apt block explains the community package flag'
if [ ! -e "$apt_blocked_log" ]; then
  pass 'blocked apt apply executes no package commands'
else
  fail 'blocked apt apply executes no package commands'
fi

apt_apply_log=$test_tmp/apt-apply.commands
run_capture "$test_tmp/apt-apply.output" env \
  HOME="$test_tmp/apt-apply-home" \
  XDG_STATE_HOME="$test_tmp/apt-apply-state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=apt \
  DOTFILES_BOOTSTRAP_TEST_ALL_PACKAGES_MISSING=1 \
  DOTFILES_BOOTSTRAP_TEST_SATISFIED_TOOLS= \
  DOTFILES_BOOTSTRAP_TEST_APT_GHOSTTY_OFFICIAL=0 \
  DOTFILES_BOOTSTRAP_TEST_STOP_AFTER_PACKAGES=1 \
  DOTFILES_BOOTSTRAP_TEST_COMMAND_LOG="$apt_apply_log" \
  "$bootstrap" --apply --allow-community-packages
if [ "$run_status" -eq 0 ]; then
  pass 'apt package phase succeeds with explicit community consent'
else
  fail 'apt package phase succeeds with explicit community consent'
fi
apt_apply_commands=$(cat "$apt_apply_log" 2>/dev/null || true)
require_contains "$apt_apply_commands" 'sudo apt-get update' 'apt package phase refreshes indexes only during apply'
require_contains "$apt_apply_commands" 'sudo apt-get install -y --no-install-recommends --no-remove' 'apt package install refuses removals'
require_contains "$apt_apply_commands" 'direct-install neovim' 'apt package phase installs supported Neovim upstream'
require_contains "$apt_apply_commands" 'direct-install uv' \
  'apt package phase installs the supported uv fallback'
require_contains "$apt_apply_commands" 'community-installer ghostty' 'apt package phase records the consented Ghostty installer'
require_contains "$apt_apply_commands" \
  'uv tool install --force --with pyarrow==25.0.0 --with duckdb==1.5.5 --no-config visidata==3.4' \
  'apt apply installs the exact data-query tool environment'

parquet_failure_log=$test_tmp/parquet-failure.commands
run_capture "$test_tmp/parquet-failure.output" env \
  HOME="$test_tmp/parquet-failure-home" \
  XDG_STATE_HOME="$test_tmp/parquet-failure-state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=apt \
  DOTFILES_BOOTSTRAP_TEST_ALL_PACKAGES_MISSING=1 \
  DOTFILES_BOOTSTRAP_TEST_APT_GHOSTTY_OFFICIAL=1 \
  DOTFILES_BOOTSTRAP_TEST_PARQUET_INSTALL_FAIL=1 \
  DOTFILES_BOOTSTRAP_TEST_STOP_AFTER_PACKAGES=1 \
  DOTFILES_BOOTSTRAP_TEST_COMMAND_LOG="$parquet_failure_log" \
  "$bootstrap" --apply
parquet_failure_output=$(cat "$test_tmp/parquet-failure.output")
if [ "$run_status" -ne 0 ] \
  && printf '%s\n' "$parquet_failure_output" \
    | grep -Fq 'Parquet viewer installation failed'; then
  pass 'Parquet viewer installation failure stops the bootstrap'
else
  fail 'Parquet viewer installation failure stops the bootstrap'
fi
require_contains "$(cat "$parquet_failure_log" 2>/dev/null || true)" \
  'uv tool install --force --with pyarrow==25.0.0 --with duckdb==1.5.5 --no-config visidata==3.4' \
  'data-query tool failure records the attempted exact install'

apt_update_line=$(printf '%s\n' "$apt_apply_commands" | grep -nF 'sudo apt-get update' | head -n 1 | cut -d: -f1)
apt_install_line=$(printf '%s\n' "$apt_apply_commands" | grep -nF 'sudo apt-get install ' | head -n 1 | cut -d: -f1)
managed_node_line=$(printf '%s\n' "$apt_apply_commands" | grep -nF 'direct-install node' | head -n 1 | cut -d: -f1)
managed_lua_line=$(printf '%s\n' "$apt_apply_commands" | grep -nF 'direct-install lua-language-server' | head -n 1 | cut -d: -f1)
managed_taplo_line=$(printf '%s\n' "$apt_apply_commands" | grep -nF 'direct-install taplo' | head -n 1 | cut -d: -f1)
managed_npm_line=$(printf '%s\n' "$apt_apply_commands" | grep -nF 'npm-ci --ignore-scripts --omit=dev --no-audit --no-fund' | head -n 1 | cut -d: -f1)
if [ -n "$apt_update_line" ] \
  && [ "$apt_update_line" -lt "$apt_install_line" ] \
  && [ "$apt_install_line" -lt "$managed_node_line" ] \
  && [ "$managed_node_line" -lt "$managed_lua_line" ] \
  && [ "$managed_lua_line" -lt "$managed_taplo_line" ] \
  && [ "$managed_taplo_line" -lt "$managed_npm_line" ]; then
  pass 'Debian apply preserves apt Node LuaLS Taplo and npm installation order'
else
  fail 'Debian apply preserves apt Node LuaLS Taplo and npm installation order'
fi

run_satisfaction_case exact \
  22.0.0 10.0.0 5.6.0 wait 3.19.1 wait 1.1.411 1.24.0 0.11.6
if [ "$satisfaction_case_status" -eq 0 ] \
  && ! printf '%s\n' "$satisfaction_case_commands" \
    | grep -Eq '^(direct-install (node|lua-language-server|taplo)|npm-ci )'; then
  pass 'exact Node npm and language-server floors are preserved'
else
  fail 'exact Node npm and language-server floors are preserved'
fi

satisfaction_lower_versions_pass=true
run_satisfaction_case node-low \
  21.99.0 10.0.0 5.6.0 wait 3.19.1 wait 1.1.411 1.24.0 0.11.6
printf '%s\n' "$satisfaction_case_commands" | grep -Fqx 'direct-install node' \
  || satisfaction_lower_versions_pass=false
run_satisfaction_case npm-low \
  22.0.0 9.99.0 5.6.0 wait 3.19.1 wait 1.1.411 1.24.0 0.11.6
printf '%s\n' "$satisfaction_case_commands" | grep -Fqx 'direct-install node' \
  || satisfaction_lower_versions_pass=false
run_satisfaction_case bash-low \
  22.0.0 10.0.0 5.5.9 wait 3.19.1 wait 1.1.411 1.24.0 0.11.6
printf '%s\n' "$satisfaction_case_commands" \
  | grep -Fqx 'npm-ci --ignore-scripts --omit=dev --no-audit --no-fund' \
  || satisfaction_lower_versions_pass=false
run_satisfaction_case lua-low \
  22.0.0 10.0.0 5.6.0 wait 3.19.0 wait 1.1.411 1.24.0 0.11.6
printf '%s\n' "$satisfaction_case_commands" | grep -Fqx 'direct-install lua-language-server' \
  || satisfaction_lower_versions_pass=false
run_satisfaction_case yaml-low \
  22.0.0 10.0.0 5.6.0 wait 3.19.1 wait 1.1.411 1.23.9 0.11.6
printf '%s\n' "$satisfaction_case_commands" \
  | grep -Fqx 'npm-ci --ignore-scripts --omit=dev --no-audit --no-fund' \
  || satisfaction_lower_versions_pass=false
run_satisfaction_case uv-low \
  22.0.0 10.0.0 5.6.0 wait 3.19.1 wait 1.1.411 1.24.0 0.11.5
printf '%s\n' "$satisfaction_case_commands" | grep -Fqx 'direct-install uv' \
  || satisfaction_lower_versions_pass=false
if [ "$satisfaction_lower_versions_pass" = true ]; then
  pass 'each immediately lower version selects its exact managed fallback'
else
  fail 'each immediately lower version selects its exact managed fallback'
fi

satisfaction_stdio_pass=true
run_satisfaction_case json-fail \
  22.0.0 10.0.0 5.6.0 fail 3.19.1 wait 1.1.411 1.24.0 0.11.6
printf '%s\n' "$satisfaction_case_commands" \
  | grep -Fqx 'npm-ci --ignore-scripts --omit=dev --no-audit --no-fund' \
  || satisfaction_stdio_pass=false
run_satisfaction_case pyright-fail \
  22.0.0 10.0.0 5.6.0 wait 3.19.1 fail 1.1.411 1.24.0 0.11.6
printf '%s\n' "$satisfaction_case_commands" \
  | grep -Fqx 'npm-ci --ignore-scripts --omit=dev --no-audit --no-fund' \
  || satisfaction_stdio_pass=false
run_satisfaction_case pyright-companion-low \
  22.0.0 10.0.0 5.6.0 wait 3.19.1 wait 1.1.410 1.24.0 0.11.6
printf '%s\n' "$satisfaction_case_commands" \
  | grep -Fqx 'npm-ci --ignore-scripts --omit=dev --no-audit --no-fund' \
  || satisfaction_stdio_pass=false
if [ "$satisfaction_stdio_pass" = true ]; then
  pass 'stdio startup and the Pyright companion floor select managed fallbacks'
else
  fail 'stdio startup and the Pyright companion floor select managed fallbacks'
fi

satisfaction_taplo_pass=true
run_satisfaction_case taplo-newer \
  22.0.0 10.0.0 5.6.0 wait 3.19.1 wait 1.1.411 1.24.0 \
  0.11.6 'taplo 0.10.1' success
printf '%s\n' "$satisfaction_case_commands" | grep -Fqx 'direct-install taplo' \
  && satisfaction_taplo_pass=false
run_satisfaction_case taplo-low \
  22.0.0 10.0.0 5.6.0 wait 3.19.1 wait 1.1.411 1.24.0 \
  0.11.6 'taplo 0.9.9' success
printf '%s\n' "$satisfaction_case_commands" | grep -Fqx 'direct-install taplo' \
  || satisfaction_taplo_pass=false
run_satisfaction_case taplo-prerelease \
  22.0.0 10.0.0 5.6.0 wait 3.19.1 wait 1.1.411 1.24.0 \
  0.11.6 'taplo 0.10.0-rc.1' success
printf '%s\n' "$satisfaction_case_commands" | grep -Fqx 'direct-install taplo' \
  || satisfaction_taplo_pass=false
run_satisfaction_case taplo-no-lsp \
  22.0.0 10.0.0 5.6.0 wait 3.19.1 wait 1.1.411 1.24.0 \
  0.11.6 'taplo 0.10.0' fail
printf '%s\n' "$satisfaction_case_commands" | grep -Fqx 'direct-install taplo' \
  || satisfaction_taplo_pass=false
run_satisfaction_case taplo-malformed-version \
  22.0.0 10.0.0 5.6.0 wait 3.19.1 wait 1.1.411 1.24.0 \
  0.11.6 'Taplo version unknown' success
printf '%s\n' "$satisfaction_case_commands" | grep -Fqx 'direct-install taplo' \
  || satisfaction_taplo_pass=false
run_satisfaction_case taplo-empty-version \
  22.0.0 10.0.0 5.6.0 wait 3.19.1 wait 1.1.411 1.24.0 \
  0.11.6 '' success
printf '%s\n' "$satisfaction_case_commands" | grep -Fqx 'direct-install taplo' \
  || satisfaction_taplo_pass=false
run_satisfaction_case taplo-hanging-lsp \
  22.0.0 10.0.0 5.6.0 wait 3.19.1 wait 1.1.411 1.24.0 \
  0.11.6 'taplo 0.10.0' hang
printf '%s\n' "$satisfaction_case_commands" | grep -Fqx 'direct-install taplo' \
  || satisfaction_taplo_pass=false
taplo_hanging_pid=$(cat "$satisfaction_root/taplo-probe.pid" 2>/dev/null || true)
case "$taplo_hanging_pid" in
  ''|*[!0-9]*) satisfaction_taplo_pass=false ;;
  *)
    kill -0 "$taplo_hanging_pid" >/dev/null 2>&1 \
      && satisfaction_taplo_pass=false
    ;;
esac
if [ "$satisfaction_taplo_pass" = true ]; then
  pass 'Taplo requires a stable version floor and bounded LSP capability'
else
  fail 'Taplo requires a stable version floor and bounded LSP capability'
fi

for runtime_apply_kind in setsid env; do
  run_debian_runtime_apply_case "$runtime_apply_kind" "$runtime_apply_kind"
  runtime_apply_pass=true
  runtime_apply_expected_args=$(
    expected_runtime_capability_args "$runtime_apply_kind"
  )
  runtime_apply_expected_diagnostic=$(
    runtime_capability_diagnostic "$runtime_apply_kind"
  )
  [ "$runtime_apply_status" -ne 0 ] || runtime_apply_pass=false
  [ "$(printf '%s\n' "$runtime_apply_output" \
    | grep -Fxc "$runtime_apply_expected_diagnostic" || true)" -eq 1 ] \
    || runtime_apply_pass=false
  [ "$runtime_apply_capability_args" = "$runtime_apply_expected_args" ] \
    || runtime_apply_pass=false
  [ "$runtime_apply_commands" = runtime-command-baseline ] \
    || runtime_apply_pass=false
  [ "$runtime_apply_tracking_started" = false ] \
    || runtime_apply_pass=false
  [ "$runtime_apply_seed_preserved" = true ] \
    || runtime_apply_pass=false
  only_ownership_coordination "$runtime_apply_home" || runtime_apply_pass=false
  [ "$runtime_apply_residue" = true ] || runtime_apply_pass=false
  case "$runtime_apply_kind" in
    setsid)
      setsid_contract_root=$test_tmp/setsid-contract
      setsid_contract_bin=$setsid_contract_root/bin
      setsid_contract_log=$setsid_contract_root/setsid.args
      setsid_contract_marker=$setsid_contract_root/target-started
      setsid_contract_command=$setsid_contract_root/probe-target
      mkdir -p "$setsid_contract_bin"
      : >"$setsid_contract_log"
      make_probe_tree_command \
        "$setsid_contract_command" marker-success \
        "$setsid_contract_root/target.pid" \
        "$setsid_contract_root/child.pid" \
        "$setsid_contract_marker"
      make_direct_runtime_command \
        setsid "$setsid_contract_bin/setsid" \
        "$setsid_contract_log" "$test_real_setsid" reject-launch
      make_direct_runtime_command \
        env "$setsid_contract_bin/env" \
        "$setsid_contract_root/env.args" "$test_real_env" delegate
      run_direct_probe_case \
        setsid-contract "$setsid_contract_command" \
        "$direct_probe_bootstrap" \
        PATH="$setsid_contract_bin:$test_utilities_bin"
      [ "$run_status" -eq 42 ] || runtime_apply_pass=false
      grep -Fqx "capability|setsid|$setsid_contract_bin/setsid|-f|-w|/bin/sh|-c|exit 0" \
        "$setsid_contract_log" 2>/dev/null \
        || runtime_apply_pass=false
      grep -Fq "launch|setsid|$setsid_contract_bin/setsid|-f|-w|" \
        "$setsid_contract_log" 2>/dev/null \
        || runtime_apply_pass=false
      [ ! -e "$setsid_contract_marker" ] || runtime_apply_pass=false

      stored_runtime_root=$test_tmp/stored-runtime-reuse
      stored_runtime_bin=$stored_runtime_root/bin
      stored_runtime_poison_bin=$stored_runtime_root/post-gate-bin
      stored_runtime_log=$stored_runtime_root/runtime.args
      stored_runtime_poison_log=$stored_runtime_root/post-gate.args
      stored_runtime_audit=$stored_runtime_root/stored.paths
      stored_runtime_marker=$stored_runtime_root/target-started
      stored_runtime_command=$stored_runtime_root/probe-target
      mkdir -p "$stored_runtime_bin" "$stored_runtime_poison_bin"
      : >"$stored_runtime_log"
      : >"$stored_runtime_poison_log"
      make_probe_tree_command \
        "$stored_runtime_command" marker-success \
        "$stored_runtime_root/target.pid" \
        "$stored_runtime_root/child.pid" \
        "$stored_runtime_marker"
      make_direct_runtime_command \
        setsid "$stored_runtime_bin/setsid" \
        "$stored_runtime_log" "$test_real_setsid" delegate
      make_direct_runtime_command \
        env "$stored_runtime_bin/env" \
        "$stored_runtime_log" "$test_real_env" delegate
      make_post_gate_poison_command \
        "$stored_runtime_poison_bin/setsid" "$stored_runtime_poison_log"
      make_post_gate_poison_command \
        "$stored_runtime_poison_bin/env" "$stored_runtime_poison_log"
      run_direct_probe_case \
        stored-runtime-reuse "$stored_runtime_command" \
        "$direct_probe_bootstrap" \
        PATH="$stored_runtime_bin:$test_utilities_bin" \
        DOTFILES_BOOTSTRAP_TEST_DIRECT_PROBE_RUNTIME_AUDIT="$stored_runtime_audit" \
        DOTFILES_BOOTSTRAP_TEST_DIRECT_PROBE_EXPECTED_SETSID="$stored_runtime_bin/setsid" \
        DOTFILES_BOOTSTRAP_TEST_DIRECT_PROBE_EXPECTED_ENV="$stored_runtime_bin/env" \
        DOTFILES_BOOTSTRAP_TEST_DIRECT_PROBE_POST_GATE_PATH="$stored_runtime_poison_bin:$test_utilities_bin"
      stored_runtime_expected_paths=$(printf '%s\n' \
        "setsid|$stored_runtime_bin/setsid" \
        "env|$stored_runtime_bin/env")
      [ "$run_status" -eq 0 ] || runtime_apply_pass=false
      [ "$(cat "$stored_runtime_audit" 2>/dev/null || true)" \
        = "$stored_runtime_expected_paths" ] \
        || runtime_apply_pass=false
      stored_runtime_selected_setsid=$(
        sed -n 's/^setsid|//p' "$stored_runtime_audit" 2>/dev/null
      )
      stored_runtime_selected_env=$(
        sed -n 's/^env|//p' "$stored_runtime_audit" 2>/dev/null
      )
      case $stored_runtime_selected_setsid in
        /*) [ -x "$stored_runtime_selected_setsid" ] \
          || runtime_apply_pass=false ;;
        *) runtime_apply_pass=false ;;
      esac
      case $stored_runtime_selected_env in
        /*) [ -x "$stored_runtime_selected_env" ] \
          || runtime_apply_pass=false ;;
        *) runtime_apply_pass=false ;;
      esac
      stored_runtime_setsid_launch=launch\|setsid\|$stored_runtime_selected_setsid\|-f\|-w\|
      stored_runtime_env_launch=launch\|env\|$stored_runtime_selected_env\|--default-signal=HUP,INT,TERM\|
      [ "$(grep -Fc "$stored_runtime_setsid_launch" \
        "$stored_runtime_log" 2>/dev/null || true)" -eq 1 ] \
        || runtime_apply_pass=false
      [ "$(grep -Fc "$stored_runtime_env_launch" \
        "$stored_runtime_log" 2>/dev/null || true)" -eq 1 ] \
        || runtime_apply_pass=false
      [ -e "$stored_runtime_marker" ] || runtime_apply_pass=false
      [ ! -s "$stored_runtime_poison_log" ] || runtime_apply_pass=false
      runtime_probe_residue_is_absent "$direct_probe_tmp" \
        || runtime_apply_pass=false
      runtime_apply_label='Debian apply preflights util-linux setsid before every mutation'
      ;;
    env)
      runtime_apply_label='Debian apply preflights GNU env before every mutation'
      ;;
  esac
  if [ "$runtime_apply_pass" = true ]; then
    pass "$runtime_apply_label"
  else
    fail "$runtime_apply_label"
  fi
done

runtime_boundary_pass=true
for runtime_boundary_kind in setsid env; do
  runtime_boundary_expected_args=$(
    expected_runtime_capability_args "$runtime_boundary_kind"
  )
  runtime_boundary_expected_diagnostic=$(
    runtime_capability_diagnostic "$runtime_boundary_kind"
  )
  for runtime_boundary_case in standalone remote; do
    run_debian_runtime_boundary_case \
      "$runtime_boundary_kind-$runtime_boundary_case" \
      "$runtime_boundary_kind" \
      "$runtime_boundary_case"
    [ "$runtime_boundary_status" -ne 0 ] \
      || runtime_boundary_pass=false
    [ "$(printf '%s\n' "$runtime_boundary_output" \
      | grep -Fxc "$runtime_boundary_expected_diagnostic" || true)" -eq 1 ] \
      || runtime_boundary_pass=false
    [ "$runtime_boundary_capability_args" \
      = "$runtime_boundary_expected_args" ] \
      || runtime_boundary_pass=false
    [ "$runtime_boundary_commands" = runtime-command-baseline ] \
      || runtime_boundary_pass=false
    [ "$runtime_boundary_tracking_started" = false ] \
      || runtime_boundary_pass=false
    [ "$runtime_boundary_git_mutated" = false ] \
      || runtime_boundary_pass=false
    [ "$runtime_boundary_seed_preserved" = true ] \
      || runtime_boundary_pass=false
    only_ownership_coordination "$runtime_boundary_home" \
      || runtime_boundary_pass=false
    [ "$runtime_boundary_residue" = true ] \
      || runtime_boundary_pass=false
  done
done
if [ "$runtime_boundary_pass" = true ]; then
  pass 'Debian runtime preflight guards standalone and remote Git mutation'
else
  fail 'Debian runtime preflight guards standalone and remote Git mutation'
fi

probe_idle_root=$test_tmp/probe-idle-release-wait
probe_idle_tmp=$probe_idle_root/tmp
probe_idle_home=$probe_idle_root/home
probe_idle_state=$probe_idle_root/state
probe_idle_output=$probe_idle_root/output
probe_idle_command=$probe_idle_root/probe-target
probe_idle_marker=$probe_idle_root/target-started
probe_idle_hold_ready=$probe_idle_root/parent-hold.ready
probe_idle_hold_release=$probe_idle_root/parent-hold.release
probe_idle_hold_failed=$probe_idle_root/parent-hold.failed
probe_idle_bootstrap=$probe_idle_root/direct-probe-bootstrap
mkdir -p "$probe_idle_tmp" "$probe_idle_home" "$probe_idle_state"
make_probe_tree_command \
  "$probe_idle_command" marker-success \
  "$probe_idle_root/target.pid" \
  "$probe_idle_root/child.pid" \
  "$probe_idle_marker"
make_probe_parent_hold_bootstrap \
  "$direct_probe_bootstrap" "$probe_idle_bootstrap"
"$test_real_env" \
  TMPDIR="$probe_idle_tmp" \
  HOME="$probe_idle_home" \
  XDG_STATE_HOME="$probe_idle_state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_DIRECT_PROBE=1 \
  DOTFILES_BOOTSTRAP_TEST_DIRECT_PROBE_COMMAND="$probe_idle_command" \
  DOTFILES_BOOTSTRAP_TEST_PROBE_PARENT_HOLD=1 \
  DOTFILES_BOOTSTRAP_TEST_PROBE_PARENT_HOLD_READY="$probe_idle_hold_ready" \
  DOTFILES_BOOTSTRAP_TEST_PROBE_PARENT_HOLD_RELEASE="$probe_idle_hold_release" \
  DOTFILES_BOOTSTRAP_TEST_PROBE_PARENT_HOLD_FAILED="$probe_idle_hold_failed" \
  "$probe_idle_bootstrap" --apply \
  >"$probe_idle_output" 2>&1 &
probe_idle_owner=$!
probe_idle_pass=true
probe_idle_anchor=
probe_idle_waiter=
probe_idle_private_root=$probe_idle_root
probe_idle_owner_identity=
probe_idle_owner_command_line=
probe_idle_anchor_identity=
probe_idle_anchor_command_line=
probe_idle_waiter_identity=
probe_idle_waiter_command_line=
if capture_test_process_bounded \
  "$probe_idle_owner" "$probe_idle_bootstrap" "$$"; then
  probe_idle_owner_identity=$captured_process_identity
  probe_idle_owner_command_line=$captured_process_command
else
  probe_idle_pass=false
fi
probe_idle_hold_attempt=0
while [ "$probe_idle_hold_attempt" -lt 80 ] \
  && [ ! -e "$probe_idle_hold_ready" ]
do
  sleep 0.05
  probe_idle_hold_attempt=$((probe_idle_hold_attempt + 1))
done
[ -e "$probe_idle_hold_ready" ] || probe_idle_pass=false
if wait_for_probe_record \
  "$probe_idle_tmp" anchor.ready "$probe_idle_owner"; then
  probe_idle_private_root=$(dirname "$observed_probe_record")
  probe_idle_anchor_record=$(
    cat "$probe_idle_private_root/anchor.ready" 2>/dev/null || true
  )
  probe_idle_anchor=${probe_idle_anchor_record%%|*}
  probe_idle_waiter=${probe_idle_anchor_record#*|}
  test_pid_is_safe "$probe_idle_anchor" || probe_idle_pass=false
  test_pid_is_safe "$probe_idle_waiter" || probe_idle_pass=false
  if [ "$probe_idle_pass" = true ] \
    && capture_test_process_bounded \
      "$probe_idle_waiter" "$probe_idle_private_root" "$probe_idle_owner"; then
    probe_idle_waiter_identity=$captured_process_identity
    probe_idle_waiter_command_line=$captured_process_command
  else
    probe_idle_pass=false
  fi
  if [ "$probe_idle_pass" = true ] \
    && capture_test_process_bounded \
      "$probe_idle_anchor" "$probe_idle_private_root" "$probe_idle_waiter"; then
    probe_idle_anchor_identity=$captured_process_identity
    probe_idle_anchor_command_line=$captured_process_command
    [ "$probe_idle_anchor_identity" \
      = "$probe_idle_anchor|$probe_idle_waiter|$probe_idle_anchor|$probe_idle_anchor" ] \
      || probe_idle_pass=false
  else
    probe_idle_pass=false
  fi
else
  probe_idle_pass=false
fi
probe_idle_expected_snapshot=$probe_idle_anchor\|$probe_idle_waiter\|$probe_idle_anchor\|$probe_idle_anchor\|S
probe_idle_snapshot_one=$(
  probe_group_identity_snapshot "$probe_idle_anchor" 2>/dev/null || true
)
sleep 0.05
probe_idle_snapshot_two=$(
  probe_group_identity_snapshot "$probe_idle_anchor" 2>/dev/null || true
)
sleep 0.05
probe_idle_snapshot_three=$(
  probe_group_identity_snapshot "$probe_idle_anchor" 2>/dev/null || true
)
[ "$probe_idle_snapshot_one" = "$probe_idle_expected_snapshot" ] \
  || probe_idle_pass=false
[ "$probe_idle_snapshot_two" = "$probe_idle_expected_snapshot" ] \
  || probe_idle_pass=false
[ "$probe_idle_snapshot_three" = "$probe_idle_expected_snapshot" ] \
  || probe_idle_pass=false
: >"$probe_idle_hold_release"
finish_async_probe_case \
  "$probe_idle_owner" \
  "$probe_idle_owner_identity" \
  "$probe_idle_owner_command_line" \
  "$probe_idle_anchor" \
  "$probe_idle_anchor_identity" \
  "$probe_idle_anchor_command_line" \
  "$probe_idle_waiter" \
  "$probe_idle_waiter_identity" \
  "$probe_idle_waiter_command_line" \
  "$probe_idle_private_root" \
  "$probe_idle_bootstrap"
[ "$async_probe_was_forced" = false ] || probe_idle_pass=false
[ "$async_probe_reaped" = true ] || probe_idle_pass=false
[ "$async_probe_status" -eq 0 ] || probe_idle_pass=false
[ ! -e "$probe_idle_hold_failed" ] || probe_idle_pass=false
runtime_probe_residue_is_absent "$probe_idle_tmp" \
  || probe_idle_pass=false
private_probe_processes_are_absent "$probe_idle_private_root" \
  || {
    probe_idle_pass=false
    kill_private_probe_processes "$probe_idle_private_root"
  }
if [ "$probe_idle_pass" = true ]; then
  pass 'probe supervisor release wait sleeps without a helper child'
else
  fail 'probe supervisor release wait sleeps without a helper child'
fi

probe_token_root=$test_tmp/probe-release-token-race
probe_token_tmp=$probe_token_root/tmp
probe_token_home=$probe_token_root/home
probe_token_state=$probe_token_root/state
probe_token_output=$probe_token_root/output
probe_token_audit=$probe_token_root/audit
probe_token_command=$probe_token_root/probe-target
probe_token_marker=$probe_token_root/target-started
mkdir -p "$probe_token_tmp" "$probe_token_home" "$probe_token_state"
: >"$probe_token_audit"
make_probe_tree_command \
  "$probe_token_command" marker-success \
  "$probe_token_root/target.pid" \
  "$probe_token_root/child.pid" \
  "$probe_token_marker"
"$test_real_env" \
  TMPDIR="$probe_token_tmp" \
  HOME="$probe_token_home" \
  XDG_STATE_HOME="$probe_token_state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_DIRECT_PROBE=1 \
  DOTFILES_BOOTSTRAP_TEST_DIRECT_PROBE_COMMAND="$probe_token_command" \
  DOTFILES_BOOTSTRAP_TEST_PROBE_AUDIT_FILE="$probe_token_audit" \
  DOTFILES_BOOTSTRAP_TEST_PROBE_STOP_AFTER_RELEASE_READY=1 \
  DOTFILES_BOOTSTRAP_TEST_PROBE_STOP_BETWEEN_WAITS=1 \
  "$direct_probe_bootstrap" --apply \
  >"$probe_token_output" 2>&1 &
probe_token_owner=$!
probe_token_pass=true
probe_token_coordinated=true
probe_token_anchor=
probe_token_waiter=
probe_token_private_root=$probe_token_root
probe_token_owner_identity=
probe_token_owner_command_line=
probe_token_anchor_identity=
probe_token_anchor_command_line=
probe_token_waiter_identity=
probe_token_waiter_command_line=
probe_token_release_fifo=
if capture_test_process_bounded \
  "$probe_token_owner" "$direct_probe_bootstrap" "$$"; then
  probe_token_owner_identity=$captured_process_identity
  probe_token_owner_command_line=$captured_process_command
else
  probe_token_coordinated=false
fi
if wait_for_probe_record \
  "$probe_token_tmp" release.ready "$probe_token_owner"; then
  probe_token_private_root=$(dirname "$observed_probe_record")
  probe_token_anchor_record=$(
    cat "$probe_token_private_root/anchor.ready" 2>/dev/null || true
  )
  probe_token_anchor=${probe_token_anchor_record%%|*}
  probe_token_waiter=${probe_token_anchor_record#*|}
  test_pid_is_safe "$probe_token_anchor" \
    || probe_token_coordinated=false
  test_pid_is_safe "$probe_token_waiter" \
    || probe_token_coordinated=false
  if [ "$probe_token_coordinated" = true ] \
    && capture_test_process_bounded \
      "$probe_token_waiter" \
      "$probe_token_private_root" \
      "$probe_token_owner"; then
    probe_token_waiter_identity=$captured_process_identity
    probe_token_waiter_command_line=$captured_process_command
  else
    probe_token_coordinated=false
  fi
  if [ "$probe_token_coordinated" = true ] \
    && capture_test_process_bounded \
      "$probe_token_anchor" \
      "$probe_token_private_root" \
      "$probe_token_waiter"; then
    probe_token_anchor_identity=$captured_process_identity
    probe_token_anchor_command_line=$captured_process_command
    [ "$probe_token_anchor_identity" \
      = "$probe_token_anchor|$probe_token_waiter|$probe_token_anchor|$probe_token_anchor" ] \
      || probe_token_coordinated=false
  else
    probe_token_coordinated=false
  fi
else
  probe_token_coordinated=false
fi
if [ "$probe_token_coordinated" = true ] \
  && ! wait_for_test_process_state \
    "$probe_token_anchor" "$probe_token_anchor_identity" T; then
  probe_token_coordinated=false
fi
[ "$probe_token_coordinated" = true ] || probe_token_pass=false
if [ "$probe_token_coordinated" = true ]; then
  probe_token_owner_fifo=$(
    readlink "/proc/$probe_token_owner/fd/4" 2>/dev/null || true
  )
  probe_token_anchor_fifo=$(
    readlink "/proc/$probe_token_anchor/fd/5" 2>/dev/null || true
  )
  probe_token_release_fifo=$probe_token_owner_fifo
  [ -p "/proc/$probe_token_owner/fd/4" ] || probe_token_pass=false
  [ -p "/proc/$probe_token_anchor/fd/5" ] || probe_token_pass=false
  [ ! -e "/proc/$probe_token_anchor/fd/4" ] || probe_token_pass=false
  case $probe_token_release_fifo in
    /*) ;;
    *) probe_token_pass=false ;;
  esac
  [ "$(dirname "$probe_token_release_fifo" 2>/dev/null || true)" \
    = "$probe_token_private_root" ] \
    || probe_token_pass=false
  [ -p "$probe_token_release_fifo" ] || probe_token_pass=false
  [ "/proc/$probe_token_owner/fd/4" -ef "$probe_token_release_fifo" ] \
    || probe_token_pass=false
  [ "/proc/$probe_token_anchor/fd/5" -ef "$probe_token_release_fifo" ] \
    || probe_token_pass=false
  [ "/proc/$probe_token_owner/fd/4" -ef "/proc/$probe_token_anchor/fd/5" ] \
    || probe_token_pass=false
  [ "$probe_token_owner_fifo" = "$probe_token_release_fifo" ] \
    || probe_token_pass=false
  [ "$probe_token_anchor_fifo" = "$probe_token_release_fifo" ] \
    || probe_token_pass=false
  [ "$(probe_fd_access_mode "$probe_token_owner" 4 2>/dev/null || true)" = 2 ] \
    || probe_token_pass=false
  [ "$(probe_fd_access_mode "$probe_token_anchor" 5 2>/dev/null || true)" = 0 ] \
    || probe_token_pass=false
  probe_token_private_fifos=$(
    find "$probe_token_private_root" -mindepth 1 -maxdepth 1 \
      -type p -print 2>/dev/null || true
  )
  [ "$probe_token_private_fifos" = "$probe_token_release_fifo" ] \
    || probe_token_pass=false
  [ "$(probe_group_member_count "$probe_token_anchor")" -eq 1 ] \
    || probe_token_pass=false
  [ "$(probe_child_count "$probe_token_anchor")" -eq 0 ] \
    || probe_token_pass=false
  probe_token_close_attempt=0
  while [ "$probe_token_close_attempt" -lt 80 ] \
    && [ -e "/proc/$probe_token_owner/fd/4" ]
  do
    sleep 0.05
    probe_token_close_attempt=$((probe_token_close_attempt + 1))
  done
  [ ! -e "/proc/$probe_token_owner/fd/4" ] || probe_token_pass=false
  signal_verified_test_process \
    TERM "$probe_token_owner" \
    "$probe_token_owner_identity" "$probe_token_owner_command_line" \
    >/dev/null 2>&1 || probe_token_pass=false
  probe_token_interrupt_attempt=0
  while [ "$probe_token_interrupt_attempt" -lt 80 ] \
    && ! grep -Eq '^wait-interrupted\|[0-9]+$' \
      "$probe_token_audit" 2>/dev/null
  do
    sleep 0.05
    probe_token_interrupt_attempt=$((probe_token_interrupt_attempt + 1))
  done
  grep -Eq '^wait-interrupted\|[0-9]+$' \
    "$probe_token_audit" 2>/dev/null || probe_token_pass=false
  if ! wait_for_test_process_state \
    "$probe_token_owner" "$probe_token_owner_identity" T; then
    probe_token_pass=false
  fi
  signal_verified_test_process \
    CONT "$probe_token_anchor" \
    "$probe_token_anchor_identity" "$probe_token_anchor_command_line" \
    >/dev/null 2>&1 || probe_token_pass=false
  if ! wait_for_test_process_state \
    "$probe_token_waiter" "$probe_token_waiter_identity" Z; then
    probe_token_pass=false
  fi
  signal_verified_test_process \
    CONT "$probe_token_owner" \
    "$probe_token_owner_identity" "$probe_token_owner_command_line" \
    >/dev/null 2>&1 || probe_token_pass=false
fi
finish_async_probe_case \
  "$probe_token_owner" \
  "$probe_token_owner_identity" \
  "$probe_token_owner_command_line" \
  "$probe_token_anchor" \
  "$probe_token_anchor_identity" \
  "$probe_token_anchor_command_line" \
  "$probe_token_waiter" \
  "$probe_token_waiter_identity" \
  "$probe_token_waiter_command_line" \
  "$probe_token_private_root" \
  "$direct_probe_bootstrap"
[ "$async_probe_was_forced" = false ] || probe_token_pass=false
[ "$async_probe_reaped" = true ] || probe_token_pass=false
[ "$async_probe_status" -eq 143 ] || probe_token_pass=false
probe_token_wait_attempts=$(
  grep -Fxc "wait-attempt|$probe_token_waiter" \
    "$probe_token_audit" 2>/dev/null || true
)
[ "$probe_token_wait_attempts" -ge 2 ] || probe_token_pass=false
[ "$(grep -Fxc "wait-interrupted|$probe_token_waiter" \
  "$probe_token_audit" 2>/dev/null || true)" -eq 1 ] \
  || probe_token_pass=false
[ "$(grep -Fxc "waiter-status|$probe_token_waiter|0" \
  "$probe_token_audit" 2>/dev/null || true)" -eq 1 ] \
  || probe_token_pass=false
if grep -Eq '^waiter-kill-zero\|' "$probe_token_audit" 2>/dev/null; then
  probe_token_pass=false
fi
probe_wait_block=$(
  sed -n '/stop_owned_probe() {/,/^}/p' "$bootstrap"
)
if printf '%s\n' "$probe_wait_block" | grep -Eq 'kill[[:space:]]+-0'; then
  probe_token_pass=false
fi
[ ! -e "/proc/$probe_token_owner" ] || probe_token_pass=false
[ ! -e "/proc/$probe_token_anchor" ] || probe_token_pass=false
[ ! -e "/proc/$probe_token_waiter" ] || probe_token_pass=false
[ -z "$probe_token_release_fifo" ] \
  || [ ! -e "$probe_token_release_fifo" ] \
  || probe_token_pass=false
[ ! -d "$probe_token_private_root" ] || probe_token_pass=false
runtime_probe_residue_is_absent "$probe_token_tmp" \
  || probe_token_pass=false
if find "$probe_token_root" -type p -print -quit 2>/dev/null | grep -q .; then
  probe_token_pass=false
fi
private_probe_processes_are_absent "$probe_token_private_root" \
  || {
    probe_token_pass=false
    kill_private_probe_processes "$probe_token_private_root"
  }
if [ "$probe_token_pass" = true ]; then
  pass 'probe release token survives STOP deferred TERM and interrupted wait'
else
  fail 'probe release token survives STOP deferred TERM and interrupted wait'
fi

probe_predelivery_root=$test_tmp/probe-predelivery-anchor-loss
probe_predelivery_tmp=$probe_predelivery_root/tmp
probe_predelivery_home=$probe_predelivery_root/home
probe_predelivery_state=$probe_predelivery_root/state
probe_predelivery_output=$probe_predelivery_root/output
probe_predelivery_command=$probe_predelivery_root/probe-target
probe_predelivery_audit=$probe_predelivery_root/audit
probe_predelivery_target_release=$probe_predelivery_root/target.release
mkdir -p \
  "$probe_predelivery_tmp" \
  "$probe_predelivery_home" \
  "$probe_predelivery_state"
: >"$probe_predelivery_audit"
make_probe_tree_command \
  "$probe_predelivery_command" wait-for-release \
  "$probe_predelivery_root/target.pid" \
  "$probe_predelivery_root/child.pid" \
  "$probe_predelivery_target_release"
"$test_real_env" \
  TMPDIR="$probe_predelivery_tmp" \
  HOME="$probe_predelivery_home" \
  XDG_STATE_HOME="$probe_predelivery_state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_DIRECT_PROBE=1 \
  DOTFILES_BOOTSTRAP_TEST_DIRECT_PROBE_COMMAND="$probe_predelivery_command" \
  DOTFILES_BOOTSTRAP_TEST_PROBE_AUDIT_FILE="$probe_predelivery_audit" \
  DOTFILES_BOOTSTRAP_TEST_PROBE_LOSE_ANCHOR_BEFORE_RELEASE_TOKEN=1 \
  "$direct_probe_bootstrap" --apply \
  >"$probe_predelivery_output" 2>&1 &
probe_predelivery_owner=$!
probe_predelivery_pass=true
probe_predelivery_private_root=$probe_predelivery_tmp
probe_predelivery_anchor=
probe_predelivery_waiter=
probe_predelivery_target=
probe_predelivery_owner_identity=
probe_predelivery_owner_command_line=
probe_predelivery_anchor_identity=
probe_predelivery_anchor_command_line=
probe_predelivery_waiter_identity=
probe_predelivery_waiter_command_line=
if capture_test_process_bounded \
  "$probe_predelivery_owner" "$direct_probe_bootstrap" "$$"; then
  probe_predelivery_owner_identity=$captured_process_identity
  probe_predelivery_owner_command_line=$captured_process_command
else
  probe_predelivery_pass=false
fi
if wait_for_probe_record \
  "$probe_predelivery_tmp" anchor.ready "$probe_predelivery_owner"; then
  probe_predelivery_private_root=$(dirname "$observed_probe_record")
  probe_predelivery_anchor_record=$(
    cat "$probe_predelivery_private_root/anchor.ready" 2>/dev/null || true
  )
  probe_predelivery_anchor=${probe_predelivery_anchor_record%%|*}
  probe_predelivery_waiter=${probe_predelivery_anchor_record#*|}
  test_pid_is_safe "$probe_predelivery_anchor" \
    || probe_predelivery_pass=false
  test_pid_is_safe "$probe_predelivery_waiter" \
    || probe_predelivery_pass=false
  if [ "$probe_predelivery_pass" = true ] \
    && capture_test_process_bounded \
      "$probe_predelivery_waiter" \
      "$probe_predelivery_private_root" \
      "$probe_predelivery_owner"; then
    probe_predelivery_waiter_identity=$captured_process_identity
    probe_predelivery_waiter_command_line=$captured_process_command
  else
    probe_predelivery_pass=false
  fi
  if [ "$probe_predelivery_pass" = true ] \
    && capture_test_process_bounded \
      "$probe_predelivery_anchor" \
      "$probe_predelivery_private_root" \
      "$probe_predelivery_waiter"; then
    probe_predelivery_anchor_identity=$captured_process_identity
    probe_predelivery_anchor_command_line=$captured_process_command
    [ "$probe_predelivery_anchor_identity" \
      = "$probe_predelivery_anchor|$probe_predelivery_waiter|$probe_predelivery_anchor|$probe_predelivery_anchor" ] \
      || probe_predelivery_pass=false
  else
    probe_predelivery_pass=false
  fi
else
  probe_predelivery_pass=false
fi
probe_predelivery_target_attempt=0
while [ "$probe_predelivery_target_attempt" -lt 80 ] \
  && [ ! -s "$probe_predelivery_root/target.pid" ]
do
  sleep 0.05
  probe_predelivery_target_attempt=$((probe_predelivery_target_attempt + 1))
done
probe_predelivery_target=$(
  cat "$probe_predelivery_root/target.pid" 2>/dev/null || true
)
test_pid_is_safe "$probe_predelivery_target" \
  || probe_predelivery_pass=false
test_process_identity_matches \
  "$probe_predelivery_anchor" \
  "$probe_predelivery_anchor_identity" \
  "$probe_predelivery_anchor_command_line" \
  || probe_predelivery_pass=false
test_process_identity_matches \
  "$probe_predelivery_waiter" \
  "$probe_predelivery_waiter_identity" \
  "$probe_predelivery_waiter_command_line" \
  || probe_predelivery_pass=false
: >"$probe_predelivery_target_release"
finish_async_probe_case \
  "$probe_predelivery_owner" \
  "$probe_predelivery_owner_identity" \
  "$probe_predelivery_owner_command_line" \
  "$probe_predelivery_anchor" \
  "$probe_predelivery_anchor_identity" \
  "$probe_predelivery_anchor_command_line" \
  "$probe_predelivery_waiter" \
  "$probe_predelivery_waiter_identity" \
  "$probe_predelivery_waiter_command_line" \
  "$probe_predelivery_private_root" \
  "$direct_probe_bootstrap"
[ "$async_probe_reaped" = true ] || probe_predelivery_pass=false
[ "$async_probe_was_forced" = false ] || probe_predelivery_pass=false
[ "$async_probe_status" -eq 42 ] || probe_predelivery_pass=false
if ! awk -F '|' '
  $1 == "anchor-loss-before-release" {
      loss_events += 1
      loss_seen = 1
      next
    }
  loss_seen && ($1 == "group-term" || $1 == "group-kill") {
    later_group_signal = 1
  }
  END {
    exit !(loss_events == 1 && !later_group_signal)
  }
' "$probe_predelivery_audit" 2>/dev/null; then
  probe_predelivery_pass=false
fi
[ ! -e "/proc/$probe_predelivery_owner" ] \
  || probe_predelivery_pass=false
[ -z "$probe_predelivery_anchor" ] \
  || [ ! -e "/proc/$probe_predelivery_anchor" ] \
  || probe_predelivery_pass=false
[ -z "$probe_predelivery_waiter" ] \
  || [ ! -e "/proc/$probe_predelivery_waiter" ] \
  || probe_predelivery_pass=false
[ -z "$probe_predelivery_target" ] \
  || [ ! -e "/proc/$probe_predelivery_target" ] \
  || probe_predelivery_pass=false
[ ! -d "$probe_predelivery_private_root" ] \
  || probe_predelivery_pass=false
runtime_probe_residue_is_absent "$probe_predelivery_tmp" \
  || probe_predelivery_pass=false
private_probe_processes_are_absent "$probe_predelivery_tmp" \
  || {
    probe_predelivery_pass=false
    kill_private_probe_processes "$probe_predelivery_tmp"
  }
if find "$probe_predelivery_root" -type p -print -quit 2>/dev/null \
  | grep -q .; then
  probe_predelivery_pass=false
fi
if [ "$probe_predelivery_pass" = true ]; then
  pass 'probe anchor loss before token delivery fails closed'
else
  fail 'probe anchor loss before token delivery fails closed'
fi

missing_handshake_pass=true
for missing_handshake_kind in missing-anchor missing-target; do
  missing_handshake_root=$test_tmp/missing-handshake-$missing_handshake_kind
  missing_handshake_command=$missing_handshake_root/probe-target
  missing_handshake_marker=$missing_handshake_root/target-started
  mkdir -p "$missing_handshake_root"
  make_probe_tree_command \
    "$missing_handshake_command" marker-success \
    "$missing_handshake_root/target.pid" \
    "$missing_handshake_root/child.pid" \
    "$missing_handshake_marker"
  run_direct_probe_case "missing-handshake-$missing_handshake_kind" \
    "$missing_handshake_command" "$direct_probe_bootstrap" \
    DOTFILES_BOOTSTRAP_TEST_PROBE_HANDSHAKE="$missing_handshake_kind"
  [ "$run_status" -eq 42 ] || missing_handshake_pass=false
  [ ! -e "$missing_handshake_marker" ] || missing_handshake_pass=false
  if find "$direct_probe_tmp" -mindepth 1 -maxdepth 1 \
    -name 'dotfiles-bootstrap.*' -print -quit | grep -q .; then
    missing_handshake_pass=false
  fi
done
if [ "$missing_handshake_pass" = true ]; then
  pass 'missing probe handshakes fail closed'
else
  fail 'missing probe handshakes fail closed'
fi

malformed_handshake_pass=true
for malformed_handshake_kind in \
  malformed-anchor \
  malformed-anchor-ack \
  malformed-target \
  malformed-status
do
  malformed_handshake_root=$test_tmp/malformed-handshake-$malformed_handshake_kind
  malformed_handshake_command=$malformed_handshake_root/probe-target
  malformed_handshake_marker=$malformed_handshake_root/target-started
  mkdir -p "$malformed_handshake_root"
  make_probe_tree_command \
    "$malformed_handshake_command" marker-success \
    "$malformed_handshake_root/target.pid" \
    "$malformed_handshake_root/child.pid" \
    "$malformed_handshake_marker"
  run_direct_probe_case "malformed-handshake-$malformed_handshake_kind" \
    "$malformed_handshake_command" "$direct_probe_bootstrap" \
    DOTFILES_BOOTSTRAP_TEST_PROBE_HANDSHAKE="$malformed_handshake_kind"
  [ "$run_status" -eq 42 ] || malformed_handshake_pass=false
  case "$malformed_handshake_kind" in
    malformed-status)
      [ -e "$malformed_handshake_marker" ] || malformed_handshake_pass=false
      ;;
    *)
      [ ! -e "$malformed_handshake_marker" ] || malformed_handshake_pass=false
      ;;
  esac
  if find "$direct_probe_tmp" -mindepth 1 -maxdepth 1 \
    -name 'dotfiles-bootstrap.*' -print -quit | grep -q .; then
    malformed_handshake_pass=false
  fi
done
if [ "$malformed_handshake_pass" = true ]; then
  pass 'malformed probe handshakes fail closed'
else
  fail 'malformed probe handshakes fail closed'
fi

probe_ack_signal_root=$test_tmp/probe-ack-signal
probe_ack_signal_command=$probe_ack_signal_root/probe-target
probe_ack_signal_marker=$probe_ack_signal_root/target-started
mkdir -p "$probe_ack_signal_root"
make_probe_tree_command \
  "$probe_ack_signal_command" marker-success \
  "$probe_ack_signal_root/target.pid" \
  "$probe_ack_signal_root/child.pid" \
  "$probe_ack_signal_marker"
run_direct_probe_case probe-ack-signal "$probe_ack_signal_command" \
  "$direct_probe_bootstrap" \
  DOTFILES_BOOTSTRAP_TEST_PROBE_SIGNAL_AT=before-anchor-ack
probe_ack_signal_pass=true
[ "$run_status" -eq 143 ] || probe_ack_signal_pass=false
[ ! -e "$probe_ack_signal_marker" ] || probe_ack_signal_pass=false
[ "$(grep -Fc 'received TERM; stopping safely' \
  "$direct_probe_output" 2>/dev/null || true)" -eq 1 ] \
  || probe_ack_signal_pass=false
if find "$direct_probe_tmp" -mindepth 1 -maxdepth 1 \
  -name 'dotfiles-bootstrap.*' -print -quit | grep -q .; then
  probe_ack_signal_pass=false
fi
if [ "$probe_ack_signal_pass" = true ]; then
  pass 'signal during probe ACK registration is deferred without starting an unowned target'
else
  fail 'signal during probe ACK registration is deferred without starting an unowned target'
fi

for child_exit_kind in exit-zero-child exit-nonzero-child; do
  child_exit_root=$test_tmp/$child_exit_kind
  child_exit_command=$child_exit_root/probe-target
  child_exit_pid_file=$child_exit_root/target.pid
  child_exit_child_pid_file=$child_exit_root/child.pid
  child_exit_relation_file=$child_exit_root/relation
  child_exit_audit_file=$child_exit_root/probe.audit
  mkdir -p "$child_exit_root"
  make_probe_tree_command \
    "$child_exit_command" "$child_exit_kind" \
    "$child_exit_pid_file" \
    "$child_exit_child_pid_file" \
    "$child_exit_relation_file"
  run_direct_probe_case "$child_exit_kind" "$child_exit_command" \
    "$direct_probe_bootstrap" \
    DOTFILES_BOOTSTRAP_TEST_PROBE_AUDIT_FILE="$child_exit_audit_file"
  child_exit_pass=true
  case "$child_exit_kind:$run_status" in
    exit-zero-child:0|exit-nonzero-child:42) ;;
    *) child_exit_pass=false ;;
  esac
  child_exit_pid=$(cat "$child_exit_pid_file" 2>/dev/null || true)
  child_exit_child_pid=$(cat "$child_exit_child_pid_file" 2>/dev/null || true)
  [ "$(cat "$child_exit_relation_file" 2>/dev/null || true)" \
    = "$child_exit_pid|$child_exit_child_pid" ] || child_exit_pass=false
  [ "$(cat "$child_exit_relation_file.ready" 2>/dev/null || true)" = ready ] \
    || child_exit_pass=false
  # A target that exits before its child still requires owned group cleanup.
  if [ "$(grep -Fc 'group-term|' "$child_exit_audit_file" 2>/dev/null || true)" -ne 1 ]; then
    child_exit_pass=false
  fi
  case "$child_exit_child_pid" in
    ''|*[!0-9]*) child_exit_pass=false ;;
    *)
      if test_process_is_matching "$child_exit_child_pid" "$child_exit_command"; then
        child_exit_pass=false
        kill_matching_test_process "$child_exit_child_pid" "$child_exit_command"
      fi
      ;;
  esac
  if find "$direct_probe_tmp" -mindepth 1 -maxdepth 1 \
    -name 'dotfiles-bootstrap.*' -print -quit | grep -q .; then
    child_exit_pass=false
  fi
  case "$child_exit_kind" in
    exit-zero-child)
      child_exit_label='exit-zero probe reaps its distinct child before success'
      ;;
    exit-nonzero-child)
      child_exit_label='nonzero probe reaps its distinct child before fallback'
      ;;
  esac
  if [ "$child_exit_pass" = true ]; then
    pass "$child_exit_label"
  else
    fail "$child_exit_label"
  fi
done

probe_snapshot_root=$test_tmp/probe-status-snapshot
probe_snapshot_command=$probe_snapshot_root/probe-target
probe_snapshot_audit=$probe_snapshot_root/audit
mkdir -p "$probe_snapshot_root"
make_probe_tree_command \
  "$probe_snapshot_command" exit-seven \
  "$probe_snapshot_root/target.pid" \
  "$probe_snapshot_root/child.pid" \
  "$probe_snapshot_root/auxiliary"
run_direct_probe_case probe-status-snapshot "$probe_snapshot_command" \
  "$direct_probe_bootstrap" \
  DOTFILES_BOOTSTRAP_TEST_PROBE_AUDIT_FILE="$probe_snapshot_audit"
probe_snapshot_pass=true
[ "$run_status" -eq 42 ] || probe_snapshot_pass=false
grep -Eq '^status-before-term\|[0-9]+\|7$' "$probe_snapshot_audit" \
  2>/dev/null || probe_snapshot_pass=false
if find "$direct_probe_tmp" -mindepth 1 -maxdepth 1 \
  -name 'dotfiles-bootstrap.*' -print -quit | grep -q .; then
  probe_snapshot_pass=false
fi
if [ "$probe_snapshot_pass" = true ]; then
  pass 'probe deadline uses the complete pre-TERM target status snapshot'
else
  fail 'probe deadline uses the complete pre-TERM target status snapshot'
fi

probe_escalation_root=$test_tmp/probe-group-escalation
probe_escalation_command=$probe_escalation_root/probe-target
probe_escalation_pid_file=$probe_escalation_root/target.pid
probe_escalation_child_pid_file=$probe_escalation_root/child.pid
probe_escalation_relation_file=$probe_escalation_root/relation
probe_escalation_audit=$probe_escalation_root/audit
mkdir -p "$probe_escalation_root"
make_probe_tree_command \
  "$probe_escalation_command" ignore-term-tree \
  "$probe_escalation_pid_file" \
  "$probe_escalation_child_pid_file" \
  "$probe_escalation_relation_file"
run_direct_probe_case probe-group-escalation "$probe_escalation_command" \
  "$direct_probe_bootstrap" \
  DOTFILES_BOOTSTRAP_TEST_PROBE_AUDIT_FILE="$probe_escalation_audit"
probe_escalation_pass=true
[ "$run_status" -eq 42 ] || probe_escalation_pass=false
probe_escalation_pid=$(cat "$probe_escalation_pid_file" 2>/dev/null || true)
probe_escalation_child_pid=$(cat "$probe_escalation_child_pid_file" 2>/dev/null || true)
[ "$(cat "$probe_escalation_relation_file" 2>/dev/null || true)" \
  = "$probe_escalation_pid|$probe_escalation_child_pid" ] \
  || probe_escalation_pass=false
for probe_escalation_check_pid in \
  "$probe_escalation_pid" "$probe_escalation_child_pid"
do
  case "$probe_escalation_check_pid" in
    ''|*[!0-9]*) probe_escalation_pass=false ;;
    *)
      if test_process_is_matching \
        "$probe_escalation_check_pid" "$probe_escalation_command"; then
        probe_escalation_pass=false
        kill_matching_test_process \
          "$probe_escalation_check_pid" "$probe_escalation_command"
      fi
      ;;
  esac
done
if [ ! -r "$probe_escalation_audit" ] \
  || [ "$(grep -Ec '^group-term\|[0-9]+$' \
    "$probe_escalation_audit" || true)" -ne 1 ]; then
  probe_escalation_pass=false
fi
if [ ! -r "$probe_escalation_audit" ] \
  || [ "$(grep -Ec '^group-kill\|[0-9]+$' \
    "$probe_escalation_audit" || true)" -ne 1 ]; then
  probe_escalation_pass=false
fi
if find "$direct_probe_tmp" -mindepth 1 -maxdepth 1 \
  -name 'dotfiles-bootstrap.*' -print -quit | grep -q .; then
  probe_escalation_pass=false
fi
if [ "$probe_escalation_pass" = true ]; then
  pass 'TERM-ignoring probe tree is removed by one owned group escalation'
else
  fail 'TERM-ignoring probe tree is removed by one owned group escalation'
fi

probe_signal_reset_pass=true
for probe_signal_reset_kind in self-hup self-int self-term; do
  probe_signal_reset_root=$test_tmp/probe-signal-reset-$probe_signal_reset_kind
  probe_signal_reset_command=$probe_signal_reset_root/probe-target
  mkdir -p "$probe_signal_reset_root"
  make_probe_tree_command \
    "$probe_signal_reset_command" "$probe_signal_reset_kind" \
    "$probe_signal_reset_root/target.pid" \
    "$probe_signal_reset_root/child.pid" \
    "$probe_signal_reset_root/auxiliary"
  run_direct_probe_case "probe-signal-reset-$probe_signal_reset_kind" \
    "$probe_signal_reset_command" "$direct_probe_bootstrap"
  [ "$run_status" -eq 42 ] || probe_signal_reset_pass=false
done
if [ "$probe_signal_reset_pass" = true ]; then
  pass 'probe target starts with HUP INT TERM reset'
else
  fail 'probe target starts with HUP INT TERM reset'
fi

probe_teardown_signal_root=$test_tmp/probe-teardown-signal
probe_teardown_signal_command=$probe_teardown_signal_root/probe-target
probe_teardown_signal_audit=$probe_teardown_signal_root/audit
probe_unrelated_command=$probe_teardown_signal_root/unrelated-target
probe_unrelated_release=$probe_teardown_signal_root/unrelated.release
probe_unrelated_pid_file=$probe_teardown_signal_root/unrelated.pid
mkdir -p "$probe_teardown_signal_root"
make_probe_tree_command \
  "$probe_teardown_signal_command" wait-for-release \
  "$probe_teardown_signal_root/target.pid" \
  "$probe_teardown_signal_root/child.pid" \
  "$probe_teardown_signal_root/target.release"
make_probe_tree_command \
  "$probe_unrelated_command" wait-for-release \
  "$probe_unrelated_pid_file" \
  "$probe_teardown_signal_root/unrelated-child.pid" \
  "$probe_unrelated_release"
setsid -f -w "$probe_unrelated_command" &
probe_unrelated_waiter_pid=$!
probe_unrelated_ready=false
probe_unrelated_attempt=0
while [ "$probe_unrelated_attempt" -lt 20 ]; do
  if [ -s "$probe_unrelated_pid_file" ]; then
    probe_unrelated_ready=true
    break
  fi
  sleep 1
  probe_unrelated_attempt=$((probe_unrelated_attempt + 1))
done
probe_unrelated_pid=$(cat "$probe_unrelated_pid_file" 2>/dev/null || true)
probe_unrelated_pgid=$(ps -p "$probe_unrelated_pid" -o pgid= 2>/dev/null \
  | awk '{ print $1 }')
run_direct_probe_case probe-teardown-signal "$probe_teardown_signal_command" \
  "$direct_probe_bootstrap" \
  DOTFILES_BOOTSTRAP_TEST_PROBE_AUDIT_FILE="$probe_teardown_signal_audit" \
  DOTFILES_BOOTSTRAP_TEST_PROBE_SIGNAL_AT=teardown
probe_teardown_signal_pass=true
[ "$probe_unrelated_ready" = true ] || probe_teardown_signal_pass=false
[ "$run_status" -eq 143 ] || probe_teardown_signal_pass=false
test_process_is_matching "$probe_unrelated_pid" "$probe_unrelated_command" \
  || probe_teardown_signal_pass=false
grep -Fqx 'teardown-signal|TERM' "$probe_teardown_signal_audit" \
  2>/dev/null || probe_teardown_signal_pass=false
if grep -Fqx "group-term|$probe_unrelated_pgid" \
  "$probe_teardown_signal_audit" 2>/dev/null \
  || grep -Fqx "group-kill|$probe_unrelated_pgid" \
    "$probe_teardown_signal_audit" 2>/dev/null; then
  probe_teardown_signal_pass=false
fi
: >"$probe_unrelated_release"
set +e
wait "$probe_unrelated_waiter_pid" >/dev/null 2>&1
set -e
if [ "$probe_teardown_signal_pass" = true ]; then
  pass 'signal during teardown does not recurse or signal an unrelated PGID'
else
  fail 'signal during teardown does not recurse or signal an unrelated PGID'
fi

probe_lost_anchor_root=$test_tmp/probe-lost-anchor
probe_lost_anchor_command=$probe_lost_anchor_root/probe-target
probe_lost_anchor_release=$probe_lost_anchor_root/target.release
probe_lost_anchor_audit=$probe_lost_anchor_root/audit
probe_lost_anchor_pid_file=$probe_lost_anchor_root/target.pid
mkdir -p "$probe_lost_anchor_root"
make_probe_tree_command \
  "$probe_lost_anchor_command" wait-for-release \
  "$probe_lost_anchor_pid_file" \
  "$probe_lost_anchor_root/child.pid" \
  "$probe_lost_anchor_release"
run_direct_probe_case probe-lost-anchor "$probe_lost_anchor_command" \
  "$direct_probe_bootstrap" \
  DOTFILES_BOOTSTRAP_TEST_PROBE_AUDIT_FILE="$probe_lost_anchor_audit" \
  DOTFILES_BOOTSTRAP_TEST_PROBE_LOSE_ANCHOR_BEFORE_KILL=1 \
  DOTFILES_BOOTSTRAP_TEST_PROBE_LOSS_RELEASE_FILE="$probe_lost_anchor_release"
probe_lost_anchor_pass=true
[ "$run_status" -eq 42 ] || probe_lost_anchor_pass=false
grep -Fq 'bootstrap: probe anchor disappeared before forced group cleanup' \
  "$direct_probe_output" || probe_lost_anchor_pass=false
if grep -Eq '^group-kill\|' "$probe_lost_anchor_audit" 2>/dev/null; then
  probe_lost_anchor_pass=false
fi
probe_lost_anchor_pid=$(cat "$probe_lost_anchor_pid_file" 2>/dev/null || true)
case "$probe_lost_anchor_pid" in
  ''|*[!0-9]*) probe_lost_anchor_pass=false ;;
  *)
    probe_lost_anchor_attempt=0
    while [ "$probe_lost_anchor_attempt" -lt 5 ] \
      && test_process_is_matching \
        "$probe_lost_anchor_pid" "$probe_lost_anchor_command"
    do
      sleep 1
      probe_lost_anchor_attempt=$((probe_lost_anchor_attempt + 1))
    done
    if test_process_is_matching \
      "$probe_lost_anchor_pid" "$probe_lost_anchor_command"; then
      probe_lost_anchor_pass=false
      kill_matching_test_process \
        "$probe_lost_anchor_pid" "$probe_lost_anchor_command"
    fi
    ;;
esac
if find "$direct_probe_tmp" -mindepth 1 -maxdepth 1 \
  -name 'dotfiles-bootstrap.*' -print -quit | grep -q .; then
  probe_lost_anchor_pass=false
fi
if [ "$probe_lost_anchor_pass" = true ]; then
  pass 'lost probe anchor fails closed before group KILL'
else
  fail 'lost probe anchor fails closed before group KILL'
fi

probe_signal_root=$test_tmp/stdio-probe-signal
probe_signal_bin=$probe_signal_root/bin
probe_signal_home=$probe_signal_root/home
probe_signal_state=$probe_signal_root/state
probe_signal_tmp=$probe_signal_root/tmp
probe_signal_pid_file=$probe_signal_root/probe.pid
probe_signal_ready_file=$probe_signal_root/probe.ready
probe_signal_deadline_file=$probe_signal_root/watchdog-fired
mkdir -p \
  "$probe_signal_home" \
  "$probe_signal_state" \
  "$probe_signal_tmp"
prepare_satisfaction_commands "$probe_signal_bin" \
  22.0.0 10.0.0 5.6.0 wait 3.19.1 wait 1.1.411 1.24.0 0.11.6
make_term_ignoring_stdio_command \
  "$probe_signal_bin/vscode-json-language-server" \
  "$probe_signal_pid_file" \
  "$probe_signal_ready_file"
set +e
env \
  PATH="$probe_signal_bin:$test_utilities_bin" \
  TMPDIR="$probe_signal_tmp" \
  HOME="$probe_signal_home" \
  XDG_STATE_HOME="$probe_signal_state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=apt \
  DOTFILES_BOOTSTRAP_TEST_APT_GHOSTTY_OFFICIAL=1 \
  DOTFILES_BOOTSTRAP_TEST_STOP_AFTER_PACKAGES=1 \
  "$bootstrap" --apply \
  >"$probe_signal_root/output" 2>&1 &
probe_signal_bootstrap_pid=$!
set -e
probe_signal_ready=false
probe_signal_attempt=0
while [ "$probe_signal_attempt" -lt 5 ]; do
  if [ -s "$probe_signal_ready_file" ]; then
    probe_signal_ready=true
    break
  fi
  sleep 1
  probe_signal_attempt=$((probe_signal_attempt + 1))
done
probe_signal_pass=true
probe_signal_status=not-run
probe_signal_server_command=
if [ "$probe_signal_ready" != true ]; then
  probe_signal_pass=false
  kill_matching_test_process "$probe_signal_bootstrap_pid" "$bootstrap"
  set +e
  wait "$probe_signal_bootstrap_pid" >/dev/null 2>&1
  set -e
else
  probe_signal_server_pid=$(cat "$probe_signal_pid_file")
  case "$probe_signal_server_pid" in
    ''|*[!0-9]*)
      probe_signal_pass=false
      kill_matching_test_process "$probe_signal_bootstrap_pid" "$bootstrap"
      set +e
      wait "$probe_signal_bootstrap_pid" >/dev/null 2>&1
      set -e
      ;;
    *)
      (
        probe_watchdog_sleep_pid=
        trap '[ -z "$probe_watchdog_sleep_pid" ] || kill "$probe_watchdog_sleep_pid" >/dev/null 2>&1; exit 0' HUP INT TERM
        sleep 5 &
        probe_watchdog_sleep_pid=$!
        wait "$probe_watchdog_sleep_pid" || exit 0
        : >"$probe_signal_deadline_file"
        kill_matching_test_process \
          "$probe_signal_server_pid" \
          "$probe_signal_bin/vscode-json-language-server"
        sleep 2 &
        probe_watchdog_sleep_pid=$!
        wait "$probe_watchdog_sleep_pid" || exit 0
        kill_matching_test_process "$probe_signal_bootstrap_pid" "$bootstrap"
      ) &
      probe_signal_watchdog_pid=$!
      set +e
      wait "$probe_signal_bootstrap_pid"
      probe_signal_status=$?
      kill "$probe_signal_watchdog_pid" >/dev/null 2>&1
      wait "$probe_signal_watchdog_pid" >/dev/null 2>&1
      set -e
      [ "$probe_signal_status" -eq 143 ] || probe_signal_pass=false
      [ ! -e "$probe_signal_deadline_file" ] || probe_signal_pass=false
      probe_signal_server_command=$(
        ps -p "$probe_signal_server_pid" -o command= 2>/dev/null || true
      )
      case "$probe_signal_server_command" in
        *"$probe_signal_bin/vscode-json-language-server"*)
          probe_signal_pass=false
          kill_matching_test_process \
            "$probe_signal_server_pid" \
            "$probe_signal_bin/vscode-json-language-server"
          ;;
      esac
      grep -Fq 'received TERM; stopping safely' "$probe_signal_root/output" \
        || probe_signal_pass=false
      if find "$probe_signal_tmp" -mindepth 1 -maxdepth 1 \
        -name 'dotfiles-bootstrap.*' -print -quit \
        | grep -q .; then
        probe_signal_pass=false
      fi
      ;;
  esac
fi
if [ "$probe_signal_pass" = true ]; then
  pass 'termination force-stops a TERM-ignoring stdio probe and removes probe state'
else
  fail 'termination force-stops a TERM-ignoring stdio probe and removes probe state'
  printf '  stdio probe signal status: %s\n' "$probe_signal_status" >&2
  if [ -e "$probe_signal_deadline_file" ]; then
    printf '%s\n' '  stdio probe watchdog: fired' >&2
  else
    printf '%s\n' '  stdio probe watchdog: not fired' >&2
  fi
  printf '  stdio probe remaining command: %s\n' \
    "${probe_signal_server_command:-none}" >&2
  sed 's/^/  stdio probe signal output: /' \
    "$probe_signal_root/output" >&2
fi

probe_race_root=$test_tmp/stdio-probe-spawn-race
probe_race_harness=$probe_race_root/harness
probe_race_bootstrap=$probe_race_harness/bootstrap
probe_race_bin=$probe_race_root/bin
probe_race_home=$probe_race_root/home
probe_race_state=$probe_race_root/state
probe_race_tmp=$probe_race_root/tmp
probe_race_pid_file=$probe_race_root/probe.pid
probe_race_deadline_file=$probe_race_root/watchdog-fired
mkdir -p \
  "$probe_race_harness" \
  "$probe_race_home" \
  "$probe_race_state" \
  "$probe_race_tmp"
cp -R "$dotfiles_dir/manifests" "$probe_race_harness/manifests"
make_probe_spawn_signal_bootstrap "$bootstrap" "$probe_race_bootstrap"
prepare_satisfaction_commands "$probe_race_bin" \
  22.0.0 10.0.0 5.6.0 wait 3.19.1 wait 1.1.411 1.24.0 0.11.6
set +e
env \
  PATH="$probe_race_bin:$test_utilities_bin" \
  TMPDIR="$probe_race_tmp" \
  HOME="$probe_race_home" \
  XDG_STATE_HOME="$probe_race_state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=apt \
  DOTFILES_BOOTSTRAP_TEST_APT_GHOSTTY_OFFICIAL=1 \
  DOTFILES_BOOTSTRAP_TEST_STOP_AFTER_PACKAGES=1 \
  DOTFILES_BOOTSTRAP_TEST_PROBE_RACE_PID_FILE="$probe_race_pid_file" \
  "$probe_race_bootstrap" --apply \
  >"$probe_race_root/output" 2>&1 &
probe_race_bootstrap_pid=$!
set -e
(
  probe_race_watchdog_sleep_pid=
  trap '[ -z "$probe_race_watchdog_sleep_pid" ] || kill "$probe_race_watchdog_sleep_pid" >/dev/null 2>&1; exit 0' HUP INT TERM
  sleep 8 &
  probe_race_watchdog_sleep_pid=$!
  wait "$probe_race_watchdog_sleep_pid" || exit 0
  : >"$probe_race_deadline_file"
  probe_race_watchdog_child_pid=$(cat "$probe_race_pid_file" 2>/dev/null || true)
  case "$probe_race_watchdog_child_pid" in
    ''|*[!0-9]*)
      ;;
    *)
      kill_matching_test_process \
        "$probe_race_watchdog_child_pid" "$probe_race_bootstrap"
      kill_matching_test_process \
        "$probe_race_watchdog_child_pid" \
        "$probe_race_bin/vscode-json-language-server"
      ;;
  esac
  kill_matching_test_process "$probe_race_bootstrap_pid" "$probe_race_bootstrap"
) &
probe_race_watchdog_pid=$!
set +e
wait "$probe_race_bootstrap_pid"
probe_race_status=$?
kill "$probe_race_watchdog_pid" >/dev/null 2>&1
wait "$probe_race_watchdog_pid" >/dev/null 2>&1
set -e
probe_race_pass=true
probe_race_pid=$(cat "$probe_race_pid_file" 2>/dev/null || true)
probe_race_command=
case "$probe_race_pid" in
  ''|*[!0-9]*)
    probe_race_pass=false
    ;;
  *)
    probe_race_command=$(ps -p "$probe_race_pid" -o command= 2>/dev/null || true)
    if kill -0 "$probe_race_pid" >/dev/null 2>&1; then
      probe_race_pass=false
      kill_matching_test_process "$probe_race_pid" "$probe_race_bootstrap"
      kill_matching_test_process \
        "$probe_race_pid" "$probe_race_bin/vscode-json-language-server"
    fi
    ;;
esac
[ "$probe_race_status" -eq 143 ] || probe_race_pass=false
[ ! -e "$probe_race_deadline_file" ] || probe_race_pass=false
grep -Fq 'received TERM; stopping safely' "$probe_race_root/output" \
  || probe_race_pass=false
if find "$probe_race_tmp" -mindepth 1 -maxdepth 1 \
  -name 'dotfiles-bootstrap.*' -print -quit \
  | grep -q .; then
  probe_race_pass=false
fi
if [ "$probe_race_pass" = true ]; then
  pass 'termination during stdio probe spawn registers and removes the exact child'
else
  fail 'termination during stdio probe spawn registers and removes the exact child'
  printf '  stdio probe race status: %s\n' "$probe_race_status" >&2
  printf '  stdio probe race PID: %s\n' "${probe_race_pid:-none}" >&2
  printf '  stdio probe race command: %s\n' \
    "${probe_race_command:-none}" >&2
  if [ -e "$probe_race_deadline_file" ]; then
    printf '%s\n' '  stdio probe race watchdog: fired' >&2
  else
    printf '%s\n' '  stdio probe race watchdog: not fired' >&2
  fi
  sed 's/^/  stdio probe race output: /' "$probe_race_root/output" >&2
fi

probe_temp_root=$test_tmp/stdio-probe-temp-race
probe_temp_harness=$probe_temp_root/harness
probe_temp_bootstrap=$probe_temp_harness/bootstrap
probe_temp_bin=$probe_temp_root/bin
probe_temp_home=$probe_temp_root/home
probe_temp_state=$probe_temp_root/state
probe_temp_tmp=$probe_temp_root/tmp
probe_temp_path_file=$probe_temp_root/probe-temp.path
mkdir -p \
  "$probe_temp_harness" \
  "$probe_temp_home" \
  "$probe_temp_state" \
  "$probe_temp_tmp"
cp -R "$dotfiles_dir/manifests" "$probe_temp_harness/manifests"
make_probe_temp_signal_bootstrap "$bootstrap" "$probe_temp_bootstrap"
prepare_satisfaction_commands "$probe_temp_bin" \
  22.0.0 10.0.0 5.6.0 wait 3.19.1 wait 1.1.411 1.24.0 0.11.6
run_capture "$probe_temp_root/output" env \
  PATH="$probe_temp_bin:$test_utilities_bin" \
  TMPDIR="$probe_temp_tmp" \
  HOME="$probe_temp_home" \
  XDG_STATE_HOME="$probe_temp_state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=apt \
  DOTFILES_BOOTSTRAP_TEST_APT_GHOSTTY_OFFICIAL=1 \
  DOTFILES_BOOTSTRAP_TEST_STOP_AFTER_PACKAGES=1 \
  DOTFILES_BOOTSTRAP_TEST_PROBE_TEMP_RACE_PATH_FILE="$probe_temp_path_file" \
  "$probe_temp_bootstrap" --apply
probe_temp_status=$run_status
probe_temp_pass=true
probe_temp_path=$(cat "$probe_temp_path_file" 2>/dev/null || true)
[ "$probe_temp_status" -eq 143 ] || probe_temp_pass=false
grep -Fq 'received TERM; stopping safely' "$probe_temp_root/output" \
  || probe_temp_pass=false
case "$probe_temp_path" in
  "$probe_temp_tmp"/dotfiles-bootstrap.*)
    path_exists_for_test "$probe_temp_path" && probe_temp_pass=false
    ;;
  *)
    probe_temp_pass=false
    ;;
esac
if find "$probe_temp_tmp" -mindepth 1 -maxdepth 1 \
  -name 'dotfiles-bootstrap.*' -print -quit \
  | grep -q .; then
  probe_temp_pass=false
fi
if [ "$probe_temp_pass" = true ]; then
  pass 'termination during probe temp registration removes the exact temporary root'
else
  fail 'termination during probe temp registration removes the exact temporary root'
  printf '  stdio probe temp status: %s\n' "$probe_temp_status" >&2
  printf '  stdio probe temp path: %s\n' "${probe_temp_path:-none}" >&2
  sed 's/^/  stdio probe temp output: /' "$probe_temp_root/output" >&2
fi

probe_repeat_root=$test_tmp/stdio-probe-repeat-signal
probe_repeat_harness=$probe_repeat_root/harness
probe_repeat_bootstrap=$probe_repeat_harness/bootstrap
probe_repeat_bin=$probe_repeat_root/bin
probe_repeat_home=$probe_repeat_root/home
probe_repeat_state=$probe_repeat_root/state
probe_repeat_tmp=$probe_repeat_root/tmp
probe_repeat_pid_file=$probe_repeat_root/probe.pid
probe_repeat_ready_file=$probe_repeat_root/probe.ready
probe_repeat_deadline_file=$probe_repeat_root/watchdog-fired
mkdir -p \
  "$probe_repeat_harness" \
  "$probe_repeat_home" \
  "$probe_repeat_state" \
  "$probe_repeat_tmp"
cp -R "$dotfiles_dir/manifests" "$probe_repeat_harness/manifests"
make_exit_repeat_signal_bootstrap "$bootstrap" "$probe_repeat_bootstrap"
prepare_satisfaction_commands "$probe_repeat_bin" \
  22.0.0 10.0.0 5.6.0 wait 3.19.1 wait 1.1.411 1.24.0 0.11.6
make_term_ignoring_stdio_command \
  "$probe_repeat_bin/vscode-json-language-server" \
  "$probe_repeat_pid_file" \
  "$probe_repeat_ready_file"
set +e
env \
  PATH="$probe_repeat_bin:$test_utilities_bin" \
  TMPDIR="$probe_repeat_tmp" \
  HOME="$probe_repeat_home" \
  XDG_STATE_HOME="$probe_repeat_state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=apt \
  DOTFILES_BOOTSTRAP_TEST_APT_GHOSTTY_OFFICIAL=1 \
  DOTFILES_BOOTSTRAP_TEST_STOP_AFTER_PACKAGES=1 \
  "$probe_repeat_bootstrap" --apply \
  >"$probe_repeat_root/output" 2>&1 &
probe_repeat_bootstrap_pid=$!
set -e
probe_repeat_ready=false
probe_repeat_attempt=0
while [ "$probe_repeat_attempt" -lt 5 ]; do
  if [ -s "$probe_repeat_ready_file" ]; then
    probe_repeat_ready=true
    break
  fi
  sleep 1
  probe_repeat_attempt=$((probe_repeat_attempt + 1))
done
probe_repeat_pass=true
probe_repeat_status=not-run
probe_repeat_server_command=
if [ "$probe_repeat_ready" != true ]; then
  probe_repeat_pass=false
  kill_matching_test_process \
    "$probe_repeat_bootstrap_pid" "$probe_repeat_bootstrap"
  set +e
  wait "$probe_repeat_bootstrap_pid" >/dev/null 2>&1
  set -e
else
  probe_repeat_server_pid=$(cat "$probe_repeat_pid_file")
  case "$probe_repeat_server_pid" in
    ''|*[!0-9]*)
      probe_repeat_pass=false
      kill_matching_test_process \
        "$probe_repeat_bootstrap_pid" "$probe_repeat_bootstrap"
      set +e
      wait "$probe_repeat_bootstrap_pid" >/dev/null 2>&1
      set -e
      ;;
    *)
      (
        probe_repeat_watchdog_sleep_pid=
        trap '[ -z "$probe_repeat_watchdog_sleep_pid" ] || kill "$probe_repeat_watchdog_sleep_pid" >/dev/null 2>&1; exit 0' HUP INT TERM
        sleep 5 &
        probe_repeat_watchdog_sleep_pid=$!
        wait "$probe_repeat_watchdog_sleep_pid" || exit 0
        : >"$probe_repeat_deadline_file"
        kill_matching_test_process \
          "$probe_repeat_server_pid" \
          "$probe_repeat_bin/vscode-json-language-server"
        sleep 2 &
        probe_repeat_watchdog_sleep_pid=$!
        wait "$probe_repeat_watchdog_sleep_pid" || exit 0
        kill_matching_test_process \
          "$probe_repeat_bootstrap_pid" "$probe_repeat_bootstrap"
      ) &
      probe_repeat_watchdog_pid=$!
      set +e
      wait "$probe_repeat_bootstrap_pid"
      probe_repeat_status=$?
      kill "$probe_repeat_watchdog_pid" >/dev/null 2>&1
      wait "$probe_repeat_watchdog_pid" >/dev/null 2>&1
      set -e
      [ "$probe_repeat_status" -eq 143 ] || probe_repeat_pass=false
      [ ! -e "$probe_repeat_deadline_file" ] || probe_repeat_pass=false
      probe_repeat_server_command=$(
        ps -p "$probe_repeat_server_pid" -o command= 2>/dev/null || true
      )
      case "$probe_repeat_server_command" in
        *"$probe_repeat_bin/vscode-json-language-server"*)
          probe_repeat_pass=false
          kill_matching_test_process \
            "$probe_repeat_server_pid" \
            "$probe_repeat_bin/vscode-json-language-server"
          ;;
      esac
      [ "$(grep -Fc 'received TERM; stopping safely' \
        "$probe_repeat_root/output")" -eq 1 ] \
        || probe_repeat_pass=false
      if find "$probe_repeat_tmp" -mindepth 1 -maxdepth 1 \
        -name 'dotfiles-bootstrap.*' -print -quit \
        | grep -q .; then
        probe_repeat_pass=false
      fi
      ;;
  esac
fi
if [ "$probe_repeat_pass" = true ]; then
  pass 'repeat termination during EXIT cleanup preserves status and removes probe state'
else
  fail 'repeat termination during EXIT cleanup preserves status and removes probe state'
  printf '  repeat signal status: %s\n' "$probe_repeat_status" >&2
  if [ -e "$probe_repeat_deadline_file" ]; then
    printf '%s\n' '  repeat signal watchdog: fired' >&2
  else
    printf '%s\n' '  repeat signal watchdog: not fired' >&2
  fi
  printf '  repeat signal remaining command: %s\n' \
    "${probe_repeat_server_command:-none}" >&2
  sed 's/^/  repeat signal output: /' "$probe_repeat_root/output" >&2
fi

collision_home=$test_tmp/lsp-collision-home
collision_log=$test_tmp/lsp-collision.commands
mkdir -p "$collision_home/.local/bin"
printf '%s\n' 'pre-existing command' >"$collision_home/.local/bin/bash-language-server"
run_capture "$test_tmp/lsp-collision.output" env \
  HOME="$collision_home" \
  XDG_STATE_HOME="$test_tmp/lsp-collision-state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=apt \
  DOTFILES_BOOTSTRAP_TEST_ALL_PACKAGES_MISSING=1 \
  DOTFILES_BOOTSTRAP_TEST_SATISFIED_TOOLS= \
  DOTFILES_BOOTSTRAP_TEST_APT_GHOSTTY_OFFICIAL=1 \
  DOTFILES_BOOTSTRAP_TEST_STOP_AFTER_PACKAGES=1 \
  DOTFILES_BOOTSTRAP_TEST_COMMAND_LOG="$collision_log" \
  "$bootstrap" --apply
collision_output=$(cat "$test_tmp/lsp-collision.output")
if [ "$run_status" -ne 0 ] \
  && printf '%s\n' "$collision_output" \
    | grep -Fq "$collision_home/.local/bin/bash-language-server"; then
  pass 'managed target collision reports the exact occupied path'
else
  fail 'managed target collision reports the exact occupied path'
fi
if [ ! -e "$collision_log" ]; then
  pass 'managed target collision precedes apt downloads direct installs and npm'
else
  fail 'managed target collision precedes apt downloads direct installs and npm'
fi

managed_fixture_root=$test_tmp/managed-harness
managed_fixture_download=$test_tmp/managed-downloads
managed_fixture_source=$test_tmp/managed-archive-sources
mkdir -p \
  "$managed_fixture_root" \
  "$managed_fixture_download" \
  "$managed_fixture_source/x86_64" \
  "$managed_fixture_source/arm64"
cp "$bootstrap" "$managed_fixture_root/bootstrap"
cp -R "$dotfiles_dir/manifests" "$managed_fixture_root/manifests"

create_fake_node_archive \
  "$managed_fixture_download" "$managed_fixture_source/x86_64" x86_64
fake_node_x86_sha=$fake_node_sha
create_fake_lua_archive \
  "$managed_fixture_download" "$managed_fixture_source/x86_64" x86_64
fake_lua_x86_sha=$fake_lua_sha
create_fake_taplo_asset \
  "$managed_fixture_download" "$managed_fixture_source/x86_64" x86_64
fake_taplo_x86_sha=$fake_taplo_sha
create_fake_node_archive \
  "$managed_fixture_download" "$managed_fixture_source/arm64" arm64
fake_node_arm_sha=$fake_node_sha
create_fake_lua_archive \
  "$managed_fixture_download" "$managed_fixture_source/arm64" arm64
fake_lua_arm_sha=$fake_lua_sha
create_fake_taplo_asset \
  "$managed_fixture_download" "$managed_fixture_source/arm64" arm64
fake_taplo_arm_sha=$fake_taplo_sha

awk -F '\t' -v OFS='\t' \
  -v node_x86_sha="$fake_node_x86_sha" \
  -v node_arm_sha="$fake_node_arm_sha" \
  -v lua_x86_sha="$fake_lua_x86_sha" \
  -v lua_arm_sha="$fake_lua_arm_sha" \
  -v taplo_x86_sha="$fake_taplo_x86_sha" \
  -v taplo_arm_sha="$fake_taplo_arm_sha" '
  $1 == "node" && $3 == "x86_64" {
    $6 = "https://fixtures.invalid/node-v24.19.0-linux-x64.tar.xz"
    $7 = node_x86_sha
  }
  $1 == "node" && $3 == "arm64" {
    $6 = "https://fixtures.invalid/node-v24.19.0-linux-arm64.tar.xz"
    $7 = node_arm_sha
  }
  $1 == "lua-language-server" && $3 == "x86_64" {
    $6 = "https://fixtures.invalid/lua-language-server-3.19.1-linux-x64.tar.gz"
    $7 = lua_x86_sha
  }
  $1 == "lua-language-server" && $3 == "arm64" {
    $6 = "https://fixtures.invalid/lua-language-server-3.19.1-linux-arm64.tar.gz"
    $7 = lua_arm_sha
  }
  $1 == "taplo" && $3 == "x86_64" {
    $6 = "https://fixtures.invalid/taplo-linux-x86_64.gz"
    $7 = taplo_x86_sha
  }
  $1 == "taplo" && $3 == "arm64" {
    $6 = "https://fixtures.invalid/taplo-linux-aarch64.gz"
    $7 = taplo_arm_sha
  }
  { print }
' "$managed_fixture_root/manifests/packages-direct.tsv" \
  >"$managed_fixture_root/manifests/packages-direct.tsv.new"
mv "$managed_fixture_root/manifests/packages-direct.tsv.new" \
  "$managed_fixture_root/manifests/packages-direct.tsv"

managed_scope_root=$test_tmp/managed-tool-dry-run
managed_scope_home=$managed_scope_root/home
managed_scope_tmp=$managed_scope_root/tmp
managed_scope_output=$managed_scope_root/output
managed_scope_probe_pid=$managed_scope_root/taplo-probe.pid
mkdir -p "$managed_scope_home" "$managed_scope_tmp"
managed_scope_roots_before=$(managed_probe_root_set "$managed_scope_tmp")
managed_scope_processes_before=$(managed_probe_process_set "$managed_scope_tmp")
run_capture "$managed_scope_output" env \
  PATH="$managed_scope_home/.local/bin:$test_utilities_bin" \
  TMPDIR="$managed_scope_tmp" \
  HOME="$managed_scope_home" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
  DOTFILES_BOOTSTRAP_TEST_ARCH=x86_64 \
  DOTFILES_BOOTSTRAP_TEST_TAPLO_PROBE_PID_FILE="$managed_scope_probe_pid" \
  "$managed_fixture_root/bootstrap" --managed-tool taplo
managed_scope_text=$(cat "$managed_scope_output")
if [ "$run_status" -eq 0 ] \
  && printf '%s\n' "$managed_scope_text" | grep -Fq 'Managed tool: taplo' \
  && printf '%s\n' "$managed_scope_text" | grep -Fq 'State: missing' \
  && printf '%s\n' "$managed_scope_text" | grep -Fq 'Action: install' \
  && [ ! -e "$managed_scope_home/.local" ] \
  && managed_probe_state_matches \
    "$managed_scope_tmp" \
    "$managed_scope_roots_before" \
    "$managed_scope_processes_before" \
    "$managed_scope_probe_pid"; then
  pass 'managed Taplo dry-run is accepted without a window-manager and leaves no persistent or probe state'
else
  fail 'managed Taplo dry-run is accepted without a window-manager and leaves no persistent or probe state'
fi

managed_apply_root=$test_tmp/managed-tool-apply
managed_apply_home=$managed_apply_root/home
managed_apply_tmp=$managed_apply_root/tmp
managed_apply_output=$managed_apply_root/output
managed_apply_log=$managed_apply_root/commands
managed_apply_probe_pid=$managed_apply_root/taplo-probe.pid
mkdir -p "$managed_apply_home" "$managed_apply_tmp"
managed_apply_roots_before=$(managed_probe_root_set "$managed_apply_tmp")
managed_apply_processes_before=$(managed_probe_process_set "$managed_apply_tmp")
run_capture "$managed_apply_output" env \
  PATH="$managed_apply_home/.local/bin:$test_utilities_bin" \
  TMPDIR="$managed_apply_tmp" \
  HOME="$managed_apply_home" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
  DOTFILES_BOOTSTRAP_TEST_ARCH=x86_64 \
  DOTFILES_BOOTSTRAP_TEST_REAL_MANAGED_INSTALL=1 \
  DOTFILES_BOOTSTRAP_TEST_DOWNLOAD_ROOT="$managed_fixture_download" \
  DOTFILES_BOOTSTRAP_TEST_COMMAND_LOG="$managed_apply_log" \
  DOTFILES_BOOTSTRAP_TEST_TAPLO_PROBE_PID_FILE="$managed_apply_probe_pid" \
  "$managed_fixture_root/bootstrap" --apply --managed-tool taplo
managed_apply_text=$(cat "$managed_apply_output")
managed_apply_target=$managed_apply_home/.local/opt/taplo-0.10.0-x86_64
managed_apply_link=$managed_apply_home/.local/bin/taplo
if [ "$run_status" -eq 0 ] \
  && printf '%s\n' "$managed_apply_text" | grep -Fqx 'Mode: apply' \
  && printf '%s\n' "$managed_apply_text" | grep -Fqx 'State: missing' \
  && printf '%s\n' "$managed_apply_text" | grep -Fqx 'Action: install' \
  && [ -x "$managed_apply_target/taplo" ] \
  && [ ! -L "$managed_apply_target/taplo" ] \
  && [ "$(readlink "$managed_apply_link")" = "$managed_apply_target/taplo" ] \
  && [ "$("$managed_apply_link" --version)" = 'taplo 0.10.0' ] \
  && [ -s "$managed_apply_probe_pid" ] \
  && managed_probe_state_matches \
    "$managed_apply_tmp" \
    "$managed_apply_roots_before" \
    "$managed_apply_processes_before" \
    "$managed_apply_probe_pid"; then
  pass 'managed Taplo apply publishes only the verified Arch asset and leaves no probe residue'
else
  fail 'managed Taplo apply publishes only the verified Arch asset and leaves no probe residue'
fi

managed_apply_entries=$(find "$managed_apply_home" -mindepth 1 -printf '%P\n' | LC_ALL=C sort)
managed_apply_expected_entries=$(printf '%s\n' \
  '.local' '.local/bin' '.local/bin/taplo' '.local/opt' \
  '.local/opt/taplo-0.10.0-x86_64' '.local/opt/taplo-0.10.0-x86_64/taplo' \
  '.local/state' '.local/state/dotfiles-ownership')
if [ "$managed_apply_entries" = "$managed_apply_expected_entries" ] \
  && [ "$(stat -c '%a' "$managed_apply_target/taplo")" = 755 ] \
  && ! grep -Eq 'pacman|apt-get|brew|npm|uv|git|systemctl|launchctl' \
    "$managed_apply_log"; then
  pass 'managed Taplo apply creates exactly its permitted paths and excludes unrelated commands'
else
  fail 'managed Taplo apply creates exactly its permitted paths and excludes unrelated commands'
fi

# Managed-scope parser checks include explicit empty values and both flag orders.
prepare_managed_scope_case parser
assert_managed_scope_readonly 2 '--managed-tool requires a tool name' \
  'managed scope rejects a missing tool' --managed-tool
assert_managed_scope_readonly 2 '--managed-tool may be specified only once' \
  'managed scope rejects duplicate selection' --managed-tool taplo --managed-tool taplo
assert_managed_scope_readonly 2 '--managed-tool may be specified only once' \
  'managed scope rejects duplicate empty selection' --managed-tool '' --managed-tool taplo
assert_managed_scope_readonly 2 'unsupported managed tool:' \
  'managed scope rejects an empty tool' --managed-tool ''
assert_managed_scope_readonly 2 'unsupported managed tool: unknown' \
  'managed scope rejects an unknown tool' --managed-tool unknown
assert_managed_scope_readonly 2 'unknown option: unexpected' \
  'managed scope rejects positional arguments' --managed-tool taplo unexpected
assert_managed_scope_readonly 2 'positional arguments are not supported' \
  'managed scope rejects arguments after the separator' --managed-tool taplo -- unexpected
for scope_flag in window-manager repo ref rollback allow-community-packages; do
  case $scope_flag in
    window-manager) set -- --window-manager none ;;
    repo) set -- --repo https://example.invalid/repo ;;
    ref) set -- --ref main ;;
    rollback) set -- --rollback latest ;;
    allow-community-packages) set -- --allow-community-packages ;;
  esac
  assert_managed_scope_readonly 2 "--managed-tool cannot be combined with --$scope_flag" \
    "managed scope rejects --$scope_flag after selection" --managed-tool taplo "$@"
  assert_managed_scope_readonly 2 "--managed-tool cannot be combined with --$scope_flag" \
    "managed scope rejects --$scope_flag before selection" "$@" --managed-tool taplo
done
assert_managed_scope_readonly 2 '--managed-tool cannot be combined with --window-manager' \
  'managed scope rejects an explicitly empty window manager' --managed-tool taplo --window-manager ''

for scope_case in external-satisfied external-newer managed-satisfied external-old \
  external-prerelease external-malformed external-empty external-missing-lsp \
  external-hanging-lsp external-failing-version external-hanging-version \
  target-only link-only target-file target-symlink link-file wrong-link \
  hidden-managed wrong-version missing-lsp extra-file executable-symlink \
  not-executable parent-file parent-symlink missing-path
do
  prepare_managed_scope_case "$scope_case"
  scope_expected=1
  scope_text='conflicting managed Taplo state'
  scope_expect_probe=false
  case $scope_case in
    external-*)
      scope_version='taplo 0.10.0'
      scope_lsp=success
      scope_text='existing Taplo command is unsatisfactory'
      case $scope_case in
        external-satisfied) scope_expected=0; scope_text='Action: skip external'; scope_expect_probe=true ;;
        external-newer) scope_version='taplo 0.11.0'; scope_expected=0; scope_text='Action: skip external'; scope_expect_probe=true ;;
        external-old) scope_version='taplo 0.9.3' ;;
        external-prerelease) scope_version='taplo 0.10.0-rc.1' ;;
        external-malformed) scope_version='unexpected taplo 0.10.0' ;;
        external-empty) scope_version= ;;
        external-missing-lsp) scope_lsp=fail; scope_expect_probe=true ;;
        external-hanging-lsp) scope_lsp=hang; scope_expect_probe=true ;;
      esac
      make_taplo_command "$scope_bin/taplo" "$scope_version" "$scope_lsp"
      case $scope_case in
        external-failing-version)
          printf '%s\n' '#!/bin/sh' 'printf "%s\n" "taplo 0.10.0"; exit 7' >"$scope_bin/taplo"
          ;;
        external-hanging-version)
          # shellcheck disable=SC2016 # Expanded by the generated executable.
          printf '%s\n' '#!/bin/sh' \
            'printf "%s\n" "$$" >"$DOTFILES_BOOTSTRAP_TEST_TAPLO_PROBE_PID_FILE"' \
            'exec sleep 30' >"$scope_bin/taplo"
          scope_expect_probe=true
          ;;
      esac
      ;;
    parent-file) printf '%s\n' sentinel >"$scope_home/.local"; scope_text='parent must be a real directory' ;;
    parent-symlink) mkdir "$scope_home/elsewhere"; ln -s "$scope_home/elsewhere" "$scope_home/.local"; scope_text='parent must be a real directory' ;;
    missing-path) scope_path=$scope_bin:$test_utilities_bin; scope_text='activation directory is not present in PATH' ;;
    *)
      make_exact_managed_scope_layout
      case $scope_case in
        managed-satisfied) scope_expected=0; scope_text='Action: skip managed'; scope_expect_probe=true ;;
        target-only) rm "$scope_link" ;;
        link-only) rm -r "$scope_target" ;;
        target-file) rm -r "$scope_target"; printf '%s\n' sentinel >"$scope_target" ;;
        target-symlink) mv "$scope_target" "$scope_target.original"; ln -s "$scope_target.original" "$scope_target" ;;
        link-file) rm "$scope_link"; printf '%s\n' sentinel >"$scope_link" ;;
        wrong-link) rm "$scope_link"; ln -s "$scope_home/missing" "$scope_link" ;;
        hidden-managed) scope_path=$scope_bin:$test_utilities_bin ;;
        wrong-version) make_taplo_command "$scope_target/taplo" 'taplo 0.9.3' success ;;
        missing-lsp) make_taplo_command "$scope_target/taplo" 'taplo 0.10.0' fail; scope_expect_probe=true ;;
        extra-file) printf '%s\n' sentinel >"$scope_target/.unexpected" ;;
        executable-symlink) mv "$scope_target/taplo" "$scope_home/elsewhere"; ln -s "$scope_home/elsewhere" "$scope_target/taplo" ;;
        not-executable) chmod 0644 "$scope_target/taplo" ;;
      esac
      ;;
  esac
  for scope_mode in dry-run apply; do
    set -- --managed-tool taplo
    [ "$scope_mode" != apply ] || set -- --apply "$@"
    scope_mode_text=$scope_text
    case "$scope_mode:$scope_case" in
      apply:parent-file|apply:parent-symlink) scope_mode_text="ownership: unsafe directory: $scope_home/.local" ;;
    esac
    assert_managed_scope_readonly "$scope_expected" "$scope_mode_text" \
      "managed Taplo $scope_case $scope_mode preserves state and cleans probes" "$@"
    if [ "$scope_expect_probe" = true ]; then
      if [ -s "$scope_pid_file" ]; then
        pass "managed Taplo $scope_case $scope_mode exercised the bounded probe"
      else
        fail "managed Taplo $scope_case $scope_mode exercised the bounded probe"
      fi
    fi
  done
done

for scope_case in macos architecture standalone; do
  prepare_managed_scope_case "$scope_case"
  case $scope_case in
    macos) scope_platform=macos; scope_text='supported only on Linux' ;;
    architecture) scope_arch=riscv64; scope_text='unsupported architecture: riscv64' ;;
    standalone) rm -r "$managed_failure_harness/manifests"; scope_text='requires local bootstrap manifests' ;;
  esac
  assert_managed_scope_readonly 1 "$scope_text" \
    "managed Taplo rejects $scope_case before mutation" --apply --managed-tool taplo
done

prepare_managed_scope_case arm64
scope_arch=arm64
run_managed_scope --managed-tool taplo
scope_arm_dry_status=$run_status
run_managed_scope --apply --managed-tool taplo
if [ "$scope_arm_dry_status" -eq 0 ] && [ "$run_status" -eq 0 ] \
  && [ -x "$scope_home/.local/opt/taplo-0.10.0-arm64/taplo" ] \
  && [ ! -e "$scope_target" ] && managed_scope_is_clean; then
  pass 'managed Taplo installs the arm64 asset in its exact target'
else
  fail 'managed Taplo installs the arm64 asset in its exact target'
fi
assert_managed_scope_readonly 0 'Action: skip managed' \
  'managed Taplo repeated dry-run preserves installed identities' --managed-tool taplo
assert_managed_scope_readonly 0 'Action: skip managed' \
  'managed Taplo repeated apply preserves installed identities' --apply --managed-tool taplo

for scope_case in manifest-missing manifest-duplicate manifest-version manifest-format \
  manifest-http manifest-sha manifest-sha-length checksum gzip empty wrong-staged-version \
  missing-staged-lsp hanging-staged-version failing-staged-version publish-directory publish-link
do
  prepare_managed_scope_case "$scope_case"
  scope_asset=$managed_failure_download/taplo-linux-x86_64.gz
  case $scope_case in
    manifest-missing) remove_failure_case_taplo_record; scope_text='missing direct asset' ;;
    manifest-duplicate) duplicate_failure_case_taplo_record; scope_text='malformed direct asset entry' ;;
    manifest-version) set_failure_case_taplo_field 4 0.11.0; scope_text='unexpected managed Taplo version' ;;
    manifest-format) set_failure_case_taplo_field 5 tar.gz; scope_text='unexpected managed Taplo archive format' ;;
    manifest-http) set_failure_case_taplo_field 6 http://fixtures.invalid/taplo.gz; scope_text='must use HTTPS' ;;
    manifest-sha) set_failure_case_taplo_field 7 zzz; scope_text='invalid SHA-256' ;;
    manifest-sha-length) set_failure_case_taplo_field 7 abc; scope_text='invalid SHA-256 length' ;;
    checksum) printf '%s\n' damaged >>"$scope_asset"; scope_text='checksum mismatch' ;;
    gzip) printf '%s\n' 'not gzip' >"$scope_asset"; scope_text='not valid gzip' ;;
    empty) printf '' | gzip >"$scope_asset"; scope_text='did not produce one regular executable' ;;
    wrong-staged-version|missing-staged-lsp|hanging-staged-version|failing-staged-version)
      scope_version='taplo 0.10.0'
      scope_lsp=success
      scope_text='staged Taplo version does not match'
      case $scope_case in
        wrong-staged-version) scope_version='taplo 0.9.3' ;;
        missing-staged-lsp) scope_lsp=fail; scope_text='does not expose lsp stdio' ;;
      esac
      make_taplo_command "$managed_failure_source/taplo" "$scope_version" "$scope_lsp"
      case $scope_case in
        hanging-staged-version)
          # shellcheck disable=SC2016 # Expanded by the generated executable.
          printf '%s\n' '#!/bin/sh' \
            'printf "%s\n" "$$" >"$DOTFILES_BOOTSTRAP_TEST_TAPLO_PROBE_PID_FILE"' \
            'exec sleep 30' >"$managed_failure_source/taplo"
          ;;
        failing-staged-version)
          printf '%s\n' '#!/bin/sh' 'printf "%s\n" "taplo 0.10.0"; exit 7' \
            >"$managed_failure_source/taplo"
          ;;
      esac
      gzip -c "$managed_failure_source/taplo" >"$scope_asset"
      ;;
    publish-directory) scope_publish_failure=taplo-directory; scope_text='forced managed publication failure' ;;
    publish-link) scope_publish_failure=taplo-link; scope_text='forced managed publication failure' ;;
  esac
  case $scope_case in
    gzip|empty|wrong-staged-version|missing-staged-lsp|hanging-staged-version|failing-staged-version)
      set_failure_case_taplo_field 7 "$(file_sha256_for_test "$scope_asset")"
      ;;
  esac
  prepare_managed_scope_snapshot --apply
  scope_tree_before=$(managed_scope_tree)
  run_managed_scope --apply --managed-tool taplo
  if [ "$run_status" -ne 0 ] && grep -Fq "$scope_text" "$scope_output" \
    && [ "$(managed_scope_tree)" = "$scope_tree_before" ] \
    && managed_scope_is_clean; then
    pass "managed Taplo $scope_case failure removes only invocation-created state"
  else
    fail "managed Taplo $scope_case failure removes only invocation-created state"
    sed 's/^/  scoped output: /' "$scope_output" >&2
  fi
done

for scope_phase in before-journal after-journal; do
  for scope_kind in regular directory; do
    prepare_managed_scope_case "replacement-$scope_phase-$scope_kind"
    scope_mutation_phase=$scope_phase
    scope_mutation_kind=$scope_kind
    scope_publish_failure=taplo-link
    run_managed_scope --apply --managed-tool taplo
    case $scope_kind in
      regular) scope_replacement=$(cat "$scope_link" 2>/dev/null || true); scope_expected_replacement='mutated Taplo link bytes' ;;
      directory) scope_replacement=$(cat "$scope_link/sentinel" 2>/dev/null || true); scope_expected_replacement='mutated Taplo link directory' ;;
    esac
    if [ "$run_status" -ne 0 ] && [ "$scope_replacement" = "$scope_expected_replacement" ] \
      && [ ! -e "$scope_target" ] && managed_scope_is_clean \
      && grep -Fq 'cleanup was incomplete' "$scope_output"; then
      pass "managed Taplo preserves the $scope_phase $scope_kind replacement"
    else
      fail "managed Taplo preserves the $scope_phase $scope_kind replacement"
      sed 's/^/  scoped output: /' "$scope_output" >&2
    fi
  done
done

for scope_registration_shell in sh bash; do
for scope_signal in HUP INT TERM; do
  case $scope_signal in
    HUP) scope_signal_status=129 ;;
    INT) scope_signal_status=130 ;;
    TERM) scope_signal_status=143 ;;
  esac
  for scope_signal_at in 1 2; do
    prepare_managed_scope_case "registration-$scope_registration_shell-$scope_signal-$scope_signal_at"
    make_scoped_registration_signal_fixture
    run_managed_scope --apply --managed-tool taplo
    scope_interrupted_path=$(cat "$managed_failure_root/interrupted.path" 2>/dev/null || true)
    if [ "$run_status" -eq "$scope_signal_status" ] \
      && [ -n "$scope_interrupted_path" ] \
      && [ ! -e "$scope_interrupted_path" ] && only_ownership_coordination "$scope_home" \
      && managed_scope_is_clean; then
      pass "managed Taplo $scope_registration_shell $scope_signal registration $scope_signal_at removes its exact root"
    else
      fail "managed Taplo $scope_registration_shell $scope_signal registration $scope_signal_at removes its exact root"
      sed 's/^/  scoped output: /' "$scope_output" >&2
    fi
  done
done
done

for scope_signal in HUP INT TERM; do
  case $scope_signal in
    HUP) scope_signal_status=129 ;;
    INT) scope_signal_status=130 ;;
    TERM) scope_signal_status=143 ;;
  esac
  for scope_phase in before-journal after-journal; do
    prepare_managed_scope_case "publication-$scope_signal-$scope_phase"
    awk -v phase="$scope_phase" -v signal_name="$scope_signal" \
      -v marker="$managed_failure_root/signal.reached" '
      { print }
      $0 == "mutate_managed_link_for_test() {" {
        print "  if [ \"$1\" = \"" phase "\" ]; then"
        print "    printf \"%s\\n\" reached >\"" marker "\""
        print "    kill -" signal_name " \"$$\""
        print "  fi"
        injected += 1
      }
      END { if (injected != 1) exit 1 }
    ' "$scope_bootstrap" >"$scope_bootstrap.new"
    mv "$scope_bootstrap.new" "$scope_bootstrap"
    chmod 0755 "$scope_bootstrap"
    run_managed_scope --apply --managed-tool taplo
    if [ "$run_status" -eq "$scope_signal_status" ] \
      && [ -s "$managed_failure_root/signal.reached" ] \
      && only_ownership_coordination "$scope_home" && managed_scope_is_clean; then
      pass "managed Taplo $scope_signal $scope_phase publication cleans its paths and probes"
    else
      fail "managed Taplo $scope_signal $scope_phase publication cleans its paths and probes"
      sed 's/^/  scoped output: /' "$scope_output" >&2
    fi
  done
  for scope_mode in dry-run apply; do
    prepare_managed_scope_case "probe-$scope_signal-$scope_mode"
    if [ "$scope_mode" = dry-run ]; then
      make_taplo_command "$scope_bin/taplo" 'taplo 0.10.0' hang
      set -- --managed-tool taplo
    else
      make_taplo_command "$managed_failure_source/taplo" 'taplo 0.10.0' hang
      gzip -c "$managed_failure_source/taplo" >"$managed_failure_download/taplo-linux-x86_64.gz"
      set_failure_case_taplo_field 7 "$(file_sha256_for_test "$managed_failure_download/taplo-linux-x86_64.gz")"
      set -- --apply --managed-tool taplo
    fi
    # Reset async-shell inherited SIGINT before launching the real owner.
    "$test_real_env" --default-signal=HUP,INT,TERM \
      PATH="$scope_path" HOME="$scope_home" TMPDIR="$scope_tmp" \
      DOTFILES_BOOTSTRAP_TESTING=1 \
      DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
      DOTFILES_BOOTSTRAP_TEST_ARCH=x86_64 \
      DOTFILES_BOOTSTRAP_TEST_TAPLO_PROBE_PID_FILE="$scope_pid_file" \
      DOTFILES_BOOTSTRAP_TEST_DOWNLOAD_ROOT="$managed_failure_download" \
      "$scope_bootstrap" "$@" >"$scope_output" 2>&1 &
    scope_owner=$!
    scope_attempt=0
    while [ ! -s "$scope_pid_file" ] && [ "$scope_attempt" -lt 100 ]; do
      sleep 0.05
      scope_attempt=$((scope_attempt + 1))
    done
    scope_signal_delivered=false
    if [ -s "$scope_pid_file" ] \
      && capture_test_process "$scope_owner" "$scope_bootstrap" \
      && signal_verified_test_process "$scope_signal" "$scope_owner" \
        "$captured_process_identity" "$captured_process_command"; then
      scope_signal_delivered=true
    else
      kill_matching_test_process "$scope_owner" "$scope_bootstrap"
    fi
    set +e
    wait "$scope_owner"
    scope_probe_status=$?
    set -e
    if [ "$scope_signal_delivered" = true ] \
      && [ "$scope_probe_status" -eq "$scope_signal_status" ] \
      && only_ownership_coordination "$scope_home" && managed_scope_is_clean; then
      pass "managed Taplo $scope_signal during $scope_mode probe leaves no owned state"
    else
      fail "managed Taplo $scope_signal during $scope_mode probe leaves no owned state"
      sed 's/^/  scoped output: /' "$scope_output" >&2
    fi
  done
done

for scope_race in replace-link-before replace-link-after replace-directory-before \
  replace-directory-after target-collision link-collision
do
  prepare_managed_scope_case "$scope_race"
  make_scoped_publication_race_fixture
  run_managed_scope --apply --managed-tool taplo
  scope_race_preserved=false
  case $scope_race in
    replace-link-*)
      [ "$(readlink "$scope_link" 2>/dev/null || true)" = "$scope_home/replacement" ] \
        && scope_race_preserved=true
      ;;
    replace-directory-*|target-collision)
      [ "$(cat "$scope_target/sentinel" 2>/dev/null || true)" = replacement ] \
        && scope_race_preserved=true
      ;;
    link-collision)
      [ "$(cat "$scope_link/sentinel" 2>/dev/null || true)" = replacement ] \
        && [ "$(find "$scope_link" -mindepth 1 -maxdepth 1 -printf '%f\n')" = sentinel ] \
        && scope_race_preserved=true
      ;;
  esac
  if [ "$run_status" -ne 0 ] && [ "$scope_race_preserved" = true ] \
    && [ -s "$managed_failure_root/race.reached" ] && managed_scope_is_clean; then
    pass "managed Taplo $scope_race preserves the competing artifact"
  else
    fail "managed Taplo $scope_race preserves the competing artifact"
    sed 's/^/  scoped output: /' "$scope_output" >&2
  fi
done

prepare_managed_scope_case cross-device
make_scoped_cross_device_commands
run_managed_scope --apply --managed-tool taplo
if [ "$run_status" -eq 0 ] && [ -x "$scope_target/taplo" ] \
  && [ "$(stat -c '%a' "$scope_target/taplo")" = 755 ] \
  && [ ! -e "$managed_failure_root/copy-fallback" ] \
  && [ "$(find "$scope_home/.local/opt" -mindepth 1 -maxdepth 1 -printf '%f\n')" = taplo-0.10.0-x86_64 ] \
  && managed_scope_is_clean; then
  pass 'managed Taplo stages across devices before atomic final publication'
else
  fail 'managed Taplo stages across devices before atomic final publication'
  sed 's/^/  scoped output: /' "$scope_output" >&2
fi

for scope_device_mode in target link; do
  for scope_device_outcome in success failure HUP INT TERM; do
    prepare_managed_scope_case "device-$scope_device_mode-$scope_device_outcome"
    scope_device_case=$scope_device_mode
    make_scoped_cross_device_commands
    case $scope_device_outcome in
      success) scope_device_status=0 ;;
      failure) scope_publish_failure=taplo-link; scope_device_status=1 ;;
      *)
        scope_signal=$scope_device_outcome
        scope_signal_at=3
        scope_signal_parent=$scope_device_parent
        scope_registration_shell='sh'
        make_scoped_registration_signal_fixture
        case $scope_signal in
          HUP) scope_device_status=129 ;;
          INT) scope_device_status=130 ;;
          TERM) scope_device_status=143 ;;
        esac
        ;;
    esac
    run_managed_scope --apply --managed-tool taplo
    scope_device_clean=true
    case $scope_device_outcome in
      success)
        [ "$(stat -c '%a' "$scope_target/taplo")" = 755 ] \
          && [ "$(readlink "$scope_link")" = "$scope_target/taplo" ] \
          || scope_device_clean=false
        [ "$(find "$scope_home/.local" -name 'dotfiles-bootstrap.*' -print)" = '' ] \
          || scope_device_clean=false
        ;;
      failure) only_ownership_coordination "$scope_home" || scope_device_clean=false ;;
      *)
        only_ownership_coordination "$scope_home" \
          && [ -s "$managed_failure_root/interrupted.path" ] \
          || scope_device_clean=false
        case $(cat "$managed_failure_root/interrupted.path" 2>/dev/null || true) in
          "$scope_device_parent"/dotfiles-bootstrap.*) ;;
          *) scope_device_clean=false ;;
        esac
        ;;
    esac
    if [ "$run_status" -eq "$scope_device_status" ] \
      && [ "$scope_device_clean" = true ] && managed_scope_is_clean \
      && [ ! -e "$managed_failure_root/copy-fallback" ]; then
      pass "managed Taplo separate $scope_device_mode filesystem $scope_device_outcome cleans owned staging"
    else
      fail "managed Taplo separate $scope_device_mode filesystem $scope_device_outcome cleans owned staging"
      sed 's/^/  scoped output: /' "$scope_output" >&2
    fi
  done
done

managed_stage_race_root=$test_tmp/managed-stage-registration-race
managed_stage_race_harness=$managed_stage_race_root/harness
managed_stage_race_home=$managed_stage_race_root/home
managed_stage_race_state=$managed_stage_race_root/state
managed_stage_race_tmp=$managed_stage_race_root/tmp
managed_stage_race_path_file=$managed_stage_race_root/stage.path
managed_stage_race_log=$managed_stage_race_root/commands
mkdir -p \
  "$managed_stage_race_harness" \
  "$managed_stage_race_home" \
  "$managed_stage_race_state" \
  "$managed_stage_race_tmp"
cp -R "$managed_fixture_root/." "$managed_stage_race_harness/"
make_managed_stage_signal_bootstrap \
  "$managed_fixture_root/bootstrap" \
  "$managed_stage_race_harness/bootstrap"
run_capture "$managed_stage_race_root/output" env \
  HOME="$managed_stage_race_home" \
  TMPDIR="$managed_stage_race_tmp" \
  XDG_STATE_HOME="$managed_stage_race_state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=apt \
  DOTFILES_BOOTSTRAP_TEST_ARCH=x86_64 \
  DOTFILES_BOOTSTRAP_TEST_ALL_PACKAGES_MISSING=1 \
  DOTFILES_BOOTSTRAP_TEST_SATISFIED_TOOLS= \
  DOTFILES_BOOTSTRAP_TEST_APT_GHOSTTY_OFFICIAL=1 \
  DOTFILES_BOOTSTRAP_TEST_REAL_MANAGED_INSTALL=1 \
  DOTFILES_BOOTSTRAP_TEST_DOWNLOAD_ROOT="$managed_fixture_download" \
  DOTFILES_BOOTSTRAP_TEST_STOP_AFTER_PACKAGES=1 \
  DOTFILES_BOOTSTRAP_TEST_COMMAND_LOG="$managed_stage_race_log" \
  DOTFILES_BOOTSTRAP_TEST_MANAGED_STAGE_RACE_PATH_FILE="$managed_stage_race_path_file" \
  "$managed_stage_race_harness/bootstrap" --apply
managed_stage_race_status=$run_status
managed_stage_race_path=$(cat "$managed_stage_race_path_file" 2>/dev/null || true)
managed_stage_race_pass=true
[ "$managed_stage_race_status" -eq 143 ] || managed_stage_race_pass=false
grep -Fq 'received TERM; stopping safely' "$managed_stage_race_root/output" \
  || managed_stage_race_pass=false
case "$managed_stage_race_path" in
  "$managed_stage_race_tmp"/dotfiles-bootstrap.*)
    path_exists_for_test "$managed_stage_race_path" \
      && managed_stage_race_pass=false
    ;;
  *)
    managed_stage_race_pass=false
    ;;
esac
if find "$managed_stage_race_tmp" -mindepth 1 -maxdepth 1 \
  -name 'dotfiles-bootstrap.*' -print -quit \
  | grep -q .; then
  managed_stage_race_pass=false
fi
if [ "$managed_stage_race_pass" = true ]; then
  pass 'termination during managed staging registration removes the exact temporary root'
else
  fail 'termination during managed staging registration removes the exact temporary root'
  printf '  managed stage status: %s\n' "$managed_stage_race_status" >&2
  printf '  managed stage path: %s\n' \
    "${managed_stage_race_path:-none}" >&2
  sed 's/^/  managed stage output: /' \
    "$managed_stage_race_root/output" >&2
fi

for managed_test_architecture in x86_64 arm64; do
  run_managed_architecture_case "$managed_test_architecture"
  managed_case_pass=true
  managed_node_directory=$managed_case_home/.local/opt/node-24.19.0-$managed_test_architecture
  managed_lua_directory=$managed_case_home/.local/opt/lua-language-server-3.19.1-$managed_test_architecture
  managed_taplo_directory=$managed_case_home/.local/opt/taplo-0.10.0-$managed_test_architecture
  managed_npm_directory=$managed_case_home/.local/opt/dotfiles-lsp-node-$actual_npm_lock_sha256
  case "$managed_test_architecture" in
    x86_64)
      expected_node_asset=node-v24.19.0-linux-x64.tar.xz
      expected_lua_asset=lua-language-server-3.19.1-linux-x64.tar.gz
      expected_taplo_asset=taplo-linux-x86_64.gz
      ;;
    arm64)
      expected_node_asset=node-v24.19.0-linux-arm64.tar.xz
      expected_lua_asset=lua-language-server-3.19.1-linux-arm64.tar.gz
      expected_taplo_asset=taplo-linux-aarch64.gz
      ;;
  esac

  [ "$managed_case_status" -eq 0 ] || managed_case_pass=false
  [ -d "$managed_node_directory" ] || managed_case_pass=false
  [ -d "$managed_lua_directory" ] || managed_case_pass=false
  [ -d "$managed_taplo_directory" ] || managed_case_pass=false
  [ -x "$managed_taplo_directory/taplo" ] || managed_case_pass=false
  [ -d "$managed_npm_directory" ] || managed_case_pass=false
  [ "$(readlink "$managed_case_home/.local/bin/node" 2>/dev/null || true)" \
    = "$managed_node_directory/bin/node" ] || managed_case_pass=false
  [ "$(readlink "$managed_case_home/.local/bin/npm" 2>/dev/null || true)" \
    = "$managed_node_directory/bin/npm" ] || managed_case_pass=false
  [ -x "$managed_case_home/.local/bin/lua-language-server" ] \
    && [ ! -L "$managed_case_home/.local/bin/lua-language-server" ] \
    || managed_case_pass=false
  grep -Fq \
    "../opt/lua-language-server-3.19.1-$managed_test_architecture/bin/lua-language-server" \
    "$managed_case_home/.local/bin/lua-language-server" \
    || managed_case_pass=false
  [ "$(readlink "$managed_case_home/.local/bin/taplo" 2>/dev/null || true)" \
    = "$managed_taplo_directory/taplo" ] || managed_case_pass=false
  for managed_command in \
    bash-language-server \
    vscode-json-language-server \
    pyright-langserver \
    taplo \
    yaml-language-server
  do
    [ -L "$managed_case_home/.local/bin/$managed_command" ] \
      || managed_case_pass=false
  done
  for managed_package in \
    bash-language-server \
    vscode-langservers-extracted \
    pyright \
    yaml-language-server
  do
    [ -d "$managed_npm_directory/node_modules/$managed_package" ] \
      || managed_case_pass=false
  done
  for unpublished_command in \
    vscode-css-language-server \
    vscode-html-language-server \
    vscode-eslint-language-server \
    pyright \
    npx \
    corepack
  do
    [ ! -e "$managed_case_home/.local/bin/$unpublished_command" ] \
      && [ ! -L "$managed_case_home/.local/bin/$unpublished_command" ] \
      || managed_case_pass=false
  done
  [ "$(find "$managed_case_home/.local/bin" -mindepth 1 -maxdepth 1 | wc -l)" -eq 8 ] \
    || managed_case_pass=false
  printf '%s\n' "$managed_case_commands" \
    | grep -Fqx "download https://fixtures.invalid/$expected_node_asset" \
    || managed_case_pass=false
  printf '%s\n' "$managed_case_commands" \
    | grep -Fqx "download https://fixtures.invalid/$expected_lua_asset" \
    || managed_case_pass=false
  printf '%s\n' "$managed_case_commands" \
    | grep -Fqx "download https://fixtures.invalid/$expected_taplo_asset" \
    || managed_case_pass=false
  printf '%s\n' "$managed_case_commands" \
    | grep -Fqx 'npm-ci --ignore-scripts --omit=dev --no-audit --no-fund' \
    || managed_case_pass=false

  if [ "$managed_case_pass" = true ]; then
    pass "$managed_test_architecture stages and publishes the exact managed language-server set"
  else
    fail "$managed_test_architecture stages and publishes the exact managed language-server set"
    sed "s/^/  $managed_test_architecture output: /" \
      "$test_tmp/managed-$managed_test_architecture.output" >&2
  fi
done

prepare_managed_failure_case unsupported-architecture
run_managed_failure_case 'unsupported architecture: riscv64' '' 0 '' riscv64
if [ -z "$managed_failure_commands" ]; then
  pass 'unsupported architecture fails before apt download and npm commands'
else
  fail 'unsupported architecture fails before apt download and npm commands'
  printf '  unexpected command: %s\n' "$managed_failure_commands" >&2
fi

while IFS='|' read -r failure_version_tool failure_version failure_version_diagnostic; do
  prepare_managed_failure_case "$failure_version_tool-wrong-manifest-version"
  failure_asset_manifest=$managed_failure_harness/manifests/packages-direct.tsv
  awk -F '\t' -v OFS='\t' \
    -v tool="$failure_version_tool" -v version="$failure_version" '
    $1 == tool && $2 == "linux" && $3 == "x86_64" { $4 = version }
    { print }
  ' "$failure_asset_manifest" >"$failure_asset_manifest.new"
  mv "$failure_asset_manifest.new" "$failure_asset_manifest"
  run_managed_failure_case "$failure_version_diagnostic"
done <<'MANAGED_VERSION_FAILURE_CASES'
node|24.20.0|unexpected managed Node version
lua-language-server|3.20.0|unexpected managed LuaLS version
MANAGED_VERSION_FAILURE_CASES

prepare_managed_failure_case non-https-asset
set_failure_case_direct_asset node \
  'http://fixtures.invalid/node-v24.19.0-linux-x64.tar.xz' \
  "$fake_node_x86_sha"
run_managed_failure_case 'direct asset URL must use HTTPS: node'

prepare_managed_failure_case invalid-sha-length
set_failure_case_direct_asset node \
  'https://fixtures.invalid/node-v24.19.0-linux-x64.tar.xz' abc
run_managed_failure_case 'invalid SHA-256 length'

prepare_managed_failure_case invalid-sha-character
set_failure_case_direct_asset node \
  'https://fixtures.invalid/node-v24.19.0-linux-x64.tar.xz' \
  'g000000000000000000000000000000000000000000000000000000000000000'
run_managed_failure_case 'invalid SHA-256'

prepare_managed_failure_case node-checksum-mismatch
set_failure_case_direct_asset node \
  'https://fixtures.invalid/node-v24.19.0-linux-x64.tar.xz' \
  '0000000000000000000000000000000000000000000000000000000000000000'
run_managed_failure_case 'checksum mismatch for https://fixtures.invalid/node-v24.19.0-linux-x64.tar.xz'

prepare_managed_failure_case lua-checksum-mismatch
set_failure_case_direct_asset lua-language-server \
  'https://fixtures.invalid/lua-language-server-3.19.1-linux-x64.tar.gz' \
  '0000000000000000000000000000000000000000000000000000000000000000'
run_managed_failure_case 'checksum mismatch for https://fixtures.invalid/lua-language-server-3.19.1-linux-x64.tar.gz'

prepare_managed_failure_case taplo-missing-record
remove_failure_case_taplo_record
run_managed_failure_case 'missing direct asset for taplo/linux/x86_64'

prepare_managed_failure_case taplo-duplicate-record
duplicate_failure_case_taplo_record
run_managed_failure_case 'malformed direct asset entry: taplo'

prepare_managed_failure_case taplo-wrong-manifest-version
set_failure_case_taplo_field 4 0.9.9
run_managed_failure_case 'unexpected managed Taplo version'

prepare_managed_failure_case taplo-wrong-manifest-format
set_failure_case_taplo_field 5 binary
run_managed_failure_case 'unexpected managed Taplo archive format'

prepare_managed_failure_case taplo-non-https-asset
set_failure_case_direct_asset taplo \
  'http://fixtures.invalid/taplo-linux-x86_64.gz' \
  "$fake_taplo_x86_sha"
run_managed_failure_case 'direct asset URL must use HTTPS: taplo'

prepare_managed_failure_case taplo-checksum-mismatch
set_failure_case_direct_asset taplo \
  'https://fixtures.invalid/taplo-linux-x86_64.gz' \
  '0000000000000000000000000000000000000000000000000000000000000000'
run_managed_failure_case \
  'checksum mismatch for https://fixtures.invalid/taplo-linux-x86_64.gz'

while IFS='|' read -r failure_case_name failure_case_variant failure_case_diagnostic; do
  prepare_managed_failure_case "$failure_case_name"
  create_failure_taplo_asset "$failure_case_variant"
  run_managed_failure_case "$failure_case_diagnostic"
done <<'TAPLO_FAILURE_CASES'
taplo-malformed-gzip|malformed-gzip|verified Taplo asset is not valid gzip
taplo-empty-output|empty|verified Taplo asset did not produce one regular executable
taplo-wrong-staged-version|wrong-version|staged Taplo version does not match taplo 0.10.0
taplo-missing-lsp|missing-lsp|staged Taplo does not expose lsp stdio
TAPLO_FAILURE_CASES

while IFS='|' read -r failure_case_name failure_case_variant failure_case_diagnostic; do
  prepare_managed_failure_case "$failure_case_name"
  create_failure_node_archive "$failure_case_variant"
  run_managed_failure_case "$failure_case_diagnostic"
done <<'NODE_FAILURE_CASES'
node-absolute-member|absolute|verified Node archive contains an unsafe member
node-parent-traversal|parent-traversal|verified Node archive contains an unsafe member
node-outside-root|outside-root|verified Node archive contains an unsafe member
node-missing-executable|missing-node|verified Node archive is missing executable bin/node
node-missing-npm-cli|missing-npm-cli|verified Node archive is missing npm-cli.js
node-wrong-staged-version|wrong-version|staged Node version does not match 24.19.0
NODE_FAILURE_CASES

while IFS='|' read -r failure_case_name failure_case_variant failure_case_diagnostic; do
  prepare_managed_failure_case "$failure_case_name"
  create_failure_lua_archive "$failure_case_variant"
  run_managed_failure_case "$failure_case_diagnostic"
done <<'LUA_FAILURE_CASES'
lua-absolute-member|absolute|verified LuaLS archive contains an unsafe member
lua-parent-traversal|parent-traversal|verified LuaLS archive contains an unsafe member
lua-unexpected-root|unexpected-root|verified LuaLS archive has unexpected top-level content
lua-missing-executable|missing-executable|verified LuaLS archive is missing executable bin/lua-language-server
lua-missing-main|missing-main|verified LuaLS archive is missing main.lua
lua-missing-script-directory|missing-script-directory|verified LuaLS archive is missing script
LUA_FAILURE_CASES

while IFS='|' read -r failure_case_name failure_case_mutation; do
  prepare_managed_failure_case "$failure_case_name"
  mutate_failure_npm_manifest "$failure_case_mutation"
  run_managed_failure_case 'npm language-server manifests failed validation'
done <<'NPM_MANIFEST_FAILURE_CASES'
npm-malformed-package|malformed-package
npm-private-false|private-false
npm-ranged-version|ranged-version
npm-lock-root-mismatch|lock-root-mismatch
npm-lockfile-version|lockfile-version
npm-missing-resolved|missing-resolved
npm-invalid-resolved|invalid-resolved
npm-missing-integrity|missing-integrity
npm-malformed-integrity|malformed-integrity
NPM_MANIFEST_FAILURE_CASES

prepare_managed_failure_case npm-command-failure
run_managed_failure_case 'npm language-server installation failed' '' 1
if printf '%s\n' "$managed_failure_commands" \
  | grep -Fqx 'npm-ci --ignore-scripts --omit=dev --no-audit --no-fund'; then
  pass 'npm failure preserves every required npm ci hardening flag'
else
  fail 'npm failure preserves every required npm ci hardening flag'
fi

prepare_managed_failure_case npm-missing-staged-command
run_managed_failure_case \
  'npm language-server bundle is missing executable: yaml-language-server' \
  '' 0 yaml-language-server

while IFS='|' read -r collision_name collision_relative collision_type; do
  run_managed_collision_case \
    "$collision_name" "$collision_relative" "$collision_type"
done <<COLLISION_CASES
node-version-directory|.local/opt/node-24.19.0-x86_64|directory
lua-version-directory|.local/opt/lua-language-server-3.19.1-x86_64|directory
taplo-version-directory|.local/opt/taplo-0.10.0-x86_64|directory
taplo-version-file|.local/opt/taplo-0.10.0-x86_64|file
taplo-version-symlink|.local/opt/taplo-0.10.0-x86_64|symlink
npm-bundle-directory|.local/opt/dotfiles-lsp-node-$actual_npm_lock_sha256|directory
node-command-link|.local/bin/node|file
npm-command-link|.local/bin/npm|file
lua-wrapper-target|.local/bin/lua-language-server|file
taplo-command-directory|.local/bin/taplo|directory
taplo-command-file|.local/bin/taplo|file
taplo-command-symlink|.local/bin/taplo|symlink
bash-command-target|.local/bin/bash-language-server|file
json-command-target|.local/bin/vscode-json-language-server|file
pyright-command-target|.local/bin/pyright-langserver|file
yaml-command-target|.local/bin/yaml-language-server|file
local-parent-file|.local|file
local-parent-symlink|.local|symlink
bin-parent-file|.local/bin|file
bin-parent-symlink|.local/bin|symlink
opt-parent-file|.local/opt|file
opt-parent-symlink|.local/opt|symlink
COLLISION_CASES

standalone_collision_root=$test_tmp/managed-standalone-collision
standalone_collision_home=$standalone_collision_root/home
standalone_collision_bin=$standalone_collision_root/bin
standalone_collision_log=$standalone_collision_root/commands
standalone_collision_target=$standalone_collision_home/.local/opt/dotfiles-lsp-node-$actual_npm_lock_sha256
mkdir -p \
  "$standalone_collision_home" \
  "$standalone_collision_bin" \
  "$standalone_collision_target"
cp "$bootstrap" "$standalone_collision_root/bootstrap"
printf '%s\n' '#!/bin/sh' 'exit 1' >"$standalone_collision_bin/git"
chmod 0755 "$standalone_collision_bin/git" "$standalone_collision_root/bootstrap"
printf '%s\n' 'standalone collision sentinel' \
  >"$standalone_collision_target/sentinel"
run_capture "$standalone_collision_root/output" env \
  PATH="$standalone_collision_bin:$test_utilities_bin" \
  HOME="$standalone_collision_home" \
  XDG_STATE_HOME="$standalone_collision_root/state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=apt \
  DOTFILES_BOOTSTRAP_TEST_ARCH=x86_64 \
  DOTFILES_BOOTSTRAP_TEST_ALL_PACKAGES_MISSING=1 \
  DOTFILES_BOOTSTRAP_TEST_SATISFIED_TOOLS= \
  DOTFILES_BOOTSTRAP_TEST_APT_GHOSTTY_OFFICIAL=1 \
  DOTFILES_BOOTSTRAP_TEST_COMMAND_LOG="$standalone_collision_log" \
  /bin/sh "$standalone_collision_root/bootstrap" --apply
standalone_collision_output=$(cat "$standalone_collision_root/output")
if [ "$run_status" -ne 0 ] \
  && printf '%s\n' "$standalone_collision_output" \
    | grep -Fq "$standalone_collision_target" \
  && [ ! -e "$standalone_collision_log" ] \
  && [ "$(cat "$standalone_collision_target/sentinel" 2>/dev/null || true)" \
    = 'standalone collision sentinel' ]; then
  pass 'standalone Debian collision fails before Git bootstrap apt commands'
else
  fail 'standalone Debian collision fails before Git bootstrap apt commands'
fi

for publication_token in \
  node-directory \
  lua-directory \
  taplo-directory \
  taplo-link \
  npm-directory \
  command-links
do
  prepare_managed_failure_case "publish-$publication_token"
  publication_parent_one=
  publication_parent_two=
  case "$publication_token" in
    node-directory)
      mkdir "$managed_failure_home/.local"
      publication_parent_one=$managed_failure_home/.local
      ;;
    lua-directory)
      mkdir -p "$managed_failure_home/.local/bin"
      publication_parent_one=$managed_failure_home/.local/bin
      ;;
    taplo-directory)
      mkdir -p "$managed_failure_home/.local/bin"
      publication_parent_one=$managed_failure_home/.local/bin
      ;;
    taplo-link)
      mkdir -p \
        "$managed_failure_home/.local/bin" \
        "$managed_failure_home/.local/opt"
      publication_parent_one=$managed_failure_home/.local/bin
      publication_parent_two=$managed_failure_home/.local/opt
      ;;
    npm-directory)
      mkdir -p "$managed_failure_home/.local/opt"
      publication_parent_one=$managed_failure_home/.local/opt
      ;;
    command-links)
      mkdir -p \
        "$managed_failure_home/.local/bin" \
        "$managed_failure_home/.local/opt"
      publication_parent_one=$managed_failure_home/.local/bin
      publication_parent_two=$managed_failure_home/.local/opt
      ;;
  esac
  printf '%s\n' 'publication sentinel' \
    >"$managed_failure_home/preexisting-sentinel"
  run_managed_failure_case \
    "forced managed publication failure after $publication_token" \
    "$publication_token"
  publication_cleanup_pass=true
  [ "$(cat "$managed_failure_home/preexisting-sentinel" 2>/dev/null || true)" \
    = 'publication sentinel' ] || publication_cleanup_pass=false
  [ -d "$publication_parent_one" ] && [ ! -L "$publication_parent_one" ] \
    || publication_cleanup_pass=false
  if [ -n "$publication_parent_two" ]; then
    [ -d "$publication_parent_two" ] && [ ! -L "$publication_parent_two" ] \
      || publication_cleanup_pass=false
  fi
  if [ "$publication_cleanup_pass" = true ]; then
    pass "$publication_token failure removes only invocation-created managed state"
  else
    fail "$publication_token failure removes only invocation-created managed state"
  fi
done

for signal_token in \
  parent-directory \
  managed-directory \
  managed-link \
  lua-wrapper \
  taplo-directory \
  taplo-link
do
  prepare_managed_failure_case "signal-before-journal-$signal_token"
  signal_parent_one=
  signal_parent_two=
  case "$signal_token" in
    parent-directory)
      ;;
    managed-directory|managed-link|lua-wrapper|taplo-directory|taplo-link)
      mkdir -p \
        "$managed_failure_home/.local/bin" \
        "$managed_failure_home/.local/opt"
      signal_parent_one=$managed_failure_home/.local/bin
      signal_parent_two=$managed_failure_home/.local/opt
      ;;
  esac
  printf '%s\n' 'pre-journal signal sentinel' \
    >"$managed_failure_home/preexisting-sentinel"
  run_managed_failure_case \
    'received TERM; stopping safely' \
    '' \
    0 \
    '' \
    x86_64 \
    "$signal_token"
  signal_cleanup_pass=true
  [ "$managed_failure_status" -eq 143 ] || signal_cleanup_pass=false
  [ "$(cat "$managed_failure_home/preexisting-sentinel" 2>/dev/null || true)" \
    = 'pre-journal signal sentinel' ] || signal_cleanup_pass=false
  if [ "$signal_token" = parent-directory ]; then
    only_ownership_coordination "$managed_failure_home" \
      || signal_cleanup_pass=false
  else
    [ -d "$signal_parent_one" ] && [ ! -L "$signal_parent_one" ] \
      || signal_cleanup_pass=false
    [ -d "$signal_parent_two" ] && [ ! -L "$signal_parent_two" ] \
      || signal_cleanup_pass=false
  fi
  if [ "$signal_cleanup_pass" = true ]; then
    pass "$signal_token interruption removes only invocation-created managed state"
  else
    fail "$signal_token interruption removes only invocation-created managed state"
  fi
done

run_managed_type_mutation_case taplo-directory directory-to-file
run_managed_type_mutation_case taplo-link link-to-directory
run_managed_type_mutation_case \
  taplo-link-to-regular link-to-regular \
  'unjournaled Taplo link cleanup preserves a regular-file replacement'
run_journaled_link_mutation_case \
  'journaled Taplo link cleanup preserves a regular-file replacement' regular
run_journaled_link_mutation_case \
  'journaled Taplo link cleanup preserves a real-directory replacement' directory
run_link_result_case \
  'managed link publication rejects a successful no-link command' \
  no-link \
  'managed language-tool link was not published'
run_link_result_case \
  'managed link publication rejects a successful wrong-target link' \
  wrong-link \
  'managed language-tool link has an unexpected target'

control_link_root=$test_tmp/managed-link-controls
control_link_harness=$control_link_root/bootstrap
control_link_bin=$control_link_root/bin
control_link_home=$control_link_root/home
control_link_journal=$control_link_root/managed-created.paths
control_link_audit=$control_link_root/ln.audit
mkdir -p "$control_link_bin" "$control_link_home/.local/bin"
make_managed_link_control_bootstrap "$bootstrap" "$control_link_harness"
make_link_audit_command \
  "$control_link_bin/ln" "$(command -v ln)"
control_link_pass=true
for control_link_character in lf cr tab; do
  case "$control_link_character" in
    lf) control_link_value=$(printf 'left\nright') ;;
    cr) control_link_value=$(printf 'left\rright') ;;
    tab) control_link_value=$(printf 'left\tright') ;;
  esac
  for control_link_position in source target; do
    control_link_source=$control_link_root/source
    control_link_target=$control_link_home/.local/bin/taplo
    case "$control_link_position" in
      source) control_link_source=$control_link_root/$control_link_value ;;
      target) control_link_target=$control_link_home/.local/bin/$control_link_value ;;
    esac
    : >"$control_link_audit"
    run_capture "$control_link_root/$control_link_character-$control_link_position.output" env \
      PATH="$control_link_bin:$test_utilities_bin" \
      TMPDIR="$control_link_root" \
      HOME="$control_link_home" \
      XDG_STATE_HOME="$control_link_root/state" \
      DOTFILES_BOOTSTRAP_TESTING=1 \
      DOTFILES_BOOTSTRAP_TEST_CONTROL_LINK=1 \
      DOTFILES_BOOTSTRAP_TEST_CONTROL_LINK_JOURNAL="$control_link_journal" \
      DOTFILES_BOOTSTRAP_TEST_CONTROL_LINK_SOURCE="$control_link_source" \
      DOTFILES_BOOTSTRAP_TEST_CONTROL_LINK_TARGET="$control_link_target" \
      DOTFILES_BOOTSTRAP_TEST_LINK_AUDIT_FILE="$control_link_audit" \
      "$control_link_harness" --apply
    [ "$run_status" -ne 0 ] || control_link_pass=false
    [ ! -s "$control_link_audit" ] || control_link_pass=false
  done
done
if [ "$control_link_pass" = true ]; then
  pass 'managed link publication rejects LF CR and TAB before ln'
else
  fail 'managed link publication rejects LF CR and TAB before ln'
fi

while IFS='|' read -r selective_name selective_tools selective_links selective_kind; do
  run_selective_managed_case \
    "$selective_name" "$selective_tools" "$selective_links" "$selective_kind"
done <<'SELECTIVE_CASES'
bash-only|node,npm,vscode-json-language-server,lua-language-server,pyright-langserver,taplo,yaml-language-server,uv,neovim,stylua,tree-sitter,herdr,font-space-mono-nerd|bash-language-server|npm
json-only|node,npm,bash-language-server,lua-language-server,pyright-langserver,taplo,yaml-language-server,uv,neovim,stylua,tree-sitter,herdr,font-space-mono-nerd|vscode-json-language-server|npm
lua-only|node,npm,bash-language-server,vscode-json-language-server,pyright-langserver,taplo,yaml-language-server,uv,neovim,stylua,tree-sitter,herdr,font-space-mono-nerd|lua-language-server|lua
pyright-only|node,npm,bash-language-server,vscode-json-language-server,lua-language-server,taplo,yaml-language-server,uv,neovim,stylua,tree-sitter,herdr,font-space-mono-nerd|pyright-langserver|npm
taplo-only|node,npm,bash-language-server,vscode-json-language-server,lua-language-server,pyright-langserver,yaml-language-server,uv,neovim,stylua,tree-sitter,herdr,font-space-mono-nerd|taplo|taplo
yaml-only|node,npm,bash-language-server,vscode-json-language-server,lua-language-server,pyright-langserver,taplo,uv,neovim,stylua,tree-sitter,herdr,font-space-mono-nerd|yaml-language-server|npm
json-and-pyright|node,npm,bash-language-server,lua-language-server,taplo,yaml-language-server,uv,neovim,stylua,tree-sitter,herdr,font-space-mono-nerd|vscode-json-language-server,pyright-langserver|npm
SELECTIVE_CASES

idempotent_home=$test_tmp/managed-x86_64-home
idempotent_root=$test_tmp/managed-idempotent
idempotent_bin=$idempotent_root/bin
idempotent_log=$idempotent_root/commands
mkdir -p "$idempotent_bin"
printf '%s\n' '#!/bin/sh' "printf '%s\\n' 'install ok installed'" \
  >"$idempotent_bin/dpkg-query"
printf '%s\n' '#!/bin/sh' 'exit 0' >"$idempotent_bin/apt-cache"
chmod 0755 "$idempotent_bin/dpkg-query" "$idempotent_bin/apt-cache"
idempotent_before=$(managed_tree_digest "$idempotent_home")
run_capture "$idempotent_root/output" env \
  PATH="$idempotent_bin:$test_utilities_bin" \
  HOME="$idempotent_home" \
  XDG_STATE_HOME="$idempotent_root/state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=apt \
  DOTFILES_BOOTSTRAP_TEST_SATISFIED_TOOLS='node,npm,bash-language-server,vscode-json-language-server,lua-language-server,pyright-langserver,taplo,yaml-language-server,uv,neovim,stylua,tree-sitter,herdr,font-space-mono-nerd,visidata' \
  DOTFILES_BOOTSTRAP_TEST_APT_GHOSTTY_OFFICIAL=1 \
  DOTFILES_BOOTSTRAP_TEST_REAL_MANAGED_INSTALL=1 \
  DOTFILES_BOOTSTRAP_TEST_DOWNLOAD_ROOT="$managed_fixture_download" \
  DOTFILES_BOOTSTRAP_TEST_STOP_AFTER_PACKAGES=1 \
  DOTFILES_BOOTSTRAP_TEST_COMMAND_LOG="$idempotent_log" \
  "$managed_fixture_root/bootstrap" --apply
idempotent_status=$run_status
idempotent_after=$(managed_tree_digest "$idempotent_home")
if [ "$idempotent_status" -eq 0 ] \
  && [ "$idempotent_before" = "$idempotent_after" ] \
  && [ ! -e "$idempotent_log" ]; then
  pass 'completed managed provisioning is byte-stable and performs no work on rerun'
else
  fail 'completed managed provisioning is byte-stable and performs no work on rerun'
  printf '  status: %s\n  digest before: %s\n  digest after: %s\n' \
    "$idempotent_status" "$idempotent_before" "$idempotent_after" >&2
  if [ -e "$idempotent_log" ]; then
    sed 's/^/  command: /' "$idempotent_log" >&2
  fi
  sed 's/^/  output: /' "$idempotent_root/output" >&2
fi

pacman_apply_log=$test_tmp/pacman-apply.commands
run_capture "$test_tmp/pacman-apply.output" env \
  HOME="$test_tmp/pacman-apply-home" \
  XDG_STATE_HOME="$test_tmp/pacman-apply-state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=pacman \
  DOTFILES_BOOTSTRAP_TEST_ALL_PACKAGES_MISSING=1 \
  DOTFILES_BOOTSTRAP_TEST_STOP_AFTER_PACKAGES=1 \
  DOTFILES_BOOTSTRAP_TEST_COMMAND_LOG="$pacman_apply_log" \
  "$bootstrap" --apply
if [ "$run_status" -eq 4 ]; then
  pass 'pacman apply stops for the user-managed full upgrade'
else
  fail 'pacman apply stops for the user-managed full upgrade'
fi
if [ ! -e "$pacman_apply_log" ]; then
  pass 'pacman policy stop executes no package command'
else
  fail 'pacman policy stop executes no package command'
fi

brew_apply_log=$test_tmp/brew-apply.commands
run_capture "$test_tmp/brew-apply.output" env \
  HOME="$test_tmp/brew-apply-home" \
  XDG_STATE_HOME="$test_tmp/brew-apply-state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=macos \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=homebrew \
  DOTFILES_BOOTSTRAP_TEST_ALL_PACKAGES_MISSING=1 \
  DOTFILES_BOOTSTRAP_TEST_BREW_MISSING=1 \
  DOTFILES_BOOTSTRAP_TEST_STOP_AFTER_PACKAGES=1 \
  DOTFILES_BOOTSTRAP_TEST_COMMAND_LOG="$brew_apply_log" \
  "$bootstrap" --apply
if [ "$run_status" -eq 0 ]; then
  pass 'Homebrew package phase succeeds in the command harness'
else
  fail 'Homebrew package phase succeeds in the command harness'
fi
brew_apply_commands=$(cat "$brew_apply_log" 2>/dev/null || true)
require_contains "$brew_apply_commands" 'pinned-installer homebrew a34ae4ee9151cbce4c3b33bca7043a972b7ae9a5' 'Homebrew bootstrap uses the pinned installer revision'
require_contains "$brew_apply_commands" 'brew install neovim' 'Homebrew package phase installs missing formulae'
require_contains "$brew_apply_commands" 'brew install tree-sitter-cli' \
  'Homebrew package phase installs the Tree-sitter CLI'
require_contains "$brew_apply_commands" 'brew install --cask ghostty' 'Homebrew package phase installs missing casks'
require_contains "$brew_apply_commands" \
  'uv tool install --force --with pyarrow==25.0.0 --with duckdb==1.5.5 --no-config visidata==3.4' \
  'Homebrew apply installs the exact shared editor tool environment'
if printf '%s\n' "$brew_apply_commands" | grep -Fqx 'brew install bash-language-server' \
  && printf '%s\n' "$brew_apply_commands" | grep -Fqx 'brew install vscode-langservers-extracted' \
  && printf '%s\n' "$brew_apply_commands" | grep -Fqx 'brew install lua-language-server' \
  && printf '%s\n' "$brew_apply_commands" | grep -Fqx 'brew install pyright' \
  && printf '%s\n' "$brew_apply_commands" | grep -Fqx 'brew install taplo' \
  && printf '%s\n' "$brew_apply_commands" | grep -Fqx 'brew install yaml-language-server'; then
  pass 'Homebrew apply installs all six exact language-server formulae'
else
  fail 'Homebrew apply installs all six exact language-server formulae'
fi

i3_apt_apply_log=$test_tmp/i3-apt-apply.commands
run_capture "$test_tmp/i3-apt-apply.output" env \
  HOME="$test_tmp/i3-apt-apply-home" \
  XDG_STATE_HOME="$test_tmp/i3-apt-apply-state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=apt \
  DOTFILES_BOOTSTRAP_TEST_ALL_PACKAGES_MISSING=1 \
  DOTFILES_BOOTSTRAP_TEST_APT_GHOSTTY_OFFICIAL=1 \
  DOTFILES_BOOTSTRAP_TEST_STOP_AFTER_PACKAGES=1 \
  DOTFILES_BOOTSTRAP_TEST_COMMAND_LOG="$i3_apt_apply_log" \
  "$bootstrap" --apply --window-manager i3
if [ "$run_status" -eq 0 ]; then
  pass 'i3 apt package phase succeeds in the command harness'
else
  fail 'i3 apt package phase succeeds in the command harness'
fi
i3_apt_apply_commands=$(cat "$i3_apt_apply_log" 2>/dev/null || true)
require_contains "$i3_apt_apply_commands" 'i3-wm' \
  'i3 apt profile installs i3-wm in the guarded apt transaction'

hypr_pacman_output=$test_tmp/hypr-pacman-apply.output
run_capture "$hypr_pacman_output" env \
  HOME="$test_tmp/hypr-pacman-apply-home" \
  XDG_STATE_HOME="$test_tmp/hypr-pacman-apply-state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=pacman \
  DOTFILES_BOOTSTRAP_TEST_ALL_PACKAGES_MISSING=1 \
  DOTFILES_BOOTSTRAP_TEST_STOP_AFTER_PACKAGES=1 \
  "$bootstrap" --apply --window-manager hypr
if [ "$run_status" -eq 4 ]; then
  pass 'Hyprland pacman profile stops for the user-managed full upgrade'
else
  fail 'Hyprland pacman profile stops for the user-managed full upgrade'
fi
require_contains "$(cat "$hypr_pacman_output")" 'hyprland' \
  'Hyprland is included in the single pacman full-upgrade command'
require_contains "$(cat "$hypr_pacman_output")" 'quickshell' \
  'Hyprland includes Quickshell in the single pacman full-upgrade command'
require_contains "$(cat "$hypr_pacman_output")" 'qt6-5compat' \
  'Hyprland includes Qt 5 compatibility in the single pacman full-upgrade command'

rishot_plan_root=$test_tmp/rishot-plan
rishot_plan_bin=$rishot_plan_root/bin
mkdir -p "$rishot_plan_bin"
printf '%s\n' '#!/bin/sh' 'exit 0' >"$rishot_plan_bin/pacman"
chmod 0755 "$rishot_plan_bin/pacman"

for rishot_plan_profile in hypr i3 none; do
  rishot_plan_log=$rishot_plan_root/$rishot_plan_profile.commands
  run_capture "$rishot_plan_root/$rishot_plan_profile.output" env \
    PATH="$rishot_plan_bin:$test_utilities_bin" \
    HOME="$rishot_plan_root/$rishot_plan_profile-home" \
    XDG_STATE_HOME="$rishot_plan_root/$rishot_plan_profile-state" \
    DOTFILES_BOOTSTRAP_TESTING=1 \
    DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
    DOTFILES_BOOTSTRAP_TEST_MANAGER=pacman \
    DOTFILES_BOOTSTRAP_TEST_SATISFIED_TOOLS=herdr \
    DOTFILES_BOOTSTRAP_TEST_STOP_AFTER_PACKAGES=1 \
    DOTFILES_BOOTSTRAP_TEST_COMMAND_LOG="$rishot_plan_log" \
    "$bootstrap" --apply --window-manager "$rishot_plan_profile"
  rishot_plan_status=$run_status
  rishot_plan_count=0
  if [ -f "$rishot_plan_log" ]; then
    rishot_plan_count=$(grep -Fxc 'direct-install rishot' \
      "$rishot_plan_log" || true)
  fi
  case "$rishot_plan_profile" in
    hypr) rishot_plan_expected=1 ;;
    i3|none) rishot_plan_expected=0 ;;
  esac
  if [ "$rishot_plan_status" -eq 0 ] \
    && [ "$rishot_plan_count" -eq "$rishot_plan_expected" ]; then
    pass "Rishot direct install count is exact for $rishot_plan_profile"
  else
    fail "Rishot direct install count is exact for $rishot_plan_profile"
  fi
done

for rishot_plan_profile in hypr i3 none; do
  rishot_plan_output=$(env \
    HOME="$rishot_plan_root/$rishot_plan_profile-dry-home" \
    XDG_STATE_HOME="$rishot_plan_root/$rishot_plan_profile-dry-state" \
    DOTFILES_BOOTSTRAP_TESTING=1 \
    DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
    DOTFILES_BOOTSTRAP_TEST_MANAGER=pacman \
    "$bootstrap" --window-manager "$rishot_plan_profile")
  rishot_plan_count=$(printf '%s\n' "$rishot_plan_output" | grep -Fxc \
    '  install upstream rishot 28c273b1b573725e03ef12989451f48009dabc83' \
    || true)
  case "$rishot_plan_profile" in
    hypr) rishot_plan_expected=1 ;;
    i3|none) rishot_plan_expected=0 ;;
  esac
  if [ "$rishot_plan_count" -eq "$rishot_plan_expected" ]; then
    pass "Rishot dry-run count is exact for $rishot_plan_profile"
  else
    fail "Rishot dry-run count is exact for $rishot_plan_profile"
  fi
done

rishot_fixture_root=$test_tmp/rishot-fixture
rishot_fixture_harness=$rishot_fixture_root/harness
rishot_fixture_download=$rishot_fixture_root/download
rishot_fixture_source=$rishot_fixture_root/source
rishot_fixture_bin=$rishot_fixture_root/bin
mkdir -p "$rishot_fixture_harness" "$rishot_fixture_bin"
cp -R "$dotfiles_dir/." "$rishot_fixture_harness/"
create_fake_rishot_asset \
  "$rishot_fixture_download" "$rishot_fixture_source"
rishot_fixture_manifest=$rishot_fixture_harness/manifests/packages-direct.tsv
rewrite_rishot_fixture_sha "$rishot_fixture_manifest" "$fake_rishot_sha"
printf '%s\n' '#!/bin/sh' 'exit 0' >"$rishot_fixture_bin/pacman"
chmod 0755 "$rishot_fixture_bin/pacman"

run_rishot_case() {
  rishot_case_name=$1
  rishot_case_harness=${2:-$rishot_fixture_harness}
  rishot_case_download=${3:-$rishot_fixture_download}
  rishot_case_failure_token=${4:-}
  rishot_case_bin=${5:-$rishot_fixture_bin}
  rishot_case_home=$rishot_fixture_root/$rishot_case_name-home
  rishot_case_state=$rishot_fixture_root/$rishot_case_name-state
  rishot_case_tmp=$rishot_fixture_root/$rishot_case_name-tmp
  rishot_case_log=$rishot_fixture_root/$rishot_case_name.commands
  mkdir -p "$rishot_case_home" "$rishot_case_tmp"
  : >"$rishot_case_log"
  run_capture "$rishot_fixture_root/$rishot_case_name.output" "$test_real_env" \
    PATH="$rishot_case_bin:$test_utilities_bin" \
    TMPDIR="$rishot_case_tmp" \
    HOME="$rishot_case_home" \
    XDG_STATE_HOME="$rishot_case_state" \
    DOTFILES_BOOTSTRAP_TESTING=1 \
    DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
    DOTFILES_BOOTSTRAP_TEST_MANAGER=pacman \
    DOTFILES_BOOTSTRAP_TEST_SATISFIED_TOOLS=herdr,visidata \
    DOTFILES_BOOTSTRAP_TEST_REAL_RISHOT_INSTALL=1 \
    DOTFILES_BOOTSTRAP_TEST_DOWNLOAD_ROOT="$rishot_case_download" \
    DOTFILES_BOOTSTRAP_TEST_RISHOT_FAIL_AFTER="$rishot_case_failure_token" \
    DOTFILES_BOOTSTRAP_TEST_STOP_AFTER_PACKAGES=1 \
    DOTFILES_BOOTSTRAP_TEST_COMMAND_LOG="$rishot_case_log" \
    "$rishot_case_harness/bootstrap" --apply --window-manager hypr
  rishot_case_status=$run_status
  rishot_case_output=$(cat \
    "$rishot_fixture_root/$rishot_case_name.output")
}

rishot_transients_are_absent() {
  rishot_absence_home=$1
  rishot_absence_tmp=$2
  ! find "$rishot_absence_home/.local/share" -maxdepth 1 \
    -name '.rishot-stage.*' -print 2>/dev/null | grep -q . \
    && ! find "$rishot_absence_tmp" -maxdepth 1 \
      -name 'dotfiles-bootstrap.*' -print 2>/dev/null | grep -q .
}

rishot_outputs_are_absent() {
  rishot_absence_home=$1
  rishot_absence_tmp=$2
  [ ! -e "$rishot_absence_home/.local/share/rishot" ] \
    && [ ! -L "$rishot_absence_home/.local/share/rishot" ] \
    && [ ! -e "$rishot_absence_home/.local/bin/rishot" ] \
    && [ ! -L "$rishot_absence_home/.local/bin/rishot" ] \
    && rishot_transients_are_absent \
      "$rishot_absence_home" "$rishot_absence_tmp"
}

run_rishot_case successful
if [ "$rishot_case_status" -eq 0 ] \
  && [ -d "$rishot_case_home/.local/share/rishot" ] \
  && [ ! -L "$rishot_case_home/.local/share/rishot" ] \
  && [ -x "$rishot_case_home/.local/share/rishot/bin/rishot" ] \
  && [ -f "$rishot_case_home/.local/share/rishot/src/shell.qml" ] \
  && [ ! -L "$rishot_case_home/.local/share/rishot/src/shell.qml" ] \
  && [ "$(cat "$rishot_case_home/.local/share/rishot/.dotfiles-revision")" \
    = 28c273b1b573725e03ef12989451f48009dabc83 ] \
  && [ "$(readlink "$rishot_case_home/.local/bin/rishot")" \
    = "$rishot_case_home/.local/share/rishot/bin/rishot" ] \
  && rishot_transients_are_absent \
    "$rishot_case_home" "$rishot_case_tmp"; then
  pass 'Rishot publishes the exact verified source tree and absolute launcher'
else
  fail 'Rishot publishes the exact verified source tree and absolute launcher'
  printf '%s\n' "$rishot_case_output" | sed 's/^/  output: /' >&2
fi

rishot_success_home=$rishot_case_home
rishot_success_before=$(project_state_fingerprint \
  "$rishot_success_home/.local")
run_rishot_case successful
rishot_success_after=$(project_state_fingerprint \
  "$rishot_success_home/.local")
if [ "$rishot_case_status" -eq 0 ] \
  && [ "$rishot_success_before" = "$rishot_success_after" ] \
  && [ ! -s "$rishot_case_log" ] \
  && rishot_transients_are_absent \
    "$rishot_case_home" "$rishot_case_tmp"; then
  pass 'Rishot exact-pin rerun is byte-stable and performs no work'
else
  fail 'Rishot exact-pin rerun is byte-stable and performs no work'
fi

run_rishot_archive_failure() {
  rishot_failure_name=$1
  rishot_failure_variant=$2
  rishot_failure_sha_mode=$3
  rishot_failure_diagnostic=$4
  rishot_failure_root=$rishot_fixture_root/archive-$rishot_failure_name
  rishot_failure_harness=$rishot_failure_root/harness
  rishot_failure_download=$rishot_failure_root/download
  rishot_failure_source=$rishot_failure_root/source
  mkdir -p "$rishot_failure_harness"
  cp -R "$rishot_fixture_harness/." "$rishot_failure_harness/"
  create_fake_rishot_asset_variant \
    "$rishot_failure_download" "$rishot_failure_source" \
    "$rishot_failure_variant"
  case "$rishot_failure_sha_mode" in
    exact) rishot_failure_sha=$fake_rishot_sha ;;
    mismatch)
      rishot_failure_sha=0000000000000000000000000000000000000000000000000000000000000000
      ;;
    *) return 1 ;;
  esac
  rewrite_rishot_fixture_sha \
    "$rishot_failure_harness/manifests/packages-direct.tsv" \
    "$rishot_failure_sha"
  run_rishot_case "archive-$rishot_failure_name" \
    "$rishot_failure_harness" "$rishot_failure_download"
  if [ "$rishot_case_status" -ne 0 ] \
    && printf '%s\n' "$rishot_case_output" \
      | grep -Fq "$rishot_failure_diagnostic" \
    && rishot_outputs_are_absent \
      "$rishot_case_home" "$rishot_case_tmp"; then
    pass "Rishot rejects $rishot_failure_name without publication"
  else
    fail "Rishot rejects $rishot_failure_name without publication"
    printf '%s\n' "$rishot_case_output" | sed 's/^/  output: /' >&2
  fi
}

run_rishot_archive_failure \
  checksum-mismatch normal mismatch 'checksum mismatch for'
run_rishot_archive_failure \
  parent-traversal traversal exact 'archive contains an unsafe member'
run_rishot_archive_failure \
  symbolic-link-member symlink exact 'archive contains a non-regular member'
run_rishot_archive_failure \
  missing-launcher missing-launcher exact 'archive is missing bin/rishot'
run_rishot_archive_failure \
  missing-qml missing-qml exact 'archive is missing src/shell.qml'

for rishot_failure_token in stage directory launcher; do
  run_rishot_case "failure-$rishot_failure_token" \
    "$rishot_fixture_harness" "$rishot_fixture_download" \
    "$rishot_failure_token"
  if [ "$rishot_case_status" -ne 0 ] \
    && printf '%s\n' "$rishot_case_output" | grep -Fq \
      "forced Rishot publication failure after $rishot_failure_token" \
    && rishot_outputs_are_absent \
      "$rishot_case_home" "$rishot_case_tmp"; then
    pass "Rishot cleans a forced failure after $rishot_failure_token"
  else
    fail "Rishot cleans a forced failure after $rishot_failure_token"
  fi
done

for rishot_signal_boundary in stage directory launcher; do
  rishot_signal_root=$rishot_fixture_root/signal-$rishot_signal_boundary
  rishot_signal_bin=$rishot_signal_root/bin
  rishot_signal_home=$rishot_signal_root/home
  rishot_signal_tmp=$rishot_signal_root/tmp
  mkdir -p "$rishot_signal_bin" "$rishot_signal_home" "$rishot_signal_tmp"
  cp "$rishot_fixture_bin/pacman" "$rishot_signal_bin/pacman"
  case "$rishot_signal_boundary" in
    stage)
      rishot_signal_command='mktemp'
      rishot_signal_target=$rishot_signal_home/.local/share/.rishot-stage.XXXXXX
      ;;
    directory)
      rishot_signal_command='mv'
      rishot_signal_target=$rishot_signal_home/.local/share/rishot
      ;;
    launcher)
      rishot_signal_command='ln'
      rishot_signal_target=$rishot_signal_home/.local/bin/rishot
      ;;
  esac
  rishot_signal_real_command=$(command -v "$rishot_signal_command")
  make_signal_boundary_command \
    "$rishot_signal_bin/$rishot_signal_command" \
    "$rishot_signal_real_command"
  set +e
  "$test_real_env" \
    PATH="$rishot_signal_bin:$test_utilities_bin" \
    TMPDIR="$rishot_signal_tmp" \
    HOME="$rishot_signal_home" \
    XDG_STATE_HOME="$rishot_signal_root/state" \
    DOTFILES_BOOTSTRAP_TESTING=1 \
    DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
    DOTFILES_BOOTSTRAP_TEST_MANAGER=pacman \
    DOTFILES_BOOTSTRAP_TEST_SATISFIED_TOOLS=herdr,visidata \
    DOTFILES_BOOTSTRAP_TEST_REAL_RISHOT_INSTALL=1 \
    DOTFILES_BOOTSTRAP_TEST_DOWNLOAD_ROOT="$rishot_fixture_download" \
    DOTFILES_BOOTSTRAP_TEST_SIGNAL_COMMAND="$rishot_signal_command" \
    DOTFILES_BOOTSTRAP_TEST_SIGNAL_TARGET="$rishot_signal_target" \
    DOTFILES_BOOTSTRAP_TEST_MANAGED_SIGNAL=TERM \
    DOTFILES_BOOTSTRAP_TEST_STOP_AFTER_PACKAGES=1 \
    "$rishot_fixture_harness/bootstrap" --apply --window-manager hypr \
    >"$rishot_signal_root/output" 2>&1 &
  rishot_signal_pid=$!
  wait "$rishot_signal_pid"
  rishot_signal_status=$?
  set -e
  if [ "$rishot_signal_status" -eq 143 ] \
    && ! kill -0 "$rishot_signal_pid" 2>/dev/null \
    && rishot_outputs_are_absent \
      "$rishot_signal_home" "$rishot_signal_tmp"; then
    pass "Rishot cleans TERM after $rishot_signal_boundary publication"
  else
    fail "Rishot cleans TERM after $rishot_signal_boundary publication"
    sed 's/^/  output: /' "$rishot_signal_root/output" >&2
  fi
done

rishot_directory_collision_home=$rishot_fixture_root/collision-directory-home
rishot_directory_collision_root=$rishot_directory_collision_home/.local/share/rishot
mkdir -p "$rishot_directory_collision_root" \
  "$rishot_directory_collision_home/.local/state/dotfiles-ownership"
printf '%s\n' sentinel >"$rishot_directory_collision_root/sentinel"
rishot_collision_before=$(project_state_fingerprint \
  "$rishot_directory_collision_home/.local")
run_rishot_case collision-directory
rishot_collision_after=$(project_state_fingerprint \
  "$rishot_directory_collision_home/.local")
if [ "$rishot_case_status" -ne 0 ] \
  && printf '%s\n' "$rishot_case_output" | grep -Fq \
    "refusing to replace existing direct-tool target: $rishot_directory_collision_root" \
  && [ "$rishot_collision_before" = "$rishot_collision_after" ] \
  && [ ! -e "$rishot_directory_collision_home/.local/bin/rishot" ] \
  && ! grep -Fq 'download ' "$rishot_case_log" \
  && rishot_transients_are_absent \
    "$rishot_case_home" "$rishot_case_tmp"; then
  pass 'Rishot preserves an occupied installation target without downloading'
else
  fail 'Rishot preserves an occupied installation target without downloading'
fi

rishot_launcher_collision_home=$rishot_fixture_root/collision-launcher-home
rishot_launcher_collision_path=$rishot_launcher_collision_home/.local/bin/rishot
mkdir -p "$rishot_launcher_collision_home/.local/bin" \
  "$rishot_launcher_collision_home/.local/state/dotfiles-ownership"
printf '%s\n' sentinel >"$rishot_launcher_collision_path"
rishot_collision_before=$(project_state_fingerprint \
  "$rishot_launcher_collision_home/.local")
run_rishot_case collision-launcher
rishot_collision_after=$(project_state_fingerprint \
  "$rishot_launcher_collision_home/.local")
if [ "$rishot_case_status" -ne 0 ] \
  && printf '%s\n' "$rishot_case_output" | grep -Fq \
    "refusing to replace existing direct-tool target: $rishot_launcher_collision_path" \
  && [ "$rishot_collision_before" = "$rishot_collision_after" ] \
  && [ ! -e "$rishot_launcher_collision_home/.local/share/rishot" ] \
  && ! grep -Fq 'download ' "$rishot_case_log" \
  && rishot_transients_are_absent \
    "$rishot_case_home" "$rishot_case_tmp"; then
  pass 'Rishot preserves an occupied launcher target without downloading'
else
  fail 'Rishot preserves an occupied launcher target without downloading'
fi

for rishot_parent_kind in local bin share; do
  rishot_parent_home=$rishot_fixture_root/parent-$rishot_parent_kind-home
  rishot_parent_outside=$rishot_fixture_root/parent-$rishot_parent_kind-outside
  mkdir -p "$rishot_parent_home" "$rishot_parent_outside"
  case "$rishot_parent_kind" in
    local)
      rishot_parent_link=$rishot_parent_home/.local
      rishot_parent_diagnostic="dotfiles ownership: unsafe directory: $rishot_parent_link"
      ;;
    bin)
      mkdir -p "$rishot_parent_home/.local"
      rishot_parent_link=$rishot_parent_home/.local/bin
      rishot_parent_diagnostic='the Rishot launcher parent must be a real directory'
      ;;
    share)
      mkdir -p "$rishot_parent_home/.local"
      rishot_parent_link=$rishot_parent_home/.local/share
      rishot_parent_diagnostic='the Rishot installation parent must be a real directory'
      ;;
  esac
  ln -s "$rishot_parent_outside" "$rishot_parent_link"
  rishot_parent_before=$(project_state_fingerprint "$rishot_parent_outside")
  run_rishot_case "parent-$rishot_parent_kind"
  rishot_parent_after=$(project_state_fingerprint "$rishot_parent_outside")
  if [ "$rishot_case_status" -ne 0 ] \
    && printf '%s\n' "$rishot_case_output" \
      | grep -Fq "$rishot_parent_diagnostic" \
    && [ "$(readlink "$rishot_parent_link")" = "$rishot_parent_outside" ] \
    && [ "$rishot_parent_before" = "$rishot_parent_after" ] \
    && ! grep -Fq 'download ' "$rishot_case_log" \
    && rishot_transients_are_absent \
      "$rishot_case_home" "$rishot_case_tmp"; then
    pass "Rishot rejects a symbolic-link $rishot_parent_kind parent before download"
  else
    fail "Rishot rejects a symbolic-link $rishot_parent_kind parent before download"
  fi
done

run_rishot_case wrong-marker
if [ "$rishot_case_status" -eq 0 ]; then
  printf '%s\n' wrong \
    >"$rishot_case_home/.local/share/rishot/.dotfiles-revision"
  rishot_wrong_marker_before=$(project_state_fingerprint \
    "$rishot_case_home/.local")
  run_rishot_case wrong-marker
  rishot_wrong_marker_after=$(project_state_fingerprint \
    "$rishot_case_home/.local")
  if [ "$rishot_case_status" -ne 0 ] \
    && printf '%s\n' "$rishot_case_output" | grep -Fq \
      "refusing to replace existing direct-tool target: $rishot_case_home/.local/share/rishot" \
    && [ "$rishot_wrong_marker_before" = "$rishot_wrong_marker_after" ] \
    && ! grep -Fq 'download ' "$rishot_case_log" \
    && rishot_transients_are_absent \
      "$rishot_case_home" "$rishot_case_tmp"; then
    pass 'Rishot refuses an installed tree with the wrong revision marker'
  else
    fail 'Rishot refuses an installed tree with the wrong revision marker'
  fi
else
  fail 'Rishot refuses an installed tree with the wrong revision marker'
fi

make_rishot_verifier_bootstrap() {
  rishot_verifier_source=$1
  rishot_verifier_target=$2
  awk '
    BEGIN { print "#!/bin/sh"; print "set -eu" }
    /^rishot_installation_is_satisfied[(][)] [{]$/ { copy = 1 }
    copy { print }
    copy && /^}$/ {
      print "rishot_installation_is_satisfied \"$1\""
      exit
    }
  ' "$rishot_verifier_source" >"$rishot_verifier_target"
  chmod 0755 "$rishot_verifier_target"
}

rishot_git_home=$rishot_fixture_root/git-home
rishot_git_root=$rishot_git_home/.local/share/rishot
rishot_git_verifier=$rishot_fixture_root/rishot-verifier
mkdir -p "$rishot_git_root/bin" "$rishot_git_root/src" \
  "$rishot_git_home/.local/bin"
printf '%s\n' '#!/bin/sh' 'exit 0' >"$rishot_git_root/bin/rishot"
chmod 0755 "$rishot_git_root/bin/rishot"
printf '%s\n' 'import QtQuick' >"$rishot_git_root/src/shell.qml"
git -C "$rishot_git_root" init -q -b main
git -C "$rishot_git_root" add bin/rishot src/shell.qml
git -C "$rishot_git_root" \
  -c user.name='Dotfiles Tests' \
  -c user.email=dotfiles-tests.invalid \
  -c commit.gpgsign=false \
  -c core.hooksPath=/dev/null \
  commit -q -m fixture
git -C "$rishot_git_root" remote add origin \
  https://github.com/Gakuseei/rishot.git
ln -s "$rishot_git_root/bin/rishot" \
  "$rishot_git_home/.local/bin/rishot"
rishot_git_revision=$(git -C "$rishot_git_root" rev-parse HEAD)
make_rishot_verifier_bootstrap \
  "$rishot_fixture_harness/bootstrap" "$rishot_git_verifier"
run_capture "$rishot_fixture_root/git-exact.output" "$test_real_env" \
  HOME="$rishot_git_home" "$rishot_git_verifier" "$rishot_git_revision"
if [ "$run_status" -eq 0 ]; then
  pass 'Rishot accepts an exact clean HTTPS-origin Git checkout'
else
  fail 'Rishot accepts an exact clean HTTPS-origin Git checkout'
fi

printf '%s\n' untracked >"$rishot_git_root/local-note"
run_capture "$rishot_fixture_root/git-untracked.output" "$test_real_env" \
  HOME="$rishot_git_home" "$rishot_git_verifier" "$rishot_git_revision"
if [ "$run_status" -eq 0 ]; then
  pass 'Rishot Git compatibility ignores untracked local files'
else
  fail 'Rishot Git compatibility ignores untracked local files'
fi

run_capture "$rishot_fixture_root/git-revision.output" "$test_real_env" \
  HOME="$rishot_git_home" "$rishot_git_verifier" \
  0000000000000000000000000000000000000000
if [ "$run_status" -ne 0 ]; then
  pass 'Rishot Git compatibility rejects the wrong revision'
else
  fail 'Rishot Git compatibility rejects the wrong revision'
fi

git -C "$rishot_git_root" remote set-url origin \
  https://example.invalid/rishot.git
run_capture "$rishot_fixture_root/git-origin.output" "$test_real_env" \
  HOME="$rishot_git_home" "$rishot_git_verifier" "$rishot_git_revision"
if [ "$run_status" -ne 0 ]; then
  pass 'Rishot Git compatibility rejects a noncanonical origin'
else
  fail 'Rishot Git compatibility rejects a noncanonical origin'
fi

git -C "$rishot_git_root" remote set-url origin \
  https://github.com/Gakuseei/rishot.git
printf '%s\n' '# dirty' >>"$rishot_git_root/bin/rishot"
run_capture "$rishot_fixture_root/git-dirty.output" "$test_real_env" \
  HOME="$rishot_git_home" "$rishot_git_verifier" "$rishot_git_revision"
if [ "$run_status" -ne 0 ]; then
  pass 'Rishot Git compatibility rejects tracked changes'
else
  fail 'Rishot Git compatibility rejects tracked changes'
fi

aerospace_brew_apply_log=$test_tmp/aerospace-brew-apply.commands
run_capture "$test_tmp/aerospace-brew-apply.output" env \
  HOME="$test_tmp/aerospace-brew-apply-home" \
  XDG_STATE_HOME="$test_tmp/aerospace-brew-apply-state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=macos \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=homebrew \
  DOTFILES_BOOTSTRAP_TEST_ALL_PACKAGES_MISSING=1 \
  DOTFILES_BOOTSTRAP_TEST_STOP_AFTER_PACKAGES=1 \
  DOTFILES_BOOTSTRAP_TEST_COMMAND_LOG="$aerospace_brew_apply_log" \
  "$bootstrap" --apply --window-manager aerospace
if [ "$run_status" -eq 0 ]; then
  pass 'Aerospace Homebrew package phase succeeds in the command harness'
else
  fail 'Aerospace Homebrew package phase succeeds in the command harness'
fi
aerospace_brew_apply_commands=$(cat "$aerospace_brew_apply_log" 2>/dev/null || true)
require_contains "$aerospace_brew_apply_commands" \
  'brew install --cask nikitabobko/tap/aerospace' \
  'Aerospace profile installs the official tap cask'
require_contains "$aerospace_brew_apply_commands" \
  'brew install --cask karabiner-elements' \
  'AeroSpace profile installs Karabiner Elements'

fixture_work=$test_tmp/fixture-work
fixture_repo=$test_tmp/fixture.git
mkdir -p \
  "$fixture_work/.codex" \
  "$fixture_work/.config" \
  "$fixture_work/.config/systemd/user" \
  "$fixture_work/Library/Application Support/com.mitchellh.ghostty" \
  "$fixture_work/Library/LaunchAgents"
mkdir -p "$fixture_work/.local/bin"
cp -R "$dotfiles_dir" "$fixture_work/.config/dotfiles"
cp "$workspace_root/.codex/hooks.json" "$fixture_work/.codex/hooks.json"
cp "$workspace_root/.local/bin/t" "$fixture_work/.local/bin/t"
cp -R \
  "$workspace_root/.config/aerospace" \
  "$workspace_root/.config/clipboard-history" \
  "$workspace_root/.config/cliphist" \
  "$workspace_root/.config/ghostty" \
  "$workspace_root/.config/herdr" \
  "$workspace_root/.config/hypr" \
  "$workspace_root/.config/i3" \
  "$workspace_root/.config/karabiner" \
  "$workspace_root/.config/launcher" \
  "$workspace_root/.config/macos" \
  "$workspace_root/.config/nvim" \
  "$fixture_work/.config/"
mkdir -p \
  "$fixture_work/.config/tmux/conf/platform" \
  "$fixture_work/.config/tmux/scripts" \
  "$fixture_work/.config/tmux/tests"
cp \
  "$workspace_root/.config/tmux/conf/keys.conf" \
  "$workspace_root/.config/tmux/conf/options.conf" \
  "$workspace_root/.config/tmux/conf/persistence.conf" \
  "$workspace_root/.config/tmux/conf/status.conf" \
  "$fixture_work/.config/tmux/conf/"
cp \
  "$workspace_root/.config/tmux/conf/platform/linux.conf" \
  "$workspace_root/.config/tmux/conf/platform/macos.conf" \
  "$fixture_work/.config/tmux/conf/platform/"
cp "$workspace_root/.config/tmux/tmux.conf" "$fixture_work/.config/tmux/tmux.conf"
cp -R "$workspace_root/.config/tmux/scripts/." "$fixture_work/.config/tmux/scripts/"
cp "$workspace_root/.config/tmux/tests/project-session.sh" \
  "$fixture_work/.config/tmux/tests/project-session.sh"
cp -R "$workspace_root/.config/systemd/user/cliphist.service.d" "$fixture_work/.config/systemd/user/"
cp "$workspace_root/.config/systemd/user/tmux-workspace.service" \
  "$fixture_work/.config/systemd/user/tmux-workspace.service"
cp "$workspace_root/Library/Application Support/com.mitchellh.ghostty/config.ghostty" \
  "$fixture_work/Library/Application Support/com.mitchellh.ghostty/config.ghostty"
cp "$workspace_root/Library/LaunchAgents/dev.ruohao.tmux-workspace.plist" \
  "$fixture_work/Library/LaunchAgents/dev.ruohao.tmux-workspace.plist"
printf '%s\n' 'fixture nvim' >"$fixture_work/.config/nvim/init.lua"
printf '%s\n' 'fixture tmux' >"$fixture_work/.config/tmux/tmux.conf"
printf '%s\n' 'fixture linux' >"$fixture_work/.config/tmux/conf/platform/linux.conf"
printf '%s\n' 'fixture macos' >"$fixture_work/.config/tmux/conf/platform/macos.conf"
printf '%s\n' 'fixture shared ghostty' >"$fixture_work/.config/ghostty/config.ghostty"
printf '%s\n' 'fixture linux ghostty' >"$fixture_work/.config/ghostty/platform-linux.ghostty"
printf '%s\n' 'fixture macos ghostty' >"$fixture_work/.config/ghostty/platform-macos.ghostty"
printf '%s\n' 'fixture macos entrypoint' \
  >"$fixture_work/Library/Application Support/com.mitchellh.ghostty/config.ghostty"
printf '%s\n' 'excluded fixture documentation' >"$fixture_work/README.md"
git -C "$fixture_work" init -q -b main
git -C "$fixture_work" config user.name 'Bootstrap Test'
git -C "$fixture_work" config user.email bootstrap-test@example.invalid
git -C "$fixture_work" add .
git -C "$fixture_work" commit -qm fixture
git clone -q --bare "$fixture_work" "$fixture_repo"

hypr_home=$test_tmp/hypr-home
hypr_state=$test_tmp/hypr-state
mkdir -p "$hypr_home/.config/hypr" "$hypr_home/.config/launcher"
printf '%s\n' 'legacy hypr config' >"$hypr_home/.config/hypr/hyprland.conf"
printf '%s\n' 'local hypr overrides' >"$hypr_home/.config/hypr/local.lua"
printf '%s\n' 'local Rofi configuration' >"$hypr_home/.config/launcher/rofi.rasi"
run_capture "$test_tmp/hypr-dry-run.output" env \
  HOME="$hypr_home" \
  XDG_STATE_HOME="$hypr_state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=pacman \
  DOTFILES_BOOTSTRAP_TEST_PREPARE_DRY_RUN=1 \
  "$bootstrap" --window-manager hypr --repo "$fixture_repo" --ref main
if [ "$run_status" -eq 0 ]; then
  pass 'Hyprland repository-aware dry-run succeeds'
else
  fail 'Hyprland repository-aware dry-run succeeds'
fi
hypr_dry_output=$(cat "$test_tmp/hypr-dry-run.output")
require_contains "$hypr_dry_output" 'conflict .config/hypr/hyprland.conf' \
  'Hyprland dry-run reports the legacy entrypoint migration'
require_contains "$hypr_dry_output" 'conflict .config/launcher/rofi.rasi' \
  'Hyprland dry-run reports a conflicting launcher configuration'
if [ "$(cat "$hypr_home/.config/hypr/hyprland.conf")" = 'legacy hypr config' ] \
  && [ "$(cat "$hypr_home/.config/launcher/rofi.rasi")" = \
    'local Rofi configuration' ] \
  && [ ! -e "$hypr_home/.cfg" ] \
  && [ ! -e "$hypr_state" ]; then
  pass 'Hyprland dry-run leaves the legacy config and state untouched'
else
  fail 'Hyprland dry-run leaves the legacy config and state untouched'
fi

run_capture "$test_tmp/hypr-apply.output" env \
  HOME="$hypr_home" \
  XDG_STATE_HOME="$hypr_state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=pacman \
  DOTFILES_BOOTSTRAP_TEST_SKIP_PACKAGES=1 \
  DOTFILES_BOOTSTRAP_TEST_RUN_ID=window-manager-hypr \
  "$bootstrap" --apply --window-manager hypr \
  --repo "$fixture_repo" --ref main
if [ "$run_status" -eq 0 ]; then
  pass 'Hyprland transactional profile apply succeeds'
else
  fail 'Hyprland transactional profile apply succeeds'
  sed 's/^/  /' "$test_tmp/hypr-apply.output" >&2
fi
hypr_run=$hypr_state/dotfiles-bootstrap/window-manager-hypr
if cmp -s "$fixture_work/.config/hypr/hyprland.lua" \
  "$hypr_home/.config/hypr/hyprland.lua" \
  && cmp -s "$fixture_work/.config/launcher/application-launcher" \
    "$hypr_home/.config/launcher/application-launcher" \
  && cmp -s "$fixture_work/.config/launcher/rofi.rasi" \
    "$hypr_home/.config/launcher/rofi.rasi" \
  && [ ! -e "$hypr_home/.config/macos/spotlight-shortcut" ] \
  && [ ! -e "$hypr_home/.config/i3/config" ] \
  && [ ! -e "$hypr_home/.config/i3/dwindle" ] \
  && [ ! -e "$hypr_home/.config/aerospace/aerospace.toml" ] \
  && [ ! -e "$hypr_home/.config/aerospace/dwindle" ]; then
  pass 'Hyprland apply deploys only the selected manager config'
else
  fail 'Hyprland apply deploys only the selected manager config'
fi
if [ ! -e "$hypr_home/.config/hypr/hyprland.conf" ] \
  && [ "$(cat "$hypr_run/backup/.config/hypr/hyprland.conf" 2>/dev/null || true)" = \
    'legacy hypr config' ]; then
  pass 'Hyprland apply automatically backs up the legacy entrypoint'
else
  fail 'Hyprland apply automatically backs up the legacy entrypoint'
fi
if [ "$(cat "$hypr_run/backup/.config/launcher/rofi.rasi" 2>/dev/null || true)" = \
    'local Rofi configuration' ]; then
  pass 'Hyprland apply automatically backs up a launcher conflict'
else
  fail 'Hyprland apply automatically backs up a launcher conflict'
fi
if [ "$(cat "$hypr_home/.config/hypr/local.lua")" = 'local hypr overrides' ]; then
  pass 'Hyprland apply preserves a preexisting machine-local override'
else
  fail 'Hyprland apply preserves a preexisting machine-local override'
fi
if [ "$(cat "$hypr_run/window-manager" 2>/dev/null || true)" = hypr ]; then
  pass 'Hyprland transaction records the selected profile'
else
  fail 'Hyprland transaction records the selected profile'
fi
run_capture "$test_tmp/hypr-rollback.output" env \
  HOME="$hypr_home" \
  XDG_STATE_HOME="$hypr_state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=pacman \
  "$bootstrap" --rollback window-manager-hypr
if [ "$run_status" -eq 0 ]; then
  pass 'Hyprland profile rollback succeeds'
else
  fail 'Hyprland profile rollback succeeds'
fi
if [ "$(cat "$hypr_home/.config/hypr/hyprland.conf" 2>/dev/null || true)" = \
    'legacy hypr config' ] \
  && [ ! -e "$hypr_home/.config/hypr/hyprland.lua" ] \
  && [ ! -e "$hypr_home/.config/launcher/application-launcher" ] \
  && [ "$(cat "$hypr_home/.config/launcher/rofi.rasi" 2>/dev/null || true)" = \
    'local Rofi configuration' ] \
  && [ "$(cat "$hypr_home/.config/hypr/local.lua")" = 'local hypr overrides' ]; then
  pass 'Hyprland rollback restores legacy config and preserves local overrides'
else
  fail 'Hyprland rollback restores legacy config and preserves local overrides'
fi

i3_home=$test_tmp/i3-home
i3_state=$test_tmp/i3-state
run_capture "$test_tmp/i3-apply.output" env \
  HOME="$i3_home" \
  XDG_STATE_HOME="$i3_state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=apt \
  DOTFILES_BOOTSTRAP_TEST_SKIP_PACKAGES=1 \
  DOTFILES_BOOTSTRAP_TEST_RUN_ID=window-manager-i3 \
  "$bootstrap" --apply --window-manager i3 \
  --repo "$fixture_repo" --ref main
if [ "$run_status" -eq 0 ]; then
  pass 'i3 transactional profile apply succeeds'
else
  fail 'i3 transactional profile apply succeeds'
  sed 's/^/  /' "$test_tmp/i3-apply.output" >&2
fi
if cmp -s "$fixture_work/.config/i3/config" "$i3_home/.config/i3/config" \
  && cmp -s "$fixture_work/.config/i3/dwindle" \
    "$i3_home/.config/i3/dwindle" \
  && [ -x "$i3_home/.config/i3/dwindle" ] \
  && [ -f "$i3_home/.config/i3/local.conf" ] \
  && [ ! -e "$i3_home/.config/hypr/hyprland.lua" ] \
  && [ ! -e "$i3_home/.config/aerospace/aerospace.toml" ] \
  && [ ! -e "$i3_home/.config/aerospace/dwindle" ]; then
  pass 'i3 apply creates its config, helper, and local override only'
else
  fail 'i3 apply creates its config, helper, and local override only'
fi
run_capture "$test_tmp/i3-rollback.output" env \
  HOME="$i3_home" \
  XDG_STATE_HOME="$i3_state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=apt \
  "$bootstrap" --rollback window-manager-i3
if [ "$run_status" -eq 0 ]; then
  pass 'i3 profile rollback succeeds'
else
  fail 'i3 profile rollback succeeds'
fi
if [ ! -e "$i3_home/.config/i3/config" ] \
  && [ ! -e "$i3_home/.config/i3/dwindle" ] \
  && [ ! -e "$i3_home/.config/i3/local.conf" ]; then
  pass 'i3 rollback removes the deployed config and generated local override'
else
  fail 'i3 rollback removes the deployed config and generated local override'
fi

aerospace_home=$test_tmp/aerospace-home
aerospace_state=$test_tmp/aerospace-state
aerospace_spotlight_state=$test_tmp/aerospace-spotlight-state
aerospace_window_drag_state=$test_tmp/aerospace-window-drag-state
mkdir -p \
  "$aerospace_home/.config/aerospace" \
  "$aerospace_home/.config/karabiner" \
  "$aerospace_spotlight_state" \
  "$aerospace_window_drag_state"
printf '%s\n' false >"$aerospace_window_drag_state/value"
printf '%s\n' 'legacy Karabiner configuration' \
  >"$aerospace_home/.config/karabiner/karabiner.json"
printf '%s\n' 'original Aerospace Spotlight shortcut' \
  >"$aerospace_spotlight_state/entry"
printf '%s\n' 'legacy aerospace config' >"$aerospace_home/.aerospace.toml"
printf '%s\n' '#!/bin/sh' 'echo local aerospace' \
  >"$aerospace_home/.config/aerospace/local.sh"
chmod 0700 "$aerospace_home/.config/aerospace/local.sh"
run_capture "$test_tmp/aerospace-apply.output" env \
  HOME="$aerospace_home" \
  XDG_STATE_HOME="$aerospace_state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=macos \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=homebrew \
  DOTFILES_BOOTSTRAP_TEST_SPOTLIGHT_STATE="$aerospace_spotlight_state" \
  DOTFILES_BOOTSTRAP_TEST_WINDOW_DRAG_STATE="$aerospace_window_drag_state" \
  DOTFILES_BOOTSTRAP_TEST_SKIP_PACKAGES=1 \
  DOTFILES_BOOTSTRAP_TEST_RUN_ID=window-manager-aerospace \
  "$bootstrap" --apply --window-manager aerospace \
  --repo "$fixture_repo" --ref main
if [ "$run_status" -eq 0 ]; then
  pass 'Aerospace transactional profile apply succeeds in the macOS simulation'
else
  fail 'Aerospace transactional profile apply succeeds in the macOS simulation'
  sed 's/^/  /' "$test_tmp/aerospace-apply.output" >&2
fi
aerospace_run=$aerospace_state/dotfiles-bootstrap/window-manager-aerospace
if [ "$(cat "$aerospace_spotlight_state/entry" 2>/dev/null || true)" = \
    '{"enabled":true,"value":{"parameters":[59,41,1179648],"type":"standard"}}' ] \
  && [ "$(cat "$aerospace_run/preferences/spotlight-shortcut/before.entry" 2>/dev/null || true)" = \
    'original Aerospace Spotlight shortcut' ] \
  && [ "$(cat "$aerospace_run/preferences/spotlight-shortcut/status" 2>/dev/null || true)" = \
    applied ]; then
  pass 'macOS apply journals and sets the native Spotlight shortcut'
else
  fail 'macOS apply journals and sets the native Spotlight shortcut'
fi
if [ "$(cat "$aerospace_window_drag_state/value" 2>/dev/null || true)" = true ] \
  && [ "$(cat "$aerospace_run/preferences/window-drag-gesture/before.value" 2>/dev/null || true)" = false ] \
  && [ -f "$aerospace_run/preferences/window-drag-gesture/before.present" ] \
  && [ "$(cat "$aerospace_run/preferences/window-drag-gesture/after.value" 2>/dev/null || true)" = true ] \
  && [ "$(cat "$aerospace_run/preferences/window-drag-gesture/status" 2>/dev/null || true)" = applied ]; then
  pass 'AeroSpace apply journals and enables the native window-drag preference'
else
  fail 'AeroSpace apply journals and enables the native window-drag preference'
fi
if cmp -s "$fixture_work/.config/aerospace/aerospace.toml" \
  "$aerospace_home/.config/aerospace/aerospace.toml" \
  && cmp -s "$fixture_work/.config/aerospace/dwindle" \
    "$aerospace_home/.config/aerospace/dwindle" \
  && cmp -s "$fixture_work/.config/karabiner/karabiner.json" \
    "$aerospace_home/.config/karabiner/karabiner.json" \
  && cmp -s "$fixture_work/.config/macos/spotlight-shortcut" \
    "$aerospace_home/.config/macos/spotlight-shortcut" \
  && cmp -s "$fixture_work/.config/macos/window-drag-gesture" \
    "$aerospace_home/.config/macos/window-drag-gesture" \
  && [ -x "$aerospace_run/preference-tools/spotlight-shortcut" ] \
  && cmp -s "$fixture_work/.config/macos/spotlight-shortcut" \
    "$aerospace_run/preference-tools/spotlight-shortcut" \
  && [ -x "$aerospace_run/preference-tools/window-drag-gesture" ] \
  && cmp -s "$fixture_work/.config/macos/window-drag-gesture" \
    "$aerospace_run/preference-tools/window-drag-gesture" \
  && [ ! -e "$aerospace_home/.config/launcher/application-launcher" ] \
  && [ -x "$aerospace_home/.config/aerospace/dwindle" ] \
  && [ ! -e "$aerospace_home/.config/hypr/hyprland.lua" ] \
  && [ ! -e "$aerospace_home/.config/i3/config" ] \
  && [ ! -e "$aerospace_home/.config/i3/dwindle" ]; then
  pass 'Aerospace apply deploys only the selected manager config'
else
  fail 'Aerospace apply deploys only the selected manager config'
fi
if [ ! -e "$aerospace_home/.aerospace.toml" ] \
  && [ "$(cat "$aerospace_run/backup/.aerospace.toml" 2>/dev/null || true)" = \
    'legacy aerospace config' ]; then
  pass 'Aerospace apply automatically backs up the legacy config location'
else
  fail 'Aerospace apply automatically backs up the legacy config location'
fi
if [ "$(cat "$aerospace_run/backup/.config/karabiner/karabiner.json" 2>/dev/null || true)" = \
    'legacy Karabiner configuration' ]; then
  pass 'AeroSpace apply backs up a conflicting Karabiner configuration'
else
  fail 'AeroSpace apply backs up a conflicting Karabiner configuration'
fi
if grep -Fq 'echo local aerospace' \
  "$aerospace_home/.config/aerospace/local.sh"; then
  pass 'Aerospace apply preserves a preexisting machine-local hook'
else
  fail 'Aerospace apply preserves a preexisting machine-local hook'
fi
require_contains "$(cat "$test_tmp/aerospace-apply.output")" \
  'open Karabiner-Elements and complete its required macOS setup' \
  'AeroSpace apply reports the manual permission step without claiming completion'

aerospace_drag_journal=$aerospace_run/preferences/window-drag-gesture
aerospace_drag_journal_saved=$aerospace_run/preferences/window-drag-gesture.saved
mv "$aerospace_drag_journal" "$aerospace_drag_journal_saved"
printf '%s\n' 'invalid window-drag journal' >"$aerospace_drag_journal"
run_capture "$test_tmp/aerospace-rollback-invalid-file.output" env \
  HOME="$aerospace_home" \
  XDG_STATE_HOME="$aerospace_state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=macos \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=homebrew \
  DOTFILES_BOOTSTRAP_TEST_SPOTLIGHT_STATE="$aerospace_spotlight_state" \
  DOTFILES_BOOTSTRAP_TEST_WINDOW_DRAG_STATE="$aerospace_window_drag_state" \
  "$bootstrap" --rollback window-manager-aerospace
if [ "$run_status" -ne 0 ]; then
  pass 'rollback rejects a regular-file window-drag preference journal'
else
  fail 'rollback rejects a regular-file window-drag preference journal'
fi
require_contains "$(cat "$test_tmp/aerospace-rollback-invalid-file.output")" \
  'bootstrap: transaction has invalid window-drag-gesture preference journal' \
  'regular-file preference preflight reports the invalid window-drag journal'
if [ "$(cat "$aerospace_run/status" 2>/dev/null || true)" = complete ] \
  && [ -d "$aerospace_home/.cfg" ] \
  && cmp -s "$fixture_work/.config/karabiner/karabiner.json" \
    "$aerospace_home/.config/karabiner/karabiner.json" \
  && [ "$(cat "$aerospace_spotlight_state/entry" 2>/dev/null || true)" = \
    '{"enabled":true,"value":{"parameters":[59,41,1179648],"type":"standard"}}' ] \
  && [ "$(cat "$aerospace_window_drag_state/value" 2>/dev/null || true)" = true ]; then
  pass 'regular-file preference preflight leaves the transaction untouched'
else
  fail 'regular-file preference preflight leaves the transaction untouched'
fi
rm "$aerospace_drag_journal"
ln -s "$aerospace_drag_journal_saved" "$aerospace_drag_journal"
run_capture "$test_tmp/aerospace-rollback-invalid-symlink.output" env \
  HOME="$aerospace_home" \
  XDG_STATE_HOME="$aerospace_state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=macos \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=homebrew \
  DOTFILES_BOOTSTRAP_TEST_SPOTLIGHT_STATE="$aerospace_spotlight_state" \
  DOTFILES_BOOTSTRAP_TEST_WINDOW_DRAG_STATE="$aerospace_window_drag_state" \
  "$bootstrap" --rollback window-manager-aerospace
if [ "$run_status" -ne 0 ]; then
  pass 'rollback rejects a symlinked window-drag preference journal'
else
  fail 'rollback rejects a symlinked window-drag preference journal'
fi
require_contains "$(cat "$test_tmp/aerospace-rollback-invalid-symlink.output")" \
  'bootstrap: unsafe rollback journal or path parents' \
  'journal preflight reports the unsafe preference symlink'
if [ "$(cat "$aerospace_run/status" 2>/dev/null || true)" = complete ] \
  && [ -d "$aerospace_home/.cfg" ] \
  && cmp -s "$fixture_work/.config/karabiner/karabiner.json" \
    "$aerospace_home/.config/karabiner/karabiner.json" \
  && [ "$(cat "$aerospace_spotlight_state/entry" 2>/dev/null || true)" = \
    '{"enabled":true,"value":{"parameters":[59,41,1179648],"type":"standard"}}' ] \
  && [ "$(cat "$aerospace_window_drag_state/value" 2>/dev/null || true)" = true ]; then
  pass 'symlink preference preflight leaves the transaction untouched'
else
  fail 'symlink preference preflight leaves the transaction untouched'
fi
rm "$aerospace_drag_journal"
mv "$aerospace_drag_journal_saved" "$aerospace_drag_journal"

rm \
  "$aerospace_home/.config/macos/spotlight-shortcut" \
  "$aerospace_home/.config/macos/window-drag-gesture"
if [ ! -e "$aerospace_home/.config/macos/spotlight-shortcut" ] \
  && [ ! -e "$aerospace_home/.config/macos/window-drag-gesture" ] \
  && [ -x "$aerospace_run/preference-tools/spotlight-shortcut" ] \
  && [ -x "$aerospace_run/preference-tools/window-drag-gesture" ]; then
  pass 'AeroSpace rollback remains independent of deployed preference helpers'
else
  fail 'AeroSpace rollback remains independent of deployed preference helpers'
fi
run_capture "$test_tmp/aerospace-rollback-interrupted-drag.output" env \
  HOME="$aerospace_home" \
  XDG_STATE_HOME="$aerospace_state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=macos \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=homebrew \
  DOTFILES_BOOTSTRAP_TEST_SPOTLIGHT_STATE="$aerospace_spotlight_state" \
  DOTFILES_BOOTSTRAP_TEST_WINDOW_DRAG_STATE="$aerospace_window_drag_state" \
  DOTFILES_BOOTSTRAP_TEST_WINDOW_DRAG_STOP_AFTER_RESTORE_WRITE=1 \
  "$bootstrap" --rollback window-manager-aerospace
if [ "$run_status" -ne 0 ]; then
  pass 'AeroSpace rollback exposes an interrupted window-drag restore'
else
  fail 'AeroSpace rollback exposes an interrupted window-drag restore'
fi
if [ "$(cat "$aerospace_run/status" 2>/dev/null || true)" = rolling-back ] \
  && [ "$(cat "$aerospace_run/preferences/window-drag-gesture/status" 2>/dev/null || true)" = preparing ] \
  && [ "$(cat "$aerospace_window_drag_state/value" 2>/dev/null || true)" = false ] \
  && [ "$(cat "$aerospace_run/preferences/spotlight-shortcut/status" 2>/dev/null || true)" = applied ] \
  && [ "$(cat "$aerospace_spotlight_state/entry" 2>/dev/null || true)" = \
    '{"enabled":true,"value":{"parameters":[59,41,1179648],"type":"standard"}}' ] \
  && [ -d "$aerospace_home/.cfg" ]; then
  pass 'AeroSpace rollback restores window drag before Spotlight and configuration'
else
  fail 'AeroSpace rollback restores window drag before Spotlight and configuration'
fi

run_capture "$test_tmp/aerospace-rollback.output" env \
  HOME="$aerospace_home" \
  XDG_STATE_HOME="$aerospace_state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=macos \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=homebrew \
  DOTFILES_BOOTSTRAP_TEST_SPOTLIGHT_STATE="$aerospace_spotlight_state" \
  DOTFILES_BOOTSTRAP_TEST_WINDOW_DRAG_STATE="$aerospace_window_drag_state" \
  "$bootstrap" --rollback window-manager-aerospace
if [ "$run_status" -eq 0 ]; then
  pass 'Aerospace profile rollback succeeds in the macOS simulation'
else
  fail 'Aerospace profile rollback succeeds in the macOS simulation'
fi
if [ "$(cat "$aerospace_home/.aerospace.toml" 2>/dev/null || true)" = \
    'legacy aerospace config' ] \
  && [ ! -e "$aerospace_home/.config/aerospace/aerospace.toml" ] \
  && [ ! -e "$aerospace_home/.config/aerospace/dwindle" ] \
  && [ "$(cat "$aerospace_home/.config/karabiner/karabiner.json" 2>/dev/null || true)" = \
    'legacy Karabiner configuration' ] \
  && [ ! -e "$aerospace_home/.config/macos/spotlight-shortcut" ] \
  && [ ! -e "$aerospace_home/.config/macos/window-drag-gesture" ] \
  && [ "$(cat "$aerospace_window_drag_state/value" 2>/dev/null || true)" = false ] \
  && [ "$(cat "$aerospace_spotlight_state/entry" 2>/dev/null || true)" = \
    'original Aerospace Spotlight shortcut' ] \
  && grep -Fq 'echo local aerospace' \
    "$aerospace_home/.config/aerospace/local.sh"; then
  pass 'Aerospace rollback restores legacy config and preserves its local hook'
else
  fail 'Aerospace rollback restores legacy config and preserves its local hook'
fi

aerospace_absent_home=$test_tmp/aerospace-absent-home
aerospace_absent_state=$test_tmp/aerospace-absent-state
aerospace_absent_spotlight_state=$test_tmp/aerospace-absent-spotlight-state
aerospace_absent_drag_state=$test_tmp/aerospace-absent-drag-state
mkdir -p "$aerospace_absent_spotlight_state" "$aerospace_absent_drag_state"
run_capture "$test_tmp/aerospace-absent-apply.output" env \
  HOME="$aerospace_absent_home" \
  XDG_STATE_HOME="$aerospace_absent_state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=macos \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=homebrew \
  DOTFILES_BOOTSTRAP_TEST_SPOTLIGHT_STATE="$aerospace_absent_spotlight_state" \
  DOTFILES_BOOTSTRAP_TEST_WINDOW_DRAG_STATE="$aerospace_absent_drag_state" \
  DOTFILES_BOOTSTRAP_TEST_SKIP_PACKAGES=1 \
  DOTFILES_BOOTSTRAP_TEST_RUN_ID=window-drag-absent \
  "$bootstrap" --apply --window-manager aerospace \
  --repo "$fixture_repo" --ref main
if [ "$run_status" -eq 0 ] \
  && [ "$(cat "$aerospace_absent_drag_state/value" 2>/dev/null || true)" = true ] \
  && [ ! -e "$aerospace_absent_state/dotfiles-bootstrap/window-drag-absent/preferences/window-drag-gesture/before.present" ]; then
  pass 'AeroSpace apply journals and enables an initially absent drag preference'
else
  fail 'AeroSpace apply journals and enables an initially absent drag preference'
fi
run_capture "$test_tmp/aerospace-absent-rollback.output" env \
  HOME="$aerospace_absent_home" \
  XDG_STATE_HOME="$aerospace_absent_state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=macos \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=homebrew \
  DOTFILES_BOOTSTRAP_TEST_SPOTLIGHT_STATE="$aerospace_absent_spotlight_state" \
  DOTFILES_BOOTSTRAP_TEST_WINDOW_DRAG_STATE="$aerospace_absent_drag_state" \
  "$bootstrap" --rollback window-drag-absent
if [ "$run_status" -eq 0 ] && [ ! -e "$aerospace_absent_drag_state/value" ]; then
  pass 'AeroSpace rollback removes an originally absent drag preference'
else
  fail 'AeroSpace rollback removes an originally absent drag preference'
fi

preference_order_home=$test_tmp/preference-order-home
preference_order_state=$test_tmp/preference-order-state
preference_order_spotlight_state=$test_tmp/preference-order-spotlight-state
preference_order_drag_state=$test_tmp/preference-order-drag-state
mkdir -p "$preference_order_spotlight_state" "$preference_order_drag_state"
printf '%s\n' 'original preference-order Spotlight shortcut' \
  >"$preference_order_spotlight_state/entry"
printf '%s\n' false >"$preference_order_drag_state/value"
run_capture "$test_tmp/preference-apply-order.output" env \
  HOME="$preference_order_home" \
  XDG_STATE_HOME="$preference_order_state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=macos \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=homebrew \
  DOTFILES_BOOTSTRAP_TEST_SPOTLIGHT_STATE="$preference_order_spotlight_state" \
  DOTFILES_BOOTSTRAP_TEST_WINDOW_DRAG_STATE="$preference_order_drag_state" \
  DOTFILES_BOOTSTRAP_TEST_WINDOW_DRAG_FAIL_WRITE=1 \
  DOTFILES_BOOTSTRAP_TEST_SKIP_PACKAGES=1 \
  DOTFILES_BOOTSTRAP_TEST_RUN_ID=preference-apply-order \
  "$bootstrap" --apply --window-manager aerospace \
  --repo "$fixture_repo" --ref main
preference_order_run=$preference_order_state/dotfiles-bootstrap/preference-apply-order
if [ "$run_status" -ne 0 ] \
  && [ "$(cat "$preference_order_run/preferences/spotlight-shortcut/status" 2>/dev/null || true)" = restored ] \
  && [ "$(cat "$preference_order_spotlight_state/entry" 2>/dev/null || true)" = \
    'original preference-order Spotlight shortcut' ] \
  && [ "$(cat "$preference_order_run/preferences/window-drag-gesture/status" 2>/dev/null || true)" = failed ] \
  && [ "$(cat "$preference_order_drag_state/value" 2>/dev/null || true)" = false ] \
  && [ "$(cat "$preference_order_run/status" 2>/dev/null || true)" = rolled-back ]; then
  pass 'AeroSpace applies Spotlight before attempting the window-drag preference'
else
  fail 'AeroSpace applies Spotlight before attempting the window-drag preference'
fi

mac_failure_home=$test_tmp/mac-failure-home
mac_failure_state=$test_tmp/mac-failure-state
mac_failure_spotlight_state=$test_tmp/mac-failure-spotlight-state
mkdir -p "$mac_failure_spotlight_state"
printf '%s\n' 'Spotlight before failed bootstrap' \
  >"$mac_failure_spotlight_state/entry"
run_capture "$test_tmp/mac-failure.output" env \
  HOME="$mac_failure_home" \
  XDG_STATE_HOME="$mac_failure_state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=macos \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=homebrew \
  DOTFILES_BOOTSTRAP_TEST_SPOTLIGHT_STATE="$mac_failure_spotlight_state" \
  DOTFILES_BOOTSTRAP_TEST_SKIP_PACKAGES=1 \
  DOTFILES_BOOTSTRAP_TEST_RUN_ID=mac-forced-failure \
  DOTFILES_BOOTSTRAP_TEST_FAIL_AFTER_CHECKOUT=1 \
  "$bootstrap" --apply --repo "$fixture_repo" --ref main
if [ "$run_status" -ne 0 ]; then
  pass 'forced macOS failure exits unsuccessfully after preference application'
else
  fail 'forced macOS failure exits unsuccessfully after preference application'
fi
if [ "$(cat "$mac_failure_spotlight_state/entry" 2>/dev/null || true)" = \
    'Spotlight before failed bootstrap' ] \
  && [ "$(cat "$mac_failure_state/dotfiles-bootstrap/mac-forced-failure/status" 2>/dev/null || true)" = \
    rolled-back ] \
  && [ ! -e "$mac_failure_home/.cfg" ]; then
  pass 'automatic rollback restores macOS preferences and deployed files'
else
  fail 'automatic rollback restores macOS preferences and deployed files'
fi

drag_failure_home=$test_tmp/drag-failure-home
drag_failure_state=$test_tmp/drag-failure-state
drag_failure_spotlight_state=$test_tmp/drag-failure-spotlight-state
drag_failure_preference_state=$test_tmp/drag-failure-preference-state
mkdir -p "$drag_failure_spotlight_state" "$drag_failure_preference_state"
printf '%s\n' false >"$drag_failure_preference_state/value"
run_capture "$test_tmp/drag-failure.output" env \
  HOME="$drag_failure_home" \
  XDG_STATE_HOME="$drag_failure_state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=macos \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=homebrew \
  DOTFILES_BOOTSTRAP_TEST_SPOTLIGHT_STATE="$drag_failure_spotlight_state" \
  DOTFILES_BOOTSTRAP_TEST_WINDOW_DRAG_STATE="$drag_failure_preference_state" \
  DOTFILES_BOOTSTRAP_TEST_SKIP_PACKAGES=1 \
  DOTFILES_BOOTSTRAP_TEST_RUN_ID=window-drag-forced-failure \
  DOTFILES_BOOTSTRAP_TEST_FAIL_AFTER_CHECKOUT=1 \
  "$bootstrap" --apply --window-manager aerospace \
  --repo "$fixture_repo" --ref main
if [ "$run_status" -ne 0 ]; then
  pass 'forced AeroSpace failure exits after applying the drag preference'
else
  fail 'forced AeroSpace failure exits after applying the drag preference'
fi
if [ "$(cat "$drag_failure_preference_state/value" 2>/dev/null || true)" = false ] \
  && [ "$(cat "$drag_failure_state/dotfiles-bootstrap/window-drag-forced-failure/status" 2>/dev/null || true)" = rolled-back ] \
  && [ ! -e "$drag_failure_home/.cfg" ] \
  && [ ! -e "$drag_failure_home/.config/karabiner/karabiner.json" ]; then
  pass 'automatic rollback restores the drag preference and Karabiner configuration'
else
  fail 'automatic rollback restores the drag preference and Karabiner configuration'
fi

mac_conflict_home=$test_tmp/mac-conflict-home
mac_conflict_state=$test_tmp/mac-conflict-state
mac_conflict_spotlight_state=$test_tmp/mac-conflict-spotlight-state
mkdir -p "$mac_conflict_spotlight_state"
printf '%s\n' 'Spotlight before conflict test' \
  >"$mac_conflict_spotlight_state/entry"
run_capture "$test_tmp/mac-conflict-apply.output" env \
  HOME="$mac_conflict_home" \
  XDG_STATE_HOME="$mac_conflict_state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=macos \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=homebrew \
  DOTFILES_BOOTSTRAP_TEST_SPOTLIGHT_STATE="$mac_conflict_spotlight_state" \
  DOTFILES_BOOTSTRAP_TEST_SKIP_PACKAGES=1 \
  DOTFILES_BOOTSTRAP_TEST_RUN_ID=mac-preference-conflict \
  "$bootstrap" --apply --repo "$fixture_repo" --ref main
printf '%s\n' 'Spotlight changed after bootstrap' \
  >"$mac_conflict_spotlight_state/entry"
run_capture "$test_tmp/mac-conflict-rollback.output" env \
  HOME="$mac_conflict_home" \
  XDG_STATE_HOME="$mac_conflict_state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=macos \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=homebrew \
  DOTFILES_BOOTSTRAP_TEST_SPOTLIGHT_STATE="$mac_conflict_spotlight_state" \
  "$bootstrap" --rollback mac-preference-conflict
if [ "$run_status" -ne 0 ]; then
  pass 'manual rollback reports a later Spotlight shortcut conflict'
else
  fail 'manual rollback reports a later Spotlight shortcut conflict'
fi
if [ "$(cat "$mac_conflict_spotlight_state/entry" 2>/dev/null || true)" = \
    'Spotlight changed after bootstrap' ]; then
  pass 'conflicted rollback preserves the later Spotlight shortcut'
else
  fail 'conflicted rollback preserves the later Spotlight shortcut'
fi
if [ "$(cat "$mac_conflict_state/dotfiles-bootstrap/mac-preference-conflict/status" 2>/dev/null || true)" = \
    complete ] \
  && [ -d "$mac_conflict_home/.cfg" ]; then
  pass 'preference conflict stops rollback before deployed files are changed'
else
  fail 'preference conflict stops rollback before deployed files are changed'
fi

drag_conflict_home=$test_tmp/drag-conflict-home
drag_conflict_state=$test_tmp/drag-conflict-state
drag_conflict_spotlight_state=$test_tmp/drag-conflict-spotlight-state
drag_conflict_preference_state=$test_tmp/drag-conflict-preference-state
mkdir -p "$drag_conflict_spotlight_state" "$drag_conflict_preference_state"
run_capture "$test_tmp/drag-conflict-apply.output" env \
  HOME="$drag_conflict_home" \
  XDG_STATE_HOME="$drag_conflict_state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=macos \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=homebrew \
  DOTFILES_BOOTSTRAP_TEST_SPOTLIGHT_STATE="$drag_conflict_spotlight_state" \
  DOTFILES_BOOTSTRAP_TEST_WINDOW_DRAG_STATE="$drag_conflict_preference_state" \
  DOTFILES_BOOTSTRAP_TEST_SKIP_PACKAGES=1 \
  DOTFILES_BOOTSTRAP_TEST_RUN_ID=window-drag-conflict \
  "$bootstrap" --apply --window-manager aerospace \
  --repo "$fixture_repo" --ref main
printf '%s\n' false >"$drag_conflict_preference_state/value"
run_capture "$test_tmp/drag-conflict-rollback.output" env \
  HOME="$drag_conflict_home" \
  XDG_STATE_HOME="$drag_conflict_state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=macos \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=homebrew \
  DOTFILES_BOOTSTRAP_TEST_SPOTLIGHT_STATE="$drag_conflict_spotlight_state" \
  DOTFILES_BOOTSTRAP_TEST_WINDOW_DRAG_STATE="$drag_conflict_preference_state" \
  "$bootstrap" --rollback window-drag-conflict
if [ "$run_status" -ne 0 ]; then
  pass 'manual rollback reports a later window-drag preference conflict'
else
  fail 'manual rollback reports a later window-drag preference conflict'
fi
if [ "$(cat "$drag_conflict_preference_state/value" 2>/dev/null || true)" = false ]; then
  pass 'conflicted rollback preserves the later window-drag preference'
else
  fail 'conflicted rollback preserves the later window-drag preference'
fi
if [ "$(cat "$drag_conflict_state/dotfiles-bootstrap/window-drag-conflict/status" 2>/dev/null || true)" = complete ] \
  && [ -d "$drag_conflict_home/.cfg" ]; then
  pass 'drag-preference conflict stops rollback before deployed files change'
else
  fail 'drag-preference conflict stops rollback before deployed files change'
fi

transaction_home=$test_tmp/transaction-home
transaction_state=$test_tmp/transaction-state
transaction_service_log=$test_tmp/transaction-service.commands
mkdir -p \
  "$transaction_home/.config/nvim" \
  "$transaction_home/.config/systemd/user" \
  "$transaction_home/.config/tmux" \
  "$transaction_home/.local/share"
printf '%s\n' 'original nvim' >"$transaction_home/.config/nvim/init.lua"
printf '%s\n' 'original service unit' \
  >"$transaction_home/.config/systemd/user/tmux-workspace.service"
printf '%s\n' 'keep local-only' >"$transaction_home/.config/nvim/local-only.lua"
printf '%s\n' 'original tmux target' >"$transaction_home/.local/share/original-tmux.conf"
ln -s "$transaction_home/.local/share/original-tmux.conf" "$transaction_home/.config/tmux/tmux.conf"
run_capture "$test_tmp/transaction-apply.output" env \
  HOME="$transaction_home" \
  XDG_STATE_HOME="$transaction_state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=apt \
  DOTFILES_BOOTSTRAP_TEST_SKIP_PACKAGES=1 \
  DOTFILES_BOOTSTRAP_TEST_RUN_ID=transaction-success \
  DOTFILES_BOOTSTRAP_TEST_SERVICE_ENABLED=true \
  DOTFILES_BOOTSTRAP_TEST_SERVICE_ACTIVE=true \
  DOTFILES_BOOTSTRAP_TEST_COMMAND_LOG="$transaction_service_log" \
  "$bootstrap" --apply --repo "$fixture_repo" --ref main
if [ "$run_status" -eq 0 ]; then
  pass 'transactional configuration apply succeeds'
else
  fail 'transactional configuration apply succeeds'
  sed 's/^/  /' "$test_tmp/transaction-apply.output" >&2
fi
transaction_service_commands=$(cat "$transaction_service_log" 2>/dev/null || true)
require_contains "$transaction_service_commands" \
  'systemctl --user daemon-reload' \
  'transactional apply reloads the systemd user manager'
require_excludes "$transaction_service_commands" \
  'systemctl --user enable tmux-workspace.service' \
  'transactional apply preserves existing workspace enablement'
require_excludes "$transaction_service_commands" \
  'systemctl --user start tmux-workspace.service' \
  'transactional apply preserves an active workspace service'
if [ -L "$transaction_home/.local/bin/tmux-workspace" ] \
  && [ "$(readlink "$transaction_home/.local/bin/tmux-workspace")" = \
    "$transaction_home/.config/tmux/scripts/workspace" ]; then
  pass 'transactional apply installs the workspace helper command link'
else
  fail 'transactional apply installs the workspace helper command link'
fi
transaction_run=$transaction_state/dotfiles-bootstrap/transaction-success
if [ "$(cat "$transaction_run/service-platform" 2>/dev/null || true)" = linux ] \
  && [ "$(cat "$transaction_run/services/tmux-workspace.service/was-installed" 2>/dev/null || true)" = true ] \
  && [ "$(cat "$transaction_run/services/tmux-workspace.service/was-enabled" 2>/dev/null || true)" = true ] \
  && [ "$(cat "$transaction_run/services/tmux-workspace.service/was-active" 2>/dev/null || true)" = true ]; then
  pass 'transaction records the previous workspace service state'
else
  fail 'transaction records the previous workspace service state'
fi
if [ "$(cat "$transaction_run/backup/.config/nvim/init.lua" 2>/dev/null || true)" = 'original nvim' ]; then
  pass 'conflicting file is automatically backed up'
else
  fail 'conflicting file is automatically backed up'
fi
if [ -L "$transaction_run/backup/.config/tmux/tmux.conf" ]; then
  pass 'conflicting symlink is backed up without dereferencing it'
else
  fail 'conflicting symlink is backed up without dereferencing it'
fi
if [ "$(cat "$transaction_home/.config/nvim/init.lua" 2>/dev/null || true)" = 'fixture nvim' ] \
  && [ ! -L "$transaction_home/.config/tmux/tmux.conf" ]; then
  pass 'selected repository configuration replaces conflicts'
else
  fail 'selected repository configuration replaces conflicts'
fi
if [ "$(cat "$transaction_home/.config/nvim/local-only.lua" 2>/dev/null || true)" = 'keep local-only' ]; then
  pass 'untracked local files under selected directories are preserved'
else
  fail 'untracked local files under selected directories are preserved'
fi
if [ "$(cat "$transaction_run/status" 2>/dev/null || true)" = complete ] \
  && [ "$(cat "$transaction_state/dotfiles-bootstrap/latest" 2>/dev/null || true)" = transaction-success ]; then
  pass 'completed transaction and latest run are journaled'
else
  fail 'completed transaction and latest run are journaled'
fi

: >"$transaction_service_log"
run_capture "$test_tmp/transaction-rollback.output" env \
  HOME="$transaction_home" \
  XDG_STATE_HOME="$transaction_state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=apt \
  DOTFILES_BOOTSTRAP_TEST_COMMAND_LOG="$transaction_service_log" \
  "$bootstrap" --rollback transaction-success
if [ "$run_status" -eq 0 ]; then
  pass 'manual rollback by run ID succeeds'
else
  fail 'manual rollback by run ID succeeds'
fi
transaction_rollback_service_commands=$(cat "$transaction_service_log" 2>/dev/null || true)
require_excludes "$transaction_rollback_service_commands" \
  'systemctl --user disable tmux-workspace.service' \
  'rollback preserves existing workspace enablement'
require_excludes "$transaction_rollback_service_commands" \
  'systemctl --user stop tmux-workspace.service' \
  'rollback preserves an already active workspace service'
require_contains "$transaction_rollback_service_commands" \
  'systemctl --user daemon-reload' \
  'rollback reloads the restored systemd user configuration'
if [ "$transaction_rollback_service_commands" = 'systemctl --user daemon-reload' ]; then
  pass 'rollback leaves pre-existing workspace service state intact'
else
  fail 'rollback leaves pre-existing workspace service state intact'
fi
if [ "$(cat "$transaction_home/.config/nvim/init.lua" 2>/dev/null || true)" = 'original nvim' ]; then
  pass 'rollback restores the original conflicting file'
else
  fail 'rollback restores the original conflicting file'
fi
if [ -L "$transaction_home/.config/tmux/tmux.conf" ] \
  && [ "$(readlink "$transaction_home/.config/tmux/tmux.conf")" = "$transaction_home/.local/share/original-tmux.conf" ]; then
  pass 'rollback restores the original symlink'
else
  fail 'rollback restores the original symlink'
fi
if [ ! -e "$transaction_home/.config/tmux/conf/platform/linux.conf" ] \
  && [ ! -e "$transaction_home/.cfg" ] \
  && [ ! -e "$transaction_home/.local/bin/tmux-workspace" ] \
  && [ "$(cat "$transaction_home/.config/systemd/user/tmux-workspace.service" 2>/dev/null || true)" = \
    'original service unit' ]; then
  pass 'rollback removes newly deployed files and repository metadata'
else
  fail 'rollback removes newly deployed files and repository metadata'
fi
if [ "$(cat "$transaction_home/.config/nvim/local-only.lua" 2>/dev/null || true)" = 'keep local-only' ]; then
  pass 'rollback preserves unrelated local files'
else
  fail 'rollback preserves unrelated local files'
fi
rollback_output=$(cat "$test_tmp/transaction-rollback.output")
require_contains "$rollback_output" 'Packages are not uninstalled' 'rollback reports that package changes are retained'

service_failure_home=$test_tmp/service-failure-home
service_failure_state=$test_tmp/service-failure-state
run_capture "$test_tmp/service-failure.output" env \
  HOME="$service_failure_home" \
  XDG_STATE_HOME="$service_failure_state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=apt \
  DOTFILES_BOOTSTRAP_TEST_SKIP_PACKAGES=1 \
  DOTFILES_BOOTSTRAP_TEST_RUN_ID=service-activation-failure \
  DOTFILES_BOOTSTRAP_TEST_SERVICE_FAIL=enable \
  "$bootstrap" --apply --repo "$fixture_repo" --ref main
if [ "$run_status" -ne 0 ]; then
  pass 'service activation failure exits unsuccessfully'
else
  fail 'service activation failure exits unsuccessfully'
fi
if [ "$(cat "$service_failure_state/dotfiles-bootstrap/service-activation-failure/status" 2>/dev/null || true)" = \
    rolled-back ] \
  && [ ! -e "$service_failure_home/.cfg" ] \
  && [ ! -e "$service_failure_home/.local/bin/tmux-workspace" ] \
  && [ ! -e "$service_failure_home/.config/systemd/user/tmux-workspace.service" ]; then
  pass 'service activation failure rolls back deployed configuration'
else
  fail 'service activation failure rolls back deployed configuration'
fi

run_capture "$test_tmp/transaction-rollback-again.output" env \
  HOME="$transaction_home" \
  XDG_STATE_HOME="$transaction_state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=apt \
  "$bootstrap" --rollback transaction-success
if [ "$run_status" -eq 0 ]; then
  pass 'repeating a completed rollback is idempotent'
else
  fail 'repeating a completed rollback is idempotent'
fi

latest_home=$test_tmp/latest-home
latest_state=$test_tmp/latest-state
run_capture "$test_tmp/latest-apply.output" env \
  HOME="$latest_home" \
  XDG_STATE_HOME="$latest_state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=apt \
  DOTFILES_BOOTSTRAP_TEST_SKIP_PACKAGES=1 \
  DOTFILES_BOOTSTRAP_TEST_RUN_ID=latest-success \
  "$bootstrap" --apply --repo "$fixture_repo" --ref main
run_capture "$test_tmp/latest-rollback.output" env \
  HOME="$latest_home" \
  XDG_STATE_HOME="$latest_state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=apt \
  "$bootstrap" --rollback latest
if [ "$run_status" -eq 0 ]; then
  pass 'rollback latest resolves and restores the newest run'
else
  fail 'rollback latest resolves and restores the newest run'
fi
if [ ! -e "$latest_home/.cfg" ] && [ ! -e "$latest_home/.config/nvim/init.lua" ]; then
  pass 'latest rollback removes files created in a fresh home'
else
  fail 'latest rollback removes files created in a fresh home'
fi

parent_home=$test_tmp/parent-home
parent_state=$test_tmp/parent-state
mkdir -p "$parent_home/.config"
printf '%s\n' 'original blocking parent' >"$parent_home/.config/tmux"
run_capture "$test_tmp/parent-apply.output" env \
  HOME="$parent_home" \
  XDG_STATE_HOME="$parent_state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=apt \
  DOTFILES_BOOTSTRAP_TEST_SKIP_PACKAGES=1 \
  DOTFILES_BOOTSTRAP_TEST_RUN_ID=parent-conflict \
  "$bootstrap" --apply --repo "$fixture_repo" --ref main
if [ "$run_status" -eq 0 ]; then
  pass 'apply backs up a non-directory parent blocking selected files'
else
  fail 'apply backs up a non-directory parent blocking selected files'
fi
if [ "$(cat "$parent_state/dotfiles-bootstrap/parent-conflict/backup/.config/tmux" 2>/dev/null || true)" = 'original blocking parent' ]; then
  pass 'blocking parent is retained in the transaction backup'
else
  fail 'blocking parent is retained in the transaction backup'
fi
run_capture "$test_tmp/parent-rollback.output" env \
  HOME="$parent_home" \
  XDG_STATE_HOME="$parent_state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=apt \
  "$bootstrap" --rollback parent-conflict
if [ "$(cat "$parent_home/.config/tmux" 2>/dev/null || true)" = 'original blocking parent' ]; then
  pass 'rollback restores a blocking parent conflict'
else
  fail 'rollback restores a blocking parent conflict'
fi

failure_home=$test_tmp/failure-home
failure_state=$test_tmp/failure-state
mkdir -p "$failure_home/.config/nvim"
printf '%s\n' 'failure original' >"$failure_home/.config/nvim/init.lua"
run_capture "$test_tmp/failure-apply.output" env \
  HOME="$failure_home" \
  XDG_STATE_HOME="$failure_state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=apt \
  DOTFILES_BOOTSTRAP_TEST_ALL_PACKAGES_MISSING=1 \
  DOTFILES_BOOTSTRAP_TEST_SATISFIED_TOOLS= \
  DOTFILES_BOOTSTRAP_TEST_APT_GHOSTTY_OFFICIAL=1 \
  DOTFILES_BOOTSTRAP_TEST_REAL_MANAGED_INSTALL=1 \
  DOTFILES_BOOTSTRAP_TEST_DOWNLOAD_ROOT="$managed_fixture_download" \
  DOTFILES_BOOTSTRAP_TEST_COMMAND_LOG="$test_tmp/failure.commands" \
  DOTFILES_BOOTSTRAP_TEST_RUN_ID=forced-failure \
  DOTFILES_BOOTSTRAP_TEST_FAIL_AFTER_CHECKOUT=1 \
  "$managed_fixture_root/bootstrap" --apply --repo "$fixture_repo" --ref main
failure_apply_output=$(cat "$test_tmp/failure-apply.output")
if [ "$run_status" -ne 0 ]; then
  pass 'a forced post-checkout failure exits unsuccessfully'
else
  fail 'a forced post-checkout failure exits unsuccessfully'
fi
if [ "$(cat "$failure_home/.config/nvim/init.lua" 2>/dev/null || true)" = 'failure original' ] \
  && [ ! -e "$failure_home/.cfg" ]; then
  pass 'failure trap automatically restores configuration and metadata'
else
  fail 'failure trap automatically restores configuration and metadata'
fi
if [ "$(cat "$failure_state/dotfiles-bootstrap/forced-failure/status" 2>/dev/null || true)" = rolled-back ]; then
  pass 'automatic rollback is recorded in the transaction journal'
else
  fail 'automatic rollback is recorded in the transaction journal'
fi
if printf '%s\n' "$failure_apply_output" \
  | grep -Fq 'Packages are not uninstalled by rollback.' \
  && retained_language_server_actions_are_present "$failure_apply_output"; then
  pass 'automatic rollback reports every retained managed language-server action'
else
  fail 'automatic rollback reports every retained managed language-server action'
fi
failure_node_directory=$failure_home/.local/opt/node-24.19.0-x86_64
failure_lua_directory=$failure_home/.local/opt/lua-language-server-3.19.1-x86_64
failure_taplo_directory=$failure_home/.local/opt/taplo-0.10.0-x86_64
failure_npm_directory=$failure_home/.local/opt/dotfiles-lsp-node-$actual_npm_lock_sha256
if [ -d "$failure_node_directory" ] \
  && [ -d "$failure_lua_directory" ] \
  && [ -d "$failure_taplo_directory" ] \
  && [ -d "$failure_npm_directory" ]; then
  pass 'configuration rollback retains managed language-tool directories'
else
  fail 'configuration rollback retains managed language-tool directories'
fi

signal_home=$test_tmp/signal-home
signal_state=$test_tmp/signal-state
mkdir -p "$signal_home/.config/nvim"
printf '%s\n' 'signal original' >"$signal_home/.config/nvim/init.lua"
run_capture "$test_tmp/signal-apply.output" env \
  HOME="$signal_home" \
  XDG_STATE_HOME="$signal_state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=apt \
  DOTFILES_BOOTSTRAP_TEST_SKIP_PACKAGES=1 \
  DOTFILES_BOOTSTRAP_TEST_RUN_ID=forced-signal \
  DOTFILES_BOOTSTRAP_TEST_SIGNAL_AFTER_CHECKOUT=TERM \
  "$bootstrap" --apply --repo "$fixture_repo" --ref main
if [ "$run_status" -eq 143 ]; then
  pass 'termination signal preserves the conventional exit status'
else
  fail 'termination signal preserves the conventional exit status'
fi
if [ "$(cat "$signal_home/.config/nvim/init.lua" 2>/dev/null || true)" = 'signal original' ] \
  && [ ! -e "$signal_home/.cfg" ]; then
  pass 'termination trap automatically restores configuration and metadata'
else
  fail 'termination trap automatically restores configuration and metadata'
fi

dry_conflict_home=$test_tmp/dry-conflict-home
dry_conflict_state=$test_tmp/dry-conflict-state
mkdir -p "$dry_conflict_home/.config/nvim"
printf '%s\n' 'dry-run conflict' >"$dry_conflict_home/.config/nvim/init.lua"
run_capture "$test_tmp/dry-conflict.output" env \
  HOME="$dry_conflict_home" \
  XDG_STATE_HOME="$dry_conflict_state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=apt \
  DOTFILES_BOOTSTRAP_TEST_PREPARE_DRY_RUN=1 \
  "$bootstrap" --repo "$fixture_repo" --ref main
if [ "$run_status" -eq 0 ]; then
  pass 'repository-aware dry-run succeeds'
else
  fail 'repository-aware dry-run succeeds'
fi
dry_conflict_output=$(cat "$test_tmp/dry-conflict.output")
require_contains "$dry_conflict_output" 'conflict .config/nvim/init.lua' 'dry-run reports an existing selected-file conflict'
if [ ! -e "$dry_conflict_home/.cfg" ] && [ ! -e "$dry_conflict_state" ]; then
  pass 'repository-aware dry-run creates no persistent repository or state data'
else
  fail 'repository-aware dry-run creates no persistent repository or state data'
fi

lifecycle_home=$test_tmp/lifecycle-home
lifecycle_state=$test_tmp/lifecycle-state
run_capture "$test_tmp/lifecycle-apply.output" env \
  HOME="$lifecycle_home" \
  XDG_STATE_HOME="$lifecycle_state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=apt \
  DOTFILES_BOOTSTRAP_TEST_SKIP_PACKAGES=1 \
  DOTFILES_BOOTSTRAP_TEST_RUN_ID=lifecycle-linux \
  "$bootstrap" --apply --repo "$fixture_repo" --ref main \
    --expected-commit "$(git --git-dir="$fixture_repo" rev-parse main)"
if [ "$run_status" -eq 0 ]; then
  pass 'Linux end-to-end sparse deployment succeeds'
else
  fail 'Linux end-to-end sparse deployment succeeds'
fi
if [ ! -e "$lifecycle_home/.config/tmux/conf/platform/macos.conf" ] \
  && [ ! -e "$lifecycle_home/Library/Application Support/com.mitchellh.ghostty/config.ghostty" ] \
  && [ ! -e "$lifecycle_home/.config/tmux/tests/project-session.sh" ] \
  && [ ! -e "$lifecycle_home/README.md" ]; then
  pass 'Linux deployment excludes macOS-only configuration and documentation'
else
  fail 'Linux deployment excludes macOS-only configuration and documentation'
fi
if [ -L "$lifecycle_home/.local/bin/dotfiles" ] \
  && [ -x "$lifecycle_home/.config/dotfiles/dotfiles" ]; then
  pass 'deployment installs the executable dotfiles command link'
else
  fail 'deployment installs the executable dotfiles command link'
fi
if [ -x "$lifecycle_home/.local/bin/t" ]; then
  pass 'deployment includes the cross-platform project launcher'
else
  fail 'deployment includes the cross-platform project launcher'
fi
run_capture "$test_tmp/lifecycle-status.output" env \
  HOME="$lifecycle_home" \
  "$lifecycle_home/.local/bin/dotfiles" status --porcelain=v1 --untracked-files=no
if [ "$run_status" -eq 0 ] && [ ! -s "$test_tmp/lifecycle-status.output" ]; then
  pass 'installed bare repository reports a clean tracked status'
else
  fail 'installed bare repository reports a clean tracked status'
fi
lifecycle_sparse_config=$(cat "$lifecycle_home/.cfg/config.worktree" 2>/dev/null || true)
lifecycle_sparse_paths=$(cat "$lifecycle_home/.cfg/info/sparse-checkout" 2>/dev/null || true)
if printf '%s\n' "$lifecycle_sparse_config" | grep -Fq 'sparseCheckoutCone = false' \
  && ! printf '%s\n' "$lifecycle_sparse_paths" | grep -Fq '.config/tmux/conf/platform/macos.conf'; then
  pass 'installed repository retains exact-file non-cone sparse selection'
else
  fail 'installed repository retains exact-file non-cone sparse selection'
fi
run_capture "$test_tmp/lifecycle-remote.output" env \
  HOME="$lifecycle_home" \
  "$lifecycle_home/.local/bin/dotfiles" remote get-url origin
if [ "$run_status" -eq 0 ] \
  && [ "$(cat "$test_tmp/lifecycle-remote.output")" = "$fixture_repo" ]; then
  pass 'installed repository retains the requested origin URL'
else
  fail 'installed repository retains the requested origin URL'
fi

mac_lifecycle_home=$test_tmp/mac-lifecycle-home
mac_lifecycle_state=$test_tmp/mac-lifecycle-state
mac_lifecycle_spotlight_state=$test_tmp/mac-lifecycle-spotlight-state
mkdir -p "$mac_lifecycle_spotlight_state"
run_capture "$test_tmp/mac-lifecycle-apply.output" env \
  HOME="$mac_lifecycle_home" \
  XDG_STATE_HOME="$mac_lifecycle_state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=macos \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=homebrew \
  DOTFILES_BOOTSTRAP_TEST_SPOTLIGHT_STATE="$mac_lifecycle_spotlight_state" \
  DOTFILES_BOOTSTRAP_TEST_SKIP_PACKAGES=1 \
  DOTFILES_BOOTSTRAP_TEST_RUN_ID=lifecycle-macos \
  "$bootstrap" --apply --repo "$fixture_repo" --ref main
if [ "$run_status" -eq 0 ]; then
  pass 'simulated macOS end-to-end sparse deployment succeeds'
else
  fail 'simulated macOS end-to-end sparse deployment succeeds'
fi
if [ "$(cat "$mac_lifecycle_spotlight_state/entry" 2>/dev/null || true)" = \
    '{"enabled":true,"value":{"parameters":[59,41,1179648],"type":"standard"}}' ]; then
  pass 'macOS none profile configures the native Spotlight shortcut'
else
  fail 'macOS none profile configures the native Spotlight shortcut'
fi
if [ "$(cat "$mac_lifecycle_home/.config/tmux/conf/platform/macos.conf" 2>/dev/null || true)" = 'fixture macos' ] \
  && [ "$(cat "$mac_lifecycle_home/Library/Application Support/com.mitchellh.ghostty/config.ghostty" 2>/dev/null || true)" = 'fixture macos entrypoint' ]; then
  pass 'macOS deployment includes macOS-only configuration'
else
  fail 'macOS deployment includes macOS-only configuration'
fi
if [ ! -e "$mac_lifecycle_home/.config/tmux/conf/platform/linux.conf" ] \
  && [ ! -e "$mac_lifecycle_home/.config/tmux/tests/project-session.sh" ] \
  && [ ! -e "$mac_lifecycle_home/README.md" ]; then
  pass 'macOS deployment excludes Linux-only configuration and documentation'
else
  fail 'macOS deployment excludes Linux-only configuration and documentation'
fi
run_capture "$test_tmp/mac-lifecycle-status.output" env \
  HOME="$mac_lifecycle_home" \
  "$mac_lifecycle_home/.local/bin/dotfiles" status --porcelain=v1 --untracked-files=no
if [ "$run_status" -eq 0 ] && [ ! -s "$test_tmp/mac-lifecycle-status.output" ]; then
  pass 'simulated macOS bare repository reports a clean tracked status'
else
  fail 'simulated macOS bare repository reports a clean tracked status'
fi

printf '%s\n' 'fixture nvim updated' >"$fixture_work/.config/nvim/init.lua"
git -C "$fixture_work" add .config/nvim/init.lua
git -C "$fixture_work" commit -qm update
git -C "$fixture_work" remote add fixture-origin "$fixture_repo"
git -C "$fixture_work" push -q fixture-origin main
run_capture "$test_tmp/lifecycle-pull.output" env \
  HOME="$lifecycle_home" \
  "$lifecycle_home/.local/bin/dotfiles" pull --ff-only
if [ "$run_status" -eq 0 ]; then
  pass 'installed bare repository supports a standard fast-forward pull'
else
  fail 'installed bare repository supports a standard fast-forward pull'
fi
if [ "$(cat "$lifecycle_home/.config/nvim/init.lua" 2>/dev/null || true)" = 'fixture nvim updated' ]; then
  pass 'fast-forward pull updates selected configuration'
else
  fail 'fast-forward pull updates selected configuration'
fi
if [ ! -e "$lifecycle_home/.config/tmux/conf/platform/macos.conf" ] \
  && [ ! -e "$lifecycle_home/README.md" ]; then
  pass 'fast-forward pull preserves Linux platform isolation'
else
  fail 'fast-forward pull preserves Linux platform isolation'
fi

standalone_bootstrap=$test_tmp/standalone-bootstrap
cp "$bootstrap" "$standalone_bootstrap"
standalone_dry_home=$test_tmp/standalone-dry-home
standalone_dry_state=$test_tmp/standalone-dry-state
run_capture "$test_tmp/standalone-dry.output" env \
  HOME="$standalone_dry_home" \
  XDG_STATE_HOME="$standalone_dry_state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=apt \
  /bin/sh "$standalone_bootstrap" --repo "$fixture_repo" --ref main
if [ "$run_status" -eq 0 ]; then
  pass 'standalone downloaded bootstrap supports dry-run'
else
  fail 'standalone downloaded bootstrap supports dry-run'
fi
standalone_dry_output=$(cat "$test_tmp/standalone-dry.output")
if printf '%s\n' "$standalone_dry_output" | grep -Fq '.config/tmux/conf/platform/linux.conf' \
  && printf '%s\n' "$standalone_dry_output" | grep -Fq 'install apt git'; then
  pass 'standalone bootstrap fetches platform and package manifests'
else
  fail 'standalone bootstrap fetches platform and package manifests'
fi

standalone_home=$test_tmp/standalone-home
standalone_state=$test_tmp/standalone-state
run_capture "$test_tmp/standalone-apply.output" env \
  HOME="$standalone_home" \
  XDG_STATE_HOME="$standalone_state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=apt \
  DOTFILES_BOOTSTRAP_TEST_SKIP_PACKAGES=1 \
  DOTFILES_BOOTSTRAP_TEST_RUN_ID=standalone-linux \
  /bin/sh "$standalone_bootstrap" --apply --repo "$fixture_repo" --ref main
if [ "$run_status" -eq 0 ]; then
  pass 'standalone downloaded bootstrap completes a bare deployment'
else
  fail 'standalone downloaded bootstrap completes a bare deployment'
fi
if [ -d "$standalone_home/.cfg" ] \
  && [ -x "$standalone_home/.local/bin/dotfiles" ] \
  && [ ! -e "$standalone_home/.config/tmux/conf/platform/macos.conf" ] \
  && [ ! -e "$standalone_home/README.md" ]; then
  pass 'standalone deployment preserves Linux platform isolation'
else
  fail 'standalone deployment preserves Linux platform isolation'
fi

package_report_home=$test_tmp/package-report-home
package_report_state=$test_tmp/package-report-state
package_report_log=$test_tmp/package-report.commands
run_capture "$test_tmp/package-report-apply.output" env \
  HOME="$package_report_home" \
  XDG_STATE_HOME="$package_report_state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=apt \
  DOTFILES_BOOTSTRAP_TEST_ALL_PACKAGES_MISSING=1 \
  DOTFILES_BOOTSTRAP_TEST_SATISFIED_TOOLS= \
  DOTFILES_BOOTSTRAP_TEST_APT_GHOSTTY_OFFICIAL=0 \
  DOTFILES_BOOTSTRAP_TEST_COMMAND_LOG="$package_report_log" \
  DOTFILES_BOOTSTRAP_TEST_RUN_ID=package-report \
  "$bootstrap" --apply --allow-community-packages --window-manager i3 \
  --repo "$fixture_repo" --ref main
if [ "$run_status" -eq 0 ]; then
  pass 'configuration transaction succeeds after simulated package installation'
else
  fail 'configuration transaction succeeds after simulated package installation'
fi
package_report=$(cat "$package_report_state/dotfiles-bootstrap/package-report/packages-retained.txt" 2>/dev/null || true)
if printf '%s\n' "$package_report" \
  | grep -Fqx 'uv-tool visidata@3.4+pyarrow@25.0.0+duckdb@1.5.5'; then
  pass 'transaction journals the exact retained data-query tool action'
else
  fail 'transaction journals the exact retained data-query tool action'
fi
if printf '%s\n' "$package_report" | grep -Fq 'apt git' \
  && printf '%s\n' "$package_report" | grep -Fq 'apt i3-wm' \
  && printf '%s\n' "$package_report" | grep -Fq 'direct neovim' \
  && printf '%s\n' "$package_report" | grep -Fq 'community ghostty' \
  && retained_language_server_actions_are_present "$package_report"; then
  pass 'transaction journals every package installation path'
else
  fail 'transaction journals every package installation path'
fi
run_capture "$test_tmp/package-report-rollback.output" env \
  HOME="$package_report_home" \
  XDG_STATE_HOME="$package_report_state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=linux \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=apt \
  "$bootstrap" --rollback package-report
package_rollback_output=$(cat "$test_tmp/package-report-rollback.output")
if printf '%s\n' "$package_rollback_output" \
  | grep -Fqx 'uv-tool visidata@3.4+pyarrow@25.0.0+duckdb@1.5.5'; then
  pass 'rollback reports the exact retained data-query tool action'
else
  fail 'rollback reports the exact retained data-query tool action'
fi
if [ "$run_status" -eq 0 ] \
  && printf '%s\n' "$package_rollback_output" | grep -Fq 'apt git' \
  && printf '%s\n' "$package_rollback_output" | grep -Fq 'apt i3-wm' \
  && printf '%s\n' "$package_rollback_output" | grep -Fq 'community ghostty' \
  && retained_language_server_actions_are_present "$package_rollback_output"; then
  pass 'rollback reports the retained package actions by name'
else
  fail 'rollback reports the retained package actions by name'
fi

karabiner_report_home=$test_tmp/karabiner-report-home
karabiner_report_state=$test_tmp/karabiner-report-state
karabiner_report_spotlight_state=$test_tmp/karabiner-report-spotlight-state
karabiner_report_drag_state=$test_tmp/karabiner-report-drag-state
karabiner_report_log=$test_tmp/karabiner-report.commands
mkdir -p "$karabiner_report_spotlight_state" "$karabiner_report_drag_state"
run_capture "$test_tmp/karabiner-report-apply.output" env \
  HOME="$karabiner_report_home" \
  XDG_STATE_HOME="$karabiner_report_state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=macos \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=homebrew \
  DOTFILES_BOOTSTRAP_TEST_ALL_PACKAGES_MISSING=1 \
  DOTFILES_BOOTSTRAP_TEST_COMMAND_LOG="$karabiner_report_log" \
  DOTFILES_BOOTSTRAP_TEST_SPOTLIGHT_STATE="$karabiner_report_spotlight_state" \
  DOTFILES_BOOTSTRAP_TEST_WINDOW_DRAG_STATE="$karabiner_report_drag_state" \
  DOTFILES_BOOTSTRAP_TEST_RUN_ID=karabiner-package-report \
  "$bootstrap" --apply --window-manager aerospace \
  --repo "$fixture_repo" --ref main
karabiner_report=$(
  cat "$karabiner_report_state/dotfiles-bootstrap/karabiner-package-report/packages-retained.txt" \
    2>/dev/null || true
)
if [ "$run_status" -eq 0 ] \
  && printf '%s\n' "$karabiner_report" \
    | grep -Fq 'homebrew-cask karabiner-elements'; then
  pass 'AeroSpace transaction journals Karabiner Elements as retained'
else
  fail 'AeroSpace transaction journals Karabiner Elements as retained'
fi
run_capture "$test_tmp/karabiner-report-rollback.output" env \
  HOME="$karabiner_report_home" \
  XDG_STATE_HOME="$karabiner_report_state" \
  DOTFILES_BOOTSTRAP_TESTING=1 \
  DOTFILES_BOOTSTRAP_TEST_PLATFORM=macos \
  DOTFILES_BOOTSTRAP_TEST_MANAGER=homebrew \
  DOTFILES_BOOTSTRAP_TEST_SPOTLIGHT_STATE="$karabiner_report_spotlight_state" \
  DOTFILES_BOOTSTRAP_TEST_WINDOW_DRAG_STATE="$karabiner_report_drag_state" \
  "$bootstrap" --rollback karabiner-package-report
karabiner_rollback_output=$(cat "$test_tmp/karabiner-report-rollback.output")
if [ "$run_status" -eq 0 ] \
  && printf '%s\n' "$karabiner_rollback_output" \
    | grep -Fq 'homebrew-cask karabiner-elements'; then
  pass 'AeroSpace rollback reports retained Karabiner Elements by name'
else
  fail 'AeroSpace rollback reports retained Karabiner Elements by name'
fi

if [ "$failures" -ne 0 ]; then
  printf '1..%d\n' "$tests"
  printf '# %d test(s) failed\n' "$failures" >&2
  exit 1
fi

printf '1..%d\n' "$tests"
printf '# all %d tests passed\n' "$tests"
