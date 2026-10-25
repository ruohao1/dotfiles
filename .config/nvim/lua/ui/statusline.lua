local M = {}

local palette = {
  bg = "#1A1B26",
  fg = "#a9b1d6",
  muted_fg = "#787c99",
  muted = "#24283b",
  active = "#2A2F41",
  blue = "#7aa2f7",
  cyan = "#7dcfff",
  green = "#73daca",
  magenta = "#bb9af7",
  red = "#f7768e",
  yellow = "#e0af68",
}

local profiles = {
  compact = {
    name = "compact",
    git = 22,
    path = 13,
    diagnostic = 9,
    line = 9999,
    column = 999,
  },
  medium = {
    name = "medium",
    git = 26,
    path = 14,
    diagnostic = 99,
    line = 99999,
    column = 999,
  },
  wide = {
    name = "wide",
    git = 36,
    path = 20,
    diagnostic = 999,
    line = 999999,
    column = 9999,
  },
  narrow = {
    name = "narrow",
    mode = 1,
    git = 0,
    path = 0,
    diagnostic = 0,
    line = 9999,
    column = 999,
  },
}

local mode_groups = {
  NORMAL = "DotfilesStatusModeNormal",
  INSERT = "DotfilesStatusModeInsert",
  VISUAL = "DotfilesStatusModeVisual",
  SELECT = "DotfilesStatusModeVisual",
  REPLACE = "DotfilesStatusModeReplace",
  COMMAND = "DotfilesStatusModeCommand",
  PROMPT = "DotfilesStatusModeCommand",
  TERMINAL = "DotfilesStatusModeTerminal",
}

local function profile_for_width(width)
  if width < 80 then
    return profiles.narrow
  end
  if width < 100 then
    return profiles.compact
  end
  if width < 120 then
    return profiles.medium
  end
  return profiles.wide
end

local function normalize_mode(mode)
  if mode == "t" then
    return "TERMINAL"
  end
  if
    mode == "v"
    or mode == "vs"
    or mode == "V"
    or mode == "Vs"
    or mode == "\22"
    or mode == "\22s"
  then
    return "VISUAL"
  end
  if mode == "s" or mode == "S" or mode == "\19" then
    return "SELECT"
  end
  local first = mode:sub(1, 1)
  if first == "i" then
    return "INSERT"
  end
  if first == "R" then
    return "REPLACE"
  end
  if first == "c" then
    return "COMMAND"
  end
  if first == "r" or first == "!" then
    return "PROMPT"
  end
  return "NORMAL"
end

local function sanitize(value, byte_limit)
  value = tostring(value or "")
  value = value:gsub("[%z\1-\31\127]", "")
  value = value:gsub("\194[\128-\159]", "")
  while byte_limit and #value > byte_limit do
    value = vim.fn.strcharpart(value, 0, math.max(0, vim.fn.strchars(value) - 1))
  end
  return value
end

local function escape_statusline(value)
  return sanitize(value):gsub("%%", "%%%%")
end

local function saturate(value, maximum)
  value = math.max(0, math.floor(tonumber(value) or 0))
  return value > maximum and (tostring(maximum) .. "+") or tostring(value)
end

local function truncate_left(value, maximum)
  value = sanitize(value)
  if maximum <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(value) <= maximum then
    return value
  end
  local marker = "…"
  local budget = maximum - vim.fn.strdisplaywidth(marker)
  if budget <= 0 then
    return marker
  end
  local chars = vim.fn.strchars(value, 1)
  local suffix = ""
  for start = chars - 1, 0, -1 do
    local candidate = vim.fn.strcharpart(value, start, chars - start, 1)
    if vim.fn.strdisplaywidth(candidate) > budget then
      break
    end
    suffix = candidate
  end
  return marker .. suffix
end

local semantic_fields = {
  "mode",
  "root",
  "path",
  "modified",
  "errors",
  "warnings",
  "line",
  "column",
}

