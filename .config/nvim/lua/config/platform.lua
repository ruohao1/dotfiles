local M = {}

local function is_executable(name)
  return vim.fn.executable(name) == 1
end

function M.tmux_origin(environment)
  local socket, pid, number = tostring(environment.TMUX or ""):match("^(.*),(%d+),(%d+)$")
  local pane = environment.TMUX_PANE
  if
    not socket
    or socket:sub(1, 1) ~= "/"
    or socket:find("[%c]")
    or type(pane) ~= "string"
    or not pane:match("^%%%d+$")
  then
    return nil, "A valid originating tmux session is required"
  end
  return { socket = socket, pid = pid, session = "$" .. number, pane = pane }
end

function M.tmux_probe_argv(origin)
  return {
    "tmux",
    "-u",
    "-S",
    origin.socket,
    "list-panes",
    "-s",
    "-t",
    origin.session,
    "-F",
    "#{pid}\t#{session_id}\t#{pane_id}\t#{@dotfiles_foundation_loaded}\t#{status}",
  }
end

function M.parse_tmux_probe(origin, result)
  if not result or result.code ~= 0 then
    return nil, "The editor's tmux session is no longer available"
  end
  for line in (result.stdout or ""):gmatch("[^\n]+") do
    local pid, session, pane, marker, status =
      line:match("^(%d+)\t(%$%d+)\t(%%%d+)\t([^\t]*)\t([^\t]+)$")
    if pid == origin.pid and session == origin.session and pane == origin.pane then
      if status ~= "off" and status ~= "on" and not status:match("^[2-5]$") then
        return nil, "Unexpected tmux status setting"
      end
      return { configured = marker == "1", status_enabled = status ~= "off" }
    end
  end
  return nil, "The tmux context changed; reopen the editor in its current session"
end

function M.dotfiles_helper(name, nvim_root)
  local paths =
    { git_summary = "dotfiles/git-summary", location_pins = "tmux/scripts/location-pins" }
  local relative = paths[name]
  if not relative then
    return nil, "Unknown dotfiles helper"
  end
  local root = nvim_root or vim.env.DOTFILES_NVIM_ROOT or vim.fn.stdpath("config")
  local helper = vim.fs.normalize(vim.fn.fnamemodify(root, ":p") .. "/../" .. relative)
  if not is_executable(helper) then
    return nil, "The optional " .. name .. " helper is unavailable"
  end
  return helper
end

function M.detect()
  local sysname = vim.uv.os_uname().sysname

  if sysname == "Darwin" then
    return "macos"
  end

  if sysname == "Linux" then
    return "linux"
  end

  error("Unsupported operating system: " .. sysname)
end

function M.select_clipboard(context)
  local selected_platform = assert(context.platform, "clipboard context requires platform")
  local environment = assert(context.environment, "clipboard context requires environment")
  local executable = assert(context.executable, "clipboard context requires executable")

  if selected_platform == "macos" and executable("pbcopy") and executable("pbpaste") then
    return "pbcopy"
  end

  if
    selected_platform == "linux"
    and environment.WAYLAND_DISPLAY
    and executable("wl-copy")
    and executable("wl-paste")
  then
    return "wl-copy"
  end

  if environment.TMUX and executable("tmux") then
    return "tmux"
  end

  return "osc52"
end

function M.clipboard_definition(name)
  if name == "pbcopy" then
    return {
      name = "pbcopy",
      copy = {
        ["+"] = { "pbcopy" },
        ["*"] = { "pbcopy" },
      },
      paste = {
        ["+"] = { "pbpaste" },
        ["*"] = { "pbpaste" },
      },
      cache_enabled = 0,
    }
  end

  if name == "wl-copy" then
    return {
      name = "wl-copy",
      copy = {
        ["+"] = { "wl-copy", "--type", "text/plain" },
        ["*"] = { "wl-copy", "--primary", "--type", "text/plain" },
      },
      paste = {
        ["+"] = { "wl-paste", "--no-newline" },
        ["*"] = { "wl-paste", "--no-newline", "--primary" },
      },
      cache_enabled = 1,
    }
  end

  if name == "tmux" then
    return {
      name = "tmux",
      copy = {
        ["+"] = { "tmux", "load-buffer", "-w", "-" },
        ["*"] = { "tmux", "load-buffer", "-w", "-" },
      },
      paste = {
        ["+"] = { "tmux", "save-buffer", "-" },
        ["*"] = { "tmux", "save-buffer", "-" },
      },
      cache_enabled = 1,
    }
  end

  if name == "osc52" then
    return "osc52"
  end

  error("Unsupported clipboard provider: " .. tostring(name))
end

function M.setup()
  M.name = M.detect()
  M.clipboard_provider = M.select_clipboard({
    platform = M.name,
    environment = vim.env,
    executable = is_executable,
  })

  vim.g.dotfiles_platform = M.name
  vim.g.dotfiles_clipboard_provider = M.clipboard_provider
  vim.g.clipboard = M.clipboard_definition(M.clipboard_provider)

  if vim.env.TMUX and is_executable("tmux") then
    vim.g.smart_splits_multiplexer_integration = "tmux"
  end

  return M
end

return M
