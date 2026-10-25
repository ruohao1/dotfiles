local statusline = require("ui.statusline")
local test = statusline._test

local function eq(actual, expected, label)
  assert(
    vim.deep_equal(actual, expected),
    string.format("%s\nexpected: %s\nactual: %s", label, vim.inspect(expected), vim.inspect(actual))
  )
end

local function contains(value, fragment, label)
  assert(value:find(fragment, 1, true), string.format("%s: %q lacks %q", label, value, fragment))
end

eq(test.profile_for_width(79).name, "narrow", "79 columns")
eq(test.profile_for_width(80), {
  name = "compact",
  git = 22,
  path = 13,
  diagnostic = 9,
  line = 9999,
  column = 999,
}, "80-column profile")
eq(test.profile_for_width(99).name, "compact", "99-column boundary")
eq(test.profile_for_width(100), {
  name = "medium",
  git = 26,
  path = 14,
  diagnostic = 99,
  line = 99999,
  column = 999,
}, "100-column profile")
eq(test.profile_for_width(119).name, "medium", "119-column boundary")
eq(test.profile_for_width(120), {
  name = "wide",
  git = 36,
  path = 20,
  diagnostic = 999,
  line = 999999,
  column = 9999,
}, "120-column profile")

local mode_cases = {
  n = "NORMAL",
  no = "NORMAL",
  nt = "NORMAL",
  i = "INSERT",
  ic = "INSERT",
  ix = "INSERT",
  v = "VISUAL",
  vs = "VISUAL",
  V = "VISUAL",
  Vs = "VISUAL",
  ["\22"] = "VISUAL",
  ["\22s"] = "VISUAL",
  s = "SELECT",
  S = "SELECT",
  ["\19"] = "SELECT",
  R = "REPLACE",
  Rv = "REPLACE",
  Rc = "REPLACE",
  c = "COMMAND",
  cv = "COMMAND",
  ce = "COMMAND",
  r = "PROMPT",
  rm = "PROMPT",
  ["r?"] = "PROMPT",
  ["!"] = "PROMPT",
  t = "TERMINAL",
}
for input, expected in pairs(mode_cases) do
  eq(test.normalize_mode(input), expected, "mode " .. vim.inspect(input))
end

