#!/bin/sh

# Source this file, then initialize the shared expectations with the tmux root.
tmux_audit_init() {
  [ "$#" -eq 1 ] || return 2
  tmux_persistence_prompt='Save tmux workspace now? (y/n)'
  tmux_persistence_helper="$1/scripts/workspace"
  tmux_persistence_save_command="confirm-before -p \"$tmux_persistence_prompt\" \"run-shell '$tmux_persistence_helper save'\""
  tmux_session_navigator_command='run-shell -b "exec #{q:HOME}/.config/tmux/scripts/session-navigator --popup #{q:socket_path} #{q:client_name}"'
  tmux_url_down_command='send-keys -M'
  tmux_url_up_command='send-keys -M \; run-shell -b -t = "\~/.config/tmux/scripts/open-url --pane #{mouse_pane} --x #{mouse_x} --y #{mouse_y} --hyperlink #{?mouse_hyperlink,1,0} || :"'
  tmux_swap_left_command='if-shell -F "#{window_zoomed_flag}" "resize-pane -Z ; if-shell -F \"#{pane_at_left}\" \"resize-pane -Z ; display-message \\\"No pane left\\\"\" \"run-shell -C \\\"swap-pane -Z -s '\''#{pane_id}'\'' -t '\''{left-of}'\'' ; select-pane -t '\''#{pane_id}'\'' ; resize-pane -Z -t '\''#{pane_id}'\''\\\"\"" "if-shell -F \"#{pane_at_left}\" \"display-message \\\"No pane left\\\"\" \"run-shell -C \\\"swap-pane -Z -s '\''#{pane_id}'\'' -t '\''{left-of}'\'' ; select-pane -t '\''#{pane_id}'\''\\\"\""'
  tmux_swap_down_command='if-shell -F "#{window_zoomed_flag}" "resize-pane -Z ; if-shell -F \"#{pane_at_bottom}\" \"resize-pane -Z ; display-message \\\"No pane down\\\"\" \"run-shell -C \\\"swap-pane -Z -s '\''#{pane_id}'\'' -t '\''{down-of}'\'' ; select-pane -t '\''#{pane_id}'\'' ; resize-pane -Z -t '\''#{pane_id}'\''\\\"\"" "if-shell -F \"#{pane_at_bottom}\" \"display-message \\\"No pane down\\\"\" \"run-shell -C \\\"swap-pane -Z -s '\''#{pane_id}'\'' -t '\''{down-of}'\'' ; select-pane -t '\''#{pane_id}'\''\\\"\""'
  tmux_swap_up_command='if-shell -F "#{window_zoomed_flag}" "resize-pane -Z ; if-shell -F \"#{pane_at_top}\" \"resize-pane -Z ; display-message \\\"No pane up\\\"\" \"run-shell -C \\\"swap-pane -Z -s '\''#{pane_id}'\'' -t '\''{up-of}'\'' ; select-pane -t '\''#{pane_id}'\'' ; resize-pane -Z -t '\''#{pane_id}'\''\\\"\"" "if-shell -F \"#{pane_at_top}\" \"display-message \\\"No pane up\\\"\" \"run-shell -C \\\"swap-pane -Z -s '\''#{pane_id}'\'' -t '\''{up-of}'\'' ; select-pane -t '\''#{pane_id}'\''\\\"\""'
  tmux_swap_right_command='if-shell -F "#{window_zoomed_flag}" "resize-pane -Z ; if-shell -F \"#{pane_at_right}\" \"resize-pane -Z ; display-message \\\"No pane right\\\"\" \"run-shell -C \\\"swap-pane -Z -s '\''#{pane_id}'\'' -t '\''{right-of}'\'' ; select-pane -t '\''#{pane_id}'\'' ; resize-pane -Z -t '\''#{pane_id}'\''\\\"\"" "if-shell -F \"#{pane_at_right}\" \"display-message \\\"No pane right\\\"\" \"run-shell -C \\\"swap-pane -Z -s '\''#{pane_id}'\'' -t '\''{right-of}'\'' ; select-pane -t '\''#{pane_id}'\''\\\"\""'
  tmux_move_command='run-shell -C "choose-tree -Zw \"run-shell -C \\\"move-pane -h -s '\''##{a:37}#{s/%//:pane_id}'\'' -t '\''%%'\''\\\"\""'
}

count_occurrences() {
  awk -v needle="$2" 'BEGIN { count = 0 }
    {
      line = $0
      while ((position = index(line, needle)) != 0) {
        count++
        line = substr(line, position + length(needle))
      }
    }
    END { print count }
  ' "$1"
}