local function finite_integer(value, minimum)
  value = tonumber(value)
  if not value or value ~= value or value == math.huge or value == -math.huge then
    return minimum
  end
  return math.max(minimum, math.floor(value))
end

local function sanitize_tail_bytes(value, byte_limit)
  value = sanitize(value)
  byte_limit = math.max(0, math.floor(tonumber(byte_limit) or 0))
  while #value > byte_limit do
    value = vim.fn.strcharpart(value, 1)
  end
  return value
end

local function canonical_mode(mode)
  mode = tostring(mode or "")
  if mode_groups[mode] then
    return mode
  end
  return normalize_mode(mode)
end

local function display_path(context)
  context = context or {}
  local name = tostring(context.name or "")
  local buftype = tostring(context.buftype or "")

  if buftype ~= "" then
    local tail = sanitize(name):match("([^/]+)$") or ""
    return sanitize_tail_bytes(tail, 512)
  end
  if name == "" then
    return "[No Name]"
  end

  local base = context.root
  if type(base) ~= "string" or base == "" then
    base = context.cwd
  end
  if type(base) == "string" and base ~= "" then
    local ok, relative = pcall(vim.fs.relpath, base, name)
    if
      ok
      and type(relative) == "string"
      and relative ~= ""
      and relative ~= "."
      and relative ~= ".."
      and not relative:match("^%.%./")
    then
      return sanitize_tail_bytes(relative, 512)
    end
  end

  return sanitize_tail_bytes(vim.fs.basename(name) or "", 512)
end

local function build_snapshot(context)
  context = context or {}
  local name = tostring(context.name or "")
  local buftype = tostring(context.buftype or "")
  local normal_named = buftype == "" and name ~= ""
  local root = normal_named and context.root or nil
  if type(root) ~= "string" or root == "" then
    root = nil
  end

  return {
    mode = canonical_mode(context.mode),
    root = root,
    path = display_path({
      name = name,
      buftype = buftype,
      root = root,
      cwd = context.cwd,
    }),
    modified = context.modified == true,
    errors = finite_integer(context.errors, 0),
    warnings = finite_integer(context.warnings, 0),
    line = finite_integer(context.line, 1),
    column = finite_integer(context.column, 1),
    width = finite_integer(context.width, 0),
  }
end

local function live_snapshot()
  local bufnr = vim.api.nvim_get_current_buf()
  local buftype = vim.bo[bufnr].buftype
  local name = vim.api.nvim_buf_get_name(bufnr)
  local root = nil

  if buftype == "" and name ~= "" then
    name = vim.fs.abspath(name)
    root = vim.fs.root(name, ".git")
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  return build_snapshot({
    mode = vim.api.nvim_get_mode().mode,
    name = name,
    buftype = buftype,
    modified = vim.bo[bufnr].modified,
    root = root,
    cwd = vim.fn.getcwd(0, 0),
    errors = #vim.diagnostic.get(bufnr, {
      severity = vim.diagnostic.severity.ERROR,
    }),
    warnings = #vim.diagnostic.get(bufnr, {
      severity = vim.diagnostic.severity.WARN,
    }),
    line = cursor[1],
    column = vim.fn.virtcol("."),
    width = vim.api.nvim_win_get_width(0),
  })
end

local function copy_semantic(snapshot)
  local copy = {}
  snapshot = snapshot or {}
  for _, field in ipairs(semantic_fields) do
    if snapshot[field] ~= nil then
      copy[field] = snapshot[field]
    end
  end
  return copy
end

local function canonical_semantic(snapshot)
  snapshot = snapshot or {}
  local root = snapshot.root
  if type(root) ~= "string" or root == "" then
    root = nil
  end
  return {
    mode = canonical_mode(snapshot.mode),
    root = root,
    path = sanitize_tail_bytes(snapshot.path, 512),
    modified = snapshot.modified == true,
    errors = finite_integer(snapshot.errors, 0),
    warnings = finite_integer(snapshot.warnings, 0),
    line = finite_integer(snapshot.line, 1),
    column = finite_integer(snapshot.column, 1),
  }
