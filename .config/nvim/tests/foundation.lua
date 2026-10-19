assert(vim.fn.has("nvim-0.12") == 1, "Neovim version floor failed")
assert(vim.o.termguicolors, "termguicolors must be enabled")
assert(vim.o.mouse == "a", "mouse must be enabled")
assert(vim.o.clipboard:find("unnamedplus", 1, true), "unnamedplus must be enabled")
assert(
  vim.g.dotfiles_platform == "linux" or vim.g.dotfiles_platform == "macos",
  "platform marker missing"
)

local allowed_clipboards = {
  pbcopy = true,
  ["wl-copy"] = true,
  tmux = true,
  osc52 = true,
}
assert(allowed_clipboards[vim.g.dotfiles_clipboard_provider], "unexpected clipboard provider")

local expected_clipboard_executables = {
  pbcopy = "pbcopy",
  ["wl-copy"] = "wl-copy",
  tmux = "tmux",
  osc52 = "OSC 52",
}
local clipboard_executable = vim.fn["provider#clipboard#Executable"]()
local clipboard_error = vim.fn["provider#clipboard#Error"]()

assert(clipboard_error == "", "clipboard provider error: " .. clipboard_error)
assert(
  clipboard_executable == expected_clipboard_executables[vim.g.dotfiles_clipboard_provider],
  string.format(
    "clipboard executable mismatch: expected %s, got %s",
    expected_clipboard_executables[vim.g.dotfiles_clipboard_provider],
    clipboard_executable
  )
)
assert(vim.g.loaded_clipboard_provider == 2, "clipboard provider must be loaded and available")

local ok = pcall(require, "smart-splits")
assert(ok, "smart-splits.nvim must be installed and eagerly available")

for _, key in ipairs({
  "<leader>ff",
  "<leader>fg",
  "<leader>fb",
  "<leader>fr",
  "<leader>fh",
  "<leader>ha",
  "<leader>hh",
  "<leader>hd",
  "<leader>hc",
  "<leader><Tab>",
}) do
  local mapping = vim.fn.maparg(key, "n", false, true)
  assert(type(mapping) == "table" and next(mapping) ~= nil, "missing navigation mapping " .. key)
end

for _, command in ipairs({ "LinePinAdd", "LinePins", "LinePinDelete", "LinePinsClear" }) do
  assert(vim.fn.exists(":" .. command) == 2, "missing line-pin command " .. command)
end

for _, mode in ipairs({ "n", "x" }) do
  local mapping = vim.fn.maparg("<leader>p", mode, false, true)
  assert(
    type(mapping) == "table" and mapping.desc == "Paste history",
    "missing clipboard mapping in " .. mode
  )
end
for _, command in ipairs({
  "ClipboardHistoryClear",
  "ClipboardHistoryPause",
  "ClipboardHistoryResume",
}) do
  assert(vim.fn.exists(":" .. command) == 2, "missing clipboard command " .. command)
end

assert(vim.fn.maparg("<leader>fk", "n") == "", "keymap picker must remain absent")
assert(vim.fn.maparg("<leader>fR", "n") == "", "resume picker must remain absent")
assert(pcall(require, "fzf-lua"), "fzf-lua must be installed and loadable")
assert(pcall(require, "oil"), "oil.nvim must be eagerly available")
assert(pcall(require, "mini.icons"), "mini.icons must be installed and loadable")
assert(type(_G.MiniIcons) == "table", "MiniIcons must be configured")
assert(pcall(require, "mini.starter"), "mini.starter must be installed and loadable")
assert(type(_G.MiniStarter) == "table", "MiniStarter must be configured")

local fzf_actions = require("fzf-lua.actions")
local fzf_config = require("fzf-lua.config")
assert(fzf_config.setup_opts[1] == "border-fused", "FzfLua must omit the Meta-binding profile")

local function reject_meta_keys(value, path, seen)
  if type(value) ~= "table" or seen[value] then
    return
  end
  seen[value] = true

  for key, nested in pairs(value) do
    if type(key) == "string" then
      local normalized = key:lower()
      assert(not normalized:match("^<m%-"), "unexpected Meta binding at " .. path .. "." .. key)
      assert(not normalized:match("^alt%-"), "unexpected Alt binding at " .. path .. "." .. key)
    end
    reject_meta_keys(nested, path .. "." .. tostring(key), seen)
  end
end

local normalized_providers = {}
for _, provider in ipairs({ "files", "grep", "buffers", "oldfiles", "helptags" }) do
  local options =
    assert(fzf_config.normalize_opts({}, provider), "could not normalize " .. provider)
  normalized_providers[provider] = options
  reject_meta_keys(options, provider, {})
