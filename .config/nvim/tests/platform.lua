local platform = require("config.platform")

local function executable_set(names)
  local present = {}
  for _, name in ipairs(names) do
    present[name] = true
  end

  return function(name)
    return present[name] == true
  end
end

local function assert_equal(actual, expected, label)
  assert(
    vim.deep_equal(actual, expected),
    string.format("%s\nexpected: %s\nactual: %s", label, vim.inspect(expected), vim.inspect(actual))
  )
end

local definitions = {
  pbcopy = {
    name = "pbcopy",
    copy = {
      ["+"] = { "pbcopy" },
      ["*"] = { "pbcopy" },
    },
    paste = {
      ["+"] = { "pbpaste" },
      ["*"] = { "pbpaste" },
    },
    cache_enabled = 0,
  },
  ["wl-copy"] = {
    name = "wl-copy",
    copy = {
      ["+"] = { "wl-copy", "--type", "text/plain" },
      ["*"] = { "wl-copy", "--primary", "--type", "text/plain" },
    },
    paste = {
      ["+"] = { "wl-paste", "--no-newline" },
      ["*"] = { "wl-paste", "--no-newline", "--primary" },
    },
    cache_enabled = 1,
  },
  tmux = {
    name = "tmux",
    copy = {
      ["+"] = { "tmux", "load-buffer", "-w", "-" },
      ["*"] = { "tmux", "load-buffer", "-w", "-" },
    },
    paste = {
      ["+"] = { "tmux", "save-buffer", "-" },
      ["*"] = { "tmux", "save-buffer", "-" },
    },
    cache_enabled = 1,
  },
  osc52 = "osc52",
}

local cases = {
  {
    context = {
      platform = "macos",
      environment = {},
      executable = executable_set({ "pbcopy", "pbpaste" }),
    },
    provider = "pbcopy",
  },
  {
    context = {
      platform = "linux",
      environment = { WAYLAND_DISPLAY = "wayland-1" },
      executable = executable_set({ "wl-copy", "wl-paste" }),
    },
    provider = "wl-copy",
  },
  {
    context = {
      platform = "linux",
      environment = { TMUX = "/tmp/tmux/default,1,0" },
      executable = executable_set({ "tmux" }),
    },
    provider = "tmux",
  },
  {
    context = {
      platform = "macos",
      environment = { TMUX = "/tmp/tmux/default,1,0" },
      executable = executable_set({ "tmux" }),
    },
    provider = "tmux",
  },
  {
    context = {
      platform = "linux",
      environment = {},
      executable = executable_set({}),
    },
    provider = "osc52",
  },
}

for _, case in ipairs(cases) do
  local provider = platform.select_clipboard(case.context)
  assert(provider == case.provider, string.format("expected %s, got %s", case.provider, provider))
  assert_equal(
    platform.clipboard_definition(provider),
    definitions[provider],
    provider .. " definition mismatch"
  )
end

local incomplete_contexts = {
  {},
  { platform = "linux" },
  { platform = "linux", environment = {} },
}

for _, context in ipairs(incomplete_contexts) do
  assert(not pcall(platform.select_clipboard, context), "incomplete clipboard context must fail")
end

assert(not pcall(platform.clipboard_definition, "xsel"), "unsupported clipboard provider must fail")

assert(type(platform.tmux_origin) == "function", "tmux context must be parsed independently")
local origin =
  assert(platform.tmux_origin({ TMUX = "/tmp/quoted ' socket,42,3", TMUX_PANE = "%7" }))
assert_equal(
  origin,
  { socket = "/tmp/quoted ' socket", pid = "42", session = "$3", pane = "%7" },
  "literal origin"
)
for _, env in ipairs({
  {},
  { TMUX = "relative,42,3", TMUX_PANE = "%7" },
  { TMUX = "/tmp/sock,no,3", TMUX_PANE = "%7" },
  { TMUX = "/tmp/sock,42,3", TMUX_PANE = "7" },
}) do
  assert(platform.tmux_origin(env) == nil, "invalid origin is unavailable")
end
local argv = platform.tmux_probe_argv(origin)
assert_equal(
  { argv[1], argv[2], argv[3], argv[4] },
  { "tmux", "-u", "-S", origin.socket },
  "explicit socket"
)
assert_equal(
  { argv[5], argv[6], argv[7], argv[8] },
  { "list-panes", "-s", "-t", "$3" },
  "originating session"
)
for _, case in ipairs({
  { text = "42\t$3\t%7\t1\ton\n", want = { configured = true, status_enabled = true } },
  { text = "42\t$3\t%7\t1\toff\n", want = { configured = true, status_enabled = false } },
  { text = "42\t$3\t%7\t\t2\n", want = { configured = false, status_enabled = true } },
  { text = "42\t$3\t%7\t0\ton\n", want = { configured = false, status_enabled = true } },
  {
    text = "42\t$3\t%8\t1\ton\n42\t$3\t%7\t1\toff\n",
    want = { configured = true, status_enabled = false },
  },
  { text = "99\t$3\t%7\t1\ton\n" },
  { text = "42\t$1\t%7\t1\ton\n" },
  { text = "42\t$3\t%9\t1\ton\n" },
  { text = "42\t$3\t%7\t1\tinvalid\n" },
  { text = "" },
  { text = "42\t$3\t%7\t1\ton\n", code = 124 },
}) do
  local result = platform.parse_tmux_probe(origin, { code = case.code or 0, stdout = case.text })
  assert_equal(
    result,
    case.want,
    "probe rejects failed or mismatched identity; respects session status"
  )
end

local root = vim.fn.tempname() .. " quoted ' helpers"
vim.fn.mkdir(root .. "/nvim", "p")
vim.fn.mkdir(root .. "/dotfiles", "p")
vim.fn.mkdir(root .. "/tmux/scripts", "p")
assert(
  platform.dotfiles_helper("git_summary", root .. "/nvim") == nil,
  "missing helper is optional"
)
local helper = root .. "/dotfiles/git-summary"
vim.fn.writefile({ "#!/bin/sh", "exit 0" }, helper)
assert(
  platform.dotfiles_helper("git_summary", root .. "/nvim") == nil,
  "nonexecutable helper is optional"
)
assert(vim.uv.fs_chmod(helper, 448))
assert_equal(
  platform.dotfiles_helper("git_summary", root .. "/nvim"),
  helper,
  "literal executable helper"
)
assert(vim.uv.fs_symlink(helper, root .. "/tmux/scripts/location-pins"))
assert_equal(
  platform.dotfiles_helper("location_pins", root .. "/nvim"),
  root .. "/tmux/scripts/location-pins",
  "managed helper symlink"
)
assert(platform.dotfiles_helper("unknown", root .. "/nvim") == nil, "no arbitrary provider lookup")
vim.fn.delete(root, "rf")

print("platform clipboard matrix: ok")