tmux_pristine_binding_delta_is_exact() {
  pristine_binding_file=$1
  candidate_binding_file=$2
  expected_reload_command=$3
  expected_backslash_key=$4

  # shellcheck disable=SC2154  # The caller selects URL bindings for its tmux version.
  TMUX_EXPECTED_RELOAD_COMMAND=$expected_reload_command \
  TMUX_EXPECTED_BACKSLASH_KEY=$expected_backslash_key \
  TMUX_EXPECTED_SWAP_LEFT_COMMAND=$tmux_swap_left_command \
  TMUX_EXPECTED_SWAP_DOWN_COMMAND=$tmux_swap_down_command \
  TMUX_EXPECTED_SWAP_UP_COMMAND=$tmux_swap_up_command \
  TMUX_EXPECTED_SWAP_RIGHT_COMMAND=$tmux_swap_right_command \
  TMUX_EXPECTED_MOVE_COMMAND=$tmux_move_command \
  TMUX_EXPECTED_SESSION_NAVIGATOR_COMMAND=$tmux_session_navigator_command \
  TMUX_EXPECTED_PERSISTENCE_SAVE_COMMAND=$tmux_persistence_save_command \
  TMUX_EXPECTED_URL_ENABLED=$tmux_url_enabled \
  TMUX_EXPECTED_URL_DOWN_COMMAND=$tmux_url_down_command \
  TMUX_EXPECTED_URL_UP_COMMAND=$tmux_url_up_command \
    awk '
      function approve(table, key, command,    identity) {
        identity = table SUBSEP key
        if (identity in approved_command) duplicate_approval = 1
        approved_command[identity] = command
        approval_count++
      }
      function allow_removal(table, key,    identity) {
        identity = table SUBSEP key
        if (identity in allowed_removal) duplicate_removal = 1
        allowed_removal[identity] = 1
        removal_count++
      }
      function take_token(    token) {
        token = remaining
        sub(/[[:space:]].*$/, "", token)
        remaining = substr(remaining, length(token) + 1)
        sub(/^[[:space:]]+/, "", remaining)
        return token
      }
      function parse_binding(line,    token) {
        remaining = line
        token = take_token()
        if (token != "bind-key") return 0
        token = take_token()
        while (token == "-r") token = take_token()
        if (token != "-T") return 0
        parsed_table = take_token()
        parsed_key = take_token()
        if (parsed_key == "%") parsed_key = "\\%"
        parsed_command = remaining
        return parsed_table != "" && parsed_key != ""
      }
      BEGIN {
        approve("prefix", "M-Space", "send-prefix")
        approve("prefix", "?", "list-keys")
        approve("prefix", "R", ENVIRON["TMUX_EXPECTED_RELOAD_COMMAND"])
        approve("prefix", "Q", "detach-client")
        approve("prefix", "f", ENVIRON["TMUX_EXPECTED_SESSION_NAVIGATOR_COMMAND"])
        approve("prefix", "r", "switch-client -T resize")
        approve("prefix", "v", "copy-mode")
        approve("prefix", "H", ENVIRON["TMUX_EXPECTED_SWAP_LEFT_COMMAND"])
        approve("prefix", "J", ENVIRON["TMUX_EXPECTED_SWAP_DOWN_COMMAND"])
        approve("prefix", "K", ENVIRON["TMUX_EXPECTED_SWAP_UP_COMMAND"])
        approve("prefix", "L", ENVIRON["TMUX_EXPECTED_SWAP_RIGHT_COMMAND"])
        approve("prefix", "m", ENVIRON["TMUX_EXPECTED_MOVE_COMMAND"])
        approve("prefix", "s", ENVIRON["TMUX_EXPECTED_PERSISTENCE_SAVE_COMMAND"])

        approve("root", "M-n", "new-window -c \"#{pane_current_path}\"")
        approve("root", "M-1", "select-window -t :=1")
        approve("root", "M-2", "select-window -t :=2")
        approve("root", "M-3", "select-window -t :=3")
        approve("root", "M-4", "select-window -t :=4")
        approve("root", "M-5", "select-window -t :=5")
        approve("root", "M-6", "select-window -t :=6")
        approve("root", "M-7", "select-window -t :=7")
        approve("root", "M-8", "select-window -t :=8")
        approve("root", "M-9", "select-window -t :=9")
        approve("root", "M-r", "command-prompt -I \"#W\" \"rename-window -- \047%%\047\"")
        approve("root", "M-Q", "kill-window")
        approve("root", ENVIRON["TMUX_EXPECTED_BACKSLASH_KEY"], "split-window -h -c \"#{pane_current_path}\"")
        approve("root", "M-|", "split-window -v -c \"#{pane_current_path}\"")
        approve("root", "M-h", "if-shell -F \"#{@pane-is-vim}\" \"send-keys M-h\" \"select-pane -L\"")
        approve("root", "M-j", "if-shell -F \"#{@pane-is-vim}\" \"send-keys M-j\" \"select-pane -D\"")
        approve("root", "M-k", "if-shell -F \"#{@pane-is-vim}\" \"send-keys M-k\" \"select-pane -U\"")
        approve("root", "M-l", "if-shell -F \"#{@pane-is-vim}\" \"send-keys M-l\" \"select-pane -R\"")
        approve("root", "M-q", "confirm-before -p \"Kill pane #P? (y/n)\" kill-pane")
        approve("root", "M-f", "resize-pane -Z")

        approve("resize", "h", "resize-pane -L 1 \\; switch-client -T resize")
        approve("resize", "j", "resize-pane -D 1 \\; switch-client -T resize")
        approve("resize", "k", "resize-pane -U 1 \\; switch-client -T resize")
        approve("resize", "l", "resize-pane -R 1 \\; switch-client -T resize")
        approve("resize", "Escape", "switch-client -T root")

        approve("copy-mode-vi", "v", "send-keys -X begin-selection")
        approve("copy-mode-vi", "C-v", "send-keys -X rectangle-toggle")
        approve("copy-mode-vi", "y", "send-keys -X copy-selection-and-cancel")
        approve("copy-mode-vi", "Escape", "send-keys -X cancel")
        approve("copy-mode-vi", "M-h", "select-pane -L")
        approve("copy-mode-vi", "M-j", "select-pane -D")
        approve("copy-mode-vi", "M-k", "select-pane -U")
        approve("copy-mode-vi", "M-l", "select-pane -R")

        expected_approval_count = 46
        if (ENVIRON["TMUX_EXPECTED_URL_ENABLED"] == "true") {
          approve("root", "C-MouseDown1Pane", ENVIRON["TMUX_EXPECTED_URL_DOWN_COMMAND"])
          approve("root", "C-MouseUp1Pane", ENVIRON["TMUX_EXPECTED_URL_UP_COMMAND"])
          expected_approval_count = 48
        }

        allow_removal("prefix", "C-Space")
        allow_removal("prefix", "C-b")
        allow_removal("prefix", "d")
        allow_removal("prefix", "c")
        allow_removal("prefix", "n")
        allow_removal("prefix", "p")
        allow_removal("prefix", "M-n")
        allow_removal("prefix", "M-p")
        allow_removal("prefix", "0")
        allow_removal("prefix", "1")
        allow_removal("prefix", "2")
        allow_removal("prefix", "3")
        allow_removal("prefix", "4")
        allow_removal("prefix", "5")
        allow_removal("prefix", "6")
        allow_removal("prefix", "7")
        allow_removal("prefix", "8")
        allow_removal("prefix", "9")
        allow_removal("prefix", ",")
        allow_removal("prefix", "&")
        allow_removal("prefix", "\\\"")
        allow_removal("prefix", "\\%")
        allow_removal("prefix", "w")
        allow_removal("prefix", "h")
        allow_removal("prefix", "j")
        allow_removal("prefix", "k")
        allow_removal("prefix", "l")
        allow_removal("prefix", "Up")
        allow_removal("prefix", "Down")
        allow_removal("prefix", "Left")
        allow_removal("prefix", "Right")
        allow_removal("prefix", "C-Up")
        allow_removal("prefix", "C-Down")
        allow_removal("prefix", "C-Left")
        allow_removal("prefix", "C-Right")
        allow_removal("prefix", "M-Up")
        allow_removal("prefix", "M-Down")
        allow_removal("prefix", "M-Left")
        allow_removal("prefix", "M-Right")
        allow_removal("prefix", "x")
        allow_removal("prefix", "z")
        allow_removal("prefix", "[")
        allow_removal("prefix", "Tab")

        allow_removal("root", "M-H")
        allow_removal("root", "M-J")
        allow_removal("root", "M-K")
        allow_removal("root", "M-L")
      }
      NR == FNR {
        pristine_line[$0] = 1
        pristine_order[++pristine_count] = $0
        next
      }
      /^[[:space:]]*$/ { next }
      {
        source_line = $0
        current_line[source_line] = 1
        if (parse_binding(source_line)) {
          current_command[parsed_table SUBSEP parsed_key] = parsed_command
        }
        if (source_line in pristine_line) next

        if (!parse_binding(source_line)) {
          print "unparseable current tmux binding addition: " source_line
          invalid = 1
          next
        }
        identity = parsed_table SUBSEP parsed_key

        if (!(identity in approved_command)) {
          print "unowned tmux binding delta: table=" parsed_table " key=" parsed_key
          print "  actual: " source_line
          invalid = 1
          next
        }
        if (parsed_command != approved_command[identity]) {
          print "noncanonical owned tmux binding delta: table=" parsed_table " key=" parsed_key
          print "  expected: " approved_command[identity]
          print "  actual:   " parsed_command
          invalid = 1
        }
      }
      END {
        if (duplicate_approval || approval_count != expected_approval_count) {
          print "internal tmux owned-binding map error: expected " expected_approval_count " unique identities, found " approval_count
          invalid = 1
        }
        if (ENVIRON["TMUX_EXPECTED_URL_ENABLED"] == "true") {
          down_identity = "root" SUBSEP "C-MouseDown1Pane"
          up_identity = "root" SUBSEP "C-MouseUp1Pane"
          if (!(down_identity in current_command) \
            || current_command[down_identity] != approved_command[down_identity]) {
            print "missing or noncanonical tmux Ctrl-down identity"
            invalid = 1
          }
          if (!(up_identity in current_command) \
            || current_command[up_identity] != approved_command[up_identity]) {
            print "missing or noncanonical tmux Ctrl-up identity"
            invalid = 1
          }
        }
        if (duplicate_removal || removal_count != 47) {
          print "internal tmux removal map error: expected 47 unique identities, found " removal_count
          invalid = 1
        }
        for (line_number = 1; line_number <= pristine_count; line_number++) {
          source_line = pristine_order[line_number]
          if (source_line in current_line) continue
          if (!parse_binding(source_line)) {
            print "unparseable pristine tmux binding removal: " source_line
            invalid = 1
            continue
          }
          identity = parsed_table SUBSEP parsed_key
          if ((identity in approved_command) ||
              (identity in allowed_removal) ||
              parsed_table == "resize") continue
          print "unexpected tmux binding removal: table=" parsed_table " key=" parsed_key
          print "  pristine: " source_line
          invalid = 1
        }
        exit invalid
      }
    ' "$pristine_binding_file" "$candidate_binding_file"
}

