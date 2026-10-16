local function eq(actual, expected, label)
  assert(
    vim.deep_equal(actual, expected),
    string.format("%s\nexpected: %s\nactual: %s", label, vim.inspect(expected), vim.inspect(actual))
  )
end

local function contains(items, expected)
  for _, item in ipairs(items) do
    if item == expected then
      return true
    end
  end
  return false
end

local test_file = debug.getinfo(1, "S").source:sub(2)
local nvim_root = vim.fs.dirname(vim.fs.dirname(test_file))
local init_source = table.concat(vim.fn.readfile(vim.fs.joinpath(nvim_root, "init.lua")), "\n")

assert(
  init_source:find('vim.fn.has("nvim-0.12")', 1, true),
  "startup guard must require Neovim 0.12"
)
assert(
  init_source:find("Neovim 0.12 or newer is required", 1, true),
  "startup guard must explain the Neovim 0.12 floor"
)

local function with_fixture(callback)
  local fixture = vim.fn.tempname()
  assert(type(fixture) == "string" and fixture ~= "", "tempname must return a path")
  assert(vim.fn.mkdir(fixture, "p") == 1, "could not create navigation fixture")

  local ok, result = xpcall(function()
    callback(vim.fs.normalize(fixture))
  end, debug.traceback)

  local cleanup_result = vim.fn.delete(fixture, "rf")
  assert(cleanup_result == 0, "could not remove navigation fixture")
  if not ok then
    error(result, 0)
  end
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

local root = require("navigation.root")
assert(type(root.resolve) == "function", "root.resolve must be public")
assert(type(root._test) == "table", "root test boundary missing")
assert(type(root._test.new) == "function", "root test constructor missing")
assert(type(root._test.resolve_context) == "function", "pure root resolver missing")
assert(type(root.find) == "function", "root.find must be public")
assert(type(root._test.find_path) == "function", "pure non-fallback root lookup missing")