end

local function apply_highlights()
  local set = vim.api.nvim_set_hl
  set(0, "DotfilesStatusBase", { fg = palette.fg, bg = palette.bg })
  set(0, "DotfilesStatusGit", { fg = palette.green, bg = palette.muted })
  set(0, "DotfilesStatusContext", { fg = palette.fg, bg = palette.active })
  set(0, "DotfilesStatusError", { fg = palette.red, bg = palette.active, bold = true })
  set(0, "DotfilesStatusWarning", { fg = palette.yellow, bg = palette.active, bold = true })
  set(0, "DotfilesStatusModeNormal", { fg = palette.bg, bg = palette.blue, bold = true })
  set(0, "DotfilesStatusModeInsert", { fg = palette.bg, bg = palette.green, bold = true })
  set(0, "DotfilesStatusModeVisual", { fg = palette.bg, bg = palette.magenta, bold = true })
  set(0, "DotfilesStatusModeReplace", { fg = palette.bg, bg = palette.red, bold = true })
  set(0, "DotfilesStatusModeCommand", { fg = palette.bg, bg = palette.yellow, bold = true })
  set(0, "DotfilesStatusModeTerminal", { fg = palette.bg, bg = palette.cyan, bold = true })
end

local function highlighted(group, text)
  return "%#" .. group .. "#" .. escape_statusline(text)
end

local function render_parts(snapshot, git_summary)
  snapshot = snapshot or {}
  local profile = profile_for_width(finite_integer(snapshot.width, 0))
  local mode = canonical_mode(snapshot.mode)

  local mode_content
  if profile.name == "narrow" then
    mode_content = vim.fn.strcharpart(mode, 0, 1)
  else
    mode_content = mode
  end

  local mode_text = " " .. mode_content .. " "
  local left_text = mode_text
  local left_expression = highlighted(mode_groups[mode] or mode_groups.NORMAL, mode_text)

  local git_text = ""
  if profile.git > 0 then
    git_text = sanitize_tail_bytes(git_summary, 256)
    git_text = truncate_left(git_text, profile.git)
  end
  if git_text ~= "" then
    local git_block = " " .. git_text .. " "
    left_text = left_text .. git_block
    left_expression = left_expression .. highlighted("DotfilesStatusGit", git_block)
  end
  left_expression = left_expression .. "%#DotfilesStatusBase#"

  local components = {}
  local function add_component(group, text)
    table.insert(components, { group = group, text = text })
  end

  if profile.path > 0 then
    local path =
      truncate_left(snapshot.path or "", profile.path - (snapshot.modified == true and 4 or 0))
    if path ~= "" then
      add_component("DotfilesStatusContext", path)
    end
  end
  if snapshot.modified == true then
    add_component("DotfilesStatusWarning", "[+]")
  end

  local errors = finite_integer(snapshot.errors, 0)
  local warnings = finite_integer(snapshot.warnings, 0)
  if profile.diagnostic > 0 and errors > 0 then
    add_component("DotfilesStatusError", "E" .. saturate(errors, profile.diagnostic))
  end
  if profile.diagnostic > 0 and warnings > 0 then
    add_component("DotfilesStatusWarning", "W" .. saturate(warnings, profile.diagnostic))
  end

  local cursor = saturate(finite_integer(snapshot.line, 1), profile.line)
    .. ":"
    .. saturate(finite_integer(snapshot.column, 1), profile.column)
  add_component("DotfilesStatusContext", cursor)

  local right_text_parts = {}
  local right_expression = "%#DotfilesStatusContext# "
  for index, component in ipairs(components) do
    if index > 1 then
      right_expression = right_expression .. "%#DotfilesStatusContext# "
    end
    table.insert(right_text_parts, component.text)
    right_expression = right_expression .. highlighted(component.group, component.text)
  end
  right_expression = right_expression .. "%#DotfilesStatusContext# " .. "%#DotfilesStatusBase#"

  local right_text = " " .. table.concat(right_text_parts, " ") .. " "
  return {
    left_text = left_text,
    right_text = right_text,
    expression = left_expression .. "%=" .. right_expression,
  }
