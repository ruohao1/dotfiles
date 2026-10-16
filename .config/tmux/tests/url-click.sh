#!/bin/sh
set -eu

script_directory=$(CDPATH='' cd -P "$(dirname "$0")" && pwd -P)
helper=$script_directory/../scripts/open-url
mode=--all
[ "$#" -eq 0 ] || mode=$1
case $mode in
  --unit|--private|--copy-state|--all) ;;
  *) printf '%s\n' 'usage: url-click.sh [--unit|--private|--copy-state|--all]' >&2; exit 64 ;;
esac

# This is deliberately first: RED must prove a missing helper, not bad setup.
if [ ! -x "$helper" ]; then
  printf 'not ok - open-url helper is missing: %s\n' "$helper" >&2
  exit 1
fi

umask 077
test_root=$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-url-click.XXXXXX")
cleanup() { rm -rf "$test_root"; }
trap cleanup EXIT HUP INT TERM
fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
assert_equal() { [ "$1" = "$2" ] || fail "$3 (expected [$1], got [$2])"; }
assert_empty_file() { [ ! -s "$1" ] || fail "$2"; }

run_plain() {
  output_file=$test_root/plain.out
  error_file=$test_root/plain.err
  if printf '%s' "$1" | "$helper" --test-resolve-plain "$2" "$3" >"$output_file" 2>"$error_file"; then plain_status=0; else plain_status=$?; fi
  plain_output=$(cat "$output_file")
}
expect_plain() {
  run_plain "$1" "$2" "$3"
  assert_equal 0 "$plain_status" "$5 status"
  assert_equal "$4" "$plain_output" "$5 output"
  printf '%s\n' "$4" >"$test_root/plain.expected"
  cmp "$test_root/plain.expected" "$output_file" >/dev/null || fail "$5 exact output"
}
reject_plain() {
  run_plain "$1" "$2" "$3"
  [ "$plain_status" -ne 0 ] || fail "$4 unexpectedly resolved"
  assert_empty_file "$output_file" "$4 stdout"
}
run_osc() {
  output_file=$test_root/osc.out
  error_file=$test_root/osc.err
  if printf '%s' "$1" | "$helper" --test-resolve-osc8 "$2" >"$output_file" 2>"$error_file"; then osc_status=0; else osc_status=$?; fi
  osc_output=$(cat "$output_file")
}
expect_osc() {
  run_osc "$1" "$2"
  assert_equal 0 "$osc_status" "$4 status"
  assert_equal "$3" "$osc_output" "$4 output"
  printf '%s\n' "$3" >"$test_root/osc.expected"
  cmp "$test_root/osc.expected" "$output_file" >/dev/null || fail "$4 exact output"
}

write_fake_opener() {
  opener=$1
  cat >"$test_root/$opener" <<'EOF'
#!/bin/sh
set -eu
: "$DOTFILES_URL_CLICK_OPEN_LOG"
printf '%s\000' "$#" >>"$DOTFILES_URL_CLICK_OPEN_LOG"
for url_arg do
  printf '%s\000' "$url_arg" >>"$DOTFILES_URL_CLICK_OPEN_LOG"
done
EOF
  chmod 700 "$test_root/$opener"
}
write_fake_opener xdg-open
write_fake_opener open
cat >"$test_root/tmux" <<'EOF'
#!/bin/sh
set -eu
case $1 in
  display-message)
    if [ "$2" = -p ]; then
      case $5 in
        '#{pane_in_mode}:#{pane_mode}:#{scroll_position}') printf '%s\n' "${DOTFILES_URL_CLICK_MODE_STATE-0::}" ;;
        *) printf '%s\n' "$DOTFILES_URL_CLICK_DIMENSIONS" ;;
      esac
    else
      printf 'message:%s\n' "$4" >>"$DOTFILES_URL_CLICK_TMUX_LOG"
    fi
    ;;
  capture-pane)
    printf '%s\n' capture >>"$DOTFILES_URL_CLICK_TMUX_LOG"
    printf '%s' "$DOTFILES_URL_CLICK_CAPTURE"
    ;;
  show-options) printf '%s\n' "${DOTFILES_URL_CLICK_PLATFORM-linux}" ;;
  *) exit 1 ;;
esac
EOF
chmod 700 "$test_root/tmux"
mkdir "$test_root/missing-bin"
ln -s "$(command -v od)" "$test_root/missing-bin/od"
ln -s "$(command -v awk)" "$test_root/missing-bin/awk"
mkdir "$test_root/no-mktemp-bin"
ln -s "$test_root/tmux" "$test_root/no-mktemp-bin/tmux"
ln -s "$(command -v awk)" "$test_root/no-mktemp-bin/awk"
ln -s "$(command -v cut)" "$test_root/no-mktemp-bin/cut"

run_open() {
  : >"$test_root/open.log"
  output_file=$test_root/open.out
  error_file=$test_root/open.err
  if printf '%s' "$2" | PATH="$test_root:$PATH" DOTFILES_URL_CLICK_OPEN_LOG="$test_root/open.log" "$helper" --test-open "$1" >"$output_file" 2>"$error_file"; then open_status=0; else open_status=$?; fi
  open_stdout=$(cat "$output_file")
  open_stderr=$(cat "$error_file")
}
expect_open() {
  run_open "$1" "$2"
  assert_equal 0 "$open_status" "$3 status"
  assert_equal '' "$open_stdout" "$3 stdout"
  assert_equal '' "$open_stderr" "$3 stderr"
  printf '1\000%s\000' "$2" >"$test_root/expected.log"
  cmp "$test_root/expected.log" "$test_root/open.log" >/dev/null || fail "$3 argv"
}
reject_open() {
  run_open "$1" "$2"
  assert_equal "$3" "$open_status" "$4 status"
  assert_equal '' "$open_stdout" "$4 stdout"
  assert_empty_file "$test_root/open.log" "$4 opener log"
}

run_production() {
  : >"$test_root/tmux.log"
  : >"$test_root/open.log"
  output_file=$test_root/production.out
  error_file=$test_root/production.err
  if PATH="$test_root:$PATH" DOTFILES_URL_CLICK_TMUX_LOG="$test_root/tmux.log" DOTFILES_URL_CLICK_DIMENSIONS='80 24' DOTFILES_URL_CLICK_CAPTURE="${5-}" DOTFILES_URL_CLICK_PLATFORM="${6-linux}" DOTFILES_URL_CLICK_MODE_STATE="${7-0::}" DOTFILES_URL_CLICK_OPEN_LOG="$test_root/open.log" "$helper" --pane "$1" --x "$2" --y "$3" --hyperlink "$4" >"$output_file" 2>"$error_file"; then production_status=0; else production_status=$?; fi
  production_stdout=$(cat "$output_file")
  production_stderr=$(cat "$error_file")
}

run_mktemp_failure() {
  : >"$test_root/tmux.log"
  if PATH="$test_root/no-mktemp-bin" DOTFILES_URL_CLICK_TMUX_LOG="$test_root/tmux.log" DOTFILES_URL_CLICK_DIMENSIONS='80 24' DOTFILES_URL_CLICK_CAPTURE='' "$helper" --pane %1 --x 0 --y 0 --hyperlink 1 >"$test_root/mktemp.out" 2>"$test_root/mktemp.err"; then fail 'mktemp failure unexpectedly succeeded'; else mktemp_status=$?; fi
}