with_fixture(function(fixture)
  local paths = {
    outside = "/",
    git_dir = vim.fs.joinpath(fixture, "git-dir"),
    worktree = vim.fs.joinpath(fixture, "worktree"),
    outer = vim.fs.joinpath(fixture, "outer"),
    nested = vim.fs.joinpath(fixture, "outer", "nested"),
    jj_outer = vim.fs.joinpath(fixture, "jj-outer"),
    git_inner = vim.fs.joinpath(fixture, "jj-outer", "git-inner"),
    git_outer = vim.fs.joinpath(fixture, "git-outer"),
    jj_inner = vim.fs.joinpath(fixture, "git-outer", "jj-inner"),
    global = vim.fs.joinpath(fixture, "global"),
    tab = vim.fs.joinpath(fixture, "tab"),
    window = vim.fs.joinpath(fixture, "window"),
  }

  make_directory(vim.fs.joinpath(paths.git_dir, ".git"))
  make_directory(vim.fs.joinpath(paths.git_dir, "src"))
  make_directory(vim.fs.joinpath(paths.worktree, "src"))
  write_file(vim.fs.joinpath(paths.worktree, ".git"), { "gitdir: ../bare/worktrees/demo" })
  make_directory(vim.fs.joinpath(paths.outer, ".git"))
  make_directory(vim.fs.joinpath(paths.nested, ".jj"))
  make_directory(vim.fs.joinpath(paths.nested, "src"))
  make_directory(vim.fs.joinpath(paths.jj_outer, ".jj"))
  make_directory(vim.fs.joinpath(paths.git_inner, ".git"))
  make_directory(vim.fs.joinpath(paths.git_inner, "src"))
  make_directory(vim.fs.joinpath(paths.git_outer, ".git"))
  make_directory(vim.fs.joinpath(paths.jj_inner, ".jj"))
  make_directory(vim.fs.joinpath(paths.jj_inner, "src"))

  for _, repo in ipairs({ paths.global, paths.tab, paths.window }) do
    make_directory(vim.fs.joinpath(repo, ".git"))
    make_directory(vim.fs.joinpath(repo, "src"))
  end

  eq(
    root._test.find_path(vim.fs.joinpath(paths.git_dir, "src", "main.lua")),
    paths.git_dir,
    "non-fallback .git directory root"
  )
  eq(
    root._test.find_path(vim.fs.joinpath(paths.worktree, "src", "main.lua")),
    paths.worktree,
    "non-fallback .git file root"
  )
  eq(
    root._test.find_path(vim.fs.joinpath(paths.nested, "src", "main.lua")),
    paths.nested,
    "non-fallback nearest .jj root"
  )
  eq(root._test.find_path(paths.outside), nil, "non-project directory has no root")
  eq(root._test.find_path("oil-ssh://host/project/file.lua"), nil, "remote path has no root")
  eq(root._test.find_path(""), nil, "empty path has no root")
  eq(
    root.find(vim.fs.joinpath(paths.git_inner, "src", "main.lua")),
    paths.git_inner,
    "public root lookup"
  )

  eq(
    root._test.resolve_context({
      name = vim.fs.joinpath(paths.git_dir, "src", "main.lua"),
      buftype = "",
      cwd = paths.outside,
    }),
    paths.git_dir,
    ".git directory root"
  )

  eq(
    root._test.resolve_context({
      name = vim.fs.joinpath(paths.worktree, "src", "main.lua"),
      buftype = "",
      cwd = paths.outside,
    }),
    paths.worktree,
    ".git file root"
  )

  eq(
    root._test.resolve_context({
      name = vim.fs.joinpath(paths.nested, "src", "main.lua"),
      buftype = "",
      cwd = paths.outside,
    }),
    paths.nested,
    "nearest nested .jj root"
  )

  eq(
    root._test.resolve_context({
      name = vim.fs.joinpath(paths.git_inner, "src", "new.lua"),
      buftype = "",
      cwd = paths.outside,
    }),
    paths.git_inner,
    "nearer .git beats farther .jj"
  )

  eq(
    root._test.resolve_context({
      name = vim.fs.joinpath(paths.jj_inner, "src", "new.lua"),
      buftype = "",
      cwd = paths.outside,
    }),
    paths.jj_inner,
    "nearer .jj beats farther .git"
  )

  eq(
    root._test.resolve_context({
      name = "oil://" .. vim.fs.joinpath(paths.git_dir, "src"),
      buftype = "nofile",
      cwd = paths.outside,
      oil_dir = vim.fs.joinpath(paths.git_dir, "src"),
    }),
    paths.git_dir,
    "Oil directory root"
  )

  eq(
    root._test.resolve_context({
      name = "term://host//1:zsh",
      buftype = "terminal",
      cwd = vim.fs.joinpath(paths.worktree, "src"),
    }),
    paths.worktree,
    "special buffer uses cwd"
  )

  eq(
    root._test.resolve_context({
      name = vim.fs.joinpath(paths.worktree, "src", "new.lua"),
      buftype = "",
      cwd = paths.outside,
    }),
    paths.worktree,
    "new local file resolves lexically"
  )

  eq(
    root._test.resolve_context({
      name = "oil-ssh://host/project",
      buftype = "nofile",
      cwd = vim.fs.joinpath(paths.worktree, "src"),
      oil_dir = "oil-ssh://host/project",
    }),
    paths.worktree,
    "remote Oil path falls back to cwd"
  )

  eq(
    root._test.resolve_context({ name = "", buftype = "", cwd = paths.outside }),
    paths.outside,
    "unnamed buffer falls back to cwd"
  )

  eq(
    root._test.resolve_context({
      name = "https://example.invalid/file.lua",
      buftype = "",
      cwd = vim.fs.joinpath(paths.git_dir, "src"),
    }),
    paths.git_dir,
    "unsupported URI falls back to cwd"
  )

  local cwd_values = {
    vim.fs.joinpath(paths.global, "src"),
    vim.fs.joinpath(paths.tab, "src"),
    vim.fs.joinpath(paths.window, "src"),
  }
  local cwd_index = 0
  local dynamic_cwd = root._test.new({
    current_buffer = function()
      return 11
    end,
    buffer_name = function()
      return ""
    end,
    buffer_type = function()
      return ""
    end,
    getcwd = function()
      cwd_index = cwd_index + 1
      return cwd_values[cwd_index]
    end,
    oil_directory = function()
      return nil
    end,
  })

  eq(dynamic_cwd.resolve(), paths.global, "dynamic global cwd")
  eq(dynamic_cwd.resolve(), paths.tab, "dynamic tab cwd")
  eq(dynamic_cwd.resolve(), paths.window, "dynamic window cwd")
  eq(cwd_index, 3, "cwd read on every invocation")

  local explicit_cwd = root._test.new({
    current_buffer = function()
      return 12
    end,
    buffer_name = function()
      return ""
    end,
    buffer_type = function()
      return ""
    end,
    getcwd = function()
      error("explicit cwd must skip getcwd")
    end,
    oil_directory = function()
      return nil
    end,
  })
  eq(
    explicit_cwd.resolve({ cwd = vim.fs.joinpath(paths.git_dir, "src") }),
    paths.git_dir,
    "explicit cwd bypasses runtime cwd"
  )

  local oil_directories = {
    vim.fs.joinpath(paths.git_dir, "src"),
    vim.fs.joinpath(paths.worktree, "src"),
  }
  local oil_index = 0
  local dynamic_oil = root._test.new({
    current_buffer = function()
      return 13
    end,
    buffer_name = function()
      return "oil:///dynamic"
    end,
    buffer_type = function()
      return "nofile"
    end,
    getcwd = function()
      return paths.outside
    end,
    oil_directory = function()
      oil_index = oil_index + 1
      return oil_directories[oil_index]
    end,
  })

  eq(dynamic_oil.resolve(), paths.git_dir, "dynamic first Oil directory")
  eq(dynamic_oil.resolve(), paths.worktree, "dynamic second Oil directory")
  eq(oil_index, 2, "Oil directory read on every invocation")

  local scratch = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_name(scratch, vim.fs.joinpath(paths.worktree, "src", "scratch.lua"))
  eq(
    root.resolve({ bufnr = scratch, cwd = paths.outside }),
    paths.worktree,
    "public resolver honors bufnr and explicit cwd"
  )
  vim.api.nvim_buf_delete(scratch, { force = true })

  local original_cwd = vim.fn.getcwd(0, 0)
  local original_buffer = vim.api.nvim_get_current_buf()
  local cwd_buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(cwd_buffer)

  local cwd_ok, cwd_error = xpcall(function()
    vim.cmd.cd(vim.fs.joinpath(paths.global, "src"))
    eq(root.resolve(), paths.global, "public global cwd")
    vim.cmd.tcd(vim.fs.joinpath(paths.tab, "src"))
    eq(root.resolve(), paths.tab, "public tab-local cwd")
    vim.cmd.lcd(vim.fs.joinpath(paths.window, "src"))
    eq(root.resolve(), paths.window, "public window-local cwd")
  end, debug.traceback)

  vim.cmd.lcd(original_cwd)
  vim.cmd.tcd(original_cwd)
  vim.cmd.cd(original_cwd)
  if vim.api.nvim_buf_is_valid(original_buffer) then
    vim.api.nvim_set_current_buf(original_buffer)
  end
  if vim.api.nvim_buf_is_valid(cwd_buffer) then
    vim.api.nvim_buf_delete(cwd_buffer, { force = true })
  end
  if not cwd_ok then
    error(cwd_error, 0)
  end
end)

