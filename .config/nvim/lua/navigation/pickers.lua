local M = {}

local notification_title = "Neovim navigation"

local function new(dependencies)
  local fzf_ready
  local find_warning_sent = false

  local function notify(message, level)
    dependencies.notify(message, level, { title = notification_title })
  end

  local function check_fzf()
    if fzf_ready ~= nil then
      return fzf_ready
    end

    if not dependencies.executable("fzf") then
      fzf_ready = false
      notify("FzfLua requires fzf 0.36 or newer", vim.log.levels.ERROR)
      return false
    end

    local result = dependencies.system({ "fzf", "--version" })
    local major, minor = tostring(result.stdout or ""):match("(%d+)%.(%d+)")
    if result.code ~= 0 or not major then
      fzf_ready = false
      notify("Could not determine the installed fzf version", vim.log.levels.ERROR)
      return false
    end

    fzf_ready = tonumber(major) > 0 or tonumber(minor) >= 36
    if not fzf_ready then
      notify("FzfLua requires fzf 0.36 or newer", vim.log.levels.ERROR)
    end
    return fzf_ready
  end

  local function check_file_provider()
    for _, provider in ipairs({ "fdfind", "fd", "rg" }) do
      if dependencies.executable(provider) then
        return true
      end
    end

    if dependencies.executable("find") then
      if not find_warning_sent then
        find_warning_sent = true
        notify(
          "Using find fallback; repository ignore files may not be fully respected",
          vim.log.levels.WARN
        )
      end
      return true
    end

    notify("File search requires fdfind, fd, rg, or find", vim.log.levels.ERROR)
    return false
  end

  local function check_grep_provider()
    if dependencies.executable("rg") or dependencies.executable("grep") then
      return true
    end

    notify("Live grep requires rg or grep", vim.log.levels.ERROR)
    return false
  end

  return {
    files = function(cwd)
      if not check_fzf() or not check_file_provider() then
        return
      end
      dependencies.fzf().files({ cwd = cwd or dependencies.root() })
    end,
    grep = function()
      if not check_fzf() or not check_grep_provider() then
        return
      end
      dependencies.fzf().live_grep({ cwd = dependencies.root() })
    end,
    buffers = function()
      if not check_fzf() then
        return
      end
      dependencies.fzf().buffers()
    end,
    recent = function(cwd)
      if not check_fzf() then
        return
      end
      dependencies.fzf().oldfiles(cwd and { cwd = cwd, cwd_only = true } or nil)
    end,
    line_pins = function(source)
      if not check_fzf() then
        return
      end
      return require("navigation.location_pin_picker").open(dependencies.fzf(), source)
    end,
    clipboard_history = function()
      if not check_fzf() then
        return
      end
      return dependencies.history().open()
    end,
    help = function()
      if not check_fzf() then
        return
      end
      dependencies.fzf().helptags()
    end,
    lsp_locations = function()
      if not check_fzf() then
        return
      end
      dependencies.fzf().lsp_finder({
        async = true,
        silent = true,
        includeDeclaration = false,
        providers = {
          { "definitions", prefix = "def " },
          { "implementations", prefix = "impl" },
          { "typedefs", prefix = "type" },
          { "references", prefix = "ref " },
        },
      })
    end,
    document_symbols = function()
      if not check_fzf() then
        return
      end
      dependencies.fzf().lsp_document_symbols()
    end,
    workspace_symbols = function()
      if not check_fzf() then
        return
      end
      dependencies.fzf().lsp_live_workspace_symbols()
    end,
    document_diagnostics = function()
      if not check_fzf() then
        return
      end
      dependencies.fzf().diagnostics_document()
    end,
    all_diagnostics = function()
      if not check_fzf() then
        return
      end
      dependencies.fzf().diagnostics_workspace()
    end,
  }
end

local runtime = new({
  executable = function(name)
    return vim.fn.executable(name) == 1
  end,
  system = function(argv)
    return vim.system(argv, { text = true }):wait(1000)
  end,
  notify = function(message, level, options)
    vim.notify(message, level, options)
  end,
  fzf = function()
    return require("fzf-lua")
  end,
  history = function()
    return require("clipboard.history")
  end,
  root = function()
    return require("navigation.root").resolve()
  end,
})

M.files = runtime.files
M.grep = runtime.grep
M.buffers = runtime.buffers
M.recent = runtime.recent
M.line_pins = runtime.line_pins
M.clipboard_history = runtime.clipboard_history
M.help = runtime.help
M.lsp_locations = runtime.lsp_locations
M.document_symbols = runtime.document_symbols
M.workspace_symbols = runtime.workspace_symbols
M.document_diagnostics = runtime.document_diagnostics
M.all_diagnostics = runtime.all_diagnostics
M._test = { new = new }

return M