unit() {
  expect_plain '0 - prefix https://example.com/a?b=1#frag suffix' 15 0 'https://example.com/a?b=1#frag' simple
  expect_plain '0 - HTTPS://EXAMPLE.COM/A%20B' 5 0 'HTTPS://EXAMPLE.COM/A%20B' uppercase
  expect_plain '0 - http://localhost:8080/health' 10 0 'http://localhost:8080/health' localhost
  expect_plain "$(printf '%s\n%s' '-1 - prior output' '0 - https://history.example/a')" 10 0 'https://history.example/a' signed-history-prefix
  expect_plain "$(printf '%s\n%s' '-1 W https://history.example/long' '0 - suffix')" 2 0 'https://history.example/longsuffix' history-visible-wrap
  expect_plain '0 - https://[::1]:8443/a' 12 0 'https://[::1]:8443/a' ipv6
  expect_plain '0 - See https://example.test/a(b(c))?x=1#f now' 20 0 'https://example.test/a(b(c))?x=1#f' balanced
  expect_plain '0 - See https://example.test/a(b)).,! now' 20 0 'https://example.test/a(b)' trailing-prose
  wrapped=$(printf '%s\n%s' '0 W https://example.com/abcdefghij' '1 - klmnopqrstuvwxyz?x=1#frag ')
  mixed_flags=$(printf '%s\n%s' '0 - non-link target' '1 HX https://plain.example/a ')
  expect_plain "$mixed_flags" 10 1 'https://plain.example/a' mixed-OSC-screen-flags
  extended_wrap=$(printf '%s\n%s' '0 HWX https://example.com/abcdefghij' '1 HX klmnopqrstuvwxyz?x=1#frag ')
  expect_plain "$extended_wrap" 10 0 'https://example.com/abcdefghijklmnopqrstuvwxyz?x=1#frag' extended-wrap-flags
  reject_plain '0 WH https://example.com/a' 10 0 malformed-flag-order
  reject_plain '0 HH https://example.com/a' 10 0 malformed-duplicate-flag
  reject_plain '0 H-X https://example.com/a' 10 0 malformed-mixed-hyphen-flag
  all_flags=$(printf '%s\n%s' '0 DHOPWX https://example.com/abcdefghij' '1 HX klmnopqrstuvwxyz?x=1#frag ')
  expect_plain "$all_flags" 5 1 'https://example.com/abcdefghijklmnopqrstuvwxyz?x=1#frag' ordered-flags-wrap
  expect_plain "$wrapped" 10 0 'https://example.com/abcdefghijklmnopqrstuvwxyz?x=1#frag' wrapped-first-row
  expect_plain "$wrapped" 5 1 'https://example.com/abcdefghijklmnopqrstuvwxyz?x=1#frag' wrapped-second-row

  # Prefix display width is independent of UTF-8 byte length.
  plain_unicode=$(printf '0 - \347\225\214 https://plain.example/a')
  expect_plain "$plain_unicode" 8 0 'https://plain.example/a' Unicode-plain-prefix
  combining_prefix=$(printf '0 - e\314\201 https://plain.example/combining')
  expect_plain "$combining_prefix" 9 0 'https://plain.example/combining' combining-plain-prefix
  unicode_wrapped=$(printf '0 W \347\225\214 https://plain.example/abc\n1 - def ')
  expect_plain "$unicode_wrapped" 10 0 'https://plain.example/abcdef' Unicode-wrap-first-row
  expect_plain "$unicode_wrapped" 1 1 'https://plain.example/abcdef' Unicode-wrap-second-row
  invalid_utf8_plain=$(printf '0 - \377 https://plain.example/a')
  reject_plain "$invalid_utf8_plain" 8 0 invalid-UTF-8-plain
  unicode_url=$(printf '0 - https://plain.example/a\347\225\214')
  reject_plain "$unicode_url" 12 0 Unicode-inside-URL
  unicode_url_middle=$(printf '0 - https://plain.example/a\347\225\214/b')
  reject_plain "$unicode_url_middle" 12 0 Unicode-middle-of-URL

  reject_plain '0 - https:///missing-authority' 10 0 missing-authority
  reject_plain '0 - file:///tmp/nope' 10 0 file-scheme
  reject_plain '0 - ftp://example.test/a' 10 0 ftp-scheme
  reject_plain '0 - javascript:alert(1)' 10 0 javascript-scheme
  reject_plain '0 - prefix https://example.test/a' 0 0 outside-token
  reject_plain '0 - https://one.test/https://two.test/' 25 0 competing-schemes
  raw_tab=$(printf '0 - https://safe.example/a\tbad')
  raw_cr=$(printf '0 - https://safe.example/a\rbad')
  raw_other_control=$(printf '0 - https://safe.example/a\001bad')
  hard_break=$(printf '%s\n%s' '0 - https://' '1 - safe.example/a')
  reject_plain "$raw_tab" 25 0 raw-tab
  reject_plain "$raw_cr" 25 0 raw-control
  reject_plain "$raw_other_control" 25 0 raw-other-control
  reject_plain "$hard_break" 7 0 hard-line-break
  reject_plain 'bad-metadata https://example.test/a' 10 0 malformed-row-metadata
  reject_plain '--1 - https://example.test/a' 10 0 malformed-double-minus-row
  reject_plain '+1 - https://example.test/a' 10 0 malformed-plus-row
  reject_plain '-0 - https://example.test/a' 10 0 malformed-negative-zero-row
  reject_plain "$(printf '%s\n%s' '-1 - prior' '-1 - https://example.test/a')" 10 0 duplicate-negative-row
  reject_plain "$(printf '%s\n%s' '-2 W https://' '0 - example.test/a')" 10 0 discontinuous-negative-row
  reject_plain "$(printf '%s\n%s' '0 - https://one.example/a' '0 - https://two.example/b')" 10 0 duplicate-row-metadata
  reject_plain "$(printf '%s\n%s' '0 W https://' '2 - safe.example/a')" 7 0 discontinuous-row-metadata
  reject_plain "$(printf '%s\n%s' '1 W https://' '0 - safe.example/a')" 7 0 out-of-order-row-metadata
  # shellcheck disable=SC2016
  attack='https://safe.example/$(touch '"$test_root/sentinel"')'
  reject_plain "0 - $attack" 29 0 shell-shaped-whitespace
  [ ! -e "$test_root/sentinel" ] || fail 'shell-shaped plain URL executed'

  too_long=$(awk 'BEGIN { prefix = "https://example.test/"; printf "%s", prefix; for (i = length(prefix); i < 16385; i++) printf "a"; }')
  accept_limit=$(awk 'BEGIN { prefix = "https://example.test/"; printf "%s", prefix; for (i = length(prefix); i < 16384; i++) printf "a"; }')
  expect_plain "0 - $accept_limit" 10 0 "$accept_limit" max-16384
  reject_plain "0 - $too_long" 10 0 max-16385

  # shellcheck disable=SC1003
  osc_single=$(printf '\033]8;;https://osc.example/a?b=1#frag\033\\OSC-LINK\033]8;;\033\\')
  # shellcheck disable=SC1003
  osc_adjacent=$(printf '\033]8;;https://one.example/\033\\ONE\033]8;;\033\\ '; printf '\033]8;;https://two.example/\033\\TWO\033]8;;\033\\')
  # shellcheck disable=SC1003
  osc_file=$(printf '\033]8;;file:///tmp/nope\033\\FILE\033]8;;\033\\')
  osc_malformed=$(printf '\033]8;;https://broken.example/BROKEN')
  expect_osc "$osc_single" 2 'URL:https://osc.example/a?b=1#frag' osc-single
  expect_osc "$osc_adjacent" 1 'URL:https://one.example/' osc-adjacent-first
  expect_osc "$osc_adjacent" 5 'URL:https://two.example/' osc-adjacent-second

  # The four-column regression covers both cells of one wide linked glyph.
  osc_wide=$(printf 'A\033]8;;https://osc.example/wide\033\\\347\225\214\033]8;;\033\\ ')
  for x in 1 2; do
    expect_osc "$osc_wide" "$x" 'URL:https://osc.example/wide' both-wide-cells
  done
  for x in 0 3; do
    expect_osc "$osc_wide" "$x" NONE wide-label-neighbors
  done
  osc_zero=$(printf '\033]8;;https://osc.example/zero\033\\XY\033]8;;\033\\ ')
  expect_osc "$osc_zero" 0 'URL:https://osc.example/zero' zero-prefix-first-cell
  expect_osc "$osc_zero" 1 'URL:https://osc.example/zero' zero-prefix-second-cell
  expect_osc "$osc_zero" 2 NONE zero-prefix-right-neighbor
  osc_two=$(printf 'AB\033]8;;https://osc.example/two\033\\XY\033]8;;\033\\ ')
  expect_osc "$osc_two" 1 NONE two-prefix-left-neighbor
  expect_osc "$osc_two" 2 'URL:https://osc.example/two' two-prefix-first-cell
  expect_osc "$osc_two" 3 'URL:https://osc.example/two' two-prefix-second-cell
  expect_osc "$osc_two" 4 NONE two-prefix-right-neighbor
  osc_wide_prefix=$(printf '\347\225\214 \033]8;;https://osc.example/prefix\033\\XY\033]8;;\033\\ ')
  expect_osc "$osc_wide_prefix" 2 NONE wide-prefix-left-neighbor
  expect_osc "$osc_wide_prefix" 3 'URL:https://osc.example/prefix' wide-prefix-first-cell
  expect_osc "$osc_wide_prefix" 4 'URL:https://osc.example/prefix' wide-prefix-second-cell
  expect_osc "$osc_wide_prefix" 5 NONE wide-prefix-right-neighbor
  osc_combining_prefix=$(printf 'e\314\201 \033]8;;https://osc.example/combining\033\\XY\033]8;;\033\\ ')
  expect_osc "$osc_combining_prefix" 1 NONE combining-prefix-left-neighbor
  expect_osc "$osc_combining_prefix" 2 'URL:https://osc.example/combining' combining-prefix-first-cell
  expect_osc "$osc_combining_prefix" 3 'URL:https://osc.example/combining' combining-prefix-second-cell
  expect_osc "$osc_combining_prefix" 4 NONE combining-prefix-right-neighbor
  osc_adjacent_wide=$(printf ' \033]8;;https://one.example/\033\\\347\225\214\033]8;;\033\\\033]8;;https://two.example/\033\\\347\225\214\033]8;;\033\\ ')
  expect_osc "$osc_adjacent_wide" 0 NONE adjacent-wide-left-neighbor
  for x in 1 2; do expect_osc "$osc_adjacent_wide" "$x" 'URL:https://one.example/' adjacent-wide-first; done
  for x in 3 4; do expect_osc "$osc_adjacent_wide" "$x" 'URL:https://two.example/' adjacent-wide-second; done
  expect_osc "$osc_adjacent_wide" 5 NONE adjacent-wide-right-neighbor
  invalid_utf8_osc=$(printf ' \033]8;;https://osc.example/invalid\033\\\377\033]8;;\033\\ ')
  expect_osc "$invalid_utf8_osc" 1 INVALID invalid-UTF-8-OSC-label
  # shellcheck disable=SC1003
  invalid_utf8_osc_prefix=$(printf '\377 \033]8;;https://osc.example/a\033\\X\033]8;;\033\\')
  expect_osc "$invalid_utf8_osc_prefix" 2 INVALID invalid-UTF-8-OSC-prefix
  overlong_utf8_plain=$(printf '0 - \300\257 https://plain.example/a')
  reject_plain "$overlong_utf8_plain" 8 0 overlong-UTF-8-plain
  truncated_utf8_osc=$(printf ' \033]8;;https://osc.example/truncated\033\\\347\225')
  expect_osc "$truncated_utf8_osc" 1 INVALID truncated-UTF-8-OSC
  # shellcheck disable=SC1003
  invalid_target_visible_url=$(printf '\033]8;;file:///bad\033\\https://fallback.example/a\033]8;;\033\\')
  expect_osc "$invalid_target_visible_url" 10 INVALID invalid-target-no-visible-fallback
  expect_osc 'plain text' 2 NONE osc-none
  expect_osc "$osc_file" 1 INVALID osc-file
  expect_osc "$osc_malformed" 1 INVALID osc-malformed
  # shellcheck disable=SC1003
  expect_osc "$(printf '\033]8;;ftp://bad.example/\033\\HTTP\033]8;;\033\\')" 1 INVALID osc-unsupported-suppresses-visible-http

  safe='https://safe.example/a?x=one%20two'
  expect_open linux "$safe" linux-open
  expect_open macos "$safe" macos-open
  # shellcheck disable=SC2016
  inert=$(printf '%s' 'https://safe.example/$(touch$IFS'; printf '%s' "$test_root/sentinel"; printf '%s' ');'; printf '\140touch$IFS'; printf '%s' "$test_root/sentinel"; printf '\140')
  expect_open linux "$inert" shell-metacharacters-inert
  [ ! -e "$test_root/sentinel" ] || fail 'shell-shaped opener URL executed'
  reject_open linux 'file:///tmp/nope' 2 open-reject-file
  reject_open linux 'ftp://example.test/a' 2 open-reject-ftp
  reject_open linux 'javascript:alert(1)' 2 open-reject-javascript
  reject_open linux 'https://safe.example/a bad' 2 open-reject-space
  raw_tab_url=$(printf 'https://safe.example/a\tbad')
  raw_cr_url=$(printf 'https://safe.example/a\rbad')
  raw_other_control_url=$(printf 'https://safe.example/a\001bad')
  reject_open linux "$raw_tab_url" 2 open-reject-tab
  reject_open linux "$(printf 'https://safe.example/a\nbad')" 2 open-reject-lf
  reject_open linux "$raw_cr_url" 2 open-reject-cr
  reject_open linux "$raw_other_control_url" 2 open-reject-other-control
  reject_open linux 'https:///missing-authority' 2 open-reject-authority
  reject_open unknown "$safe" 1 open-unknown-platform
  assert_equal 'Could not open URL' "$open_stderr" open-unknown-platform-message

  cat >"$test_root/xdg-open" <<'EOF'
#!/bin/sh
exit 1
EOF
  chmod 700 "$test_root/xdg-open"
  run_open linux "$safe"
  assert_equal 1 "$open_status" open-failing-opener-status
  assert_equal '' "$open_stdout" open-failing-opener-stdout
  assert_equal 'Could not open URL' "$open_stderr" open-failing-opener-message
  assert_empty_file "$test_root/open.log" open-failing-opener-log

  : >"$test_root/open.log"
  if printf '%s' "$safe" | PATH="$test_root/missing-bin" DOTFILES_URL_CLICK_OPEN_LOG="$test_root/open.log" "$helper" --test-open linux >"$test_root/missing.out" 2>"$test_root/missing.err"; then fail 'open-missing-opener unexpectedly accepted'; else missing_status=$?; fi
  assert_equal 1 "$missing_status" open-missing-opener-status
  assert_empty_file "$test_root/missing.out" open-missing-opener-stdout
  assert_equal 'Could not open URL' "$(cat "$test_root/missing.err")" open-missing-opener-message
  assert_empty_file "$test_root/open.log" open-missing-opener-log

  : >"$test_root/open.log"
  if printf 'https://safe.example/a\000' | PATH="$test_root:$PATH" DOTFILES_URL_CLICK_OPEN_LOG="$test_root/open.log" "$helper" --test-open linux >"$test_root/nul.out" 2>"$test_root/nul.err"; then fail 'open-reject-nul unexpectedly accepted'; else nul_status=$?; fi
  assert_equal 2 "$nul_status" open-reject-nul-status
  assert_empty_file "$test_root/nul.out" open-reject-nul-stdout
  assert_empty_file "$test_root/open.log" open-reject-nul-opener

  : >"$test_root/open.log"
  if printf 'https://safe.example/a\n' | PATH="$test_root:$PATH" DOTFILES_URL_CLICK_OPEN_LOG="$test_root/open.log" "$helper" --test-open linux >"$test_root/trailing-lf.out" 2>"$test_root/trailing-lf.err"; then fail 'open-reject-trailing-lf unexpectedly accepted'; else trailing_lf_status=$?; fi
  assert_equal 2 "$trailing_lf_status" open-reject-trailing-lf-status
  assert_empty_file "$test_root/trailing-lf.out" open-reject-trailing-lf-stdout
  assert_empty_file "$test_root/open.log" open-reject-trailing-lf-opener

  : >"$test_root/open.log"
  if printf 'https://safe.example/a\nhttps://other.example/b' | PATH="$test_root:$PATH" DOTFILES_URL_CLICK_OPEN_LOG="$test_root/open.log" "$helper" --test-open linux >"$test_root/multiple.out" 2>"$test_root/multiple.err"; then fail 'open-reject-multiple-records unexpectedly accepted'; else multiple_status=$?; fi
  assert_equal 2 "$multiple_status" open-reject-multiple-records-status
  assert_empty_file "$test_root/multiple.out" open-reject-multiple-records-stdout
  assert_empty_file "$test_root/open.log" open-reject-multiple-records-opener

  run_production abc 0 0 0
  assert_equal 64 "$production_status" pane-missing-percent-status
  assert_empty_file "$test_root/tmux.log" pane-missing-percent-no-tmux
  run_production 12 0 0 0
  assert_equal 64 "$production_status" pane-missing-percent-digits-status
  assert_empty_file "$test_root/tmux.log" pane-missing-percent-digits-no-tmux
  run_production %1 10 0 0 '0 - https://platform.example/a' ''
  [ "$production_status" -ne 0 ] || fail 'missing production platform unexpectedly succeeded'
  assert_equal '' "$production_stdout" missing-production-platform-stdout
  assert_empty_file "$error_file" missing-production-platform-stderr
  printf 'capture\nmessage:Could not open URL\n' >"$test_root/platform.expected"
  cmp -s "$test_root/platform.expected" "$test_root/tmux.log" || fail 'missing production platform exact generic message'
  assert_empty_file "$test_root/open.log" missing-production-platform-opener
  run_production %1 10 0 0 '0 - https://platform.example/a' unknown
  assert_equal 1 "$production_status" unsupported-production-platform-status
  assert_equal '' "$production_stdout" unsupported-production-platform-stdout
  assert_empty_file "$error_file" unsupported-production-platform-stderr
  cmp -s "$test_root/platform.expected" "$test_root/tmux.log" || fail 'unsupported production platform exact generic message'
  assert_empty_file "$test_root/open.log" unsupported-production-platform-opener
  for malformed_mode in '2:copy-mode:10' '1:view-mode:0' '1:copy-mode:-1' '1:copy-mode:00' '1:copy-mode:100000001'; do
    run_production %1 10 0 0 '0 - https://mode.example/a' linux "$malformed_mode"
    assert_equal 1 "$production_status" malformed-mode-context-status
    assert_equal '' "$production_stdout" malformed-mode-context-stdout
    assert_empty_file "$error_file" malformed-mode-context-stderr
    assert_equal 'message:Could not open URL' "$(cat "$test_root/tmux.log")" malformed-mode-context-message
    assert_empty_file "$test_root/open.log" malformed-mode-context-no-opener
  done
  run_production %1 80 0 1
  assert_equal 0 "$production_status" hyperlink-outside-pane-status
  assert_equal '' "$production_stdout" hyperlink-outside-pane-stdout
  assert_equal '' "$production_stderr" hyperlink-outside-pane-stderr
  assert_empty_file "$test_root/tmux.log" hyperlink-outside-pane-no-capture
  # Apple wc pads numeric output; both geometry and capture bounds accept it.
  real_wc=$(command -v wc)
  cat >"$test_root/wc" <<EOF
#!/bin/sh
count=\$("$real_wc" "\$@") || exit 1
printf '%7s\n' "\$count"
EOF
  chmod 700 "$test_root/wc"
  printf '%s\n' "$plain_unicode" | PATH="$test_root:$PATH" "$helper" --test-resolve-plain 8 0 >"$test_root/padded-map.out" || fail 'padded-wc mapper status'
  printf '%s\n' 'https://plain.example/a' >"$test_root/padded-map.expected"
  cmp "$test_root/padded-map.expected" "$test_root/padded-map.out" >/dev/null || fail 'padded-wc mapper output'
  run_production %1 0 0 1
  assert_equal 0 "$production_status" padded-wc-capture-status
  assert_equal capture "$(cat "$test_root/tmux.log")" padded-wc-capture-invoked
  assert_equal '' "$production_stdout" padded-wc-capture-stdout
  assert_equal '' "$production_stderr" padded-wc-capture-stderr
  rm -f "$test_root/wc"

  # Capture count succeeds, then the mapper's wc emits a diagnostic and fails.
  cat >"$test_root/wc" <<EOF
#!/bin/sh
if [ -e "$test_root/wc-counted" ]; then
  printf '%s\n' 'wc: simulated read failure' >&2
  exit 1
fi
: >"$test_root/wc-counted"
exec "$real_wc" "\$@"
EOF
  chmod 700 "$test_root/wc"
  : >"$test_root/open.log"
  run_production %1 8 0 0 "$plain_unicode"
  assert_equal '' "$production_stdout" mapper-wc-failure-stdout
  assert_empty_file "$error_file" mapper-wc-failure-stderr
  assert_equal 1 "$production_status" mapper-wc-failure-status
  printf 'capture\nmessage:Could not open URL\n' >"$test_root/mapper-wc.expected"
  cmp "$test_root/mapper-wc.expected" "$test_root/tmux.log" >/dev/null || fail 'mapper-wc generic message'
  assert_empty_file "$test_root/open.log" mapper-wc-no-opener
  rm -f "$test_root/wc-counted"
  run_production %1 1 0 1 "$osc_wide"
  assert_equal '' "$production_stdout" osc-mapper-wc-failure-stdout
  assert_empty_file "$error_file" osc-mapper-wc-failure-stderr
  assert_equal 1 "$production_status" osc-mapper-wc-failure-status
  cmp "$test_root/mapper-wc.expected" "$test_root/tmux.log" >/dev/null || fail 'osc-mapper-wc generic message'
  assert_empty_file "$test_root/open.log" osc-mapper-wc-no-opener
  rm -f "$test_root/wc" "$test_root/wc-counted"

  run_mktemp_failure
  assert_equal 1 "$mktemp_status" mktemp-failure-status
  assert_empty_file "$test_root/mktemp.out" mktemp-failure-stdout
  assert_empty_file "$test_root/mktemp.err" mktemp-failure-no-tool-diagnostic
  assert_equal 'message:Could not open URL' "$(cat "$test_root/tmux.log")" mktemp-failure-generic-message
  printf 'ok - tmux Ctrl-click URL unit behavior\n'
}

