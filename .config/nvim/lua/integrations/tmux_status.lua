local M = {}

local option_names = {
  "@dotfiles_nvim_mode",
  "@dotfiles_nvim_root",
  "@dotfiles_nvim_path",
  "@dotfiles_nvim_errors",
  "@dotfiles_nvim_warnings",
  "@dotfiles_nvim_line",
  "@dotfiles_nvim_column",
}

local allowed_modes = {
  NORMAL = true,
  INSERT = true,
  VISUAL = true,
  SELECT = true,
  REPLACE = true,
  COMMAND = true,
  PROMPT = true,
  TERMINAL = true,
}

local snapshot_keys = { "mode", "root", "path", "errors", "warnings", "line", "column" }

local function valid_pane(pane)
  return type(pane) == "string" and pane:match("^%%%d+$") ~= nil
end

local function contains_control(value)
  return value:find("[%z\1-\31\127]") ~= nil or value:find("\194[\128-\159]") ~= nil
end

local function strip_controls(value)
  return value:gsub("[%z\1-\31\127]", ""):gsub("\194[\128-\159]", "")
end

local function trim_graphemes_to_bytes(value, byte_limit)
  while #value > byte_limit do
    local characters = vim.fn.strchars(value, 1)
    if characters <= 0 then
      return ""
    end
    local shortened = vim.fn.strcharpart(value, 0, characters - 1, 1)
    if #shortened >= #value then
      return ""
    end
    value = shortened
  end
  return value
end

local function safe_text(value, byte_limit)
  value = strip_controls(tostring(value or ""))
  return trim_graphemes_to_bytes(value, byte_limit)
end

local function safe_root(value)
  value = tostring(value or "")
  if value == "" then
    return ""
  end
  if value:sub(1, 1) ~= "/" then
    return ""
  end
  if contains_control(value) or #value > 1024 then
    return ""
  end
  return value
end

local function decimal(value, minimum)
  value = tonumber(value)
  if not value or value ~= value or value == math.huge or value == -math.huge then
    value = minimum
  end
  value = math.floor(value)
  return tostring(math.min(999999999, math.max(minimum, value)))
end

local function tmux_quote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function canonicalize(snapshot)
  snapshot = snapshot or {}
  local mode = safe_text(snapshot.mode, 8)
  if not allowed_modes[mode] then
    mode = "NORMAL"
  end
  return {
    mode = mode,
    root = safe_root(snapshot.root),
    path = safe_text(snapshot.path, 512),
    errors = decimal(snapshot.errors, 0),
    warnings = decimal(snapshot.warnings, 0),
    line = decimal(snapshot.line, 1),
    column = decimal(snapshot.column, 1),
  }
end

local function copy_snapshot(snapshot)
  if snapshot == nil then
    return nil
  end
  local copy = {}
  for _, key in ipairs(snapshot_keys) do
    copy[key] = snapshot[key]
  end
  return copy
end

local function same_snapshot(left, right)
  if left == nil or right == nil then
    return left == right
  end
  for _, key in ipairs(snapshot_keys) do
    if left[key] ~= right[key] then
      return false
    end
  end
  return true
end

local function target(origin)
  return origin.session .. ":" .. origin.pane
end

local function guarded_argv(origin, condition, command, otherwise)
  return {
    "tmux",
    "-u",
    "-S",
    origin.socket,
    "if-shell",
    "-F",
    "-t",
    target(origin),
    condition,
    command,
    otherwise or "",
  }
end

local function owner_condition(owner)
  return "#{==:#{@dotfiles_nvim_owner}," .. owner .. "}"
end

local function capability_condition(origin)
  return "#{&&:#{&&:#{==:#{pid},"
    .. origin.pid
    .. "},#{==:#{session_id},"
    .. origin.session
    .. "}},#{&&:#{==:#{pane_id},"
    .. origin.pane
    .. "},#{&&:#{==:#{@dotfiles_foundation_loaded},1},#{!=:#{status},off}}}}"
end

