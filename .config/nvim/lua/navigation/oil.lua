local M = {}

local MARGIN = 2
local GAP = 0
local OIL_MIN_WIDTH = 32
local PREVIEW_MIN_WIDTH = 48
local PANE_MIN_HEIGHT = 8
local OIL_RATIO = 0.4

local function key_hints(width)
  local text = ""
  for _, hint in ipairs({ "g? Help", "Enter Open", "- Parent", "Ctrl-p Preview" }) do
    local next_text = text == "" and hint or (text .. " · " .. hint)
    if vim.fn.strdisplaywidth(next_text) + 2 > width then
      break
    end
    text = next_text
  end
  if text == "" then
    return width >= 2 and "g?" or ""
  end
  return " " .. text .. " "
end

local function border_frame(style)
  if style == nil or style == "" or style == "none" then
    return { horizontal = 0, vertical = 0 }
  end
  if style == "shadow" then
    return { horizontal = 1, vertical = 1 }
  end
  if type(style) == "table" then
    local function occupied(index)
      if #style == 0 then
        return 0
      end
      local cell = style[(index - 1) % #style + 1]
      if type(cell) == "table" then
        cell = cell[1]
      end
      return cell and cell ~= "" and 1 or 0
    end
    return { horizontal = occupied(4) + occupied(8), vertical = occupied(2) + occupied(6) }
  end
  return { horizontal = 2, vertical = 2 }
end

local function split_size(total, first_minimum, second_minimum)
  local first = math.floor(total * OIL_RATIO)
  first = math.max(first_minimum, math.min(first, total - second_minimum))
  return first, total - first
end

local function geometry(row, col, width, height)
  return {
    relative = "editor",
    row = row,
    col = col,
    width = math.max(1, width),
    height = math.max(1, height),
  }
end

local function layout(columns, usable_height, frame)
  assert(type(columns) == "number" and columns >= 1, "columns must be positive")
  assert(type(usable_height) == "number" and usable_height >= 1, "height must be positive")
  frame = frame or { horizontal = 0, vertical = 0 }

  local col = math.max(0, math.min(MARGIN, math.floor((columns - frame.horizontal - 1) / 2)))
  local row = math.max(0, math.min(MARGIN, math.floor((usable_height - frame.vertical - 1) / 2)))
  local outer_width = math.max(1, columns - 2 * col)
  local outer_height = math.max(1, usable_height - 2 * row)
  local single = geometry(row, col, outer_width - frame.horizontal, outer_height - frame.vertical)

  local common_height = outer_height - frame.vertical
  local horizontal_budget = outer_width - 2 * frame.horizontal - GAP
  if
    common_height >= PANE_MIN_HEIGHT and horizontal_budget >= OIL_MIN_WIDTH + PREVIEW_MIN_WIDTH
  then
    local oil_width, preview_width = split_size(horizontal_budget, OIL_MIN_WIDTH, PREVIEW_MIN_WIDTH)
    return {
      mode = "wide",
      single = single,
      oil = geometry(row, col, oil_width, common_height),
      preview = geometry(
        row,
        col + oil_width + frame.horizontal + GAP,
        preview_width,
        common_height
      ),
    }
  end

  local common_width = outer_width - frame.horizontal
  local vertical_budget = outer_height - 2 * frame.vertical - GAP
  if common_width >= OIL_MIN_WIDTH and vertical_budget >= 2 * PANE_MIN_HEIGHT then
    local oil_height, preview_height = split_size(vertical_budget, PANE_MIN_HEIGHT, PANE_MIN_HEIGHT)
    return {
      mode = "narrow",
      single = single,
      oil = geometry(row, col, common_width, oil_height),
      preview = geometry(
        row + oil_height + frame.vertical + GAP,
        col,
        common_width,
        preview_height
      ),
    }
  end

  return {
    mode = "extreme_small",
    single = single,
    oil = single,
    preview = nil,
  }
end

local function usable_height(lines, cmdheight, tabline_visible, statusline_visible)
  local height = lines - cmdheight
  if tabline_visible then
    height = height - 1
  end
  if statusline_visible then
    height = height - 1
  end
  return math.max(1, height)
end

local function tabline_visible()
  return vim.o.showtabline == 2 or (vim.o.showtabline == 1 and #vim.api.nvim_list_tabpages() > 1)
end

local function statusline_visible()
  if vim.o.laststatus >= 2 then
    return true
  end
  if vim.o.laststatus ~= 1 then
    return false
  end

  local normal_windows = 0
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(winid).relative == "" then
      normal_windows = normal_windows + 1
    end
  end
  return normal_windows > 1
end

local function editor_size()
  return vim.o.columns,
    usable_height(vim.o.lines, vim.o.cmdheight, tabline_visible(), statusline_visible())
end

local function new(runtime)
  local active
  local generation = 0
  local controller = {}
  local close
  local request_preview

  local function current(candidate, expected)
    return active == candidate and not candidate.closing and candidate.generation == expected
  end

  local function windows()
    local result = {}
    for _, winid in ipairs(runtime.tab_wins()) do
      result[winid] = true
    end
    return result
  end

  local function cleanup(candidate)
    if active ~= candidate then
      return
    end
    candidate.closing = true
    if candidate.oil and candidate.oil.open_preview == candidate.preview_observer then
      candidate.oil.open_preview = candidate.native_open_preview
    end
    if candidate.preview_win and runtime.win_valid(candidate.preview_win) then
      pcall(runtime.close_win, candidate.preview_win)
    end
    if candidate.group then
      pcall(runtime.delete_group, candidate.group)
      candidate.group = nil
    end
    local suspended = candidate.suspended_preview_win
    candidate.suspended_preview_win = nil
    if suspended and runtime.win_valid(suspended) then
      pcall(runtime.set_preview, suspended, true)
    end
    active = nil
  end

  local function set_oil_geometry(candidate, target)
    runtime.set_geometry(
      candidate.oil_win,
      vim.tbl_extend("force", target, { footer = key_hints(target.width), footer_pos = "left" })
    )
  end

  local function apply(candidate)
    if not runtime.win_valid(candidate.oil_win) then
      cleanup(candidate)
      return
    end
    if candidate.preview_win and not runtime.win_valid(candidate.preview_win) then
      controller.on_win_closed(candidate.preview_win)
    end
    local columns, height = runtime.editor_size()
    local frame = border_frame(runtime.get_config(candidate.oil_win).border)
    candidate.layout = layout(columns, height, frame)
    if candidate.preview_state == "manually_suppressed" then
      set_oil_geometry(candidate, candidate.layout.single)
      return
    end
    if candidate.layout.mode == "extreme_small" then
      candidate.preview_state = "deferred_by_size"
      set_oil_geometry(candidate, candidate.layout.single)
      if candidate.preview_win and not candidate.preview_pending then
        local preview = candidate.preview_win
        candidate.internal_preview_close = preview
        candidate.preview_win = nil
        runtime.close_win(preview)
        candidate.internal_preview_close = nil
      end
      return
    end
    if candidate.preview_win then
      set_oil_geometry(candidate, candidate.layout.oil)
      runtime.set_geometry(candidate.preview_win, candidate.layout.preview)
    else
      set_oil_geometry(candidate, candidate.layout.single)
      if candidate.ready and candidate.preview_state == "deferred_by_size" then
        request_preview(candidate)
      end
    end
  end

  local function adopt(candidate, before)
    for _, winid in ipairs(runtime.tab_wins()) do
      if
        not before[winid]
        and winid ~= candidate.oil_win
        and runtime.win_valid(winid)
        and runtime.is_preview(winid)
      then
        candidate.preview_win, candidate.preview_state = winid, "visible"
        break
      end
    end
    candidate.known_windows = windows()
    apply(candidate)
  end

  local function observe_previews(candidate)
    local expected = candidate.generation
    local native = candidate.oil.open_preview
    candidate.native_open_preview = native
    candidate.preview_requests = 0
    -- Native <C-p> and cursor-follow use this public entry point too. Window
    -- events alone cannot observe a pending update to an existing preview.
    candidate.preview_observer = function(opts, callback)
      if not current(candidate, expected) or runtime.current_win() ~= candidate.oil_win then
        return native(opts, callback)
      end
      local before = windows()
      candidate.preview_requests = candidate.preview_requests + 1
      candidate.preview_pending = true
      local finished = false
      local function finish(err, call_callback)
        if finished then
          return
        end
        finished = true
        local ok, callback_err = true, nil
        if call_callback and callback then
          -- Keep the source valid throughout the caller's native callback,
          -- even if that callback requests a close or raises an error.
          ok, callback_err = pcall(callback, err)
        end
        candidate.preview_requests = candidate.preview_requests - 1
        candidate.preview_pending = candidate.preview_requests > 0
        if current(candidate, expected) then
          if not err then
            adopt(candidate, before)
          end
          if candidate.close_requested and not candidate.preview_pending then
            local reopen = candidate.reopen_requested
            candidate.close_requested = false
            close(candidate)
            if reopen and not active then
              controller.toggle()
            end
          end
        end
        if not ok then
          error(callback_err, 0)
        end
      end
      local ok, result = pcall(native, opts, function(err)
        finish(err, true)
      end)
      if not ok then
        finish(result, false)
        error(result, 0)
      end
      -- Oil creates the preview synchronously, then loads its content. Own
      -- the window immediately while retaining every in-flight request.
      if current(candidate, expected) then
        adopt(candidate, before)
      end
      return result
    end
    candidate.oil.open_preview = candidate.preview_observer
  end

  request_preview = function(candidate)
    local expected = candidate.generation
    candidate.preview_state = "requested"
    local ok, err = pcall(runtime.win_call, candidate.oil_win, function()
      candidate.oil.open_preview()
    end)
    if not ok and current(candidate, expected) then
      runtime.notify(
        "Could not open Oil preview: " .. tostring(err),
        vim.log.levels.ERROR,
        { title = "Oil workspace" }
      )
    end
  end

  function controller.on_resize()
    local candidate = active
    if not candidate or candidate.closing or candidate.resize_pending then
      return
    end
    local expected = candidate.generation
    candidate.resize_pending = true
    runtime.schedule(function()
      if not current(candidate, expected) then
        return
      end
      candidate.resize_pending = false
      apply(candidate)
    end)
  end
  function controller.on_win_new()
    local candidate = active
    if not candidate or candidate.closing then
      return
    end
    local expected = candidate.generation
    local observed = windows()
    local new_windows = {}
    for winid in pairs(observed) do
      if not candidate.known_windows[winid] then
        new_windows[winid] = true
      end
      candidate.known_windows[winid] = true
    end
    local source = runtime.current_win()
    local from_oil = source == candidate.oil_win
      or (new_windows[source] and runtime.is_preview(source))
    runtime.schedule(function()
      if not current(candidate, expected) or not from_oil then
        return
      end
      if not runtime.win_valid(candidate.oil_win) then
        cleanup(candidate)
        return
      end
      if runtime.current_win() ~= candidate.oil_win then
        return
      end
      for winid in pairs(new_windows) do
        if
          winid ~= candidate.suspended_preview_win
          and runtime.win_valid(winid)
          and runtime.is_preview(winid)
        then
          candidate.preview_win, candidate.preview_state = winid, "visible"
          apply(candidate)
          return
        end
      end
    end)
  end

  function controller.on_win_closed(winid)
    local candidate = active
    if not candidate then
      return
    end
    if winid == candidate.suspended_preview_win then
      candidate.suspended_preview_win = nil
    end
    if winid == candidate.oil_win then
      cleanup(candidate)
      return
    end
    if winid == candidate.internal_preview_close then
      candidate.internal_preview_close = nil
      candidate.preview_state = "deferred_by_size"
      return
    end
    if winid ~= candidate.preview_win then
      return
    end
    candidate.preview_win = nil
    if candidate.closing then
      return
    end
    local expected = candidate.generation
    runtime.schedule(function()
      if not current(candidate, expected) then
        return
      end
      if not runtime.win_valid(candidate.oil_win) then
        cleanup(candidate)
        return
      end
      if not candidate.preview_win then
        candidate.preview_state = "manually_suppressed"
        apply(candidate)
      end
    end)
  end

  local function register(candidate)
    if candidate.group then
      return
    end
    local expected = candidate.generation
    candidate.group = runtime.create_group("dotfiles-oil-workspace-" .. expected)
    for event, callback in pairs({
      VimResized = controller.on_resize,
      WinNew = controller.on_win_new,
      BufWinEnter = controller.on_win_new,
      WinClosed = function(args)
        controller.on_win_closed(tonumber(args.match))
      end,
    }) do
      runtime.create_autocmd(event, {
        group = candidate.group,
        callback = function(args)
          if active == candidate and candidate.generation == expected then
            callback(args)
          end
        end,
      })
    end
  end

  close = function(candidate)
    if not runtime.win_valid(candidate.oil_win) then
      cleanup(candidate)
      return
    end
    if runtime.buf_modified(runtime.win_buf(candidate.oil_win)) then
      runtime.set_current_win(candidate.oil_win)
      runtime.notify(
        "Oil has pending edits; save or discard them before closing",
        vim.log.levels.WARN,
        { title = "Oil workspace" }
      )
      return
    end
    -- Oil has no cancellation API. Keep its windows valid until its pending
    -- native preview callback returns, then complete the requested close.
    if candidate.preview_pending then
      candidate.close_requested = true
      return
    end
    local previous = candidate.generation
    generation = generation + 1
    candidate.generation, candidate.closing = generation, true
    if candidate.preview_win and runtime.win_valid(candidate.preview_win) then
      runtime.close_win(candidate.preview_win)
      candidate.preview_win = nil
    end
    local ok = pcall(runtime.win_call, candidate.oil_win, candidate.oil.close)
    if not ok and runtime.win_valid(candidate.oil_win) then
      candidate.generation, candidate.closing = previous, false
      runtime.notify(
        "Could not close Oil workspace",
        vim.log.levels.ERROR,
        { title = "Oil workspace" }
      )
      return
    end
    cleanup(candidate)
    if runtime.win_valid(candidate.origin_win) then
      runtime.set_current_win(candidate.origin_win)
    end
  end

  function controller.toggle()
    if active and active.close_requested then
      active.reopen_requested = not active.reopen_requested
      return
    end
    if active then
      close(active)
      return
    end
    generation = generation + 1
    local columns, height = runtime.editor_size()
    local candidate = {
      generation = generation,
      origin_win = runtime.current_win(),
      before = windows(),
      layout = layout(columns, height, runtime.border_frame()),
      closing = false,
      resize_pending = false,
    }
    candidate.known_windows = vim.deepcopy(candidate.before)
    candidate.preview_state = candidate.layout.preview and "requested" or "deferred_by_size"
    active = candidate
    local expected = generation
    local function capture()
      if candidate.oil_win then
        return
      end
      local winid = runtime.current_win()
      if not candidate.before[winid] and runtime.win_valid(winid) then
        candidate.oil_win, candidate.oil_buf = winid, runtime.win_buf(winid)
      end
    end
    local ok, err = pcall(function()
      candidate.oil = runtime.require_oil()
      for _, winid in ipairs(runtime.tab_wins()) do
        if runtime.win_valid(winid) and runtime.is_preview(winid) then
          candidate.suspended_preview_win = winid
          runtime.set_preview(winid, false)
          break
        end
      end
      -- Oil schedules native cursor restoration after its ready callback.
      candidate.oil.open_float(nil, {}, function()
        if not current(candidate, expected) then
          return
        end
        capture()
        runtime.schedule(function()
          if not current(candidate, expected) then
            return
          end
          if not runtime.win_valid(candidate.oil_win) then
            cleanup(candidate)
            return
          end
          candidate.ready = true
          if
            candidate.layout.preview
            and not candidate.preview_win
            and candidate.preview_state ~= "manually_suppressed"
          then
            request_preview(candidate)
          end
          apply(candidate)
        end)
      end)
      capture()
      assert(candidate.oil_win, "Oil did not create a floating window")
      observe_previews(candidate)
      register(candidate)
      apply(candidate)
    end)
    if not ok then
      capture()
      generation = generation + 1
      candidate.generation, candidate.closing = generation, true
      if candidate.oil_win and runtime.win_valid(candidate.oil_win) then
        pcall(runtime.close_win, candidate.oil_win)
      end
      cleanup(candidate)
      if runtime.win_valid(candidate.origin_win) then
        runtime.set_current_win(candidate.origin_win)
      end
      runtime.notify(
        "Could not open Oil workspace: " .. tostring(err),
        vim.log.levels.ERROR,
        { title = "Oil workspace" }
      )
    end
  end

  function controller.snapshot()
    if not active then
      return nil
    end
    local result = {}
    for _, key in ipairs({
      "generation",
      "origin_win",
      "oil_win",
      "oil_buf",
      "preview_win",
      "preview_state",
      "closing",
      "resize_pending",
      "suspended_preview_win",
    }) do
      result[key] = active[key]
    end
    return result
  end
  return controller
end

local runtime = {
  require_oil = function()
    return require("oil")
  end,
  current_win = vim.api.nvim_get_current_win,
  tab_wins = function()
    return vim.api.nvim_tabpage_list_wins(0)
  end,
  win_valid = function(winid)
    return winid ~= nil and vim.api.nvim_win_is_valid(winid)
  end,
  win_buf = vim.api.nvim_win_get_buf,
  buf_modified = function(bufnr)
    return vim.bo[bufnr].modified
  end,
  editor_size = editor_size,
  border_frame = function()
    return border_frame(vim.o.winborder)
  end,
  is_preview = function(winid)
    return vim.wo[winid].previewwindow
  end,
  set_preview = function(winid, value)
    vim.wo[winid].previewwindow = value
  end,
  get_config = vim.api.nvim_win_get_config,
  set_geometry = function(winid, geometry)
    vim.api.nvim_win_set_config(
      winid,
      vim.tbl_extend("force", vim.api.nvim_win_get_config(winid), geometry)
    )
  end,
  close_win = function(winid)
    vim.api.nvim_win_close(winid, true)
  end,
  set_current_win = vim.api.nvim_set_current_win,
  win_call = vim.api.nvim_win_call,
  schedule = vim.schedule,
  notify = function(...)
    return vim.notify(...)
  end,
  create_group = function(name)
    return vim.api.nvim_create_augroup(name, { clear = true })
  end,
  create_autocmd = vim.api.nvim_create_autocmd,
  delete_group = vim.api.nvim_del_augroup_by_id,
}
local singleton = new(runtime)
M.toggle = singleton.toggle
M._test = { layout = layout, border_frame = border_frame, usable_height = usable_height, new = new }
return M
