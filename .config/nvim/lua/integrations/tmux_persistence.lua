local M = {}
local platform = require("config.platform")
local active_controller

local session_options = {
  "blank",
  "buffers",
  "curdir",
  "folds",
  "help",
  "tabpages",
  "winsize",
}

local function valid_pane(value)
  return type(value) == "string" and value:match("^%%%d+$") ~= nil
end

local function state_root()
  local base = vim.env.XDG_STATE_HOME
  if type(base) ~= "string" or base == "" then
    base = vim.fs.joinpath(assert(vim.env.HOME), ".local", "state")
  end
  return vim.fs.normalize(vim.fs.joinpath(base, "dotfiles", "tmux"))
end

local function path_within(root, path)
  root = vim.fs.normalize(root)
  path = vim.fs.normalize(path)
  return path:sub(1, #root + 1) == root .. "/"
end

local function checkpoint_path(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  path = vim.fs.normalize(path)
  local root = state_root()
  if not path_within(root, path) then
    return nil
  end
  if not path:find("/snapshots/.staging%-[^/]+/nvim/[^/]+%.vim$") then
    return nil
  end

  local parent = vim.fs.dirname(path)
  local real_root = vim.uv.fs_realpath(root)
  local real_parent = vim.uv.fs_realpath(parent)
  if not real_root or not real_parent then
    return nil
  end
  local real_path = vim.fs.joinpath(real_parent, vim.fs.basename(path))
  if not path_within(real_root, real_path) then
    return nil
  end
  local existing = vim.uv.fs_lstat(path)
  if existing and existing.type == "link" then
    return nil
  end
  return path
end

function M.checkpoint(path)
  path = checkpoint_path(path)
  if not path then
    return "error:invalid checkpoint path"
  end

  local previous = vim.o.sessionoptions
  vim.o.sessionoptions = table.concat(session_options, ",")
  local ok, result = xpcall(function()
    vim.cmd("silent mksession! " .. vim.fn.fnameescape(path))
    local stat = vim.uv.fs_lstat(path)
    assert(stat and stat.type == "file" and stat.size > 0, "empty session file")
    assert(vim.uv.fs_chmod(path, 384), "could not make session private")
  end, debug.traceback)
  vim.o.sessionoptions = previous
  if not ok then
    return "error:" .. tostring(result):gsub("[\r\n]", " ")
  end
  return "ok"
end

local function registration_argv(origin, owner, server)
  local guard = string.format(
    "#{&&:#{==:#{pid},%s},#{&&:#{==:#{session_id},%s},#{&&:#{==:#{pane_id},%s},#{==:#{@dotfiles_foundation_loaded},1}}}}",
    origin.pid,
    origin.session,
    origin.pane
  )
  local command = table.concat({
    "set-option -pt",
    origin.pane,
    "@dotfiles_nvim_persistence_owner",
    owner,
    "; set-option -pt",
    origin.pane,
    "@dotfiles_nvim_server",
    "'" .. server:gsub("'", "'\\''") .. "'",
    "; display-message -p dotfiles-nvim-persistence:" .. owner,
  }, " ")
  return {
    "tmux",
    "-u",
    "-S",
    origin.socket,
    "if-shell",
    "-F",
    "-t",
    origin.session .. ":" .. origin.pane,
    guard,
    command,
    "",
  }
end

local function cleanup_argv(socket, pane, owner)
  local clear = table.concat({
    "set-option -pu -t",
    pane,
    "@dotfiles_nvim_server",
    "; set-option -pu -t",
    pane,
    "@dotfiles_nvim_persistence_owner",
  }, " ")
  return {
    "tmux",
    "-u",
    "-S",
    socket,
    "if-shell",
    "-F",
    "-t",
    pane,
    "#{==:#{@dotfiles_nvim_persistence_owner}," .. owner .. "}",
    clear,
    "",
  }
end

local function run(deps, argv, acknowledgment)
  local ok, handle = pcall(deps.system, argv, { text = true })
  if not ok or not handle then
    return false
  end
  local waited, result = pcall(handle.wait, handle, 1000)
  return waited
    and result
    and result.code == 0
    and result.signal == 0
    and (not acknowledgment or vim.trim(result.stdout or "") == acknowledgment)
end

local function new(deps)
  assert(valid_pane(deps.pane), "invalid tmux pane")
  assert(type(deps.owner) == "string" and deps.owner:match("^%d+_%d+$"), "invalid owner")
  assert(type(deps.server) == "string" and deps.server ~= "", "invalid Neovim server")

  local started = false
  local stopped = false
  local controller = {}

  function controller:start()
    if stopped or started then
      return started
    end
    started = run(
      deps,
      registration_argv(deps.origin, deps.owner, deps.server),
      "dotfiles-nvim-persistence:" .. deps.owner
    )
    if not started then
      run(deps, cleanup_argv(deps.socket, deps.pane, deps.owner))
    end
    return started
  end

  function controller:stop()
    if stopped then
      return
    end
    stopped = true
    if started then
      run(deps, cleanup_argv(deps.socket, deps.pane, deps.owner))
    end
    started = false
  end

  return controller
end

function M.setup(options)
  if active_controller then
    active_controller:stop()
    active_controller = nil
  end
  options = options or {}
  if vim.g.dotfiles_tmux_integration == false then
    return nil
  end
  local origin = platform.tmux_origin(vim.env)
  if not origin then
    return nil
  end
  local pane = options.pane or origin.pane
  local server = options.server or vim.v.servername
  if pane ~= origin.pane or not valid_pane(pane) or vim.fn.executable("tmux") ~= 1 then
    return nil
  end
  if type(server) ~= "string" or server == "" then
    return nil
  end

  local ok, process = pcall(vim.system, platform.tmux_probe_argv(origin), { text = true })
  if not ok or not process then
    return nil
  end
  local waited, result = pcall(process.wait, process, 1000)
  local availability = waited and platform.parse_tmux_probe(origin, result)
  if not availability or not availability.configured then
    return nil
  end

  local controller = new({
    socket = origin.socket,
    origin = origin,
    pane = pane,
    owner = string.format("%d_%d", vim.fn.getpid(), vim.uv.hrtime()),
    server = server,
    system = vim.system,
  })
  if not controller:start() then
    vim.notify("tmux persistence registration failed", vim.log.levels.WARN)
    return nil
  end

  active_controller = controller
  local group = vim.api.nvim_create_augroup("DotfilesTmuxPersistence", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    once = true,
    callback = function()
      controller:stop()
    end,
  })
  return controller
end

M._test = {
  new = new,
  path_within = path_within,
  session_options = function()
    return vim.deepcopy(session_options)
  end,
  valid_pane = valid_pane,
}

return M