# Real-server regression for shared copy-mode state. The shim delays only
# delivery of real query results, forcing overlapping helpers without changing
# any tmux commands, replies, display content, or user cursor input.
copy_state() (
  state_tmux=$(command -v tmux) || fail 'copy-state tmux missing'
  state_root=$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-tmux-url-state.XXXXXX") || fail 'copy-state scratch creation'
  python3 - "$helper" "$state_tmux" "$state_root" <<'COPY_STATE'
import os, pathlib, shutil, subprocess, sys, time
helper, tmux, parent = sys.argv[1:]
r = pathlib.Path(parent)
for name in ('bin', 'home', 'tmp'):
    (r / name).mkdir()
sock = str(r / 'state.sock')
env = os.environ.copy()
env.update(HOME=str(r / 'home'), TMPDIR=str(r / 'tmp'), TERM='xterm-256color',
           PATH=str(r / 'bin') + ':' + os.environ['PATH'])
for key in ('TMUX', 'TMUX_PANE'):
    env.pop(key, None)
(r / 'empty.conf').write_text('')
(r / 'bin' / 'tmux').write_text('''#!/usr/bin/env python3
import os, pathlib, subprocess, sys, time
r = pathlib.Path(%r)
label = os.environ.get('COPY_STATE_LABEL', '')
with (r / 'shim-pids').open('a') as f:
    f.write(str(os.getpid()) + '\\n')
p = subprocess.run([%r, '-S', %r, *sys.argv[1:]], capture_output=True)
if sys.argv[1] == 'display-message' and '-p' not in sys.argv[2:]:
    with (r / (label + '.messages')).open('ab') as f:
        f.write(sys.argv[-1].encode() + b'\\n')
if label in ('A', 'B') and any('copy_cursor_hyperlink' in a for a in sys.argv[1:]):
    (r / (label + '-query')).write_bytes(p.stdout)
    wait_for = r / ('B-query' if label == 'A' else 'A-done')
    deadline = time.monotonic() + 10
    while not wait_for.exists():
        if time.monotonic() > deadline:
            sys.exit(91)
        time.sleep(.01)
sys.stdout.buffer.write(p.stdout)
sys.stderr.buffer.write(p.stderr)
sys.exit(p.returncode)
''' % (str(r), tmux, sock))
for name in ('xdg-open', 'open'):
    (r / 'bin' / name).write_text('''#!/bin/sh
printf '%s\\000' "$#" >>"$COPY_STATE_OPEN"
for arg do printf '%s\\000' "$arg" >>"$COPY_STATE_OPEN"; done
''')
for path in (r / 'bin').iterdir():
    path.chmod(0o700)
# Twenty physical rows in 40x10: history-top is row 0; history-bottom row 10.
rows = [('\x1b]8;;https://row.example/%d\x1b\\' % i + 'L' * 40 +
         '\x1b]8;;\x1b\\').encode() for i in range(20)]
for i, url in ((5, 'https://invalid.example/é'), (6, 'https://oversized.example/' + 'x' * (16385 - len('https://oversized.example/')))):
    rows[i] = ('\x1b]8;;' + url + '\x1b\\' + 'L' * 40 + '\x1b]8;;\x1b\\').encode()
(r / 'screen').write_bytes(b'\r\n'.join(rows))
(r / 'pane.py').write_text('import os,pathlib,time\nos.write(1,pathlib.Path(%r).read_bytes())\ntime.sleep(120)\n' % str(r / 'screen'))
state_format = ('#{pane_in_mode}:#{pane_mode}:#{scroll_position}:#{copy_cursor_x}:'
                '#{copy_cursor_y}:#{selection_start_x}:#{selection_start_y}:'
                '#{selection_end_x}:#{selection_end_y}:#{selection_active}:#{selection_present}')
jobs, pids, failures = [], [], []
def t(*args, check=True):
    return subprocess.run([tmux, '-S', sock, *args], env=env, capture_output=True,
                          check=check, timeout=12)
def state():
    return t('display-message', '-p', '-t', pane, state_format).stdout

def alive(pid):
    try:
        value = subprocess.run(['ps', '-p', str(pid), '-o', 'stat='], capture_output=True).stdout.strip()
        return bool(value) and not value.startswith(b'Z')
    except ProcessLookupError:
        return False

def wait_file(name):
    deadline = time.monotonic() + 10
    while not (r / name).exists():
        if time.monotonic() > deadline:
            raise AssertionError('missing overlap barrier ' + name)
        time.sleep(.01)

def start(label, x, y, link=1):
    e = dict(env, TMUX=sock + ',' + str(server) + ',0', TMUX_PANE=pane,
             COPY_STATE_LABEL=label, COPY_STATE_OPEN=str(r / (label + '.open')))
    with (r / (label + '.out')).open('wb') as out, (r / (label + '.err')).open('wb') as err:
        p = subprocess.Popen([helper, '--pane', pane, '--x', str(x), '--y', str(y),
                              '--hyperlink', str(link)], env=e, stdout=out, stderr=err)
    jobs.append(p)
    return p

def result(label, p, url, status=0):
    rc = p.wait(timeout=12)
    actual = (r / (label + '.open')).read_bytes() if (r / (label + '.open')).exists() else b''
    expected = b'1\0' + url.encode() + b'\0' if url else b''
    messages = (r / (label + '.messages')).read_bytes() if (r / (label + '.messages')).exists() else b''
    expected_messages = b'Could not open URL\n' if status else b''
    if messages != expected_messages:
        failures.append(label + ' exact tmux message')
    if rc != status or actual != expected or (r / (label + '.out')).stat().st_size or (r / (label + '.err')).stat().st_size:
        failures.append(label + ' exact open/status/secrecy')

def preserved(label, before):
    after = state()
    if after != before:
        failures.append(label + ' state changed: ' + repr(before) + ' -> ' + repr(after))

try:
    version = t('-V').stdout.decode().split()[1].split('.')
    if (int(version[0]), int(''.join(c for c in version[1] if c.isdigit()))) < (3, 7):
        raise AssertionError('copy-state tmux 3.7 or newer required')
    pane, pane_pid = t('-f', str(r / 'empty.conf'), 'new-session', '-d', '-s', 'state',
                       '-x', '40', '-y', '10', '-P', '-F', '#{pane_id} #{pane_pid}',
                       'python3 ' + str(r / 'pane.py')).stdout.decode().split()
    server = int(t('display-message', '-p', '#{pid}').stdout)
    pids.extend((int(pane_pid), server))
    t('set-option', '-g', 'status', 'off')
    t('set-option', '-g', 'window-size', 'manual')
    t('resize-window', '-t', pane, '-x', '40', '-y', '10')
    t('set-option', '-g', '@dotfiles_platform', 'linux')
    t('set-option', '-w', '-t', pane, 'copy-mode-line-numbers', 'off')
    t('set-option', '-w', '-t', pane, 'mode-keys', 'vi')
    deadline = time.monotonic() + 5
    while b'https://row.example/10' not in t('capture-pane', '-p', '-e', '-N', '-t', pane, '-S', '0', '-E', '0').stdout:
        if time.monotonic() > deadline:
            raise AssertionError('copy-state screen not ready')
        time.sleep(.02)
    t('copy-mode', '-t', pane)
    t('send-keys', '-t', pane, '-X', 'history-top')
    before = state()
    a = start('A', 1, 1)
    wait_file('A-query')
    b = start('B', 2, 2)
    wait_file('B-query')
    result('A', a, 'https://row.example/1')
    (r / 'A-done').touch()
    result('B', b, 'https://row.example/2')
    preserved('overlapping copy helpers', before)
    for label, y in (('invalid-copy-utf8', 5), ('invalid-copy-size', 6)):
        result(label, start(label, 2, y), '')
        preserved(label, before)
    t('send-keys', '-t', pane, '-X', 'history-bottom')
    t('send-keys', '-t', pane, '-X', 'start-of-line')
    t('send-keys', '-t', pane, '-X', 'begin-selection')
    t('send-keys', '-t', pane, '-N', '3', '-X', 'cursor-right')
    before = state()
    fields = before.decode().strip().split(':')
    assert int(fields[6]) >= 10 and fields[5:7] != fields[7:9] and fields[9:] == ['1', '1'], before
    result('history-selection', start('history-selection', 1, 1), 'https://row.example/11')
    preserved('history selection', before)
    t('send-keys', '-t', pane, '-X', 'cancel')
    t('set-option', '-w', '-t', pane, 'mode-keys', 'emacs')
    t('copy-mode', '-t', pane)
    t('send-keys', '-t', pane, '-X', 'history-top')
    t('send-keys', '-t', pane, '-N', '4', '-X', 'cursor-down')
    t('send-keys', '-t', pane, '-X', 'end-of-line')
    before = state()
    assert before.decode().split(':')[3:5] == ['40', '4'], before
    result('end-cursor-other-link', start('end-cursor-other-link', 2, 1), 'https://row.example/1')
    preserved('end cursor other link', before)
    t('send-keys', '-t', pane, '-X', 'start-of-line')
    t('send-keys', '-t', pane, '-X', 'begin-selection')
    t('send-keys', '-t', pane, '-X', 'end-of-line')
    before = state()
    fields = before.decode().strip().split(':')
    assert fields[3:5] == ['40', '4'] and fields[9:] == ['1', '1'], before
    result('selected-end-other-link', start('selected-end-other-link', 2, 1), 'https://row.example/1')
    preserved('selected end cursor other link', before)
    result('covered-marker', start('covered-marker', 39, 4), '')
    preserved('covered marker', before)
    # Hook command arrays are session-scoped. Exercise a nonzero array index,
    # global inheritance, and a local empty override, without changing hooks.
    for hook in ('after-send-keys', 'after-display-message'):
        t('set-hook', '-g', hook + '[7]', 'run-shell -d 0.05 true')
        hook_before = t('show-options', '-Av', '-t', pane, hook).stdout
        assert b'run-shell' in hook_before
        before = state()
        label = 'waiting-' + hook
        result(label, start(label, 2, 1), '', status=1)
        preserved(label, before)
        assert t('show-options', '-Av', '-t', pane, hook).stdout == hook_before
        t('set-hook', '-t', pane, hook, '')
        result('local-empty-' + hook, start('local-empty-' + hook, 2, 1), 'https://row.example/1')
        preserved('local empty ' + hook, before)
        t('set-hook', '-u', '-t', pane, hook)
        t('set-hook', '-gu', hook)
finally:
    # Release only this fixture's barriers and reap helpers before the server.
    for name in ('B-query', 'A-done'):
        (r / name).touch()
    for p in jobs:
        try:
            p.wait(timeout=12)
        except subprocess.TimeoutExpired:
            p.terminate()
            p.wait(timeout=5)
    t('kill-server', check=False)
    if (r / 'shim-pids').exists():
        pids.extend(int(p) for p in (r / 'shim-pids').read_text().split())
    for pid in pids:
        deadline = time.monotonic() + 5
        while alive(pid) and time.monotonic() < deadline:
            time.sleep(.02)
        if alive(pid):
            failures.append('copy-state retained PID ' + str(pid))
    stopped = t('list-sessions', check=False).returncode != 0
    if not stopped:
        failures.append('copy-state retained server')
    if stopped and not any(alive(pid) for pid in pids):
        pathlib.Path(sock).unlink(missing_ok=True)
    if pathlib.Path(sock).exists():
        failures.append('copy-state retained socket')
    if stopped and not any(alive(pid) for pid in pids) and not pathlib.Path(sock).exists():
        shutil.rmtree(r)
    else:
        print('copy-state diagnostic root: ' + str(r), file=sys.stderr)
for failure in failures:
    print('not ok - ' + failure, file=sys.stderr)
if failures:
    sys.exit(1)
print('ok - tmux Ctrl-click URL copy-state behavior')
COPY_STATE
)