end

local function make_renderer(snapshot_provider, git_provider, width_provider)
  return function()
    local snapshot = {}
    for key, value in pairs(snapshot_provider() or {}) do
      snapshot[key] = value
    end
    snapshot.width = width_provider()
    return render_parts(snapshot, git_provider() or "").expression
  end
end

local function new_git_cache(deps)
  local state = {
    root = nil,
    profile = nil,
    summary = "",
    generation = 0,
    focused = true,
    stopped = false,
    retry_at = 0,
    in_flight = nil,
    pending = nil,
  }
  local cache = {}
  local timer = deps.new_timer()
  local start

  local function is_current(request)
    return request
      and request.generation == state.generation
      and request.root == state.root
      and request.profile == state.profile
  end

  local function request_now()
    if not state.root or not state.profile then
      return nil
    end
    return {
      generation = state.generation,
      root = state.root,
      profile = state.profile,
    }
  end

  local function clean_output(output)
    output = tostring(output or ""):gsub("\r?\n$", "")
    return sanitize(output, 256)
  end

  local function complete(slot, result)
    if state.in_flight ~= slot then
      return
    end
    state.in_flight = nil
    if state.stopped then
      return
    end

    if is_current(slot.request) then
      if result and result.code == 0 and result.signal == 0 then
        state.summary = clean_output(result.stdout)
        state.retry_at = 0
      else
        state.summary = ""
        state.retry_at = deps.now() + 5000
      end
      deps.redraw()
    end

    local pending = state.pending
    state.pending = nil
    if is_current(pending) then
      local transitioned = pending.generation ~= slot.request.generation
        or pending.root ~= slot.request.root
        or pending.profile ~= slot.request.profile
      start(pending, transitioned)
    end
  end

  start = function(request, bypass_backoff)
    if state.stopped or not is_current(request) then
      return
    end
    if state.in_flight then
      state.pending = request
      return
    end
    if not bypass_backoff and deps.now() < state.retry_at then
      return
    end

    local slot = { request = request, handle = nil }
    state.in_flight = slot
    local argv = {
      deps.helper,
      "--path",
      request.root,
      "--profile",
      request.profile,
    }
    local ok, handle = pcall(deps.system, argv, {
      text = true,
      timeout = 4000,
    }, function(result)
      deps.schedule(function()
        complete(slot, result)
      end)
    end)
    if ok then
      slot.handle = handle
    else
      deps.schedule(function()
        complete(slot, { code = 1, signal = 0, stdout = "", stderr = tostring(handle) })
      end)
    end
  end

  function cache:update(root, profile, reason)
    if state.stopped then
      return
    end
    local changed = root ~= state.root or profile ~= state.profile
    if changed then
      local had_summary = state.summary ~= ""
      state.generation = state.generation + 1
      state.root = root
      state.profile = profile
      state.summary = ""
      state.retry_at = 0
      state.pending = nil
      if had_summary then
        deps.redraw()
      end
    end
    if not root or not profile then
      return
    end
    if reason == "periodic" and not state.focused then
      return
    end
    start(request_now(), changed)
  end

  function cache:set_focused(focused, context)
    if state.stopped then
      return
    end
    focused = not not focused
    local changed = focused ~= state.focused
    state.focused = focused

    if not focused then
      if changed then
        timer:stop()
      end
      return
    end

    if changed then
      timer:start(5000, 5000, function()
        deps.schedule(function()
          cache:update(state.root, state.profile, "periodic")
        end)
      end)
    end

    local root = state.root
    local profile = state.profile
    if context then
      root = context.root
      profile = context.profile
    end
    cache:update(root, profile, "FocusGained")
  end

  function cache:get()
    return state.summary
  end

  function cache:debug_state()
    return {
      root = state.root,
      profile = state.profile,
      generation = state.generation,
      focused = state.focused,
      stopped = state.stopped,
      retry_at = state.retry_at,
      has_in_flight = state.in_flight ~= nil,
      has_pending = state.pending ~= nil,
    }
  end

  function cache:stop()
    if state.stopped then
      return
    end
    state.stopped = true
    state.pending = nil
    timer:stop()
    if not timer:is_closing() then
      timer:close()
    end
    local slot = state.in_flight
    state.in_flight = nil
    if slot and slot.handle and slot.handle.kill then
      pcall(slot.handle.kill, slot.handle, 15)
    end
  end

  timer:start(5000, 5000, function()
    deps.schedule(function()
      cache:update(state.root, state.profile, "periodic")
    end)
  end)
  return cache
