local function eq(actual, expected, label)
  assert(
    vim.deep_equal(actual, expected),
    string.format("%s\nexpected: %s\nactual: %s", label, vim.inspect(expected), vim.inspect(actual))
  )
end

local workspace = require("navigation.oil")
local test = assert(workspace._test, "Oil workspace test boundary missing")
assert(type(test.layout) == "function", "Oil workspace layout function missing")
assert(type(test.border_frame) == "function", "Oil workspace border helper missing")
assert(type(test.new) == "function", "Oil workspace constructor missing")

eq(test.border_frame(""), { horizontal = 0, vertical = 0 }, "empty border")
eq(test.border_frame("none"), { horizontal = 0, vertical = 0 }, "none border")
eq(test.border_frame("rounded"), { horizontal = 2, vertical = 2 }, "rounded border")
eq(test.border_frame("+,-,+,|,+,-,+,|"), { horizontal = 2, vertical = 2 }, "custom border")

eq(test.usable_height(40, 0, false, false), 40, "no occupied editor rows")
eq(test.usable_height(40, 1, false, false), 39, "command row")
eq(test.usable_height(40, 0, true, false), 39, "tabline row")
eq(test.usable_height(40, 0, false, true), 39, "statusline row")
eq(test.usable_height(40, 1, true, true), 37, "all occupied editor rows")

local boundary_cases = {
  {
    label = "borderless exact wide minimum",
    columns = 84,
    height = 12,
    frame = { horizontal = 0, vertical = 0 },
    mode = "wide",
    oil = { relative = "editor", row = 2, col = 2, width = 32, height = 8 },
    preview = { relative = "editor", row = 2, col = 34, width = 48, height = 8 },
  },
  {
    label = "borderless one column below wide uses narrow",
    columns = 83,
    height = 20,
    frame = { horizontal = 0, vertical = 0 },
    mode = "narrow",
  },
  {
    label = "borderless exact narrow minimum",
    columns = 36,
    height = 20,
    frame = { horizontal = 0, vertical = 0 },
    mode = "narrow",
    oil = { relative = "editor", row = 2, col = 2, width = 32, height = 8 },
    preview = { relative = "editor", row = 10, col = 2, width = 32, height = 8 },
  },
  {
    label = "borderless one column below narrow is tiny",
    columns = 35,
    height = 20,
    frame = { horizontal = 0, vertical = 0 },
    mode = "extreme_small",
  },
  {
    label = "borderless one row below narrow is tiny",
    columns = 36,
    height = 19,
    frame = { horizontal = 0, vertical = 0 },
    mode = "extreme_small",
  },
  {
    label = "bordered exact wide minimum",
    columns = 88,
    height = 14,
    frame = { horizontal = 2, vertical = 2 },
    mode = "wide",
  },
  {
    label = "bordered exact narrow minimum",
    columns = 38,
    height = 24,
    frame = { horizontal = 2, vertical = 2 },
    mode = "narrow",
  },
  {
    label = "minimal editor remains usable",
    columns = 3,
    height = 2,
    frame = { horizontal = 0, vertical = 0 },
    mode = "extreme_small",
    single = { relative = "editor", row = 0, col = 1, width = 1, height = 2 },
  },
}

for _, case in ipairs({
  { label = "wide one column above", columns = 85, height = 12, mode = "wide" },
  { label = "wide one row below", columns = 84, height = 11, mode = "extreme_small" },
  { label = "wide one row above", columns = 84, height = 13, mode = "wide" },
  { label = "narrow one column above", columns = 37, height = 20, mode = "narrow" },
  { label = "narrow one row above", columns = 36, height = 21, mode = "narrow" },
  {
    label = "bordered wide one column below",
    columns = 87,
    height = 24,
    frame = { horizontal = 2, vertical = 2 },
    mode = "narrow",
  },
  {
    label = "bordered wide one column above",
    columns = 89,
    height = 14,
    frame = { horizontal = 2, vertical = 2 },
    mode = "wide",
  },
  {
    label = "bordered wide one row below",
    columns = 88,
    height = 13,
    frame = { horizontal = 2, vertical = 2 },
    mode = "extreme_small",
  },
  {
    label = "bordered wide one row above",
    columns = 88,
    height = 15,
    frame = { horizontal = 2, vertical = 2 },
    mode = "wide",
  },
  {
    label = "bordered narrow one column below",
    columns = 37,
    height = 24,
    frame = { horizontal = 2, vertical = 2 },
    mode = "extreme_small",
  },
  {
    label = "bordered narrow one column above",
    columns = 39,
    height = 24,
    frame = { horizontal = 2, vertical = 2 },
    mode = "narrow",
  },
  {
    label = "bordered narrow one row below",
    columns = 38,
    height = 23,
    frame = { horizontal = 2, vertical = 2 },
    mode = "extreme_small",
  },
  {
    label = "bordered narrow one row above",
    columns = 38,
    height = 25,
    frame = { horizontal = 2, vertical = 2 },
    mode = "narrow",
  },
}) do
  case.frame = case.frame or { horizontal = 0, vertical = 0 }
  table.insert(boundary_cases, case)
end

for _, case in ipairs(boundary_cases) do
  local actual = test.layout(case.columns, case.height, case.frame)
  eq(actual.mode, case.mode, case.label .. " mode")
  if case.oil then
    eq(actual.oil, case.oil, case.label .. " Oil geometry")
  end
  if case.preview then
    eq(actual.preview, case.preview, case.label .. " preview geometry")
  end
  if case.single then
    eq(actual.single, case.single, case.label .. " single geometry")
  end
end

local proportional_wide = test.layout(126, 40, { horizontal = 0, vertical = 0 })
eq(proportional_wide.mode, "wide", "wide proportion mode")
eq(proportional_wide.oil.width, 48, "wide 40 percent Oil width")
eq(proportional_wide.preview.width, 74, "wide 60 percent preview width")

local proportional_narrow = test.layout(80, 44, { horizontal = 0, vertical = 0 })
eq(proportional_narrow.mode, "narrow", "narrow proportion mode")
eq(proportional_narrow.oil.height, 16, "narrow 40 percent Oil height")
eq(proportional_narrow.preview.height, 24, "narrow 60 percent preview height")

