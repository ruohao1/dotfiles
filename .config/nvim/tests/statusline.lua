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
    errors = 2,
    warnings = 3,
    line = 7,
    column = 11,
    width = 100,
  },
  "canonical named-buffer snapshot"
)

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
  "@dotfiles_nvim_errors",
  "@dotfiles_nvim_warnings",
  "@dotfiles_nvim_line",
  "@dotfiles_nvim_column",
}

local function publisher_harness()
  local calls, deferred, notices = {}, {}, {}
  local deps = {
    pane = "%12",
    owner = "101_202",
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
  return { deps = deps, calls = calls, deferred = deferred, notices = notices }
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

local bridge_exports = vim.tbl_keys(bridge_test)
table.sort(bridge_exports)
eq(bridge_exports, {
  "canonicalize",
  "cleanup_argv",
  "decimal",
  "new",
  "tmux_quote",
  "update_argv",
  "valid_pane",
}, "exact tmux publisher test exports")

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
eq(bridge_test.canonicalize({ root = "/repo/" .. c1_csi_bridge }).root, "", "C1 root is rejected")

local combining_bridge = vim.fn.nr2char(0x301)
local grapheme_capped = bridge_test.canonicalize({
  path = string.rep("a", 508) .. "界" .. combining_bridge,
}).path
eq(grapheme_capped, string.rep("a", 508), "byte cap preserves a combining sequence")
assert(pcall(vim.str_utfindex, grapheme_capped), "combining cap split UTF-8")

do
  local h = publisher_harness()
  local publisher = bridge_test.new(h.deps)
  publisher:start(bridge_snapshot("first.lua", 1))
  for index = 2, 10 do
    publisher:request(bridge_snapshot("file" .. index .. ".lua", index))
  end
  eq(#h.deferred, 10, "every request gets a debounce generation")
  for _, item in ipairs(h.deferred) do
    eq(item.milliseconds, 75, "publisher debounce")
    item.callback()
  end

  eq(#h.calls, 1, "debounced initial claim")
  local claim = h.calls[1].argv
  assert(type(claim) == "table", "publisher did not use argv")
  eq(claim[1], "tmux", "publisher executable")
  eq(h.calls[1].options, { text = true }, "publisher process options")
  eq(option_value(claim, "@dotfiles_nvim_owner"), "101_202", "owner claim")
  eq(option_value(claim, "@dotfiles_nvim_path"), "file10.lua", "claim uses newest snapshot")

  local claim_names = {}
  for index, value in ipairs(claim) do
    if value == "set-option" then
      eq(claim[index + 1], "-pt", "claim pane scope")
      eq(claim[index + 2], "%12", "claim pane target")
      table.insert(claim_names, claim[index + 3])
    end
  end
  eq(claim_names, {
    "@dotfiles_nvim_owner",
    "@dotfiles_nvim_active",
    "@dotfiles_nvim_mode",
    "@dotfiles_nvim_root",
    "@dotfiles_nvim_path",
    "@dotfiles_nvim_errors",
    "@dotfiles_nvim_warnings",
    "@dotfiles_nvim_line",
    "@dotfiles_nvim_column",
    "@dotfiles_nvim_active",
  }, "initial claim option order")
  eq(claim[#claim], "1", "claim sets active last")

  local joined_claim = table.concat(claim, "\0")
  assert(not joined_claim:find("sh\0-c", 1, true), "publisher used sh -c")
  assert(not joined_claim:find("refresh-client", 1, true), "publisher forced status refresh")
end

for _, case in ipairs({
  { input = ";", expected = "\\;", label = "lone semicolon" },
  { input = "foo;", expected = "foo\\;", label = "trailing semicolon" },
  { input = "foo;;", expected = "foo;\\;", label = "two trailing semicolons" },
  { input = "back\\;", expected = "back\\\\;", label = "backslash and trailing semicolon" },
  { input = "middle;value", expected = "middle;value", label = "middle semicolon" },
  {
    input = [[quotes'" $HOME ${HOME} #]],
    expected = [[quotes'" $HOME ${HOME} #]],
    label = "quotes dollar hash",
  },
}) do
  local h = publisher_harness()
  local publisher = bridge_test.new(h.deps)
  publisher:start(bridge_snapshot(case.input, 1))
  h.deferred[1].callback()
  eq(
    option_value(h.calls[1].argv, "@dotfiles_nvim_path"),
    case.expected,
    "claim preserves " .. case.label
  )
  bridge_finish(h, 1)
end

do
  local h = publisher_harness()
  local publisher = bridge_test.new(h.deps)
  local first = bridge_snapshot("first.lua", 1)
  local running = bridge_snapshot("running.lua", 20)
  local older = bridge_snapshot("older.lua", 21)
  local newest = bridge_snapshot("newest.lua", 22)

  publisher:start(first)
  h.deferred[#h.deferred].callback()
  bridge_finish(h, 1)

  publisher:request(running)
  h.deferred[#h.deferred].callback()
  eq(#h.calls, 2, "first guarded update")
  publisher:request(older)
  h.deferred[#h.deferred].callback()
  publisher:request(newest)
  h.deferred[#h.deferred].callback()
  eq(#h.calls, 2, "one publisher child")
  bridge_finish(h, 2)
  eq(#h.calls, 3, "newest pending publisher snapshot")
  contains(h.calls[3].argv[7], "newest.lua", "pending replacement")
  eq(h.calls[3].argv[2], "if-shell", "update uses a tmux conditional")
  eq(h.calls[3].argv[3], "-F", "owner condition is a format")
  eq(h.calls[3].argv[4], "-t", "owner condition has an explicit target")
  eq(h.calls[3].argv[5], "%12", "owner condition pane")
  eq(h.calls[3].argv[6], "#{==:#{@dotfiles_nvim_owner},101_202}", "owner-guarded update")
  eq(#h.calls[3].argv, 8, "guarded update argv shape")
  bridge_finish(h, 3)

  publisher:request(newest)
  h.deferred[#h.deferred].callback()
  eq(#h.calls, 3, "successful snapshot deduplicated")
end

do
  local h = publisher_harness()
  local publisher = bridge_test.new(h.deps)
  local published_a = bridge_snapshot("a.lua", 1)
  local in_flight_b = bridge_snapshot("b.lua", 2)

  publisher:start(published_a)
  h.deferred[#h.deferred].callback()
  bridge_finish(h, 1)
  publisher:request(in_flight_b)
  h.deferred[#h.deferred].callback()
  publisher:request(published_a)
  h.deferred[#h.deferred].callback()
  eq(#h.calls, 2, "published snapshot waits while a different update runs")
  bridge_finish(h, 2)
  eq(#h.calls, 3, "newest pending snapshot is compared after child success")
  contains(h.calls[3].argv[7], "a.lua", "published A is restored after B")
end

do
  local h = publisher_harness()
  local publisher = bridge_test.new(h.deps)
  local retry = bridge_snapshot("retry.lua", 30)

  publisher:start(retry)
  h.deferred[#h.deferred].callback()
  bridge_finish(h, 1, { code = 1, stderr = "initial failed" })
  eq(#h.notices, 1, "initial failure warning")
  eq(publisher:debug_state().claimed, false, "failed claim does not claim ownership")
  eq(publisher:debug_state().published, nil, "failed claim does not advance dedup")

  publisher:request(retry)
  h.deferred[#h.deferred].callback()
  eq(#h.calls, 2, "failed initial snapshot retries")
  eq(h.calls[2].argv[2], "set-option", "initial failure retries the claim queue")
  bridge_finish(h, 2, { code = 0, signal = 15 })
  eq(#h.notices, 1, "signaled failure shares the warning gate")
  eq(publisher:debug_state().published, nil, "signaled code-zero result is not published")

  publisher:request(retry)
  h.deferred[#h.deferred].callback()
  eq(#h.calls, 3, "signaled snapshot retries")
  bridge_finish(h, 3)
  eq(publisher:debug_state().warned, false, "success resets warning state")

  local failure = bridge_snapshot("failure.lua", 31)
  publisher:request(failure)
  h.deferred[#h.deferred].callback()
  bridge_finish(h, 4, { code = 1, stderr = "failed" })
  eq(#h.notices, 2, "failure after success warns again")
  publisher:request(failure)
  h.deferred[#h.deferred].callback()
  bridge_finish(h, 5, { code = 1, stderr = "failed again" })
  eq(#h.notices, 2, "repeated failure warning deduplicated")
  publisher:request(failure)
  h.deferred[#h.deferred].callback()
  bridge_finish(h, 6)

  publisher:request(bridge_snapshot("failure-again.lua", 32))
  h.deferred[#h.deferred].callback()
  bridge_finish(h, 7, { code = 1, stderr = "failed after recovery" })
  eq(#h.notices, 3, "later success resets failure warning gate")
  eq(h.notices[3].level, "warn", "warning level")
end

do
  local h = publisher_harness()
  local real_system = h.deps.system
  local attempts = 0
  h.deps.system = function(...)
    attempts = attempts + 1
    if attempts == 1 then
      error("spawn failed")
    end
    return real_system(...)
  end

  local publisher = bridge_test.new(h.deps)
  publisher:start(bridge_snapshot("spawn.lua", 1))
  h.deferred[#h.deferred].callback()
  eq(#h.notices, 1, "thrown spawn warns")
  contains(h.notices[1].message, "spawn failed", "thrown spawn detail")
  eq(publisher:debug_state().in_flight, false, "thrown spawn clears the child slot")
  publisher:request(bridge_snapshot("spawn.lua", 1))
  h.deferred[#h.deferred].callback()
  eq(#h.calls, 1, "thrown spawn snapshot retries")
  bridge_finish(h, 1)
end

do
  local h = publisher_harness()
  local publisher = bridge_test.new(h.deps)
  publisher:start(bridge_snapshot("initial.lua", 1))
  h.deferred[1].callback()
  bridge_finish(h, 1)

  local hostile_snapshot = {
    mode = "INSERT",
    root = [[/repo/space ; ' " \ % # $HOME ${HOME} #{session_name} #[fg=red] #(id);]],
    path = [[space ; ' " \ % # $HOME ${HOME} #{session_name} #[fg=red] #(id)]]
      .. "\n\27\0"
      .. c1_csi_bridge
      .. "tail;",
    errors = "0002",
    warnings = -1,
    line = "0007",
    column = 11,
  }
  local hostile_canonical = bridge_test.canonicalize(hostile_snapshot)
  publisher:request(hostile_snapshot)
  h.deferred[2].callback()

  local hostile = h.calls[2].argv
  eq(hostile[1], "tmux", "hostile update executable")
  eq(hostile[2], "if-shell", "hostile update remains guarded")
  eq(hostile[6], "#{==:#{@dotfiles_nvim_owner},101_202}", "hostile owner condition")
  eq(#hostile, 8, "hostile update cannot append a tmux command")
  eq(hostile[8], "", "guarded update false branch")
  contains(hostile[7], "$HOME", "dollar remains literal in quoted command")
  contains(hostile[7], "#{session_name}", "format-looking value stays in the command argument")
  contains(hostile[7], "#(id)", "job-looking value stays in the command argument")
  contains(
    hostile[7],
    "@dotfiles_nvim_path " .. bridge_test.tmux_quote(hostile_canonical.path),
    "hostile path is tmux-quoted"
  )
  contains(hostile[7], "@dotfiles_nvim_errors '2'", "decimal canonicalization")
  for _, name in ipairs(bridge_option_names) do
    contains(hostile[7], "set-option -pt %12 " .. name .. " ", "hostile update includes " .. name)
  end
  for index, value in ipairs(hostile) do
    assert_control_free(value, "hostile argv " .. index)
  end
  assert(
    not table.concat(hostile, "\0"):find("refresh-client", 1, true),
    "hostile update forced refresh"
  )
end

do
  local h = publisher_harness()
  local publisher = bridge_test.new(h.deps)
  local control_path = "a\0b\n\27c\127d" .. c1_first_bridge .. "e" .. c1_last_bridge
  publisher:start(bridge_snapshot(control_path, 1))
  h.deferred[1].callback()
  eq(
    option_value(h.calls[1].argv, "@dotfiles_nvim_path"),
    "abcde",
    "claim strips every control class"
  )
  for index, value in ipairs(h.calls[1].argv) do
    assert_control_free(value, "claim argv " .. index)
  end
end

do
  local h = publisher_harness()
  local publisher = bridge_test.new(h.deps)
  publisher:start(bridge_snapshot("exit.lua", 1))
  h.deferred[#h.deferred].callback()
  publisher:request(bridge_snapshot("pending.lua", 2))
  h.deferred[#h.deferred].callback()
  publisher:stop()

  eq(h.calls[1].killed, 15, "exit terminates publisher child")
  eq(h.calls[1].waited, 150, "exit bounded-waits publisher child")
  eq(#h.calls, 2, "exit launches one cleanup queue")
  eq(h.calls[2].waited, 200, "exit bounded-waits cleanup")
  local cleanup = h.calls[2].argv
  eq(cleanup[1], "tmux", "cleanup executable")
  eq(cleanup[2], "if-shell", "cleanup uses a conditional")
  eq(cleanup[6], "#{==:#{@dotfiles_nvim_owner},101_202}", "cleanup owner guard")
  eq(cleanup[8], "", "cleanup false command")

  local expected_cleanup_names = { "@dotfiles_nvim_active" }
  vim.list_extend(expected_cleanup_names, bridge_option_names)
  table.insert(expected_cleanup_names, "@dotfiles_nvim_owner")
  local previous = 0
  for _, name in ipairs(expected_cleanup_names) do
    local position = assert(cleanup[7]:find(name, previous + 1, true), "cleanup lacks " .. name)
    assert(position > previous, "cleanup option order for " .. name)
    previous = position
  end

  local stopped = publisher:debug_state()
  bridge_finish(h, 1)
  eq(#h.calls, 2, "late publisher callback is inert")
  eq(publisher:debug_state(), stopped, "late publisher callback cannot mutate stopped state")
end

do
  local h = publisher_harness()
  local publisher = bridge_test.new(h.deps)
  publisher:start(bridge_snapshot("delayed.lua", 1))
  local delayed = h.deferred[1].callback
  publisher:stop()
  eq(#h.calls, 1, "stop before debounce launches cleanup only")
  local stopped = publisher:debug_state()
  delayed()
  publisher:request(bridge_snapshot("ignored.lua", 2))
  eq(#h.calls, 1, "delayed callback after stop starts no publisher")
  eq(#h.deferred, 1, "request after stop schedules nothing")
  eq(publisher:debug_state(), stopped, "delayed callback after stop is inert")
end

do
  local h = publisher_harness()
  local publisher = bridge_test.new(h.deps)
  publisher:start(bridge_snapshot("published.lua", 1))
  h.deferred[#h.deferred].callback()
  bridge_finish(h, 1)
  publisher:request(bridge_snapshot("running.lua", 2))
  h.deferred[#h.deferred].callback()
  publisher:request(bridge_snapshot("pending.lua", 3))
  h.deferred[#h.deferred].callback()

  local exposed = publisher:debug_state()
  exposed.desired.path = "mutated desired"
  exposed.published.path = "mutated published"
  exposed.pending.path = "mutated pending"
  local current = publisher:debug_state()
  eq(current.desired.path, "pending.lua", "debug desired is isolated")
  eq(current.published.path, "published.lua", "debug published is isolated")
  eq(current.pending.path, "pending.lua", "debug pending is isolated")
  publisher:stop()
end

do
  local saved_tmux = vim.env.TMUX
  local saved_tmux_pane = vim.env.TMUX_PANE
  local saved_executable = vim.fn.executable
  local executable_calls = 0
  local executable_result = 1
  vim.fn.executable = function(name)
    eq(name, "tmux", "setup executable name")
    executable_calls = executable_calls + 1
    return executable_result
  end

  vim.env.TMUX = nil
  vim.env.TMUX_PANE = "%12"
  eq(tmux_status.setup(), nil, "outside tmux setup is disabled")
  eq(executable_calls, 0, "outside tmux skips executable lookup")

  vim.env.TMUX = "/tmp/tmux/private,1,0"
  vim.env.TMUX_PANE = "%bad"
  eq(tmux_status.setup(), nil, "invalid pane setup is disabled")
  eq(executable_calls, 0, "invalid pane skips executable lookup")

  vim.env.TMUX_PANE = "%12"
  executable_result = 0
  eq(tmux_status.setup(), nil, "missing tmux executable disables setup")
  eq(executable_calls, 1, "missing executable checked once")

  executable_result = 1
  local publisher = tmux_status.setup()
  assert(publisher ~= nil, "valid tmux setup returned nil")
  eq(publisher:debug_state().stopped, false, "valid setup creates a publisher")
  eq(executable_calls, 2, "valid executable checked once")

  eq(tmux_status.setup({ pane = "%invalid" }), nil, "invalid explicit pane is rejected")
  eq(executable_calls, 2, "invalid explicit pane skips executable lookup")

  vim.fn.executable = saved_executable
  vim.env.TMUX = saved_tmux
  vim.env.TMUX_PANE = saved_tmux_pane
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
    eq(controller:snapshot().width, 80, "public snapshot reads initial live width")
    h.live.width = 120
    eq(controller:snapshot().width, 120, "public snapshot does not cache width")
  end)
  eq(h.options.statusline, "", "outside shutdown clears owned expression")
end

do
  local h = ownership_harness({ inside_tmux = true, pane = "%12" })
  with_runtime(h, function()
    eq(h.options.laststatus, 0, "tmux owns the only row")
    eq(h.options.cmdheight, 0, "tmux cmdheight")
    eq(h.options.showmode, false, "tmux showmode")
    eq(h.options.statusline, "", "tmux clears native expression")
    eq(h.cache_factory_calls, 0, "tmux starts no Git cache")
    eq(h.publisher_setup_calls, 1, "valid pane starts publisher")
    eq(h.publisher.setup_snapshots[1].root, "/repo/a", "initial publication")
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
    eq(h.options.laststatus, 0, case.label .. " keeps tmux ownership")
    eq(h.install_calls, 0, case.label .. " installs no native row")
    eq(h.cache_factory_calls, 0, case.label .. " starts no cache")
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
  eq(#h.autocmds, 7, "outside setup creates the exact event routes")
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
  eq(#h.autocmds, 7, "tmux setup creates the exact event routes")
  eq(h.publisher_setup_calls, 1, "tmux setup creates one publisher")
  statusline.shutdown()
  statusline.shutdown()
  eq(h.publisher.stop_calls, 1, "shutdown stops publisher once")
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
      "ModeChanged",
      "CursorMoved",
      "CursorMovedI",
      "DiagnosticChanged",
    }) do
      h.fire(event)
    end
    eq(#h.cache.updates, 0, "semantic events never invalidate Git")
    eq(h.live_reads, reads + 4, "semantic events rebuild snapshots")
    eq(h.redraws, 4, "semantic events redraw")

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
      "ModeChanged",
      "CursorMoved",
      "CursorMovedI",
      "DiagnosticChanged",
    }) do
      h.fire(event)
    end
    eq(#h.publisher.requests, 4, "semantic events publish snapshots")
    eq(h.redraws, 4, "published semantic events redraw")
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
  local ok, failure = xpcall(function()
    vim.api.nvim_win_set_buf(window, buffer)
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "\t界x" })
    vim.bo[buffer].buftype = ""
    vim.bo[buffer].tabstop = 4
    vim.api.nvim_win_set_cursor(window, { 1, 4 })
    local snapshot = test.live_snapshot()
    eq(snapshot.column, 7, "snapshot uses visual cursor column")
    assert(snapshot.column ~= 5, "snapshot used one-based byte column")
  end, debug.traceback)
  vim.api.nvim_win_set_buf(window, original_buffer)
  if vim.api.nvim_buf_is_valid(buffer) then
    vim.api.nvim_buf_delete(buffer, { force = true })
  end
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