private() (
  private_root=$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-tmux-url-click.XXXXXX") || fail 'private scratch creation'
  case ${private_root##*/} in dotfiles-tmux-url-click.*) ;; *) fail 'unsafe private scratch name' ;; esac
  private_clean=0
  private_success=0
  recorder_pids=
  private_cleanup() {
    [ "$private_clean" -eq 0 ] || return 0
    private_clean=1
    cleanup_problem=0
    exec 3>&- || :
    if [ -n "${client_pid-}" ]; then kill "$client_pid" 2>/dev/null || :; wait "$client_pid" 2>/dev/null || :; fi
    for recorder_pid in $recorder_pids; do
      recorder_command=$(ps -p "$recorder_pid" -o command= 2>/dev/null || :)
      case $recorder_command in *"$private_root/recorder"*) kill "$recorder_pid" 2>/dev/null || : ;; esac
    done
    for recorder_pid in $recorder_pids; do
      retry=0
      while [ "$retry" -lt 30 ]; do
        recorder_command=$(ps -p "$recorder_pid" -o command= 2>/dev/null || :)
        case $recorder_command in *"$private_root/recorder"*) sleep 0.1; retry=$((retry + 1)) ;; *) break ;; esac
      done
      case $recorder_command in
        *"$private_root/recorder"*) printf 'not ok - private cleanup retained recorder PID %s in %s\n' "$recorder_pid" "$private_root" >&2; cleanup_problem=1 ;;
      esac
    done
    if [ -S "$private_root/new.sock" ]; then
      "$feature_tmux" -S "$private_root/new.sock" kill-server >/dev/null 2>&1 || :
    fi
    if [ -n "${server_pid-}" ]; then
      retry=0
      while [ "$retry" -lt 30 ]; do
        server_state=$(ps -p "$server_pid" -o stat= 2>/dev/null || :)
        case $server_state in ''|Z*) break ;; esac
        sleep 0.1; retry=$((retry + 1))
      done
      case $server_state in
        ''|Z*) ;;
        *) printf 'not ok - private cleanup retained server PID %s (%s) in %s\n' "$server_pid" "$server_state" "$private_root" >&2; cleanup_problem=1 ;;
      esac
    fi
    retry=0
    while [ "$retry" -lt 30 ]; do
      [ ! -S "$private_root/new.sock" ] && break
      sleep 0.1; retry=$((retry + 1))
    done
    socket_path=$private_root/new.sock
    if [ -S "$socket_path" ]; then
      if "$feature_tmux" -S "$socket_path" list-sessions >/dev/null 2>&1; then
        printf 'not ok - private cleanup retained active socket %s\n' "$socket_path" >&2
        cleanup_problem=1
      else
        rm -f -- "$socket_path"
      fi
    fi
    if [ -S "$private_root/new.sock" ]; then
      printf 'not ok - private cleanup retained socket %s\n' "$private_root/new.sock" >&2
      cleanup_problem=1
    fi
    cd /
    if command -v fuser >/dev/null 2>&1; then
      references=$(fuser "$private_root" 2>/dev/null || :)
      if [ -n "$references" ]; then
        printf 'not ok - private cleanup retained process references %s in %s\n' "$references" "$private_root" >&2
        cleanup_problem=1
      fi
    fi
    [ "$cleanup_problem" -eq 0 ] || return 1
    [ "$private_success" -eq 1 ] || { printf "private diagnostic root: %s\n" "$private_root" >&2; return 0; }
    case $private_root in "${TMPDIR:-/tmp}"/dotfiles-tmux-url-click.*) rm -rf -- "$private_root" ;; *) return 1 ;; esac
  }
  trap private_cleanup EXIT
  trap 'exit 1' HUP INT TERM
  feature_tmux=$(command -v tmux) || fail 'private tmux missing from PATH'
  command -v python3 >/dev/null 2>&1 || fail 'private recorder requires python3'
  command -v script >/dev/null 2>&1 || fail 'private PTY client requires script'
  private_version=$($feature_tmux -V) || fail 'private tmux version unavailable'
  printf '%s\n' "$private_version" | awk '
    /^tmux [0-9]+[.][0-9]+/ {
      split($2, parts, /[.]/)
      if (parts[1] > 3 || (parts[1] == 3 && parts[2] + 0 >= 7)) valid = 1
    }
    END { exit !valid }
  ' || fail 'private tmux 3.7 or newer required'
  private_home=$private_root/home
  mkdir -p "$private_home/.config" "$private_root/state" "$private_root/cache" "$private_root/runtime" "$private_root/bin"
  cp -R "$script_directory/.." "$private_home/.config/tmux"
  cmp -s "$script_directory/../tmux.conf" "$private_home/.config/tmux/tmux.conf" || fail 'private config copy differs'
  cmp -s "$script_directory/../conf/keys.conf" "$private_home/.config/tmux/conf/keys.conf" || fail 'private bindings copy differs'
  private_conf=$private_home/.config/tmux/tmux.conf
  DOTFILES_URL_CLICK_REAL_HELPER=$helper
  DOTFILES_URL_CLICK_HELPER_LOG=$private_root/helper.log
  DOTFILES_URL_CLICK_CONTEXT_LOG=$private_root/context.log
  export DOTFILES_URL_CLICK_REAL_HELPER DOTFILES_URL_CLICK_HELPER_LOG DOTFILES_URL_CLICK_CONTEXT_LOG
  : >"$DOTFILES_URL_CLICK_HELPER_LOG"
  cat >"$private_home/.config/tmux/scripts/open-url" <<'HELPER_WRAPPER'