local pickers = require("navigation.pickers")
assert(type(pickers._test) == "table", "picker test boundary missing")
assert(type(pickers._test.new) == "function", "picker test constructor missing")

local function picker_harness(options)
  options = options or {}
  local available = options.available or { fzf = true, fd = true, rg = true }
  local calls = {}
  local notifications = {}
  local system_calls = 0
  local fzf_calls = 0
  local root_calls = 0
  local api = {}

  for _, name in ipairs({
    "files",
    "live_grep",
    "buffers",
    "oldfiles",
    "helptags",
    "lsp_finder",
    "lsp_document_symbols",
    "lsp_live_workspace_symbols",
    "diagnostics_document",
    "diagnostics_workspace",
  }) do
    api[name] = function(call_options)
      if options.error_method == name then
        error(options.error_message or "picker exploded")
      end
      local call = { name = name }
      if call_options ~= nil then
        call.options = call_options
      end
      table.insert(calls, call)
    end
  end

  api.fzf_exec = function(contents, call_options)
    table.insert(calls, {
      name = "fzf_exec",
      contents = vim.deepcopy(contents),
      options = call_options,
    })
  end

  local controller = pickers._test.new({
    executable = function(name)
      return available[name] == true
    end,
    system = function(argv)
      system_calls = system_calls + 1
      eq(argv, { "fzf", "--version" }, "fzf version argv")
      return options.version_result or { code = 0, stdout = "0.74.1" }
    end,
    notify = function(message, level, notify_options)
      table.insert(notifications, {
        message = message,
        level = level,
        options = notify_options,
      })
    end,
    fzf = function()
      fzf_calls = fzf_calls + 1
      return api
    end,
    history = function()
      return {
        open = function()
          table.insert(calls, { name = "clipboard_history" })
        end,
      }
    end,
    root = function()
      root_calls = root_calls + 1
      return options.root or "/project"
    end,
  })

  return {
    available = available,
    calls = calls,
    notifications = notifications,
    controller = controller,
    counts = function()
      return { system = system_calls, fzf = fzf_calls, root = root_calls }
    end,
  }
