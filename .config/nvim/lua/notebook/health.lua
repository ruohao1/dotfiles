local M = {}

local process_timeout = 10000
local module_source = debug.getinfo(1, "S").source

local required_packages = {
  "jupytext",
  "pynvim",
  "jupyter-client",
  "nbformat",
  "ipykernel",
}

local function nonempty(value)
  if type(value) ~= "string" then
    return nil
  end

  value = value:match("^%s*(.-)%s*$")
  return value ~= "" and value or nil
end

local function contains(value, needle)
  return type(value) == "string" and value:find(needle, 1, true) ~= nil
end

local function command_failure(result)
  return nonempty(result and result.stderr)
    or nonempty(result and result.stdout)
    or (result and result.signal and result.signal ~= 0 and "terminated by signal " .. result.signal)
    or "exited with status " .. tostring(result and result.code)
end

local function source_label(source)
  if source == "poetry" then
    return "Poetry"
  end
  if source == "active" then
    return "active"
  end
  if source == "editor" then
    return "editor"
  end
  if source == "uv" then
    return "uv"
  end
  return tostring(source or "unknown")
end

local function new(deps)
  local Health = {}

  local function report(level, message)
    deps.health[level](message)
  end

  local function protected_value(callback)
    local ok, value, detail = pcall(callback)
    if not ok then
      return nil, tostring(value)
    end
    return value, detail
  end

  local function executable(path)
    local value, executable_error = protected_value(function()
      return deps.executable(path)
    end)
    if value == nil then
      return false, executable_error
    end
    return value == 1
  end

  local function current_scope()
    local path, path_error = protected_value(deps.buffer_name)
    if type(path) ~= "string" then
      path = ""
    end

    local normalized = path
    if path ~= "" then
      local value = protected_value(function()
        return deps.normalize(path)
      end)
      if type(value) == "string" and value ~= "" then
        normalized = value
      end

      local resolved = protected_value(function()
        return deps.realpath(normalized)
      end)
      if type(resolved) == "string" and resolved ~= "" then
        normalized = resolved
      end
    end

    local notebook_flag, flag_error = protected_value(function()
      return deps.buffer_var("dotfiles_notebook")
    end)
    local notebook = notebook_flag == true and normalized:lower():sub(-6) == ".ipynb"

    local metadata, metadata_error = protected_value(function()
      return deps.buffer_var("dotfiles_notebook_metadata")
    end)
    if type(metadata) ~= "table" then
      metadata = {}
    end

    local errors = {}
    for _, item in ipairs({
      { value = path_error },
      { value = flag_error },
      { value = metadata_error },
    }) do
      local value = item.value
      if nonempty(value) then
        errors[#errors + 1] = value
      end
    end

    return {
      errors = errors,
      metadata = metadata,
      notebook = notebook,
      path = normalized,
    }
  end

  local function report_scope(scope)
    local display_path = scope.path ~= "" and scope.path or "[No Name]"
    if scope.notebook then
      report("ok", "current buffer is notebook-backed: " .. display_path)
    else
      report("ok", "current buffer is not notebook-backed: " .. display_path)
    end

    for _, scope_error in ipairs(scope.errors) do
      report("warn", "could not inspect current buffer metadata: " .. scope_error)
    end

    local kernelspec = scope.metadata.kernelspec
    local kernel_name = type(kernelspec) == "table" and nonempty(kernelspec.name) or nil
    if scope.notebook and kernel_name then
      report("ok", "stored kernelspec: " .. kernel_name)
    elseif scope.notebook then
      report("ok", "stored kernelspec: none")
    else
      report("ok", "stored kernelspec: not applicable outside notebook scope")
    end
    return kernel_name
  end

  local function report_editor_python()
    local paths, paths_error = protected_value(deps.python_paths)
    if type(paths) ~= "table" then
      report(
        "error",
        "editor Python environment is unavailable: "
          .. tostring(paths_error or "paths were not configured")
          .. "; run :NotebookBootstrap"
      )
      return
    end

    local python = nonempty(paths.python)
    local jupytext = nonempty(paths.jupytext)
    local jupyter = nonempty(paths.jupyter)
    if not python then
      report("error", "editor Python interpreter is not configured; run :NotebookBootstrap")
      return
    end

    report("ok", "editor Python: " .. python)
    for _, executable_spec in ipairs({
      { label = "Python", path = python },
      { label = "Jupytext", path = jupytext },
      { label = "Jupyter", path = jupyter },
    }) do
      local label = executable_spec.label
      local path = executable_spec.path
      local available, availability_error = executable(path)
      if not path or not available then
        local suffix = availability_error and ": " .. availability_error or ""
        report(
          "error",
          "editor "
            .. label
            .. " executable is unavailable: "
            .. tostring(path)
            .. suffix
            .. "; run :NotebookBootstrap"
        )
      end
    end

    local source, source_error = protected_value(function()
      return deps.realpath(module_source:sub(2))
    end)
    local source_root = type(source) == "string"
      and source:match("^(/.*)/lua/notebook/health%.lua$")
    if not source_root then
      report(
        "error",
        "editor Python dependency reader is unavailable: "
          .. tostring(source_error or "could not resolve notebook health source")
          .. "; run :NotebookBootstrap"
      )
      return
    end

    local run_ok, result = pcall(
      deps.system,
      { python, "-I", "-B", source_root .. "/python/dependencies.py", "--imports" },
      { text = true },
      process_timeout
    )
    if not run_ok or type(result) ~= "table" then
      local detail = run_ok and "command returned no result" or tostring(result)
      report(
        "error",
        "editor Python dependency probe failed: " .. detail .. "; run :NotebookBootstrap"
      )
      return
    end
    if result.code ~= 0 or (result.signal and result.signal ~= 0) then
      report(
        "error",
        "editor Python dependency probe failed: "
          .. command_failure(result)
          .. "; run :NotebookBootstrap"
      )
      return
    end

    local decode_ok, probe = pcall(deps.json_decode, result.stdout or "")
    if
      not decode_ok
      or type(probe) ~= "table"
      or type(probe.expected) ~= "table"
      or type(probe.actual) ~= "table"
    then
      report(
        "error",
        "editor Python dependency probe returned invalid JSON: "
          .. tostring(probe)
          .. "; run :NotebookBootstrap"
      )
      return
    end

    for _, package in ipairs(required_packages) do
      local expected = nonempty(probe.expected[package])
      local version = probe.actual[package]
      if not expected then
        report("error", package .. " expected version is missing; run :NotebookBootstrap")
      elseif version == expected then
        report("ok", package .. " " .. version)
      else
        report(
          "error",
          package
            .. " "
            .. tostring(version or "is missing")
            .. " (expected "
            .. expected
            .. "); run :NotebookBootstrap"
        )
      end
    end
  end

  local function report_molten(scope)
    local missing = {}
    for _, command in ipairs({ "MoltenInit", "MoltenImportOutput", "MoltenExportOutput" }) do
      local exists, exists_error = protected_value(function()
        return deps.command_exists(command)
      end)
      if exists ~= true then
        local detail = exists_error and " (lookup failed: " .. exists_error .. ")" or ""
        missing[#missing + 1] = command .. detail
      end
    end

    if #missing == 0 then
      report("ok", "Molten commands are available")
      return
    end

    local message = "Molten commands are unavailable: " .. table.concat(missing, ", ")
    if scope.notebook then
      report(
        "error",
        message
          .. "; run :NotebookBootstrap to refresh the editor environment and remote-plugin manifest, then restart Neovim (or run :UpdateRemotePlugins before restarting)"
      )
    else
      report("ok", message .. " (not required outside notebook scope)")
    end
  end

  local function candidate_slots(candidate)
    local slots = {}

    local function add(value)
      if type(value) ~= "table" then
        return
      end
      if value.kind == "registered" then
        slots.registered = value
      elseif value.kind == "interpreter" and value.source then
        slots[value.source] = value
      end
    end

    add(candidate)
    if type(candidate) == "table" and candidate.kind == "ambiguous" then
      for _, choice in ipairs(candidate.choices or {}) do
        add(choice)
      end
    end
    return slots
  end

  local function describe_slot(label, candidate)
    if not candidate then
      report("ok", label .. ": no usable candidate selected by the resolver")
      return
    end

    local interpreter = nonempty(candidate.interpreter)
    local detail = interpreter and " interpreter " .. interpreter or ""
    if candidate.kind == "registered" then
      detail = " kernel " .. tostring(candidate.kernel or "unknown") .. detail
    end
    report("ok", label .. ":" .. detail)
  end

  local function missing_ipykernel_warning(message)
    return contains(message, "cannot import ipykernel")
      and not contains(message, "Notebook kernelspec ")
  end

  local function report_environment(scope, kernel_name)
    if not scope.notebook then
      report("ok", "recorded kernel: not applicable outside notebook scope")
      report("ok", "selected environment: not applicable outside notebook scope")
      return
    end

    report("ok", "recorded kernel: " .. tostring(kernel_name or "none"))
    local resolve_ok, candidate, warnings =
      pcall(deps.environment_resolve, scope.path, scope.metadata)
    if not resolve_ok then
      report("warn", "notebook environment resolution failed: " .. tostring(candidate))
      report("ok", "active environment: no usable candidate selected by the resolver")
      report("ok", "nearest uv: no usable candidate selected by the resolver")
      report("ok", "nearest Poetry: no usable candidate selected by the resolver")
      report("warn", "selected environment: resolver failed")
      return
    end

    if type(warnings) ~= "table" then
      warnings = type(candidate) == "table" and candidate.warnings or {}
    end
    if type(warnings) ~= "table" then
      warnings = { "resolver returned an invalid warning list" }
    end

    local slots = candidate_slots(candidate)
    describe_slot("active environment", slots.active)
    describe_slot("nearest uv", slots.uv)
    describe_slot("nearest Poetry", slots.poetry)

    for _, warning in ipairs(warnings) do
      warning = tostring(warning)
      if missing_ipykernel_warning(warning) then
        report("error", warning)
      else
        report("warn", warning)
      end
    end

    if type(candidate) ~= "table" then
      report("warn", "selected environment: resolver returned no candidate")
      return
    end
    if candidate.kind == "registered" then
      local interpreter = nonempty(candidate.interpreter)
      if not interpreter then
        report("error", "selected registered interpreter is missing")
        return
      end
      local available, availability_error = executable(interpreter)
      if not available then
        local suffix = availability_error and ": " .. availability_error or ""
        report(
          "error",
          "selected registered interpreter is not executable: " .. interpreter .. suffix
        )
        return
      end
      report(
        "ok",
        "selected registered kernel "
          .. tostring(candidate.kernel or "unknown")
          .. " interpreter "
          .. interpreter
      )
      return
    end
    if candidate.kind == "interpreter" then
      local label = source_label(candidate.source)
      local interpreter = nonempty(candidate.interpreter)
      local available, availability_error = executable(interpreter)
      if not interpreter or not available then
        local suffix = availability_error and ": " .. availability_error or ""
        report(
          "error",
          "selected "
            .. label
            .. " interpreter is not executable: "
            .. tostring(interpreter)
            .. suffix
        )
        return
      end
      report("ok", "selected " .. label .. " interpreter: " .. interpreter)
      return
    end
    if candidate.kind == "ambiguous" then
      report("warn", "selected environment: choose between resolver candidates at first execution")
      return
    end
    report("warn", "selected environment: no automatic candidate; choose at first execution")
  end

  local function report_terminal()
    local term_program, term_error = protected_value(function()
      return deps.env.TERM_PROGRAM
    end)
    local terminal = nonempty(term_program)
    local normalized_terminal = terminal and terminal:lower() or ""
    local supported = normalized_terminal == "ghostty" or normalized_terminal == "kitty"
    local provider, provider_error = protected_value(function()
      return deps.get_global("molten_image_provider")
    end)

    if supported then
      report(
        "ok",
        "Kitty graphics protocol is supported by "
          .. terminal
          .. "; Molten image provider: "
          .. tostring(provider or "not configured")
      )
    else
      local detail = term_error and ": " .. term_error or ""
      report(
        "warn",
        "Kitty graphics protocol support is unknown for TERM_PROGRAM="
          .. tostring(terminal or "unset")
          .. detail
      )
    end

    if provider ~= "image.nvim" then
      local detail = provider_error and ": " .. provider_error or ""
      report(
        "warn",
        "Molten image provider is not image.nvim: " .. tostring(provider or "unset") .. detail
      )
    end
  end

  local function report_tmux()
    local tmux, tmux_error = protected_value(function()
      return deps.env.TMUX
    end)
    if not nonempty(tmux) then
      local detail = tmux_error and ": " .. tmux_error or ""
      report("ok", "tmux is not active" .. detail)
      return
    end

    local checks = {
      {
        command = { "tmux", "show-options", "-sv", "allow-passthrough" },
        expected = "on",
        name = "allow-passthrough",
      },
      {
        command = { "tmux", "show-options", "-sv", "focus-events" },
        expected = "on",
        name = "focus-events",
      },
      {
        command = { "tmux", "show-options", "-gv", "visual-activity" },
        expected = "off",
        name = "visual-activity",
      },
    }

    for _, check in ipairs(checks) do
      local run_ok, result = pcall(deps.system, check.command, { text = true }, process_timeout)
      if not run_ok or type(result) ~= "table" then
        local detail = run_ok and "command returned no result" or tostring(result)
        report("warn", "tmux " .. check.name .. " query failed: " .. detail)
      elseif result.code ~= 0 or (result.signal and result.signal ~= 0) then
        report("warn", "tmux " .. check.name .. " query failed: " .. command_failure(result))
      else
        local output = nonempty(result.stdout) or ""
        local value = output:match("^[^= ]+[= ](.+)$") or output
        local message = check.name .. "=" .. value .. " (exact output: " .. output .. ")"
        if value == check.expected then
          report("ok", message)
        else
          report("warn", message .. "; expected " .. check.name .. "=" .. check.expected)
        end
      end
    end
  end

  local function report_imagemagick()
    local magick = executable("magick")
    if magick then
      report("ok", "ImageMagick CLI is available through magick")
      return
    end

    local identify = executable("identify")
    local convert = executable("convert")
    if identify and convert then
      report("ok", "ImageMagick CLI is available through identify and convert")
    else
      report(
        "warn",
        "ImageMagick CLI is unavailable; inline image rendering may fail, but execution and export remain available"
      )
    end
  end

  function Health.check()
    report("start", "Neovim notebook workflow")
    local scope = current_scope()
    local kernel_name = report_scope(scope)
    report_editor_python()
    report_molten(scope)
    report_environment(scope, kernel_name)
    report_terminal()
    report_tmux()
    report_imagemagick()
  end

  function Health.setup()
    local exists = protected_value(function()
      return deps.command_exists("NotebookHealth")
    end)
    if exists == true then
      return
    end

    deps.create_user_command("NotebookHealth", function()
      deps.run_checkhealth()
    end, { desc = "Check the Neovim notebook workflow" })
  end

  return Health
end

local runtime = new({
  health = vim.health,
  env = vim.env,
  buffer_name = function()
    return vim.api.nvim_buf_get_name(0)
  end,
  buffer_var = function(name)
    return vim.b[name]
  end,
  command_exists = function(name)
    return vim.fn.exists(":" .. name) == 2
  end,
  create_user_command = function(name, callback, options)
    vim.api.nvim_create_user_command(name, callback, options)
  end,
  environment_resolve = function(path, metadata)
    return require("notebook.environment").resolve(path, metadata)
  end,
  executable = function(command)
    return type(command) == "string" and vim.fn.executable(command) or 0
  end,
  get_global = function(name)
    return vim.g[name]
  end,
  json_decode = vim.json.decode,
  normalize = vim.fs.normalize,
  python_paths = function()
    return require("notebook.python").paths()
  end,
  realpath = vim.uv.fs_realpath,
  run_checkhealth = function()
    vim.cmd("checkhealth notebook")
  end,
  system = function(command, options, timeout)
    return vim.system(command, options):wait(timeout)
  end,
})

M.check = runtime.check
M.setup = runtime.setup
M._test = { new = new }

return M