tmux_copy_pipe_and_run_shell_payloads_are_safe() {
  binding_file=$1

  TMUX_EXPECTED_SWAP_LEFT_COMMAND=$tmux_swap_left_command \
  TMUX_EXPECTED_SWAP_DOWN_COMMAND=$tmux_swap_down_command \
  TMUX_EXPECTED_SWAP_UP_COMMAND=$tmux_swap_up_command \
  TMUX_EXPECTED_SWAP_RIGHT_COMMAND=$tmux_swap_right_command \
  TMUX_EXPECTED_MOVE_COMMAND=$tmux_move_command \
  TMUX_EXPECTED_SESSION_NAVIGATOR_COMMAND=$tmux_session_navigator_command \
  TMUX_EXPECTED_PERSISTENCE_SAVE_COMMAND=$tmux_persistence_save_command \
  TMUX_EXPECTED_URL_UP_COMMAND=$tmux_url_up_command \
    awk '
    function take_token(    token) {
      token = remaining
      sub(/[[:space:]].*$/, "", token)
      remaining = substr(remaining, length(token) + 1)
      sub(/^[[:space:]]+/, "", remaining)
      return token
    }
    function emit_audit_token(depth, token) {
      audit_token_count[depth]++
      audit_token[depth, audit_token_count[depth]] = token
    }
    function tokenize_tmux_commands(input, depth,    character, character_index, escaped, has_token, quote, token) {
      audit_token_count[depth] = 0
      audit_lex_error[depth] = 0
      escaped = 0
      has_token = 0
      quote = ""
      token = ""

      for (character_index = 1; character_index <= length(input); character_index++) {
        character = substr(input, character_index, 1)

        if (escaped) {
          if (quote == "" && character == ";") {
            if (has_token) emit_audit_token(depth, token)
            emit_audit_token(depth, ";")
            has_token = 0
            token = ""
          } else {
            token = token character
            has_token = 1
          }
          escaped = 0
          continue
        }

        if (character == "\\") {
          escaped = 1
          continue
        }

        if (quote != "") {
          if (character == quote) {
            quote = ""
          } else {
            token = token character
          }
          has_token = 1
          continue
        }

        if (character == "\"" || character == "\047") {
          quote = character
          has_token = 1
        } else if (character ~ /[[:space:]]/) {
          if (has_token) emit_audit_token(depth, token)
          has_token = 0
          token = ""
        } else if (character == ";" || character == "{" || character == "}") {
          if (has_token) emit_audit_token(depth, token)
          emit_audit_token(depth, character)
          has_token = 0
          token = ""
        } else {
          token = token character
          has_token = 1
        }
      }

      if (escaped) {
        token = token "\\"
        has_token = 1
      }
      if (quote != "") audit_lex_error[depth] = 1
      if (has_token) emit_audit_token(depth, token)
      return audit_token_count[depth]
    }
    function is_command_boundary(token) {
      return token == "\\;" || token == ";" || token == "{" || token == "}"
    }
    function is_copy_pipe_action(token) {
      return token ~ /^copy-pipe(-[^[:space:]]*)?$/
    }
    function run_segment_has_payload(depth, start, end,    token_index, token) {
      token_index = start + 1
      while (token_index <= end) {
        token = audit_token[depth, token_index]
        if (token == "-b" || token == "-C" || token == "-E") {
          token_index++
        } else if (token ~ /^-d./) {
          if (token_index < end) return 1
          token_index++
        } else if (token == "-d" || token == "-t" || token == "-c") {
          if (token_index + 1 > end) return 1
          token_index += 2
        } else {
          return 1
        }
      }
      return 0
    }
    function copy_pipe_segment_has_payload(depth, start, end,    command, token_index) {
      command = audit_token[depth, start]
      if (command != "send-keys" && command != "send") return 0

      for (token_index = start + 1; token_index <= end; token_index++) {
        if (is_copy_pipe_action(audit_token[depth, token_index])) {
          return token_index < end
        }
      }
      return 0
    }
    function audit_if_shell_arguments(depth, start, end,    token_index, token) {
      token_index = start + 1
      while (token_index <= end) {
        token = audit_token[depth, token_index]
        if (token == "--") {
          token_index++
          break
        }
        if (token ~ /^-[bF]+$/) {
          token_index++
          continue
        }
        if (token == "-t") {
          if (token_index + 1 > end) return 1
          token_index += 2
          continue
        }
        if (token ~ /^-t./) {
          token_index++
          continue
        }
        break
      }

      if (token_index > end) return 0
      token_index++
      while (token_index <= end) {
        if (audit_tmux_command_list(audit_token[depth, token_index], depth + 1)) return 1
        token_index++
      }
      return 0
    }
    function audit_confirm_before_arguments(depth, start, end,    token_index, token) {
      token_index = start + 1
      while (token_index <= end) {
        token = audit_token[depth, token_index]
        if (token == "--") {
          token_index++
          break
        }
        if (token ~ /^-[by]+$/) {
          token_index++
          continue
        }
        if (token == "-c" || token == "-p" || token == "-t") {
          if (token_index + 1 > end) return 1
          token_index += 2
          continue
        }
        if (token ~ /^-[cpt]./) {
          token_index++
          continue
        }
        break
      }

      while (token_index <= end) {
        if (audit_tmux_command_list(audit_token[depth, token_index], depth + 1)) return 1
        token_index++
      }
      return 0
    }
    function audit_command_prompt_arguments(depth, start, end,    token_index, token) {
      token_index = start + 1
      while (token_index <= end) {
        token = audit_token[depth, token_index]
        if (token == "--") {
          token_index++
          break
        }
        if (token ~ /^-[1bFikN]+$/) {
          token_index++
          continue
        }
        if (token == "-I" || token == "-p" || token == "-t" || token == "-T") {
          if (token_index + 1 > end) return 1
          token_index += 2
          continue
        }
        if (token ~ /^-[IptT]./) {
          token_index++
          continue
        }
        break
      }

      while (token_index <= end) {
        if (audit_tmux_command_list(audit_token[depth, token_index], depth + 1)) return 1
        token_index++
      }
      return 0
    }
    function audit_tmux_command_segment(depth, start, end,    command) {
      command = audit_token[depth, start]
      if ((command == "run-shell" || command == "run") \
        && run_segment_has_payload(depth, start, end)) return 1
      if (copy_pipe_segment_has_payload(depth, start, end)) return 1
      if ((command == "if-shell" || command == "if") \
        && audit_if_shell_arguments(depth, start, end)) return 1
      if ((command == "confirm-before" || command == "confirm") \
        && audit_confirm_before_arguments(depth, start, end)) return 1
      if (command == "command-prompt" \
        && audit_command_prompt_arguments(depth, start, end)) return 1
      return 0
    }
    function audit_tmux_command_list(input, depth,    end, start, token_count, token_index) {
      if (depth > 12) return 1
      token_count = tokenize_tmux_commands(input, depth)
      if (audit_lex_error[depth]) return 1

      token_index = 1
      while (token_index <= token_count) {
        while (token_index <= token_count \
          && is_command_boundary(audit_token[depth, token_index])) token_index++
        if (token_index > token_count) break

        start = token_index
        while (token_index <= token_count \
          && !is_command_boundary(audit_token[depth, token_index])) token_index++
        end = token_index - 1
        if (audit_tmux_command_segment(depth, start, end)) return 1
      }
      return 0
    }
    BEGIN {
      canonical_swap_command["H"] = ENVIRON["TMUX_EXPECTED_SWAP_LEFT_COMMAND"]
      canonical_swap_command["J"] = ENVIRON["TMUX_EXPECTED_SWAP_DOWN_COMMAND"]
      canonical_swap_command["K"] = ENVIRON["TMUX_EXPECTED_SWAP_UP_COMMAND"]
      canonical_swap_command["L"] = ENVIRON["TMUX_EXPECTED_SWAP_RIGHT_COMMAND"]
      canonical_move_command = ENVIRON["TMUX_EXPECTED_MOVE_COMMAND"]
      canonical_session_navigator_command = ENVIRON["TMUX_EXPECTED_SESSION_NAVIGATOR_COMMAND"]
      canonical_persistence_save_command = ENVIRON["TMUX_EXPECTED_PERSISTENCE_SAVE_COMMAND"]
      canonical_url_up_command = ENVIRON["TMUX_EXPECTED_URL_UP_COMMAND"]
    }
    /^[[:space:]]*$/ { next }
    {
      remaining = $0
      token = take_token()
      if (token != "bind-key") {
        invalid = 1
        next
      }
      token = take_token()
      while (token == "-r") token = take_token()
      if (token != "-T") {
        invalid = 1
        next
      }
      parsed_table = take_token()
      parsed_key = take_token()
      if (remaining == "") {
        invalid = 1
        next
      }
      if (parsed_table == "prefix" \
        && parsed_key == "m" \
        && remaining == canonical_move_command) next
      if (parsed_table == "prefix" \
        && parsed_key == "f" \
        && remaining == canonical_session_navigator_command) next
      if (parsed_table == "prefix" \
        && (parsed_key in canonical_swap_command) \
        && remaining == canonical_swap_command[parsed_key]) next
      if (parsed_table == "prefix" \
        && parsed_key == "s" \
        && remaining == canonical_persistence_save_command) next
      if (parsed_table == "root" \
        && parsed_key == "C-MouseUp1Pane" \
        && remaining == canonical_url_up_command) next
      if (audit_tmux_command_list(remaining, 0)) invalid = 1
    }
    END { exit invalid }
  ' "$binding_file"
}

