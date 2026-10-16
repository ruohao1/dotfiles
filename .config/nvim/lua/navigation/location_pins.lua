local M = {}
local context = require("navigation.location_pin_context")
local store = require("navigation.location_pin_store")
local presentation = require("navigation.location_pin_picker")

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.WARN, { title = "Line pins" })
end

local function current_context()
  local ctx, err = context.resolve()
  if ctx then
    local remembered
    remembered, err = context.remember(ctx)
    if not remembered then
      ctx = nil
    end
  end
  if not ctx then
    notify(err)
  end
  return ctx
end

local function capture()
  local buffer = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(buffer)
  if vim.bo[buffer].buftype ~= "" or path:sub(1, 1) ~= "/" or path:match("^%w[%w+.-]*://") then
    return nil, "Only named local file buffers can be pinned"
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  return { path = path, line = cursor[1], col = cursor[2] }
end

function M.add()
  local ctx = current_context()
  if not ctx then
    return nil
  end
  local location, err = capture()
  if not location then
    notify(err)
    return nil
  end
  local pin, store_error = store.add(ctx, location)
  if not pin then
    notify(store_error)
    return nil
  end
  notify("Location pinned", vim.log.levels.INFO)
  return pin
end

function M.open(ctx, id)
  local pins, err = store.list(ctx)
  if not pins then
    notify(err)
    return false
  end
  local selected
  for _, pin in ipairs(pins) do
    if pin.id == id then
      selected = pin
      break
    end
  end
  if not selected then
    notify("This pin was deleted; refresh the finder")
    return false
  end
  local target
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buffer) == selected.path then
      target = buffer
      break
    end
  end
  if not target or not vim.api.nvim_buf_is_loaded(target) then
    local stat = vim.uv.fs_stat(selected.path)
    if not stat or stat.type ~= "file" then
      notify("Pinned file is unavailable: " .. selected.path)
      return false
    end
  end
  local current = vim.api.nvim_get_current_buf()
  local hidden_behavior = vim.bo[current].bufhidden
  if
    current ~= target
    and vim.bo[current].modified
    and (not vim.o.hidden or (hidden_behavior ~= "" and hidden_behavior ~= "hide"))
  then
    notify("Save the modified buffer before opening another file")
    return false
  end
  local opened, open_error = pcall(function()
    target = target or vim.fn.bufadd(selected.path)
    vim.fn.bufload(target)
    assert(vim.api.nvim_buf_is_loaded(target), "could not load pinned file")
    local row = math.max(1, math.min(selected.line, vim.api.nvim_buf_line_count(target)))
    local text = vim.api.nvim_buf_get_lines(target, row - 1, row, false)[1] or ""
    vim.api.nvim_win_set_buf(0, target)
    vim.api.nvim_win_set_cursor(0, { row, presentation.byte_column(text, selected.col) })
  end)
  if not opened then
    notify("Could not open pin: " .. tostring(open_error))
    return false
  end
  return true
end

function M.delete_current()
  local ctx = current_context()
  if not ctx then
    return nil
  end
  local location, err = capture()
  if not location then
    notify(err)
    return nil
  end
  local pins, store_error = store.list(ctx)
  if not pins then
    notify(store_error)
    return nil
  end
  for _, pin in ipairs(pins) do
    if pin.path == location.path and pin.line == location.line and pin.col == location.col then
      local deleted, delete_error = store.delete(ctx, pin.id)
      if not deleted then
        notify(delete_error)
        return nil
      end
      notify("Location pin deleted", vim.log.levels.INFO)
      return true
    end
  end
  notify("There is no pin at this location", vim.log.levels.INFO)
  return false
end

function M.clear()
  local ctx = current_context()
  if not ctx then
    return
  end
  vim.ui.select(
    { "Clear pins", "Cancel" },
    { prompt = "Clear this tmux session's line pins?" },
    function(choice)
      if choice == "Clear pins" then
        local cleared, err = store.clear(ctx)
        if not cleared then
          notify(err)
        else
          notify("Session pins cleared", vim.log.levels.INFO)
        end
      end
    end
  )
end

function M.find()
  local ctx = current_context()
  if not ctx then
    return
  end
  require("navigation.pickers").line_pins({
    list = function()
      return store.list(ctx)
    end,
    open = function(id)
      return M.open(ctx, id)
    end,
    delete = function(id)
      local deleted, err = store.delete(ctx, id)
      if not deleted then
        notify(err)
      end
      return deleted
    end,
    notify = notify,
  })
end

function M.setup()
  local ctx = context.resolve()
  if ctx then
    context.remember(ctx)
  end
  for name, action in pairs({
    LinePinAdd = M.add,
    LinePins = M.find,
    LinePinDelete = M.delete_current,
    LinePinsClear = M.clear,
  }) do
    vim.api.nvim_create_user_command(name, action, { desc = "Session line pins" })
  end
end

return M