eq(test.sanitize("a\0b\nc\r\27\td"), "abcd", "control stripping")
local c1_first = vim.fn.nr2char(0x80)
local c1_csi = vim.fn.nr2char(0x9b)
local c1_last = vim.fn.nr2char(0x9f)
eq(
  test.sanitize("é" .. c1_first .. "a" .. c1_csi .. "b" .. c1_last .. "界"),
  "éab界",
  "UTF-8 C1 control stripping"
)
eq(
  test.sanitize([[100% # #{pane_id} #(id) ' " ]]),
  [[100% # #{pane_id} #(id) ' " ]],
  "safe syntax-shaped text"
)
eq(test.escape_statusline("100%"), "100%%", "literal percent escaping")
local c1_render = test.render_parts({
  mode = "NORMAL",
  root = "/repo",
  path = "a" .. c1_csi .. "b",
  errors = 0,
  warnings = 0,
  line = 1,
  column = 1,
  width = 80,
}, "g" .. c1_csi .. "t")
assert(not c1_render.expression:find(c1_csi, 1, true), "render expression retained a C1 control")
contains(c1_render.expression, "ab", "rendered path surrounding C1")
contains(c1_render.expression, "gt", "rendered Git surrounding C1")
eq(test.truncate_left("abcdef", 4), "…def", "longest fitting suffix")
eq(test.truncate_left("a界b", 2), "…b", "wide-character suffix")
eq(test.truncate_left("xx界́", 2), "…", "combining mark stays attached to its base")
local bounded = test.sanitize(string.rep("界", 400), 100)
assert(#bounded <= 100, "sanitized value exceeds its byte cap")
assert(pcall(vim.str_utfindex, bounded), "sanitized cap split a UTF-8 character")

eq(
  test.display_path({
    name = "/work/repo/lua/ui/statusline.lua",
    buftype = "",
    root = "/work/repo",
    cwd = "/work/repo/lua",
  }),
  "lua/ui/statusline.lua",
  "Git-relative path"
)

eq(
  test.display_path({
    name = "/work/plain/src/main.lua",
    buftype = "",
    root = nil,
    cwd = "/work/plain",
  }),
  "src/main.lua",
  "cwd-relative path"
)

eq(
  test.display_path({
    name = "/elsewhere/main.lua",
    buftype = "",
    root = nil,
    cwd = "/work/plain",
  }),
  "main.lua",
  "outside-cwd basename"
)

eq(
  test.display_path({
    name = "/work/repo2/main.lua",
    buftype = "",
    root = "/work/repo",
    cwd = "/work/repo",
  }),
  "main.lua",
  "path-prefix boundary"
)

eq(
  test.display_path({ name = "", buftype = "", root = nil, cwd = "/work/repo" }),
  "[No Name]",
  "unnamed normal buffer"
)
eq(
  test.display_path({
    name = "term://host//123:zsh",
    buftype = "terminal",
    root = nil,
    cwd = "/work/repo",
  }),
  "123:zsh",
  "special buffer short name"
)

eq(
  test.build_snapshot({
    mode = "i",
    name = "/work/repo/lua/init.lua",
    buftype = "",
    root = "/work/repo",
    cwd = "/work/repo",
    errors = 2,
    warnings = 3,
    line = 7,
    column = 11,
    width = 100,
  }),
  {
    mode = "INSERT",
    root = "/work/repo",
    path = "lua/init.lua",
    modified = false,
    errors = 2,
    warnings = 3,
    line = 7,
    column = 11,
    width = 100,
  },
  "canonical named-buffer snapshot"
)
for _, value in ipairs({ true, false, 1, "1", "true" }) do
  eq(test.build_snapshot({ modified = value }).modified, value == true, "strict modified snapshot")
end

for _, special in ipairs({
  { name = "", buftype = "" },
  { name = "term://host//123:zsh", buftype = "terminal" },
}) do
  local snapshot = test.build_snapshot(vim.tbl_extend("force", special, {
    root = nil,
    cwd = "/work/repo",
    mode = "n",
    errors = 0,
    warnings = 0,
    line = 1,
    column = 1,
    width = 80,
  }))
  eq(snapshot.root, nil, "special buffer must not inherit cwd Git root")
end

local compact = test.render_parts({
  mode = "INSERT",
  root = "/work/repo",
  path = "lua/plugins/very-long-statusline.lua",
  errors = 12,
  warnings = 14,
  line = 12000,
  column = 2000,
  width = 80,
}, "longbranch +9 ~9 ?9 !9")

eq(vim.fn.strdisplaywidth(compact.left_text), 32, "compact INSERT dynamic left")
eq(vim.fn.strdisplaywidth(compact.right_text), 34, "compact right maximum")
contains(compact.expression, "%=", "single alignment separator")
eq(select(2, compact.expression:gsub("%%=", "")), 1, "one alignment separator")
contains(compact.expression, "E9+", "compact diagnostic saturation")
contains(compact.expression, "9999+:999+", "compact cursor saturation")

local medium = test.render_parts({
  mode = "NORMAL",
  root = "/repo",
  path = string.rep("p", 40),
  errors = 100,
  warnings = 100,
  line = 100000,
  column = 1000,
  width = 100,
}, "branch +99+ ~99+ ?99+ !99+")
eq(vim.fn.strdisplaywidth(medium.left_text), 36, "medium NORMAL dynamic left")
eq(vim.fn.strdisplaywidth(medium.right_text), 38, "medium right maximum")

local wide = test.render_parts({
  mode = "TERMINAL",
  root = "/repo",
  path = string.rep("p", 50),
  errors = 1000,
  warnings = 1000,
  line = 1000000,
  column = 10000,
  width = 120,
}, "widebranch12 +999+ ~999+ ?999+ !999+")
eq(vim.fn.strdisplaywidth(wide.left_text), 48, "wide TERMINAL left maximum")
eq(vim.fn.strdisplaywidth(wide.right_text), 48, "wide right maximum")

local narrow = test.render_parts({
  mode = "INSERT",
  root = "/repo",
  path = "hidden.lua",
  errors = 2,
  warnings = 3,
  line = 12,
  column = 3,
  width = 79,
}, "must-not-render")
eq(narrow.left_text, " I ", "narrow mode only")
eq(narrow.right_text, " 12:3 ", "narrow cursor only")
eq(
  test.render_parts({
    mode = "INSERT",
    modified = true,
    line = 12,
    column = 3,
    width = 79,
  }, "").right_text,
  " [+] 12:3 ",
  "narrow status retains the unsaved marker"
)
for _, width in ipairs({ 79, 80, 99, 100, 119, 120 }) do
  local snapshot = {
    path = string.rep("界", 30) .. "file.lua",
    errors = 999999999,
    warnings = 999999999,
    line = 999999999,
    column = 999999999,
    width = width,
  }
  local clean = test.render_parts(snapshot, "")
  snapshot.modified = true
  local dirty = test.render_parts(snapshot, "")
  contains(dirty.right_text, "[+]", "dirty marker at " .. width .. " columns")
  eq(
    vim.fn.strdisplaywidth(dirty.right_text),
    vim.fn.strdisplaywidth(clean.right_text) + (width < 80 and 4 or 0),
    "dirty status width budget at " .. width .. " columns"
  )
end

local omitted = test.render_parts({
  mode = "NORMAL",
  root = nil,
  path = "init.lua",
  errors = 0,
  warnings = 0,
  line = 4,
  column = 2,
  width = 80,
}, "")
eq(omitted.left_text, " NORMAL ", "omitted Git keeps natural-width mode")
eq(omitted.right_text, " init.lua 4:2 ", "omitted diagnostics remove separators")

local live_width = 80
local width_reads = 0
local live_render = test.make_renderer(function()
  return {
    mode = "NORMAL",
    root = nil,
    path = "a/very/long/path/to/statusline.lua",
    errors = 0,
    warnings = 0,
    line = 4,
    column = 2,
  }
end, function()
  return ""
end, function()
  width_reads = width_reads + 1
  return live_width
end)
local at_80 = live_render()
live_width = 120
local at_120 = live_render()
eq(width_reads, 2, "renderer reads live width on every call")
assert(at_80 ~= at_120, "renderer reused stale cached width")

print("statusline pure state and renderer: ok")

local function cache_harness()
  local now = 0
  local calls = {}
  local timer = { active = false, closed = false }

  function timer:start(timeout, repeat_ms, callback)
    self.timeout = timeout
    self.repeat_ms = repeat_ms
    self.callback = callback
    self.active = true
  end
  function timer:stop()
    self.active = false
  end
  function timer:close()
    self.closed = true
  end
  function timer:is_closing()
    return self.closed
  end

  local deps
  deps = {
    helper = "/config/dotfiles/git-summary",
    now = function()
      return now
    end,
    new_timer = function()
      return timer
    end,
    schedule = function(callback)
      callback()
    end,
    redraw = function()
      deps.redraws = (deps.redraws or 0) + 1
    end,
    system = function(argv, options, callback)
      local call = { argv = argv, options = options, callback = callback, killed = false }
      function call:kill(signal)
        self.killed = signal
      end
      table.insert(calls, call)
      return call
    end,
  }

  return {
    deps = deps,
    calls = calls,
    timer = timer,
    advance = function(milliseconds)
      now = now + milliseconds
    end,
  }
end

local function finish(harness, index, result)
  harness.calls[index].callback(vim.tbl_extend("force", {
    code = 0,
    signal = 0,
    stdout = "",
    stderr = "",
  }, result or {}))
end

do
  local h = cache_harness()
  local cache = test.new_git_cache(h.deps)
  cache:update("/repo/a", "compact", "BufEnter")
  finish(h, 1, { stdout = "main\n" })
  for index, reason in ipairs({
    "BufEnter",
    "WinEnter",
    "BufFilePost",
    "BufWritePost",
    "DirChanged",
  }) do
    cache:update("/repo/a", "compact", reason)
    eq(#h.calls, index + 1, "same-root refresh for " .. reason)
    eq(cache:get(), "main", "same-root refresh retains visible summary")
    finish(h, index + 1, { stdout = "main\n" })
  end
end

do
  local h = cache_harness()
  local cache = test.new_git_cache(h.deps)
  cache:update("/repo/a", "compact", "BufEnter")
  eq(#h.calls, 1, "first Git child")
  eq(h.calls[1].argv, {
    "/config/dotfiles/git-summary",
    "--path",
    "/repo/a",
    "--profile",
    "compact",
  }, "Git helper argv")
  eq(h.calls[1].options.text, true, "text mode")
  eq(h.calls[1].options.timeout, 4000, "outer timeout")

  cache:update("/repo/old", "compact", "BufEnter")
  cache:update("/repo/b", "compact", "BufEnter")
  eq(#h.calls, 1, "one child while roots change")
  finish(h, 1, { stdout = "stale\n" })
  eq(cache:get(), "", "late root result rejected")
  eq(#h.calls, 2, "newest pending root starts")
  eq(h.calls[2].argv[3], "/repo/b", "newest pending root")
  finish(h, 2, { stdout = "main +1\n" })
  eq(cache:get(), "main +1", "accepted current result")
  eq(h.deps.redraws, 1, "one accepted redraw")

  cache:update("/repo/b", "medium", "VimResized")
  eq(cache:get(), "", "profile transition clears incompatible output")
  eq(h.calls[3].argv[5], "medium", "profile transition request")
  finish(h, 3, { stdout = "medium-branch\n" })

  cache:set_focused(false)
  eq(h.timer.active, false, "focus loss pauses timer")
  cache:set_focused(true)
  eq(h.timer.active, true, "focus gain resumes timer")
  eq(h.timer.timeout, 5000, "timer initial delay")
  eq(h.timer.repeat_ms, 5000, "timer repeat")
  eq(cache:get(), "medium-branch", "focus refresh retains same-root result")
  eq(#h.calls, 4, "focus gain starts immediate refresh")
  finish(h, 4, { code = 124, signal = 15 })
  eq(cache:get(), "", "timeout accepts empty result")
  eq(cache:debug_state().retry_at, 5000, "failure backoff deadline")
  cache:set_focused(false)
  cache:set_focused(true)
  eq(#h.calls, 4, "same-root FocusGained obeys failure backoff")
  cache:update("/repo/b", "medium", "BufWritePost")
  eq(#h.calls, 4, "same-root request obeys backoff")
  h.advance(5000)
  cache:update("/repo/b", "medium", "periodic")
  eq(#h.calls, 5, "request resumes after backoff")
  finish(h, 5, { stdout = "safe\27value\n" })
  eq(cache:get(), "safevalue", "helper output sanitized")
end

do
  local h = cache_harness()
  local cache = test.new_git_cache(h.deps)
  cache:update("/repo/a", "compact", "BufEnter")
  cache:update("/repo/b", "compact", "BufEnter")
  cache:update("/repo/a", "compact", "BufEnter")
  eq(#h.calls, 1, "same-key generation change keeps one child")
  finish(h, 1, { stdout = "stale-same-key\n" })
  eq(cache:get(), "", "old generation is rejected when key matches again")
  eq(#h.calls, 2, "current same-key generation starts after rejection")
  finish(h, 2, { stdout = "fresh-same-key\n" })
  eq(cache:get(), "fresh-same-key", "current same-key generation is accepted")
end

do
  local h = cache_harness()
  local cache = test.new_git_cache(h.deps)
  cache:update("/repo/a", "compact", "BufEnter")
  cache:update("/repo/a", "compact", "BufWritePost")
  eq(#h.calls, 1, "same-key refresh waits behind active child")
  finish(h, 1, { code = 124, signal = 15 })
  eq(#h.calls, 1, "same-key pending request obeys new failure backoff")
  eq(cache:debug_state().retry_at, 5000, "same-key pending backoff deadline")
  h.advance(5000)
  cache:update("/repo/a", "compact", "periodic")
  eq(#h.calls, 2, "same-key refresh resumes after backoff")
  finish(h, 2, { stdout = "recovered\n" })
end

do
  local h = cache_harness()
  local cache = test.new_git_cache(h.deps)
  cache:update("/repo/a", "compact", "BufEnter")
  cache:update("/repo/b", "wide", "BufEnter")
  finish(h, 1, { code = 124, signal = 15 })
  eq(#h.calls, 2, "timeout services pending root immediately")
  eq(h.calls[2].argv[3], "/repo/b", "pending root after timeout")
  finish(h, 2, { stdout = "wide\n" })
end

do
  local h = cache_harness()
  local cache = test.new_git_cache(h.deps)
  cache:update("/repo/a", "compact", "BufEnter")
  cache:update("/repo/b", "compact", "BufEnter")
  local redraws = h.deps.redraws or 0
  cache:stop()
  eq(h.timer.active, false, "stop pauses timer")
  eq(h.timer.closed, true, "stop closes timer")
  eq(h.calls[1].killed, 15, "stop terminates child")
  finish(h, 1, { stdout = "late\n" })
  eq(cache:get(), "", "stopped cache rejects late result")
  eq(h.deps.redraws or 0, redraws, "late result does not redraw")
  eq(#h.calls, 1, "stopped cache discards pending work")
end

do
  local h = cache_harness()
  h.deps.system = function()
    error("spawn failed")
  end
  local cache = test.new_git_cache(h.deps)
  cache:update("/repo/a", "compact", "BufEnter")
  eq(cache:get(), "", "spawn failure is an empty result")
  eq(cache:debug_state().retry_at, 5000, "spawn failure backoff")
end

do
  local h = cache_harness()
  local cache = test.new_git_cache(h.deps)
  cache:update("/repo/a", "compact", "BufEnter")
  finish(h, 1, { code = 0, signal = 15, stdout = "terminated-output\n" })
  eq(cache:get(), "", "signaled code-zero result is empty")
  eq(cache:debug_state().retry_at, 5000, "signaled code-zero result enters backoff")
end

do
  local h = cache_harness()
  local cache = test.new_git_cache(h.deps)
  cache:update("/repo/a", "compact", "BufEnter")
  finish(h, 1, { stdout = "a\n" })

  cache:set_focused(false)
  cache:set_focused(true, {
    root = "/repo/b",
    profile = "wide",
  })

  eq(#h.calls, 2, "focus gain starts one current-root request")
  eq(h.calls[2].argv[3], "/repo/b", "focus gain uses recomputed root")
  eq(h.calls[2].argv[5], "wide", "focus gain uses recomputed profile")
  eq(cache:debug_state().root, "/repo/b", "focus gain replaces stale root")
  finish(h, 2, { stdout = "b\n" })
end

do
  local h = cache_harness()
  local cache = test.new_git_cache(h.deps)
  cache:update("/repo/a", "compact", "BufEnter")
  finish(h, 1, { stdout = "main\n" })

  local periodic = h.timer.callback
  periodic()
  eq(#h.calls, 2, "focused timer callback requests a refresh")
  finish(h, 2, { stdout = "main\n" })

  cache:set_focused(false)
  periodic()
  eq(#h.calls, 2, "unfocused periodic callback is suppressed")
end

do
  local h = cache_harness()
  local cache = test.new_git_cache(h.deps)
  cache:update("/repo/a", "compact", "BufEnter")
  finish(h, 1, { stdout = "visible\n" })
  cache:update("/repo/a", "compact", "BufWritePost")
  cache:update("/repo/b", "wide", "BufEnter")
  cache:update(nil, nil, "BufEnter")

  eq(cache:get(), "", "nil root clears the visible summary")
  eq(cache:debug_state().root, nil, "nil root replaces the active root")
  eq(cache:debug_state().profile, nil, "nil root clears the active profile")
  finish(h, 2, { stdout = "late\n" })
  eq(#h.calls, 2, "nil root discards pending work")
  eq(cache:get(), "", "nil root rejects the late child result")
end

do
  local h = cache_harness()
  local cache = test.new_git_cache(h.deps)
  cache:update("/repo/a", "compact", "BufEnter")
  finish(h, 1, { stdout = "crlf\r\n" })
  eq(cache:get(), "crlf", "one trailing CRLF is normalized")
  cache:update("/repo/a", "compact", "BufWritePost")
  finish(h, 2, { stdout = "lf\n" })
  eq(cache:get(), "lf", "one trailing LF is normalized")
end

do
  local h = cache_harness()
  local cache = test.new_git_cache(h.deps)
  cache:update("/repo/a", "compact", "BufEnter")
  finish(h, 1, { stdout = string.rep("界", 100) .. "\n" })
  local summary = cache:get()
  eq(#summary, 255, "Git output obeys the 256-byte UTF-8 cap")
  assert(pcall(vim.str_utfindex, summary), "Git output cap split a UTF-8 character")
end

do
  local h = cache_harness()
  local cache = test.new_git_cache(h.deps)
  local late_timer = h.timer.callback
  cache:stop()
  local before = cache:debug_state()
  late_timer()
  eq(#h.calls, 0, "late timer callback starts no child")
  eq(cache:debug_state(), before, "late timer callback cannot mutate stopped state")
end

do
  local h = cache_harness()
  local cache = test.new_git_cache(h.deps)
  cache:update("/repo/a", "compact", "BufEnter")
  local snapshot = cache:debug_state()
  snapshot.root = "/mutated"
  snapshot.generation = 999
  snapshot.has_in_flight = false
  local current = cache:debug_state()
  eq(current.root, "/repo/a", "debug state root is isolated")
  eq(current.generation, 1, "debug state generation is isolated")
  eq(current.has_in_flight, true, "debug state flight flag is isolated")
  cache:stop()
end

print("statusline async Git cache: ok")

local tmux_status = require("integrations.tmux_status")
local bridge_test = tmux_status._test

local bridge_option_names = {
  "@dotfiles_nvim_mode",
  "@dotfiles_nvim_root",
  "@dotfiles_nvim_path",
  "@dotfiles_nvim_modified",
  "@dotfiles_nvim_errors",
  "@dotfiles_nvim_warnings",
  "@dotfiles_nvim_line",
  "@dotfiles_nvim_column",
}

local function publisher_harness()
  local calls, deferred, notices, timers, availability = {}, {}, {}, {}, {}
  local deps = {
    pane = "%12",
    origin = { socket = "/private/tmux.sock", pid = "99", session = "$0", pane = "%12" },
    owner = "101_202",
    on_available = function(value)
      table.insert(availability, value)
    end,
    new_timer = function()
      local timer = { closed = false, active = false }
      function timer:start(delay, interval, callback)
        self.delay, self.interval, self.callback, self.active = delay, interval, callback, true
      end
      function timer:stop()
        assert(not self.closed, "timer stopped after close")
        self.active = false
      end
      function timer:is_closing()
        return self.closed
      end
      function timer:close()
        self.closed, self.active = true, false
      end
      function timer:fire()
        if self.active then
          self.callback()
        end
      end
      table.insert(timers, timer)
      return timer
    end,
    warn_level = "warn",
    schedule = function(callback)
      callback()
    end,
    defer = function(callback, milliseconds)
      table.insert(deferred, { callback = callback, milliseconds = milliseconds })
    end,
    notify = function(message, level)
      table.insert(notices, { message = message, level = level })
    end,
    system = function(argv, options, callback)
      local call = {
        argv = vim.deepcopy(argv),
        options = vim.deepcopy(options),
        callback = callback,
        killed = false,
        waited = false,
      }
      function call:kill(signal)
        self.killed = signal
      end
      function call:wait(milliseconds)
        self.waited = milliseconds
        return self.wait_result or { code = 0, signal = 0, stdout = "", stderr = "" }
      end
      table.insert(calls, call)
      return call
    end,
  }
  return {
    deps = deps,
    calls = calls,
    deferred = deferred,
    notices = notices,
    timers = timers,
    availability = availability,
  }
end

local function bridge_snapshot(path, line)
  return {
    mode = "INSERT",
    root = "/repo",
    path = path or "lua/init.lua",
    errors = 2,
    warnings = 3,
    line = line or 7,
    column = 11,
  }
end

local function bridge_finish(harness, index, result)
  harness.calls[index].callback(vim.tbl_extend("force", {
    code = 0,
    signal = 0,
    stdout = "",
    stderr = "",
  }, result or {}))
end

local function option_value(argv, name)
  for index, value in ipairs(argv) do
    if value == name then
      return argv[index + 1]
    end
  end
  error("option is absent from argv: " .. name)
end

local function assert_control_free(value, label)
  assert(not value:find("[%z\1-\31\127]"), label .. " retained a C0 or DEL control")
  assert(not value:find("\194[\128-\159]"), label .. " retained a C1 control")
end

for _, pane in ipairs({ "%0", "%1", "%123" }) do
  eq(bridge_test.valid_pane(pane), true, "valid pane " .. pane)
end
for _, pane in ipairs({
  "",
  "1",
  "%",
  "%1x",
  "%1;display-message",
  "%1\n",
  "% 1",
  "#{pane_id}",
  "#(id)",
}) do
  eq(bridge_test.valid_pane(pane), false, "invalid pane " .. vim.inspect(pane))
end

eq(bridge_test.tmux_quote("a'b"), [['a'\''b']], "tmux single-quote encoding")
eq(
  bridge_test.tmux_quote([[a; $HOME ${HOME} # " \]]),
  [['a; $HOME ${HOME} # " \']],
  "tmux syntax-shaped value quoting"
)
eq(bridge_test.decimal(0 / 0, 1), "1", "NaN rejected")
eq(bridge_test.decimal(math.huge, 0), "0", "infinity rejected")
eq(bridge_test.decimal(1e50, 0), "999999999", "huge number clamped")

local c1_first_bridge = vim.fn.nr2char(0x80)
local c1_csi_bridge = vim.fn.nr2char(0x9b)
local c1_last_bridge = vim.fn.nr2char(0x9f)
local canonical = bridge_test.canonicalize({
  mode = "raw-mode",
  root = "relative/repo\n",
  path = "a\n\27\0" .. c1_first_bridge .. "#[fg=red]#(id)" .. c1_last_bridge .. string.rep(
    "界",
    300
  ),
  errors = -4,
  warnings = math.huge,
  line = 0 / 0,
  column = 1e50,
})
eq(canonical.mode, "NORMAL", "unknown mode fallback")
eq(canonical.root, "", "unsafe root cleared")
assert_control_free(canonical.path, "published path")
assert(#canonical.path <= 512, "published path exceeds byte cap")
assert(pcall(vim.str_utfindex, canonical.path), "published path split a UTF-8 character")
eq(canonical.errors, "0", "negative diagnostic clamped")
eq(canonical.warnings, "0", "infinite diagnostic rejected")
eq(canonical.line, "1", "invalid line fallback")
eq(canonical.column, "999999999", "column upper clamp")
eq(canonical.modified, "0", "missing modified state defaults to clean")
for _, value in ipairs({ true, false, 1, "1", "true" }) do
  eq(
    bridge_test.canonicalize({ modified = value }).modified,
    value == true and "1" or "0",
    "bridge publishes only strict boolean modified state"
  )
end
eq(bridge_test.canonicalize({ root = "/repo/" .. c1_csi_bridge }).root, "", "C1 root is rejected")

local combining_bridge = vim.fn.nr2char(0x301)
local grapheme_capped = bridge_test.canonicalize({
  path = string.rep("a", 508) .. "界" .. combining_bridge,
}).path
eq(grapheme_capped, string.rep("a", 508), "byte cap preserves a combining sequence")
assert(pcall(vim.str_utfindex, grapheme_capped), "combining cap split UTF-8")

local function flush_bridge(h)
  for index = #h.deferred, 1, -1 do
    if h.deferred[index].milliseconds == 75 then
      h.deferred[index].callback()
      return
    end
  end
  error("missing publication debounce")
end
local function complete_bridge(h, result)
  local call = h.calls[#h.calls]
  local stdout = call.argv[5] == "list-panes" and "99\t$0\t%12\t1\ton\n"
    or "dotfiles-nvim-status:101_202\n"
  bridge_finish(h, #h.calls, vim.tbl_extend("force", { stdout = stdout }, result or {}))
end
local function ready_bridge(h, publisher)
  publisher:start(bridge_snapshot())
  flush_bridge(h)
  eq(h.calls[#h.calls].argv[5], "list-panes", "first publication probes the origin")
  complete_bridge(h)
  eq(h.calls[#h.calls].argv[5], "if-shell", "configured capability permits a guarded claim")
  complete_bridge(h)
  eq(h.availability[#h.availability], true, "only the exact claim acknowledgment enables handoff")
end

for _, output in ipairs({
  "",
  "99\t$0\t%12\t0\ton\n",
  "99\t$0\t%12\t1\toff\n",
  "98\t$0\t%12\t1\ton\n",
}) do
  local h = publisher_harness()
  local publisher = bridge_test.new(h.deps)
  publisher:start(bridge_snapshot())
  flush_bridge(h)
  eq(h.calls[1].argv[5], "list-panes", "ordinary tmux is probed before any write")
  complete_bridge(h, { stdout = output })
  eq(#h.calls, 1, "unavailable tmux never receives a claim or cleanup write")
  assert(h.availability[#h.availability] ~= true, "unavailable capability hid native status")
  publisher:stop()
  eq(#h.calls, 1, "unavailable shutdown does not write pane options")
end

for _, result in ipairs({
  { stdout = "" },
  { stdout = "unexpected\n" },
  { stdout = "dotfiles-nvim-status:other\n" },
  { stdout = "dotfiles-nvim-status:101_202\n", signal = 9 },
}) do
  local h = publisher_harness()
  local publisher = bridge_test.new(h.deps)
  publisher:start(bridge_snapshot())
  flush_bridge(h)
  complete_bridge(h)
  complete_bridge(h, result)
  assert(h.availability[#h.availability] ~= true, "exit zero without exact ack hid the native row")
  eq(publisher:debug_state().published, nil, "unacknowledged publication never advances dedup")
  publisher:stop()
end

do
  local h = publisher_harness()
  local publisher = bridge_test.new(h.deps)
  ready_bridge(h, publisher)
  local snapshot = bridge_snapshot()
  local count = #h.calls
  for _, modified in ipairs({ true, false }) do
    snapshot.modified = modified
    publisher:request(snapshot)
    flush_bridge(h)
    count = count + 1
    eq(#h.calls, count, "modified-only transition publishes")
    complete_bridge(h)
    eq(
      publisher:debug_state().published.modified,
      modified and "1" or "0",
      "modified state acknowledged"
    )
    publisher:request(snapshot)
    flush_bridge(h)
    eq(#h.calls, count, "unchanged modified state deduplicates")
  end
  publisher:stop()
  contains(
    table.concat(h.calls[#h.calls].argv, " "),
    "@dotfiles_nvim_modified",
    "cleanup owns modified option"
  )
end

do
  local h = publisher_harness()
  local publisher = bridge_test.new(h.deps)
  ready_bridge(h, publisher)
  local count = #h.calls
  publisher:request(bridge_snapshot())
  flush_bridge(h)
  eq(#h.calls, count, "acknowledged snapshot deduplicated")
  publisher:request(bridge_snapshot("running", 2))
  flush_bridge(h)
  publisher:request(bridge_snapshot("older", 3))
  flush_bridge(h)
  publisher:request(bridge_snapshot("newest", 4))
  flush_bridge(h)
  eq(#h.calls, count + 1, "one publication in flight")
  complete_bridge(h)
  eq(#h.calls, count + 2, "only newest pending snapshot follows completion")
  contains(table.concat(h.calls[#h.calls].argv, " "), "newest", "latest state wins")
  complete_bridge(h)
  publisher:stop()
end

do
  local h = publisher_harness()
  local publisher = bridge_test.new(h.deps)
  ready_bridge(h, publisher)
  publisher:request(bridge_snapshot("changed", 2))
  flush_bridge(h)
  complete_bridge(h, { stdout = "dotfiles-nvim-owner-mismatch\n" })
  eq(h.availability[#h.availability], false, "replacement owner restores native status")
  local count = #h.calls
  publisher:refresh()
  publisher:request(bridge_snapshot("ignored", 3))
  flush_bridge(h)
  eq(#h.calls, count, "replacement owner cannot trigger automatic reclaim")
  publisher:stop()
end

do
  local h = publisher_harness()
  local publisher = bridge_test.new(h.deps)
  ready_bridge(h, publisher)
  publisher:request(bridge_snapshot("before-focus", 2))
  flush_bridge(h)
  publisher:set_focused(false)
  publisher:set_focused(true)
  complete_bridge(h)
  eq(
    h.availability[#h.availability],
    false,
    "old in-flight success cannot bypass focus revalidation"
  )
  eq(h.calls[#h.calls].argv[5], "list-panes", "focus revalidation follows the old child")
  complete_bridge(h)
  complete_bridge(h)
  eq(h.availability[#h.availability], true, "fresh acknowledgment restores handoff")
  publisher:stop()
end

do
  local h = publisher_harness()
  local publisher = bridge_test.new(h.deps)
  ready_bridge(h, publisher)
  publisher:set_focused(true)
  eq(
    h.availability[#h.availability],
    false,
    "focus gain without prior loss still withdraws native handoff"
  )
  eq(h.calls[#h.calls].argv[5], "list-panes", "repeated focus gain revalidates immediately")
  publisher:stop()
end

do
  local h = publisher_harness()
  local publisher = bridge_test.new(h.deps)
  ready_bridge(h, publisher)
  publisher:set_focused(false)
  eq(h.timers[1].active, false, "focus loss pauses capability polling")
  publisher:set_focused(true)
  eq(h.availability[#h.availability], false, "focus gain restores native while revalidating")
  eq(h.calls[#h.calls].argv[5], "list-panes", "focus gain probes immediately")
  complete_bridge(h, { stdout = "99\t$0\t%12\t1\toff\n" })
  if h.calls[#h.calls].argv[5] == "if-shell" then
    complete_bridge(h, { stdout = "" })
  end
  eq(h.availability[#h.availability], false, "status disabled retains native ownership")
  publisher:refresh()
  complete_bridge(h)
  complete_bridge(h)
  eq(h.availability[#h.availability], true, "capability recovery allows acknowledged handoff")
  publisher:stop()
end

do
  local h = publisher_harness()
  local publisher = bridge_test.new(h.deps)
  ready_bridge(h, publisher)
  publisher:request(bridge_snapshot("hung", 2))
  flush_bridge(h)
  local call = h.calls[#h.calls]
  local deadline = h.timers[#h.timers]
  eq(deadline.delay, 1000, "publication deadline")
  deadline:fire()
  eq(h.availability[#h.availability], false, "deadline falls back without an exit callback")
  eq(call.killed, 9, "deadline force-terminates the owned client")
  local count = #h.calls
  publisher:refresh()
  eq(#h.calls, count, "deadline retains occupied slot until reap")
  call.callback({ code = 0, signal = 0, stdout = "dotfiles-nvim-status:101_202\n", stderr = "" })
  eq(h.availability[#h.availability], false, "late timed-out success cannot reclaim native row")
  publisher:stop()
  for _, timer in ipairs(h.timers) do
    assert(timer.closed, "shutdown leaked a timer")
  end
end

do
  local h = publisher_harness()
  local publisher = bridge_test.new(h.deps)
  publisher:start(bridge_snapshot())
  flush_bridge(h)
  complete_bridge(h)
  local first = h.calls[#h.calls]
  complete_bridge(h, { code = 1, stderr = "failed" })
  if h.calls[#h.calls] ~= first then
    complete_bridge(h, { stdout = "" })
  end
  publisher:refresh()
  complete_bridge(h)
  local retry = table.concat(h.calls[#h.calls].argv, " ")
  contains(retry, "@dotfiles_nvim_owner", "uncertain claim retry retains owner validation")
  contains(retry, "dotfiles-nvim-owner-mismatch", "uncertain retry refuses another owner")
  publisher:stop()
  local count = #h.calls
  first.callback({ code = 0, signal = 0, stdout = "dotfiles-nvim-status:101_202\n" })
  publisher:refresh()
  publisher:request(bridge_snapshot())
  eq(#h.calls, count, "stopped callbacks and requests are inert")
end

do
  local h = publisher_harness()
  local publisher = bridge_test.new(h.deps)
  ready_bridge(h, publisher)
  local hostile = bridge_snapshot([[a; ' " $HOME #{session_name} #(id)\tail;]], 2)
  publisher:request(hostile)
  flush_bridge(h)
  local argv = h.calls[#h.calls].argv
  eq(argv[4], "/private/tmux.sock", "publisher targets explicit socket")
  eq(argv[8], "$0:%12", "publisher targets originating session and pane")
  local commands = table.concat(argv, "\0")
  contains(commands, "$HOME #{session_name} #(id)", "hostile expansion syntax remains command data")
  contains(commands, "#{pid}", "write rechecks server identity")
  contains(commands, "#{session_id}", "write rechecks originating session")
  contains(commands, "#{@dotfiles_foundation_loaded}", "write rechecks configured marker")
  contains(commands, "#{status}", "write rechecks effective status")
  assert(not commands:find("refresh-client", 1, true), "publication forced a status refresh")
  publisher:stop()
end

print("statusline tmux publisher: ok")

local function ownership_harness(options)
  options = options or {}
  local state = {
    options = {},
    option_writes = {},
    augroup_calls = 0,
    autocmds = {},
    scheduled = {},
    queue_scheduled = options.queue_scheduled == true,
    highlight_calls = 0,
    install_calls = 0,
    clear_calls = 0,
    redraws = 0,
    live_reads = 0,
    width_reads = 0,
    executable_calls = 0,
    cache_factory_calls = 0,
    publisher_setup_calls = 0,
    log = {},
    live = {
      mode = "NORMAL",
      root = "/repo/a",
      path = "lua/a.lua",
      errors = 0,
      warnings = 0,
      line = 4,
      column = 2,
      width = 80,
    },
  }

  local cache = { summary = "", updates = {}, focuses = {}, stop_calls = 0 }
  function cache:update(root, profile, reason)
    table.insert(self.updates, { root = root, profile = profile, reason = reason })
  end
  function cache:set_focused(focused, context)
    table.insert(self.focuses, {
      focused = focused,
      context = context and vim.deepcopy(context) or nil,
    })
  end
  function cache:get()
    return self.summary
  end
  function cache:stop()
    self.stop_calls = self.stop_calls + 1
    table.insert(state.log, "cache.stop")
  end

  local publisher = { setup_snapshots = {}, requests = {}, stop_calls = 0 }
  function publisher:request(snapshot)
    table.insert(self.requests, vim.deepcopy(snapshot))
  end
  function publisher:refresh()
    self.refreshes = (self.refreshes or 0) + 1
  end
  function publisher:set_focused(value)
    self.focused = value
  end
  function publisher:stop()
    self.stop_calls = self.stop_calls + 1
    table.insert(state.log, "publisher.stop")
  end

  local deps = {
    inside_tmux = options.inside_tmux == true,
    pane = options.pane or "",
    executable = function(name)
      state.executable_calls = state.executable_calls + 1
      eq(name, "tmux", "ownership executable name")
      return options.tmux_executable == false and 0 or 1
    end,
    width = function()
      state.width_reads = state.width_reads + 1
      return state.live.width
    end,
    live_snapshot = function()
      state.live_reads = state.live_reads + 1
      return vim.deepcopy(state.live)
    end,
    schedule = function(callback)
      if state.queue_scheduled then
        table.insert(state.scheduled, callback)
      else
        callback()
      end
    end,
    set_option = function(name, value)
      state.options[name] = value
      table.insert(state.option_writes, { name = name, value = value })
    end,
    apply_highlights = function()
      state.highlight_calls = state.highlight_calls + 1
    end,
    redraw = function()
      state.redraws = state.redraws + 1
    end,
    create_augroup = function(name, augroup_options)
      state.augroup_calls = state.augroup_calls + 1
      eq(name, "dotfiles-statusline", "owned augroup name")
      eq(augroup_options, { clear = true }, "owned augroup options")
      return 73
    end,
    create_autocmd = function(events, autocmd_options)
      table.insert(state.autocmds, { events = events, options = autocmd_options })
    end,
    install_render = function()
      state.install_calls = state.install_calls + 1
      state.options.statusline = "%!v:lua.dotfiles_statusline()"
      table.insert(state.log, "install_render")
    end,
    clear_render = function()
      state.clear_calls = state.clear_calls + 1
      if state.options.statusline == "%!v:lua.dotfiles_statusline()" then
        state.options.statusline = ""
      end
      table.insert(state.log, "clear_render")
    end,
    make_git_cache = function()
      state.cache_factory_calls = state.cache_factory_calls + 1
      return cache
    end,
    publisher_setup = function(publisher_options)
      state.publisher_setup_calls = state.publisher_setup_calls + 1
      publisher.on_available = publisher_options.on_available
      table.insert(publisher.setup_snapshots, vim.deepcopy(publisher_options.snapshot))
      eq(publisher_options.pane, options.pane, "publisher pane")
      return publisher
    end,
  }

  local function includes(events, event)
    if type(events) == "string" then
      return events == event
    end
    for _, candidate in ipairs(events) do
      if candidate == event then
        return true
      end
    end
    return false
  end

  function state.fire(event)
    for _, autocmd in ipairs(state.autocmds) do
      if includes(autocmd.events, event) then
        autocmd.options.callback({ event = event })
      end
    end
  end

  function state.run_scheduled()
    while #state.scheduled > 0 do
      table.remove(state.scheduled, 1)()
    end
  end

  state.deps = deps
  state.cache = cache
  state.publisher = publisher
  return state
end

local function with_runtime(harness, callback)
  statusline.shutdown()
  local ok, failure = xpcall(function()
    callback(statusline.setup(harness.deps))
  end, debug.traceback)
  statusline.shutdown()
  assert(ok, failure)
end

do
  local h = ownership_harness()
  with_runtime(h, function(controller)
    eq(h.options.laststatus, 3, "outside tmux owns native row")
    eq(h.options.cmdheight, 0, "outside tmux cmdheight")
    eq(h.options.showmode, false, "outside tmux showmode")
    eq(h.install_calls, 1, "outside tmux installs expression")
    eq(h.cache_factory_calls, 1, "outside tmux creates one cache")
    eq(h.publisher_setup_calls, 0, "outside tmux has no publisher")
    eq(controller:snapshot().modified, false, "runtime defaults to clean state")
    h.live.modified = "1"
    h.fire("BufModifiedSet")
    eq(controller:snapshot().modified, false, "runtime rejects truthy nonboolean modified state")
    eq(controller:snapshot().width, 80, "public snapshot reads initial live width")
    h.live.width = 120
    eq(controller:snapshot().width, 120, "public snapshot does not cache width")
  end)
  eq(h.options.statusline, "", "outside shutdown clears owned expression")
end

do
  local h = ownership_harness({ inside_tmux = true, pane = "%12" })
  with_runtime(h, function(controller)
    eq(h.options.laststatus, 3, "tmux starts with a native row until acknowledgment")
    eq(h.install_calls, 1, "tmux retains a native renderer for fallback")
    eq(h.publisher_setup_calls, 1, "valid pane starts capability discovery")
    assert(type(h.publisher.on_available) == "function", "publisher ownership callback missing")
    h.publisher.on_available(true)
    eq(h.options.laststatus, 0, "acknowledged remote ownership hides native row")
    eq(h.cache.stop_calls, 1, "remote ownership stops native Git polling")
    h.publisher.on_available(false)
    eq(h.options.laststatus, 3, "lost remote ownership restores native row")
    controller:set_startup_visible(true)
    h.live.modified = true
    h.fire("BufModifiedSet")
    eq(controller:snapshot().modified, true, "modified state reaches the public snapshot")
    eq(
      h.publisher.requests[#h.publisher.requests].modified,
      true,
      "modified state reaches the publisher"
    )
    h.publisher.on_available(true)
    h.publisher.on_available(false)
    eq(h.options.laststatus, 0, "handoff cannot reveal a starter status row")
    controller:set_startup_visible(false)
    eq(h.options.laststatus, 3, "native row returns after starter")
  end)
end

do
  local h = ownership_harness()
  with_runtime(h, function(controller)
    eq(controller:debug_state().startup_visible, false, "startup initially hidden")
    eq(controller:set_startup_visible(true), true, "controller accepts startup visibility")
    eq(h.options.laststatus, 0, "standalone starter suppresses status row")
    local writes = #h.option_writes
    eq(controller:set_startup_visible(true), true, "repeated startup visibility succeeds")
    eq(#h.option_writes, writes, "repeated startup visibility is idempotent")
    eq(controller:set_startup_visible(false), true, "controller restores normal visibility")
    eq(h.options.laststatus, 3, "standalone status row restored")
    eq(controller:debug_state().startup_visible, false, "debug state reports restoration")
  end)
end

do
  local h = ownership_harness({ inside_tmux = true, pane = "%12" })
  with_runtime(h, function(controller)
    h.publisher.on_available(true)
    controller:set_startup_visible(true)
    eq(h.options.laststatus, 0, "tmux starter keeps native row hidden")
    controller:set_startup_visible(false)
    eq(h.options.laststatus, 0, "tmux restoration cannot create a native row")
  end)
end

for _, case in ipairs({
  { label = "invalid pane", pane = "invalid-pane", executable = true },
  { label = "missing tmux", pane = "%12", executable = false },
}) do
  local h = ownership_harness({
    inside_tmux = true,
    pane = case.pane,
    tmux_executable = case.executable,
  })
  with_runtime(h, function()
    eq(h.options.laststatus, 3, case.label .. " retains native ownership")
    eq(h.install_calls, 1, case.label .. " installs native row")
    eq(h.cache_factory_calls, 1, case.label .. " retains native Git cache")
    eq(h.publisher_setup_calls, 0, case.label .. " starts no process")
    eq(
      h.executable_calls,
      case.label == "invalid pane" and 0 or 1,
      case.label .. " executable validation count"
    )
  end)
end

do
  statusline.shutdown()
  local h = ownership_harness()
  local first = statusline.setup(h.deps)
  local second = statusline.setup(h.deps)
  assert(first == second, "setup did not return the existing controller")
  eq(h.augroup_calls, 1, "outside setup creates one augroup")
  eq(#h.autocmds, 8, "outside setup creates the exact event routes")
  eq(h.cache_factory_calls, 1, "outside setup creates one timer/cache")
  h.options.statusline = "%!v:lua.user_statusline()"
  statusline.shutdown()
  statusline.shutdown()
  eq(h.cache.stop_calls, 1, "shutdown stops cache once")
  eq(h.clear_calls, 1, "shutdown clears render callback once")
  eq(
    h.options.statusline,
    "%!v:lua.user_statusline()",
    "shutdown preserves a replacement statusline"
  )

  local restarted = statusline.setup(h.deps)
  assert(restarted ~= first, "setup after shutdown reused a stopped controller")
  eq(h.augroup_calls, 2, "setup after shutdown recreates the owned augroup")
  eq(h.cache_factory_calls, 2, "setup after shutdown creates a fresh cache")
  statusline.shutdown()
  eq(h.cache.stop_calls, 2, "restarted cache stops exactly once")
end

do
  statusline.shutdown()
  local h = ownership_harness({ inside_tmux = true, pane = "%12" })
  local first = statusline.setup(h.deps)
  local second = statusline.setup(h.deps)
  assert(first == second, "tmux setup did not return existing controller")
  eq(h.augroup_calls, 1, "tmux setup creates one augroup")
  eq(#h.autocmds, 8, "tmux setup creates the exact event routes")
  eq(h.publisher_setup_calls, 1, "tmux setup creates one publisher")
  statusline.shutdown()
  statusline.shutdown()
  eq(h.publisher.stop_calls, 1, "shutdown stops publisher once")
end

do
  local h = ownership_harness({ inside_tmux = true, pane = "%12" })
  with_runtime(h, function(controller)
    h.publisher.on_available(true)
    h.fire("FocusLost")
    eq(h.publisher.focused, false, "focus loss pauses publisher")
    h.fire("FocusGained")
    eq(h.publisher.focused, true, "focus gain revalidates publisher")
    controller:refresh()
    eq(h.publisher.refreshes, 1, "manual refresh rechecks capability")
    h.fire("VimSuspend")
    eq(h.publisher.stop_calls, 1, "suspend withdraws publication")
    eq(h.options.laststatus, 3, "suspend returns native ownership")
    h.fire("VimResume")
    eq(h.publisher_setup_calls, 2, "resume starts a fresh publisher")
    eq(h.options.laststatus, 3, "resume awaits new acknowledgment")
  end)
end

statusline.shutdown()
eq(statusline.set_startup_visible(true), false, "missing runtime rejects startup visibility")
local public_harness = ownership_harness()
statusline.setup(public_harness.deps)
eq(statusline.set_startup_visible(true), true, "public startup visibility dispatch")
eq(public_harness.options.laststatus, 0, "public startup suppression")
statusline.shutdown()
eq(statusline.set_startup_visible(false), false, "stopped runtime rejects startup visibility")

do
  local h = ownership_harness()
  with_runtime(h, function(controller)
    h.cache.updates = {}
    h.redraws = 0
    local reads = h.live_reads
    for _, event in ipairs({
      "BufModifiedSet",
      "ModeChanged",
      "CursorMoved",
      "CursorMovedI",
      "DiagnosticChanged",
    }) do
      h.fire(event)
    end
    eq(#h.cache.updates, 0, "semantic events never invalidate Git")
    eq(h.live_reads, reads + 5, "semantic events rebuild snapshots")
    eq(h.redraws, 5, "semantic events redraw")

    h.cache.updates = {}
    for _, event in ipairs({
      "VimEnter",
      "BufEnter",
      "WinEnter",
      "BufFilePost",
      "DirChanged",
      "BufWritePost",
    }) do
      h.fire(event)
      local update = h.cache.updates[#h.cache.updates]
      eq(update.reason, event, event .. " Git reason")
      eq(update.root, "/repo/a", event .. " refreshes unchanged root")
      eq(update.profile, "compact", event .. " profile")
    end
    eq(#h.cache.updates, 6, "all Git events request refresh")

    h.cache.updates = {}
    controller:refresh("UnexpectedEvent")
    eq(#h.cache.updates, 0, "unknown events never invalidate Git")

    local highlight_calls = h.highlight_calls
    local redraws = h.redraws
    h.fire("ColorScheme")
    eq(h.highlight_calls, highlight_calls + 1, "ColorScheme reapplies highlights")
    eq(h.redraws, redraws + 1, "ColorScheme redraws the statusline")

    h.cache.focuses = {}
    h.fire("FocusLost")
    eq(h.cache.focuses[1].focused, false, "FocusLost pauses cache")
    h.live.root = "/repo/b"
    h.live.path = "lua/b.lua"
    h.live.width = 100
    h.fire("FocusGained")
    eq(h.cache.focuses[2].focused, true, "FocusGained resumes cache")
    eq(h.cache.focuses[2].context, {
      root = "/repo/b",
      profile = "medium",
    }, "FocusGained uses recomputed context")

    h.cache.updates = {}
    h.live.width = 119
    h.fire("VimResized")
    eq(#h.cache.updates, 0, "same-tier resize does not refresh Git")
    h.live.width = 120
    h.fire("WinResized")
    eq(#h.cache.updates, 1, "tier transition refreshes Git")
    eq(h.cache.updates[1].profile, "wide", "resize selects wide profile")

    h.live.path = "a/very/long/path/to/statusline.lua"
    h.fire("ModeChanged")
    h.live.width = 80
    local at_80 = statusline.render()
    h.live.width = 120
    local at_120 = statusline.render()
    assert(at_80 ~= at_120, "render reused cached window width")
  end)
end

do
  local h = ownership_harness({ inside_tmux = true, pane = "%12" })
  with_runtime(h, function()
    h.publisher.requests = {}
    h.redraws = 0
    for _, event in ipairs({
      "BufModifiedSet",
      "ModeChanged",
      "CursorMoved",
      "CursorMovedI",
      "DiagnosticChanged",
    }) do
      h.fire(event)
    end
    eq(#h.publisher.requests, 5, "semantic events publish snapshots")
    eq(h.redraws, 5, "published semantic events redraw")
  end)
end

local function log_index(log, expected)
  for index, value in ipairs(log) do
    if value == expected then
      return index
    end
  end
  return nil
end

do
  local h = ownership_harness()
  with_runtime(h, function()
    h.fire("VimLeavePre")
    assert(
      log_index(h.log, "cache.stop") < log_index(h.log, "clear_render"),
      "cache stopped after render callback deletion"
    )
  end)
end

do
  local h = ownership_harness({ inside_tmux = true, pane = "%12" })
  with_runtime(h, function()
    h.fire("VimLeavePre")
    assert(
      log_index(h.log, "publisher.stop") < log_index(h.log, "clear_render"),
      "publisher stopped after render callback deletion"
    )
  end)
end

do
  statusline.shutdown()
  local h = ownership_harness({ queue_scheduled = true })
  statusline.setup(h.deps)
  h.fire("ModeChanged")
  eq(#h.scheduled, 1, "event queues scheduled refresh")
  local reads = h.live_reads
  statusline.shutdown()
  h.run_scheduled()
  eq(h.live_reads, reads, "late callback mutated stopped state")
  eq(h.cache.stop_calls, 1, "late callback restarted stopped cache")
  eq(h.clear_calls, 1, "late callback repeated cleanup")
  statusline.shutdown()
end

do
  local original_cwd = vim.fn.getcwd()
  local temporary = vim.fn.tempname()
  assert(vim.fn.mkdir(temporary, "p") == 1, "statusline tempdir")
  vim.api.nvim_set_current_dir(temporary)
  local ok, failure = xpcall(function()
    test.apply_highlights()
    local rendered = test.render_parts({
      mode = "INSERT",
      root = "/repo",
      path = "#[fg=red] #(touch x)",
      errors = 0,
      warnings = 0,
      line = 7,
      column = 3,
      width = 120,
    }, "100% %#ErrorMsg# #{session_name}\n\27\t 界")
    contains(rendered.expression, "100%% %%#ErrorMsg#", "percent escaping")

    local evaluated = vim.api.nvim_eval_statusline(rendered.expression, {
      maxwidth = 120,
      highlights = true,
    })
    contains(evaluated.str, "100% %#ErrorMsg# #{session_name} 界", "literal hostile Git text")
    contains(evaluated.str, "#[fg=red] #(touch x)", "literal hostile path")
    eq(vim.uv.fs_stat(vim.fs.joinpath(temporary, "x")), nil, "statusline executed injected command")
    eq(evaluated.width, vim.fn.strdisplaywidth(evaluated.str), "evaluated display width")
    for _, highlight in ipairs(evaluated.highlights or {}) do
      for _, group in ipairs(highlight.groups or { highlight.group }) do
        assert(group ~= "ErrorMsg", "external text injected a highlight")
      end
    end
  end, debug.traceback)
  vim.api.nvim_set_current_dir(original_cwd)
  vim.fn.delete(temporary, "rf")
  assert(ok, failure)
end

do
  local window = vim.api.nvim_get_current_win()
  local original_buffer = vim.api.nvim_get_current_buf()
  local buffer = vim.api.nvim_create_buf(false, false)
  local path = vim.fn.tempname() .. ".lua"
  local ok, failure = xpcall(function()
    vim.api.nvim_win_set_buf(window, buffer)
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "\t界x" })
    vim.bo[buffer].buftype = ""
    vim.bo[buffer].tabstop = 4
    vim.api.nvim_win_set_cursor(window, { 1, 4 })
    local snapshot = test.live_snapshot()
    eq(snapshot.column, 7, "snapshot uses visual cursor column")
    assert(snapshot.column ~= 5, "snapshot used one-based byte column")
    eq(snapshot.modified, true, "editing marks the live snapshot modified")
    vim.cmd("silent write " .. vim.fn.fnameescape(path))
    eq(test.live_snapshot().modified, false, "saving clears the live modified state")
  end, debug.traceback)
  vim.api.nvim_win_set_buf(window, original_buffer)
  if vim.api.nvim_buf_is_valid(buffer) then
    vim.api.nvim_buf_delete(buffer, { force = true })
  end
  vim.fn.delete(path)
  assert(ok, failure)
end

do
  statusline.shutdown()
  local saved_system, saved_root = vim.system, vim.env.DOTFILES_NVIM_ROOT
  local root = vim.fn.tempname() .. "-standalone"
  vim.fn.mkdir(root, "p")
  vim.env.DOTFILES_NVIM_ROOT = root
  local calls = 0
  vim.system = function(...)
    calls = calls + 1
    return saved_system(...)
  end
  local controller = statusline.setup({ inside_tmux = false })
  eq(controller:debug_state().has_cache, false, "absent optional helper creates no Git cache")
  eq(vim.o.laststatus, 3, "standalone retains native row without rich Git")
  assert(controller:render() ~= "", "standalone native renderer remains usable")
  eq(calls, 0, "absent helper launches no doomed subprocess")
  statusline.shutdown()
  vim.system, vim.env.DOTFILES_NVIM_ROOT = saved_system, saved_root
  vim.fn.delete(root, "rf")
end

local final_exports = vim.tbl_keys(test)
table.sort(final_exports)
eq(final_exports, {
  "apply_highlights",
  "build_snapshot",
  "display_path",
  "escape_statusline",
  "live_snapshot",
  "make_renderer",
  "new_git_cache",
  "new_runtime",
  "normalize_mode",
  "profile_for_width",
  "render_parts",
  "sanitize",
  "saturate",
  "truncate_left",
}, "exact statusline test exports")

print("statusline ownership and event wiring: ok")

if vim.env.DOTFILES_STATUS_LIVE == "1" then
  local root = assert(vim.env.DOTFILES_STATUS_ROOT, "private status root required")
  local socket = vim.fs.joinpath(root, "s.sock")
  local previous =
    { tmux = vim.env.TMUX, pane = vim.env.TMUX_PANE, disabled = vim.g.dotfiles_tmux_integration }
  local publisher
  local function tmux(...)
    local argv = { "tmux", "-S", socket }
    vim.list_extend(argv, { ... })
    local result = vim
      .system(argv, { text = true, env = { TMUX = false, TMUX_PANE = false, SHELL = "/bin/sh" } })
      :wait(2000)
    assert(result.code == 0 and result.signal == 0, result.stderr)
    return (result.stdout:gsub("\n$", ""))
  end
  local function until_true(condition, label)
    assert(vim.wait(3000, condition, 10), label)
  end
  local ok, failure = xpcall(function()
    tmux("-f", "/dev/null", "new-session", "-d", "-s", "first")
    local pane = tmux("display-message", "-p", "-t", "first:", "#{pane_id}")
    local session = tmux("display-message", "-p", "-t", "first:", "#{session_id}")
    local pid = tmux("display-message", "-p", "-t", "first:", "#{pid}")
    tmux("new-session", "-d", "-s", "second")
    tmux("link-window", "-s", "first:0", "-t", "second:1")
    tmux("set-option", "-t", "second", "status", "off")
    vim.env.TMUX, vim.env.TMUX_PANE = socket .. "," .. pid .. "," .. session:sub(2), pane
    local remote = false
    publisher = assert(tmux_status.setup({
      snapshot = bridge_snapshot(),
      on_available = function(value)
        remote = value
      end,
    }))
    until_true(function()
      return not publisher:debug_state().in_flight and publisher:debug_state().desired ~= nil
    end, "generic discovery")
    vim.wait(150, function()
      return false
    end, 10)
    eq(remote, false, "generic real tmux remains native")
    eq(
      tmux("show-options", "-pqv", "-t", pane, "@dotfiles_nvim_owner"),
      "",
      "generic real tmux receives no owner"
    )
    tmux("set-option", "-g", "@dotfiles_foundation_loaded", "1")
    publisher:refresh()
    until_true(function()
      return remote
    end, "configured real tmux acknowledges originating session")
    local hostile =
      bridge_snapshot([[quote' " $HOME ${HOME} #{session_name} #(touch NEVER) \ tail;]], 17)
    publisher:request(hostile)
    until_true(function()
      return publisher:debug_state().published and publisher:debug_state().published.line == "17"
    end, "literal hostile publication")
    eq(
      tmux("show-options", "-pqv", "-t", pane, "@dotfiles_nvim_path"),
      hostile.path,
      "real tmux stores hostile path literally"
    )
    eq(vim.uv.fs_stat(vim.fs.joinpath(root, "NEVER")), nil, "hostile status value executes nothing")
    tmux("set-option", "-t", "first", "status", "off")
    publisher:refresh()
    until_true(function()
      return not remote
    end, "effective session status off restores native")
    until_true(function()
      return not publisher:debug_state().in_flight
    end, "withdrawal reaped")
    eq(
      tmux("show-options", "-pqv", "-t", pane, "@dotfiles_nvim_active"),
      "",
      "status off withdraws own options"
    )
    tmux("set-option", "-t", "first", "status", "on")
    publisher:refresh()
    until_true(function()
      return remote
    end, "effective session status recovery")
    tmux("set-option", "-g", "@dotfiles_foundation_loaded", "0")
    publisher:refresh()
    until_true(function()
      return not remote
    end, "marker loss restores native")
    until_true(function()
      return not publisher:debug_state().in_flight
    end, "marker cleanup reaped")
    tmux("set-option", "-g", "@dotfiles_foundation_loaded", "1")
    publisher:refresh()
    until_true(function()
      return remote
    end, "marker recovery acknowledges")
    tmux("set-option", "-pt", pane, "@dotfiles_nvim_owner", "replacement")
    publisher:request(bridge_snapshot("replaced", 18))
    until_true(function()
      return publisher:debug_state().blocked
    end, "owner replacement is detected")
    eq(remote, false, "owner replacement restores native")
    publisher:refresh()
    publisher:stop()
    publisher = nil
    eq(
      tmux("show-options", "-pqv", "-t", pane, "@dotfiles_nvim_owner"),
      "replacement",
      "old publisher leaves replacement owner intact"
    )
    local hang, hung_pid = false, nil
    local origin = assert(require("config.platform").tmux_origin(vim.env))
    publisher = bridge_test.new({
      origin = origin,
      owner = "303_404",
      schedule = vim.schedule,
      defer = vim.defer_fn,
      new_timer = function()
        return assert(vim.uv.new_timer())
      end,
      notify = function() end,
      warn_level = vim.log.levels.WARN,
      on_available = function(value)
        remote = value
      end,
      system = function(argv, options, callback)
        if hang then
          hang = false
          local handle = vim.system({
            "python3",
            "-c",
            "import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(60)",
          }, options, callback)
          hung_pid = handle.pid
          return handle
        end
        return vim.system(argv, options, callback)
      end,
    })
    remote = false
    publisher:start(bridge_snapshot())
    until_true(function()
      return remote
    end, "deadline fixture claims")
    hang = true
    publisher:request(bridge_snapshot("deadline", 19))
    until_true(function()
      return hung_pid ~= nil
    end, "owned slow client started")
    until_true(function()
      return not remote
    end, "real deadline restores native despite ignored graceful signal")
    until_true(function()
      return not publisher:debug_state().in_flight
    end, "force-killed client and cleanup reaped")
    assert(not vim.uv.kill(hung_pid, 0), "deadline left an owned process running")
    publisher:stop()
    publisher = nil
    vim.g.dotfiles_tmux_integration = false
    eq(
      tmux_status.setup({ snapshot = bridge_snapshot() }),
      nil,
      "explicit opt-out creates no publisher"
    )
  end, debug.traceback)
  if publisher then
    publisher:stop()
  end
  pcall(tmux, "kill-server")
  vim.env.TMUX, vim.env.TMUX_PANE, vim.g.dotfiles_tmux_integration =
    previous.tmux, previous.pane, previous.disabled
  assert(ok, failure)
  print("statusline private tmux integration: ok")
end