tmux_status_jobs_are_exact() {
  [ "$#" -eq 2 ] || return 2
  tmux_audit_socket=$1
  tmux_audit_target=$2

  tmux_audit_left=$(tmux -S "$tmux_audit_socket" show-options -gv \
    -t "$tmux_audit_target" status-left) || return 1
  tmux_audit_right=$(tmux -S "$tmux_audit_socket" show-options -gv \
    -t "$tmux_audit_target" status-right) || return 1
  tmux_audit_window=$(tmux -S "$tmux_audit_socket" show-options -gv \
    -t "$tmux_audit_target" window-status-format) || return 1
  tmux_audit_current=$(tmux -S "$tmux_audit_socket" show-options -gv \
    -t "$tmux_audit_target" window-status-current-format) || return 1
  tmux_audit_root=$(tmux -S "$tmux_audit_socket" show-options -gv \
    -t "$tmux_audit_target" 'status-format[0]') || return 1

  tmux_audit_sep=$(printf '\034')
  case "$tmux_audit_left$tmux_audit_right$tmux_audit_window$tmux_audit_current$tmux_audit_root" in
    *"$tmux_audit_sep"*)
      printf '%s\n' 'tmux status format contains the reserved audit separator'
      return 1
      ;;
  esac

  # Encode only the known literal through the same version-specific print transport.
  # shellcheck disable=SC2016  # l: prevents expansion or execution of the exact job key.
  TMUX_EXPECTED_STATUS_JOB=$(tmux -S "$tmux_audit_socket" display-message -p \
    '#{l:#($HOME/.config/dotfiles/git-summary --tmux-pane #{pane_id} --profile #{?#{e|>=:#{client_width},120},wide,#{?#{e|>=:#{client_width},100},medium,compact}})}') || return 1
  TMUX_EXPECTED_UPDATE_JOB='#(command -v dotfiles-update >/dev/null 2>&1 && exec dotfiles-update status --tmux 2>/dev/null)'
  export TMUX_EXPECTED_STATUS_JOB TMUX_EXPECTED_UPDATE_JOB

  printf '%s\034%s\034%s\034%s\034%s\034' \
    "$tmux_audit_left" "$tmux_audit_right" \
    "$tmux_audit_window" "$tmux_audit_current" "$tmux_audit_root" |
    LC_ALL=C awk '
      BEGIN {
        RS = sprintf("%c", 28)
        expected = ENVIRON["TMUX_EXPECTED_STATUS_JOB"]
        update = ENVIRON["TMUX_EXPECTED_UPDATE_JOB"]
      }
      {
        text = $0
        cursor = 1
        while (cursor <= length(text)) {
          if (substr(text, cursor, 1) != "#") {
            cursor++
            continue
          }

          hashes = 0
          while (substr(text, cursor + hashes, 1) == "#") hashes++
          if (substr(text, cursor + hashes, 1) != "(" || hashes % 2 == 0) {
            cursor += hashes
            continue
          }
          if (hashes != 1) {
            print "executable tmux status job is hidden behind " hashes " hashes"
            invalid = 1
          }

          start = cursor + hashes - 1
          depth = 1
          cursor = start + 2
          while (cursor <= length(text) && depth > 0) {
            byte = substr(text, cursor, 1)
            if (byte == "(") depth++
            else if (byte == ")") depth--
            cursor++
          }

          if (depth != 0) {
            print "unterminated executable tmux status job"
            invalid = 1
            next
          }

          job = substr(text, start, cursor - start)
          references++
          keys[job] = 1
          if (job != expected && job != update) {
            print "altered executable tmux status job: " job
            invalid = 1
          }
        }
      }
      END {
        for (job in keys) unique++
        if (references < 2) print "missing executable tmux status job"
        if (unique != 2) print "tmux status contains " unique " unique executable job keys"
        if (!(expected in keys)) print "tmux status does not contain the exact Git helper job key"
        if (!(update in keys)) print "tmux status does not contain the exact updater job key"
        if (invalid || references < 2 || unique != 2 || !(expected in keys) || !(update in keys))
          exit 1
      }
    '
  tmux_audit_status=$?

  unset TMUX_EXPECTED_STATUS_JOB TMUX_EXPECTED_UPDATE_JOB
  return "$tmux_audit_status"
}

