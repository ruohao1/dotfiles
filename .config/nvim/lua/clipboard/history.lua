local M = {}
local title = "Clipboard history"

-- LuaJIT's byte strings need explicit validation before they reach buffer APIs.
local function character_width(text, offset)
  local first = text:byte(offset)
  if not first or first == 0 then
    return nil
  end
  if first < 128 then
    return 1
  end
  local width = first >= 194 and first <= 223 and 2
    or first >= 224 and first <= 239 and 3
    or first >= 240 and first <= 244 and 4
  if not width then
    return nil
  end
  for index = 1, width - 1 do
    local byte = text:byte(offset + index)
    if not byte or byte < 128 or byte > 191 then
      return nil
    end
  end
  local second = text:byte(offset + 1)
  if
    (first == 224 and second < 160)
    or (first == 237 and second >= 160)
    or (first == 240 and second < 144)
    or (first == 244 and second >= 144)
  then
    return nil
  end
  return width
end

local function valid_text(text)
  if type(text) ~= "string" then
    return false
  end
  local offset = 1
  while offset <= #text do
    local width = character_width(text, offset)
    if not width then
      return false
    end
    offset = offset + width
  end
  return true
end

local function default_dependencies()
  return {
    api = vim.api,
    platform = function()
      return vim.g.dotfiles_platform
    end,
    provider = function()
      return vim.g.dotfiles_clipboard_provider
    end,
    wayland = function()
      return vim.env.WAYLAND_DISPLAY
    end,
    executable = function(name)
      return vim.fn.executable(name) == 1
    end,
    system = function(argv, options)
      return vim.system(argv, options)
    end,
    fzf = function()
      return require("fzf-lua")
    end,
    notify = function(message, level)
      vim.notify(message, level, { title = title })
    end,
    confirm = function()
      return vim.fn.confirm("Clear all clipboard history?", "&Clear\n&Cancel", 2)
    end,
    create_command = function(name, callback)
      vim.api.nvim_create_user_command(name, callback, {})
    end,
    schedule = vim.schedule,
    setreg = function(name, value, kind)
      return vim.fn.setreg(name, value, kind)
    end,
    mode = function()
      return vim.fn.mode()
    end,
    anchor = function()
      return vim.fn.getpos("v")
    end,
    selection = function()
      return vim.o.selection
    end,
    region = function(anchor, cursor, mode)
      return vim.fn.getregionpos(anchor, cursor, { type = mode, eol = true })
    end,
    leave_visual = function()
      vim.cmd.normal({ args = { vim.keycode("<Esc>") }, bang = true })
    end,
  }
end

