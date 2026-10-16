# shellcheck shell=sh
# Portable fixed-home coordination; embedded verbatim in standalone bootstrap.
# mkdir is the atomic lock primitive on Linux and Darwin, also used by Python.
ownership_lock_path=
ownership_lock_identity=

ownership_error() {
  printf 'dotfiles ownership: %s\n' "$1" >&2
  return 1
}

ownership_safe_directory() {
  [ ! -L "$1" ] && [ -d "$1" ] || {
    ownership_error "unsafe directory: $1"; return 1;
  }
  ownership_listing=$(LC_ALL=C ls -ldn -- "$1") || return 1
  # Filename fields may contain spaces. Only the fixed mode/UID fields matter.
  read -r ownership_permissions _ownership_link_count ownership_directory_uid _ownership_rest <<EOF
$ownership_listing
EOF
  [ "$ownership_directory_uid" = "$ownership_uid" ] || {
    ownership_error 'coordination directories must belong to the current user'; return 1;
  }
  case "$ownership_permissions" in
    ?????w*|????????w*) ownership_error 'coordination directories must not be group/world writable'; return 1 ;;
  esac
}

ownership_check_paths() {
  case "${HOME:-}" in
    /*) ;;
    *) ownership_error 'HOME must be an absolute directory'; return 1 ;;
  esac
  case "$HOME" in
    */../*|*/./*|*/..|*/.|*//*) ownership_error 'HOME must not contain traversal or empty components'; return 1 ;;
  esac
  [ "$HOME" != / ] || { ownership_error 'HOME must not be root'; return 1; }
  # Reject symlinks in the complete lexical home path, including its parents.
  ownership_ancestor=$HOME
  while [ "$ownership_ancestor" != / ]; do
    [ ! -L "$ownership_ancestor" ] || {
      ownership_error "symlinked home parent: $ownership_ancestor"; return 1;
    }
    ownership_ancestor=${ownership_ancestor%/*}
    [ -n "$ownership_ancestor" ] || ownership_ancestor=/
  done
  ownership_uid=$(id -u) || return 1
  ownership_safe_directory "$HOME" || return 1
  ownership_home=$(CDPATH='' cd -- "$HOME" && pwd -P) || return 1
  ownership_root=$ownership_home/.local/state/dotfiles-ownership
  for ownership_directory in "$ownership_home/.local" "$ownership_home/.local/state" "$ownership_root"; do
    if [ -e "$ownership_directory" ] || [ -L "$ownership_directory" ]; then
      ownership_safe_directory "$ownership_directory" || return 1
    fi
  done
  if [ -e "$ownership_root/owner.json" ] || [ -L "$ownership_root/owner.json" ]; then
    ownership_error 'Home Manager ownership metadata exists; legacy deployment is blocked'
    return 1
  fi
}

ownership_acquire() {
  ownership_check_paths || return 1
  # Create one component at a time; recheck before and after publication.
  for ownership_directory in "$ownership_home/.local" "$ownership_home/.local/state" "$ownership_root"; do
    if [ ! -e "$ownership_directory" ]; then
      (umask 077; mkdir -- "$ownership_directory") 2>/dev/null || {
        ownership_safe_directory "$ownership_directory" || return 1;
      }
    fi
    ownership_safe_directory "$ownership_directory" || return 1
  done
  ownership_candidate=$ownership_root/lock
  (umask 077; mkdir -- "$ownership_candidate") 2>/dev/null || {
    ownership_error 'another deployer holds the per-home lock'; return 1;
  }
  ownership_lock_path=$ownership_candidate
  # Keep the inode alive so a removed lock cannot be replaced with the same inode.
  exec 9< "$ownership_lock_path" || return 1
  ownership_lock_identity=$(ls -di -- "$ownership_lock_path") || return 1
  read -r ownership_lock_identity _ownership_rest <<EOF
$ownership_lock_identity
EOF
  ownership_recheck || { ownership_release; return 1; }
}

ownership_recheck() {
  ownership_check_paths || return 1
  [ -n "$ownership_lock_path" ] && [ "$ownership_lock_path" = "$ownership_root/lock" ] || {
    ownership_error 'deployment requires its held per-home lock'; return 1;
  }
  ownership_safe_directory "$ownership_lock_path" || return 1
  ownership_current_identity=$(ls -di -- "$ownership_lock_path") || return 1
  read -r ownership_current_identity _ownership_rest <<EOF
$ownership_current_identity
EOF
  [ "$ownership_current_identity" = "$ownership_lock_identity" ] || {
    ownership_error 'held lock was replaced'; return 1;
  }
}

ownership_release() {
  if [ -n "$ownership_lock_path" ] && [ ! -L "$ownership_lock_path" ] && [ -d "$ownership_lock_path" ]; then
    ownership_current_identity=$(ls -di -- "$ownership_lock_path") || return 1
    read -r ownership_current_identity _ownership_rest <<EOF
$ownership_current_identity
EOF
    if [ "$ownership_current_identity" = "$ownership_lock_identity" ]; then
      rmdir -- "$ownership_lock_path" || return 1
    fi
  fi
  exec 9<&-
  ownership_lock_path=
  ownership_lock_identity=
}