end

assert(
  normalized_providers.buffers.actions["ctrl-x"] == false,
  "buffer delete action must remain disabled"
)
assert(
  normalized_providers.helptags.actions.enter == fzf_actions.help_curwin,
  "help Enter must stay in the current window"
)

local modes = { "n", "i", "t" }
local keys = { "<M-h>", "<M-j>", "<M-k>", "<M-l>", "<M-H>", "<M-J>", "<M-K>", "<M-L>" }

for _, mode in ipairs(modes) do
  for _, key in ipairs(keys) do
    local mapping = vim.fn.maparg(key, mode, false, true)
    assert(
      type(mapping) == "table" and next(mapping) ~= nil,
      string.format("missing %s mapping in mode %s", key, mode)
    )
  end
end

assert(vim.fn.maparg("<M-h>", "v") == "", "Visual mode must remain unmapped")
assert(vim.fn.maparg("<M-h>", "c") == "", "Command-line mode must remain unmapped")

assert(pcall(require, "tokyonight"), "TokyoNight must be eagerly loadable")
assert(pcall(require, "nvim-treesitter"), "nvim-treesitter must be eagerly loadable")
assert(vim.g.colors_name == "tokyonight-night", "TokyoNight Night must be active")
assert(vim.o.background == "dark", "TokyoNight Night requires a dark background")

local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
local comment = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
local keyword = vim.api.nvim_get_hl(0, { name = "Keyword", link = false })
local treesitter_comment = vim.api.nvim_get_hl(0, { name = "@comment", link = false })
local treesitter_keyword = vim.api.nvim_get_hl(0, { name = "@keyword", link = false })
local status_base = vim.api.nvim_get_hl(0, { name = "DotfilesStatusBase", link = false })
assert(normal.bg == tonumber("1a1b26", 16), "TokyoNight Night Normal background mismatch")
assert(comment.italic == true, "TokyoNight comments must be italic")
assert(keyword.italic == true, "TokyoNight keywords must be italic")
assert(treesitter_comment.italic == true, "TokyoNight Treesitter comments must be italic")
assert(treesitter_keyword.italic == true, "TokyoNight Treesitter keywords must be italic")
assert(
  status_base.bg == normal.bg,
  "statusline ColorScheme repair must retain the shared background"
)

for index = 0, 15 do
  local color = vim.g["terminal_color_" .. index]
  assert(type(color) == "string" and color ~= "", "terminal ANSI color missing: " .. index)
end

assert(vim.o.laststatus == 3, "standalone Neovim must retain the shared-row ownership")

local uv = assert(vim.uv, "vim.uv is required for live Treesitter assertions")

local function open_regular(path, label)
  local descriptor, open_error = uv.fs_open(path, "r", 0)
  assert(descriptor, string.format("could not open %s: %s", label, tostring(open_error)))

  local stat, stat_error = uv.fs_fstat(descriptor)
  if not stat or stat.type ~= "file" or stat.size <= 0 then
    uv.fs_close(descriptor)
    error(string.format("%s must be a readable nonempty file: %s", label, tostring(stat_error)), 0)
  end

  return descriptor, stat
end

local function require_nonempty_file(path, label)
  local descriptor, stat = open_regular(path, label)
  local first_byte, read_error = uv.fs_read(descriptor, 1, 0)
  local closed, close_error = uv.fs_close(descriptor)
  assert(closed, string.format("could not close %s: %s", label, tostring(close_error)))
  assert(
    first_byte and #first_byte == 1,
    string.format("could not read %s: %s", label, tostring(read_error))
  )
  return stat
end

local function read_exact_file(path, label)
  local descriptor, stat = open_regular(path, label)
  local contents, read_error = uv.fs_read(descriptor, stat.size, 0)
  local closed, close_error = uv.fs_close(descriptor)
  assert(closed, string.format("could not close %s: %s", label, tostring(close_error)))
  assert(
    contents and #contents == stat.size,
    string.format("could not read complete %s: %s", label, tostring(read_error))
  )
  return contents
end