local function new(deps)
  local configured = false
  local public = {}

  local function notify(message)
    deps.notify(message, vim.log.levels.WARN)
  end

  local function available(service)
    if
      deps.platform() ~= "linux"
      or deps.provider() ~= "wl-copy"
      or not deps.wayland()
      or deps.wayland() == ""
    then
      notify("Clipboard history requires Linux with the Wayland clipboard provider")
      return false
    end
    for _, executable in ipairs({ "cliphist", "wl-copy", "wl-paste" }) do
      if not deps.executable(executable) then
        notify("Clipboard history requires cliphist and wl-clipboard")
        return false
      end
    end
    if service and not deps.executable("systemctl") then
      notify("Clipboard history service control requires systemctl")
      return false
    end
    return true
  end

  local function run(argv, input)
    local ok, result = pcall(function()
      return deps.system(argv, { stdin = input, text = false }):wait(1000)
    end)
    if
      not ok
      or type(result) ~= "table"
      or result.code ~= 0
      or (result.signal or 0) ~= 0
      or type(result.stdout) ~= "string"
    then
      notify("Clipboard history command failed or timed out")
      return nil
    end
    return result.stdout
  end

  local function line_at(buffer, row)
    return deps.api.nvim_buf_get_lines(buffer, row - 1, row, true)[1]
  end

  local function valid_position(buffer, row, column)
    if
      type(row) ~= "number"
      or type(column) ~= "number"
      or row < 1
      or column < 0
      or row % 1 ~= 0
      or column % 1 ~= 0
      or row > deps.api.nvim_buf_line_count(buffer)
    then
      return false
    end
    local line = line_at(buffer, row)
    if not valid_text(line) or column > #line then
      return false
    end
    return column == #line or character_width(line, column + 1) ~= nil
  end

  local function capture_target()
    local api = deps.api
    local mode = deps.mode()
    if mode ~= "n" and mode ~= "v" and mode ~= "V" then
      return nil
    end
    local target = {
      window = api.nvim_get_current_win(),
      buffer = api.nvim_get_current_buf(),
      mode = mode,
      cursor = api.nvim_win_get_cursor(0),
      selection = deps.selection(),
    }
    target.tick = api.nvim_buf_get_changedtick(target.buffer)
    if
      not api.nvim_get_option_value("modifiable", { buf = target.buffer })
      or api.nvim_get_option_value("buftype", { buf = target.buffer }) ~= ""
      or not valid_position(target.buffer, target.cursor[1], target.cursor[2])
    then
      return nil
    end
    if mode ~= "n" then
      target.anchor = deps.anchor()
      if
        target.anchor[4] ~= 0
        or not valid_position(target.buffer, target.anchor[2], target.anchor[3] - 1)
      then
        return nil
      end
      if mode == "V" then
        target.first = { math.min(target.anchor[2], target.cursor[1]) - 1, 0 }
        target.last = { math.max(target.anchor[2], target.cursor[1]), 0 }
      else
        local region = deps.region(
          target.anchor,
          { target.buffer, target.cursor[1], target.cursor[2] + 1, 0 },
          mode
        )
        if #region == 0 then
          return nil
        end
        local first, last = region[1][1], region[#region][2]
        if first[4] ~= 0 or last[4] ~= 0 then
          return nil
        end
        local start_column = math.max(0, first[3] - 1)
        -- getregionpos ends on the last selected byte, including for multibyte characters.
        local line = line_at(target.buffer, last[2])
        local end_column = math.min(#line, math.max(0, last[3]))
        if
          not valid_position(target.buffer, first[2], start_column)
          or not valid_position(target.buffer, last[2], end_column)
        then
          return nil
        end
        target.first = { first[2] - 1, start_column }
        target.last = { last[2] - 1, end_column }
      end
      deps.leave_visual()
      -- Leaving Visual mode can move an end-of-line cursor onto the last character.
      -- Keep the captured selection bounds, but validate against the normal-mode cursor.
      target.cursor = api.nvim_win_get_cursor(target.window)
      target.marks =
        { api.nvim_buf_get_mark(target.buffer, "<"), api.nvim_buf_get_mark(target.buffer, ">") }
    end
    return target
  end

  local function target_is_valid(target)
    local api = deps.api
    if
      not api.nvim_win_is_valid(target.window)
      or not api.nvim_buf_is_valid(target.buffer)
      or api.nvim_win_get_buf(target.window) ~= target.buffer
      or api.nvim_buf_get_changedtick(target.buffer) ~= target.tick
      or not api.nvim_get_option_value("modifiable", { buf = target.buffer })
      or not vim.deep_equal(api.nvim_win_get_cursor(target.window), target.cursor)
    then
      return false
    end
    if
      target.marks
      and (
        deps.selection() ~= target.selection
        or not vim.deep_equal(
          target.marks,
          { api.nvim_buf_get_mark(target.buffer, "<"), api.nvim_buf_get_mark(target.buffer, ">") }
        )
      )
    then
      return false
    end
    if api.nvim_get_current_win() == target.window and deps.mode() ~= "n" then
      return false
    end
    return true
  end

  local function paste(target, row)
    if not target_is_valid(target) then
      notify("Paste target changed; reopen clipboard history")
      return
    end
    local value = run({ "cliphist", "decode" }, row)
    if value == nil then
      return
    end
    if value == "" or not valid_text(value) then
      notify("Clipboard entry is not supported text")
      return
    end
    if not target_is_valid(target) then
      notify("Paste target changed; reopen clipboard history")
      return
    end
    local kind = value:sub(-1) == "\n" and "V" or "v"
    local ok, status = pcall(deps.setreg, "+", value, kind)
    if not ok or status ~= 0 then
      notify("Could not write the clipboard register")
      return
    end
    local edited = pcall(function()
      local api = deps.api
      api.nvim_set_current_win(target.window)
      assert(target_is_valid(target))
      api.nvim_win_set_cursor(target.window, target.cursor)
      if target.mode == "n" then
        local lines = vim.split(kind == "V" and value:sub(1, -2) or value, "\n", { plain = true })
        api.nvim_put(lines, kind, true, true)
      elseif target.mode == "V" then
        local lines = vim.split(kind == "V" and value:sub(1, -2) or value, "\n", { plain = true })
        api.nvim_buf_set_lines(target.buffer, target.first[1], target.last[1], false, lines)
        api.nvim_win_set_cursor(target.window, { target.first[1] + 1, 0 })
      else
        -- A single replacement preserves the black-hole deletion behavior and one-step undo,
        -- including when deletion would move a normal-mode cursor left at end of line.
        api.nvim_buf_set_text(
          target.buffer,
          target.first[1],
          target.first[2],
          target.last[1],
          target.last[2],
          vim.split(value, "\n", { plain = true })
        )
        api.nvim_win_set_cursor(target.window, { target.first[1] + 1, target.first[2] })
      end
    end)
    if not edited then
      notify("Could not paste into the target buffer")
    end
  end

  local show
  show = function(target)
    local output = run({ "cliphist", "list" })
    if output == nil then
      return
    end
    if not valid_text(output) then
      notify("Clipboard history returned an invalid list")
      return
    end
    if output == "" then
      notify("Clipboard history is empty")
      return
    end
    local rows = vim.split(output, "\n", { plain = true })
    if rows[#rows] == "" then
      table.remove(rows)
    end
    local allowed = {}
    for _, row in ipairs(rows) do
      if not row:match("^%d+\t.+$") then
        notify("Clipboard history returned an invalid list")
        return
      end
      allowed[row] = true
    end
    local function selected_row(selected)
      if type(selected) ~= "table" or #selected == 0 then
        return nil
      end
      if #selected ~= 1 or type(selected[1]) ~= "string" or not allowed[selected[1]] then
        notify("Clipboard history selection is invalid")
        return nil
      end
      return selected[1]
    end
    local ok = pcall(function()
      deps.fzf().fzf_exec(rows, {
        prompt = "Clipboard> ",
        previewer = false,
        fzf_opts = {
          ["--no-sort"] = true,
          ["--no-multi"] = true,
          ["--delimiter"] = "\t",
          ["--with-nth"] = "2..",
        },
        actions = {
          enter = function(selected)
            local row = selected_row(selected)
            if row then
              paste(target, row)
            end
          end,
          ["ctrl-d"] = function(selected)
            local row = selected_row(selected)
            if row and run({ "cliphist", "delete" }, row) ~= nil then
              deps.schedule(function()
                show(target)
              end)
            end
          end,
        },
      })
    end)
    if not ok then
      notify("Could not open clipboard history picker")
    end
  end

  function public.open()
    if not available(false) then
      return
    end
    local ok, target = pcall(capture_target)
    if not ok or not target then
      notify("Clipboard history supports editable normal, characterwise, and linewise targets")
      return
    end
    show(target)
  end

  function public.setup()
    if configured then
      return
    end
    deps.create_command("ClipboardHistoryClear", function()
      if available(false) and deps.confirm() == 1 then
        run({ "cliphist", "wipe" })
      end
    end)
    deps.create_command("ClipboardHistoryPause", function()
      if available(true) then
        run({ "systemctl", "--user", "stop", "cliphist.service" })
      end
    end)
    deps.create_command("ClipboardHistoryResume", function()
      if available(true) then
        run({ "systemctl", "--user", "start", "cliphist.service" })
      end
    end)
    configured = true
  end
  return public
end

local runtime = new(default_dependencies())
M.open = runtime.open
M.setup = runtime.setup
M._test = { new = new, default_dependencies = default_dependencies }
return M
