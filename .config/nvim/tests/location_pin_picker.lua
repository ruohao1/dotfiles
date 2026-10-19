local function eq(actual, expected, label)
  assert(vim.deep_equal(actual, expected), label .. "\n" .. vim.inspect(actual))
end
local picker = require("navigation.location_pin_picker")
local pin = { id = string.rep("a", 64), path = "/literal/雪", line = 1, col = 5 }
local previous_tabstop = vim.o.tabstop
vim.o.tabstop = 2
local preview = picker.render({ "a\t雪x" }, pin)
eq(
  preview[#preview],
  string.rep(" ", 10) .. "^",
  "tabs use eight display cells, independent of editor tabstop"
)
eq(preview[#preview - 1], "a\t雪x", "preview preserves literal tabs")
pin.col = 3
eq(
  picker.render({ "a\t雪x" }, pin)[4],
  string.rep(" ", 8) .. "^",
  "interior UTF-8 byte rounds back"
)
-- Oracle: Neovim's independent character slicing and display width at tabstop 8.
local matrix = {}
vim.o.tabstop = 8
for row = 0, 100 do
  local value = string.rep("a\t雪é", row % 9) .. tostring(row) .. "\tx"
  for col = 0, 100 do
    local limit = math.min(col, #value - 1)
    local prefix = ""
    for chars = 0, vim.fn.strchars(value) do
      local candidate = vim.fn.strcharpart(value, 0, chars)
      if #candidate <= limit then
        prefix = candidate
      end
    end
    matrix[#matrix + 1] = { value, col, vim.fn.strdisplaywidth(prefix) }
  end
end
vim.o.tabstop = 2
for _, case in ipairs(matrix) do
  pin.col = case[2]
  local rendered = picker.render({ case[1] }, pin)
  eq(rendered[#rendered], string.rep(" ", case[3]) .. "^", "byte-column/display-cell matrix")
end
vim.o.tabstop = previous_tabstop
eq(#matrix, 10201, "matrix dimensions")
pin.path = "/escape\27[31m\nname"
pin.col = 0
local safe = table.concat(picker.render({ "\27[31m\ttext" }, pin), "\n")
assert(not safe:find("\27", 1, true), "preview must not emit terminal escape bytes")
local rows = picker.rows({ pin })
assert(not rows[1]:find("\n", 1, true), "a path cannot create another picker row")
assert(rows[1]:sub(1, 65) == pin.id .. "\t", "selection uses a separate stable ID field")
local opened, deleted, loads = nil, nil, 0
local live = { pin }
local source = {
  list = function()
    loads = loads + 1
    return live
  end,
  open = function(id)
    opened = id
  end,
  delete = function(id)
    deleted = id
    live = {}
  end,
  notify = function(message)
    error(message)
  end,
}
local contents, options = picker.spec(source)
local emitted = {}
contents(function(row)
  if row then
    emitted[#emitted + 1] = row
  end
end)
eq(emitted, rows, "initial finder content")
options.actions.enter({ rows[1] })
eq(opened, pin.id, "opening routes by stable identity")
options.actions["ctrl-x"].fn({ rows[1] })
eq(deleted, pin.id, "deletion routes by stable identity")
emitted = {}
contents(function(row)
  if row then
    emitted[#emitted + 1] = row
  end
end)
eq(emitted, {}, "reload reads current store after deletion")
assert(loads >= 2 and options.actions["ctrl-x"].reload, "deletion refreshes the finder")
options.actions.enter({ "not-an-id\t" .. pin.path })
eq(opened, pin.id, "malformed selection is ignored")
local argv = { "fzf", "--filter=escape" }
for option, value in pairs(options.fzf_opts) do
  if value == "" or value == true then
    argv[#argv + 1] = option
  elseif value ~= false then
    argv[#argv + 1] = option .. "=" .. value
  end
end
local result =
  vim.system(argv, { stdin = table.concat(rows, "\n") .. "\n", text = true }):wait(5000)
eq(result.code, 0, "finder searches the displayed file path")
eq(result.stdout:gsub("\n$", ""), rows[1], "fzf returns the original stable row")
argv[2] = "--filter=" .. string.rep("a", 20)
local hidden_id_result = vim.system(argv, { stdin = rows[1] .. "\n", text = true }):wait(5000)
eq(hidden_id_result.code, 1, "hidden identities do not participate in path search")
print("Line-pin picker assertions: ok (10201 preview cases)")

-- Exercise the pinned fzf-lua RPC adapters when this runs in configured Neovim.
-- Pure preview tests above also run without plugin data.
if package.loaded["lazy"] then
  local fzf = require("fzf-lua")
  local fixture = vim.fn.tempname() .. "-pin-preview"
  assert(vim.fn.mkdir(fixture, "p", 448) == 1)
  local previous_cwd = vim.fn.getcwd()
  vim.api.nvim_set_current_dir(fixture)
  local ok, err = xpcall(function()
    local path = fixture .. "/雪 ' $(touch NEVER).txt"
    assert(vim.fn.writefile({ "a\t雪x" }, path) == 0)
    local record = { id = string.rep("b", 64), path = path, line = 1, col = 5 }
    local contents, opts = picker.spec({
      list = function()
        return { record }
      end,
      open = function() end,
      delete = function() end,
      notify = error,
    })
    opts._start = false
    local _, command, resolved = fzf.fzf_exec(contents, opts)
    assert(type(command) == "string", "pinned fzf-lua must adapt the content provider")
    local function run_callback(shell_command)
      local completed
      local process = vim.system({ "sh", "-c", shell_command }, { text = true }, function(result)
        completed = result
      end)
      if not vim.wait(10000, function()
        return completed ~= nil
      end, 10) then
        process:kill(9)
        error("fzf-lua data callback timed out")
      end
      eq(completed.code, 0, "pinned fzf-lua callback exits successfully")
      return completed.stdout
    end
    local expected_row = picker.rows({ record })[1]
    eq(run_callback(command), expected_row .. "\n", "pinned content adapter preserves literal data")
    local preview_command = require("fzf-lua.previewer").normalize_spec(opts.preview, resolved)
    preview_command = preview_command:gsub("{}", function()
      return vim.fn.shellescape(expected_row)
    end)
    local actual_preview = run_callback(preview_command)
    assert(
      actual_preview:find("a\t雪x\n          ^", 1, true),
      "pinned preview adapter retains tab alignment"
    )
    assert(
      not vim.uv.fs_stat(fixture .. "/NEVER"),
      "callback treats command-looking filenames literally"
    )
  end, debug.traceback)
  vim.api.nvim_set_current_dir(previous_cwd)
  vim.fn.delete(fixture, "rf")
  assert(ok, err)
  print("Configured line-pin fzf-lua callbacks: ok")
end
