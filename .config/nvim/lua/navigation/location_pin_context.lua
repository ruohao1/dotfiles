local M = {}

-- TMUX's final field is the editor's originating session. Use it explicitly:
-- a pane can be linked into several sessions, so a pane-only target is ambiguous.
function M.resolve()
  local socket, pid, number = tostring(vim.env.TMUX or ""):match("^(.*),(%d+),(%d+)$")
  local pane = vim.env.TMUX_PANE
  if not socket or socket:sub(1, 1) ~= "/" or not pane or not pane:match("^%%%d+$") then
    return nil, "Line pins require an editor inside a tmux session"
  end
  local session = "$" .. number
  local ok, process = pcall(vim.system, {
    "tmux",
    "-u",
    "-S",
    socket,
    "list-panes",
    "-s",
    "-t",
    session,
    "-F",
    "#{pid}\t#{session_id}\t#{pane_id}",
  }, { text = true })
  if not ok then
    return nil, "Could not query tmux: " .. tostring(process)
  end
  local result = process:wait(5000)
  if result.code ~= 0 then
    return nil, "The editor's tmux session is no longer available"
  end
  for line in (result.stdout or ""):gmatch("[^\n]+") do
    local actual_pid, actual_session, actual_pane = line:match("^(%d+)\t(%$%d+)\t(%%%d+)$")
    if actual_pid == pid and actual_session == session and actual_pane == pane then
      return { socket = socket, pid = pid, session = session, pane = pane }
    end
  end
  return nil, "The tmux context changed; reopen the editor in its current session"
end

function M.validate(expected)
  local current, err = M.resolve()
  if not current then
    return nil, err
  end
  for _, field in ipairs({ "socket", "pid", "session", "pane" }) do
    if current[field] ~= expected[field] then
      return nil, "The tmux context changed; reopen the line-pin action"
    end
  end
  return true
end

-- Remember only a validated origin, so linked panes can retain their scope when
-- workspace restore assigns new session IDs. Resolution never guesses by pane.
function M.remember(ctx)
  local valid, err = M.validate(ctx)
  if not valid then
    return nil, err
  end
  local result = vim
    .system({
      "tmux",
      "-u",
      "-S",
      ctx.socket,
      "set-option",
      "-p",
      "-t",
      ctx.pane,
      "@dotfiles_line_pin_session",
      ctx.session,
    }, { text = true })
    :wait(5000)
  if result.code ~= 0 then
    return nil, "Could not retain the line-pin session for workspace restore"
  end
  return true
end

return M