tmux_status_assignment_manifest_is_exact() {
  LC_ALL=C awk '
    BEGIN {
      expected["status"] = "-g"
      expected["status-interval"] = "-g"
      expected["status-position"] = "-g"
      expected["status-justify"] = "-g"
      expected["status-left-length"] = "-g"
      expected["status-right-length"] = "-g"
      expected["status-style"] = "-g"
      expected["status-left-style"] = "-g"
      expected["status-right-style"] = "-g"
      expected["monitor-activity"] = "-gw"
      expected["monitor-bell"] = "-gw"
      expected["visual-activity"] = "-g"
      expected["visual-bell"] = "-g"
      expected["window-status-separator"] = "-g"
      expected["window-status-style"] = "-g"
      expected["window-status-current-style"] = "-g"
      expected["window-status-activity-style"] = "-g"
      expected["window-status-bell-style"] = "-g"
      expected["window-status-format"] = "-g"
      expected["window-status-current-format"] = "-g"
      expected["status-left"] = "-g"
      expected["status-right"] = "-g"
    }
    function reject(message) {
      print message
      invalid = 1
    }
    /^[[:space:]]*($|#)/ { next }
    {
      active_lines++
      line = $0
      sub(/^[[:space:]]*/, "", line)
      split(line, field, /[[:space:]]+/)
      if (field[1] != "set") {
        reject("unapproved tmux status assignment verb at line " FNR ": " field[1])
        next
      }
      option = field[3]
      if (!(option in expected)) {
        reject("unapproved tmux status option at line " FNR ": " option)
      } else {
        seen[option]++
        if (field[2] != expected[option])
          reject("wrong tmux status scope for " option ": " field[2])
      }

      assignment_count = 0
      remaining = $0
      while ((position = index(remaining, "set -g")) != 0) {
        assignment_count++
        remaining = substr(remaining, position + length("set -g"))
      }
      if (assignment_count != 1)
        reject("tmux status line " FNR " contains " assignment_count " assignments")
    }
    END {
      if (active_lines != 22)
        reject("tmux status assignment count mismatch: expected 22, found " active_lines)
      for (option in expected) {
        if (seen[option] != 1)
          reject("tmux status option assignment mismatch for " option ": expected 1, found " seen[option])
      }
      exit invalid
    }
  ' "$1"
}

tmux_status_palette_is_exact() {
  LC_ALL=C awk '
    BEGIN {
      allowed["#1A1B26"] = 1
      allowed["#a9b1d6"] = 1
      allowed["#787c99"] = 1
      allowed["#24283b"] = 1
      allowed["#2A2F41"] = 1
      allowed["#7aa2f7"] = 1
      allowed["#7dcfff"] = 1
      allowed["#73daca"] = 1
      allowed["#bb9af7"] = 1
      allowed["#f7768e"] = 1
      allowed["#e0af68"] = 1
      squote = sprintf("%c", 39)
    }
    function reject(message) {
      print message
      invalid = 1
    }
    function validate_style_list(style, context,    attribute, attribute_count, attribute_no, color, normalized) {
      normalized = style
      gsub(/#,/, ",", normalized)
      attribute_count = split(normalized, attribute, ",")
      for (attribute_no = 1; attribute_no <= attribute_count; attribute_no++) {
        if (attribute[attribute_no] == "bold" || attribute[attribute_no] == "default")
          continue
        if (attribute[attribute_no] ~ /^(fg|bg)=/) {
          color = substr(attribute[attribute_no], 4)
          if (!(color in allowed))
            reject("unapproved tmux status color token in " context ": " color)
          else
            seen[color] = 1
          continue
        }
        reject("unapproved tmux status style attribute in " context ": " attribute[attribute_no])
      }
    }
    /^[[:space:]]*#/ { next }
    {
      remaining = $0
      while ((style_start = index(remaining, "#[")) != 0) {
        remaining = substr(remaining, style_start + 2)
        style_end = index(remaining, "]")
        if (style_end == 0) {
          reject("unterminated tmux status style at line " FNR)
          remaining = ""
          break
        }
        validate_style_list(substr(remaining, 1, style_end - 1), "line " FNR)
        remaining = substr(remaining, style_end + 1)
      }

      if ($0 ~ /^[[:space:]]*set[[:space:]]+-gw?[[:space:]]+[^[:space:]]*-style[[:space:]]+/) {
        style_start = index($0, squote)
        if (style_start == 0) {
          reject("unquoted tmux status style option at line " FNR)
          next
        }
        remaining = substr($0, style_start + 1)
        style_end = index(remaining, squote)
        if (style_end == 0) {
          reject("unterminated tmux status style option at line " FNR)
          next
        }
        validate_style_list(substr(remaining, 1, style_end - 1), "style option line " FNR)
        trailing = substr(remaining, style_end + 1)
        sub(/^[[:space:]]*#[^\n]*$/, "", trailing)
        if (trailing !~ /^[[:space:]]*$/)
          reject("unexpected tmux status style option suffix at line " FNR)
      }
    }
    END {
      for (color in allowed) {
        if (!(color in seen))
          reject("missing tmux status color: " color)
      }
      exit invalid
    }
  ' "$1"
}

tmux_status_source_is_safe() {
  tmux_status_source=$1
  tmux_status_source_invalid=false
  tmux_powerline_right=$(printf '\356\202\260')
  tmux_powerline_left=$(printf '\356\202\262')
  tmux_powerline_right_thin=$(printf '\356\202\261')
  tmux_powerline_left_thin=$(printf '\356\202\263')

  tmux_status_assignment_manifest_is_exact "$tmux_status_source" \
    || tmux_status_source_invalid=true
  tmux_status_palette_is_exact "$tmux_status_source" \
    || tmux_status_source_invalid=true

  # shellcheck disable=SC2016  # These are byte-literal tmux format requirements.
  for tmux_status_required_fragment in \
    '#($HOME/.config/dotfiles/git-summary --tmux-pane #{pane_id} --profile #{?#{e|>=:#{client_width},120},wide,#{?#{e|>=:#{client_width},100},medium,compact}})' \
    '#{e|>=:#{client_width},80}' \
    '#{e|>=:#{client_width},100}' \
    '#{e|>=:#{client_width},120}' \
    '#{qh:@dotfiles_nvim_mode}' \
    '#{qh:@dotfiles_nvim_path}' \
    '#{==:#{@dotfiles_nvim_modified},1}' \
    '#{qh:@dotfiles_nvim_errors}' \
    '#{qh:@dotfiles_nvim_warnings}' \
    '#{qh:@dotfiles_nvim_line}' \
    '#{qh:@dotfiles_nvim_column}' \
    '#{qh:pane_current_path}' \
    '#{b;qh:session_path}' \
    '#{qh:window_name}' \
    '#{b:pane_current_command}' \
    's/^(sh|bash|zsh|fish|dash|ksh|nu)$/SHELL/' \
    's/^(ssh|mosh-client)$/SSH/' \
    's/^(nvim|nvimdiff|nvim-wrapped|nvimdiff-wrapped)$/NVIM/' \
    's/^lazygit$/LAZYGIT/' \
    's/^gitui$/GITUI/' \
    's/^htop$/HTOP/' \
    's/^btop$/BTOP/' \
    's/^man$/MAN/' \
    's/^less$/LESS/'
  do
    if ! grep -Fq -e "$tmux_status_required_fragment" "$tmux_status_source"; then
      printf 'missing tmux status fragment: %s\n' "$tmux_status_required_fragment"
      tmux_status_source_invalid=true
    fi
  done

  for tmux_status_forbidden_fragment in \
    '#{@dotfiles_nvim_root}' \
    '#{@dotfiles_nvim_path}' \
    '#{pane_current_path}' \
    '#{session_path}' \
    '#{window_name}' \
    '#{E:' \
    '#{T:' \
    '#{p8:' \
    '#{session_name}' \
    '#S' \
    'refresh-client' \
    'source-file' \
    'run-shell' \
    '@plugin' \
    "$tmux_powerline_right" \
    "$tmux_powerline_left" \
    "$tmux_powerline_right_thin" \
    "$tmux_powerline_left_thin"
  do
    if grep -Fq -e "$tmux_status_forbidden_fragment" "$tmux_status_source"; then
      printf 'forbidden tmux status fragment: %s\n' "$tmux_status_forbidden_fragment"
      tmux_status_source_invalid=true
    fi
  done

  while IFS='|' read -r tmux_status_count_fragment \
    tmux_status_count_expected tmux_status_count_label; do
    tmux_status_count_actual=$(count_occurrences \
      "$tmux_status_source" "$tmux_status_count_fragment")
    if [ "$tmux_status_count_actual" -ne "$tmux_status_count_expected" ]; then
      printf 'tmux status %s occurrence mismatch: expected %s, found %s\n' \
        "$tmux_status_count_label" \
        "$tmux_status_count_expected" \
        "$tmux_status_count_actual"
      tmux_status_source_invalid=true
    fi
  done <<'TMUX_STATUS_DISPLAY_COUNTS'
#{@dotfiles_nvim_mode}|7|raw mode predicate
#{@dotfiles_nvim_errors}|5|raw error predicate
#{@dotfiles_nvim_warnings}|5|raw warning predicate
#{@dotfiles_nvim_line}|5|raw line predicate
#{@dotfiles_nvim_column}|5|raw column predicate
#{@dotfiles_nvim_modified}|4|raw modified predicate
#{==:#{@dotfiles_nvim_modified},1}|4|exact modified predicate
#{qh:@dotfiles_nvim_mode}|12|quoted mode display
#{qh:@dotfiles_nvim_errors}|3|quoted error display
#{qh:@dotfiles_nvim_warnings}|3|quoted warning display
#{qh:@dotfiles_nvim_line}|3|quoted line display
#{qh:@dotfiles_nvim_column}|3|quoted column display
#{qh:@dotfiles_nvim_path}|7|quoted Neovim path display
#{qh:pane_current_path}|3|quoted pane path display
#{b;qh:session_path}|3|quoted project basename
#{qh:window_name}|6|quoted window name display
TMUX_STATUS_DISPLAY_COUNTS

  while IFS='|' read -r tmux_status_key_fragment \
    tmux_status_key_expected tmux_status_key_label; do
    tmux_status_key_actual=$(count_occurrences \
      "$tmux_status_source" "$tmux_status_key_fragment")
    if [ "$tmux_status_key_actual" -ne "$tmux_status_key_expected" ]; then
      printf 'tmux status %s total-key mismatch: expected %s, found %s\n' \
        "$tmux_status_key_label" \
        "$tmux_status_key_expected" \
        "$tmux_status_key_actual"
      tmux_status_source_invalid=true
    fi
  done <<'TMUX_STATUS_KEY_COUNTS'
@dotfiles_nvim_mode|19|mode
@dotfiles_nvim_errors|8|errors
@dotfiles_nvim_warnings|8|warnings
@dotfiles_nvim_line|8|line
@dotfiles_nvim_column|8|column
@dotfiles_nvim_path|7|Neovim path
@dotfiles_nvim_modified|4|modified
pane_current_path|3|pane path
session_path|3|project path
window_name|6|window name
session_name|0|session name
TMUX_STATUS_KEY_COUNTS

  [ "$tmux_status_source_invalid" = false ]
}