end

local function make_production_git_cache(runtime_deps)
  local helper = require("config.platform").dotfiles_helper("git_summary")
  if not helper then
    return nil
  end

  return new_git_cache({
    helper = helper,
    now = function()
      return vim.uv.now()
    end,
    new_timer = function()
      return assert(vim.uv.new_timer())
    end,
    schedule = runtime_deps.schedule,
    system = vim.system,
    redraw = runtime_deps.redraw,
  })
end

local runtime = nil
local owned_statusline = "%!v:lua.dotfiles_statusline()"

local git_refresh_events = {
  VimEnter = true,
  BufEnter = true,
  WinEnter = true,
  BufFilePost = true,
  BufWritePost = true,
  DirChanged = true,
}

local semantic_only_events = {
  BufModifiedSet = true,
  ModeChanged = true,
  CursorMoved = true,
  CursorMovedI = true,
  DiagnosticChanged = true,
}

local function valid_tmux_pane(pane)
  return type(pane) == "string" and pane:match("^%%%d+$") ~= nil
end

local function production_dependencies(overrides)
  local deps = {
    inside_tmux = type(vim.env.TMUX) == "string" and vim.env.TMUX ~= "",
    pane = vim.env.TMUX_PANE,
    executable = vim.fn.executable,
    width = function()
      return vim.api.nvim_win_get_width(0)
    end,
    live_snapshot = live_snapshot,
    schedule = vim.schedule,
    set_option = function(name, value)
      vim.o[name] = value
    end,
    apply_highlights = apply_highlights,
    redraw = function()
      if vim.api.nvim_get_mode().blocking then
        return
      end
      vim.cmd.redrawstatus()
    end,
    create_augroup = vim.api.nvim_create_augroup,
    create_autocmd = vim.api.nvim_create_autocmd,
    install_render = function()
      _G.dotfiles_statusline = M.render
      vim.o.statusline = owned_statusline
    end,
    clear_render = function()
      if _G.dotfiles_statusline == M.render then
        if vim.o.statusline == owned_statusline then
          vim.o.statusline = ""
        end
        _G.dotfiles_statusline = nil
      end
    end,
    publisher_setup = function(options)
      return require("integrations.tmux_status").setup(options)
    end,
  }

  for key, value in pairs(overrides or {}) do
    deps[key] = value
  end
  if not deps.make_git_cache then
    deps.make_git_cache = function()
      return make_production_git_cache(deps)
    end
  end
  return deps
end

