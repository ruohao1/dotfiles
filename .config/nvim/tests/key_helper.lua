vim.g.mapleader = " "

local function eq(actual, expected, label)
  assert(
    vim.deep_equal(actual, expected),
    string.format(
      "%s\nexpected: %s\nactual:   %s",
      label,
      vim.inspect(expected),
      vim.inspect(actual)
    )
  )
end

local function exact_keys(value, expected, label)
  local actual = {}
  for key in pairs(value) do
    actual[tostring(key)] = true
  end

  local wanted = {}
  for _, key in ipairs(expected) do
    wanted[key] = true
  end
  eq(actual, wanted, label)
end

local function count_plain(haystack, needle)
  local count = 0
  local offset = 1
  while true do
    local first = haystack:find(needle, offset, true)
    if not first then
      return count
    end
    count = count + 1
    offset = first + #needle
  end
end

local function normalized_modes(mode, label)
  local modes = type(mode) == "table" and vim.deepcopy(mode) or { mode }
  assert(#modes > 0, label .. " must declare at least one mode")
  table.sort(modes)
  return modes
end

local test_file = debug.getinfo(1, "S").source:sub(2)
local nvim_root = vim.env.DOTFILES_NVIM_ROOT or vim.fs.dirname(vim.fs.dirname(test_file))
vim.opt.runtimepath:prepend(nvim_root)

local specs = require("plugins.key-helper")
eq(#specs, 1, "key helper plugin count")

local plugin = specs[1]
exact_keys(plugin, { "1", "dependencies", "event", "opts", "version" }, "WhichKey spec keys")
eq(plugin[1], "folke/which-key.nvim", "WhichKey repository")
eq(plugin.version, false, "WhichKey rolling version policy")
eq(plugin.event, "VeryLazy", "WhichKey load event")
eq(plugin.dependencies, { "nvim-mini/mini.icons" }, "WhichKey icon dependency")
assert(plugin.keys == nil and plugin.config == nil, "WhichKey must not create action mappings")

exact_keys(
  plugin.opts,
  { "delay", "filter", "plugins", "preset", "spec", "triggers" },
  "WhichKey option keys"
)
eq(plugin.opts.preset, "helix", "WhichKey preset")
eq(plugin.opts.delay, 300, "WhichKey delay")
assert(plugin.opts.defer == nil, "WhichKey must preserve the default defer policy")
assert(plugin.opts.timeoutlen == nil, "WhichKey must not configure timeoutlen")

local allowed_modes = { n = true, o = true, x = true }
for _, mode in ipairs({ "n", "x", "o" }) do
  assert(plugin.opts.filter({ mode = mode }), "filter rejected approved mode " .. mode)
end
for _, mode in ipairs({ "v", "i", "s", "c", "t", "", "N", "no", "!" }) do
  assert(not plugin.opts.filter({ mode = mode }), "filter accepted prohibited mode " .. mode)
end
assert(not plugin.opts.filter({}), "filter accepted a missing scalar mode")
assert(not plugin.opts.filter({ mode = { "n" } }), "filter accepted a nonscalar mode")

local required_triggers = {
  { "<auto>", { "n", "o", "x" } },
  { "<leader>", { "n", "x" } },
  { "g", { "n", "x" } },
  { "z", { "n" } },
  { "[", { "n" } },
  { "]", { "n" } },
  { "<C-w>", { "n" } },
  { "'", { "n" } },
  { "`", { "n" } },
  { '"', { "n", "x" } },
}

local expected_trigger_counts = {}
for _, required in ipairs(required_triggers) do
  local identity = required[1] .. "\0" .. table.concat(required[2], "\0")
  expected_trigger_counts[identity] = 1
end

local trigger_counts = {}
for index, trigger in ipairs(plugin.opts.triggers) do
  exact_keys(trigger, { "1", "mode" }, "WhichKey trigger " .. index .. " keys")
  assert(type(trigger[1]) == "string" and trigger[1] ~= "", "WhichKey trigger prefix is invalid")

  local modes = normalized_modes(trigger.mode, "WhichKey trigger " .. trigger[1])
  for _, mode in ipairs(modes) do
    assert(allowed_modes[mode], "WhichKey trigger installed a prohibited mode: " .. tostring(mode))
    assert(mode ~= "v", "WhichKey trigger must use x instead of v")
  end

  local identity = trigger[1] .. "\0" .. table.concat(modes, "\0")
  trigger_counts[identity] = (trigger_counts[identity] or 0) + 1
end
eq(trigger_counts, expected_trigger_counts, "complete WhichKey trigger contract")

eq(plugin.opts.plugins, {
  marks = true,
  registers = true,
  spelling = { enabled = false },
  presets = {
    operators = true,
    motions = true,
    text_objects = true,
    windows = true,
    nav = true,
    z = true,
    g = true,
  },
}, "WhichKey built-in descriptions")

local expected_groups = {
  ["<leader>b\0n"] = "Buffers",
  ["<leader>c\0n\0x"] = "Code",
  ["<leader>f\0n"] = "Find",
  ["<leader>h\0n"] = "Line pins",
  ["<leader>j\0n\0x"] = "Notebook",
  ["<leader>t\0n"] = "Toggle",
}
local actual_groups = {}
for index, group in ipairs(plugin.opts.spec) do
  exact_keys(group, { "1", "group", "mode" }, "WhichKey group " .. index .. " keys")
  assert(type(group[1]) == "string" and group[1] ~= "", "WhichKey group prefix is invalid")
  assert(type(group.group) == "string" and group.group ~= "", "WhichKey group label is invalid")
  assert(
    group[2] == nil and group.rhs == nil and group.callback == nil,
    "WhichKey group became executable"
  )
  assert(group[1] ~= "<leader>?", "manual key-helper mapping is forbidden")

  local modes = normalized_modes(group.mode, "WhichKey group " .. group[1])
  for _, mode in ipairs(modes) do
    assert(mode == "n" or mode == "x", "WhichKey group installed a prohibited mode: " .. mode)
    assert(mode ~= "v", "WhichKey group must use x instead of v")
  end
  local identity = group[1] .. "\0" .. table.concat(modes, "\0")
  assert(actual_groups[identity] == nil, "duplicate WhichKey group " .. group[1])
  actual_groups[identity] = group.group
end
eq(actual_groups, expected_groups, "WhichKey leader groups")

local plugin_source_path = vim.fs.joinpath(nvim_root, "tests", "plugin_source.lua")
local plugin_source = table.concat(vim.fn.readfile(plugin_source_path), "\n")
eq(
  count_plain(plugin_source, '["which-key.nvim"] = true'),
  1,
  "WhichKey generated doc/tags allowance"
)

local config_root = vim.fs.dirname(nvim_root)
local checker_source = table.concat(
  vim.fn.readfile(vim.fs.joinpath(config_root, "dotfiles", "check-terminal-stack")),
  "\n"
)

local configured_start = assert(
  checker_source:find("DOTFILES_REQUIRE_EDITING_PLUGINS=1", 1, true),
  "configured Neovim invocation start is missing"
)
local configured_finish = assert(
  checker_source:find('> "$check_tmp/nvim-tests.txt" 2>&1', configured_start, true),
  "configured Neovim invocation end is missing"
)
local configured_invocation = checker_source:sub(configured_start, configured_finish)
local configured_command_count = 0
for line in configured_invocation:gmatch("[^\n]+") do
  if line:match("^%s+%-c%s") or line:match("^%s+%-%-cmd%s") or line:match("^%s+%+%S") then
    configured_command_count = configured_command_count + 1
  end
end
assert(
  configured_command_count <= 10,
  "configured Neovim command count exceeds 10: " .. configured_command_count
)

for _, fragment in ipairs({
  'keys == ["fzf-lua", "image.nvim", "jupytext.nvim", "lazy.nvim", "mini.icons", "mini.pairs", "mini.starter", "mini.surround", "molten-nvim", "nvim-treesitter", "oil.nvim", "otter.nvim", "quarto-nvim", "smart-splits.nvim", "tokyonight.nvim", "which-key.nvim"]',
  "which-key.nvim)",
  "nvim_tags_sources='doc/which-key.nvim.txt'",
  "lazy.nvim|fzf-lua|jupytext.nvim|oil.nvim|otter.nvim|nvim-treesitter|tokyonight.nvim|which-key.nvim)",
  '"which-key.nvim": {"branch":"main","commit":"3aab2147e74890957785941f0c1ad87d0a44c15a"}',
  "approved_nvim_plugins='fzf-lua image.nvim jupytext.nvim lazy.nvim mini.icons mini.pairs mini.starter mini.surround molten-nvim nvim-treesitter oil.nvim otter.nvim quarto-nvim smart-splits.nvim tokyonight.nvim which-key.nvim'",
  'which_key_dir="$nvim_data_root/lazy/which-key.nvim"',
  "Neovim lockfile contains exactly sixteen object-valued pinned plugins",
  "Neovim sixteen-plugin revision and source trust gate satisfied",
  "DOTFILES_KEY_HELPER_LIVE=1",
  '-l "$nvim_root/tests/key_helper.lua"',
  'vim.api.nvim_exec_autocmds("User", { pattern = "VeryLazy", modeline = false })',
  'require("lazy.core.config").plugins["which-key.nvim"]',
  '"WhichKey did not load on VeryLazy"',
  'for _, name in ipairs({ "platform", "foundation", "key_helper" }) do',
  'dofile(vim.fs.joinpath(vim.env.DOTFILES_NVIM_ROOT, "tests", name .. ".lua"))',
  "Neovim WhichKey modes, delay, completion, cancellation, cleanup, and diagnostics pass",
  "MiniSurround, WhichKey, smart-splits",
}) do
  assert(
    checker_source:find(fragment, 1, true),
    "checker missing key-helper integration fragment: " .. fragment
  )
end

eq(
  count_plain(checker_source, '"$nvim_root/lua/plugins/key-helper.lua"'),
  2,
  "checker key-helper plugin inventory count"
)
eq(
  count_plain(checker_source, "$nvim_root/tests/key_helper.lua"),
  3,
  "checker direct key-helper test reference count"
)
for _, stale in ipairs({
  "exact fifteen-object lock is accepted",
  "exactly fifteen object-valued pinned plugins",
  "exact fifteen-plugin object boundary",
  "fifteen-plugin revision and source trust",
}) do
  assert(not checker_source:find(stale, 1, true), "stale checker wording remains: " .. stale)
end

if vim.env.DOTFILES_KEY_HELPER_LIVE ~= "1" then
  print("Neovim key helper static assertions: ok")
  return
end

local mini_icons_root =
  assert(vim.env.DOTFILES_MINI_ICONS_ROOT, "DOTFILES_MINI_ICONS_ROOT must be set")
local which_key_root =
  assert(vim.env.DOTFILES_WHICH_KEY_ROOT, "DOTFILES_WHICH_KEY_ROOT must be set")
vim.opt.runtimepath:prepend(mini_icons_root)
vim.opt.runtimepath:prepend(which_key_root)

require("mini.icons").setup()
require("which-key").setup(plugin.opts)

local Config = require("which-key.config")
assert(
  vim.wait(1000, function()
    return Config.loaded
  end),
  "WhichKey did not load"
)
eq(Config.options.preset, "helix", "configured WhichKey preset")
eq(Config.options.plugins.spelling.enabled, false, "configured spelling replacement")
assert(type(Config.defer) == "function", "WhichKey default defer function is missing")
eq(Config.defer({ mode = "v", operator = "" }), false, "characterwise Visual defer")
eq(Config.defer({ mode = "V", operator = "" }), true, "linewise Visual defer")
eq(Config.defer({ mode = "<C-V>", operator = "" }), true, "blockwise Visual defer")
eq(Config.defer({ mode = "o", operator = "d" }), false, "Operator-pending defer")

local automatic_trigger_modes = {}
for mode, enabled in pairs(Config.triggers.modes) do
  assert(allowed_modes[mode], "automatic WhichKey trigger has prohibited mode: " .. tostring(mode))
  assert(enabled == true, "automatic WhichKey trigger mode is not enabled: " .. tostring(mode))
  automatic_trigger_modes[mode] = true
end
eq(automatic_trigger_modes, allowed_modes, "automatic WhichKey trigger modes")

local Buf = require("which-key.buf")
local Triggers = require("which-key.triggers")
local bufnr = vim.api.nvim_get_current_buf()
local function which_key_trigger(lhs, mode)
  local mapping = vim.fn.maparg(lhs, mode, false, true)
  return type(mapping) == "table"
    and type(mapping.desc) == "string"
    and mapping.desc:find("which-key-trigger", 1, true) ~= nil
end

local leader_fixtures = {
  { lhs = "<leader>bx", mode = "n", label = "Buffers" },
  { lhs = "<leader>cx", mode = "n", label = "Code" },
  { lhs = "<leader>fx", mode = "n", label = "Find" },
  { lhs = "<leader>hx", mode = "n", label = "Line pins" },
  { lhs = "<leader>jx", mode = "n", label = "Notebook" },
  { lhs = "<leader>tx", mode = "n", label = "Toggle" },
  { lhs = "<leader>cx", mode = "x", label = "Code" },
  { lhs = "<leader>jx", mode = "x", label = "Notebook" },
}
local created_leader_fixtures = {}

local fixture_ok, fixture_error = xpcall(function()
  for _, fixture in ipairs(leader_fixtures) do
    assert(
      vim.tbl_isempty(vim.fn.maparg(fixture.lhs, fixture.mode, false, true)),
      fixture.mode .. " fixture mapping already exists for " .. fixture.lhs
    )
    vim.keymap.set(fixture.mode, fixture.lhs, "<Nop>", {
      buffer = bufnr,
      desc = "Key helper test fixture: " .. fixture.label,
    })
    table.insert(created_leader_fixtures, fixture)
  end

  local mode_states = {}
  for _, mode in ipairs({ "n", "x", "o", "v", "i", "s", "c", "t" }) do
    mode_states[mode] = Buf.get({ buf = bufnr, mode = mode })
  end

  local live_groups = {}
  for _, group in ipairs({
    { lhs = "<leader>b", label = "Buffers" },
    { lhs = "<leader>c", label = "Code" },
    { lhs = "<leader>f", label = "Find" },
    { lhs = "<leader>h", label = "Line pins" },
    { lhs = "<leader>j", label = "Notebook" },
    { lhs = "<leader>t", label = "Toggle" },
  }) do
    local modes = {}
    for _, mode in ipairs({ "n", "x", "o", "v", "i", "s", "c", "t" }) do
      local node = mode_states[mode].tree:find(group.lhs)
      if node and node.group == true then
        assert(mode == "n" or mode == "x", "live group has prohibited mode " .. mode)
        eq(node.desc, group.label, mode .. " live group label for " .. group.lhs)
        table.insert(modes, mode)
      end
    end
    assert(#modes > 0, "live group is missing for " .. group.lhs)
    live_groups[group.lhs .. "\0" .. table.concat(modes, "\0")] = group.label
  end
  eq(live_groups, expected_groups, "live WhichKey leader groups")

  assert(
    vim.wait(1000, function()
      local seen = {}
      for _, trigger in pairs(Triggers._triggers) do
        seen[trigger.mode] = true
      end
      return seen.n and seen.x and seen.o
    end, 10),
    "WhichKey trigger registry did not populate"
  )

  local installed_trigger_modes = {}
  for id, trigger in pairs(Triggers._triggers) do
    assert(
      allowed_modes[trigger.mode],
      string.format("forbidden trigger mode %s at %s", tostring(trigger.mode), tostring(id))
    )
    installed_trigger_modes[trigger.mode] = true
  end
  eq(installed_trigger_modes, allowed_modes, "installed WhichKey trigger modes")

  assert(
    vim.wait(1000, function()
      for _, required in ipairs(required_triggers) do
        if required[1] ~= "<auto>" then
          for _, mode in ipairs(required[2]) do
            if not which_key_trigger(required[1], mode) then
              return false
            end
          end
        end
      end
      return true
    end, 10),
    "approved WhichKey triggers did not install"
  )

  for _, required in ipairs(required_triggers) do
    if required[1] ~= "<auto>" then
      for _, mode in ipairs(required[2]) do
        assert(which_key_trigger(required[1], mode), mode .. " trigger missing for " .. required[1])
      end
    end
  end
end, debug.traceback)

local fixture_cleanup_errors = {}
for index = #created_leader_fixtures, 1, -1 do
  local fixture = created_leader_fixtures[index]
  local deleted, delete_error = pcall(vim.keymap.del, fixture.mode, fixture.lhs, { buffer = bufnr })
  if not deleted then
    table.insert(
      fixture_cleanup_errors,
      string.format("delete %s %s: %s", fixture.mode, fixture.lhs, tostring(delete_error))
    )
  end
end
for _, fixture in ipairs(leader_fixtures) do
  if not vim.tbl_isempty(vim.fn.maparg(fixture.lhs, fixture.mode, false, true)) then
    table.insert(
      fixture_cleanup_errors,
      fixture.mode .. " fixture mapping leaked for " .. fixture.lhs
    )
  end
end

local fixture_cleanup_error = #fixture_cleanup_errors > 0
    and table.concat(fixture_cleanup_errors, "\n")
  or nil
if not fixture_ok then
  if fixture_cleanup_error then
    fixture_error = fixture_error .. "\nfixture cleanup failed:\n" .. fixture_cleanup_error
  end
  error(fixture_error, 0)
end
assert(not fixture_cleanup_error, fixture_cleanup_error)

local State = require("which-key.state")
eq(State.delay({ mode = "n", keys = "<leader>" }), 300, "normal leader delay")
eq(State.delay({ mode = "x", keys = "g", plugin = "presets" }), 300, "plugin delay remains fixed")

local View = require("which-key.view")
View.hide()
local original_timer = View.timer
local original_state = State.state
local timeout
local repeat_interval
local scheduled_callback
local timer_ok, timer_error = xpcall(function()
  View.timer = {
    start = function(_, requested, repeating, scheduled)
      timeout = requested
      repeat_interval = repeating
      scheduled_callback = scheduled
    end,
  }
  State.state = {
    mode = { mode = "n" },
    node = { keys = "<leader>", plugin = nil },
  }
  View.update()
  eq(timeout, 300, "popup timer timeout")
  eq(repeat_interval, 0, "popup timer repeat")
  assert(type(scheduled_callback) == "function", "popup timer callback")
end, debug.traceback)
View.timer = original_timer
State.state = original_state
assert(timer_ok, timer_error)

local action_count = 0
local action_enabled = true
local mapping_created = false
local input_timers = {}
local original_raw_delay = rawget(Config, "delay")

local function flush_typeahead()
  vim.api.nvim_feedkeys("", "x", false)
end

local function cleanup_dynamic_test()
  local errors = {}
  local function cleanup_step(label, callback)
    local ok, cleanup_error = pcall(callback)
    if not ok then
      table.insert(errors, label .. ": " .. tostring(cleanup_error))
    end
  end

  action_enabled = false
  cleanup_step("restore raw Config.delay", function()
    rawset(Config, "delay", original_raw_delay)
  end)
  for index, timer in ipairs(input_timers) do
    cleanup_step("stop pending input timer " .. index, function()
      if timer and not timer:is_closing() then
        timer:stop()
        timer:close()
      end
    end)
  end
  cleanup_step("stop View timer", function()
    if View.timer then
      View.timer:stop()
    end
  end)
  cleanup_step("stop WhichKey State", function()
    State.stop()
  end)
  cleanup_step("hide WhichKey View", function()
    View.hide()
  end)

  if mapping_created then
    cleanup_step("drain pending test input first pass", function()
      flush_typeahead()
    end)
    cleanup_step("drain pending test input second pass", function()
      flush_typeahead()
    end)
    cleanup_step("delete test mapping", function()
      vim.keymap.del("n", "<leader>qa")
      mapping_created = false
    end)
  end

  if #errors > 0 then
    return table.concat(errors, "\n")
  end
end

local dynamic_ok, dynamic_error = xpcall(function()
  local leader_trigger = vim.fn.maparg("<leader>", "n", false, true)
  assert(type(leader_trigger.callback) == "function", "leader trigger callback missing")
  assert(vim.tbl_isempty(vim.fn.maparg("<leader>qa", "n", false, true)), "test mapping exists")

  vim.keymap.set("n", "<leader>qa", function()
    if action_enabled then
      action_count = action_count + 1
    end
  end, { desc = "Key helper test action" })
  mapping_created = true

  table.insert(
    input_timers,
    vim.defer_fn(function()
      vim.api.nvim_input("qa")
    end, 0)
  )
  leader_trigger.callback()
  flush_typeahead()
  eq(action_count, 1, "fast mapping execution count")
  flush_typeahead()
  eq(action_count, 1, "fast mapping second-flush execution count")
  assert(not View.valid(), "fast mapping opened WhichKey")

  rawset(Config, "delay", 0)
  local before_buffer = vim.api.nvim_get_current_buf()
  local before_lines = vim.api.nvim_buf_get_lines(before_buffer, 0, -1, false)
  local popup_seen = false
  table.insert(
    input_timers,
    vim.defer_fn(function()
      popup_seen = vim.wait(1000, function()
        return View.valid()
      end, 5)
      vim.api.nvim_input("<Esc>")
    end, 0)
  )
  leader_trigger.callback()
  assert(popup_seen, "WhichKey popup did not open before the upper deadline")
  assert(
    vim.wait(1000, function()
      return not View.valid()
    end, 5),
    "WhichKey popup did not close after Escape"
  )
  eq(vim.api.nvim_get_current_buf(), before_buffer, "WhichKey popup current buffer")
  eq(
    vim.api.nvim_buf_get_lines(before_buffer, 0, -1, false),
    before_lines,
    "WhichKey popup buffer text"
  )
  eq(action_count, 1, "WhichKey popup cancellation action count")

  for _, notification in ipairs(require("which-key.mappings").notifs) do
    assert(
      notification.level < vim.log.levels.ERROR,
      "WhichKey mapping diagnostic: " .. notification.msg
    )
  end
end, debug.traceback)

local cleanup_error = cleanup_dynamic_test()
if not dynamic_ok then
  if cleanup_error then
    dynamic_error = dynamic_error .. "\ncleanup failed:\n" .. cleanup_error
  end
  error(dynamic_error, 0)
end
assert(not cleanup_error, cleanup_error)
eq(rawget(Config, "delay"), original_raw_delay, "raw Config.delay restoration")
eq(action_count, 1, "cleaned-up action count")
assert(vim.tbl_isempty(vim.fn.maparg("<leader>qa", "n", false, true)), "test mapping leaked")
print("Neovim key helper live assertions: ok")
