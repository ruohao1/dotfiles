local M = {}
local platform = require("config.platform")

-- TMUX's final field is the editor's originating session. Use it explicitly:
-- a pane can be linked into several sessions, so a pane-only target is ambiguous.
function M.resolve()
  local origin = platform.tmux_origin(vim.env)
  if not origin then
    return nil, "Line pins require an editor inside a tmux session"
  end
  local ok, process = pcall(vim.system, platform.tmux_probe_argv(origin), { text = true })
  if not ok then
    return nil, "Could not query tmux: " .. tostring(process)
  end
  local availability, err = platform.parse_tmux_probe(origin, process:wait(1000))
  if not availability then
    return nil, err
  end
  origin.configured = availability.configured
  origin.status_enabled = availability.status_enabled
  return origin
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
  if vim.g.dotfiles_tmux_integration == false then
    return nil, "Line pins are disabled by dotfiles_tmux_integration"
  end
  if not current.configured then
    return nil, "Line pins require configured dotfiles tmux"
  end
  local helper, helper_error = platform.dotfiles_helper("location_pins")
  if not helper then
    return nil, helper_error
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