local expected_languages = {
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

local treesitter = require("config.treesitter")
assert(
  vim.deep_equal(treesitter.languages(), expected_languages),
  "Treesitter declared language boundary mismatch"
)

local install_dir = vim.fs.joinpath(vim.fn.stdpath("data"), "site")
local parsers = require("nvim-treesitter.parsers")

for _, language in ipairs(expected_languages) do
  local parser = assert(parsers[language], "missing parser manifest: " .. language)
  local install_info = assert(parser.install_info, "missing parser install info: " .. language)
  local revision = install_info.revision
  assert(type(revision) == "string" and revision ~= "", "missing parser revision: " .. language)

  local recorded_path = vim.fs.joinpath(install_dir, "parser-info", language .. ".revision")
  local recorded = read_exact_file(recorded_path, language .. " parser revision")
  assert(recorded == revision, language .. " parser revision differs from the pinned manifest")

  local parser_path = vim.fs.joinpath(install_dir, "parser", language .. ".so")
  require_nonempty_file(parser_path, language .. " managed parser")

  local relative_query = vim.fs.joinpath("queries", language, "highlights.scm")
  local managed_query = vim.fs.joinpath(install_dir, relative_query)
  require_nonempty_file(managed_query, language .. " managed highlight query")

  local runtime_queries = vim.api.nvim_get_runtime_file(relative_query, true)
  assert(#runtime_queries > 0, language .. " has no runtime highlight query")
  for index, query_path in ipairs(runtime_queries) do
    require_nonempty_file(
      query_path,
      string.format("%s runtime highlight query %d", language, index)
    )
  end

  local parser_ok, loaded = pcall(vim.treesitter.language.add, language)
  assert(parser_ok and loaded, language .. " parser must load from the managed installation")

  local query_ok, query = pcall(vim.treesitter.query.get, language, "highlights")
  assert(query_ok and query, language .. " highlight query must compile")
end

assert(
  parsers.html
    and type(parsers.html.requires) == "table"
    and vim.tbl_contains(parsers.html.requires, "html_tags"),
  "HTML manifest must retain its html_tags dependency"
)

local html_tags_relative = vim.fs.joinpath("queries", "html_tags", "highlights.scm")
local html_tags_managed = vim.fs.joinpath(install_dir, html_tags_relative)
require_nonempty_file(html_tags_managed, "managed html_tags highlight query")
local html_tags_runtime = vim.api.nvim_get_runtime_file(html_tags_relative, true)
assert(#html_tags_runtime > 0, "html_tags has no runtime highlight query")
for index, query_path in ipairs(html_tags_runtime) do
  require_nonempty_file(query_path, string.format("html_tags runtime highlight query %d", index))
end

assert(vim.treesitter.language.get_lang("sh") == "bash", "sh must resolve to the bash parser")
assert(vim.treesitter.language.get_lang("help") == "vimdoc", "help must resolve to vimdoc")

local previous_buffer = vim.api.nvim_get_current_buf()
local scratch = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(scratch)
vim.api.nvim_buf_set_lines(scratch, 0, -1, false, { "local answer = 42", "return answer" })
vim.b[scratch].dotfiles_treesitter_language = "lua"
vim.bo[scratch].filetype = "lua"
vim.treesitter.stop(scratch)
local fold_after_filetype = {
  foldmethod = vim.wo.foldmethod,
  foldexpr = vim.wo.foldexpr,
  foldenable = vim.wo.foldenable,
  foldlevel = vim.wo.foldlevel,
}
local indent_after_filetype = vim.bo[scratch].indentexpr
assert(
  vim.treesitter.highlighter.active[scratch] == nil,
  "fixture baseline must have no active Treesitter highlighter"
)
vim.b[scratch].dotfiles_treesitter_language = nil
vim.api.nvim_exec_autocmds("BufEnter", { buffer = scratch })

assert(
  vim.b[scratch].dotfiles_treesitter_language == "lua",
  "Lua buffer must record successful Treesitter attachment"
)
assert(
  vim.treesitter.highlighter.active[scratch] ~= nil,
  "Lua buffer must have a native Treesitter highlighter"
)
assert(vim.bo[scratch].syntax == "", "Treesitter attachment must not restore regex syntax")
assert(
  vim.deep_equal({
    foldmethod = vim.wo.foldmethod,
    foldexpr = vim.wo.foldexpr,
    foldenable = vim.wo.foldenable,
    foldlevel = vim.wo.foldlevel,
  }, fold_after_filetype),
  "Treesitter attachment must preserve the ftplugin fold options"
)
assert(
  vim.bo[scratch].indentexpr == indent_after_filetype,
  "Treesitter attachment must preserve the ftplugin indentexpr"
)
assert(
  not vim.bo[scratch].indentexpr:find("nvim-treesitter", 1, true),
  "Treesitter experimental indentexpr must remain disabled"
)

pcall(vim.treesitter.stop, scratch)
vim.api.nvim_set_current_buf(previous_buffer)
vim.api.nvim_buf_delete(scratch, { force = true })

print("Neovim foundation assertions: ok")