-- Inject only the editor/plugin boundary so races and failures are reproducible.
local function controller_harness(options)
  options = options or {}
  local h = {
    columns = options.columns or 126,
    height = options.height or 40,
    current = 1,
    next_win = 1,
    queue = {},
    events = {},
    notifications = {},
    windows = { [1] = { buf = 101, config = { relative = "" }, preview = false } },
    modified = {},
    open_float_calls = {},
    open_preview_calls = 0,
    close_calls = 0,
    deletes = 0,
    moves = 0,
    restores = 0,
    pending = {},
  }
  function h:emit(event, args)
    for _, callback in ipairs(self.events[event] or {}) do
      callback(args or {})
    end
  end
  function h:add(preview)
    self.next_win = self.next_win + 1
    local id = self.next_win
    self.windows[id] = {
      buf = id * 100 + 1,
      preview = preview or false,
      cursor = { 2, 0 },
      config = {
        relative = "editor",
        row = 0,
        col = 0,
        width = 20,
        height = 10,
        border = "none",
        title = "native",
        zindex = 45,
        focusable = not preview,
      },
    }
    self:emit("WinNew")
    return id
  end
  function h:flush()
    local n = 0
    while #self.queue > 0 do
      n = n + 1
      assert(n < 200, "controller scheduled an unbounded loop")
      table.remove(self.queue, 1)()
    end
  end
  local runtime = {
    current_win = function()
      return h.current
    end,
    tab_wins = function()
      local result = vim.tbl_keys(h.windows)
      table.sort(result)
      return result
    end,
    win_valid = function(id)
      return id ~= nil and h.windows[id] ~= nil
    end,
    win_buf = function(id)
      return h.windows[id].buf
    end,
    buf_modified = function(buf)
      return h.modified[buf] or false
    end,
    editor_size = function()
      return h.columns, h.height
    end,
    border_frame = function()
      return { horizontal = 0, vertical = 0 }
    end,
    is_preview = function(id)
      return h.windows[id].preview
    end,
    set_preview = function(id, value)
      h.windows[id].preview = value
      if value then
        h.restores = h.restores + 1
      end
    end,
    get_config = function(id)
      return vim.deepcopy(h.windows[id].config)
    end,
    set_geometry = function(id, geometry)
      h.moves = h.moves + 1
      h.windows[id].config = vim.tbl_extend("force", h.windows[id].config, geometry)
    end,
    close_win = function(id)
      assert(h.windows[id], "closing an invalid window")
      h.windows[id] = nil
      if h.current == id then
        h.current = next(h.windows)
      end
      h:emit("WinClosed", { match = tostring(id) })
    end,
    set_current_win = function(id)
      assert(h.windows[id])
      h.current = id
    end,
    schedule = function(callback)
      table.insert(h.queue, callback)
    end,
    notify = function(message, level, opts)
      table.insert(h.notifications, { message, level, opts })
    end,
    create_group = function()
      return 7
    end,
    create_autocmd = function(events, opts)
      if type(events) == "string" then
        events = { events }
      end
      for _, event in ipairs(events) do
        h.events[event] = h.events[event] or {}
        table.insert(h.events[event], opts.callback)
      end
    end,
    delete_group = function()
      h.deletes = h.deletes + 1
      h.events = {}
    end,
  }
  runtime.win_call = function(id, callback)
    local previous = h.current
    h.current = id
    local ok, err = pcall(callback)
    if h.windows[previous] then
      h.current = previous
    end
    if not ok then
      error(err)
    end
  end
  local oil = {}
  oil.open_preview = function(_, callback)
    h.open_preview_calls = h.open_preview_calls + 1
    if options.preview_throw then
      error("injected preview exception")
    end
    if options.preview_error then
      runtime.notify(options.preview_error, vim.log.levels.ERROR, {})
      if callback then
        callback(options.preview_error)
      end
      return
    end
    local id
    for winid, window in pairs(h.windows) do
      if window.preview then
        id = winid
        break
      end
    end
    id = id or h:add(true)
    h.last_preview = id
    if callback then
      if options.defer_preview then
        table.insert(h.pending, callback)
      else
        callback()
      end
    end
  end
  oil.open_float = function(dir, opts, callback)
    table.insert(h.open_float_calls, { dir = dir, opts = vim.deepcopy(opts) })
    h.current = h:add()
    if options.open_error then
      error("injected open failure")
    end
    local ready = function()
      if opts.preview then
        oil.open_preview(opts.preview, callback)
      else
        callback()
      end
    end
    if options.defer_open then
      table.insert(h.pending, ready)
    else
      ready()
    end
  end
  oil.close = function()
    h.close_calls = h.close_calls + 1
    h.close_from = h.current
    if options.close_error then
      error("injected close failure")
    end
    runtime.close_win(h.current)
  end
  runtime.require_oil = function()
    if options.require_error then
      error("injected require failure")
    end
    return oil
  end
  h.runtime, h.oil = runtime, oil
  return h, test.new(runtime)
end

