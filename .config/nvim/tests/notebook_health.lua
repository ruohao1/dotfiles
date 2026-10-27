local function expect(value, message)
  if not value then
    error(message, 2)
  end
end

local function contains(value, needle)
  return type(value) == "string" and value:find(needle, 1, true) ~= nil
end

local expected_versions = {
  ipykernel = "7.3.0",
  ["jupyter-client"] = "8.9.1",
  jupytext = "1.19.5",
  nbformat = "5.11.0",
  pynvim = "0.6.0",
}

local function probe_result()
  return {
    actual = vim.deepcopy(expected_versions),
    expected = vim.deepcopy(expected_versions),
    python_compatible = true,
    requires_python = ">=3.10,<3.15",
  }
end

local function merge(target, source)
  for key, value in pairs(source or {}) do
    target[key] = value
  end
  return target
end

local function healthy_dependencies(overrides)
  local reports = {}
  local calls = {
    commands = {},
    created = {},
    resolve = 0,
  }
  local command_set = {
    MoltenExportOutput = true,
    MoltenImportOutput = true,
    MoltenInit = true,
  }
  local environment = {
    TERM_PROGRAM = "ghostty",
    TMUX = "/tmp/tmux-1000/default,1,0",
  }
  local globals = { molten_image_provider = "image.nvim" }
  local buffer = {
    metadata = { kernelspec = { name = "python3" } },
    name = "/work/notebooks/report.ipynb",
    notebook = true,
  }

  local deps = {
    health = {},
    env = environment,
    buffer_name = function()
      return buffer.name
    end,
    buffer_var = function(name)
      if name == "dotfiles_notebook" then
        return buffer.notebook
      end
      if name == "dotfiles_notebook_metadata" then
        return buffer.metadata
      end
    end,
    command_exists = function(name)
      return command_set[name] == true
    end,
    create_user_command = function(name, callback, options)
      calls.created[#calls.created + 1] = { callback = callback, name = name, options = options }
      command_set[name] = true
    end,
    environment_resolve = function(path, metadata)
      calls.resolve = calls.resolve + 1
      expect(path == buffer.name, "health changed the notebook path before resolution")
      expect(metadata == buffer.metadata, "health did not pass stored notebook metadata")
      return {
        interpreter = "/work/.venv/bin/python",
        kind = "interpreter",
        label = "uv: work",
        manager = "uv",
        root = "/work",
        source = "uv",
      }, {}
    end,
    executable = function(command)
      return (
        command == "/editor/bin/python"
        or command == "/editor/bin/jupyter"
        or command == "/editor/bin/jupytext"
        or command == "/work/.venv/bin/python"
        or command == "magick"
      )
          and 1
        or 0
    end,
    get_global = function(name)
      return globals[name]
    end,
    json_decode = vim.json.decode,
    normalize = vim.fs.normalize,
    python_paths = function()
      return {
        environment = "/editor",
        jupyter = "/editor/bin/jupyter",
        jupytext = "/editor/bin/jupytext",
        python = "/editor/bin/python",
      }
    end,
    realpath = function(path)
      return path
    end,
    run_checkhealth = function()
      calls.checkhealth = (calls.checkhealth or 0) + 1
    end,
    system = function(command, options, timeout)
      calls.commands[#calls.commands + 1] = {
        command = vim.deepcopy(command),
        options = vim.deepcopy(options),
        timeout = timeout,
      }
      if command[1] == "/editor/bin/python" then
        return {
          code = 0,
          signal = 0,
          stderr = "",
          stdout = vim.json.encode(probe_result()) .. "\n",
        }
      end

      local key = table.concat(command, " ")
      local outputs = {
        ["tmux show-options -sv allow-passthrough"] = "allow-passthrough=on\n",
        ["tmux show-options -sv focus-events"] = "focus-events=on\n",
        ["tmux show-options -gv visual-activity"] = "off\n",
      }
      return {
        code = outputs[key] and 0 or 1,
        signal = 0,
        stderr = outputs[key] and "" or "unexpected command",
        stdout = outputs[key] or "",
      }
    end,
  }

  for _, level in ipairs({ "start", "ok", "warn", "error", "info" }) do
    deps.health[level] = function(message)
      reports[#reports + 1] = { level = level, message = message }
    end
  end

  merge(deps, overrides)
  return deps, reports, calls, buffer, command_set, environment, globals
end

local health_module = require("notebook.health")

local function run_case(overrides, configure)
  local deps, reports, calls, buffer, commands, environment, globals =
    healthy_dependencies(overrides)
  if configure then
    configure(deps, buffer, commands, environment, globals)
  end
  local health = health_module._test.new(deps)
  local ok, error_message = pcall(health.check)
  expect(ok, "health check raised an exception: " .. tostring(error_message))

  local result = { calls = calls, reports = reports }
  function result:has(level, needle)
    for _, report in ipairs(self.reports) do
      if report.level == level and contains(report.message, needle) then
        return true
      end
    end
    return false
  end
  function result:index(level, needle)
    for index, report in ipairs(self.reports) do
      if report.level == level and contains(report.message, needle) then
        return index
      end
    end
  end
  function result:execution_blocked()
    for _, report in ipairs(self.reports) do
      if report.level == "error" then
        return true
      end
    end
    return false
  end
  return result, health
end

local healthy = run_case()
expect(healthy:has("start", "Neovim notebook workflow"), "health section title is missing")
expect(healthy:has("ok", "current buffer is notebook-backed"), "notebook scope is not reported")
expect(healthy:has("ok", "stored kernelspec: python3"), "stored kernelspec is not reported")
expect(healthy:has("ok", "editor Python: /editor/bin/python"), "editor Python is not reported")
expect(healthy:has("ok", "jupytext 1.19.5"), "Jupytext version is not reported")
expect(healthy:has("ok", "pynvim 0.6.0"), "pynvim version is not reported")
expect(healthy:has("ok", "jupyter-client 8.9.1"), "Jupyter client version is not reported")
expect(healthy:has("ok", "nbformat 5.11.0"), "nbformat version is not reported")
expect(healthy:has("ok", "ipykernel 7.3.0"), "ipykernel version is not reported")
expect(healthy:has("ok", "Molten commands are available"), "Molten availability is not reported")
expect(healthy:has("ok", "recorded kernel: python3"), "recorded candidate is not reported")
expect(healthy:has("ok", "active environment:"), "active environment line is not reported")
expect(healthy:has("ok", "nearest uv:"), "nearest uv line is not reported")
expect(healthy:has("ok", "nearest Poetry:"), "nearest Poetry line is not reported")
expect(healthy:has("ok", "selected uv interpreter"), "selected environment is not reported")
expect(healthy:has("ok", "/work/.venv/bin/python"), "selected interpreter path is not reported")
expect(healthy:has("ok", "Kitty graphics protocol"), "terminal graphics support is not reported")
expect(healthy:has("ok", "image.nvim"), "configured image provider is not reported")
expect(healthy:has("ok", "allow-passthrough=on"), "tmux passthrough is not reported")
expect(healthy:has("ok", "focus-events=on"), "tmux focus events are not reported")
expect(healthy:has("ok", "visual-activity=off"), "tmux activity overlays are not reported")
expect(healthy:has("ok", "ImageMagick"), "image processor is not reported")
expect(healthy.calls.resolve == 1, "healthy notebook was not resolved exactly once")

local ordered_groups = {
  { "ok", "current buffer" },
  { "ok", "editor Python" },
  { "ok", "Molten commands" },
  { "ok", "recorded kernel" },
  { "ok", "Kitty graphics protocol" },
  { "ok", "allow-passthrough" },
  { "ok", "ImageMagick" },
}
local previous = 0
for _, item in ipairs(ordered_groups) do
  local index = healthy:index(item[1], item[2])
  expect(index and index > previous, "health report groups are out of order at " .. item[2])
  previous = index
end

local python_probes = 0
local test_source = assert(vim.uv.fs_realpath(debug.getinfo(1, "S").source:sub(2)))
local nvim_root = vim.fs.dirname(vim.fs.dirname(test_source))
for _, call in ipairs(healthy.calls.commands) do
  expect(type(call.timeout) == "number" and call.timeout > 0, "health subprocess was unbounded")
  expect(call.timeout <= 10000, "health subprocess timeout exceeded ten seconds")
  expect(
    call.options and call.options.text == true,
    "health subprocess did not request text output"
  )
  if call.command[1] == "/editor/bin/python" then
    python_probes = python_probes + 1
    expect(
      vim.deep_equal(call.command, {
        "/editor/bin/python",
        "-I",
        "-B",
        nvim_root .. "/python/dependencies.py",
        "--imports",
      }),
      "health must run the shared reader once with notebook imports"
    )
  end
end
expect(python_probes == 1, "health must use exactly one editor Python probe")

local function with_probe(value)
  return run_case(nil, function(deps)
    local original_system = deps.system
    deps.system = function(command, options, timeout)
      local result = original_system(command, options, timeout)
      if command[1] == "/editor/bin/python" then
        result.stdout = type(value) == "string" and value or vim.json.encode(value)
      end
      return result
    end
  end)
end

local changed_contract = probe_result()
changed_contract.expected.pynvim = "9.9.9"
expect(
  with_probe(changed_contract):has("error", "pynvim 0.6.0 (expected 9.9.9)"),
  "health must use the project-derived expected version"
)
changed_contract.actual.pynvim = "9.9.9"
expect(
  with_probe(changed_contract):has("ok", "pynvim 9.9.9"),
  "health must accept an installed version matching the changed project"
)

for _, malformed in ipairs({
  "{broken",
  "[]",
  { actual = expected_versions },
  { expected = expected_versions },
}) do
  expect(
    with_probe(malformed):has("error", "returned invalid JSON"),
    "missing dependency maps must not report health success"
  )
end

local missing_expected = probe_result()
missing_expected.expected.pynvim = nil
expect(
  with_probe(missing_expected):has("error", "pynvim expected version is missing"),
  "missing expected package metadata must fail closed"
)
local missing_actual = probe_result()
missing_actual.actual.pynvim = nil
expect(
  with_probe(missing_actual):has("error", "pynvim is missing (expected 0.6.0)"),
  "missing installed package metadata must retain the expected-version diagnostic"
)

do
  local fixture = vim.fn.tempname()
  local source = fixture .. "/standalone editor"
  local deployed = fixture .. "/deployed"
  vim.fn.mkdir(source .. "/lua/notebook", "p")
  vim.fn.mkdir(source .. "/python", "p")
  vim.fn.mkdir(deployed .. "/lua/notebook", "p")
  vim.fn.mkdir(deployed .. "/python", "p")
  vim.fn.writefile(
    vim.fn.readfile(nvim_root .. "/lua/notebook/health.lua"),
    source .. "/lua/notebook/health.lua"
  )
  vim.fn.writefile({ "# canonical reader" }, source .. "/python/dependencies.py")
  vim.fn.writefile({ "# foreign deployed reader" }, deployed .. "/python/dependencies.py")
  assert(
    vim.uv.fs_symlink(source .. "/lua/notebook/health.lua", deployed .. "/lua/notebook/health.lua")
  )
  local standalone = dofile(deployed .. "/lua/notebook/health.lua")
  local deps, _, calls = healthy_dependencies({ realpath = vim.uv.fs_realpath })
  standalone._test.new(deps).check()
  local reader_probe
  for _, call in ipairs(calls.commands) do
    if call.command[1] == "/editor/bin/python" then
      reader_probe = call.command
    end
  end
  expect(
    reader_probe and reader_probe[4] == source .. "/python/dependencies.py",
    "a deployed health link must select the reader beside its canonical standalone source"
  )
  vim.fn.delete(fixture, "rf")
end

for _, failed_resolution in ipairs({
  function(path)
    if path:match("/lua/notebook/health%.lua$") then
      return nil, "injected missing source"
    end
    return path
  end,
  function(path)
    if path:match("/lua/notebook/health%.lua$") then
      error("injected source lookup failure")
    end
    return path
  end,
}) do
  local unavailable = run_case({ realpath = failed_resolution })
  expect(
    unavailable:has("error", "dependency reader is unavailable")
      and unavailable:has("error", ":NotebookBootstrap"),
    "reader lookup failure must report recovery guidance"
  )
  for _, call in ipairs(unavailable.calls.commands) do
    expect(call.command[1] ~= "/editor/bin/python", "unresolved reader reached Python")
  end
end

local missing_reader = run_case(nil, function(deps)
  local original_system = deps.system
  deps.system = function(command, options, timeout)
    if command[1] == "/editor/bin/python" then
      return { code = 2, stderr = "can't open file dependencies.py", stdout = "" }
    end
    return original_system(command, options, timeout)
  end
end)
expect(
  missing_reader:has("error", "dependency probe failed")
    and missing_reader:has("error", ":NotebookBootstrap"),
  "missing reader file must remain an actionable probe failure"
)

local missing_editor = run_case({
  python_paths = function()
    error("injected missing editor environment")
  end,
})
expect(
  missing_editor:has("error", ":NotebookBootstrap"),
  "missing editor environment must be an error with recovery command"
)

local failed_editor_probe = run_case({
  system = function(command)
    if command[1] == "/editor/bin/python" then
      error("injected process failure")
    end
    return { code = 1, signal = 0, stderr = "injected process failure", stdout = "" }
  end,
})
expect(
  failed_editor_probe:has("error", ":NotebookBootstrap"),
  "editor probe exceptions must be contained with recovery guidance"
)

local missing_converter = run_case({
  python_paths = function()
    return {
      environment = "/editor",
      jupyter = "/editor/bin/jupyter",
      python = "/editor/bin/python",
    }
  end,
})
expect(
  missing_converter:has("error", "Jupytext executable is unavailable")
    and missing_converter:has("error", ":NotebookBootstrap"),
  "missing Jupytext executable must be an actionable editor dependency error"
)

local missing_ipykernel = run_case({
  environment_resolve = function()
    return { kind = "picker", warnings = {} }, {
      "uv project interpreter cannot import ipykernel: missing; run uv add --dev ipykernel",
    }
  end,
})
expect(
  missing_ipykernel:has("error", "uv add --dev ipykernel"),
  "missing project ipykernel must show the manager hint"
)

local invalid_selected = run_case({
  environment_resolve = function()
    return {
      interpreter = "/missing/bin/python",
      kind = "interpreter",
      source = "poetry",
    }, {}
  end,
})
expect(
  invalid_selected:has("error", "selected Poetry interpreter is not executable"),
  "invalid selected interpreter must be an error"
)

local invalid_registered = run_case({
  environment_resolve = function()
    return {
      kernel = "python3",
      kind = "registered",
    }, {}
  end,
})
expect(
  invalid_registered:has("error", "selected registered interpreter is missing"),
  "registered candidate without an interpreter must be an error"
)

local resolver_exception = run_case({
  environment_resolve = function()
    error("injected resolver failure")
  end,
})
expect(
  resolver_exception:has("warn", "injected resolver failure"),
  "resolver exceptions must be contained as project warnings"
)

local missing_molten = run_case({
  command_exists = function(name)
    if name == "MoltenImportOutput" then
      error("injected command lookup failure")
    end
    return name ~= "MoltenExportOutput"
  end,
})
expect(
  missing_molten:has("error", "MoltenImportOutput")
    and missing_molten:has("error", "MoltenExportOutput"),
  "missing Molten commands in a notebook must be errors"
)
expect(
  missing_molten:has("error", ":NotebookBootstrap")
    and missing_molten:has("error", ":UpdateRemotePlugins")
    and missing_molten:has("error", "restart Neovim"),
  "missing Molten commands must explain how to refresh the remote-plugin manifest"
)

local tmux_without_passthrough = run_case(nil, function(deps)
  local original_system = deps.system
  deps.system = function(command, options, timeout)
    local result = original_system(command, options, timeout)
    if table.concat(command, " ") == "tmux show-options -sv allow-passthrough" then
      result.stdout = "allow-passthrough=off\n"
    end
    return result
  end
end)
expect(
  tmux_without_passthrough:has("warn", "allow-passthrough"),
  "tmux rendering issue must be a warning"
)

local without_imagemagick = run_case({
  executable = function(command)
    return command:sub(1, 1) == "/" and 1 or 0
  end,
})
expect(without_imagemagick:has("warn", "ImageMagick"), "image rendering issue must be a warning")
expect(
  without_imagemagick:execution_blocked() == false,
  "rendering diagnostics must never block execution"
)

local ordinary = run_case({
  command_exists = function()
    return false
  end,
  environment_resolve = function()
    error("ordinary Markdown must not resolve a notebook environment")
  end,
}, function(_, buffer)
  buffer.metadata = nil
  buffer.name = "/work/README.md"
  buffer.notebook = false
end)
expect(ordinary:has("ok", "not notebook-backed"), "ordinary Markdown scope must be explicit")
expect(
  not ordinary:has("error", "Molten"),
  "ordinary Markdown must not turn missing Molten commands into an error"
)
expect(ordinary.calls.resolve == 0, "ordinary Markdown invoked project resolution")

local scope_exception = run_case({
  buffer_var = function(name)
    if name == "dotfiles_notebook_metadata" then
      error("injected metadata lookup failure")
    end
    return name == "dotfiles_notebook"
  end,
})
expect(
  scope_exception:has("warn", "injected metadata lookup failure"),
  "buffer metadata exceptions must be contained and reported"
)

do
  local deps, _, calls = healthy_dependencies()
  local health = health_module._test.new(deps)
  health.setup()
  health.setup()
  expect(#calls.created == 1, "NotebookHealth setup is not idempotent")
  expect(calls.created[1].name == "NotebookHealth", "health setup created the wrong command")
  expect(
    calls.created[1].options.desc == "Check the Neovim notebook workflow",
    "health command description changed"
  )
  calls.created[1].callback()
  expect(calls.checkhealth == 1, "NotebookHealth did not invoke checkhealth notebook")
end

print("notebook health assertions: ok")