#!/bin/sh
set -eu
printf 'start\n' >>"$DOTFILES_URL_CLICK_HELPER_LOG"
printf 'context:%s:%s:%s:%s\n' "$2" "$4" "$6" "$8" >>"$DOTFILES_URL_CLICK_CONTEXT_LOG"
if "$DOTFILES_URL_CLICK_REAL_HELPER" "$@"; then helper_status=0; else helper_status=$?; fi
printf 'done:%s\n' "$helper_status" >>"$DOTFILES_URL_CLICK_HELPER_LOG"
exit "$helper_status"
HELPER_WRAPPER
  chmod 700 "$private_home/.config/tmux/scripts/open-url"
  cat >"$private_root/bin/xdg-open" <<'OPENER'
#!/bin/sh
set -eu
printf '%s\000' "$#" >>"$DOTFILES_URL_CLICK_OPEN_LOG"
for argument do printf '%s\000' "$argument" >>"$DOTFILES_URL_CLICK_OPEN_LOG"; done
OPENER
  cp "$private_root/bin/xdg-open" "$private_root/bin/open"
  chmod 700 "$private_root/bin/xdg-open" "$private_root/bin/open"
  HOME=$private_home; XDG_STATE_HOME=$private_root/state; XDG_CACHE_HOME=$private_root/cache; XDG_RUNTIME_DIR=$private_root/runtime
  export HOME XDG_STATE_HOME XDG_CACHE_HOME XDG_RUNTIME_DIR
  DOTFILES_URL_CLICK_OPEN_LOG=$private_root/open.log; export DOTFILES_URL_CLICK_OPEN_LOG
  PATH="$private_root/bin:$PATH"; export PATH
  unset TMUX TMUX_PANE
  : >"$DOTFILES_URL_CLICK_OPEN_LOG"
  cat >"$private_root/recorder" <<'RECORDER'
#!/usr/bin/env python3
import os
import sys
import tty

fixture = sys.argv[1]
tty.setraw(0)
with open(fixture + ".pid", "w", encoding="ascii") as pid_file:
    pid_file.write(str(os.getpid()))
with open(fixture, "rb") as screen_file:
    screen = screen_file.read()
os.write(1, b"\x1b[H\x1b[2J" + screen + b"\x1b[?1000h\x1b[?1002h\x1b[?1006h")
with open(fixture + ".mouse", "ab", buffering=0) as mouse_file:
    while True:
        chunk = os.read(0, 4096)
        if not chunk:
            break
        mouse_file.write(chunk)
