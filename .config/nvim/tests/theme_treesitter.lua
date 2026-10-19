local function eq(actual, expected, label)
  assert(
    vim.deep_equal(actual, expected),
    string.format("%s\nexpected: %s\nactual: %s", label, vim.inspect(expected), vim.inspect(actual))
  )
end

local function exact_keys(value, expected, label)
  local actual = {}
  for key in pairs(value) do
    actual[#actual + 1] = tostring(key)
  end
  table.sort(actual)

  expected = vim.deepcopy(expected)
  table.sort(expected)
  eq(actual, expected, label)
end

local languages = {
  "bash",
  "html",
  "json",
  "lua",
  "markdown",
  "markdown_inline",
  "python",
  "query",
  "toml",
  "vim",
  "vimdoc",
  "yaml",
}

local test_file = debug.getinfo(1, "S").source:sub(2)
local nvim_root = vim.fs.dirname(vim.fs.dirname(test_file))

local theme_specs = require("plugins.theme")
exact_keys(theme_specs, { "1" }, "TokyoNight spec list")
eq(#theme_specs, 1, "TokyoNight spec count")

local theme = theme_specs[1]
exact_keys(theme, { "1", "config", "lazy", "opts", "priority", "version" }, "TokyoNight Lazy keys")
eq(theme[1], "folke/tokyonight.nvim", "TokyoNight repository")
eq(theme.version, "v4.14.1", "TokyoNight stable version")
eq(theme.lazy, false, "TokyoNight eager loading")
eq(theme.priority, 1000, "TokyoNight priority")
eq(theme.opts, {
  style = "night",
  transparent = false,
  terminal_colors = true,
  on_highlights = theme.opts.on_highlights,
  styles = {
    comments = { italic = true },
    keywords = { italic = true },
    sidebars = "dark",
    floats = "dark",
  },
}, "TokyoNight options")
assert(type(theme.opts.on_highlights) == "function", "TokyoNight highlight callback missing")
assert(type(theme.config) == "function", "TokyoNight config callback missing")

do
  local fixture = vim.fn.tempname()
  local colors_dir = vim.fs.joinpath(fixture, "colors")
  local colors_file = vim.fs.joinpath(colors_dir, "tokyonight-night.vim")
  assert(vim.fn.mkdir(colors_dir, "p") == 1, "theme fixture creation failed")
  assert(vim.fn.writefile({
    [[lua table.insert(_G.__dotfiles_theme_events, "colorscheme")]],
    [[let g:colors_name = 'tokyonight-night']],
  }, colors_file) == 0, "theme fixture write failed")

  local old_runtimepath = vim.o.runtimepath
  local old_colors_name = vim.g.colors_name
  local old_tokyonight = package.loaded["tokyonight"]
  _G.__dotfiles_theme_events = {}

  package.loaded["tokyonight"] = {
    setup = function(opts)
      eq(opts, theme.opts, "TokyoNight setup options")
      table.insert(_G.__dotfiles_theme_events, "setup")
    end,
  }
  vim.opt.runtimepath:prepend(fixture)

  local ok, failure = xpcall(function()
    theme.config(nil, theme.opts)
    eq(
      _G.__dotfiles_theme_events,
      { "setup", "colorscheme" },
      "TokyoNight setup must precede colorscheme"
    )
    eq(vim.g.colors_name, "tokyonight-night", "explicit TokyoNight Night colorscheme")
  end, debug.traceback)

  vim.o.runtimepath = old_runtimepath
  vim.g.colors_name = old_colors_name
  package.loaded["tokyonight"] = old_tokyonight
  _G.__dotfiles_theme_events = nil
  assert(vim.fn.delete(colors_file) == 0, "theme fixture file cleanup failed")
  assert(vim.fn.delete(colors_dir, "d") == 0, "theme fixture colors cleanup failed")
  assert(vim.fn.delete(fixture, "d") == 0, "theme fixture root cleanup failed")
  assert(ok, failure)
end

local treesitter_specs = require("plugins.treesitter")
exact_keys(treesitter_specs, { "1" }, "Treesitter spec list")
eq(#treesitter_specs, 1, "Treesitter spec count")

local plugin = treesitter_specs[1]
exact_keys(plugin, { "1", "build", "config", "lazy" }, "Treesitter Lazy keys")
eq(plugin[1], "nvim-treesitter/nvim-treesitter", "Treesitter repository")
eq(plugin.lazy, false, "Treesitter eager loading")
eq(plugin.build, ":TSUpdate", "Treesitter build command")
eq(plugin.branch, nil, "Treesitter must follow the default main branch")
eq(plugin.version, nil, "Treesitter lockfile must own the exact revision")
assert(type(plugin.config) == "function", "Treesitter config callback missing")

do
  local previous = package.loaded["config.treesitter"]
  local setup_calls = 0
  package.loaded["config.treesitter"] = {
    setup = function()
      setup_calls = setup_calls + 1
    end,
  }

  local ok, failure = xpcall(plugin.config, debug.traceback)
  package.loaded["config.treesitter"] = previous

  assert(ok, failure)
  eq(setup_calls, 1, "Treesitter plugin delegates setup exactly once")
end

local treesitter = require("config.treesitter")
exact_keys(treesitter, { "_test", "languages", "setup" }, "Treesitter module exports")
exact_keys(treesitter._test, { "new" }, "Treesitter test exports")
assert(type(treesitter.languages) == "function", "Treesitter languages function missing")
assert(type(treesitter.setup) == "function", "Treesitter setup function missing")
assert(type(treesitter._test.new) == "function", "Treesitter test constructor missing")

eq(treesitter.languages(), languages, "exact Treesitter language allowlist")
local copied_languages = treesitter.languages()
copied_languages[1] = "rust"
eq(treesitter.languages(), languages, "language allowlist must be a defensive copy")

local install_dir = "/fixture/data/site"
local plugin_runtime = "/fixture/plugin/runtime"

local function make_harness()
  local state = {
    expected = {},
    recorded = {},
    files = {},
    runtime = {},
    filetypes = {},
    markers = {},
    interactive = false,
    skip = false,
    setup_calls = {},
    install_calls = {},
    expected_calls = {},
    revision_calls = {},
    file_calls = {},
    runtime_calls = {},
    language_add_calls = {},
    query_get_calls = {},
    start_calls = {},
    stop_calls = {},
    notifications = {},
    scheduled = {},
    augroup_calls = {},
    autocmd_calls = {},
    expected_errors = {},
    revision_errors = {},
    file_errors = {},
    runtime_errors = {},
    language_add_errors = {},
    language_add_nil = {},
    query_get_errors = {},
    query_get_nil = {},
    start_errors = {},
    stop_errors = {},
    events = {},
    await_calls = 0,
  }

  function state.parser_path(lang)
    return vim.fs.joinpath(install_dir, "parser", lang .. ".so")
  end

  function state.query_relative(lang)
    return vim.fs.joinpath("queries", lang, "highlights.scm")
  end

  function state.managed_query_path(lang)
    return vim.fs.joinpath(install_dir, state.query_relative(lang))
  end

  function state.plugin_query_path(lang)
    return vim.fs.joinpath(plugin_runtime, state.query_relative(lang))
  end

  function state.seed_language(lang)
    state.expected[lang] = "revision-" .. lang
    state.recorded[lang] = "revision-" .. lang
    state.files[state.parser_path(lang)] = true
    state.files[state.managed_query_path(lang)] = true
    state.files[state.plugin_query_path(lang)] = true
    state.runtime[state.query_relative(lang)] = {
      state.managed_query_path(lang),
      state.plugin_query_path(lang),
    }
  end

  for _, lang in ipairs(languages) do
    state.seed_language(lang)
  end

  state.files[state.managed_query_path("html_tags")] = true
  state.files[state.plugin_query_path("html_tags")] = true
  state.runtime[state.query_relative("html_tags")] = {
    state.managed_query_path("html_tags"),
    state.plugin_query_path("html_tags"),
  }

  state.task = {
    await = function(_, callback)
      state.await_calls = state.await_calls + 1
      assert(type(callback) == "function", "Task:await callback missing")
      state.await_callback = callback
      if state.on_await then
        state.on_await()
      end
      if state.complete_during_await then
        callback(false)
      end
    end,
  }

  local deps = {
    install_dir = install_dir,
    joinpath = vim.fs.joinpath,
    setup_plugin = function(opts)
      state.setup_calls[#state.setup_calls + 1] = vim.deepcopy(opts)
    end,
    install = function(requested, opts)
      state.install_calls[#state.install_calls + 1] = {
        languages = vim.deepcopy(requested),
        options = vim.deepcopy(opts),
      }
      if state.on_install then
        state.on_install()
      end
      return state.task
    end,
    expected_revision = function(lang)
      state.expected_calls[#state.expected_calls + 1] = lang
      state.events[#state.events + 1] = "expected:" .. lang
      if state.expected_errors[lang] then
        error(state.expected_errors[lang])
      end
      return state.expected[lang]
    end,
    read_revision = function(lang)
      state.revision_calls[#state.revision_calls + 1] = lang
      state.events[#state.events + 1] = "revision:" .. lang
      if state.revision_errors[lang] then
        error(state.revision_errors[lang])
      end
      return state.recorded[lang]
    end,
    file_nonempty = function(path)
      state.file_calls[#state.file_calls + 1] = path
      state.events[#state.events + 1] = "file:" .. path
      if state.file_errors[path] then
        error(state.file_errors[path])
      end
      return state.files[path] == true
    end,
    runtime_files = function(relative)
      state.runtime_calls[#state.runtime_calls + 1] = relative
      state.events[#state.events + 1] = "runtime:" .. relative
      if state.runtime_errors[relative] then
        error(state.runtime_errors[relative])
      end
      return vim.deepcopy(state.runtime[relative] or {})
    end,
    language_add = function(lang)
      state.language_add_calls[#state.language_add_calls + 1] = lang
      state.events[#state.events + 1] = "add:" .. lang
      if state.language_add_errors[lang] then
        error(state.language_add_errors[lang])
      end
      if state.language_add_nil[lang] then
        return nil
      end
      return true
    end,
    query_get = function(lang, query_name)
      state.query_get_calls[#state.query_get_calls + 1] = { lang, query_name }
      state.events[#state.events + 1] = "query:" .. lang .. ":" .. query_name
      if state.query_get_errors[lang] then
        error(state.query_get_errors[lang])
      end
      if state.query_get_nil[lang] then
        return nil
      end
      return {}
    end,
    list_uis = function()
      if state.interactive then
        return { { chan = 1 } }
      end
      return {}
    end,
    skip_install = function()
      return state.skip
    end,
    schedule = function(callback)
      state.scheduled[#state.scheduled + 1] = callback
    end,
    create_augroup = function(name, opts)
      state.augroup_calls[#state.augroup_calls + 1] = {
        name = name,
        options = vim.deepcopy(opts),
      }
      return 91
    end,
    create_autocmd = function(events, opts)
      state.autocmd_calls[#state.autocmd_calls + 1] = {
        events = vim.deepcopy(events),
        options = opts,
      }
      state.autocmd = state.autocmd_calls[#state.autocmd_calls]
      return 92
    end,
    buffer_filetype = function(bufnr)
      return state.filetypes[bufnr] or ""
    end,
    resolve_language = function(filetype)
      local aliases = {
        help = "vimdoc",
        sh = "bash",
      }
      return aliases[filetype] or (filetype ~= "" and filetype or nil)
    end,
    get_marker = function(bufnr)
      return state.markers[bufnr]
    end,
    set_marker = function(bufnr, value)
      state.markers[bufnr] = value
    end,
    stop = function(bufnr)
      state.stop_calls[#state.stop_calls + 1] = bufnr
      if state.stop_errors[bufnr] then
        error(state.stop_errors[bufnr])
      end
    end,
    start = function(bufnr, lang)
      state.start_calls[#state.start_calls + 1] = { bufnr, lang }
      if state.start_errors[lang] then
        error(state.start_errors[lang])
      end
    end,
    notify = function(message, level)
      state.notifications[#state.notifications + 1] = {
        message = message,
        level = level,
      }
    end,
    warn_level = 777,
  }

  state.controller = treesitter._test.new(deps)
  exact_keys(state.controller, { "attach", "debug_state", "ready", "setup" }, "controller exports")

  return state
end

local function assert_not_ready(label, mutate, verify)
  local state = make_harness()
  mutate(state)
  local ready, reason = state.controller.ready("lua")
  eq(ready, false, label)
  assert(type(reason) == "string" and reason ~= "", label .. " must provide a reason")
  if verify then
    verify(state)
  end
end

do
  local state = make_harness()
  local ready = state.controller.ready("lua")
  eq(ready, true, "fully installed parser readiness")
  eq(state.language_add_calls, { "lua" }, "parser loaded after preflight")
  eq(state.query_get_calls, { { "lua", "highlights" } }, "highlight query parsed")

  local add_index
  local query_index
  for index, event in ipairs(state.events) do
    if event == "add:lua" then
      add_index = index
    elseif event == "query:lua:highlights" then
      query_index = index
    end
  end
  assert(
    add_index and query_index and add_index < query_index,
    "parser load must precede query parse"
  )
  for index, event in ipairs(state.events) do
    if event:find("^file:") or event:find("^runtime:") then
      assert(index < add_index, "all managed files must be preflighted before parser load")
    end
  end
end

assert_not_ready("missing expected revision", function(state)
  state.expected.lua = nil
end, function(state)
  eq(#state.language_add_calls, 0, "missing manifest must not load a parser")
end)

assert_not_ready("unreadable expected revision", function(state)
  state.expected_errors.lua = "manifest unreadable"
end)

assert_not_ready("missing recorded revision", function(state)
  state.recorded.lua = nil
end)

assert_not_ready("unreadable recorded revision", function(state)
  state.revision_errors.lua = "revision unreadable"
end)

assert_not_ready("revision mismatch", function(state)
  state.recorded.lua = "another-revision"
end)

assert_not_ready("revision bytes are not trimmed", function(state)
  state.recorded.lua = state.expected.lua .. "\n"
end)

assert_not_ready("missing managed parser", function(state)
  state.files[state.parser_path("lua")] = nil
end, function(state)
  eq(#state.language_add_calls, 0, "bundled parser fallback must not hide a missing managed parser")
end)

assert_not_ready("empty managed parser", function(state)
  state.files[state.parser_path("lua")] = false
end)

assert_not_ready("unreadable managed parser", function(state)
  state.file_errors[state.parser_path("lua")] = "parser unreadable"
end)

assert_not_ready("missing managed query", function(state)
  local builtin = "/fixture/builtin/queries/lua/highlights.scm"
  state.files[state.managed_query_path("lua")] = nil
  state.files[builtin] = true
  state.runtime[state.query_relative("lua")] = { builtin }
end, function(state)
  eq(#state.language_add_calls, 0, "built-in query fallback must not load the managed parser")
  eq(#state.query_get_calls, 0, "missing managed query must not reach memoized query getter")
end)

assert_not_ready("empty managed query", function(state)
  state.files[state.managed_query_path("lua")] = false
end, function(state)
  eq(#state.language_add_calls, 0, "empty managed query must precede parser load")
  eq(#state.query_get_calls, 0, "empty managed query must precede query getter")
end)

assert_not_ready("unreadable managed query", function(state)
  state.file_errors[state.managed_query_path("lua")] = "query unreadable"
end)

assert_not_ready("missing runtime query", function(state)
  state.runtime[state.query_relative("lua")] = {}
end, function(state)
  eq(#state.language_add_calls, 0, "missing runtime query must precede parser load")
  eq(#state.query_get_calls, 0, "missing runtime query must precede query getter")
end)

assert_not_ready("unreadable runtime query", function(state)
  local path = state.plugin_query_path("lua")
  state.file_errors[path] = "runtime query unreadable"
end)

assert_not_ready("empty secondary runtime query", function(state)
  local path = "/fixture/other/queries/lua/highlights.scm"
  state.runtime[state.query_relative("lua")][#state.runtime[state.query_relative("lua")] + 1] = path
  state.files[path] = false
end)

assert_not_ready("parser load throws", function(state)
  state.language_add_errors.lua = "load failed"
end)

assert_not_ready("parser load returns nil", function(state)
  state.language_add_nil.lua = true
end)

assert_not_ready("query parse throws", function(state)
  state.query_get_errors.lua = "invalid query"
end)

assert_not_ready("query parse returns nil", function(state)
  state.query_get_nil.lua = true
end)

do
  local state = make_harness()
  state.files[state.managed_query_path("html_tags")] = nil
  local ready = state.controller.ready("html")
  eq(ready, false, "HTML requires managed html_tags highlights")
  eq(#state.language_add_calls, 0, "HTML dependency preflight must precede parser load")
  eq(#state.query_get_calls, 0, "HTML dependency preflight must precede query getter")
end

do
  local state = make_harness()
  state.runtime[state.query_relative("html_tags")] = {}
  local ready = state.controller.ready("html")
  eq(ready, false, "HTML requires runtime html_tags highlights")
  eq(#state.language_add_calls, 0, "missing html_tags runtime query must precede load")
end

do
  local state = make_harness()
  local ready, reason = state.controller.ready("rust")
  eq(ready, false, "unapproved language rejection")
  assert(type(reason) == "string" and reason ~= "", "unapproved language reason missing")
  eq(#state.expected_calls, 0, "unapproved language must not inspect the manifest")
end

do
  local state = make_harness()
  state.controller.setup()
  assert(state.controller.setup() == state.controller, "setup must return its controller")
  eq(state.setup_calls, { { install_dir = install_dir } }, "explicit Treesitter install directory")
  eq(state.augroup_calls, {
    {
      name = "dotfiles-treesitter",
      options = { clear = true },
    },
  }, "single owned Treesitter augroup")
  eq(#state.autocmd_calls, 1, "single attachment autocmd")
  eq(state.autocmd.events, { "FileType", "BufEnter" }, "attachment events")
  eq(state.autocmd.options.group, 91, "attachment augroup")
  assert(type(state.autocmd.options.callback) == "function", "attachment callback missing")
  eq(#state.install_calls, 0, "headless setup must not install parsers")
  eq(#state.expected_calls, 0, "headless setup must not scan repair candidates")
  eq(state.controller.debug_state(), {
    setup = true,
    install_task = false,
    pending = {},
  }, "headless debug state")
end

do
  local state = make_harness()
  state.interactive = true
  state.skip = true
  state.files[state.parser_path("lua")] = nil
  state.controller.setup()
  eq(#state.install_calls, 0, "checker opt-out must prevent installation")
  eq(#state.expected_calls, 0, "checker opt-out must prevent repair scanning")
end

do
  local state = make_harness()
  state.interactive = true
  state.controller.setup()
  eq(#state.install_calls, 0, "ready parser set must not invoke installer")
  eq(state.expected_calls, languages, "interactive readiness scan order")
end

do
  local state = make_harness()
  state.interactive = true
  state.recorded.lua = "stale"
  state.language_add_nil.python = true
  state.query_get_nil.yaml = true
  state.controller.setup()

  eq(#state.install_calls, 1, "single repair batch")
  eq(
    state.install_calls[1].languages,
    { "lua", "python", "yaml" },
    "revision, load, and query failures selected for repair"
  )
  eq(state.install_calls[1].options, {
    force = true,
    max_jobs = 4,
  }, "forced four-job repair")
end

for _, mode in ipairs({ "install", "task", "await" }) do
  local state = make_harness()
  state.interactive = true
  state.files[state.parser_path("lua")] = nil
  if mode == "install" then
    state.on_install = function()
      error("install failed")
    end
  elseif mode == "task" then
    state.task = {}
  else
    state.task.await = function()
      error("await failed")
    end
  end

  local ok = pcall(state.controller.setup)
  assert(ok, mode .. " failure must not abort Neovim setup")
  eq(state.controller.debug_state().pending, { "lua" }, mode .. " failure keeps repair pending")
  eq(state.controller.debug_state().install_task, false, mode .. " failure leaves no live task")
end

do
  local state = make_harness()
  state.interactive = true
  state.files[state.parser_path("lua")] = nil
  state.files[state.parser_path("yaml")] = nil
  state.filetypes[7] = "lua"

  state.on_install = function()
    state.autocmd.options.callback({ buf = 7 })
    state.starts_during_install = #state.start_calls
  end
  state.on_await = function()
    state.task_retained_during_await = state.controller.debug_state().install_task
  end

  state.controller.setup()
  state.controller.setup()

  eq(#state.setup_calls, 1, "idempotent plugin setup")
  eq(#state.install_calls, 1, "idempotent repair launch")
  eq(state.await_calls, 1, "installer uses Task:await exactly once")
  eq(state.starts_during_install, 0, "pending parser cannot attach during installation")
  eq(state.task_retained_during_await, true, "task retained before Task:await")
  eq(state.controller.debug_state(), {
    setup = true,
    install_task = true,
    pending = { "lua", "yaml" },
  }, "pending repair state")

  local copied = state.controller.debug_state()
  copied.pending[1] = "rust"
  eq(
    state.controller.debug_state().pending,
    { "lua", "yaml" },
    "debug state must return a defensive pending copy"
  )

  state.files[state.parser_path("lua")] = true
  state.await_callback(false)

  eq(#state.scheduled, 1, "Task completion must schedule reevaluation")
  eq(
    state.controller.debug_state().pending,
    { "lua", "yaml" },
    "completion callback must not reevaluate inline"
  )
  eq(
    state.controller.debug_state().install_task,
    true,
    "task retained until scheduled reevaluation"
  )
  eq(#state.start_calls, 0, "repair completion must not attach buffers directly")

  state.scheduled[1]()

  eq(state.controller.debug_state(), {
    setup = true,
    install_task = false,
    pending = { "yaml" },
  }, "partial repair promotion")
  eq(#state.start_calls, 0, "scheduled repair completion still does not attach directly")

  state.autocmd.options.callback({ buf = 7 })
  eq(state.start_calls, { { 7, "lua" } }, "BufEnter-style retry after successful repair")
  eq(state.markers[7], "lua", "successful retry marker")
end

do
  local state = make_harness()
  state.interactive = true
  state.files[state.managed_query_path("lua")] = nil
  state.controller.setup()

  eq(#state.language_add_calls, 11, "missing query avoids loading only its parser")
  for _, lang in ipairs(state.language_add_calls) do
    assert(lang ~= "lua", "Lua parser loaded before its managed query existed")
  end
  for _, call in ipairs(state.query_get_calls) do
    assert(call[1] ~= "lua", "Lua query getter called before repair")
  end

  state.files[state.managed_query_path("lua")] = true
  state.await_callback(false)
  state.scheduled[1]()

  eq(state.controller.debug_state().pending, {}, "missing query repair completion")
  assert(vim.tbl_contains(state.language_add_calls, "lua"), "repaired Lua parser was not rechecked")
end

do
  local state = make_harness()
  state.interactive = true
  state.files[state.parser_path("lua")] = nil
  state.complete_during_await = true
  state.controller.setup()

  eq(#state.scheduled, 1, "already-completed Task still schedules reevaluation")
  eq(state.controller.debug_state().install_task, true, "synchronous await callback retains task")
  state.scheduled[1]()
  eq(state.controller.debug_state().pending, { "lua" }, "failed synchronous repair remains pending")
  eq(
    state.controller.debug_state().install_task,
    false,
    "completed task cleared after reevaluation"
  )
end

do
  local state = make_harness()
  state.controller.setup()
  state.filetypes[3] = "lua"

  eq(state.controller.attach(3), true, "successful Lua attachment")
  eq(state.start_calls, { { 3, "lua" } }, "native highlighter start")
  eq(state.markers[3], "lua", "successful attachment marker")

  state.controller.attach(3)
  eq(#state.start_calls, 1, "repeated event must not duplicate a highlighter")
end

do
  for filetype, expected in pairs({ sh = "bash", help = "vimdoc" }) do
    local state = make_harness()
    state.controller.setup()
    state.filetypes[4] = filetype
    state.controller.attach(4)
    eq(state.start_calls, { { 4, expected } }, filetype .. " parser resolution")
    eq(state.markers[4], expected, filetype .. " marker")
  end
end

do
  local state = make_harness()
  state.interactive = true
  state.files[state.parser_path("lua")] = nil
  state.filetypes[5] = "lua"
  state.controller.setup()

  local expected_calls = #state.expected_calls
  eq(state.controller.attach(5), false, "pending parser attachment rejection")
  eq(#state.expected_calls, expected_calls, "pending parser must be rejected before readiness")
  eq(#state.start_calls, 0, "pending parser must not start")
end

do
  local state = make_harness()
  state.controller.setup()
  state.files[state.parser_path("lua")] = nil
  state.filetypes[6] = "lua"

  eq(state.controller.attach(6), false, "missing parser attachment rejection")
  state.files[state.parser_path("lua")] = true
  eq(state.controller.attach(6), true, "missing parser later retry")
  eq(state.start_calls, { { 6, "lua" } }, "later retry starts once")
end

do
  local state = make_harness()
  state.controller.setup()
  state.filetypes[8] = "lua"
  state.controller.attach(8)

  state.filetypes[8] = "python"
  state.controller.attach(8)

  eq(state.stop_calls, { 8 }, "language switch stops old highlighter")
  eq(state.start_calls, { { 8, "lua" }, { 8, "python" } }, "language switch start order")
  eq(state.markers[8], "python", "language switch marker")
end

do
  local state = make_harness()
  state.controller.setup()
  state.filetypes[9] = "lua"
  state.controller.attach(9)

  state.files[state.parser_path("python")] = nil
  state.filetypes[9] = "python"
  eq(state.controller.attach(9), false, "unavailable replacement rejection")

  eq(state.stop_calls, { 9 }, "old highlighter stopped before replacement readiness")
  eq(state.markers[9], nil, "marker cleared immediately after successful stop")
  eq(#state.start_calls, 1, "unavailable replacement must not start")
end

do
  local state = make_harness()
  state.controller.setup()
  state.filetypes[10] = "lua"
  state.controller.attach(10)

  state.filetypes[10] = "rust"
  eq(state.controller.attach(10), false, "unapproved filetype detachment")
  eq(state.markers[10], nil, "unapproved filetype clears marker")
  eq(state.stop_calls, { 10 }, "unapproved filetype stops old highlighter")

  state.filetypes[10] = "lua"
  state.controller.attach(10)
  state.filetypes[10] = ""
  eq(state.controller.attach(10), false, "empty filetype detachment")
  eq(state.markers[10], nil, "empty filetype clears marker")
  eq(state.stop_calls, { 10, 10 }, "empty filetype stops old highlighter")
end

do
  local state = make_harness()
  state.controller.setup()
  state.filetypes[11] = "lua"
  state.controller.attach(11)

  state.filetypes[11] = "python"
  state.stop_errors[11] = "stop failed"
  eq(state.controller.attach(11), false, "stop failure rejection")
  eq(state.controller.attach(11), false, "stop failure retry rejection")

  eq(state.markers[11], "lua", "stop failure retains old marker")
  eq(#state.start_calls, 1, "stop failure prevents replacement highlighter")
  eq(#state.notifications, 1, "stop warning deduplicated")
  eq(state.notifications[1].level, 777, "stop warning level")
  assert(state.notifications[1].message ~= "", "stop warning message missing")
end

do
  local state = make_harness()
  state.controller.setup()
  state.filetypes[12] = "lua"
  state.start_errors.lua = "start failed"

  eq(state.controller.attach(12), false, "start failure rejection")
  eq(state.controller.attach(12), false, "start failure retry")
  eq(state.markers[12], nil, "start failure leaves marker clear")
  eq(#state.start_calls, 2, "start failure remains retryable")
  eq(#state.notifications, 1, "start warning deduplicated")
  eq(state.notifications[1].level, 777, "start warning level")

  state.start_errors.lua = nil
  eq(state.controller.attach(12), true, "start succeeds after transient failure")
  eq(state.markers[12], "lua", "successful retry marker")
end

do
  local before = {
    foldmethod = vim.wo.foldmethod,
    foldexpr = vim.wo.foldexpr,
    foldenable = vim.wo.foldenable,
    foldlevel = vim.wo.foldlevel,
    indentexpr = vim.bo.indentexpr,
  }

  local state = make_harness()
  state.controller.setup()
  state.filetypes[13] = "lua"
  state.controller.attach(13)

  eq({
    foldmethod = vim.wo.foldmethod,
    foldexpr = vim.wo.foldexpr,
    foldenable = vim.wo.foldenable,
    foldlevel = vim.wo.foldlevel,
    indentexpr = vim.bo.indentexpr,
  }, before, "Treesitter must not change fold or indent options")
end

local controller_source =
  table.concat(vim.fn.readfile(vim.fs.joinpath(nvim_root, "lua", "config", "treesitter.lua")), "\n")

for _, forbidden in ipairs({
  "nvim-treesitter.configs",
  "raise_on_error",
  "foldmethod",
  "foldexpr",
  "foldenable",
  "foldlevel",
  "indentexpr",
}) do
  assert(
    not controller_source:find(forbidden, 1, true),
    "Treesitter controller contains forbidden API or option: " .. forbidden
  )
end

assert(
  not controller_source:find("[%.:]%s*p?wait%s*%("),
  "Treesitter controller must not block on Task wait methods"
)
assert(
  controller_source:find("DOTFILES_NVIM_SKIP_PARSER_INSTALL", 1, true),
  "production checker install guard missing"
)
assert(controller_source:find("nvim_list_uis", 1, true), "production interactive UI guard missing")

print("TokyoNight and Treesitter focused assertions: ok")
