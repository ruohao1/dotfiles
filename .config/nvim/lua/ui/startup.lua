local M = {}

local allowed_flags = {
  ["--clean"] = true,
  ["--embed"] = true,
  ["--headless"] = true,
  ["--noplugin"] = true,
  ["-M"] = true,
  ["-N"] = true,
  ["-R"] = true,
  ["-b"] = true,
  ["-m"] = true,
  ["-n"] = true,
}

local value_flags = {
  ["--listen"] = true,
  ["--startuptime"] = true,
  ["-U"] = true,
  ["-i"] = true,
  ["-u"] = true,
}

local function has_attached_value(argument)
  if argument:match("^%-[Uiu].+") then
    return true
  end
  for name in pairs(value_flags) do
    if name:sub(1, 2) == "--" and argument:sub(1, #name + 1) == name .. "=" then
      return #argument > #name + 1
    end
  end
  return false
end

local function has_editing_intent(argv)
  local index = 2
  while index <= #argv do
    local argument = argv[index]
    if argument == "--" then
      return index < #argv
    end
    if allowed_flags[argument] then
      index = index + 1
    elseif value_flags[argument] then
      if type(argv[index + 1]) ~= "string" or argv[index + 1] == "" then
        return true
      end
      index = index + 2
    elseif has_attached_value(argument) then
      index = index + 1
    else
      return true
    end
  end
  return false
end

local function argv_contains(argv, target)
  for index = 2, #argv do
    if argv[index] == target then
      return true
    end
  end
  return false
end

local function is_bare_launch(context)
  if
    context.stdin_seen
    or context.this_session ~= ""
    or has_editing_intent(context.argv)
    or (argv_contains(context.argv, "--embed") and context.builtin_tui ~= true)
  then
    return false
  end
  if #context.buffers ~= 1 or context.current_buffer ~= context.buffers[1] then
    return false
  end

  local initial = context.initial_buffer
  if not initial or initial.id ~= context.buffers[1] then
    return false
  end
  for _, bufnr in ipairs(context.window_buffers) do
    if bufnr ~= initial.id then
      return false
    end
  end

  return initial.name == ""
    and initial.buftype == ""
    and initial.modified == false
    and vim.deep_equal(initial.lines, { "" })
end

local function has_builtin_tui()
  for _, ui in ipairs(vim.api.nvim_list_uis()) do
    local ok, channel = pcall(vim.api.nvim_get_chan_info, ui.chan)
    local client = ok and type(channel) == "table" and channel.client or nil
    if type(client) == "table" and client.name == "nvim-tui" and client.type == "ui" then
      return true
    end
  end
  return false
end

local notification_title = "Neovim startup"

local function new(dependencies)
  local state = {
    evaluated = false,
    group = nil,
    setup = false,
    stdin_seen = false,
    buffers = {},
  }
  local controller = {}
  local actions = {}

  local function notify(message)
    dependencies.notify(message, vim.log.levels.WARN, { title = notification_title })
  end

  actions.quit = dependencies.quit

  actions.files = function()
    dependencies.pickers().files(dependencies.root())
  end

  actions.recent = function()
    dependencies.pickers().recent(dependencies.root())
  end

  local function synchronize_status()
    local bufnr = dependencies.current_buffer()
    dependencies.set_startup_visible(dependencies.buffer_filetype(bufnr) == "ministarter")
  end

  local function valid(bufnr, entry)
    return state.buffers[bufnr] == entry
      and dependencies.buffer_valid(bufnr)
      and dependencies.buffer_filetype(bufnr) == "ministarter"
  end

  local function ensure_buffer(bufnr)
    if not state.buffers[bufnr] then
      state.buffers[bufnr] = {
        directory = dependencies.getcwd(bufnr),
        generation = 0,
        view = { kind = "loading" },
        selected = actions.files,
      }
    end
    return state.buffers[bufnr]
  end

  local function capture_selection(bufnr, entry)
    local cursor = dependencies.cursor(bufnr)
    if not cursor then
      return
    end
    local starter = dependencies.starter()
    for _, item in ipairs(starter.content_to_items(starter.get_content(bufnr))) do
      if vim.deep_equal(item._cursorpos, cursor) then
        entry.selected = item.action
        return
      end
    end
  end

  local function reconcile(bufnr, entry)
    if not valid(bufnr, entry) then
      return
    end
    local starter = dependencies.starter()
    local content = starter.get_content(bufnr)
    local items = starter.content_to_items(content)
    -- Native refresh resets selection when item coordinates change.
    for _ = 1, #items do
      local cursor = dependencies.cursor(bufnr)
      local selected
      for _, item in ipairs(items) do
        if vim.deep_equal(item._cursorpos, cursor) then
          selected = item.action
        end
      end
      if not cursor or selected == entry.selected then
        break
      end
      starter.update_current_item("next", bufnr)
    end
    local cursor = dependencies.cursor(bufnr)
    for row, line in ipairs(content) do
      local column = 0
      for index, unit in ipairs(line) do
        if unit.type == "pointer" then
          local item = line[index + 1]
          local active = item
            and item.type == "item"
            and cursor
            and cursor[1] == row
            and cursor[2] == column + #unit.string
          unit.string = active and "> " or "  "
          dependencies.write_pointer(bufnr, row, column, unit.string)
        end
        column = column + #unit.string
      end
    end
  end

  local function refresh(bufnr, entry)
    if not valid(bufnr, entry) then
      return
    end
    if not entry.restoring then
      capture_selection(bufnr, entry)
    end
    dependencies.starter().refresh(bufnr)
    reconcile(bufnr, entry)
  end

  local function stop_timer(entry)
    if entry.focus_timer then
      entry.focus_timer:stop()
      entry.focus_timer:close()
      entry.focus_timer = nil
    end
  end

  local function invalidate(entry)
    entry.generation = entry.generation + 1
    stop_timer(entry)
    if entry.request then
      entry.request:cancel()
      entry.request = nil
    end
  end

  local function collect(bufnr, entry)
    invalidate(entry)
    local generation, directory = entry.generation, entry.directory
    entry.request = dependencies.collect(directory, function(view)
      if
        not valid(bufnr, entry)
        or entry.generation ~= generation
        or entry.directory ~= directory
      then
        return
      end
      entry.request = nil
      entry.view = view
      if view.kind == "error" and not entry.warned then
        entry.warned = true
        notify("Git summary unavailable")
      end
      refresh(bufnr, entry)
    end)
  end

  function controller:setup()
    if state.setup then
      return controller
    end
    state.setup = true

    local starter = dependencies.starter()
    starter.setup({
      autoopen = false,
      evaluate_single = false,
      header = "",
      footer = "",
      query_updaters = "",
      items = {
        { name = "f  Find files", action = actions.files, section = "" },
        { name = "r  Recent files", action = actions.recent, section = "" },
        { name = "q  Quit", action = actions.quit, section = "" },
      },
      content_hooks = {
        function(content, bufnr)
          synchronize_status()
          local entry = ensure_buffer(bufnr)
          entry.restoring = true
          dependencies.schedule(function()
            reconcile(bufnr, entry)
            entry.restoring = false
          end)
          return dependencies.compose(content, entry.view, dependencies.dimensions(bufnr))
        end,
      },
    })

    state.group = dependencies.create_augroup("dotfiles-startup", { clear = true })
    dependencies.create_autocmd("StdinReadPre", {
      group = state.group,
      desc = "Record startup stdin intent",
      callback = function()
        state.stdin_seen = true
      end,
    })
    dependencies.create_autocmd("VimEnter", {
      group = state.group,
      desc = "Open MiniStarter for a true bare launch",
      callback = function()
        if state.evaluated then
          return
        end
        state.evaluated = true
        if is_bare_launch(dependencies.startup_context(state.stdin_seen)) then
          starter.open()
        end
      end,
    })
    dependencies.create_autocmd("User", {
      group = state.group,
      pattern = "MiniStarterOpened",
      desc = "Install MiniStarter action mappings",
      callback = function()
        local bufnr = dependencies.current_buffer()
        -- MiniStarter's native Alt bindings shadow global split navigation.
        dependencies.delete_mapping(bufnr, "<M-j>")
        dependencies.delete_mapping(bufnr, "<M-k>")
        dependencies.set_startup_visible(true)
        dependencies.set_mapping(bufnr, "f", actions.files, "Find files")
        dependencies.set_mapping(bufnr, "r", actions.recent, "Open recent files")
        dependencies.set_mapping(bufnr, "q", actions.quit, "Quit")
        dependencies.set_mapping(bufnr, "<C-c>", actions.quit, "Quit")
        local entry = ensure_buffer(bufnr)
        for _, direction in ipairs({
          { "next", "Next startup item", { "j", "<Down>", "<C-n>" } },
          { "prev", "Previous startup item", { "k", "<Up>", "<C-p>" } },
        }) do
          for _, key in ipairs(direction[3]) do
            dependencies.set_mapping(bufnr, key, function()
              starter.update_current_item(direction[1], bufnr)
              capture_selection(bufnr, entry)
              reconcile(bufnr, entry)
            end, direction[2])
          end
        end
        reconcile(bufnr, entry)
        if not entry.request then
          collect(bufnr, entry)
        end
      end,
    })
    dependencies.create_autocmd({ "BufEnter", "WinEnter" }, {
      group = state.group,
      desc = "Synchronize startup status visibility",
      callback = synchronize_status,
    })
    dependencies.create_autocmd("WinResized", {
      group = state.group,
      callback = function()
        for bufnr, entry in pairs(state.buffers) do
          if valid(bufnr, entry) and dependencies.buffer_visible(bufnr) then
            refresh(bufnr, entry)
          end
        end
      end,
    })

    dependencies.create_autocmd("CursorMoved", {
      group = state.group,
      callback = function(event)
        local entry = state.buffers[event.buf]
        if entry and valid(event.buf, entry) and not entry.restoring then
          capture_selection(event.buf, entry)
          reconcile(event.buf, entry)
        end
      end,
    })
    dependencies.create_autocmd("DirChanged", {
      group = state.group,
      callback = function()
        for bufnr, entry in pairs(state.buffers) do
          if valid(bufnr, entry) then
            local directory = dependencies.getcwd(bufnr)
            if directory ~= entry.directory then
              entry.directory = directory
              entry.view = { kind = "loading" }
              refresh(bufnr, entry)
              collect(bufnr, entry)
            end
          end
        end
      end,
    })
    dependencies.create_autocmd("FocusGained", {
      group = state.group,
      callback = function()
        for bufnr, entry in pairs(state.buffers) do
          if valid(bufnr, entry) and dependencies.buffer_visible(bufnr) and not entry.request then
            stop_timer(entry)
            local timer = dependencies.new_timer()
            entry.focus_timer = timer
            timer:start(150, 0, function()
              dependencies.schedule(function()
                if entry.focus_timer ~= timer then
                  return
                end
                stop_timer(entry)
                if
                  valid(bufnr, entry)
                  and dependencies.buffer_visible(bufnr)
                  and not entry.request
                then
                  collect(bufnr, entry)
                end
              end)
            end)
          end
        end
      end,
    })
    dependencies.create_autocmd({ "BufWipeout", "VimLeavePre" }, {
      group = state.group,
      callback = function(event)
        if event.event == "VimLeavePre" then
          for bufnr, entry in pairs(state.buffers) do
            invalidate(entry)
            state.buffers[bufnr] = nil
          end
        else
          local entry = state.buffers[event.buf]
          if entry then
            invalidate(entry)
            state.buffers[event.buf] = nil
          end
        end
      end,
    })

    return controller
  end

  function controller:debug_state()
    return vim.deepcopy(state)
  end

  return controller
end

local function startup_context(stdin_seen)
  local buffers = vim.tbl_filter(function(bufnr)
    return vim.api.nvim_buf_is_loaded(bufnr)
  end, vim.api.nvim_list_bufs())
  local current = vim.api.nvim_get_current_buf()
  local window_buffers = vim.tbl_map(function(window)
    return vim.api.nvim_win_get_buf(window)
  end, vim.api.nvim_list_wins())

  return {
    argv = vim.deepcopy(vim.v.argv),
    builtin_tui = has_builtin_tui(),
    stdin_seen = stdin_seen,
    this_session = vim.v.this_session,
    buffers = buffers,
    current_buffer = current,
    window_buffers = window_buffers,
    initial_buffer = {
      id = current,
      name = vim.api.nvim_buf_get_name(current),
      buftype = vim.bo[current].buftype,
      modified = vim.bo[current].modified,
      lines = vim.api.nvim_buf_get_lines(current, 0, -1, false),
    },
  }
end

local function buffer_window(bufnr)
  return vim.fn.win_findbuf(bufnr)[1]
end

local runtime = new({
  collect = function(directory, callback)
    return require("ui.startup.git").collect(directory, callback)
  end,
  compose = function(content, view, dimensions)
    return require("ui.startup.layout").compose(content, view, dimensions)
  end,
  schedule = vim.schedule,
  new_timer = vim.uv.new_timer,
  quit = function()
    vim.cmd.quit()
  end,
  buffer_valid = vim.api.nvim_buf_is_valid,
  buffer_visible = function(bufnr)
    return buffer_window(bufnr) ~= nil
  end,
  dimensions = function(bufnr)
    local width, height = vim.o.columns, vim.o.lines - 1
    for _, window in ipairs(vim.fn.win_findbuf(bufnr)) do
      width = math.min(width, vim.api.nvim_win_get_width(window))
      height = math.min(height, vim.api.nvim_win_get_height(window))
    end
    return { width = width, height = height }
  end,
  cursor = function(bufnr)
    local window = buffer_window(bufnr)
    return window and vim.api.nvim_win_get_cursor(window) or nil
  end,
  write_pointer = function(bufnr, row, column, text)
    local current = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1]
    if not current or current:sub(column + 1, column + 2) == text then
      return
    end
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_text(bufnr, row - 1, column, row - 1, column + 2, { text })
    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].modified = false
  end,
  starter = function()
    return require("mini.starter")
  end,
  pickers = function()
    return require("navigation.pickers")
  end,
  root = function()
    return require("navigation.root").resolve()
  end,
  getcwd = function(bufnr)
    local window = bufnr and buffer_window(bufnr)
    return window
        and vim.api.nvim_win_call(window, function()
          return vim.fn.getcwd(0, 0)
        end)
      or vim.fn.getcwd(0, 0)
  end,
  notify = vim.notify,
  current_buffer = vim.api.nvim_get_current_buf,
  buffer_filetype = function(bufnr)
    return vim.bo[bufnr].filetype
  end,
  set_startup_visible = function(visible)
    return require("ui.statusline").set_startup_visible(visible)
  end,
  set_mapping = function(bufnr, lhs, callback, description)
    vim.keymap.set("n", lhs, callback, {
      buffer = bufnr,
      desc = description,
      nowait = true,
      silent = true,
    })
  end,
  delete_mapping = function(bufnr, lhs)
    vim.keymap.del("n", lhs, { buffer = bufnr })
  end,
  create_augroup = vim.api.nvim_create_augroup,
  create_autocmd = vim.api.nvim_create_autocmd,
  startup_context = startup_context,
})

function M.setup()
  return runtime:setup()
end

M._test = {
  has_editing_intent = has_editing_intent,
  is_bare_launch = is_bare_launch,
  new = new,
}

return M