RECORDER
  chmod 700 "$private_root/recorder"
  # Keep the URL unbroken in the input stream; tmux supplies the soft wrap.
  {
    printf 'non-link target\r\nhttps://plain.example/abcdefghijklmnopqrstuvwxyz?x=1#z\r\n'
    printf '\033]8;;https://osc.example/a?b=1#frag\033\\https://visible.invalid/path\033]8;;\033\\\r\n'
    printf 'plain mouse target\r\n'
    printf '\033]8;;https:///bad\033\\https://fallback.example/a\033]8;;\033\\\r\n'
    printf '\033]8;;file:///bad\033\\https://fallback.example/b\033]8;;\033\\\r\n'
  } >"$private_root/base.screen"
  {
    printf '\347\225\214 https://plain.example/a\r\n'
    printf 'e\314\201 https://plain.example/combining\r\n'
    printf '\347\225\214 https://plain.example/abcdefghijklmnopqrstuvwxyz\r\n'
    printf 'A\033]8;;https://osc.example/wide\033\\\347\225\214\033]8;;\033\\ \r\n'
    printf '\033]8;;https://osc.example/zero\033\\XY\033]8;;\033\\ \r\n'
    printf 'AB\033]8;;https://osc.example/two\033\\XY\033]8;;\033\\ \r\n'
    printf '\347\225\214 \033]8;;https://osc.example/prefix\033\\XY\033]8;;\033\\ \r\n'
    printf 'e\314\201 \033]8;;https://osc.example/combining\033\\XY\033]8;;\033\\ \r\n'
    printf ' \033]8;;https://one.example/\033\\\347\225\214\033]8;;\033\\\033]8;;https://two.example/\033\\\347\225\214\033]8;;\033\\ '
  } >"$private_root/unicode.screen"
  printf 'https://left.test/a\r\nhttps://left.test/b\r\n' >"$private_root/left.screen"
  printf 'https://right.test/a\r\nplain right target\r\n' >"$private_root/right.screen"
  {
    row=0
    while [ "$row" -lt 14 ]; do
      printf 'prior output %02d\r\n' "$row"
      row=$((row + 1))
    done
    printf 'https://history-visible.example/a'
  } >"$private_root/history.screen"
  {
    printf 'https://shown.example/abcdefghijklmnopq\r\n'
    printf ' \033]8;;https://shown.example/osc\033\\MODE\033]8;;\033\\\r\n'
    printf ' \033]8;;file:///bad\033\\BAD\033]8;;\033\\\r\n'
    printf 'A\033]8;;https://shown.example/wide\033\\\347\225\214\033]8;;\033\\ \r\n'
    printf 'https://shown.example/abcdefghijklmnopqr\r\n'
    row=5
    while [ "$row" -lt 10 ]; do printf 'shown filler %02d\r\n' "$row"; row=$((row + 1)); done
    printf 'https://hidden.example/plain\r\n'
    printf ' \033]8;;https://hidden.example/osc\033\\BASE\033]8;;\033\\\r\n'
    printf 'A\033]8;;https://hidden.example/wide\033\\\347\225\214\033]8;;\033\\ \r\n'
    row=13
    while [ "$row" -lt 19 ]; do printf 'hidden filler %02d\r\n' "$row"; row=$((row + 1)); done
    printf 'hidden filler 19'
  } >"$private_root/copy.screen"

  "$feature_tmux" -S "$private_root/new.sock" -f "$private_conf" new-session -d -s urltest -x 40 -y 10 "$private_root/recorder $private_root/base.screen" || fail 'feature private server start'
  server_pid=$($feature_tmux -S "$private_root/new.sock" display-message -p '#{pid}')
  case $server_pid in ''|*[!0-9]*) fail 'private server PID unavailable' ;; esac
  "$feature_tmux" -S "$private_root/new.sock" set-option -g status off
  "$feature_tmux" -S "$private_root/new.sock" set-option -g window-size manual
  "$feature_tmux" -S "$private_root/new.sock" resize-window -t urltest:1 -x 40 -y 10
  retry=0
  while [ "$retry" -lt 50 ]; do
    foundation_loaded=$($feature_tmux -S "$private_root/new.sock" show-options -gqv @dotfiles_foundation_loaded)
    [ "$foundation_loaded" = 1 ] && break
    sleep 0.1; retry=$((retry + 1))
  done
  [ "$foundation_loaded" = 1 ] || fail 'private foundation did not load'
  keys=$($feature_tmux -S "$private_root/new.sock" list-keys -T root)
  down_key=$(printf '%s\n' "$keys" | grep 'C-MouseDown1Pane' || :)
  up_key=$(printf '%s\n' "$keys" | grep 'C-MouseUp1Pane' || :)
  case $down_key in *'send-keys -M'*) ;; *) fail 'private URL Ctrl-down route missing' ;; esac
  case $down_key in *swap-pane*) fail 'private URL Ctrl-down swaps panes' ;; esac
  case $up_key in *'send-keys -M'*'run-shell -b'*'open-url'*'#{?mouse_hyperlink,1,0}'*) ;; *) fail 'private URL Ctrl-up route missing' ;; esac
  case $up_key in *'#{mouse_hyperlink}'*|*'#{mouse_word}'*) fail 'private URL route expands untrusted mouse data' ;; esac

  mkfifo "$private_root/client.fifo"
  attach_command="$feature_tmux -S $private_root/new.sock attach-session -t urltest"
  case $(uname -s) in
    Linux)
      env TERM=xterm-256color script -qefc \
        "$attach_command" /dev/null \
        <"$private_root/client.fifo" >"$private_root/client.stdout" 2>"$private_root/client.stderr" &
      ;;
    Darwin)
      env TERM=xterm-256color script -q /dev/null \
        /bin/sh -c "$attach_command" \
        <"$private_root/client.fifo" >"$private_root/client.stdout" 2>"$private_root/client.stderr" &
      ;;
    *) fail 'unsupported private-client platform' ;;
  esac
  client_pid=$!
  exec 3>"$private_root/client.fifo"
  main_pane=$($feature_tmux -S "$private_root/new.sock" display-message -p -t urltest:1.1 '#{pane_id}')
  wait_screen() {
    expected=$1; pane=$2
    retry=0
    while [ "$retry" -lt 50 ]; do
      captured=$($feature_tmux -S "$private_root/new.sock" capture-pane -p -t "$pane" -S 0 -E 9 2>/dev/null || :)
      case $captured in *"$expected"*) return 0 ;; esac
      sleep 0.1; retry=$((retry + 1))
    done
    fail "private screen not ready: $expected"
  }
  track_recorder() {
    pid_file=$1
    retry=0
    while [ ! -s "$pid_file" ] && [ "$retry" -lt 50 ]; do sleep 0.1; retry=$((retry + 1)); done
    [ -s "$pid_file" ] || fail "private recorder PID missing: $pid_file"
    recorder_pid=$(cat "$pid_file")
    case $recorder_pid in ''|*[!0-9]*) fail "private recorder PID malformed: $pid_file" ;; esac
    recorder_pids="$recorder_pids $recorder_pid"
  }
  wait_screen 'non-link target' "$main_pane"
  track_recorder "$private_root/base.screen.pid"
  send_mouse() {
    mouse_code=$1; mouse_x=$2; mouse_y=$3; mouse_suffix=$4
    printf '\033[<%s;%s;%s%s' \
      "$mouse_code" "$((mouse_x + 1))" "$((mouse_y + 1))" \
      "$mouse_suffix" >&3
  }
  wait_log_bytes() {
    expected=$1; log_path=$2
    retry=0
    while [ "$retry" -lt 50 ]; do
      actual=$(wc -c <"$log_path" 2>/dev/null || printf 0)
      [ "$actual" -ge "$expected" ] && return 0
      sleep 0.1; retry=$((retry + 1))
    done
    fail "private log bytes: $log_path expected $expected got $actual"
  }
  event_queue_barrier() {
    "$feature_tmux" -S "$private_root/new.sock" display-message -p '#{session_name}' >/dev/null
  }
  expect_click() {
    label=$1; x=$2; y=$3; expected_url=$4; pane_log=$5
    : >"$DOTFILES_URL_CLICK_OPEN_LOG"
    helper_before=$(wc -l <"$DOTFILES_URL_CLICK_HELPER_LOG")
    before=$(wc -c <"$pane_log")
    send_mouse 16 "$x" "$y" M
    expected_x=${6-$x}; expected_y=${7-$y}
    printf '\033[<16;%s;%sM' "$((expected_x + 1))" "$((expected_y + 1))" >"$private_root/down.expected"
    down_bytes=$(wc -c <"$private_root/down.expected")
    wait_log_bytes "$((before + down_bytes))" "$pane_log"
    send_mouse 16 "$x" "$y" m
    printf '\033[<16;%s;%sM\033[<16;%s;%sm' "$((expected_x + 1))" "$((expected_y + 1))" "$((expected_x + 1))" "$((expected_y + 1))" >"$private_root/pair.expected"
    pair_bytes=$(wc -c <"$private_root/pair.expected")
    wait_log_bytes "$((before + pair_bytes))" "$pane_log"
    event_queue_barrier
    retry=0
    while [ "$(wc -l <"$DOTFILES_URL_CLICK_HELPER_LOG")" -lt "$((helper_before + 2))" ] && [ "$retry" -lt 50 ]; do
      sleep 0.1; retry=$((retry + 1))
    done
    assert_equal "$((helper_before + 2))" "$(wc -l <"$DOTFILES_URL_CLICK_HELPER_LOG")" "$label helper completion count"
    tail -n 2 "$DOTFILES_URL_CLICK_HELPER_LOG" >"$private_root/helper.actual"
    printf 'start\ndone:0\n' >"$private_root/helper.expected"
    cmp -s "$private_root/helper.expected" "$private_root/helper.actual" || fail "$label helper completion"
    if [ -n "$expected_url" ]; then
      printf '1\000%s\000' "$expected_url" >"$private_root/expected.open"
      retry=0
      until cmp -s "$private_root/expected.open" "$DOTFILES_URL_CLICK_OPEN_LOG"; do
        [ "$retry" -lt 50 ] || fail "$label opener argv"
        sleep 0.1; retry=$((retry + 1))
      done
    else
      [ ! -s "$DOTFILES_URL_CLICK_OPEN_LOG" ] || fail "$label unexpected opener"
    fi
    dd if="$pane_log" bs=1 skip="$before" count="$pair_bytes" 2>/dev/null >"$private_root/pair.actual"
    cmp -s "$private_root/pair.expected" "$private_root/pair.actual" || fail "$label forwarded pair"
  }
  expect_click wrap-first 10 1 'https://plain.example/abcdefghijklmnopqrstuvwxyz?x=1#z' "$private_root/base.screen.mouse"
  expect_click wrap-second 4 2 'https://plain.example/abcdefghijklmnopqrstuvwxyz?x=1#z' "$private_root/base.screen.mouse"
  expect_click osc-precedence 10 3 'https://osc.example/a?b=1#frag' "$private_root/base.screen.mouse"
  expect_click non-link 5 4 '' "$private_root/base.screen.mouse"
  expect_click malformed-osc 10 5 '' "$private_root/base.screen.mouse"
  expect_click unsupported-osc 10 6 '' "$private_root/base.screen.mouse"
  : >"$DOTFILES_URL_CLICK_OPEN_LOG"
  helper_before=$(wc -l <"$DOTFILES_URL_CLICK_HELPER_LOG")
  before=$(wc -c <"$private_root/base.screen.mouse")
  send_mouse 16 10 1 M
  send_mouse 48 12 2 M
  send_mouse 16 12 2 m
  printf '\033[<16;11;2M\033[<48;13;3M\033[<16;13;3m' >"$private_root/drag.expected"
  drag_bytes=$(wc -c <"$private_root/drag.expected")
  wait_log_bytes "$((before + drag_bytes))" "$private_root/base.screen.mouse"
  dd if="$private_root/base.screen.mouse" bs=1 skip="$before" count="$drag_bytes" 2>/dev/null >"$private_root/drag.actual"
  cmp -s "$private_root/drag.expected" "$private_root/drag.actual" || fail 'drag forwarding sequence'
  event_queue_barrier
  assert_equal "$helper_before" "$(wc -l <"$DOTFILES_URL_CLICK_HELPER_LOG")" drag-no-helper
  [ ! -s "$DOTFILES_URL_CLICK_OPEN_LOG" ] || fail 'drag opened URL'
  # A new complete click after drag must remain paired and independent.
  expect_click post-drag 5 4 '' "$private_root/base.screen.mouse"
  : >"$DOTFILES_URL_CLICK_OPEN_LOG"
  helper_before=$(wc -l <"$DOTFILES_URL_CLICK_HELPER_LOG")
  before=$(wc -c <"$private_root/base.screen.mouse")
  send_mouse 0 10 1 M
  send_mouse 0 10 1 m
  printf '\033[<0;11;2M\033[<0;11;2m' >"$private_root/ordinary.expected"
  ordinary_bytes=$(wc -c <"$private_root/ordinary.expected")
  wait_log_bytes "$((before + ordinary_bytes))" "$private_root/base.screen.mouse"
  dd if="$private_root/base.screen.mouse" bs=1 skip="$before" count="$ordinary_bytes" 2>/dev/null >"$private_root/ordinary.actual"
  cmp -s "$private_root/ordinary.expected" "$private_root/ordinary.actual" || fail 'ordinary forwarding sequence'
  event_queue_barrier
  assert_equal "$helper_before" "$(wc -l <"$DOTFILES_URL_CLICK_HELPER_LOG")" ordinary-no-helper
  [ ! -s "$DOTFILES_URL_CLICK_OPEN_LOG" ] || fail 'ordinary click opened URL'

  "$feature_tmux" -S "$private_root/new.sock" respawn-pane -k -t "$main_pane" "$private_root/recorder $private_root/unicode.screen"
  wait_screen 'https://plain.example/combining' "$main_pane"
  track_recorder "$private_root/unicode.screen.pid"
  expect_click unicode-prefix 8 0 'https://plain.example/a' "$private_root/unicode.screen.mouse"
  expect_click combining-prefix 9 1 'https://plain.example/combining' "$private_root/unicode.screen.mouse"
  expect_click unicode-wrap-first 10 2 'https://plain.example/abcdefghijklmnopqrstuvwxyz' "$private_root/unicode.screen.mouse"
  expect_click unicode-wrap-second 2 3 'https://plain.example/abcdefghijklmnopqrstuvwxyz' "$private_root/unicode.screen.mouse"
  expect_click wide-first 1 4 'https://osc.example/wide' "$private_root/unicode.screen.mouse"
  expect_click wide-second 2 4 'https://osc.example/wide' "$private_root/unicode.screen.mouse"
  expect_click wide-left 0 4 '' "$private_root/unicode.screen.mouse"
  expect_click wide-right 3 4 '' "$private_root/unicode.screen.mouse"
  expect_click zero-first 0 5 'https://osc.example/zero' "$private_root/unicode.screen.mouse"
  expect_click zero-second 1 5 'https://osc.example/zero' "$private_root/unicode.screen.mouse"
  expect_click zero-right 2 5 '' "$private_root/unicode.screen.mouse"
  expect_click two-left 1 6 '' "$private_root/unicode.screen.mouse"
  expect_click two-first 2 6 'https://osc.example/two' "$private_root/unicode.screen.mouse"
  expect_click two-second 3 6 'https://osc.example/two' "$private_root/unicode.screen.mouse"
  expect_click two-right 4 6 '' "$private_root/unicode.screen.mouse"
  expect_click wide-prefix-left 2 7 '' "$private_root/unicode.screen.mouse"
  expect_click wide-prefix-first 3 7 'https://osc.example/prefix' "$private_root/unicode.screen.mouse"
  expect_click wide-prefix-second 4 7 'https://osc.example/prefix' "$private_root/unicode.screen.mouse"
  expect_click wide-prefix-right 5 7 '' "$private_root/unicode.screen.mouse"
  expect_click combining-left 1 8 '' "$private_root/unicode.screen.mouse"
  expect_click combining-first 2 8 'https://osc.example/combining' "$private_root/unicode.screen.mouse"
  expect_click combining-second 3 8 'https://osc.example/combining' "$private_root/unicode.screen.mouse"
  expect_click combining-right 4 8 '' "$private_root/unicode.screen.mouse"
  expect_click adjacent-left 0 9 '' "$private_root/unicode.screen.mouse"
  expect_click adjacent-first-a 1 9 'https://one.example/' "$private_root/unicode.screen.mouse"
  expect_click adjacent-first-b 2 9 'https://one.example/' "$private_root/unicode.screen.mouse"
  expect_click adjacent-second-a 3 9 'https://two.example/' "$private_root/unicode.screen.mouse"
  expect_click adjacent-second-b 4 9 'https://two.example/' "$private_root/unicode.screen.mouse"
  expect_click adjacent-right 5 9 '' "$private_root/unicode.screen.mouse"

  "$feature_tmux" -S "$private_root/new.sock" respawn-pane -k -t "$main_pane" "$private_root/recorder $private_root/left.screen"
  wait_screen 'https://left.test/a' "$main_pane"
  track_recorder "$private_root/left.screen.pid"
  "$feature_tmux" -S "$private_root/new.sock" split-window -h -l 24 -t "$main_pane" "$private_root/recorder $private_root/right.screen"
  right_pane=$($feature_tmux -S "$private_root/new.sock" display-message -p -t urltest:1.2 '#{pane_id}')
  wait_screen 'https://right.test/a' "$right_pane"
  track_recorder "$private_root/right.screen.pid"
  right_left=$($feature_tmux -S "$private_root/new.sock" display-message -p -t "$right_pane" '#{pane_left}')
  right_top=$($feature_tmux -S "$private_root/new.sock" display-message -p -t "$right_pane" '#{pane_top}')
  [ "$right_left" -gt 0 ] || fail 'split pane is at origin'
  left_before=$(wc -c <"$private_root/left.screen.mouse")
  expect_click split-right "$((right_left + 8))" "$right_top" 'https://right.test/a' "$private_root/right.screen.mouse" 8 0
  expect_click split-non-link "$((right_left + 8))" "$((right_top + 1))" '' "$private_root/right.screen.mouse" 8 1
  assert_equal "$left_before" "$(wc -c <"$private_root/left.screen.mouse")" split-adjacent-pane-untouched
  "$feature_tmux" -S "$private_root/new.sock" kill-pane -t "$right_pane"
  "$feature_tmux" -S "$private_root/new.sock" resize-window -t urltest:1 -x 40 -y 10
  # A captured negative history prefix must not suppress a visible click.
  "$feature_tmux" -S "$private_root/new.sock" respawn-pane -k -t "$main_pane" "$private_root/recorder $private_root/history.screen"
  wait_screen 'https://history-visible.example/a' "$main_pane"
  track_recorder "$private_root/history.screen.pid"
  history_rows=$("$feature_tmux" -S "$private_root/new.sock" capture-pane -p -L -F -N -S -20 -E 9 -t "$main_pane")
  printf '%s\n' "$history_rows" | awk '$1 ~ /^-[0-9]+$/ { found = 1 } END { exit !found }' || fail 'history fixture has no signed rows'
  history_y=$(printf '%s\n' "$history_rows" | awk '/https:\/\/history-visible[.]example\/a/ && $1 ~ /^[0-9]+$/ { print $1 }')
  case $history_y in ''|*[!0-9]*) fail 'visible history fixture row unavailable' ;; esac
  expect_click history-visible 10 "$history_y" 'https://history-visible.example/a' "$private_root/history.screen.mouse"

  "$feature_tmux" -S "$private_root/new.sock" clear-history -t "$main_pane"
  "$feature_tmux" -S "$private_root/new.sock" respawn-pane -k -t "$main_pane" "$private_root/recorder $private_root/copy.screen"
  wait_screen 'https://hidden.example/plain' "$main_pane"
  track_recorder "$private_root/copy.screen.pid"
  enter_copy_top() {
    "$feature_tmux" -S "$private_root/new.sock" copy-mode -t "$main_pane"
    "$feature_tmux" -S "$private_root/new.sock" send-keys -t "$main_pane" -X history-top
    mode_state=$("$feature_tmux" -S "$private_root/new.sock" display-message -p -t "$main_pane" '#{pane_in_mode}:#{pane_mode}:#{scroll_position}')
    case $mode_state in 1:copy-mode:[1-9]*) ;; *) fail "copy fixture state $mode_state" ;; esac
    scroll_offset=${mode_state##*:}
    shown=$("$feature_tmux" -S "$private_root/new.sock" capture-pane -p -M -e -N -S "-$scroll_offset" -E "$((1 - scroll_offset))" -t "$main_pane")
    base=$("$feature_tmux" -S "$private_root/new.sock" capture-pane -p -e -N -S 0 -E 1 -t "$main_pane")
    printf '%s\n' "$mode_state" >"$private_root/copy.mode-state"
    printf '%s\n' "$shown" >"$private_root/copy.shown"
    printf '%s\n' "$base" >"$private_root/copy.base"
    case $shown in *'https://shown.example/abcdefghijklmnopq'*'MODE'*) ;; *) fail 'copy fixture displayed rows unavailable' ;; esac
    case $base in *'https://hidden.example/plain'*'https://hidden.example/osc'*) ;; *) fail 'copy fixture hidden base rows unavailable' ;; esac
  }
  expect_mode_click() {
    mode_label=$1; mode_x=$2; mode_y=$3; mode_url=$4
    enter_copy_top
    if [ "${6-}" = end-marker ]; then
      "$feature_tmux" -S "$private_root/new.sock" send-keys -t "$main_pane" -N 4 -X cursor-down
      "$feature_tmux" -S "$private_root/new.sock" send-keys -t "$main_pane" -X end-of-line
      marker_cursor=$("$feature_tmux" -S "$private_root/new.sock" display-message -p -t "$main_pane" '#{copy_cursor_x}:#{copy_cursor_y}')
      assert_equal 40:4 "$marker_cursor" 'copy end-marker fixture cursor'
    fi
    mode_before=$("$feature_tmux" -S "$private_root/new.sock" display-message -p -t "$main_pane" '#{pane_in_mode}:#{pane_mode}:#{scroll_position}:#{copy_cursor_x}:#{copy_cursor_y}:#{selection_start_x}:#{selection_active}:#{selection_present}')
    : >"$DOTFILES_URL_CLICK_OPEN_LOG"
    helper_before=$(wc -l <"$DOTFILES_URL_CLICK_HELPER_LOG")
    send_mouse 16 "$mode_x" "$mode_y" M
    send_mouse 16 "$mode_x" "$mode_y" m
    event_queue_barrier
    retry=0
    while [ "$(wc -l <"$DOTFILES_URL_CLICK_HELPER_LOG")" -lt "$((helper_before + 2))" ] && [ "$retry" -lt 50 ]; do sleep 0.1; retry=$((retry + 1)); done
    assert_equal "$((helper_before + 2))" "$(wc -l <"$DOTFILES_URL_CLICK_HELPER_LOG")" "$mode_label helper count"
    mode_after=$("$feature_tmux" -S "$private_root/new.sock" display-message -p -t "$main_pane" '#{pane_in_mode}:#{pane_mode}:#{scroll_position}:#{copy_cursor_x}:#{copy_cursor_y}:#{selection_start_x}:#{selection_active}:#{selection_present}')
    assert_equal "$mode_before" "$mode_after" "$mode_label copy cursor/scroll/selection restored"
    assert_equal "context:$main_pane:$mode_x:$mode_y:${5-0}" "$(tail -n 1 "$DOTFILES_URL_CLICK_CONTEXT_LOG")" "$mode_label raw helper context"
    tail -n 2 "$DOTFILES_URL_CLICK_HELPER_LOG" >"$private_root/helper.actual"
    printf 'start\ndone:0\n' >"$private_root/helper.expected"
    cmp -s "$private_root/helper.expected" "$private_root/helper.actual" || fail "$mode_label helper completion"
    if [ -n "$mode_url" ]; then
      printf '1\000%s\000' "$mode_url" >"$private_root/expected.open"
      cmp -s "$private_root/expected.open" "$DOTFILES_URL_CLICK_OPEN_LOG" || fail "$mode_label displayed opener argv"
    else
      assert_empty_file "$DOTFILES_URL_CLICK_OPEN_LOG" "$mode_label non-link opener"
    fi
  }
  "$feature_tmux" -S "$private_root/new.sock" set-option -w -t "$main_pane" mode-keys emacs
  expect_mode_click copy-end-marker 39 4 '' 0 end-marker
  expect_mode_click copy-end-cursor-other-osc 2 1 'https://shown.example/osc' 1 end-marker
  "$feature_tmux" -S "$private_root/new.sock" send-keys -t "$main_pane" -X cancel
  "$feature_tmux" -S "$private_root/new.sock" set-option -w -t "$main_pane" mode-keys vi
  enter_copy_top
  position_width=$("$feature_tmux" -S "$private_root/new.sock" display-message -p -t "$main_pane" '#{w:#{E:copy-mode-position-format}}')
  case $position_width in ''|*[!0-9]*) fail 'copy position indicator width unavailable' ;; esac
  [ 10 -lt "$((40 - position_width))" ] && [ 35 -ge "$((40 - position_width))" ] || fail 'copy position indicator fixture does not separate visible and covered cells'
  expect_mode_click copy-plain 10 0 'https://shown.example/abcdefghijklmnopq'
  expect_mode_click copy-position-covered 35 0 ''
  expect_mode_click copy-plain-neighbor 39 0 ''
  "$feature_tmux" -S "$private_root/new.sock" set-option -w -t "$main_pane" copy-mode-position-format '#[align=left]mask'
  expect_mode_click copy-custom-position-row0 10 0 ''
  expect_mode_click copy-custom-position-row1 2 1 'https://shown.example/osc' 1
  "$feature_tmux" -S "$private_root/new.sock" set-option -wu -t "$main_pane" copy-mode-position-format
  "$feature_tmux" -S "$private_root/new.sock" set-option -p -t "$main_pane" copy-mode-position-format '#[align=left]pane-mask'
  expect_mode_click copy-pane-window-position-mismatch 10 0 ''
  "$feature_tmux" -S "$private_root/new.sock" set-option -pu -t "$main_pane" copy-mode-position-format
  "$feature_tmux" -S "$private_root/new.sock" set-option -w -t "$main_pane" copy-mode-line-numbers default
  expect_mode_click copy-line-number-gutter 2 0 ''
  "$feature_tmux" -S "$private_root/new.sock" set-option -wu -t "$main_pane" copy-mode-line-numbers
  expect_mode_click copy-osc 2 1 'https://shown.example/osc' 1
  expect_mode_click copy-osc-left-neighbor 0 1 ''
  expect_mode_click copy-osc-right-neighbor 5 1 ''
  expect_mode_click copy-invalid-osc 2 2 '' 1
  expect_mode_click copy-wide-first 1 3 'https://shown.example/wide' 1
  expect_mode_click copy-wide-second 2 3 'https://shown.example/wide' 1
  expect_mode_click copy-wide-left-neighbor 0 3 ''
  expect_mode_click copy-wide-right-neighbor 3 3 ''
  enter_copy_top
  "$feature_tmux" -S "$private_root/new.sock" send-keys -t "$main_pane" -X begin-selection
  selected_before=$("$feature_tmux" -S "$private_root/new.sock" display-message -p -t "$main_pane" '#{pane_in_mode}:#{pane_mode}:#{scroll_position}:#{copy_cursor_x}:#{copy_cursor_y}:#{selection_start_x}:#{selection_start_y}:#{selection_end_x}:#{selection_end_y}:#{selection_active}:#{selection_present}')
  selection_start=$("$feature_tmux" -S "$private_root/new.sock" display-message -p -t "$main_pane" '#{selection_start_x}')
  [ -n "$selection_start" ] || fail 'copy selection fixture is inactive'
  : >"$DOTFILES_URL_CLICK_OPEN_LOG"
  helper_before=$(wc -l <"$DOTFILES_URL_CLICK_HELPER_LOG")
  send_mouse 16 2 1 M
  send_mouse 16 2 1 m
  event_queue_barrier
  retry=0
  while [ "$(wc -l <"$DOTFILES_URL_CLICK_HELPER_LOG")" -lt "$((helper_before + 2))" ] && [ "$retry" -lt 50 ]; do sleep 0.1; retry=$((retry + 1)); done
  assert_equal "$((helper_before + 2))" "$(wc -l <"$DOTFILES_URL_CLICK_HELPER_LOG")" copy-selection-helper-count
  selected_after=$("$feature_tmux" -S "$private_root/new.sock" display-message -p -t "$main_pane" '#{pane_in_mode}:#{pane_mode}:#{scroll_position}:#{copy_cursor_x}:#{copy_cursor_y}:#{selection_start_x}:#{selection_start_y}:#{selection_end_x}:#{selection_end_y}:#{selection_active}:#{selection_present}')
  printf '%s\n%s\n' "$selected_before" "$selected_after" >"$private_root/copy.selection-state"
  assert_equal "$selected_before" "$selected_after" copy-selection-state-preserved
  tail -n 2 "$DOTFILES_URL_CLICK_HELPER_LOG" >"$private_root/helper.actual"
  printf 'start\ndone:0\n' >"$private_root/helper.expected"
  cmp -s "$private_root/helper.expected" "$private_root/helper.actual" || fail 'copy selection valid helper completion'
  printf '1\000%s\000' 'https://shown.example/osc' >"$private_root/expected.open"
  cmp -s "$private_root/expected.open" "$DOTFILES_URL_CLICK_OPEN_LOG" || fail 'copy selection displayed OSC opener argv'
  private_success=1
  private_cleanup || fail 'private cleanup incomplete'
  printf 'ok - tmux Ctrl-click URL private behavior\n'
)

case $mode in
  --unit) unit ;;
  --private) private; copy_state ;;
  --copy-state) copy_state ;;
  --all) unit; private; copy_state ;;
esac
