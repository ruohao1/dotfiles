local function eq(actual, expected, label)
  assert(
    vim.deep_equal(actual, expected),
    string.format("%s\nexpected: %s\nactual: %s", label, vim.inspect(expected), vim.inspect(actual))
  )
end

local startup = require("ui.startup")
local test = startup._test

for _, name in ipairs({
  "has_editing_intent",
  "is_bare_launch",
  "new",
}) do
  assert(type(test[name]) == "function", "missing startup test helper " .. name)
end

for _, argv in ipairs({
  { "nvim" },
  { "nvim", "--headless" },
  { "nvim", "--embed" },
  { "nvim", "--clean", "--noplugin", "-n", "-R" },
  { "nvim", "-u", "NONE", "-U", "NONE", "-i", "NONE" },
  { "nvim", "-uNONE", "-UNONE", "-iNONE" },
  { "nvim", "--listen", "/tmp/nvim.sock" },
  { "nvim", "--listen=/tmp/nvim.sock" },
  { "nvim", "--startuptime", "/tmp/nvim-startup.log" },
  { "nvim", "--" },
}) do
  eq(test.has_editing_intent(argv), false, "process-only argv " .. vim.inspect(argv))
end

for _, argv in ipairs({
  { "nvim", "file.lua" },
  { "nvim", "--embed", "file.lua" },
  { "nvim", "--embed", "-c", "set number" },
  { "nvim", "/tmp/project" },
  { "nvim", "-" },
  { "nvim", "-c", "set number" },
  { "nvim", "--cmd", "set number" },
  { "nvim", "+set number" },
  { "nvim", "-S", "Session.vim" },
  { "nvim", "-q", "errors" },
  { "nvim", "-t", "Main" },
  { "nvim", "-d" },
  { "nvim", "--remote", "file.lua" },
  { "nvim", "--server", "/tmp/nvim.sock", "--remote", "file.lua" },
  { "nvim", "--unknown-process-flag" },
  { "nvim", "-u" },
  { "nvim", "--listen" },
  { "nvim", "--", "file.lua" },
}) do
  eq(test.has_editing_intent(argv), true, "editing argv " .. vim.inspect(argv))
end

local bare_context = {
  argv = { "nvim", "--headless", "--listen", "/tmp/nvim.sock" },
  builtin_tui = false,
  stdin_seen = false,
  this_session = "",
  buffers = { 1 },
  current_buffer = 1,
  window_buffers = { 1 },
  initial_buffer = {
    id = 1,
    name = "",
    buftype = "",
    modified = false,
    lines = { "" },
  },
}

eq(test.is_bare_launch(bare_context), true, "configured non-embed headless bare launch")

local embedded_tui_context = vim.deepcopy(bare_context)
embedded_tui_context.argv = { "nvim", "--embed", "--listen", "/tmp/nvim.sock" }
embedded_tui_context.builtin_tui = true
eq(test.is_bare_launch(embedded_tui_context), true, "builtin TUI embedded bare launch")

local direct_embed_context = vim.deepcopy(embedded_tui_context)
direct_embed_context.builtin_tui = false
eq(test.is_bare_launch(direct_embed_context), false, "direct embedded launch remains non-bare")

local external_embed_context = vim.deepcopy(embedded_tui_context)
external_embed_context.builtin_tui = nil
eq(test.is_bare_launch(external_embed_context), false, "external embedded launch remains non-bare")

local invalid_contexts = {
  function(context)
    context.argv = { "nvim", "file.lua" }
  end,
  function(context)
    context.stdin_seen = true
  end,
  function(context)
    context.this_session = "/tmp/Session.vim"
  end,
  function(context)
    context.buffers = { 1, 2 }
  end,
  function(context)
    context.current_buffer = 2
  end,
  function(context)
    context.window_buffers = { 1, 2 }
  end,
  function(context)
    context.initial_buffer.name = "/tmp/file.lua"
  end,
  function(context)
    context.initial_buffer.buftype = "nofile"
  end,
  function(context)
    context.initial_buffer.modified = true
  end,
  function(context)
    context.initial_buffer.lines = { "not empty" }
  end,
  function(context)
    context.initial_buffer.lines = { "", "" }
  end,
}

for index, mutate in ipairs(invalid_contexts) do
  local context = vim.deepcopy(bare_context)
  mutate(context)
  eq(test.is_bare_launch(context), false, "invalid bare context " .. index)
end

local repeated_window = vim.deepcopy(bare_context)
repeated_window.window_buffers = { 1, 1 }
eq(test.is_bare_launch(repeated_window), true, "multiple windows may show the initial buffer")