local function new_runtime(deps)
  local state = {
    stopped = false,
    startup_visible = false,
    snapshot = nil,
    profile = nil,
    cache = nil,
    publisher = nil,
    group = nil,
    render_installed = false,
    remote_available = false,
    focused = true,
    publisher_generation = 0,
  }
  local controller = {}
  local start_publisher, set_remote_available

  local function apply_status_ownership()
    local laststatus = (state.remote_available or state.startup_visible) and 0 or 3
    deps.set_option("laststatus", laststatus)
  end

  deps.set_option("cmdheight", 0)
  deps.set_option("showmode", false)
  apply_status_ownership()
  deps.apply_highlights()

  local initial = deps.live_snapshot()
  state.snapshot = canonical_semantic(initial)
  state.profile = profile_for_width(initial.width ~= nil and initial.width or deps.width()).name

  local renderer = make_renderer(function()
    return state.snapshot
  end, function()
    return state.cache and state.cache:get() or ""
  end, deps.width)

  local function publish()
    if state.publisher then
      state.publisher:request(copy_semantic(state.snapshot))
    end
  end

  local function replace_snapshot(refresh_git, reason)
    local fresh = deps.live_snapshot()
    state.snapshot = canonical_semantic(fresh)
    publish()
    if refresh_git and state.cache then
      state.profile = profile_for_width(fresh.width ~= nil and fresh.width or deps.width()).name
      state.cache:update(state.snapshot.root, state.profile, reason)
    end
    deps.redraw()
  end

  function controller:render()
    if state.stopped then
      return ""
    end
    return renderer()
  end

  function controller:snapshot()
    if state.stopped then
      return nil
    end
    local snapshot = copy_semantic(state.snapshot)
    snapshot.width = deps.width()
    return snapshot
  end

  function controller:refresh(reason)
    if state.stopped then
      return
    end
    reason = reason or "manual"

    if reason == "ColorScheme" then
      deps.apply_highlights()
      deps.redraw()
      return
    end
    if reason == "VimSuspend" then
      state.focused = false
      if state.publisher then
        state.publisher:stop()
        state.publisher = nil
      end
      set_remote_available(false)
      if state.cache then
        state.cache:set_focused(false)
      end
      return
    end
    if reason == "VimResume" then
      state.focused = true
      start_publisher()
      reason = "FocusGained"
    end
    if reason == "manual" and state.publisher then
      state.publisher:refresh()
    end
    if reason == "FocusLost" then
      state.focused = false
      if state.publisher then
        state.publisher:set_focused(false)
      end
      if state.cache then
        state.cache:set_focused(false)
      end
      return
    end
    if reason == "FocusGained" then
      state.focused = true
      if state.publisher then
        state.publisher:set_focused(true)
      end
      local fresh = deps.live_snapshot()
      state.snapshot = canonical_semantic(fresh)
      state.profile = profile_for_width(fresh.width ~= nil and fresh.width or deps.width()).name
      publish()
      if state.cache then
        state.cache:set_focused(true, {
          root = state.snapshot.root,
          profile = state.profile,
        })
      end
      deps.redraw()
      return
    end
    if reason == "VimResized" or reason == "WinResized" then
      local next_profile = profile_for_width(deps.width()).name
      if next_profile ~= state.profile then
        state.profile = next_profile
        if state.cache then
          state.cache:update(state.snapshot.root, state.profile, reason)
        end
      end
      deps.redraw()
      return
    end
    if semantic_only_events[reason] then
      replace_snapshot(false, reason)
      return
    end
    replace_snapshot(git_refresh_events[reason] or reason == "manual", reason)
  end

  function controller:set_startup_visible(visible)
    assert(type(visible) == "boolean", "startup visibility must be boolean")
    if state.stopped then
      return false
    end
    if state.startup_visible == visible then
      return true
    end
    state.startup_visible = visible
    apply_status_ownership()
    return true
  end

  function controller:shutdown()
    if state.stopped then
      return
    end
    state.stopped = true
    if state.publisher then
      state.publisher:stop()
      state.publisher = nil
    end
    if state.cache then
      state.cache:stop()
      state.cache = nil
    end
    deps.clear_render()
    state.render_installed = false
  end

  function controller:is_stopped()
    return state.stopped
  end

  function controller:debug_state()
    return {
      stopped = state.stopped,
      startup_visible = state.startup_visible,
      snapshot = copy_semantic(state.snapshot),
      profile = state.profile,
      has_cache = state.cache ~= nil,
      has_publisher = state.publisher ~= nil,
      group = state.group,
      render_installed = state.render_installed,
    }
  end

  deps.install_render()
  state.render_installed = true
  set_remote_available = function(value)
    if state.stopped or state.remote_available == value then
      return
    end
    state.remote_available = value
    if value then
      if state.cache then
        state.cache:stop()
        state.cache = nil
      end
    elseif not state.cache then
      state.cache = deps.make_git_cache()
      if state.cache then
        state.cache:set_focused(state.focused)
        if state.focused then
          state.cache:update(state.snapshot.root, state.profile, "fallback")
        end
      end
    end
    apply_status_ownership()
    deps.redraw()
  end
  state.cache = deps.make_git_cache()
  if state.cache then
    state.cache:update(state.snapshot.root, state.profile, "setup")
  end
  start_publisher = function()
    if not deps.inside_tmux or not valid_tmux_pane(deps.pane) or deps.executable("tmux") ~= 1 then
      return
    end
    state.publisher_generation = state.publisher_generation + 1
    local generation = state.publisher_generation
    state.publisher = deps.publisher_setup({
      pane = deps.pane,
      snapshot = copy_semantic(state.snapshot),
      on_available = function(value)
        if generation == state.publisher_generation then
          set_remote_available(value)
        end
      end,
    })
  end
  start_publisher()

  state.group = deps.create_augroup("dotfiles-statusline", { clear = true })
  local function register_scheduled(events, description)
    deps.create_autocmd(events, {
      group = state.group,
      desc = description,
      callback = function(event)
        local reason = event.event
        deps.schedule(function()
          controller:refresh(reason)
        end)
      end,
    })
  end

  register_scheduled({
    "VimEnter",
    "BufEnter",
    "WinEnter",
    "BufFilePost",
    "BufWritePost",
    "DirChanged",
  }, "Refresh status state and Git context")
  register_scheduled({
    "BufModifiedSet",
    "ModeChanged",
    "CursorMoved",
    "CursorMovedI",
    "DiagnosticChanged",
  }, "Refresh status semantic state")
  register_scheduled("FocusLost", "Pause standalone status Git refresh")
  register_scheduled("FocusGained", "Resume standalone status Git refresh")
  register_scheduled({ "VimSuspend", "VimResume" }, "Withdraw and revalidate tmux status ownership")
  register_scheduled({ "VimResized", "WinResized" }, "Refresh responsive status profile")
  register_scheduled("ColorScheme", "Reapply owned status highlights")
  deps.create_autocmd("VimLeavePre", {
    group = state.group,
    desc = "Stop status controllers",
    callback = function()
      controller:shutdown()
    end,
  })

  return controller
