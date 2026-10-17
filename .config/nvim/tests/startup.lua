local function eq(actual, expected, label)
  assert(
    vim.deep_equal(actual, expected),
    string.format("%s\nexpected: %s\nactual: %s", label, vim.inspect(expected), vim.inspect(actual))
  )
end

local startup = require("ui.startup")
local test = startup._test

for _, name in ipairs({
  "discover_projects",
  "has_editing_intent",
  "is_bare_launch",
  "new",
  "project_is_current",
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
    status_calls = {},
    picker_calls = {},
    notifications = {},
    current_buffer = 9,
    filetypes = { [9] = "ministarter" },
    context = vim.deepcopy(context or bare_context),
    context_calls = 0,
    find_root_calls = 0,
    project_available = true,
    project_history_available = true,
    project_file = "/home/src/project/main.lua",
    project_root = "/home/src/project",
    cwd = "/workspace",
    set_current_dir_calls = {},
    action_calls = {},
    fail_set_current_dir = false,
    requests = {},
    scheduled = {},
    timers = {},
    refreshes = {},
    selected = 1,
    pointers = {},
    composed = {},
  }
  harness.oldfiles = { harness.project_file }

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
    recent = function()
      table.insert(harness.picker_calls, { name = "recent" })
    end,
    projects = function(projects, on_select)
      table.insert(harness.picker_calls, {
        name = "projects",
        projects = vim.deepcopy(projects),
      })
      harness.project_callback = on_select
    end,
    files = function(root)
      table.insert(harness.picker_calls, { name = "files", root = root })
      table.insert(harness.action_calls, { name = "files", root = root })
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
    oldfiles = function()
      return harness.oldfiles
    end,
    getcwd = function()
      return harness.cwd
    end,
    set_current_dir = function(path)
      table.insert(harness.set_current_dir_calls, path)
      table.insert(harness.action_calls, { name = "set_current_dir", root = path })
      if harness.fail_set_current_dir and path == harness.project_root then
        harness.cwd = path
        error("simulated cwd failure")
      end
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
    project_dependencies = {
      find_root = function(path)
        harness.find_root_calls = harness.find_root_calls + 1
        if path == harness.project_file and harness.project_history_available then
          return harness.project_root
        end
      end,
      home = function()
        return "/home"
      end,
      lstat = function(path)
        if path == harness.project_root and harness.project_available then
          return { type = "directory" }
        end
      end,
      normalize = function(path)
        return path
      end,
      readable = function(path)
        return path == harness.project_file and harness.project_history_available
      end,
      realpath = function(path)
        if path == "/home" then
          return path
        end
        if path == harness.project_root and harness.project_available then
          return path
        end
      end,
      relpath = function(base, path)
        eq({ base, path }, { "/home", harness.project_root }, "project label paths")
        return "src/project"
      end,
      stat = function(path)
        if path == harness.project_file and harness.project_history_available then
          return { type = "file" }
        end
        if path == harness.project_root and harness.project_available then
          return { type = "directory" }
        end
      end,
    },
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

local function warning(message)
  return {
    message = message,
    level = vim.log.levels.WARN,
    options = { title = "Neovim startup" },
  }
end

local function picker_call_count(harness, name)
  local count = 0
  for _, call in ipairs(harness.picker_calls) do
    if call.name == name then
      count = count + 1
    end
  end
  return count
end

local harness = new_controller_harness()
local controller = test.new(harness.dependencies)
assert(controller:setup() == controller, "setup must return its controller")
assert(controller:setup() == controller, "repeated setup must return its controller")
eq(#harness.starter_setup_calls, 1, "MiniStarter setup once")
eq(#harness.augroup_calls, 1, "one startup augroup")
eq(
  vim.tbl_map(function(item)
    return item.name
  end, harness.starter_setup_calls[1].items),
  { "p  Projects", "r  Recent files", "q  Quit" },
  "approved menu preserves all three actions"
)
eq(#harness.autocmds, 8, "startup event routes")
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
    "p  Projects",
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
eq(harness.find_root_calls, 0, "project discovery waits for its action")

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
eq(#harness.mappings, 11, "MiniStarterOpened action and native navigation mappings")
eq(
  vim.tbl_map(function(mapping)
    return { mapping.bufnr, mapping.lhs, mapping.description }
  end, harness.mappings),
  {
    { harness.current_buffer, "p", "Open projects" },
    { harness.current_buffer, "r", "Open recent files" },
    { harness.current_buffer, "q", "Quit" },
    { harness.current_buffer, "j", "Next startup item" },
    { harness.current_buffer, "<Down>", "Next startup item" },
    { harness.current_buffer, "<C-n>", "Next startup item" },
    { harness.current_buffer, "<M-j>", "Next startup item" },
    { harness.current_buffer, "k", "Previous startup item" },
    { harness.current_buffer, "<Up>", "Previous startup item" },
    { harness.current_buffer, "<C-p>", "Previous startup item" },
    { harness.current_buffer, "<M-k>", "Previous startup item" },
  },
  "exact buffer-local startup mappings"
)
assert(harness.mappings[1].callback == options.items[1].action, "project action identity changed")
assert(harness.mappings[2].callback == options.items[2].action, "recent action identity changed")

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
eq(harness.picker_calls, { { name = "recent" } }, "recent action calls only recent picker")
eq(harness.find_root_calls, 0, "recent action does not discover projects")

local empty_harness = new_controller_harness()
local empty_controller = test.new(empty_harness.dependencies)
empty_controller:setup()
empty_harness.oldfiles = {}
empty_harness.starter_setup_calls[1].items[1].action()
eq(empty_harness.notifications, { warning("No recent projects found") }, "empty project warning")
eq(empty_harness.picker_calls, {}, "empty project list opens no picker")

local cancel_harness = new_controller_harness()
local cancel_controller = test.new(cancel_harness.dependencies)
cancel_controller:setup()
cancel_harness.starter_setup_calls[1].items[1].action()
eq(cancel_harness.find_root_calls, 1, "project discovery runs when the action executes")
eq(picker_call_count(cancel_harness, "projects"), 1, "project picker opens once")
eq(picker_call_count(cancel_harness, "files"), 0, "cancelled project picker opens no files")
eq(cancel_harness.cwd, "/workspace", "project cancellation preserves cwd")
assert(type(cancel_harness.project_callback) == "function", "project picker callback missing")

local selected_harness = new_controller_harness()
local selected_controller = test.new(selected_harness.dependencies)
selected_controller:setup()
selected_harness.starter_setup_calls[1].items[1].action()
selected_harness.project_callback(selected_harness.project_root)
eq(selected_harness.action_calls, {
  { name = "set_current_dir", root = selected_harness.project_root },
  { name = "files", root = selected_harness.project_root },
}, "selected project changes cwd before opening files")
eq(selected_harness.cwd, selected_harness.project_root, "selected project becomes cwd")
eq(selected_harness.notifications, {}, "current project selection stays silent")

local disappeared_harness = new_controller_harness()
local disappeared_controller = test.new(disappeared_harness.dependencies)
disappeared_controller:setup()
disappeared_harness.starter_setup_calls[1].items[1].action()
disappeared_harness.project_available = false
disappeared_harness.project_callback(disappeared_harness.project_root)
eq(disappeared_harness.notifications, {
  warning("Recent project is no longer available: ~/src/project"),
}, "disappeared project warning")
eq(disappeared_harness.cwd, "/workspace", "disappeared project preserves cwd")
eq(picker_call_count(disappeared_harness, "files"), 0, "disappeared project opens no files")

local unknown_harness = new_controller_harness()
local unknown_controller = test.new(unknown_harness.dependencies)
unknown_controller:setup()
unknown_harness.starter_setup_calls[1].items[1].action()
unknown_harness.project_callback("/home/src/not-offered")
eq(unknown_harness.action_calls, {}, "unknown project identity does nothing")
eq(unknown_harness.notifications, {}, "unknown project identity stays silent")
eq(unknown_harness.cwd, "/workspace", "unknown project identity preserves cwd")
eq(picker_call_count(unknown_harness, "files"), 0, "unknown project opens no files")

local failure_harness = new_controller_harness()
local failure_controller = test.new(failure_harness.dependencies)
failure_controller:setup()
failure_harness.starter_setup_calls[1].items[1].action()
failure_harness.fail_set_current_dir = true
failure_harness.project_callback(failure_harness.project_root)
eq(failure_harness.set_current_dir_calls, {
  failure_harness.project_root,
  "/workspace",
}, "failed cwd change restores the previous cwd")
eq(failure_harness.cwd, "/workspace", "failed cwd change preserves cwd")
eq(failure_harness.notifications, {
  warning("Recent project is no longer available: ~/src/project"),
}, "failed cwd change warning")
eq(picker_call_count(failure_harness, "files"), 0, "failed cwd change opens no files")

-- These checks catch stale callbacks, uncanceled work, overlapping focus requests,
-- and losing an action when native MiniStarter repositions its items.
local lifecycle = new_controller_harness()
local lifecycle_controller = test.new(lifecycle.dependencies)
lifecycle_controller:setup()
lifecycle:invoke("User")
eq(#lifecycle.requests, 1, "opening starts one asynchronous request")
eq(lifecycle.requests[1].directory, "/workspace", "request captures the buffer directory")
lifecycle:flush()
lifecycle.mappings[4].callback()
eq(lifecycle.selected, 2, "j selects Recent files natively")
lifecycle.mappings[4].callback()
lifecycle.mappings[4].callback()
eq(lifecycle.selected, 1, "j cycles back to Projects")
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
local restore_navigation = new_controller_harness()
test.new(restore_navigation.dependencies):setup()
restore_navigation:invoke("User")
restore_navigation:flush()
restore_navigation.mappings[4].callback()
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

local function with_project_fixture(callback)
  local live_paths = get_startup_live_paths()
  local fixture = live_paths and vim.fs.joinpath(live_paths.test_root, "pure-project-fixture")
    or vim.fs.normalize(vim.fn.tempname())
  assert(type(fixture) == "string" and fixture:sub(1, 1) == "/", "fixture must be absolute")
  assert(fixture ~= "/" and fixture ~= "/tmp", "fixture cleanup target is too broad")
  assert(vim.uv.fs_lstat(fixture) == nil, "fixture path already exists")

  local allowed_root = live_paths and live_paths.test_root or vim.env.DOTFILES_STARTUP_TEST_ROOT
  if type(allowed_root) == "string" and allowed_root ~= "" then
    allowed_root = vim.fs.normalize(allowed_root)
    assert(path_is_within(fixture, allowed_root), "fixture escaped the allowed startup test root")
  end

  assert(vim.fn.mkdir(fixture, "p") == 1, "could not create startup fixture")
  local ok, result = xpcall(function()
    return callback(fixture)
  end, debug.traceback)

  assert(fixture ~= "/" and fixture ~= "/tmp", "fixture cleanup target changed")
  if allowed_root then
    assert(path_is_within(fixture, allowed_root), "fixture cleanup escaped the allowed root")
  end
  local cleanup_result = vim.fn.delete(fixture, "rf")
  assert(cleanup_result == 0, "could not remove startup fixture")
  if not ok then
    error(result, 0)
  end
  return result
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

local symlink_result = "unsupported"

with_project_fixture(function(fixture)
  local home = vim.fs.joinpath(fixture, "home")
  local git_project = vim.fs.joinpath(home, "src", "git-project")
  local git_file = vim.fs.joinpath(git_project, "src", "recent.lua")
  local unreadable_file = vim.fs.joinpath(git_project, "src", "unreadable.lua")
  local worktree = vim.fs.joinpath(home, "src", "worktree")
  local worktree_file = vim.fs.joinpath(worktree, "lib", "work.lua")
  local jj_outer = vim.fs.joinpath(home, "src", "jj-outer")
  local jj_outer_file = vim.fs.joinpath(jj_outer, "outer.lua")
  local nested = vim.fs.joinpath(jj_outer, "nested")
  local nested_file = vim.fs.joinpath(nested, "main.lua")
  local outside = vim.fs.joinpath(fixture, "outside")
  local plain_file = vim.fs.joinpath(outside, "plain.lua")
  local missing_file = vim.fs.joinpath(fixture, "missing.lua")

  make_directory(vim.fs.joinpath(git_project, ".git"))
  write_file(git_file)
  write_file(unreadable_file)
  write_file(vim.fs.joinpath(worktree, ".git"), { "gitdir: ../bare/worktrees/demo" })
  write_file(worktree_file)
  make_directory(vim.fs.joinpath(jj_outer, ".jj"))
  write_file(jj_outer_file)
  make_directory(vim.fs.joinpath(nested, ".git"))
  write_file(nested_file)
  write_file(plain_file)

  local root = require("navigation.root")
  local inherited_fixture_root = root.find(fixture)
  local notifications = {}
  local dependencies = {
    find_root = function(path)
      local found = root.find(path)
      if path == plain_file and found == inherited_fixture_root then
        return nil
      end
      return found
    end,
    home = function()
      return home
    end,
    lstat = vim.uv.fs_lstat,
    normalize = vim.fs.normalize,
    notify = function(...)
      table.insert(notifications, { ... })
    end,
    readable = function(path)
      return path ~= unreadable_file and vim.fn.filereadable(path) == 1
    end,
    realpath = vim.uv.fs_realpath,
    relpath = vim.fs.relpath,
    stat = vim.uv.fs_stat,
  }

  local canonical_nested = assert(vim.uv.fs_realpath(nested), "nested realpath missing")
  local canonical_git = assert(vim.uv.fs_realpath(git_project), "Git realpath missing")
  local canonical_worktree = assert(vim.uv.fs_realpath(worktree), "worktree realpath missing")
  local canonical_jj_outer = assert(vim.uv.fs_realpath(jj_outer), "Jujutsu realpath missing")
  local expected = {
    { label = "~/src/jj-outer/nested", root = canonical_nested },
    { label = "~/src/git-project", root = canonical_git },
    { label = "~/src/worktree", root = canonical_worktree },
    { label = "~/src/jj-outer", root = canonical_jj_outer },
  }
  local history = {
    nested_file,
    git_file,
    nested_file,
    worktree_file,
    jj_outer_file,
    plain_file,
    missing_file,
    "https://example.invalid/file.lua",
    "relative.lua",
    "",
  }

  eq(test.discover_projects(history, dependencies), expected, "ordered canonical projects")
  eq(notifications, {}, "project discovery remains silent")

  local symlink_root = vim.fs.joinpath(home, "src", "git-project-link")
  local linked, link_error = vim.uv.fs_symlink(git_project, symlink_root, { dir = true })
  if linked then
    symlink_result = "supported"
    local history_with_link = vim.deepcopy(history)
    table.insert(history_with_link, 2, vim.fs.joinpath(symlink_root, "src", "recent.lua"))
    eq(
      test.discover_projects(history_with_link, dependencies),
      expected,
      "symlink roots canonicalize and deduplicate"
    )
  else
    symlink_result = "unsupported: " .. tostring(link_error)
  end

  eq(
    test.discover_projects({
      unreadable_file,
      missing_file,
      git_project,
      "https://example.invalid/file.lua",
      "relative.lua",
      plain_file,
      "",
    }, dependencies),
    {},
    "invalid history entries are skipped"
  )
  eq(notifications, {}, "invalid history entries emit no notification")
end)

local selected_root = "/canonical/project"
local function revalidate(lstat_result, realpath_result)
  return test.project_is_current(selected_root, {
    lstat = function(path)
      eq(path, selected_root, "revalidation lstat path")
      return lstat_result
    end,
    normalize = vim.fs.normalize,
    realpath = function(path)
      eq(path, selected_root, "revalidation realpath path")
      return realpath_result
    end,
  })
end

eq(revalidate({ type = "directory" }, selected_root), true, "current canonical project")
eq(revalidate(nil, nil), false, "missing project is rejected")
eq(revalidate({ type = "file" }, selected_root), false, "regular file project is rejected")
eq(revalidate({ type = "link" }, selected_root), false, "replaced symlink project is rejected")
eq(
  revalidate({ type = "directory" }, "/replacement/project"),
  false,
  "changed canonical project is rejected"
)

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

print("Neovim startup symlink fixture: " .. symlink_result)
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
    local p = vim.fn.maparg("p", "n", false, true)
    local r = vim.fn.maparg("r", "n", false, true)
    local q = vim.fn.maparg("q", "n", false, true)
    return {
      filetype = vim.bo.filetype,
      visible = visible,
      rows = rows,
      height = vim.api.nvim_win_get_height(0),
      laststatus = vim.o.laststatus,
      p_buffer = p.buffer,
      r_buffer = r.buffer,
      q_buffer = q.buffer,
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
    for _, name in ipairs({ "p  Projects", "r  Recent files", "q  Quit" }) do
      if line:find(name, 1, true) then
        menu[#menu + 1] = name
      end
    end
  end
  eq(menu, { "p  Projects", "r  Recent files", "q  Quit" }, label .. " visible actions")
  eq(state.laststatus, 0, label .. " status row hidden")
  eq(state.p_buffer, 1, label .. " p mapping is buffer-local")
  eq(state.r_buffer, 1, label .. " r mapping is buffer-local")
  eq(state.q_buffer, 1, label .. " q mapping is buffer-local")
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

    local regular = vim.fs.joinpath(child.root, "restored.lua")
    write_file(regular, { "return true" })
    local restored = edit_and_inspect(child, regular)
    eq(restored.laststatus, 3, "standalone status restored after starter")
    assert(restored.filetype ~= "ministarter", "regular file retained starter filetype")
    eq(restored.name, vim.fs.normalize(regular), "regular file becomes current")
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
    eq(restored.laststatus, 0, "tmux keeps status row hidden after starter")
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

  with_child({ name = "quit-enter" }, function(child)
    wait_for_starter(child, "normal Enter Quit startup")
    child_input(child, "k<CR>")
    assert(
      vim.wait(5000, function()
        return child.process:is_closing()
      end, 20),
      "native Enter Quit did not exit"
    )
    eq(child.process:wait(5000).code, 0, "native Enter Quit exits normally")
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
        local selected, pointers, active = nil, 0, nil
        for _, item in ipairs(starter.content_to_items()) do
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
          requests = #_G.startup_requests, recent = _G.startup_recent }
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
    assert_selection("p  Projects", "initial")
    child_input(child, "k")
    wait_child_lua(child, [[return vim.api.nvim_win_get_cursor(0)[1] > 0]], "native key delivery")
    -- RPC requests run after queued input, so inspections observe native selection.
    assert_selection("q  Quit", "backward wrap")
    child_input(child, "j")
    assert_selection("p  Projects", "forward wrap")
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
    child_lua(child, [[vim.o.columns = 70; vim.api.nvim_exec_autocmds("VimResized", {})]])
    assert_selection("r  Recent files", "narrow resize")
    child_input(child, "<Down>")
    assert_selection("q  Quit", "shared-row Quit")
    child_lua(child, [[vim.o.columns = 120; vim.api.nvim_exec_autocmds("VimResized", {})]])
    eq(assert_selection("q  Quit", "wide resize").requests, 1, "resize never recollects Git")
    child_lua(child, [[require("mini.starter").open()]])
    assert_selection("p  Projects", "second buffer")
    child_lua(child, [[_G.startup_requests[1].callback({ kind = "non_repository" })]])
    assert_selection("p  Projects", "closed-buffer late completion")
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
    assert_selection("p  Projects", "pending resize buffer")
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
    assert_selection("p  Projects", "pending quit buffer")
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