local function new_controller_harness(context)
  local harness = {
    starter_setup_calls = {},
    starter_open_calls = 0,
    augroup_calls = {},
    autocmds = {},
    mappings = {},
    removed_mappings = {},
    status_calls = {},
    picker_calls = {},
    notifications = {},
    current_buffer = 9,
    filetypes = { [9] = "ministarter" },
    context = vim.deepcopy(context or bare_context),
    context_calls = 0,
    root_calls = 0,
    project_root = "/home/src/project",
    cwd = "/workspace",
    set_current_dir_calls = {},
    requests = {},
    scheduled = {},
    timers = {},
    refreshes = {},
    selected = 1,
    pointers = {},
    composed = {},
  }

  local fake_starter = {
    gen_hook = {
      aligning = function()
        return function(content)
          return content
        end
      end,
    },
    get_content = function()
      local line = {}
      for _, item in ipairs(harness.starter_setup_calls[1].items) do
        table.insert(line, { type = "pointer", string = "  " })
        table.insert(
          line,
          { type = "item", string = item.name .. string.rep(" ", 18 - #item.name), item = item }
        )
      end
      return { {}, line }
    end,
    content_to_items = function()
      local items = {}
      for index, item in ipairs(harness.starter_setup_calls[1].items) do
        items[index] = { action = item.action, _cursorpos = { 2, (index - 1) * 20 + 2 } }
      end
      return items
    end,
    update_current_item = function(direction)
      harness.selected = (harness.selected - 1 + (direction == "next" and 1 or -1)) % 3 + 1
    end,
    refresh = function(bufnr)
      table.insert(harness.refreshes, bufnr)
      harness.selected = 1
      harness.starter_setup_calls[1].content_hooks[1]({}, bufnr)
    end,
    setup = function(options)
      table.insert(harness.starter_setup_calls, options)
    end,
    open = function()
      harness.starter_open_calls = harness.starter_open_calls + 1
    end,
  }

  local fake_pickers = {
    recent = function(root)
      table.insert(harness.picker_calls, { name = "recent", root = root })
    end,
    files = function(root)
      table.insert(harness.picker_calls, { name = "files", root = root })
    end,
  }

  harness.dependencies = {
    collect = function(directory, callback)
      local request = { directory = directory, callback = callback, canceled = false }
      function request:cancel()
        self.canceled = true
      end
      table.insert(harness.requests, request)
      return request
    end,
    compose = function(content, view, dimensions)
      table.insert(harness.composed, { view = view, dimensions = dimensions })
      return content
    end,
    schedule = function(callback)
      table.insert(harness.scheduled, callback)
    end,
    new_timer = function()
      local timer = { closed = false }
      function timer:start(delay, repeat_delay, callback)
        self.delay = delay
        self.callback = callback
      end
      function timer:stop()
        self.callback = nil
      end
      function timer:close()
        self.closed = true
      end
      table.insert(harness.timers, timer)
      return timer
    end,
    buffer_valid = function(bufnr)
      return harness.filetypes[bufnr] ~= nil
    end,
    buffer_visible = function(bufnr)
      return harness.current_buffer == bufnr
    end,
    dimensions = function()
      return { width = 80, height = 23 }
    end,
    cursor = function()
      return { 2, (harness.selected - 1) * 20 + 2 }
    end,
    write_pointer = function(bufnr, row, column, text)
      table.insert(harness.pointers, { bufnr, row, column, text })
    end,
    quit = function()
      harness.quit_called = true
    end,
    starter = function()
      return fake_starter
    end,
    pickers = function()
      return fake_pickers
    end,
    root = function()
      harness.root_calls = harness.root_calls + 1
      return harness.project_root
    end,
    getcwd = function()
      return harness.cwd
    end,
    set_current_dir = function(path)
      table.insert(harness.set_current_dir_calls, path)
      harness.cwd = path
    end,
    notify = function(message, level, options)
      table.insert(harness.notifications, {
        message = message,
        level = level,
        options = vim.deepcopy(options),
      })
    end,
    current_buffer = function()
      return harness.current_buffer
    end,
    buffer_filetype = function(bufnr)
      return harness.filetypes[bufnr]
    end,
    set_startup_visible = function(visible)
      table.insert(harness.status_calls, { phase = "status", visible = visible })
    end,
    set_mapping = function(bufnr, lhs, callback, description)
      table.insert(harness.mappings, {
        bufnr = bufnr,
        lhs = lhs,
        callback = callback,
        description = description,
      })
    end,
    delete_mapping = function(bufnr, lhs)
      table.insert(harness.removed_mappings, { bufnr, lhs })
    end,
    create_augroup = function(name, options)
      table.insert(harness.augroup_calls, {
        name = name,
        options = vim.deepcopy(options),
      })
      return 17
    end,
    create_autocmd = function(event, options)
      table.insert(harness.autocmds, {
        event = vim.deepcopy(event),
        options = options,
      })
      return #harness.autocmds
    end,
    startup_context = function(stdin_seen)
      harness.context_calls = harness.context_calls + 1
      local current = vim.deepcopy(harness.context)
      current.stdin_seen = stdin_seen
      return current
    end,
  }

  function harness:flush()
    while #self.scheduled > 0 do
      local queued = self.scheduled
      self.scheduled = {}
      for _, callback in ipairs(queued) do
        callback()
      end
    end
  end

  function harness:invoke(event)
    if event == "VimResized" then
      fake_starter.refresh(self.current_buffer)
      return
    end
    local matches = {}
    for _, route in ipairs(self.autocmds) do
      local registered = route.event
      local matches_event = registered == event
        or (type(registered) == "table" and vim.tbl_contains(registered, event))
      if matches_event then
        if event ~= "User" or route.options.pattern == "MiniStarterOpened" then
          table.insert(matches, route)
        end
      end
    end
    eq(#matches, 1, "one captured " .. event .. " route")
    matches[1].options.callback({ event = event, buf = self.current_buffer })
  end

  return harness
end

local harness = new_controller_harness()
local controller = test.new(harness.dependencies)
assert(controller:setup() == controller, "setup must return its controller")
local scoped = new_controller_harness()
test.new(scoped.dependencies):setup()
scoped.starter_setup_calls[1].items[1].action()
scoped.starter_setup_calls[1].items[2].action()
eq(scoped.picker_calls, {
  { name = "files", root = "/home/src/project" },
  { name = "recent", root = "/home/src/project" },
}, "starter actions open files within the current project")
eq(scoped.cwd, "/workspace", "starter actions preserve the editor directory")
eq(scoped.set_current_dir_calls, {}, "starter actions never change directory")
scoped.project_root = "/another directory"
scoped.starter_setup_calls[1].items[1].action()
eq(
  scoped.picker_calls[3],
  { name = "files", root = "/another directory" },
  "actions resolve current context"
)
assert(controller:setup() == controller, "repeated setup must return its controller")
eq(#harness.starter_setup_calls, 1, "MiniStarter setup once")
eq(#harness.augroup_calls, 1, "one startup augroup")
eq(
  vim.tbl_map(function(item)
    return item.name
  end, harness.starter_setup_calls[1].items),
  { "f  Find files", "r  Recent files", "q  Quit" },
  "approved menu preserves all three actions"
)
eq(#harness.autocmds, 9, "startup event routes")
eq(harness.augroup_calls, {
  { name = "dotfiles-startup", options = { clear = true } },
}, "exact startup augroup")
eq(
  vim.tbl_map(function(route)
    return route.event
  end, harness.autocmds),
  {
    "StdinReadPre",
    "VimEnter",
    "User",
    { "BufEnter", "WinEnter" },
    "WinResized",
    "CursorMoved",
    "DirChanged",
    "FocusGained",
    { "BufWipeout", "VimLeavePre" },
  },
  "exact startup events"
)
eq(harness.autocmds[3].options.pattern, "MiniStarterOpened", "exact opened event pattern")

local options = harness.starter_setup_calls[1]
eq(options.autoopen, false, "plugin autoopen disabled")
eq(options.evaluate_single, false, "single item never autoexecutes")
eq(options.header, "", "empty startup header")
eq(options.footer, "", "empty startup footer")
eq(options.query_updaters, "", "query mappings disabled")
eq(
  vim.tbl_map(function(item)
    return item.name
  end, options.items),
  {
    "f  Find files",
    "r  Recent files",
    "q  Quit",
  },
  "exact startup item names"
)
eq(
  vim.tbl_map(function(item)
    return item.section
  end, options.items),
  { "", "", "" },
  "empty item sections"
)
eq(#options.content_hooks, 1, "one composition hook")
options.content_hooks[1]({}, harness.current_buffer)
eq(harness.composed[1].view, { kind = "loading" }, "initial content renders loading")
eq(harness.status_calls, {
  { phase = "status", visible = true },
}, "status suppression precedes composition")
eq(harness.root_calls, 0, "root lookup waits for an action")

local stdin_harness = new_controller_harness()
local stdin_controller = test.new(stdin_harness.dependencies)
stdin_controller:setup()
stdin_harness:invoke("StdinReadPre")
stdin_harness:invoke("VimEnter")
eq(stdin_harness.starter_open_calls, 0, "stdin intent suppresses startup")
eq(stdin_harness.context_calls, 1, "stdin startup evaluates once")
eq(stdin_controller:debug_state().stdin_seen, true, "stdin intent is captured")

local eligible_harness = new_controller_harness()
local eligible_controller = test.new(eligible_harness.dependencies)
eligible_controller:setup()
eligible_harness:invoke("VimEnter")
eq(eligible_harness.starter_open_calls, 1, "eligible startup opens once")
eq(eligible_harness.context_calls, 1, "eligible startup evaluates once")
eligible_harness:invoke("VimEnter")
eq(eligible_harness.starter_open_calls, 1, "repeated VimEnter does not reopen")
eq(eligible_harness.context_calls, 1, "repeated VimEnter does not reevaluate")

local nonbare_context = vim.deepcopy(bare_context)
nonbare_context.argv = { "nvim", "file.lua" }
local nonbare_harness = new_controller_harness(nonbare_context)
local nonbare_controller = test.new(nonbare_harness.dependencies)
nonbare_controller:setup()
nonbare_harness:invoke("VimEnter")
nonbare_harness.context = vim.deepcopy(bare_context)
nonbare_harness:invoke("VimEnter")
eq(nonbare_harness.starter_open_calls, 0, "non-bare startup never becomes eligible")
eq(nonbare_harness.context_calls, 1, "non-bare startup evaluates only once")

harness.status_calls = {}
harness:invoke("User")
eq(harness.status_calls, {
  { phase = "status", visible = true },
}, "MiniStarterOpened suppresses the statusline")
eq(harness.removed_mappings, {
  { harness.current_buffer, "<M-j>" },
  { harness.current_buffer, "<M-k>" },
}, "MiniStarterOpened releases native Alt mappings for split navigation")
eq(#harness.mappings, 10, "MiniStarterOpened action and native navigation mappings")
eq(
  vim.tbl_map(function(mapping)
    return { mapping.bufnr, mapping.lhs, mapping.description }
  end, harness.mappings),
  {
    { harness.current_buffer, "f", "Find files" },
    { harness.current_buffer, "r", "Open recent files" },
    { harness.current_buffer, "q", "Quit" },
    { harness.current_buffer, "<C-c>", "Quit" },
    { harness.current_buffer, "j", "Next startup item" },
    { harness.current_buffer, "<Down>", "Next startup item" },
    { harness.current_buffer, "<C-n>", "Next startup item" },
    { harness.current_buffer, "k", "Previous startup item" },
    { harness.current_buffer, "<Up>", "Previous startup item" },
    { harness.current_buffer, "<C-p>", "Previous startup item" },
  },
  "exact buffer-local startup mappings"
)
assert(harness.mappings[1].callback == options.items[1].action, "file action identity changed")
assert(harness.mappings[2].callback == options.items[2].action, "recent action identity changed")
assert(harness.mappings[4].callback == options.items[3].action, "Ctrl-C must share the Quit action")

harness.status_calls = {}
harness.filetypes[harness.current_buffer] = "ministarter"
harness:invoke("BufEnter")
harness:invoke("WinEnter")
harness.filetypes[harness.current_buffer] = "lua"
harness:invoke("BufEnter")
harness:invoke("WinEnter")
eq(harness.status_calls, {
  { phase = "status", visible = true },
  { phase = "status", visible = true },
  { phase = "status", visible = false },
  { phase = "status", visible = false },
}, "buffer and window routes synchronize startup visibility")

harness.picker_calls = {}
options.items[2].action()
eq(
  harness.picker_calls,
  { { name = "recent", root = harness.project_root } },
  "recent action uses current project"
)
eq(harness.root_calls, 1, "recent action resolves the current root once")

-- These checks catch stale callbacks, uncanceled work, overlapping focus requests,
-- and losing an action when native MiniStarter repositions its items.
local lifecycle = new_controller_harness()
local lifecycle_controller = test.new(lifecycle.dependencies)
lifecycle_controller:setup()
lifecycle:invoke("User")
eq(#lifecycle.requests, 1, "opening starts one asynchronous request")
eq(lifecycle.requests[1].directory, "/workspace", "request captures the buffer directory")
lifecycle:flush()
lifecycle.mappings[5].callback()
eq(lifecycle.selected, 2, "j selects Recent files natively")
lifecycle.mappings[5].callback()
lifecycle.mappings[5].callback()
eq(lifecycle.selected, 1, "j cycles back to Find files")
lifecycle.mappings[8].callback()
eq(lifecycle.selected, 3, "k cycles backward to Quit")
lifecycle.requests[1].callback({ kind = "repository", name = "fixture" })
lifecycle:flush()
eq(lifecycle.selected, 3, "async refresh preserves the selected action")
eq(
  lifecycle.pointers[#lifecycle.pointers],
  { 9, 2, 40, "> " },
  "shared-row pointer uses byte column"
)
lifecycle:invoke("VimResized")
lifecycle:flush()
eq(#lifecycle.requests, 1, "resize uses cached Git data")
local window_refreshes = #lifecycle.refreshes
lifecycle:invoke("WinResized")
lifecycle:flush()
eq(#lifecycle.refreshes, window_refreshes + 1, "window resize recomposes the visible starter")
eq(lifecycle.selected, 3, "window resize preserves the selected action")
eq(#lifecycle.requests, 1, "window resize uses cached Git data")
lifecycle.current_buffer = 10
lifecycle:invoke("WinResized")
eq(#lifecycle.refreshes, window_refreshes + 1, "window resize skips hidden starters")
lifecycle.current_buffer = 9
lifecycle:invoke("FocusGained")
local stale_focus = lifecycle.timers[1].callback
stale_focus()
lifecycle:invoke("FocusGained")
lifecycle:flush()
eq(#lifecycle.requests, 1, "queued old focus does not preempt newer debounce")
eq(lifecycle.timers[2].closed, false, "queued old focus leaves its replacement open")
eq(lifecycle.timers[1].closed, true, "repeat focus closes its old debounce timer")
local focus_timer = lifecycle.timers[2]
eq(focus_timer.delay, 150, "focus debounce delay")
focus_timer.callback()
lifecycle:flush()
eq(#lifecycle.requests, 2, "focus starts one request after debounce")
lifecycle:invoke("FocusGained")
eq(#lifecycle.timers, 2, "focus does not overlap an active request")
lifecycle.cwd = "/other"
lifecycle:invoke("DirChanged")
eq(lifecycle.requests[2].canceled, true, "directory change cancels old work")
eq(lifecycle.requests[3].directory, "/other", "directory change collects the new directory")
local refresh_count = #lifecycle.refreshes
lifecycle.requests[2].callback({ kind = "error" })
eq(#lifecycle.refreshes, refresh_count, "late old-directory callback cannot refresh")
lifecycle.requests[3].callback({ kind = "error" })
lifecycle:flush()
eq(#lifecycle.notifications, 1, "Git failure warns once")
lifecycle:invoke("FocusGained")
lifecycle.timers[#lifecycle.timers].callback()
lifecycle:flush()
lifecycle.requests[4].callback({ kind = "error" })
eq(#lifecycle.notifications, 1, "repeated Git failure remains quiet")
lifecycle.current_buffer = 10
lifecycle.filetypes[10] = "ministarter"
lifecycle:invoke("User")
eq(#lifecycle.requests, 5, "second starter owns a separate request")
lifecycle:invoke("FocusGained")
eq(#lifecycle.timers, 3, "second buffer request also prevents focus overlap")
lifecycle:invoke("BufWipeout")
eq(lifecycle.requests[5].canceled, true, "wipe cancels the owning buffer request")
refresh_count = #lifecycle.refreshes
lifecycle.current_buffer = 9
lifecycle.requests[5].callback({ kind = "repository" })
eq(#lifecycle.refreshes, refresh_count, "closed buffer completion cannot refresh another starter")
lifecycle:invoke("FocusGained")
local closing_timer = lifecycle.timers[#lifecycle.timers]
lifecycle:invoke("BufWipeout")
eq(closing_timer.closed, true, "wipe closes its focus timer")
refresh_count = #lifecycle.refreshes
lifecycle:invoke("WinResized")
eq(#lifecycle.refreshes, refresh_count, "window resize ignores closed starter buffers")
local restore_navigation = new_controller_harness()
test.new(restore_navigation.dependencies):setup()
restore_navigation:invoke("User")
restore_navigation:flush()
restore_navigation.mappings[5].callback()
restore_navigation:invoke("VimResized")
restore_navigation.mappings[8].callback()
restore_navigation.requests[1].callback({ kind = "non_repository" })
restore_navigation:flush()
eq(
  restore_navigation.selected,
  3,
  "explicit navigation replaces saved action during resize reconciliation"
)

local exiting = new_controller_harness()
test.new(exiting.dependencies):setup()
exiting:invoke("User")
exiting.requests[1].callback({ kind = "non_repository" })
exiting:invoke("FocusGained")
exiting.current_buffer = 10
exiting.filetypes[10] = "ministarter"
exiting:invoke("User")
exiting:invoke("VimLeavePre")
eq(exiting.timers[1].closed, true, "editor exit closes owned focus timers")
eq(exiting.requests[2].canceled, true, "editor exit cancels pending requests")
options.items[3].action()
eq(harness.quit_called, true, "Quit action uses the normal quit boundary")

local function path_is_within(path, root)
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function normalized_absolute(path, label)
  assert(type(path) == "string" and path ~= "", label .. " must be nonempty")
  local normalized = vim.fs.normalize(path):gsub("/+$", "")
  assert(normalized:sub(1, 1) == "/", label .. " must be absolute")
  assert(normalized ~= "", label .. " must not be the filesystem root")
  return normalized
end

local function resolve_path_and_parent(path, label)
  local normalized = normalized_absolute(path, label)
  local parent = vim.fs.dirname(normalized)
  local resolved_parent = vim.uv.fs_realpath(parent)
  if resolved_parent then
    normalized = vim.fs.joinpath(resolved_parent, vim.fs.basename(normalized))
  end
  local resolved = vim.uv.fs_realpath(normalized)
  return normalized_absolute(resolved or normalized, label)
end

local function assert_directory(path, label)
  local stat = vim.uv.fs_stat(path)
  assert(stat and stat.type == "directory", label .. " must be an existing directory")
end

local startup_live_paths
local function get_startup_live_paths()
  if vim.env.DOTFILES_STARTUP_LIVE ~= "1" then
    return nil
  end
  if startup_live_paths then
    return startup_live_paths
  end

  local paths = {
    nvim_root = assert(vim.env.DOTFILES_NVIM_ROOT, "DOTFILES_NVIM_ROOT missing"),
    data_home = assert(vim.env.DOTFILES_STARTUP_DATA_HOME, "startup data home missing"),
    test_root = assert(vim.env.DOTFILES_STARTUP_TEST_ROOT, "startup test root missing"),
    allowed_root = assert(vim.env.DOTFILES_STARTUP_ALLOWED_ROOT, "startup allowed root missing"),
  }
  paths.nvim_root = resolve_path_and_parent(paths.nvim_root, "Neovim root")
  paths.data_home = resolve_path_and_parent(paths.data_home, "startup data home")
  paths.test_root = resolve_path_and_parent(paths.test_root, "startup test root")
  paths.allowed_root = resolve_path_and_parent(paths.allowed_root, "startup allowed root")

  assert_directory(paths.nvim_root, "Neovim root")
  assert_directory(paths.data_home, "startup data home")
  assert_directory(paths.test_root, "startup test root")
  assert_directory(paths.allowed_root, "startup allowed root")
  assert(
    path_is_within(paths.test_root, paths.allowed_root),
    "startup test root escaped its allowed root"
  )
  startup_live_paths = paths
  return paths
end

local function make_directory(path)
  vim.fn.mkdir(path, "p")
  local stat = vim.uv.fs_stat(path)
  assert(stat and stat.type == "directory", "could not create directory " .. path)
end

local function write_file(path, lines)
  make_directory(vim.fs.dirname(path))
  assert(vim.fn.writefile(lines or { "fixture" }, path) == 0, "could not write " .. path)
end

local specs = require("plugins.startup")
eq(#specs, 1, "startup plugin count")
local spec = specs[1]
eq(spec[1], "nvim-mini/mini.starter", "MiniStarter repository")
eq(spec.version, "*", "MiniStarter stable policy")
eq(spec.lazy, false, "MiniStarter eager load")
assert(type(spec.config) == "function", "MiniStarter config callback missing")
assert(spec.opts == nil, "MiniStarter setup belongs to ui.startup")

local original_startup_module = package.loaded["ui.startup"]
local plugin_setup_calls = 0
package.loaded["ui.startup"] = {
  setup = function()
    plugin_setup_calls = plugin_setup_calls + 1
  end,
}
local config_ok, config_error = xpcall(spec.config, debug.traceback)
package.loaded["ui.startup"] = original_startup_module
assert(config_ok, config_error)
eq(plugin_setup_calls, 1, "MiniStarter config calls startup setup once")

if vim.env.DOTFILES_REQUIRE_EDITING_PLUGINS == "1" then
  assert(type(_G.MiniStarter) == "table", "MiniStarter must remain configured in the aggregate")
  assert(vim.bo.filetype ~= "ministarter", "configured -c aggregate opened MiniStarter")
  eq(vim.o.laststatus, 3, "configured -c aggregate keeps the standalone statusline")
end

print("Neovim startup pure assertions: ok")

if vim.env.DOTFILES_STARTUP_LIVE ~= "1" then
  return
end

local live_paths = assert(get_startup_live_paths(), "startup live paths missing")
local nvim_root = live_paths.nvim_root
local data_home = live_paths.data_home
local test_root = live_paths.test_root
local allowed_root = live_paths.allowed_root

local function validated_case_root(name)
  assert(type(name) == "string" and name:match("^[%w][%w_-]*$"), "invalid startup case name")
  local root = vim.fs.normalize(vim.fs.joinpath(test_root, name))
  assert(root ~= test_root and path_is_within(root, test_root), "startup case escaped test root")
  return root
end

local function make_case_directories(case)
  local case_root = validated_case_root(case.name)
  assert(vim.uv.fs_lstat(case_root) == nil, "startup case root already exists: " .. case.name)

  local state = vim.fs.joinpath(case_root, "state")
  local cache = vim.fs.joinpath(case_root, "cache")
  local runtime = vim.fs.joinpath(case_root, "runtime")
  assert(vim.fn.mkdir(state, "p") == 1, "could not create child state: " .. case.name)
  assert(vim.fn.mkdir(cache, "p") == 1, "could not create child cache: " .. case.name)
  assert(vim.fn.mkdir(runtime, "p") == 1, "could not create child runtime: " .. case.name)
  assert(vim.uv.fs_chmod(runtime, 448), "could not protect child runtime: " .. case.name)

  return {
    cache = cache,
    root = case_root,
    runtime = runtime,
    socket = vim.fs.joinpath(case_root, "nvim.sock"),
    state = state,
  }
end

local function terminate_process(process)
  local signal_ok, signal_error = pcall(process.kill, process, 15)
  local wait_ok, result = pcall(process.wait, process, 5000)
  return signal_ok, signal_error, wait_ok and result or nil
end

local function connect_child(case, paths, process)
  local listening = vim.wait(10000, function()
    return vim.uv.fs_stat(paths.socket) ~= nil
  end, 20)
  if not listening then
    local _, _, result = terminate_process(process)
    error(
      string.format(
        "child listen socket timed out: %s\n%s",
        case.name,
        result and (result.stderr or result.stdout or "") or "child could not be reaped"
      ),
      0
    )
  end

  local connected, channel = pcall(vim.fn.sockconnect, "pipe", paths.socket, { rpc = true })
  if not connected or type(channel) ~= "number" or channel <= 0 then
    terminate_process(process)
    error("could not connect child RPC socket: " .. case.name, 0)
  end

  return {
    channel = channel,
    process = process,
    root = paths.root,
    socket = paths.socket,
  }
end

local function start_child(case)
  local paths = make_case_directories(case)
  local argv = {
    "env",
    "-u",
    "TMUX",
    "-u",
    "TMUX_PANE",
    "-u",
    "NVIM_APPNAME",
    "XDG_CONFIG_HOME=" .. vim.fs.dirname(nvim_root),
    "XDG_DATA_HOME=" .. data_home,
    "XDG_STATE_HOME=" .. paths.state,
    "XDG_CACHE_HOME=" .. paths.cache,
    "XDG_RUNTIME_DIR=" .. paths.runtime,
    "NVIM_LOG_FILE=" .. vim.fs.joinpath(paths.root, "nvim.log"),
    "DOTFILES_NVIM_SKIP_PARSER_INSTALL=1",
    "TERM_PROGRAM=ghostty",
  }
  vim.list_extend(argv, case.environment or {})
  vim.list_extend(argv, { "nvim", "--headless", "--listen", paths.socket, "-i", "NONE" })
  vim.list_extend(argv, case.arguments or {})

  local process = vim.system(argv, {
    cwd = case.cwd or paths.root,
    stdin = case.stdin,
    text = true,
  })
  return connect_child(case, paths, process)
end

local function start_none_child(case)
  local paths = make_case_directories(case)
  local argv = {
    "env",
    "-u",
    "TMUX",
    "-u",
    "TMUX_PANE",
    "-u",
    "NVIM_APPNAME",
    "XDG_STATE_HOME=" .. paths.state,
    "XDG_CACHE_HOME=" .. paths.cache,
    "XDG_RUNTIME_DIR=" .. paths.runtime,
    "NVIM_LOG_FILE=" .. vim.fs.joinpath(paths.root, "nvim.log"),
    "nvim",
    "--clean",
    "--headless",
    "-u",
    "NONE",
    "--listen",
    paths.socket,
    "-i",
    "NONE",
  }
  vim.list_extend(argv, case.arguments or {})

  local process = vim.system(argv, {
    cwd = case.cwd or paths.root,
    stdin = case.stdin,
    text = true,
  })
  return connect_child(case, paths, process)
end

local function tui_output(child)
  local output = table.concat(child.output, "\n")
  return output:sub(math.max(1, #output - 4000))
end

local function stop_tui_job(job)
  local status = vim.fn.jobwait({ job }, 0)[1]
  local stopped = false
  if status == -1 then
    stopped = vim.fn.jobstop(job) == 1
    status = vim.fn.jobwait({ job }, 5000)[1]
  end
  return status, stopped
end

local function start_tui_child(case)
  local paths = make_case_directories(case)
  local output = {}
  local argv = {
    "env",
    "-u",
    "NVIM",
    "-u",
    "TMUX",
    "-u",
    "TMUX_PANE",
    "-u",
    "NVIM_APPNAME",
    "XDG_CONFIG_HOME=" .. vim.fs.dirname(nvim_root),
    "XDG_DATA_HOME=" .. data_home,
    "XDG_STATE_HOME=" .. paths.state,
    "XDG_CACHE_HOME=" .. paths.cache,
    "XDG_RUNTIME_DIR=" .. paths.runtime,
    "NVIM_LOG_FILE=" .. vim.fs.joinpath(paths.root, "nvim.log"),
    "DOTFILES_NVIM_SKIP_PARSER_INSTALL=1",
    "TERM=xterm-256color",
    "TERM_PROGRAM=ghostty",
    "nvim",
    "--listen",
    paths.socket,
    "-i",
    "NONE",
  }
  vim.list_extend(argv, case.arguments or {})

  local job = vim.fn.jobstart(argv, {
    cwd = case.cwd or paths.root,
    pty = true,
    width = 80,
    height = 23,
    on_stdout = function(_, data)
      for _, chunk in ipairs(data or {}) do
        if chunk ~= "" then
          table.insert(output, chunk)
        end
      end
    end,
  })
  assert(job > 0, "could not start TUI child: " .. case.name)

  local child = {
    channel = nil,
    job = job,
    output = output,
    root = paths.root,
    socket = paths.socket,
  }
  local listening = vim.wait(10000, function()
    return vim.uv.fs_stat(paths.socket) ~= nil
  end, 20)
  if not listening then
    local status, stopped = stop_tui_job(job)
    error(
      string.format(
        "TUI child listen socket timed out: %s; status: %s; stopped: %s\n%s",
        case.name,
        tostring(status),
        tostring(stopped),
        tui_output(child)
      ),
      0
    )
  end

  local connected, channel = pcall(vim.fn.sockconnect, "pipe", paths.socket, { rpc = true })
  if not connected or type(channel) ~= "number" or channel <= 0 then
    local status, stopped = stop_tui_job(job)
    error(
      string.format(
        "could not connect TUI child RPC socket: %s; status: %s; stopped: %s\n%s",
        case.name,
        tostring(status),
        tostring(stopped),
        tui_output(child)
      ),
      0
    )
  end
  child.channel = channel
  return child
end

local function child_lua(child, source)
  return vim.rpcrequest(child.channel, "nvim_exec_lua", source, {})
end

local function wait_child_lua(child, source, label)
  local value
  local last_error
  local ready = vim.wait(10000, function()
    local ok, current = pcall(child_lua, child, source)
    if ok and current ~= nil and current ~= false then
      value = current
      return true
    end
    if not ok then
      last_error = current
    end
    return false
  end, 20)
  assert(ready, string.format("%s timed out: %s", label, tostring(last_error or "not ready")))
  return value
end

local function child_input(child, keys)
  local accepted = vim.rpcrequest(child.channel, "nvim_input", keys)
  assert(type(accepted) == "number" and accepted > 0, "child rejected input " .. keys)
end

local function stop_child(child)
  if child.process:is_closing() then
    local result = child.process:wait(5000)
    pcall(vim.fn.chanclose, child.channel)
    assert(result.code == 0 and result.signal == 0, "child normal quit failed")
    return
  end
  local rpc_ok, rpc_error = pcall(vim.rpcnotify, child.channel, "nvim_command", "qa!")
  local exited = rpc_ok
    and vim.wait(5000, function()
      return child.process:is_closing()
    end, 20)
  pcall(vim.fn.chanclose, child.channel)
  if not rpc_ok or not exited then
    if rpc_ok then
      rpc_error = "child did not exit after RPC stop notification"
    end
    local signal_ok, signal_error, result = terminate_process(child.process)
    error(
      string.format(
        "child RPC stop failed: %s; signal sent: %s (%s); result: %s",
        tostring(rpc_error),
        tostring(signal_ok),
        tostring(signal_error),
        vim.inspect(result)
      ),
      0
    )
  end

  local result = child.process:wait(5000)
  assert(result.code == 0 and result.signal == 0, result.stderr or result.stdout or "child failed")
end

local function stop_tui_child(child)
  local rpc_ok, rpc_error = pcall(vim.rpcnotify, child.channel, "nvim_command", "qa!")
  local status = vim.fn.jobwait({ child.job }, 5000)[1]
  local stopped = false
  if status == -1 then
    stopped = vim.fn.jobstop(child.job) == 1
    status = vim.fn.jobwait({ child.job }, 5000)[1]
  end
  pcall(vim.fn.chanclose, child.channel)

  assert(
    rpc_ok and status == 0,
    string.format(
      "TUI child stop failed: rpc=%s (%s); status=%s; stopped=%s\n%s",
      tostring(rpc_ok),
      tostring(rpc_error),
      tostring(status),
      tostring(stopped),
      tui_output(child)
    )
  )
end

local function delete_case_root(root)
  assert(root ~= test_root and path_is_within(root, test_root), "case cleanup escaped test root")
  assert(vim.fn.delete(root, "rf") == 0, "could not delete startup case " .. root)
  assert(vim.uv.fs_lstat(root) == nil, "startup case cleanup incomplete: " .. root)
end

local function with_child(case, callback, launcher)
  local root = validated_case_root(case.name)
  local child
  local case_ok, case_result = xpcall(function()
    child = (launcher or start_child)(case)
    return callback(child)
  end, debug.traceback)

  local errors = {}
  if not case_ok then
    table.insert(errors, case_result)
  end
  if child then
    local stop_ok, stop_error = xpcall(function()
      stop_child(child)
    end, debug.traceback)
    if not stop_ok then
      table.insert(errors, stop_error)
    end
  end
  if vim.uv.fs_lstat(root) then
    local cleanup_ok, cleanup_error = xpcall(function()
      delete_case_root(root)
    end, debug.traceback)
    if not cleanup_ok then
      table.insert(errors, cleanup_error)
    end
  end
  if #errors > 0 then
    error(table.concat(errors, "\n"), 0)
  end
  return case_result
end

local function with_tui_child(case, callback)
  local root = validated_case_root(case.name)
  local child
  local case_ok, case_result = xpcall(function()
    child = start_tui_child(case)
    return callback(child)
  end, debug.traceback)

  local errors = {}
  if not case_ok then
    table.insert(errors, case_result)
  end
  if child then
    local stop_ok, stop_error = xpcall(function()
      stop_tui_child(child)
    end, debug.traceback)
    if not stop_ok then
      table.insert(errors, stop_error)
    end
  end
  if vim.uv.fs_lstat(root) then
    local cleanup_ok, cleanup_error = xpcall(function()
      delete_case_root(root)
    end, debug.traceback)
    if not cleanup_ok then
      table.insert(errors, cleanup_error)
    end
  end
  if #errors > 0 then
    error(table.concat(errors, "\n"), 0)
  end
  return case_result
end

local function wait_for_vimenter(child, label)
  return wait_child_lua(
    child,
    [[
    if vim.v.vim_did_enter == 1 then
      return {
        filetype = vim.bo.filetype,
        name = vim.fs.normalize(vim.api.nvim_buf_get_name(0)),
      }
    end
    return false
  ]],
    label
  )
end

local function wait_for_starter(child, label)
  return wait_child_lua(
    child,
    [[
    return vim.v.vim_did_enter == 1 and vim.bo.filetype == "ministarter"
  ]],
    label
  )
end

local function inspect_starter(child)
  return child_lua(
    child,
    [[
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local visible, rows = {}, {}
    for index, line in ipairs(lines) do
      local trimmed = vim.trim(line)
      if trimmed ~= "" then
        table.insert(visible, trimmed)
        table.insert(rows, index)
      end
    end
    local p = vim.fn.maparg("f", "n", false, true)
    local r = vim.fn.maparg("r", "n", false, true)
    local q = vim.fn.maparg("q", "n", false, true)
    local ctrl_c = vim.fn.maparg("<C-c>", "n", false, true)
    return {
      filetype = vim.bo.filetype,
      visible = visible,
      rows = rows,
      height = vim.api.nvim_win_get_height(0),
      laststatus = vim.o.laststatus,
      f_buffer = p.buffer,
      r_buffer = r.buffer,
      q_buffer = q.buffer,
      ctrl_c_buffer = ctrl_c.buffer,
    }
  ]]
  )
end

local function inspect_tui_context(child)
  return child_lua(
    child,
    [[
    local clients = {}
    for _, ui in ipairs(vim.api.nvim_list_uis()) do
      local ok, info = pcall(vim.api.nvim_get_chan_info, ui.chan)
      if ok then
        table.insert(clients, {
          chan = ui.chan,
          name = info.client and info.client.name or nil,
          type = info.client and info.client.type or nil,
        })
      end
    end
    return {
      argv = vim.deepcopy(vim.v.argv),
      clients = clients,
    }
  ]]
  )
end

local function assert_builtin_tui_context(state, label)
  assert(vim.tbl_contains(state.argv, "--embed"), label .. " core argv omitted --embed")
  local found = false
  for _, client in ipairs(state.clients) do
    if client.name == "nvim-tui" and client.type == "ui" then
      found = true
      break
    end
  end
  assert(found, label .. " omitted the exact builtin nvim-tui client")
end

local function assert_bare_starter(state, label)
  eq(state.filetype, "ministarter", label .. " filetype")
  local menu = {}
  for _, line in ipairs(state.visible) do
    for _, name in ipairs({ "f  Find files", "r  Recent files", "q  Quit" }) do
      if line:find(name, 1, true) then
        menu[#menu + 1] = name
      end
    end
  end
  eq(menu, { "f  Find files", "r  Recent files", "q  Quit" }, label .. " visible actions")
  eq(state.laststatus, 0, label .. " status row hidden")
  eq(state.f_buffer, 1, label .. " f mapping is buffer-local")
  eq(state.r_buffer, 1, label .. " r mapping is buffer-local")
  eq(state.q_buffer, 1, label .. " q mapping is buffer-local")
  eq(state.ctrl_c_buffer, 1, label .. " Ctrl-C mapping is buffer-local")
end

local function edit_and_inspect(child, path)
  child_lua(child, "vim.cmd.edit(vim.fn.fnameescape(" .. string.format("%q", path) .. "))")
  return wait_child_lua(
    child,
    "local name = vim.fs.normalize(vim.api.nvim_buf_get_name(0)); "
      .. "if name == "
      .. string.format("%q", vim.fs.normalize(path))
      .. " then return { filetype = vim.bo.filetype, laststatus = vim.o.laststatus, name = name } end; "
      .. "return false",
    "edited file state"
  )
end

local fixtures_root = validated_case_root("fixtures")
assert(vim.uv.fs_lstat(fixtures_root) == nil, "startup fixtures already exist")
assert(vim.fn.mkdir(fixtures_root, "p") == 1, "could not create startup live fixtures")

local live_ok, live_error = xpcall(function()
  with_child({ name = "bare" }, function(child)
    wait_for_starter(child, "bare startup")
    assert_bare_starter(inspect_starter(child), "bare launch")

    child_lua(
      child,
      string.format(
        [[
      local fixture = %q
      local project = fixture .. "/project space"
      local ordinary = fixture .. "/ordinary"
      vim.fn.mkdir(project .. "/.git", "p")
      vim.fn.mkdir(project .. "/src", "p")
      vim.fn.mkdir(project .. "-sibling", "p")
      vim.fn.mkdir(ordinary, "p")
      local inside = project .. "/src/inside.lua"
      local outside = project .. "-sibling/outside.lua"
      vim.fn.writefile({ "inside" }, inside)
      vim.fn.writefile({ "outside" }, outside)
      local previous_cwd, previous_history = vim.fn.getcwd(), vim.v.oldfiles
      local core = require("fzf-lua.core")
      local original_exec = core.fzf_exec
      local calls = {}
      core.fzf_exec = function(contents, opts)
        local call = { cwd = opts.cwd, entries = {} }
        calls[#calls + 1] = call
        if type(contents) == "function" then
          local complete = false
          contents(function(entry, resume)
            if entry == nil then complete = true; return end
            call.entries[#call.entries + 1] = entry
            vim.schedule(function() resume(nil) end)
          end)
          assert(vim.wait(1000, function() return complete end), "history collection timed out")
        end
      end
      local ok, err = xpcall(function()
        vim.cmd.lcd(vim.fn.fnameescape(project .. "/src"))
        vim.v.oldfiles = { outside, inside, project .. "/missing.lua" }
        local files = vim.fn.maparg("f", "n", false, true).callback
        local recent = vim.fn.maparg("r", "n", false, true).callback
        files()
        recent()
        assert(calls[1].cwd == project and calls[2].cwd == project,
          "starter actions must use the repository root from a subdirectory")
        assert(#calls[2].entries == 1 and calls[2].entries[1]:find("inside.lua", 1, true),
          "scoped history must exclude missing files and similarly prefixed sibling projects")
        assert(vim.fn.getcwd() == project .. "/src", "actions changed the editor directory")
        vim.v.oldfiles = {}
        files()
        assert(calls[3].cwd == project, "Find files must work without history")
        vim.cmd.lcd(vim.fn.fnameescape(ordinary))
        recent()
        assert(calls[4].cwd == ordinary and #calls[4].entries == 0,
          "ordinary directories use their own empty scoped history")
        assert(vim.fn.getcwd() == ordinary, "ordinary directory changed")
      end, debug.traceback)
      core.fzf_exec = original_exec
      vim.v.oldfiles = previous_history
      vim.cmd.lcd(vim.fn.fnameescape(previous_cwd))
      assert(ok, err)
    ]],
        child.root
      )
    )

    child_lua(
      child,
      [[
      vim.cmd('belowright split')
      _G.navigation_bottom = vim.api.nvim_get_current_win()
      vim.cmd('wincmd k')
      _G.navigation_top = vim.api.nvim_get_current_win()
      assert(_G.navigation_top ~= _G.navigation_bottom, 'starter split fixture')
    ]]
    )
    child_input(child, "<M-j>")
    wait_child_lua(
      child,
      [[return vim.api.nvim_get_current_win() == _G.navigation_bottom]],
      "Alt-j moves down between starter windows"
    )
    child_input(child, "<M-k>")
    wait_child_lua(
      child,
      [[return vim.api.nvim_get_current_win() == _G.navigation_top]],
      "Alt-k moves up between starter windows"
    )
    child_lua(child, [[vim.cmd('only')]])

    child_lua(
      child,
      [[
      for _, reload in ipairs({ false, true }) do
        if reload then
          vim.cmd.colorscheme("tokyonight-night")
        end
        local selected = vim.api.nvim_get_hl(0, { name = "MiniStarterCurrent", link = false })
        local item = vim.api.nvim_get_hl(0, { name = "MiniStarterItem", link = false })
        assert(selected.bg ~= nil and selected.bg ~= item.bg,
          "selected starter item needs a distinct background, including after colorscheme reload")
      end
    ]]
    )

    local regular = vim.fs.joinpath(child.root, "restored.lua")
    write_file(regular, { "return true" })
    local restored = edit_and_inspect(child, regular)
    eq(restored.laststatus, 3, "standalone status restored after starter")
    assert(restored.filetype ~= "ministarter", "regular file retained starter filetype")
    eq(restored.name, vim.fs.normalize(regular), "regular file becomes current")
    eq(
      child_lua(child, [[return vim.fn.maparg("<C-c>", "n")]]),
      "",
      "regular file keeps native Ctrl-C"
    )
  end)

  with_child({
    name = "tmux",
    environment = {
      "TMUX=/tmp/nvim-ministarter-project-home/nonexistent,1,1",
      "TMUX_PANE=invalid",
    },
  }, function(child)
    wait_for_starter(child, "tmux bare startup")
    local state = inspect_starter(child)
    eq(state.filetype, "ministarter", "tmux bare launch filetype")
    eq(state.laststatus, 0, "tmux starter row hidden")

    local regular = vim.fs.joinpath(child.root, "tmux.lua")
    write_file(regular, { "return true" })
    local restored = edit_and_inspect(child, regular)
    eq(restored.laststatus, 3, "invalid tmux restores native status after starter")
    assert(restored.filetype ~= "ministarter", "tmux regular file retained starter filetype")
  end)

  local regular_file = vim.fs.joinpath(fixtures_root, "regular.lua")
  local project_directory = vim.fs.joinpath(fixtures_root, "project")
  local session_file = vim.fs.joinpath(fixtures_root, "Session.vim")
  local quickfix_file = vim.fs.joinpath(fixtures_root, "quickfix.txt")
  local tag_fixture = vim.fs.joinpath(fixtures_root, "tag")
  local tag_file = vim.fs.joinpath(tag_fixture, "target.lua")
  write_file(regular_file, { "return true" })
  make_directory(project_directory)
  write_file(session_file, { "let g:startup_session = 1" })
  write_file(quickfix_file, { regular_file .. ":1:1: startup fixture" })
  write_file(tag_file, { "local StartupTarget = true", "return StartupTarget" })
  write_file(vim.fs.joinpath(tag_fixture, "tags"), {
    "StartupTarget\ttarget.lua\t/^local StartupTarget = true$/",
  })

  with_tui_child({ name = "tui-bare" }, function(child)
    wait_for_starter(child, "configured TUI bare startup")
    assert_builtin_tui_context(inspect_tui_context(child), "configured TUI bare startup")
    assert_bare_starter(inspect_starter(child), "configured TUI bare launch")
  end)

  with_tui_child({ name = "tui-file", arguments = { regular_file } }, function(child)
    local state = wait_for_vimenter(child, "configured TUI file startup")
    assert(state.filetype ~= "ministarter", "configured TUI file unexpectedly opened MiniStarter")
    eq(state.name, vim.fs.normalize(regular_file), "configured TUI file target becomes current")
    local context = inspect_tui_context(child)
    assert_builtin_tui_context(context, "configured TUI file startup")
    assert(
      vim.tbl_contains(context.argv, regular_file),
      "configured TUI core argv omitted file target"
    )
  end)

  local nonbare_cases = {
    { name = "file", arguments = { regular_file } },
    { name = "directory", arguments = { project_directory } },
    { name = "stdin", arguments = { "-" }, stdin = "stdin text\n" },
    { name = "command-c", arguments = { "-c", "let g:startup_probe = 1" } },
    { name = "command-plus", arguments = { "+let g:startup_probe = 1" } },
    { name = "session", arguments = { "-S", session_file } },
    { name = "quickfix", arguments = { "-q", quickfix_file } },
    { name = "tag", arguments = { "-t", "StartupTarget" }, cwd = tag_fixture },
  }

  for _, case in ipairs(nonbare_cases) do
    with_child(case, function(child)
      local state = wait_for_vimenter(child, case.name .. " startup")
      assert(state.filetype ~= "ministarter", case.name .. " unexpectedly opened MiniStarter")
      if case.name == "file" then
        eq(state.name, vim.fs.normalize(regular_file), "file target becomes current")
        local filetypes = child_lua(
          child,
          [[
          local current = vim.api.nvim_get_current_buf()
          vim.api.nvim_buf_delete(current, { force = true })
          local cycled = false
          vim.schedule(function()
            cycled = true
          end)
          assert(vim.wait(1000, function()
            return cycled
          end, 10), "event cycle timed out")
          local result = {}
          for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_loaded(bufnr) then
              table.insert(result, vim.bo[bufnr].filetype)
            end
          end
          return result
        ]]
        )
        assert(
          not vim.tbl_contains(filetypes, "ministarter"),
          "closing the final file reopened MiniStarter"
        )
      end
    end)
  end

  with_child({ name = "remote-server" }, function(child)
    wait_for_vimenter(child, "remote server startup")
    local target = vim.fs.joinpath(child.root, "remote-target.lua")
    write_file(target, { "return true" })
    local remote_result = vim
      .system({
        "env",
        "-u",
        "TMUX",
        "-u",
        "TMUX_PANE",
        "-u",
        "NVIM_APPNAME",
        "NVIM_LOG_FILE=" .. vim.fs.joinpath(child.root, "remote-client.log"),
        "nvim",
        "--server",
        child.socket,
        "--remote",
        target,
      }, { cwd = child.root, text = true })
      :wait(10000)
    assert(
      remote_result.code == 0 and remote_result.signal == 0,
      remote_result.stderr or remote_result.stdout or "remote client failed"
    )

    local remote_state = wait_child_lua(
      child,
      "local target = "
        .. string.format("%q", vim.fs.normalize(target))
        .. "; local found = false; local filetypes = {}; "
        .. "for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do "
        .. "if vim.api.nvim_buf_is_loaded(bufnr) then "
        .. "local name = vim.fs.normalize(vim.api.nvim_buf_get_name(bufnr)); "
        .. "found = found or name == target; table.insert(filetypes, vim.bo[bufnr].filetype); end; end; "
        .. "if found then return { found = true, filetypes = filetypes, configured = _G.MiniStarter ~= nil } end; "
        .. "return false",
      "remote target"
    )
    eq(remote_state.found, true, "remote target appears in server")
    eq(remote_state.configured, false, "remote server remains unconfigured")
    assert(
      not vim.tbl_contains(remote_state.filetypes, "ministarter"),
      "remote intent created MiniStarter"
    )
  end, start_none_child)

  local function fixture_git(directory, arguments)
    local argv =
      { "git", "-c", "user.name=Startup fixture", "-c", "user.email=startup@example.invalid" }
    vim.list_extend(argv, arguments)
    local result = vim.system(argv, { cwd = directory, text = true }):wait(5000)
    assert(result.code == 0, result.stderr or "Git fixture failed")
  end
  for _, kind in ipairs({ "clean", "dirty", "dense", "detached", "unborn" }) do
    local directory = vim.fs.joinpath(fixtures_root, "git-" .. kind)
    make_directory(directory)
    fixture_git(directory, { "init", "--initial-branch=main" })
    if kind ~= "unborn" then
      write_file(vim.fs.joinpath(directory, "tracked.lua"), { "initial" })
      fixture_git(directory, { "add", "." })
      fixture_git(directory, { "commit", "-m", "Startup fixture commit" })
    end
    local expected = { "main", "Working tree clean", "Startup fixture commit" }
    if kind == "dirty" then
      write_file(vim.fs.joinpath(directory, "tracked.lua"), { "staged" })
      fixture_git(directory, { "add", "." })
      write_file(vim.fs.joinpath(directory, "tracked.lua"), { "unstaged" })
      write_file(vim.fs.joinpath(directory, "src", "new.lua"), { "new" })
      expected = { "MM", "??", "src/", "2 changed" }
    elseif kind == "dense" then
      for index = 1, 15 do
        write_file(vim.fs.joinpath(directory, "file-" .. index), { "new" })
      end
      expected = { "15 changed", "more paths" }
    elseif kind == "detached" then
      fixture_git(directory, { "checkout", "--detach" })
      expected = { "detached HEAD", "Working tree clean" }
    elseif kind == "unborn" then
      expected = { "main", "No commits yet", "Working tree clean" }
    end
    with_child({ name = "git-" .. kind, cwd = directory }, function(child)
      wait_for_starter(child, "Git " .. kind .. " startup")
      child_lua(
        child,
        [[vim.o.columns = 120; vim.o.lines = 45; vim.api.nvim_exec_autocmds("VimResized", {})]]
      )
      for _, text in ipairs(expected) do
        wait_child_lua(
          child,
          "local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\\n'); return text:find("
            .. string.format("%q", text)
            .. ", 1, true) ~= nil",
          "Git " .. kind .. " displays " .. text
        )
      end
      assert_bare_starter(inspect_starter(child), "Git " .. kind .. " menu")
    end)
  end

  for _, case in ipairs({
    { name = "quit-enter", keys = "k<CR>" },
    { name = "quit-ctrl-c", keys = "<C-c>" },
  }) do
    with_child({ name = case.name }, function(child)
      wait_for_starter(child, case.name .. " startup")
      child_input(child, case.keys)
      assert(
        vim.wait(5000, function()
          return child.process:is_closing()
        end, 20),
        case.name .. " did not exit"
      )
      eq(child.process:wait(5000).code, 0, case.name .. " exits normally")
    end)
  end

  with_child({ name = "ctrl-c-unsaved" }, function(child)
    wait_for_starter(child, "Ctrl-C unsaved startup")
    child_lua(
      child,
      [[
      vim.o.hidden, vim.o.confirm = true, false
      vim.o.autowrite, vim.o.autowriteall = false, false
      vim.cmd.enew()
      _G.startup_unsaved = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_name(0, vim.fn.getcwd() .. "/unsaved.txt")
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "keep this unsaved edit" })
      vim.cmd.enew()
      require("mini.starter").open()
      vim.v.errmsg = ""
    ]]
    )
    wait_for_starter(child, "starter with hidden unsaved buffer")
    child_input(child, "<C-c>")
    wait_child_lua(child, [[return vim.v.errmsg ~= ""]], "Ctrl-C reports unsafe quit")
    eq(
      child_lua(
        child,
        [[return {
        modified = vim.bo[_G.startup_unsaved].modified,
        lines = vim.api.nvim_buf_get_lines(_G.startup_unsaved, 0, -1, false),
      }]]
      ),
      { modified = true, lines = { "keep this unsaved edit" } },
      "Ctrl-C preserves unsaved hidden buffer and running editor"
    )
  end)

  with_child({ name = "ctrl-c-split" }, function(child)
    wait_for_starter(child, "Ctrl-C split startup")
    child_lua(child, [[vim.cmd.split()]])
    child_input(child, "<C-c>")
    eq(
      wait_child_lua(child, [[return #vim.api.nvim_list_wins() == 1]], "Ctrl-C closes one split"),
      true,
      "Ctrl-C preserves normal quit behavior with multiple windows"
    )
  end)

  with_child({ name = "native-mechanics" }, function(child)
    wait_for_vimenter(child, "native mechanics startup")
    local checkout = vim.fs.joinpath(data_home, "nvim", "lazy", "mini.starter")
    assert_directory(checkout, "MiniStarter checkout")
    child_lua(child, "vim.opt.runtimepath:prepend(" .. string.format("%q", checkout) .. ")")
    child_lua(child, "vim.opt.runtimepath:prepend(" .. string.format("%q", nvim_root) .. ")")
    child_lua(
      child,
      [[
      _G.startup_requests, _G.startup_recent = {}, 0
      local git = require("ui.startup.git")
      git.collect = function(directory, callback)
        local request = { callback = callback, directory = directory }
        function request:cancel() self.canceled = true end
        table.insert(_G.startup_requests, request)
        return request
      end
      package.loaded["navigation.pickers"] = { recent = function() _G.startup_recent = _G.startup_recent + 1 end }
      require("ui.statusline").setup()
      require("ui.startup").setup()
      vim.o.columns = 120
      require("mini.starter").open()
    ]]
    )
    wait_for_starter(child, "native first open")
    local function selection()
      return child_lua(
        child,
        [[
        local starter = require("mini.starter")
        local cursor = vim.api.nvim_win_get_cursor(0)
        local selected, pointers, active, menu_rows = nil, 0, nil, {}
        for _, item in ipairs(starter.content_to_items()) do
          menu_rows[#menu_rows + 1] = item._cursorpos[1]
          if vim.deep_equal(item._cursorpos, cursor) then selected = item.name end
        end
        for row, line in ipairs(starter.get_content()) do
          local column = 0
          for _, unit in ipairs(line) do
            if unit.type == "pointer" and unit.string == "> " then
              pointers = pointers + 1
              active = { row, column + 2 }
            end
            column = column + #unit.string
          end
        end
        return { name = selected, pointers = pointers, matches = vim.deep_equal(cursor, active) and active ~= nil
            and vim.api.nvim_buf_get_lines(0, active[1] - 1, active[1], false)[1]:sub(active[2] - 1, active[2]) == "> ",
          requests = #_G.startup_requests, recent = _G.startup_recent, menu_rows = menu_rows }
      ]]
      )
    end
    local function assert_selection(name, label)
      local state = selection()
      eq(state.name, name, label .. " selected action")
      eq(state.pointers, 1, label .. " one visible pointer")
      eq(state.matches, true, label .. " pointer matches row and byte column")
      return state
    end
    assert_selection("f  Find files", "initial")
    child_input(child, "k")
    wait_child_lua(child, [[return vim.api.nvim_win_get_cursor(0)[1] > 0]], "native key delivery")
    -- RPC requests run after queued input, so inspections observe native selection.
    assert_selection("q  Quit", "backward wrap")
    child_input(child, "j")
    assert_selection("f  Find files", "forward wrap")
    child_input(child, "<Down>")
    assert_selection("r  Recent files", "arrow next")
    child_input(child, "<CR>")
    eq(
      wait_child_lua(child, [[return _G.startup_recent == 1]], "native Recent Enter"),
      true,
      "Enter invokes Recent once"
    )
    child_lua(
      child,
      [[
      _G.startup_requests[1].callback({ kind = "repository", name = "fixture", root = "/fixture",
        branch = { head = "main" }, history = {}, changes = {}, counts = { total = 0 } })
    ]]
    )
    assert_selection("r  Recent files", "async completion")
    child_lua(child, [[vim.o.columns = 115; vim.api.nvim_exec_autocmds("VimResized", {})]])
    local narrow_rows = assert_selection("r  Recent files", "narrow resize").menu_rows
    eq(narrow_rows[1], narrow_rows[3], "115-column menu stays on a shared row")
    child_input(child, "<Down>")
    assert_selection("q  Quit", "shared-row Quit")
    child_lua(child, [[vim.o.columns = 116; vim.api.nvim_exec_autocmds("VimResized", {})]])
    local wide_state = assert_selection("q  Quit", "wide resize")
    eq(wide_state.requests, 1, "resize never recollects Git")
    assert(wide_state.menu_rows[1] < wide_state.menu_rows[3], "116-column menu uses separate rows")
    child_lua(
      child,
      [[
      _G.startup_window = vim.api.nvim_get_current_win()
      vim.cmd.vnew()
      vim.api.nvim_win_set_width(_G.startup_window, 39)
    ]]
    )
    wait_child_lua(
      child,
      [[
      local buffer = vim.api.nvim_win_get_buf(_G.startup_window)
      local width = vim.api.nvim_win_get_width(_G.startup_window)
      for _, line in ipairs(vim.api.nvim_buf_get_lines(buffer, 0, -1, false)) do
        if vim.fn.strdisplaywidth(line) > width then return false end
      end
      return true
    ]],
      "window resize fits cached Starter content without entering its buffer"
    )
    eq(
      child_lua(child, [[return { vim.o.laststatus, #_G.startup_requests }]]),
      { 3, 1 },
      "background window resize preserves the regular statusline and cached Git request"
    )
    child_lua(child, [[vim.cmd.close()]])
    eq(
      assert_selection("q  Quit", "closing the adjacent split").requests,
      1,
      "closing an adjacent split does not collect Git"
    )
    child_lua(child, [[vim.cmd.vsplit(); vim.api.nvim_win_set_width(0, 80)]])
    wait_child_lua(
      child,
      [[
      local buffer = vim.api.nvim_get_current_buf()
      for _, window in ipairs(vim.fn.win_findbuf(buffer)) do
        local width = vim.api.nvim_win_get_width(window)
        for _, line in ipairs(vim.api.nvim_buf_get_lines(buffer, 0, -1, false)) do
          if vim.fn.strdisplaywidth(line) > width then return false end
        end
      end
      return true
    ]],
      "shared Starter content fits both asymmetric windows"
    )
    eq(
      assert_selection("q  Quit", "shared Starter resize").requests,
      1,
      "shared resize uses cached Git"
    )
    child_lua(child, [[vim.cmd.close()]])
    assert_selection("q  Quit", "closing one shared Starter window")
    child_lua(child, [[require("mini.starter").open()]])
    assert_selection("f  Find files", "second buffer")
    child_lua(child, [[_G.startup_requests[1].callback({ kind = "non_repository" })]])
    assert_selection("f  Find files", "closed-buffer late completion")
    child_lua(
      child,
      [[
      vim.cmd.vnew()
      assert(vim.bo.filetype ~= "ministarter" and vim.o.laststatus == 3)
      _G.startup_requests[2].callback({ kind = "non_repository" })
    ]]
    )
    eq(
      child_lua(child, [[return vim.o.laststatus]]),
      3,
      "background Starter completion preserves current regular statusline"
    )
    child_lua(child, [[vim.cmd.close(); require("mini.starter").open()]])
    assert_selection("f  Find files", "pending resize buffer")
    child_input(child, "j")
    assert_selection("r  Recent files", "before queued resize completion")
    child_lua(
      child,
      [[
      vim.schedule(function()
        vim.o.columns = 70
        vim.api.nvim_exec_autocmds("VimResized", {})
      end)
      vim.schedule(function()
        _G.startup_requests[3].callback({ kind = "non_repository" })
        vim.schedule(function() _G.startup_resize_race_done = true end)
      end)
    ]]
    )
    wait_child_lua(child, [[return _G.startup_resize_race_done]], "queued resize completion")
    assert_selection("r  Recent files", "completion before resize reconciliation")
    child_lua(child, [[require("mini.starter").open()]])
    assert_selection("f  Find files", "pending quit buffer")
    child_input(child, "q")
    assert(
      vim.wait(5000, function()
        return child.process:is_closing()
      end, 20),
      "normal q did not exit while Git pending"
    )
    eq(child.process:wait(5000).code, 0, "normal q exits successfully")
  end, start_none_child)
end, debug.traceback)

local fixtures_cleanup_ok, fixtures_cleanup_error = xpcall(function()
  delete_case_root(fixtures_root)
end, debug.traceback)
if not live_ok then
  if not fixtures_cleanup_ok then
    error(live_error .. "\n" .. fixtures_cleanup_error, 0)
  end
  error(live_error, 0)
end
assert(fixtures_cleanup_ok, fixtures_cleanup_error)

print("Configured MiniStarter startup matrix: ok")