local function update_argv(origin, owner, snapshot, first)
  local commands = {
    "set-option -pt " .. origin.pane .. " @dotfiles_nvim_owner " .. owner,
    "set-option -pt " .. origin.pane .. " @dotfiles_nvim_active 0",
  }
  for _, name in ipairs(option_names) do
    commands[#commands + 1] = "set-option -pt "
      .. origin.pane
      .. " "
      .. name
      .. " "
      .. tmux_quote(snapshot[name:gsub("^@dotfiles_nvim_", "")])
  end
  commands[#commands + 1] = "set-option -pt " .. origin.pane .. " @dotfiles_nvim_active 1"
  commands[#commands + 1] = "display-message -p " .. tmux_quote("dotfiles-nvim-status:" .. owner)
  local condition = first and "1"
    or "#{||:#{==:#{@dotfiles_nvim_owner},}," .. owner_condition(owner) .. "}"
  local guarded = "if-shell -F -t "
    .. tmux_quote(target(origin))
    .. " "
    .. tmux_quote(condition)
    .. " "
    .. tmux_quote(table.concat(commands, " ; "))
    .. " "
    .. tmux_quote("display-message -p dotfiles-nvim-owner-mismatch")
  return guarded_argv(
    origin,
    capability_condition(origin),
    guarded,
    "display-message -p dotfiles-nvim-unavailable"
  )
end

local function cleanup_argv(origin, owner)
  local names = { "@dotfiles_nvim_active" }
  vim.list_extend(names, option_names)
  names[#names + 1] = "@dotfiles_nvim_owner"
  local commands = {}
  for _, name in ipairs(names) do
    commands[#commands + 1] = "set-option -pu -t " .. origin.pane .. " " .. name
  end
  return guarded_argv(
    origin,
    "#{&&:#{==:#{pid}," .. origin.pid .. "}," .. owner_condition(owner) .. "}",
    table.concat(commands, " ; ")
  )
end

local function close_timer(timer)
  if not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

local function new(deps)
  local platform = require("config.platform")
  assert(valid_pane(deps.origin.pane), "invalid tmux pane")
  assert(type(deps.owner) == "string" and deps.owner:match("^%d+_%d+$"), "invalid owner")
  local state = {
    stopped = false,
    blocked = false,
    focused = true,
    available = false,
    capable = nil,
    attempted = false,
    may_own = false,
    needs_ack = false,
    debounce_generation = 0,
    validation_generation = 0,
    desired = nil,
    published = nil,
    in_flight = nil,
    probe_pending = false,
    cleanup_pending = false,
    warned = false,
  }
  local controller = {}
  local poll = deps.new_timer()
  local drain, launch

  local function available(value)
    if state.available == value then
      return
    end
    state.available = value
    if deps.on_available then
      deps.on_available(value)
    end
  end

  local function unavailable()
    state.capable = false
    state.published = nil
    available(false)
  end

  local function warn_once(detail)
    if state.warned then
      return
    end
    state.warned = true
    deps.notify("tmux status publication failed: " .. tostring(detail), deps.warn_level)
  end

  local function finish(flight, result)
    deps.schedule(function()
      if state.stopped or state.in_flight ~= flight then
        return
      end
      close_timer(flight.deadline)
      state.in_flight = nil
      local success = result and result.code == 0 and result.signal == 0
      if flight.expired then
        if flight.kind ~= "cleanup" then
          state.cleanup_pending = state.may_own
        end
      elseif flight.generation ~= state.validation_generation then
        -- Focus revalidation must precede any handoff from an older child.
      elseif flight.kind == "probe" then
        local capability = success and platform.parse_tmux_probe(deps.origin, result)
        if capability and capability.configured and capability.status_enabled then
          state.capable, state.needs_ack = true, true
        else
          unavailable()
          state.cleanup_pending = state.may_own
        end
      elseif flight.kind == "cleanup" then
        if success then
          state.may_own = false
        end
      elseif success and result.stdout == "dotfiles-nvim-status:" .. deps.owner .. "\n" then
        state.published = flight.snapshot
        state.needs_ack, state.warned = false, false
        available(true)
      else
        unavailable()
        if success and result.stdout == "dotfiles-nvim-owner-mismatch\n" then
          state.blocked, state.may_own = true, false
          poll:stop()
        else
          state.cleanup_pending = state.may_own
          if not success or result.stdout ~= "dotfiles-nvim-unavailable\n" then
            warn_once(
              result and result.stderr ~= "" and result.stderr
                or "missing publication acknowledgment"
            )
          end
        end
      end
      drain()
    end)
  end

  launch = function(kind, argv, snapshot)
    local flight = {
      kind = kind,
      snapshot = snapshot,
      deadline = deps.new_timer(),
      generation = state.validation_generation,
    }
    state.in_flight = flight
    local ok, handle = pcall(deps.system, argv, { text = true }, function(result)
      finish(flight, result)
    end)
    if not ok or not handle then
      finish(
        flight,
        { code = 1, signal = 0, stdout = "", stderr = tostring(handle or "missing process handle") }
      )
      return
    end
    flight.handle = handle
    flight.deadline:start(1000, 0, function()
      deps.schedule(function()
        if state.stopped or state.in_flight ~= flight then
          return
        end
        flight.expired = true
        close_timer(flight.deadline)
        unavailable()
        -- Retain the slot until its exit callback reaps the force-killed client.
        pcall(handle.kill, handle, 9)
      end)
    end)
  end

  drain = function()
    if state.stopped or state.blocked or state.in_flight then
      return
    end
    if state.cleanup_pending then
      state.cleanup_pending = false
      launch("cleanup", cleanup_argv(deps.origin, deps.owner))
    elseif state.probe_pending then
      state.probe_pending = false
      launch("probe", platform.tmux_probe_argv(deps.origin))
    elseif
      state.capable
      and state.desired
      and (state.needs_ack or not same_snapshot(state.desired, state.published))
    then
      local first = not state.attempted
      state.attempted, state.may_own = true, true
      launch(
        "write",
        update_argv(deps.origin, deps.owner, state.desired, first),
        copy_snapshot(state.desired)
      )
    end
  end

  function controller:request(snapshot)
    if state.stopped or state.blocked then
      return
    end
    state.desired = canonicalize(snapshot)
    state.debounce_generation = state.debounce_generation + 1
    local generation = state.debounce_generation
    deps.defer(function()
      if state.stopped or state.blocked or generation ~= state.debounce_generation then
        return
      end
      if state.capable == nil then
        state.probe_pending = true
      end
      drain()
    end, 75)
  end

  function controller:start(snapshot)
    self:request(snapshot)
  end

  function controller:refresh()
    if state.stopped or state.blocked then
      return
    end
    state.probe_pending = true
    drain()
  end

  local function start_poll()
    poll:start(5000, 5000, function()
      deps.schedule(function()
        controller:refresh()
      end)
    end)
  end

  function controller:set_focused(focused)
    if state.stopped or state.blocked then
      return
    end
    focused = not not focused
    if not focused and not state.focused then
      return
    end
    state.focused = focused
    if focused then
      state.validation_generation = state.validation_generation + 1
      unavailable()
      start_poll()
      self:refresh()
    else
      poll:stop()
    end
  end

  function controller:stop()
    if state.stopped then
      return
    end
    state.stopped = true
    state.debounce_generation = state.debounce_generation + 1
    available(false)
    close_timer(poll)
    local flight = state.in_flight
    state.in_flight = nil
    if flight then
      close_timer(flight.deadline)
      if flight.handle then
        pcall(flight.handle.kill, flight.handle, 9)
        pcall(flight.handle.wait, flight.handle, 1000)
      end
    end
    if state.may_own and not state.blocked then
      local ok, handle = pcall(deps.system, cleanup_argv(deps.origin, deps.owner), { text = true })
      if ok and handle then
        local waited, result = pcall(handle.wait, handle, 1000)
        if not waited or not result or result.code == 124 then
          pcall(handle.kill, handle, 9)
          pcall(handle.wait, handle, 1000)
        end
      end
    end
    state.desired, state.published = nil, nil
  end

  function controller:debug_state()
    return {
      stopped = state.stopped,
      claimed = state.available,
      available = state.available,
      blocked = state.blocked,
      desired = copy_snapshot(state.desired),
      published = copy_snapshot(state.published),
      in_flight = state.in_flight ~= nil,
      warned = state.warned,
    }
  end

  start_poll()
  return controller
end

function M.setup(options)
  options = options or {}
  if vim.g.dotfiles_tmux_integration == false or vim.fn.executable("tmux") ~= 1 then
    return nil
  end
  local origin = require("config.platform").tmux_origin({
    TMUX = vim.env.TMUX,
    TMUX_PANE = options.pane or vim.env.TMUX_PANE,
  })
  if not origin then
    return nil
  end
  local publisher = new({
    origin = origin,
    owner = string.format("%d_%d", vim.fn.getpid(), vim.uv.hrtime()),
    system = vim.system,
    schedule = vim.schedule,
    defer = vim.defer_fn,
    new_timer = function()
      return assert(vim.uv.new_timer())
    end,
    notify = vim.notify,
    warn_level = vim.log.levels.WARN,
    on_available = options.on_available,
  })
  if options.snapshot then
    publisher:start(options.snapshot)
  end
  return publisher
end

M._test = {
  canonicalize = canonicalize,
  cleanup_argv = cleanup_argv,
  decimal = decimal,
  new = new,
  tmux_quote = tmux_quote,
  update_argv = update_argv,
  valid_pane = valid_pane,
}
return M