end

local expected_lsp_finder_options = {
  async = true,
  silent = true,
  includeDeclaration = false,
  providers = {
    { "definitions", prefix = "def " },
    { "implementations", prefix = "impl" },
    { "typedefs", prefix = "type" },
    { "references", prefix = "ref " },
  },
}

local function invoke_lsp_pickers(controller)
  controller.lsp_locations()
  controller.document_symbols()
  controller.workspace_symbols()
  controller.document_diagnostics()
  controller.all_diagnostics()
end

local dispatch = picker_harness()
dispatch.controller.files()
dispatch.controller.grep()
dispatch.controller.buffers()
dispatch.controller.recent()
dispatch.controller.help()
invoke_lsp_pickers(dispatch.controller)
eq(dispatch.calls[1], { name = "files", options = { cwd = "/project" } }, "files dispatch")
eq(dispatch.calls[2], { name = "live_grep", options = { cwd = "/project" } }, "grep dispatch")
eq(dispatch.calls[3], { name = "buffers" }, "buffer dispatch has no cwd")
eq(dispatch.calls[4], { name = "oldfiles" }, "recent dispatch has no cwd")
eq(dispatch.calls[5], { name = "helptags" }, "help dispatch has no cwd")
eq(
  dispatch.calls[6],
  { name = "lsp_finder", options = expected_lsp_finder_options },
  "LSP locations dispatch"
)
eq(dispatch.calls[7], { name = "lsp_document_symbols" }, "document symbols dispatch")
eq(dispatch.calls[8], { name = "lsp_live_workspace_symbols" }, "workspace symbols dispatch")
eq(dispatch.calls[9], { name = "diagnostics_document" }, "document diagnostics dispatch")
eq(dispatch.calls[10], { name = "diagnostics_workspace" }, "all diagnostics dispatch")
eq(dispatch.counts(), { system = 1, fzf = 10, root = 2 }, "successful dispatch counts")

local explicit = picker_harness()
explicit.controller.files("/selected/project")
eq(
  explicit.calls[1],
  { name = "files", options = { cwd = "/selected/project" } },
  "explicit file root"
)
eq(explicit.counts().root, 0, "explicit file root bypasses root resolver")

local project_selection
local projects = picker_harness()
projects.controller.projects({
  { label = "~/src/alpha", root = "/home/test/src/alpha" },
  { label = "/srv/alpha", root = "/srv/alpha" },
}, function(root_path)
  project_selection = root_path
end)

eq(projects.calls[1].name, "fzf_exec", "project picker API")
eq(projects.calls[1].contents, { "~/src/alpha", "/srv/alpha" }, "project display order")
eq(projects.calls[1].options.prompt, "Projects> ", "project prompt")
eq(projects.calls[1].options.previewer, false, "project preview disabled")
projects.calls[1].options.actions.enter({ "/srv/alpha" })
eq(project_selection, "/srv/alpha", "project picker retains canonical root")

project_selection = nil
projects.calls[1].options.actions.enter({})
eq(project_selection, nil, "project cancellation has no callback")
projects.calls[1].options.actions.enter({ "not-an-entry" })
eq(project_selection, nil, "unknown project label has no callback")