end

function M.render()
  if not runtime or runtime:is_stopped() then
    return ""
  end
  return runtime:render()
end

function M.snapshot()
  if not runtime or runtime:is_stopped() then
    return live_snapshot()
  end
  return runtime:snapshot()
end

function M.refresh(reason)
  if runtime and not runtime:is_stopped() then
    runtime:refresh(reason)
  end
end

function M.set_startup_visible(visible)
  assert(type(visible) == "boolean", "startup visibility must be boolean")
  if not runtime or runtime:is_stopped() then
    return false
  end
  return runtime:set_startup_visible(visible)
end

function M.shutdown()
  local active = runtime
  if not active then
    return
  end
  active:shutdown()
  if runtime == active then
    runtime = nil
  end
end

function M.setup(overrides)
  if runtime and not runtime:is_stopped() then
    return runtime
  end
  runtime = new_runtime(production_dependencies(overrides))
  return runtime
end

M._test = {
  apply_highlights = apply_highlights,
  build_snapshot = build_snapshot,
  display_path = display_path,
  escape_statusline = escape_statusline,
  live_snapshot = live_snapshot,
  make_renderer = make_renderer,
  new_git_cache = new_git_cache,
  new_runtime = new_runtime,
  normalize_mode = normalize_mode,
  profile_for_width = profile_for_width,
  render_parts = render_parts,
  sanitize = sanitize,
  saturate = saturate,
  truncate_left = truncate_left,
}

return M