local failures = {}
local function case(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if not ok then
    table.insert(failures, name .. ": " .. err)
  end
end

case("modified close preserves pending edits", function()
  local h, controller = controller_harness()
  controller.toggle()
  h:flush()
  local state = controller.snapshot()
  eq(state.generation, 1, "first generation")
  eq(h.open_float_calls[1].dir, nil, "native target")
  eq(state.preview_state, "visible", "native preview visible")
  h.modified[state.oil_buf] = true
  h.current = state.preview_win
  controller.toggle()
  assert(h.windows[state.oil_win] and h.windows[state.preview_win], "modified workspace was closed")
  eq(h.current, state.oil_win, "refocus pending edits")
  eq(h.close_calls, 0, "modified Oil was not closed")
  eq(h.notifications, {
    {
      "Oil has pending edits; save or discard them before closing",
      vim.log.levels.WARN,
      { title = "Oil workspace" },
    },
  }, "one pending-edits warning")
  h.modified[state.oil_buf] = false
  controller.toggle()
  eq(h.close_from, state.oil_win, "native close context")
  eq(h.current, 1, "origin restored")
  eq(h.deletes, 1, "group removed once")
  eq(controller.snapshot(), nil, "session cleaned")
  controller.on_win_closed(state.oil_win)
  eq(h.deletes, 1, "cleanup is idempotent")
end)

case("missing origin retains an existing window", function()
  local h, controller = controller_harness()
  local remaining = h:add()
  h.current = 1
  controller.toggle()
  h.runtime.close_win(1)
  controller.toggle()
  eq(h.current, remaining, "remaining window focus")
  eq(vim.tbl_count(h.windows), 1, "no replacement buffer/window created")
end)

for _, failure in ipairs({ "require_error", "open_error" }) do
  case(failure .. " releases partial session", function()
    local h, controller = controller_harness({ [failure] = true })
    controller.toggle()
    eq(controller.snapshot(), nil, "failed open has no session")
    eq(vim.tbl_keys(h.windows), { 1 }, "only origin survives")
    eq(h.current, 1, "failed open origin")
    eq(#h.notifications, 1, "one open error")
    eq(h.notifications[1][2], vim.log.levels.ERROR, "error severity")
    eq(h.notifications[1][3].title, "Oil workspace", "error title")
  end)
end

case("stale open callbacks cannot touch the next workspace", function()
  local h, controller = controller_harness({ defer_open = true })
  controller.toggle()
  local first = controller.snapshot()
  controller.toggle()
  controller.toggle()
  local second = controller.snapshot()
  assert(second.generation > first.generation)
  local before = vim.deepcopy(h.windows)
  local moves = h.moves
  table.remove(h.pending, 1)()
  h:flush()
  eq(h.windows, before, "stale native ready callback changed windows")
  eq(h.moves, moves, "stale callback moved windows")
  controller.toggle()
  table.remove(h.pending, 1)()
  h:flush()
  eq(vim.tbl_keys(h.windows), { 1 }, "closing during open left a float")
  eq(controller.snapshot(), nil, "closing during open leaked a session")
end)

case("preview failure is native and does not retry", function()
  local h, controller = controller_harness({ preview_error = "Could not find entry under cursor" })
  controller.toggle()
  h:flush()
  local state = controller.snapshot()
  assert(h.windows[state.oil_win])
  eq(state.preview_state, "requested", "failed request retained")
  controller.on_resize()
  h:flush()
  eq(h.open_preview_calls, 1, "preview failure retried")
  eq(#h.notifications, 1, "native error was duplicated")
end)

case("close error leaves the workspace controllable", function()
  local options = { close_error = true }
  local h, controller = controller_harness(options)
  controller.toggle()
  h:flush()
  local state = controller.snapshot()
  controller.toggle()
  assert(h.windows[state.oil_win])
  eq(controller.snapshot().closing, false, "close error latched closing")
  eq(#h.notifications, 1, "one close error")
  options.close_error = false
  controller.toggle()
  eq(controller.snapshot(), nil, "close retry failed")
end)

case("unrelated preview retains contents, view, geometry and marker", function()
  local h, controller = controller_harness()
  local unrelated = h:add(true)
  local before = vim.deepcopy(h.windows[unrelated])
  controller.toggle()
  h:flush()
  eq(
    h.windows[unrelated],
    vim.tbl_extend("force", before, { preview = false }),
    "unrelated preview changed"
  )
  local state = controller.snapshot()
  assert(state.preview_win ~= unrelated, "unrelated preview was reused")
  eq(state.suspended_preview_win, unrelated, "unrelated marker not suspended")
  controller.toggle()
  eq(h.windows[unrelated], before, "unrelated preview was not restored")
  eq(h.restores, 1, "marker restored exactly once")
end)

case("closed unrelated preview is never replaced during cleanup", function()
  local h, controller = controller_harness()
  local unrelated = h:add(true)
  controller.toggle()
  h:flush()
  h.runtime.close_win(unrelated)
  controller.toggle()
  eq(h.restores, 0, "restored a closed preview")
  eq(vim.tbl_keys(h.windows), { 1 }, "cleanup created a window")
end)

case("open failure restores the unrelated preview marker", function()
  local h, controller = controller_harness({ open_error = true })
  local unrelated = h:add(true)
  local before = vim.deepcopy(h.windows[unrelated])
  controller.toggle()
  eq(h.windows[unrelated], before, "failed open damaged unrelated preview")
  eq(h.restores, 1, "failed open did not restore the marker")
end)

case("manual preview close is classified later and native reopen is adopted", function()
  local h, controller = controller_harness()
  controller.toggle()
  h:flush()
  local state = controller.snapshot()
  h.runtime.close_win(state.preview_win)
  assert(
    controller.snapshot().preview_state ~= "manually_suppressed",
    "classification was synchronous"
  )
  h:flush()
  eq(controller.snapshot().preview_state, "manually_suppressed", "manual close was forgotten")
  eq(h.windows[state.oil_win].config.width, 122, "suppressed preview left half-width Oil")
  controller.on_resize()
  h:flush()
  eq(h.open_preview_calls, 1, "resize reopened a manually closed preview")
  h.oil.open_preview()
  h:flush()
  eq(controller.snapshot().preview_win, h.last_preview, "native reopen was not adopted")
  eq(controller.snapshot().preview_state, "visible", "reopened preview state")
  eq(h.windows[state.oil_win].config.width, 48, "native reopen geometry")
end)

case("preview created from another window is not adopted", function()
  local h, controller = controller_harness()
  controller.toggle()
  h:flush()
  h.runtime.close_win(controller.snapshot().preview_win)
  h:flush()
  h.current = 1
  local other = h:add(true)
  controller.on_win_new()
  h:flush()
  eq(controller.snapshot().preview_win, nil, "adopted another window's preview")
  h.current = controller.snapshot().oil_win
  controller.on_win_new()
  h:flush()
  eq(controller.snapshot().preview_win, nil, "adopted an already-observed unrelated preview")
  controller.toggle()
  assert(h.windows[other], "closed unrelated preview")
end)

case("native selection cleanup wins over preview-close classification", function()
  local h, controller = controller_harness()
  controller.toggle()
  h:flush()
  local state = controller.snapshot()
  h.runtime.close_win(state.preview_win)
  h.runtime.close_win(state.oil_win)
  h:flush()
  eq(controller.snapshot(), nil, "native close left a session")
  eq(h.deletes, 1, "native close leaked a group")
end)

case("actual border occupancy keeps tiny geometry in bounds", function()
  eq(
    test.border_frame({ "", "", "", "|", "", "", "", "|" }),
    { horizontal = 2, vertical = 0 },
    "side-only border occupancy"
  )
  eq(
    test.border_frame({ { "", "FloatBorder" } }),
    { horizontal = 0, vertical = 0 },
    "empty highlighted border occupancy"
  )
  eq(test.border_frame("shadow"), { horizontal = 1, vertical = 1 }, "shadow border occupancy")
  eq(
    test.layout(3, 3, { horizontal = 2, vertical = 2 }).single,
    { relative = "editor", row = 0, col = 0, width = 1, height = 1 },
    "tiny bordered float remains in bounds"
  )
end)

case("resize preserves native panes and coalesces a burst", function()
  local h, controller = controller_harness()
  controller.toggle()
  h:flush()
  local original = controller.snapshot()
  local oil = h.windows[original.oil_win]
  local preview = h.windows[original.preview_win]
  h.modified[oil.buf] = true
  h.current = original.preview_win
  h.columns, h.height = 80, 44
  local moves = h.moves
  controller.on_resize()
  controller.on_resize()
  h:flush()
  eq(h.moves - moves, 2, "resize burst did not apply one pair layout")
  eq(controller.snapshot().oil_win, original.oil_win, "resize replaced Oil")
  eq(controller.snapshot().preview_win, original.preview_win, "resize replaced preview")
  eq(oil.config.width, 76, "narrow width")
  eq(oil.config.height, 16, "narrow Oil height")
  eq(preview.config.height, 24, "narrow preview height")
  eq(oil.cursor, { 2, 0 }, "resize moved cursor")
  eq(oil.buf, original.oil_buf, "resize replaced buffer")
  eq(h.modified[oil.buf], true, "resize discarded edits")
  eq(oil.config.title, "native", "resize lost native style")
  eq(h.current, original.preview_win, "pair resize stole focus")
  h.columns, h.height = 126, 40
  controller.on_resize()
  h:flush()
  eq(oil.config.width, 48, "wide Oil width")
  eq(preview.config.width, 74, "wide preview width")
end)

for _, target in ipairs({ { 80, 44 }, { 126, 40 } }) do
  case("tiny preview is deferred and restored at " .. target[1], function()
    local h, controller = controller_harness({ columns = 30, height = 10 })
    controller.toggle()
    h:flush()
    local state = controller.snapshot()
    eq(state.preview_state, "deferred_by_size", "initial tiny state")
    eq(h.open_preview_calls, 0, "tiny open requested preview")
    h.columns, h.height = target[1], target[2]
    controller.on_resize()
    controller.on_resize()
    h:flush()
    eq(h.open_preview_calls, 1, "enlarge did not request preview exactly once")
    eq(controller.snapshot().preview_state, "visible", "enlarge did not restore preview")
    eq(controller.snapshot().oil_win, state.oil_win, "enlarge replaced Oil")
    local first_preview = controller.snapshot().preview_win
    h.columns, h.height = 30, 10
    controller.on_resize()
    h:flush()
    eq(controller.snapshot().preview_state, "deferred_by_size", "internal close classified manual")
    assert(not h.windows[first_preview], "tiny resize kept preview open")
    eq(h.windows[state.oil_win].config.width, 26, "tiny Oil width")
    h.columns, h.height = target[1], target[2]
    controller.on_resize()
    h:flush()
    eq(h.open_preview_calls, 2, "second enlarge lost requested preview")
    assert(controller.snapshot().preview_win ~= first_preview, "reused a closed preview id")
  end)
end

case("suppressed preview stays closed through every size class", function()
  local h, controller = controller_harness()
  controller.toggle()
  h:flush()
  h.runtime.close_win(controller.snapshot().preview_win)
  h:flush()
  for _, size in ipairs({ { 30, 10 }, { 80, 44 }, { 126, 40 } }) do
    h.columns, h.height = unpack(size)
    controller.on_resize()
    h:flush()
    eq(
      controller.snapshot().preview_state,
      "manually_suppressed",
      "resize forgot manual suppression"
    )
    eq(controller.snapshot().preview_win, nil, "resize recreated suppressed preview")
  end
  eq(h.open_preview_calls, 1, "manual suppression retried preview")
end)

case("deferred request does not repeat until another real size transition", function()
  local h, controller =
    controller_harness({ columns = 30, height = 10, preview_error = "unsupported entry" })
  controller.toggle()
  h:flush()
  h.columns, h.height = 126, 40
  controller.on_resize()
  h:flush()
  eq(h.open_preview_calls, 1, "size-deferred preview was not requested")
  controller.on_resize()
  h:flush()
  eq(h.open_preview_calls, 1, "failed preview retried without a size transition")
  eq(#h.notifications, 1, "native preview error duplicated")
  h.columns, h.height = 30, 10
  controller.on_resize()
  h:flush()
  h.columns, h.height = 126, 40
  controller.on_resize()
  h:flush()
  eq(h.open_preview_calls, 2, "new size transition could not request preview")
end)

case("pending native preview is not duplicated or closed before its callback", function()
  local h, controller = controller_harness({ columns = 30, height = 10, defer_preview = true })
  controller.toggle()
  h:flush()
  h.columns, h.height = 126, 40
  controller.on_resize()
  h:flush()
  controller.on_resize()
  h:flush()
  eq(h.open_preview_calls, 1, "pending preview duplicated")
  local preview = controller.snapshot().preview_win
  h.columns, h.height = 30, 10
  controller.on_resize()
  h:flush()
  assert(h.windows[preview], "closed an in-flight native preview")
  table.remove(h.pending, 1)()
  h:flush()
  eq(controller.snapshot().preview_state, "deferred_by_size", "preview completion forgot tiny size")
  assert(not h.windows[preview], "completed tiny preview did not close")
end)

case("obsolete resize cannot move the next generation", function()
  local h, controller = controller_harness()
  controller.toggle()
  h:flush()
  controller.on_resize()
  local stale = table.remove(h.queue, 1)
  assert(stale, "resize did not schedule work")
  controller.toggle()
  controller.toggle()
  h:flush()
  local before, moves = vim.deepcopy(h.windows), h.moves
  stale()
  eq(h.windows, before, "obsolete resize changed windows")
  eq(h.moves, moves, "obsolete resize applied geometry")
end)

case("preview API exception leaves Oil usable and closable", function()
  local h, controller = controller_harness({ preview_throw = true })
  controller.toggle()
  h:flush()
  local state = controller.snapshot()
  assert(h.windows[state.oil_win], "preview exception closed Oil")
  eq(#h.notifications, 1, "preview exception notification")
  controller.on_resize()
  h:flush()
  eq(h.open_preview_calls, 1, "preview exception retried")
  controller.toggle()
  eq(controller.snapshot(), nil, "preview exception trapped close behind a pending request")
end)

case("queued reopen waits for native preview completion", function()
  local h, controller = controller_harness({ defer_preview = true })
  controller.toggle()
  h:flush()
  local old = controller.snapshot()
  controller.toggle()
  controller.toggle()
  assert(h.windows[old.oil_win], "closed native source before pending callback")
  table.remove(h.pending, 1)()
  h:flush()
  local fresh = controller.snapshot()
  assert(
    fresh.generation > old.generation and fresh.oil_win ~= old.oil_win,
    "queued reopen did not create a fresh session"
  )
  assert(
    not h.windows[old.oil_win] and not h.windows[old.preview_win],
    "queued reopen leaked old windows"
  )
  controller.toggle()
  table.remove(h.pending, 1)()
  h:flush()
  eq(controller.snapshot(), nil, "queued close did not settle")
  eq(vim.tbl_keys(h.windows), { 1 }, "queued close leaked windows")
  eq(h.deletes, 2, "queued close leaked groups")
end)

case("native preview overlap keeps the source until every callback finishes", function()
  local h, controller = controller_harness({ columns = 30, height = 10, defer_preview = true })
  local native = h.oil.open_preview
  controller.toggle()
  h:flush()
  local state = controller.snapshot()
  local completed = 0
  local function callback(err)
    assert(h.windows[state.oil_win], "native callback lost its source window")
    completed = completed + 1
    if completed == 1 then
      eq(err, "native preview failure", "native callback error changed")
    end
  end
  h.oil.open_preview(nil, callback)
  h.oil.open_preview(nil, callback)
  local preview = h.last_preview
  controller.toggle()
  assert(
    h.windows[state.oil_win] and h.windows[preview],
    "native requests closed before completion"
  )
  table.remove(h.pending, 2)("native preview failure")
  h:flush()
  assert(h.windows[state.oil_win] and h.windows[preview], "first callback closed another request")
  table.remove(h.pending, 1)()
  h:flush()
  eq(completed, 2, "native callbacks were not forwarded exactly once")
  eq(controller.snapshot(), nil, "native requests did not release queued close")
  eq(vim.tbl_keys(h.windows), { 1 }, "native overlap leaked windows")
  eq(h.oil.open_preview, native, "close did not restore native public API")
end)

case("unrelated native requests do not delay workspace close", function()
  local h, controller = controller_harness({ columns = 30, height = 10, defer_preview = true })
  controller.toggle()
  h:flush()
  h.current = 1
  local finished = false
  h.oil.open_preview(nil, function()
    finished = true
  end)
  local unrelated = h.last_preview
  controller.toggle()
  eq(controller.snapshot(), nil, "unrelated request blocked close")
  assert(h.windows[unrelated], "workspace closed unrelated native preview")
  table.remove(h.pending, 1)()
  eq(finished, true, "unrelated callback was not forwarded")
end)

case("native callback exceptions release the queued close", function()
  local h, controller = controller_harness({ columns = 30, height = 10, defer_preview = true })
  controller.toggle()
  h:flush()
  h.oil.open_preview(nil, function()
    error("native caller callback failure")
  end)
  controller.toggle()
  local ok, err = pcall(table.remove(h.pending, 1))
  assert(not ok and tostring(err):find("native caller callback failure", 1, true))
  eq(controller.snapshot(), nil, "callback exception left close pending")
  eq(vim.tbl_keys(h.windows), { 1 }, "callback exception leaked windows")
end)

case("native API exceptions preserve their error and release the session", function()
  local options = { columns = 30, height = 10, preview_throw = true }
  local h, controller = controller_harness(options)
  local native = h.oil.open_preview
  controller.toggle()
  h:flush()
  local ok, err = pcall(h.oil.open_preview)
  assert(not ok and tostring(err):find("injected preview exception", 1, true))
  eq(#h.notifications, 0, "native exception was converted to a duplicate notification")
  controller.toggle()
  eq(controller.snapshot(), nil, "native exception left close pending")
  eq(h.oil.open_preview, native, "failed native request leaked its API observer")
end)

case("native cleanup restores only the API observer owned by this session", function()
  local h, controller = controller_harness()
  local native = h.oil.open_preview
  controller.toggle()
  h:flush()
  h.runtime.close_win(controller.snapshot().oil_win)
  eq(h.oil.open_preview, native, "native close leaked its API observer")
  controller.toggle()
  h:flush()
  local replacement = function() end
  h.oil.open_preview = replacement
  controller.toggle()
  eq(h.oil.open_preview, replacement, "cleanup replaced another caller's public API")
end)

assert(#failures == 0, table.concat(failures, "\n\n"))

if vim.env.DOTFILES_OIL_WORKSPACE_LIVE == "1" then
  local root = assert(vim.env.DOTFILES_OIL_WORKSPACE_TEST_ROOT, "private fixture root required")
  assert(root:sub(1, 1) == "/" and root ~= "/", "fixture root must be an absolute child")
  local stat = assert(vim.uv.fs_lstat(root), "fixture root must already exist")
  assert(
    stat.type == "directory" and vim.uv.fs_realpath(root) == root,
    "fixture root must not be a symlink"
  )
  local source = root .. "/source/"
  assert(vim.uv.fs_mkdir(source, 448))
  assert(vim.uv.fs_mkdir(source .. "nested", 448))
  vim.fn.writefile({ "alpha contents" }, source .. "alpha.txt")
  vim.fn.writefile({ "beta contents" }, source .. "beta.txt")
  vim.fn.writefile({ "child contents" }, source .. "nested/child.txt")
  require("mini.icons").setup({})
  local oil_spec
  for _, spec in ipairs(require("plugins.navigation")) do
    if spec[1] == "stevearc/oil.nvim" then
      oil_spec = spec
    end
  end
  local oil = require("oil")
  oil.setup(assert(oil_spec).opts)
  for _, mapping in ipairs(oil_spec.keys) do
    vim.keymap.set(mapping.mode, mapping[1], mapping[2], { desc = mapping.desc })
  end
  vim.o.columns, vim.o.lines = 126, 44
  vim.o.showtabline, vim.o.laststatus, vim.o.cmdheight = 0, 0, 0
  vim.cmd.edit(vim.fn.fnameescape(source .. "alpha.txt"))
  local origin_buf = vim.api.nvim_get_current_buf()
  eq(vim.fn.maparg("-", "n", false, true), {}, "global dash is native Neovim")
  workspace.toggle()
  local oil_win = vim.api.nvim_get_current_win()
  local function preview()
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if winid ~= oil_win and vim.wo[winid].previewwindow then
        return winid
      end
    end
  end
  local function contains(winid, content)
    return winid
      and vim.api.nvim_win_is_valid(winid)
      and table
        .concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(winid), 0, -1, false), "\n")
        :find(content, 1, true)
  end
  assert(
    vim.wait(3000, function()
      return contains(preview(), "alpha contents")
    end),
    "native preview did not render the current file"
  )
  local preview_win = assert(preview())
  eq(vim.bo[vim.api.nvim_win_get_buf(oil_win)].filetype, "oil", "quick open focused Oil")
  eq(oil.get_current_dir(), source, "file opens its parent directory")
  local oil_config = vim.api.nvim_win_get_config(oil_win)
  local preview_config = vim.api.nvim_win_get_config(preview_win)
  local rounded_border = { "╭", "─", "╮", "│", "╯", "─", "╰", "│" }
  local function footer_text(config)
    if type(config.footer) == "string" then
      return config.footer
    end
    local parts = {}
    for _, chunk in ipairs(config.footer or {}) do
      parts[#parts + 1] = chunk[1]
    end
    return table.concat(parts)
  end
  local function visible_hints(winid)
    local config = vim.api.nvim_win_get_config(winid)
    local text = footer_text(config)
    assert(text:find("g? Help", 1, true), "Oil did not show its help key on open or resize")
    assert(vim.fn.strdisplaywidth(text) <= config.width, "Oil hints overflowed the border")
    eq(config.footer_pos, "left", "Oil hint alignment")
    eq(config.border, rounded_border, "Oil lost its visible rounded border")
    return text
  end
  local decoration_failures = {}
  if not vim.deep_equal(oil_config.border, rounded_border) then
    table.insert(decoration_failures, "Oil needs a visible rounded border")
  end
  if not vim.deep_equal(preview_config.border, rounded_border) then
    table.insert(decoration_failures, "native preview needs a visible rounded border")
  end
  if not footer_text(oil_config):find("g? Help", 1, true) then
    table.insert(decoration_failures, "Oil needs a discoverable help hint on open")
  end
  assert(#decoration_failures == 0, table.concat(decoration_failures, "; "))
  local initial_hints = visible_hints(oil_win)
  assert(initial_hints:find("Enter Open", 1, true) and initial_hints:find("- Parent", 1, true))
  eq(footer_text(preview_config), "", "Oil control hints leaked into the native preview")
  assert(oil_config.col < preview_config.col, "wide Oil must be left of preview")
  eq(vim.api.nvim_get_current_win(), oil_win, "quick open focus")
  eq(vim.fn.maparg("-", "n", false, true).buffer, 1, "native buffer-local parent mapping")
  local function move_to(name)
    local found = false
    for row, line in
      ipairs(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(oil_win), 0, -1, false))
    do
      if line:sub(-#name) == name then
        vim.api.nvim_win_set_cursor(oil_win, { row, 0 })
        found = true
        break
      end
    end
    assert(found, "missing native Oil entry: " .. name)
    vim.api.nvim_exec_autocmds(
      "CursorMoved",
      { buffer = vim.api.nvim_win_get_buf(oil_win), modeline = false }
    )
  end
  local function native_key(key)
    local mapping = vim.fn.maparg(key, "n", false, true)
    assert(
      mapping.buffer == 1 and type(mapping.callback) == "function",
      "native Oil callback missing: " .. key
    )
    mapping.callback()
  end
  -- The visible help hint leads to Oil's native list and returns to browsing.
  local before_help_cursor = vim.api.nvim_win_get_cursor(oil_win)
  native_key("g?")
  local help_win = vim.api.nvim_get_current_win()
  assert(help_win ~= oil_win and help_win ~= preview_win, "native help did not open")
  assert(contains(help_win, "Open the entry under the cursor"), "native key list is missing")
  assert(contains(help_win, "<C-p>"), "native preview key is absent from help")
  vim.cmd.normal("q")
  assert(not vim.api.nvim_win_is_valid(help_win), "native help did not close with q")
  eq(vim.api.nvim_get_current_win(), oil_win, "help did not return focus to Oil")
  eq(vim.api.nvim_win_get_cursor(oil_win), before_help_cursor, "help moved Oil selection")
  eq(preview(), preview_win, "help replaced the native preview")
  eq(visible_hints(oil_win), initial_hints, "help changed the border hints")
  move_to("beta.txt")
  assert(
    vim.wait(3000, function()
      return contains(preview_win, "beta contents")
    end),
    "native cursor follow failed"
  )
  eq(preview(), preview_win, "cursor follow replaced preview")
  move_to("nested/")
  assert(
    vim.wait(3000, function()
      return vim.bo[vim.api.nvim_win_get_buf(preview_win)].filetype == "oil"
    end),
    "native directory preview failed"
  )
  eq(vim.api.nvim_get_current_win(), oil_win, "directory preview stole focus")
  native_key("<C-p>")
  assert(
    vim.wait(3000, function()
      return not vim.api.nvim_win_is_valid(preview_win)
    end),
    "native preview close failed"
  )
  vim.wait(20)
  vim.api.nvim_exec_autocmds("VimResized", { modeline = false })
  vim.wait(20)
  eq(preview(), nil, "manually closed preview reopened")
  native_key("<C-p>")
  assert(
    vim.wait(3000, function()
      local winid = preview()
      return winid
        and vim.api.nvim_win_get_config(winid).col > vim.api.nvim_win_get_config(oil_win).col
    end),
    "native preview reopen was not adopted into responsive geometry"
  )
  preview_win = preview()

  workspace.toggle()
  assert(
    vim.wait(3000, function()
      return not vim.api.nvim_win_is_valid(oil_win)
    end),
    "toggle did not close Oil after native preview completion"
  )
  assert(not vim.api.nvim_win_is_valid(preview_win), "toggle did not close preview")
  eq(vim.api.nvim_get_current_buf(), origin_buf, "toggle restored origin buffer")

  local native_preview = oil.open_preview
  local preview_finished = false
  oil.open_preview = function(opts, callback)
    native_preview(opts, function(err)
      preview_finished = true
      callback(err)
    end)
    workspace.toggle()
  end
  workspace.toggle()
  local closed_during_preview = vim.wait(3000, function()
    return preview_finished and #vim.api.nvim_tabpage_list_wins(0) == 1
  end)
  oil.open_preview = native_preview
  assert(closed_during_preview, "close during native preview creation did not finish cleanly")
  local unrelated_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(unrelated_buf, 0, -1, false, { "unrelated", "preview" })
  local unrelated_win = vim.api.nvim_open_win(unrelated_buf, false, {
    relative = "editor",
    row = 3,
    col = 3,
    width = 28,
    height = 5,
    border = "none",
  })
  vim.wo[unrelated_win].previewwindow = true
  vim.api.nvim_win_set_cursor(unrelated_win, { 2, 0 })
  local unrelated_config = vim.api.nvim_win_get_config(unrelated_win)
  local unrelated_view = vim.api.nvim_win_call(unrelated_win, vim.fn.winsaveview)
  local origin_win = vim.api.nvim_get_current_win()
  workspace.toggle()
  oil_win = vim.api.nvim_get_current_win()
  assert(
    vim.wait(3000, function()
      return contains(preview(), "alpha contents")
    end),
    "private preview did not open"
  )
  eq(vim.wo[unrelated_win].previewwindow, false, "unrelated marker not suspended")
  eq(vim.api.nvim_win_get_buf(unrelated_win), unrelated_buf, "unrelated buffer replaced")
  eq(vim.api.nvim_win_get_config(unrelated_win), unrelated_config, "unrelated geometry changed")
  eq(
    vim.api.nvim_win_call(unrelated_win, vim.fn.winsaveview),
    unrelated_view,
    "unrelated view changed"
  )
  workspace.toggle()
  eq(vim.wo[unrelated_win].previewwindow, true, "unrelated marker not restored")
  eq(vim.api.nvim_get_current_win(), origin_win, "unrelated preview stole final focus")
  vim.api.nvim_win_close(unrelated_win, true)

  assert(vim.uv.fs_mkdir(source .. "empty", 448))
  vim.cmd.cd(vim.fn.fnameescape(source .. "empty"))
  vim.cmd.enew()
  vim.bo.buftype = "nofile"
  local notifications = {}
  local native_notify = vim.notify
  vim.notify = function(message, level, opts)
    table.insert(notifications, { message, level, opts })
  end
  workspace.toggle()
  oil_win = vim.api.nvim_get_current_win()
  assert(
    vim.wait(3000, function()
      return #notifications > 0
    end),
    "empty directory did not finish its native preview request"
  )
  vim.api.nvim_exec_autocmds("VimResized", { modeline = false })
  vim.wait(20)
  workspace.toggle()
  vim.notify = native_notify
  eq(#notifications, 1, "empty-directory error duplicated")
  eq(notifications[1][1], "Could not find entry under cursor", "empty-directory native error")
  local function resize(columns, lines)
    vim.o.columns, vim.o.lines = columns, lines
    vim.api.nvim_exec_autocmds("VimResized", { modeline = false })
  end
  local function open_at(columns, lines)
    resize(columns, lines)
    vim.cmd.edit(vim.fn.fnameescape(source .. "alpha.txt"))
    workspace.toggle()
    oil_win = vim.api.nvim_get_current_win()
    assert(
      vim.wait(3000, function()
        return vim.bo[vim.api.nvim_win_get_buf(oil_win)].filetype == "oil"
          and vim.bo[vim.api.nvim_win_get_buf(oil_win)].modifiable
      end),
      "Oil did not become ready"
    )
    return oil_win, vim.api.nvim_win_get_buf(oil_win)
  end
  local function pair_is(mode)
    local winid = preview()
    if not winid then
      return false
    end
    local left, right = vim.api.nvim_win_get_config(oil_win), vim.api.nvim_win_get_config(winid)
    if mode == "wide" then
      return left.col < right.col and left.width >= 32 and right.width >= 48
    end
    return left.row < right.row and left.height >= 8 and right.height >= 8
  end
  local stable_oil, stable_buf = open_at(126, 44)
  assert(
    vim.wait(3000, function()
      return contains(preview(), "alpha contents")
    end),
    "wide preview missing"
  )
  local stable_preview = preview()
  resize(80, 44)
  assert(
    vim.wait(3000, function()
      return pair_is("narrow")
    end),
    "resize did not stack native preview"
  )
  eq(preview(), stable_preview, "wide-to-narrow replaced preview")
  eq(vim.api.nvim_get_current_win(), stable_oil, "resize moved Oil focus")
  assert(
    visible_hints(stable_oil):find("Ctrl-p Preview", 1, true),
    "wide Oil pane did not expand its hints"
  )
  eq(
    vim.api.nvim_win_get_config(stable_preview).border,
    rounded_border,
    "resize lost preview border"
  )
  resize(126, 44)
  assert(
    vim.wait(3000, function()
      return pair_is("wide")
    end),
    "resize did not restore side-by-side preview"
  )
  eq(preview(), stable_preview, "narrow-to-wide replaced preview")
  visible_hints(stable_oil)
  move_to("beta.txt")
  assert(
    vim.wait(3000, function()
      return contains(stable_preview, "beta contents")
    end),
    "selected beta preview missing"
  )
  local saved_cursor = vim.api.nvim_win_get_cursor(stable_oil)
  vim.api.nvim_buf_set_lines(stable_buf, -1, -1, false, { "unsaved-file.txt" })
  assert(vim.bo[stable_buf].modified, "pending edit fixture did not modify Oil")
  resize(30, 10)
  assert(
    vim.wait(3000, function()
      return preview() == nil
    end),
    "tiny resize did not defer preview"
  )
  local tiny_hints = visible_hints(stable_oil)
  assert(not tiny_hints:find("Ctrl-p", 1, true), "tiny Oil did not shorten its hints")
  eq(vim.api.nvim_win_get_buf(stable_oil), stable_buf, "tiny resize replaced Oil buffer")
  eq(vim.api.nvim_win_get_cursor(stable_oil), saved_cursor, "tiny resize moved selection")
  eq(vim.bo[stable_buf].modified, true, "tiny resize discarded edits")
  eq(oil.get_current_dir(), source, "tiny resize changed directory")
  resize(80, 44)
  assert(
    vim.wait(3000, function()
      return pair_is("narrow") and contains(preview(), "beta contents")
    end),
    "enlarge did not restore the selected native preview"
  )
  assert(preview() ~= stable_preview, "enlarge reused a closed preview")
  eq(vim.api.nvim_get_current_win(), stable_oil, "deferred preview stole focus")
  eq(vim.bo[stable_buf].modified, true, "preview reopen discarded edits")
  vim.cmd.edit({ bang = true })
  assert(
    vim.wait(3000, function()
      local buf = vim.api.nvim_win_get_buf(oil_win)
      local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      return vim.bo[buf].modifiable
        and not vim.bo[buf].modified
        and text:find("alpha.txt", 1, true)
        and not text:find("unsaved-file.txt", 1, true)
    end),
    "explicit discard did not complete"
  )
  workspace.toggle()

  for _, target in ipairs({ { 80, 44, "narrow" }, { 126, 44, "wide" } }) do
    local tiny_oil = open_at(30, 10)
    local tiny = vim.api.nvim_win_get_config(tiny_oil)
    assert(
      tiny.width > 0
        and tiny.height > 0
        and tiny.col + tiny.width + 2 <= 30
        and tiny.row + tiny.height + 2 <= 10,
      "tiny Oil escaped editor"
    )
    visible_hints(tiny_oil)
    eq(preview(), nil, "tiny open requested preview")
    resize(target[1], target[2])
    assert(
      vim.wait(3000, function()
        return pair_is(target[3]) and contains(preview(), "alpha contents")
      end),
      "initial tiny preview did not return on enlargement"
    )
    eq(vim.api.nvim_get_current_win(), tiny_oil, "initial tiny enlargement replaced focus")
    native_key("<C-p>")
    assert(
      vim.wait(3000, function()
        return preview() == nil
      end),
      "native close failed"
    )
    vim.wait(20)
    for _, dimensions in ipairs({ { 30, 10 }, { 80, 44 }, { 126, 44 } }) do
      resize(dimensions[1], dimensions[2])
      vim.wait(20)
      eq(preview(), nil, "resize undid manual preview closure")
    end
    native_key("<C-p>")
    assert(
      vim.wait(3000, function()
        return pair_is("wide") and contains(preview(), "alpha contents")
      end),
      "native reopen lost current layout"
    )
    workspace.toggle()
  end
  local function global_toggle()
    local mapping = vim.fn.maparg("<leader><Tab>", "n", false, true)
    eq(mapping.desc, "Toggle Oil workspace", "global workspace toggle description")
    assert(type(mapping.callback) == "function", "global workspace callback missing")
    mapping.callback()
  end
  local function no_owned_events()
    for _, autocmd in ipairs(vim.api.nvim_get_autocmds({})) do
      assert(
        not (autocmd.group_name or ""):find("^dotfiles%-oil%-workspace%-"),
        "owned autocmd group leaked"
      )
    end
  end
  local function wait_closed(winid)
    assert(
      vim.wait(3000, function()
        return not vim.api.nvim_win_is_valid(winid)
      end),
      "workspace did not close"
    )
    no_owned_events()
  end
  -- Native directory Enter, parent '-', and file Enter retain Oil semantics.
  local directory_oil = open_at(126, 44)
  assert(
    vim.wait(3000, function()
      return contains(preview(), "alpha contents")
    end),
    "selection preview not ready"
  )
  move_to("nested/")
  native_key("<CR>")
  assert(
    vim.wait(3000, function()
      return oil.get_current_dir() == source .. "nested/"
        and vim.bo.modifiable
        and table
          .concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
          :find("child.txt", 1, true)
    end),
    "native Enter did not navigate to directory"
  )
  eq(vim.api.nvim_get_current_win(), directory_oil, "directory Enter replaced Oil window")
  native_key("-")
  assert(
    vim.wait(3000, function()
      return oil.get_current_dir() == source
        and vim.bo.modifiable
        and table
          .concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
          :find("beta.txt", 1, true)
    end),
    "native parent mapping failed"
  )
  move_to("beta.txt")
  assert(
    vim.wait(3000, function()
      return contains(preview(), "beta contents")
    end),
    "file selection preview missing"
  )
  native_key("<CR>")
  wait_closed(directory_oil)
  assert(
    vim.wait(3000, function()
      return vim.api.nvim_buf_get_name(0) == source .. "beta.txt"
    end),
    "native file Enter did not restore editing context"
  )

  -- The global callback targets the owned session from every normal-mode context.
  for _, context in ipairs({ "oil", "preview", "other" }) do
    local focused_oil = open_at(126, 44)
    assert(
      vim.wait(3000, function()
        return contains(preview(), "alpha contents")
      end),
      "toggle preview not ready"
    )
    local origin = vim.api.nvim_tabpage_list_wins(0)[1]
    if context == "preview" then
      vim.api.nvim_set_current_win(assert(preview()))
    elseif context == "other" then
      vim.api.nvim_set_current_win(origin)
    end
    global_toggle()
    wait_closed(focused_oil)
    eq(vim.api.nvim_get_current_win(), origin, "toggle did not restore origin from " .. context)
  end

  -- Pending edits refuse the mapped close; native :edit! discards them explicitly.
  local edited_oil, edited_buf = open_at(126, 44)
  assert(
    vim.wait(3000, function()
      return contains(preview(), "alpha contents")
    end),
    "edit preview not ready"
  )
  vim.api.nvim_buf_set_lines(edited_buf, -1, -1, false, { "unsaved-second-file.txt" })
  local notices, original_notify = {}, vim.notify
  vim.notify = function(message, level, opts)
    table.insert(notices, { message, level, opts })
  end
  global_toggle()
  vim.notify = original_notify
  assert(vim.api.nvim_win_is_valid(edited_oil) and preview(), "mapped toggle discarded Oil edits")
  eq(#notices, 1, "mapped close warning count")
  eq(notices[1][2], vim.log.levels.WARN, "mapped close warning severity")
  eq(vim.api.nvim_get_current_win(), edited_oil, "pending edit warning did not focus Oil")
  vim.cmd.edit({ bang = true })
  assert(
    vim.wait(3000, function()
      local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
      return vim.bo.modifiable
        and not vim.bo.modified
        and text:find("alpha.txt", 1, true)
        and not text:find("unsaved-second-file.txt", 1, true)
    end),
    "native discard did not finish"
  )
  global_toggle()
  wait_closed(edited_oil)

  -- An unnamed nofile buffer uses the cwd through Oil's nil directory argument.
  vim.cmd.cd(vim.fn.fnameescape(source))
  vim.cmd.enew()
  vim.bo.buftype = "nofile"
  global_toggle()
  oil_win = vim.api.nvim_get_current_win()
  assert(
    vim.wait(3000, function()
      return oil.get_current_dir() == source
        and vim.bo.modifiable
        and table
          .concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
          :find("alpha.txt", 1, true)
    end),
    "unnamed buffer did not open cwd"
  )
  move_to("alpha.txt")
  assert(
    vim.wait(3000, function()
      return contains(preview(), "alpha contents")
    end),
    "unnamed preview did not finish"
  )
  global_toggle()
  wait_closed(oil_win)

  -- Deleting the origin never causes the controller to create a replacement buffer.
  local surviving_win = vim.api.nvim_get_current_win()
  vim.cmd.vsplit()
  local deleted_origin = vim.api.nvim_get_current_win()
  local orphan_oil = open_at(126, 44)
  assert(
    vim.wait(3000, function()
      return contains(preview(), "alpha contents")
    end),
    "invalid-origin preview not ready"
  )
  vim.api.nvim_win_close(deleted_origin, true)
  local before_buffers = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    before_buffers[bufnr] = true
  end
  global_toggle()
  wait_closed(orphan_oil)
  eq(
    vim.api.nvim_get_current_win(),
    surviving_win,
    "invalid origin did not retain a valid existing window"
  )
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    assert(before_buffers[bufnr], "invalid-origin close created a buffer")
  end

  -- Rapid toggles while a fresh directory is still loading leave only the new session.
  assert(vim.uv.fs_mkdir(source .. "rapid", 448))
  vim.fn.writefile({ "rapid contents" }, source .. "rapid/entry.txt")
  vim.cmd.edit(vim.fn.fnameescape(source .. "rapid/entry.txt"))
  global_toggle()
  local obsolete = vim.api.nvim_get_current_win()
  global_toggle()
  global_toggle()
  oil_win = vim.api.nvim_get_current_win()
  assert(oil_win ~= obsolete, "rapid reopen reused the old Oil window")
  assert(
    vim.wait(3000, function()
      return contains(preview(), "rapid contents")
    end),
    "rapid reopen did not settle"
  )
  eq(#vim.api.nvim_tabpage_list_wins(0), 3, "rapid sequence left extra floats")
  global_toggle()
  wait_closed(oil_win)
  eq(#vim.api.nvim_tabpage_list_wins(0), 1, "rapid close left floats")

  -- A real partial native open failure restores an unrelated preview exactly.
  vim.cmd.edit(vim.fn.fnameescape(source .. "alpha.txt"))
  local unrelated = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
    relative = "editor",
    row = 1,
    col = 1,
    width = 22,
    height = 5,
    border = "none",
  })
  vim.wo[unrelated].previewwindow = true
  local unrelated_before = vim.api.nvim_win_get_config(unrelated)
  local native_open, notify_before = oil.open_float, vim.notify
  local open_errors = {}
  oil.open_float = function(...)
    native_open(...)
    error("injected partial native open failure")
  end
  vim.notify = function(message)
    table.insert(open_errors, message)
  end
  global_toggle()
  oil.open_float, vim.notify = native_open, notify_before
  eq(#open_errors, 1, "partial native open failure notification count")
  eq(vim.wo[unrelated].previewwindow, true, "partial native failure lost unrelated preview marker")
  eq(
    vim.api.nvim_win_get_config(unrelated),
    unrelated_before,
    "partial native failure moved unrelated preview"
  )
  eq(#vim.api.nvim_tabpage_list_wins(0), 2, "partial native failure leaked a float")
  no_owned_events()
  vim.api.nvim_win_close(unrelated, true)

  for _, trigger in ipairs({ "manual reopen", "cursor follow" }) do
    for _, reopen in ipairs({ false, true }) do
      local native = oil.open_preview
      local armed, started, finished = false, false, false
      local observed = function(opts, callback)
        local targeted = armed
        if targeted then
          armed, started = false, true
        end
        native(opts, function(err)
          if targeted then
            finished = true
          end
          if callback then
            callback(err)
          end
        end)
        if targeted then
          global_toggle()
          if reopen then
            global_toggle()
          end
        end
      end
      oil.open_preview = observed
      open_at(126, 44)
      local old_oil = oil_win
      assert(
        vim.wait(3000, function()
          return contains(preview(), "alpha contents")
        end),
        "native race fixture did not settle"
      )
      if trigger == "manual reopen" then
        native_key("<C-p>")
        assert(
          vim.wait(3000, function()
            return not preview()
          end),
          "native race fixture preview did not close"
        )
        vim.wait(20)
      end
      armed = true
      if trigger == "manual reopen" then
        native_key("<C-p>")
      else
        move_to("beta.txt")
      end
      assert(
        vim.wait(3000, function()
          if not started or not finished or vim.api.nvim_win_is_valid(old_oil) then
            return false
          end
          if reopen then
            oil_win = vim.api.nvim_get_current_win()
            return oil_win ~= old_oil
              and vim.bo[vim.api.nvim_win_get_buf(oil_win)].filetype == "oil"
              and contains(preview(), "alpha contents")
          end
          return #vim.api.nvim_tabpage_list_wins(0) == 1
        end),
        "close during native "
          .. trigger
          .. " did not finish cleanly (reopen="
          .. tostring(reopen)
          .. ")"
      )
      if reopen then
        global_toggle()
      end
      eq(oil.open_preview, observed, "native race cleanup did not restore public API")
      oil.open_preview = native
      eq(#vim.api.nvim_tabpage_list_wins(0), 1, "native race leaked windows")
      no_owned_events()
    end
  end
end

print("Responsive Oil workspace assertions: ok")