for _, version_case in ipairs({
  { version = "0.36.0", accepted = true },
  { version = "0.35.3", accepted = false },
  { version = "1.0.0", accepted = true },
  { version = "0.74.1 (brew)", accepted = true },
}) do
  local harness = picker_harness({
    available = { fzf = true },
    version_result = { code = 0, stdout = version_case.version },
  })
  harness.controller.buffers()
  eq(#harness.calls == 1, version_case.accepted, "fzf version boundary " .. version_case.version)
end

local function assert_guard(options, expected_message, label)
  local harness = picker_harness(options)
  harness.controller.buffers()
  invoke_lsp_pickers(harness.controller)
  harness.controller.buffers()
  invoke_lsp_pickers(harness.controller)
  eq(#harness.calls, 0, label .. " blocks pickers")
  eq(#harness.notifications, 1, label .. " notifies once")
  eq(harness.notifications[1].message, expected_message, label .. " message")
  eq(harness.notifications[1].level, vim.log.levels.ERROR, label .. " level")
  eq(harness.notifications[1].options, { title = "Neovim navigation" }, label .. " title")
  return harness
end

local missing_fzf =
  assert_guard({ available = {} }, "FzfLua requires fzf 0.36 or newer", "missing fzf")
eq(missing_fzf.counts(), { system = 0, fzf = 0, root = 0 }, "missing fzf counts")

assert_guard(
  { available = { fzf = true }, version_result = { code = 0, stdout = "unknown" } },
  "Could not determine the installed fzf version",
  "unparseable fzf"
)
assert_guard(
  { available = { fzf = true }, version_result = { code = 2, stdout = "0.74.1" } },
  "Could not determine the installed fzf version",
  "failed fzf command"
)
assert_guard(
  { available = { fzf = true }, version_result = { code = 124, stdout = "" } },
  "Could not determine the installed fzf version",
  "timed out fzf command"
)

for _, provider in ipairs({ "fdfind", "fd", "rg" }) do
  local harness = picker_harness({ available = { fzf = true, [provider] = true } })
  harness.controller.files()
  eq(#harness.calls, 1, provider .. " file provider")
  eq(#harness.notifications, 0, provider .. " is silent")
end

local find_only = picker_harness({ available = { fzf = true, find = true } })
find_only.controller.files()
find_only.controller.files()
eq(#find_only.calls, 2, "find fallback dispatches")
eq(#find_only.notifications, 1, "find fallback warns once")
eq(
  find_only.notifications[1].message,
  "Using find fallback; repository ignore files may not be fully respected",
  "find fallback warning"
)
eq(find_only.notifications[1].level, vim.log.levels.WARN, "find fallback warning level")

local dynamic_provider = picker_harness({ available = { fzf = true, fd = true } })
dynamic_provider.controller.files()
dynamic_provider.available.fd = nil
dynamic_provider.available.find = true
dynamic_provider.controller.files()
dynamic_provider.available.find = nil
dynamic_provider.controller.files()
dynamic_provider.available.rg = true
dynamic_provider.controller.files()
eq(#dynamic_provider.calls, 3, "file provider availability is re-evaluated")
eq(#dynamic_provider.notifications, 2, "find warning and missing provider error")
eq(
  dynamic_provider.notifications[2].message,
  "File search requires fdfind, fd, rg, or find",
  "missing file provider message"
)

local no_files = picker_harness({ available = { fzf = true } })
no_files.controller.files()
no_files.controller.buffers()
eq(no_files.calls, { { name = "buffers" } }, "missing file provider blocks only files")

for _, provider in ipairs({ "rg", "grep" }) do
  local harness = picker_harness({ available = { fzf = true, [provider] = true } })
  harness.controller.grep()
  eq(#harness.calls, 1, provider .. " grep provider")
  eq(#harness.notifications, 0, provider .. " grep provider is silent")
end

local no_grep = picker_harness({ available = { fzf = true } })
no_grep.controller.grep()
no_grep.controller.help()
eq(no_grep.calls, { { name = "helptags" } }, "missing grep provider blocks only grep")
eq(no_grep.notifications[1].message, "Live grep requires rg or grep", "missing grep message")

local lsp_only = picker_harness({ available = { fzf = true } })
invoke_lsp_pickers(lsp_only.controller)
eq(#lsp_only.calls, 5, "LSP pickers do not require file or grep providers")
eq(#lsp_only.notifications, 0, "LSP pickers do not emit provider notifications")
eq(lsp_only.counts(), { system = 1, fzf = 5, root = 0 }, "LSP-only dispatch counts")

local exploding = picker_harness({ error_method = "buffers", error_message = "picker exploded" })
local picker_ok, picker_error = pcall(exploding.controller.buffers)
assert(not picker_ok, "unexpected picker error must propagate")
assert(tostring(picker_error):find("picker exploded", 1, true), "propagated picker error changed")

local exploding_lsp = picker_harness({
  error_method = "lsp_finder",
  error_message = "LSP picker exploded",
})
local lsp_ok, lsp_error = pcall(exploding_lsp.controller.lsp_locations)
assert(not lsp_ok, "unexpected LSP picker error must propagate")
assert(tostring(lsp_error):find("LSP picker exploded", 1, true), "LSP picker error changed")

local pin_without_fzf = picker_harness({ available = {} })
pin_without_fzf.controller.line_pins({
  list = function()
    error("pin finder reached the store without fzf")
  end,
})
eq(#pin_without_fzf.calls, 0, "missing fzf blocks the pin finder")

local clipboard_dispatch = picker_harness()
clipboard_dispatch.controller.clipboard_history()
eq(clipboard_dispatch.calls, { { name = "clipboard_history" } }, "clipboard history dispatch")
for _, options in ipairs({
  { available = {} },
  { version_result = { code = 0, stdout = "0.35.0" } },
}) do
  local unavailable = picker_harness(options)
  unavailable.controller.clipboard_history()
  eq(#unavailable.calls, 0, "Fzf gate blocks clipboard loading")
end

local expected_public_pickers = {
  "files",
  "grep",
  "buffers",
  "recent",
  "projects",
  "line_pins",
  "clipboard_history",
  "help",
  "lsp_locations",
  "document_symbols",
  "workspace_symbols",
  "document_diagnostics",
  "all_diagnostics",
  "_test",
}
for _, method in ipairs(expected_public_pickers) do
  if method ~= "_test" then
    assert(type(pickers[method]) == "function", "missing public picker " .. method)
  end
end
for public_name in pairs(pickers) do
  assert(
    contains(expected_public_pickers, public_name),
    "unexpected public picker surface " .. tostring(public_name)
  )
end

local specs = require("plugins.navigation")
eq(#specs, 3, "navigation plugin count")

local function find_spec(repository)
  for _, spec in ipairs(specs) do
    if spec[1] == repository then
      return spec
    end
  end
  error("missing plugin spec " .. repository)
end

local mini_spec = find_spec("nvim-mini/mini.icons")
local fzf_spec = find_spec("ibhagwan/fzf-lua")
local oil_spec = find_spec("stevearc/oil.nvim")

eq(mini_spec.version, "*", "MiniIcons version policy")
eq(mini_spec.lazy, true, "MiniIcons lazy policy")
eq(mini_spec.main, "mini.icons", "MiniIcons main module")
assert(
  type(mini_spec.opts) == "table" and next(mini_spec.opts) == nil,
  "MiniIcons opts must be empty"
)
assert(mini_spec.config == nil, "MiniIcons must not install a compatibility shim")

local fzf_keys = {}
for _, mapping in ipairs(fzf_spec.keys) do
  table.insert(fzf_keys, mapping[1])
end
eq(fzf_keys, {
  "<leader>ff",
  "<leader>fg",
  "<leader>fb",
  "<leader>fr",
  "<leader>fh",
  "<leader>fl",
  "<leader>fs",
  "<leader>fS",
  "<leader>fd",
  "<leader>fD",
  "<leader>p",
}, "FzfLua mapping surface")
assert(not contains(fzf_keys, "<leader>fk"), "keymap picker must remain absent")
assert(not contains(fzf_keys, "<leader>fR"), "resume picker must remain absent")

local clipboard_mapping
for _, mapping in ipairs(fzf_spec.keys) do
  if mapping[1] == "<leader>p" then
    assert(not clipboard_mapping, "duplicate clipboard mapping")
    clipboard_mapping = mapping
  end
end
assert(clipboard_mapping, "missing clipboard history mapping")
eq(clipboard_mapping.mode, { "n", "x" }, "clipboard mapping modes")
eq(clipboard_mapping.desc, "Paste history", "clipboard mapping description")
local previous_history = package.loaded["clipboard.history"]
local setup_calls = 0
package.loaded["clipboard.history"] = {
  setup = function()
    setup_calls = setup_calls + 1
  end,
}
fzf_spec.init()
package.loaded["clipboard.history"] = previous_history
eq(setup_calls, 1, "Fzf initializer must set up clipboard alongside line pins")
local previous_dispatch = package.loaded["navigation.pickers"]
local clipboard_calls = 0
package.loaded["navigation.pickers"] = {
  clipboard_history = function()
    clipboard_calls = clipboard_calls + 1
  end,
}
clipboard_mapping[2]()
package.loaded["navigation.pickers"] = previous_dispatch
eq(clipboard_calls, 1, "clipboard mapping must use navigation dispatch")

local expected_fzf_lsp_mappings = {
  {
    lhs = "<leader>fl",
    desc = "LSP locations",
    picker = "lsp_locations",
    api = "lsp_finder",
  },
  {
    lhs = "<leader>fs",
    desc = "Document symbols",
    picker = "document_symbols",
    api = "lsp_document_symbols",
  },
  {
    lhs = "<leader>fS",
    desc = "Workspace symbols",
    picker = "workspace_symbols",
    api = "lsp_live_workspace_symbols",
  },
  {
    lhs = "<leader>fd",
    desc = "Document diagnostics",
    picker = "document_diagnostics",
    api = "diagnostics_document",
  },
  {
    lhs = "<leader>fD",
    desc = "All diagnostics",
    picker = "all_diagnostics",
    api = "diagnostics_workspace",
  },
}

local fzf_lsp_callbacks = {}
for _, expected in ipairs(expected_fzf_lsp_mappings) do
  local matches = {}
  for _, mapping in ipairs(fzf_spec.keys) do
    if mapping[1] == expected.lhs then
      table.insert(matches, mapping)
    end
  end
  eq(#matches, 1, "mapping count for " .. expected.lhs)
  assert(type(matches[1][2]) == "function", "mapping callback missing for " .. expected.lhs)
  eq(matches[1].desc, expected.desc, "mapping description for " .. expected.lhs)
  table.insert(fzf_lsp_callbacks, matches[1][2])
end

local previous_picker_module = package.loaded["navigation.pickers"]
local callback_calls = {}
local fake_picker_module = {}
for _, expected in ipairs(expected_fzf_lsp_mappings) do
  local picker_name = expected.picker
  fake_picker_module[picker_name] = function()
    table.insert(callback_calls, picker_name)
  end
end

package.loaded["navigation.pickers"] = fake_picker_module
local callbacks_ok, callbacks_error = xpcall(function()
  for _, callback in ipairs(fzf_lsp_callbacks) do
    callback()
  end
end, debug.traceback)
package.loaded["navigation.pickers"] = previous_picker_module
if not callbacks_ok then
  error(callbacks_error, 0)
end

eq(callback_calls, {
  "lsp_locations",
  "document_symbols",
  "workspace_symbols",
  "document_diagnostics",
  "all_diagnostics",
}, "FzfLua LSP mapping callbacks")

if package.loaded["lazy"] ~= nil then
  local installed_fzf = require("fzf-lua")
  for _, expected in ipairs(expected_fzf_lsp_mappings) do
    assert(type(installed_fzf[expected.api]) == "function", "missing FzfLua API " .. expected.api)
    local mapping = vim.fn.maparg(expected.lhs, "n", false, true)
    assert(
      type(mapping) == "table" and next(mapping) ~= nil,
      "missing live mapping " .. expected.lhs
    )
    eq(mapping.desc, expected.desc, "live mapping description for " .. expected.lhs)
  end
end

eq(fzf_spec.dependencies, { "nvim-mini/mini.icons" }, "FzfLua MiniIcons dependency")

local action_stubs = {
  file_edit = function() end,
  file_split = function() end,
  file_vsplit = function() end,
  file_tabedit = function() end,
  help_curwin = function() end,
  help = function() end,
  help_vert = function() end,
  help_tab = function() end,
}
local previous_actions = package.loaded["fzf-lua.actions"]
package.loaded["fzf-lua.actions"] = action_stubs
local opts_ok, fzf_options = xpcall(fzf_spec.opts, debug.traceback)
package.loaded["fzf-lua.actions"] = previous_actions
if not opts_ok then
  error(fzf_options, 0)
end

eq(fzf_options.defaults.file_icons, "mini", "FzfLua MiniIcons selection")
eq(fzf_options[1], "border-fused", "FzfLua safe base profile")
eq(
  fzf_options.files,
  { hidden = true, no_ignore = false, previewer = true },
  "FzfLua file behavior"
)
assert(fzf_options.keymap.builtin[1] == nil, "builtin keymap must not inherit defaults")
assert(fzf_options.keymap.fzf[1] == nil, "fzf keymap must not inherit defaults")
assert(fzf_options.actions.files[1] == nil, "file actions must not inherit defaults")
eq(fzf_options.actions.files.enter, action_stubs.file_edit, "file Enter action")
eq(fzf_options.actions.files["ctrl-s"], action_stubs.file_split, "file split action")
eq(fzf_options.actions.files["ctrl-v"], action_stubs.file_vsplit, "file vertical split action")
eq(fzf_options.actions.files["ctrl-t"], action_stubs.file_tabedit, "file tab action")
eq(fzf_options.buffers.actions["ctrl-x"], false, "buffer delete action disabled")
eq(fzf_options.helptags.actions.enter, action_stubs.help_curwin, "help current-window action")

local function assert_no_meta_keys(value, path)
  if type(value) ~= "table" then
    return
  end
  for key, nested in pairs(value) do
    if type(key) == "string" then
      local normalized = key:lower()
      assert(not normalized:match("^<m%-"), "Meta mapping at " .. path .. "." .. key)
      assert(not normalized:match("^alt%-"), "Alt mapping at " .. path .. "." .. key)
    end
    assert_no_meta_keys(nested, path .. "." .. tostring(key))
  end
end
assert_no_meta_keys(fzf_options, "fzf")

eq(oil_spec.version, false, "Oil version policy")
eq(oil_spec.lazy, false, "Oil eager loading")
eq(oil_spec.dependencies, { "nvim-mini/mini.icons" }, "Oil MiniIcons dependency")
eq(#oil_spec.keys, 1, "Oil global mapping count")
eq(oil_spec.keys[1][1], "<leader><Tab>", "Oil workspace mapping")
eq(oil_spec.keys[1].mode, "n", "Oil workspace mapping mode")
eq(oil_spec.keys[1].desc, "Toggle Oil workspace", "Oil workspace mapping description")
assert(type(oil_spec.keys[1][2]) == "function", "Oil workspace mapping must use a callback")

local previous_oil_workspace = package.loaded["navigation.oil"]
local oil_toggle_calls = 0
package.loaded["navigation.oil"] = {
  toggle = function()
    oil_toggle_calls = oil_toggle_calls + 1
  end,
}
local oil_callback_ok, oil_callback_error = xpcall(oil_spec.keys[1][2], debug.traceback)
package.loaded["navigation.oil"] = previous_oil_workspace
if not oil_callback_ok then
  error(oil_callback_error, 0)
end
eq(oil_toggle_calls, 1, "Oil workspace mapping callback")

if package.loaded["lazy"] ~= nil then
  local workspace_mapping = vim.fn.maparg("<leader><Tab>", "n", false, true)
  assert(type(workspace_mapping) == "table" and next(workspace_mapping), "missing live Oil mapping")
  eq(workspace_mapping.desc, "Toggle Oil workspace", "live Oil mapping description")
  eq(vim.fn.maparg("-", "n", false, true), {}, "global Oil dash mapping removed")
end

eq(oil_spec.opts.default_file_explorer, true, "Oil default explorer")
eq(oil_spec.opts.columns, { "icon" }, "Oil columns")
eq(oil_spec.opts.delete_to_trash, true, "Oil trash policy")
eq(oil_spec.opts.skip_confirm_for_simple_edits, true, "Oil simple-edit confirmation")
eq(oil_spec.opts.prompt_save_on_select_new_entry, true, "Oil new-entry save prompt")
eq(
  oil_spec.opts.lsp_file_methods,
  { enabled = true, timeout_ms = 1000, autosave_changes = false },
  "Oil LSP policy"
)
eq(oil_spec.opts.watch_for_changes, false, "Oil watcher policy")
eq(oil_spec.opts.use_default_keymaps, true, "Oil default keymaps")
eq(oil_spec.opts.keymaps["g\\"], false, "Oil trash-view mapping disabled")
eq(oil_spec.opts.view_options.show_hidden, false, "Oil hidden-file default")
for _, operation in ipairs({ "add", "mv", "rm" }) do
  eq(oil_spec.opts.git[operation](), false, "Oil Git hook disabled: " .. operation)
end

print("Neovim navigation assertions: ok")
