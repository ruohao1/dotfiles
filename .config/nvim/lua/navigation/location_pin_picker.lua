local M = {}
local tabstop = 8

local function visible(value, keep_tabs)
  value = value:gsub("[%z\1-\31\127]", function(character)
    if keep_tabs and character == "\t" then
      return character
    end
    return string.format("\\x%02x", character:byte())
  end)
  return (
    value:gsub("\194[\128-\159]", function(character)
      return string.format("\\u%04x", character:byte(2))
    end)
  )
end

function M.byte_column(value, requested)
  local column = math.max(0, math.min(requested, #value - 1))
  while column > 0 do
    local byte = value:byte(column + 1)
    if not byte or byte < 128 or byte >= 192 then
      break
    end
    column = column - 1
  end
  return column
end

local function display_width(value)
  local width, offset = 0, 1
  while true do
    local tab = value:find("\t", offset, true)
    width = width + vim.fn.strdisplaywidth(tab and value:sub(offset, tab - 1) or value:sub(offset))
    if not tab then
      return width
    end
    width = width + tabstop - (width % tabstop)
    offset = tab + 1
  end
end

function M.render(lines, pin)
  if #lines == 0 then
    lines = { "" }
  end
  local line = math.max(1, math.min(pin.line, #lines))
  local column = M.byte_column(lines[line], pin.col)
  local output = { string.format("%s:%d:%d", visible(pin.path, false), line, column + 1), "" }
  for row = math.max(1, line - 4), math.min(#lines, line + 4) do
    output[#output + 1] = visible(lines[row], true)
    if row == line then
      local prefix = visible(lines[row]:sub(1, column), true)
      output[#output + 1] = string.rep(" ", display_width(prefix)) .. "^"
    end
  end
  return output
end

function M.preview(pin)
  if not pin then
    return { "Pin is no longer available" }
  end
  -- Prefer unsaved editor contents, comparing names literally (bufnr accepts patterns).
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buffer) and vim.api.nvim_buf_get_name(buffer) == pin.path then
      return M.render(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), pin)
    end
  end
  local stat = vim.uv.fs_stat(pin.path)
  if not stat or stat.type ~= "file" then
    return { "File unavailable: " .. visible(pin.path, false), "Ctrl-x deletes this pin" }
  end
  local ok, lines = pcall(vim.fn.readfile, pin.path, "b")
  if not ok then
    return { "Cannot read: " .. visible(pin.path, false), "Ctrl-x deletes this pin" }
  end
  return M.render(lines, pin)
end

function M.rows(pins)
  local rows = {}
  for _, pin in ipairs(pins) do
    rows[#rows + 1] =
      string.format("%s\t%s:%d:%d", pin.id, visible(pin.path, false), pin.line, pin.col + 1)
  end
  return rows
end

local function selected_id(selected)
  local id = selected and selected[1] and selected[1]:match("^([0-9a-f]+)\t")
  return id and #id == 64 and id or nil
end

function M.spec(source)
  local records = {}
  local function contents(callback)
    local pins, err = source.list()
    records = {}
    if not pins then
      source.notify(err)
      callback()
      return
    end
    for _, pin in ipairs(pins) do
      records[pin.id] = pin
    end
    for _, row in ipairs(M.rows(pins)) do
      callback(row)
    end
    callback()
  end
  local options = {
    prompt = "Line pins> ",
    previewer = false,
    preview = function(selected)
      return M.preview(records[selected_id(selected)])
    end,
    fzf_opts = {
      ["--delimiter"] = "\t",
      ["--with-nth"] = "2..",
      ["--track"] = "",
      ["--tabstop"] = tostring(tabstop),
      ["--no-multi"] = "",
      ["--ansi"] = false,
    },
    actions = {
      enter = function(selected)
        local id = selected_id(selected)
        if id then
          source.open(id)
        end
      end,
      ["ctrl-x"] = {
        fn = function(selected)
          local id = selected_id(selected)
          if id then
            source.delete(id)
          end
        end,
        reload = true,
      },
    },
  }
  return contents, options
end

function M.open(fzf, source)
  local contents, options = M.spec(source)
  return fzf.fzf_exec(contents, options)
end

return M
