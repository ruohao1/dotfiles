local function eq(actual, expected, label)
  assert(vim.deep_equal(actual, expected), label)
end

local history = require("clipboard.history")
for _, name in ipairs({ "setup", "open" }) do
  assert(type(history[name]) == "function", "missing clipboard public entry point")
end
assert(type(history._test.new) == "function", "missing injected history constructor")
assert(type(history._test.default_dependencies) == "function", "missing runtime dependencies")

local marker = "clipboard-secret-DO-NOT-LEAK"
local row = "42\t" .. marker
local function fixture(options)
  options = options or {}
  vim.cmd("enew!")
  local buffer = vim.api.nvim_get_current_buf()
  vim.bo[buffer].buftype = ""
  vim.bo[buffer].modifiable = true
  vim.api.nvim_buf_set_lines(
    buffer,
    0,
    -1,
    false,
    options.lines or { "aé中z", "second", "third" }
  )
  vim.bo[buffer].undolevels = -1
  vim.bo[buffer].undolevels = 1000
  vim.api.nvim_win_set_cursor(0, options.cursor or { 1, 1 })
  local state = { calls = {}, notices = {}, pickers = {}, commands = {}, registers = {} }
  local deps = history._test.default_dependencies()
  deps.platform = function()
    return "linux"
  end
  deps.provider = function()
    return "wl-copy"
  end
  deps.wayland = function()
    return "test-wayland"
  end
  deps.executable = function()
    return true
  end
  deps.notify = function(message)
    assert(not message:find(marker, 1, true), "notification leaked clipboard content")
    table.insert(state.notices, message)
  end
  deps.confirm = function()
    return state.confirmation or 2
  end
  deps.create_command = function(name, callback)
    assert(not state.commands[name], "setup repeated command registration")
    state.commands[name] = callback
  end
  deps.schedule = function(callback)
    callback()
  end
  deps.setreg = function(name, value, kind)
    table.insert(state.registers, { name, value, kind })
    if state.register_error then
      error(marker)
    end
    return state.register_status or 0
  end
  deps.system = function(argv, process_options)
    assert(
      type(argv) == "table" and process_options.text == false,
      "process is not argv/binary based"
    )
    assert(not table.concat(argv, " "):find(marker, 1, true), "clipboard content entered argv")
    table.insert(state.calls, { argv = vim.deepcopy(argv), stdin = process_options.stdin })
    if state.spawn_error then
      error(marker)
    end
    return {
      wait = function(_, timeout)
        eq(timeout, 1000, "history process wait is not bounded")
        if state.wait_error then
          error(marker)
        end
        if state.result then
          return state.result
        end
        if argv[1] == "cliphist" and argv[2] == "list" then
          return { code = 0, signal = 0, stdout = state.list or row .. "\n" }
        elseif argv[1] == "cliphist" and argv[2] == "decode" then
          if state.during_decode then
            state.during_decode()
          end
          return { code = 0, signal = 0, stdout = state.payload or " é中 \n" }
        end
        return { code = 0, signal = 0, stdout = "" }
      end,
    }
  end
  deps.fzf = function()
    return {
      fzf_exec = function(rows, picker_options)
        table.insert(state.pickers, { rows = rows, options = picker_options })
      end,
    }
  end
  state.deps = deps
  state.buffer = buffer
  state.instance = history._test.new(deps)
  state.choose = function(selection, key)
    local picker = state.pickers[#state.pickers]
    assert(picker, "history picker was not opened")
    picker.options.actions[key or "enter"](selection == nil and { row } or selection)
  end
  state.lines = function()
    return vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
  end
  return state
end

local s = fixture()
s.instance.setup()
s.instance.setup()
for _, name in ipairs({ "ClipboardHistoryClear", "ClipboardHistoryPause", "ClipboardHistoryResume" }) do
  assert(type(s.commands[name]) == "function", "missing history command")
end
s.instance.open()
local picker = s.pickers[1]
eq(picker.rows, { row }, "list row was changed")
eq(picker.options.prompt, "Clipboard> ", "wrong picker prompt")
eq(picker.options.previewer, false, "history should not run a preview process")
eq(picker.options.fzf_opts["--no-sort"], true, "history order must be retained")
eq(picker.options.fzf_opts["--no-multi"], true, "history selection must be singular")
eq(picker.options.fzf_opts["--with-nth"], "2..", "identifier must be hidden")
eq(picker.options.fzf_opts["--delimiter"], "\t", "history fields must use a tab delimiter")
s.choose({})
eq(#s.registers, 0, "cancellation changed the clipboard")
eq(s.lines(), { "aé中z", "second", "third" }, "cancellation edited the target")

for _, change in ipairs({
  function(d)
    d.platform = function()
      return "macos"
    end
  end,
  function(d)
    d.provider = function()
      return "osc52"
    end
  end,
  function(d)
    d.wayland = function()
      return ""
    end
  end,
  function(d)
    d.executable = function(name)
      return name ~= "cliphist"
    end
  end,
  function(d)
    d.executable = function(name)
      return name ~= "wl-copy"
    end
  end,
  function(d)
    d.executable = function(name)
      return name ~= "wl-paste"
    end
  end,
}) do
  s = fixture()
  change(s.deps)
  s.instance.open()
  eq(#s.calls, 0, "unavailable environment launched a process")
  eq(#s.pickers, 0, "unavailable environment opened a picker")
  assert(#s.notices > 0, "unavailable environment was silent")
end

for _, output in ipairs({
  "invalid",
  "1\t\n",
  "x\tpreview\n",
  "1\tpreview\n\n",
  "1\t\255\n",
  "1\tbad\0text\n",
  "1\t\192\175\n",
  "1\t\237\160\128\n",
}) do
  s = fixture()
  s.list = output
  s.instance.open()
  eq(#s.pickers, 0, "malformed list opened a picker")
end
s = fixture()
s.list = ""
s.instance.open()
eq(#s.pickers, 0, "empty history opened a picker")
for _, result in ipairs({
  { code = 124, signal = 15, stdout = marker },
  { code = 1, stdout = marker },
  { code = 0, signal = 9, stdout = marker },
  { code = 0 },
}) do
  s = fixture()
  s.result = result
  s.instance.open()
  eq(#s.pickers, 0, "failed history command opened a picker")
  assert(#s.notices > 0, "history process failure was silent")
end
for _, flag in ipairs({ "spawn_error", "wait_error" }) do
  s = fixture()
  s[flag] = true
  s.instance.open()
  eq(#s.pickers, 0, "process exception opened a picker")
end
for _, selection in ipairs({
  { "43\tunknown" },
  { "42\tdifferent" },
  { row, row },
  { "42" },
  { 42 },
}) do
  s = fixture()
  s.instance.open()
  s.choose(selection)
  eq(#s.calls, 1, "untrusted selection reached decode")
  eq(#s.registers, 0, "untrusted selection changed the clipboard")
end

for _, payload in ipairs({ "", "bad\0text", "\255", "\240\128\128\128", "\244\144\128\128" }) do
  s = fixture()
  s.payload = payload
  s.instance.open()
  s.choose()
  eq(#s.registers, 0, "invalid decoded text changed the clipboard")
end
s = fixture()
s.payload = " é🙂 "
s.instance.open()
s.choose()
eq(
  s.calls[2],
  { argv = { "cliphist", "decode" }, stdin = row },
  "decode did not receive the complete row through stdin"
)
eq(s.registers, { { "+", " é🙂 ", "v" } }, "characterwise register changed text")
eq(
  s.lines(),
  { "aé é🙂 中z", "second", "third" },
  "normal Unicode paste changed byte boundaries"
)
s = fixture()
s.payload = "first\nsecond\n"
s.instance.open()
s.choose()
eq(s.registers[1][3], "V", "final newline did not select a linewise register")
eq(
  s.lines(),
  { "aé中z", "first", "second", "second", "third" },
  "normal linewise paste changed final newline handling"
)
s = fixture({ lines = { "" }, cursor = { 1, 0 } })
s.payload = "x"
s.instance.open()
s.choose()
eq(s.lines(), { "x" }, "empty target paste failed")

local function visual(kind, anchor, cursor, payload, lines, expected, exclusive)
  local v = fixture({ lines = lines, cursor = anchor })
  vim.o.selection = exclusive and "exclusive" or "inclusive"
  vim.cmd.normal({ args = { kind }, bang = true })
  vim.api.nvim_win_set_cursor(0, cursor)
  v.payload = payload
  v.instance.open()
  v.choose()
  eq(v.lines(), expected, "visual paste changed the selected range")
  vim.cmd("silent undo")
  eq(v.lines(), lines, "visual paste was not a single undo step")
  vim.o.selection = "inclusive"
end
visual("v", { 1, 1 }, { 1, 3 }, " X ", { "aé中z" }, { "a X z" })
visual("v", { 1, 3 }, { 1, 1 }, "🙂", { "aé中z" }, { "a🙂z" })
visual("v", { 1, 3 }, { 1, 3 }, "new", { "last" }, { "lasnew" })
visual("v", { 1, 1 }, { 2, 1 }, "R\nS", { "abc", "def" }, { "aR", "Sf" })
visual("v", { 1, 1 }, { 1, 3 }, "X", { "aé中z" }, { "aX中z" }, true)
visual("V", { 1, 0 }, { 2, 0 }, "α\nβ\n", { "one", "two", "three" }, { "α", "β", "three" })
visual("V", { 1, 0 }, { 2, 0 }, "text", { "one", "two", "three" }, { "text", "three" })
visual("v", { 1, 0 }, { 1, 0 }, "é", { "" }, { "é" })
visual("v", { 1, 1 }, { 1, 2 }, "R\n", { "abcd" }, { "aR", "d" })
visual("v", { 1, 3 }, { 1, 1 }, "X", { "aé中z" }, { "aX中z" }, true)

-- Native end-of-line motions can leave the Visual cursor one byte past the line.
for _, case in ipairs({
  { motion = "v$", lines = { "abc", "def" }, expected = { "aX", "def" } },
  { motion = "v$", lines = { "aé🙂", "def" }, expected = { "aX", "def" } },
  { motion = "V$", lines = { "abc", "def" }, expected = { "X", "def" } },
  { motion = "Vj$", lines = { "abc", "def", "ghi" }, expected = { "X", "ghi" } },
}) do
  for _, selection in ipairs({ "inclusive", "exclusive" }) do
    s = fixture({ lines = case.lines, cursor = { 1, 1 } })
    vim.o.selection = selection
    vim.cmd.normal({ args = { case.motion }, bang = true })
    s.payload = "X"
    s.instance.open()
    s.choose()
    eq(#s.notices, 0, case.motion .. " was rejected without any target change")
    eq(s.lines(), case.expected, case.motion .. " changed the selected boundary")
    vim.cmd("silent undo")
    eq(s.lines(), case.lines, case.motion .. " was not a single undo step")
  end
end
vim.o.selection = "inclusive"

s = fixture({ lines = { "abc" }, cursor = { 1, 1 } })
vim.cmd.normal({ args = { "v$" }, bang = true })
s.instance.open()
vim.api.nvim_win_set_cursor(0, { 1, 0 })
s.choose()
eq(#s.registers, 0, "cursor moved after leaving Visual mode was accepted")

s = fixture()
vim.cmd.normal({ args = { vim.keycode("<C-v>") }, bang = true })
s.instance.open()
eq(#s.pickers, 0, "blockwise selection was not rejected")
vim.cmd.normal({ args = { vim.keycode("<Esc>") }, bang = true })

for _, stale in ipairs({
  function(v)
    vim.api.nvim_buf_set_lines(v.buffer, 0, 1, false, { "changed" })
  end,
  function()
    vim.api.nvim_win_set_cursor(0, { 1, 3 })
  end,
  function(v)
    vim.bo[v.buffer].modifiable = false
  end,
  function()
    vim.cmd("enew!")
  end,
  function(v)
    vim.api.nvim_buf_delete(v.buffer, { force = true })
  end,
}) do
  s = fixture()
  s.instance.open()
  stale(s)
  s.choose()
  eq(#s.registers, 0, "stale target changed the clipboard")
end
s = fixture()
s.during_decode = function()
  vim.api.nvim_win_set_cursor(0, { 1, 3 })
end
s.instance.open()
s.choose()
eq(#s.registers, 0, "target changed during decode was accepted")
s = fixture()
vim.cmd.normal({ args = { "v" }, bang = true })
vim.api.nvim_win_set_cursor(0, { 1, 3 })
s.instance.open()
vim.api.nvim_buf_set_mark(s.buffer, "<", 2, 0, {})
s.choose()
eq(#s.registers, 0, "changed visual selection was accepted")
s = fixture()
vim.cmd.normal({ args = { "v" }, bang = true })
vim.api.nvim_win_set_cursor(0, { 1, 3 })
s.instance.open()
vim.api.nvim_win_set_cursor(0, { 1, 1 })
vim.cmd.normal({ args = { "V" }, bang = true })
vim.api.nvim_win_set_cursor(0, { 1, 3 })
vim.cmd.normal({ args = { vim.keycode("<Esc>") }, bang = true })
s.choose()
eq(#s.registers, 0, "changed visual selection mode was accepted")
s = fixture()
s.deps.api = setmetatable({
  nvim_win_get_cursor = function()
    return { 1, 2 }
  end,
}, { __index = vim.api })
s.instance.open()
eq(#s.pickers, 0, "cursor inside a UTF-8 character was accepted")

s = fixture()
s.payload = "X"
local original_window = vim.api.nvim_get_current_win()
s.instance.open()
vim.cmd("vnew")
local other_window = vim.api.nvim_get_current_win()
s.choose()
eq(vim.api.nvim_get_current_win(), original_window, "paste did not restore its captured window")
eq(s.lines(), { "aéX中z", "second", "third" }, "paste used the picker-time current buffer")
vim.api.nvim_win_close(other_window, true)
s = fixture()
s.instance.open()
vim.cmd("vnew")
vim.api.nvim_win_close(original_window, true)
s.choose()
eq(#s.registers, 0, "closed target window was accepted")

for _, flag in ipairs({ "register_error", "register_status" }) do
  s = fixture()
  s[flag] = flag == "register_status" and 1 or true
  s.instance.open()
  s.choose()
  eq(s.lines(), { "aé中z", "second", "third" }, "register failure still edited the buffer")
end
s = fixture()
s.deps.api = setmetatable({
  nvim_put = function()
    error(marker)
  end,
}, { __index = vim.api })
s.instance.open()
s.choose()
assert(#s.notices > 0, "edit failure was not reported")

s = fixture()
s.instance.open()
s.list = "43\tremaining\n"
s.choose(nil, "ctrl-d")
eq(
  s.calls[2],
  { argv = { "cliphist", "delete" }, stdin = row },
  "delete did not receive complete row through stdin"
)
eq(s.pickers[2].rows, { "43\tremaining" }, "delete did not reload history")
eq(#s.registers, 0, "delete pasted text")
s = fixture()
s.instance.open()
s.result = { code = 1, stdout = marker }
s.choose(nil, "ctrl-d")
eq(#s.pickers, 1, "failed deletion reloaded the picker")
s = fixture()
s.instance.open()
s.result = { code = 124, signal = 15, stdout = marker }
s.choose()
eq(#s.registers, 0, "decode timeout edited the clipboard")

s = fixture()
s.instance.setup()
s.commands.ClipboardHistoryClear()
eq(#s.calls, 0, "clear did not require confirmation")
s.confirmation = 1
s.commands.ClipboardHistoryClear()
eq(s.calls[1].argv, { "cliphist", "wipe" }, "confirmed clear did not wipe history")
s.commands.ClipboardHistoryPause()
s.commands.ClipboardHistoryResume()
eq(
  s.calls[2].argv,
  { "systemctl", "--user", "stop", "cliphist.service" },
  "pause changed service enablement"
)
eq(
  s.calls[3].argv,
  { "systemctl", "--user", "start", "cliphist.service" },
  "resume changed service enablement"
)
s = fixture()
s.deps.executable = function(name)
  return name ~= "systemctl"
end
s.instance.setup()
s.commands.ClipboardHistoryPause()
eq(#s.calls, 0, "missing systemctl reached the service manager")

print("Neovim clipboard history assertions: ok")
