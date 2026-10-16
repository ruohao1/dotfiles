local function expect(value, message)
  if not value then
    error(message, 2)
  end
end

local function eq(actual, expected, message)
  expect(vim.deep_equal(actual, expected), message .. "\n" .. vim.inspect({ actual, expected }))
end

local test_file = debug.getinfo(1, "S").source:sub(2)
local nvim_root = vim.fs.dirname(vim.fs.dirname(test_file))
vim.opt.runtimepath:prepend(nvim_root)

local tool = require("data_query.tool")

eq(tool.versions, {
  duckdb = "1.5.5",
  pyarrow = "25.0.0",
  uv = "0.11.6",
  visidata = "3.4",
}, "version contract")

local environment = "/tools/visidata"
local python = environment .. "/bin/python"
local runner = "/config/nvim/scripts/data-query-runner.py"
local duckdb_path = environment .. "/lib/python3.13/site-packages/duckdb/__init__.py"
local pyarrow_path = environment .. "/lib/python3.13/site-packages/pyarrow/__init__.py"
local source = "/data/sales.csv"
local workspace = "/cache/run-v1-0123456789abcdef0123456789abcdef"
local spill = workspace .. "/spill"
local result = workspace .. "/result-v1-abcdef0123456789abcdef0123456789.parquet"

local function parquet_report(overrides)
  local report = {
    environment = environment,
    errors = {},
    expected = { pyarrow = "25.0.0", uv = "0.11.6", visidata = "3.4" },
    ok = true,
    pyarrow = { ok = true, path = pyarrow_path, version = "25.0.0" },
    python = python,
    uv = { ok = true, path = "/usr/bin/uv", version = "0.11.6" },
    viewer = { ok = true, path = environment .. "/bin/vd", version = "3.4" },
  }
  return vim.tbl_deep_extend("force", report, overrides or {})
end

local function fixture(case)
  case = case or {}
  local state = {
    executable_calls = {},
    exepath_calls = 0,
    lstat_calls = {},
    parquet_calls = {},
    readable_calls = {},
    realpath_calls = {},
    system_calls = {},
  }

  local module_path = case.module_path or "/config/nvim/lua/data_query/tool.lua"
  local path_candidate = case.path_candidate
  if path_candidate == nil then
    path_candidate = "/usr/bin/bwrap"
  end

  local realpaths = {
    [module_path] = module_path,
    [environment] = environment,
    [duckdb_path] = duckdb_path,
    ["/usr/bin/bwrap"] = "/usr/bin/bwrap",
    ["/bin/bwrap"] = "/usr/bin/bwrap",
    ["/config/nvim"] = "/config/nvim",
    [runner] = runner,
    [source] = source,
    [workspace] = workspace,
    [spill] = spill,
  }
  for path, target in pairs(case.realpaths or {}) do
    realpaths[path] = target
  end

  local metadata = {
    [duckdb_path] = { mode = 33188, type = "file", uid = 1000 },
    ["/usr/bin/bwrap"] = { mode = 33261, type = "file", uid = 0 },
    [runner] = { mode = 33188, type = "file", uid = 1000 },
    [source] = { mode = 33188, type = "file", uid = 1000 },
    [workspace] = { mode = 16832, type = "directory", uid = 1000 },
    [spill] = { mode = 16832, type = "directory", uid = 1000 },
  }
  for path, value in pairs(case.metadata or {}) do
    metadata[path] = value
  end

  local executables = { ["/usr/bin/bwrap"] = true }
  for path, value in pairs(case.executables or {}) do
    executables[path] = value
  end

  local readable = { [duckdb_path] = true, [runner] = true, [source] = true }
  for path, value in pairs(case.readable or {}) do
    readable[path] = value
  end

  local parquet_value = case.parquet_report
  if parquet_value == nil then
    parquet_value = parquet_report()
  end

  local function process_result(command)
    if command[1] == python then
      if case.duckdb_exception then
        error(case.duckdb_exception)
      end
      return vim.deepcopy(case.duckdb_result or {
        code = 0,
        signal = 0,
        stderr = "",
        stdout = vim.json.encode({ path = duckdb_path, version = "1.5.5" }) .. "\n",
      })
    end
    if command[2] == "--version" then
      local configured = case.version_results and case.version_results[command[1]]
      if configured then
        return vim.deepcopy(configured)
      end
      return { code = 0, signal = 0, stderr = "", stdout = "bubblewrap 0.11.2\n" }
    end
    local configured = case.namespace_results and case.namespace_results[command[1]]
    if configured then
      return vim.deepcopy(configured)
    end
    return {
      code = 0,
      signal = 0,
      stderr = "",
      stdout = "data-query-sandbox-ok\n",
    }
  end

  local runtime = tool._test.new({
    deepcopy = vim.deepcopy,
    executable = function(path)
      state.executable_calls[#state.executable_calls + 1] = path
      if case.executable_exception == path then
        error("executable check exploded")
      end
      return executables[path] and 1 or 0
    end,
    exepath = function(name)
      expect(name == "bwrap", "unexpected executable lookup")
      state.exepath_calls = state.exepath_calls + 1
      if case.exepath_exception then
        error(case.exepath_exception)
      end
      return path_candidate
    end,
    joinpath = vim.fs.joinpath,
    json_decode = vim.json.decode,
    lstat = function(path)
      state.lstat_calls[#state.lstat_calls + 1] = path
      if case.fs_root and path:sub(1, #case.fs_root + 1) == case.fs_root .. "/" then
        return vim.uv.fs_lstat(path)
      end
      if case.lstat_exceptions and case.lstat_exceptions[path] then
        error(case.lstat_exceptions[path])
      end
      if case.lstat_errors and case.lstat_errors[path] then
        return nil, case.lstat_errors[path]
      end
      local value = metadata[path]
      if value then
        return vim.deepcopy(value)
      end
      return nil, "ENOENT: no such file or directory"
    end,
    module_source = function()
      if case.module_source_exception then
        error(case.module_source_exception)
      end
      return case.raw_module_source or ("@" .. module_path)
    end,
    normalize = function(path)
      if case.normalize_exceptions and case.normalize_exceptions[path] then
        error(case.normalize_exceptions[path])
      end
      return vim.fs.normalize(path, { expand_env = false })
    end,
    parquet_probe = function(options)
      state.parquet_calls[#state.parquet_calls + 1] = vim.deepcopy(options)
      if case.parquet_exception then
        error(case.parquet_exception)
      end
      if type(parquet_value) == "function" then
        return parquet_value(#state.parquet_calls)
      end
      return vim.deepcopy(parquet_value)
    end,
    platform = function()
      if case.platform_exception then
        error(case.platform_exception)
      end
      return case.platform or "Linux"
    end,
    readable = function(path)
      state.readable_calls[#state.readable_calls + 1] = path
      if case.fs_root and path:sub(1, #case.fs_root + 1) == case.fs_root .. "/" then
        return vim.fn.filereadable(path)
      end
      if case.readable_exception == path then
        error("readability check exploded")
      end
      return readable[path] and 1 or 0
    end,
    realpath = function(path)
      state.realpath_calls[#state.realpath_calls + 1] = path
      if case.fs_root and path:sub(1, #case.fs_root + 1) == case.fs_root .. "/" then
        return vim.uv.fs_realpath(path)
      end
      if case.realpath_exceptions and case.realpath_exceptions[path] then
        error(case.realpath_exceptions[path])
      end
      if case.realpath_errors and case.realpath_errors[path] then
        return nil, case.realpath_errors[path]
      end
      if case.result_realpath ~= nil and path == result then
        return case.result_realpath
      end
      if path:sub(1, #workspace + 1) == workspace .. "/" and path:sub(-8) == ".parquet" then
        return nil, "ENOENT: no such file or directory"
      end
      local value = realpaths[path]
      if value == false then
        return nil, "ENOENT: no such file or directory"
      end
      return value or path
    end,
    system = function(command, options, wait_timeout)
      state.system_calls[#state.system_calls + 1] = {
        command = vim.deepcopy(command),
        options = vim.deepcopy(options),
        timeout = wait_timeout,
      }
      if case.system_exception and case.system_exception(command) then
        error("system call exploded")
      end
      return process_result(command)
    end,
    uid = function()
      return case.uid or 1000
    end,
  })
  return runtime, state, metadata, realpaths, executables, readable
end

local function joined_errors(report)
  return table.concat(report.errors or {}, "; ")
end

local function contains(haystack, needle, message)
  expect(haystack:find(needle, 1, true), message .. ": " .. haystack)
end

local expected_report = {
  duckdb = { ok = true, path = duckdb_path, version = "1.5.5" },
  environment = environment,
  errors = {},
  expected = {
    duckdb = "1.5.5",
    pyarrow = "25.0.0",
    uv = "0.11.6",
    visidata = "3.4",
  },
  ok = true,
  platform = "Linux",
  pyarrow = { ok = true, path = pyarrow_path, version = "25.0.0" },
  python = python,
  runner = { ok = true, path = runner },
  sandbox = {
    ok = true,
    path = "/usr/bin/bwrap",
    probe = "data-query-sandbox-ok",
    version = "0.11.2",
  },
  uv = { ok = true, path = "/usr/bin/uv", version = "0.11.6" },
  viewer = { ok = true, path = environment .. "/bin/vd", version = "3.4" },
}

do
  local runtime, state = fixture()
  local report = runtime.probe()
  eq(report, expected_report, "ready report")
  expect(#state.parquet_calls == 1, "Parquet resolver call count")
  eq(state.parquet_calls[1], {}, "Parquet resolver options")
  expect(#state.system_calls == 3, "ready resolver process count")
  for _, call in ipairs(state.system_calls) do
    expect(call.timeout == 10000, "resolver timeout changed")
    expect(call.options.text == true, "resolver did not request text output")
    expect(call.options.clear_env == true, "resolver inherited the parent environment")
    eq(call.options.env, {
      PYTHONDONTWRITEBYTECODE = "1",
      PYTHONNOUSERSITE = "1",
      UV_OFFLINE = "1",
    }, "resolver environment")
  end

  report.duckdb.version = "mutated"
  report.errors[1] = "mutated"
  eq(runtime.probe(), expected_report, "cached report is a defensive copy")
  expect(#state.parquet_calls == 1, "successful report was not cached")

  runtime.probe({ refresh = true })
  expect(#state.parquet_calls == 2, "refresh did not rerun the resolver")
  eq(state.parquet_calls[2], { refresh = true }, "refresh was not passed to Parquet resolver")
  runtime.invalidate()
  runtime.probe()
  expect(#state.parquet_calls == 3, "invalidate did not clear the query cache")
end

for _, case in ipairs({
  {
    name = "exception",
    parquet_exception = "Parquet resolver exploded",
    needle = "Parquet resolver failed",
  },
  {
    name = "non-table",
    parquet_report = "bad",
    needle = "Parquet resolver returned an invalid report",
  },
  {
    name = "missing components",
    parquet_report = { errors = {}, ok = true },
    needle = "Parquet resolver report is incomplete",
  },
  {
    name = "not ready",
    parquet_report = parquet_report({ errors = { "uv missing", "uv missing" }, ok = false }),
    needle = "managed Parquet runtime is not ready",
    detail = "uv missing",
  },
}) do
  local runtime, state = fixture(case)
  local report = runtime.probe()
  expect(not report.ok, case.name .. " unexpectedly passed")
  contains(joined_errors(report), case.needle, case.name .. " diagnostic")
  if case.detail then
    contains(joined_errors(report), case.detail, case.name .. " detail")
    local matches = 0
    for _, error_message in ipairs(report.errors) do
      if error_message == case.detail then
        matches = matches + 1
      end
    end
    expect(matches == 1, case.name .. " duplicated an upstream error")
  end
  expect(#state.system_calls == 0, case.name .. " launched a query probe")
end

do
  local runtime, state = fixture({
    parquet_report = function(index)
      if index == 1 then
        return parquet_report({ errors = { "first failure" }, ok = false })
      end
      return parquet_report()
    end,
  })
  expect(not runtime.probe().ok, "failure cache fixture unexpectedly passed")
  expect(runtime.probe().ok, "failed report was cached")
  expect(#state.parquet_calls == 2, "failed report did not rerun")
end

for _, case in ipairs({
  {
    name = "invalid JSON",
    duckdb_result = { code = 0, signal = 0, stderr = "", stdout = "not-json\n" },
    needle = "DuckDB probe returned invalid JSON",
  },
  {
    name = "timeout",
    duckdb_result = { code = 124, signal = 0, stderr = "", stdout = "" },
    needle = "DuckDB probe timed out after 10000 ms",
  },
  {
    name = "version mismatch",
    duckdb_result = {
      code = 0,
      signal = 0,
      stderr = "",
      stdout = vim.json.encode({ path = duckdb_path, version = "1.5.4" }) .. "\n",
    },
    needle = "managed DuckDB 1.5.5 is required",
  },
  {
    name = "outside environment",
    duckdb_result = {
      code = 0,
      signal = 0,
      stderr = "",
      stdout = vim.json.encode({ path = "/outside/duckdb/__init__.py", version = "1.5.5" }) .. "\n",
    },
    realpaths = { ["/outside/duckdb/__init__.py"] = "/outside/duckdb/__init__.py" },
    needle = "managed DuckDB resolves outside the managed environment",
  },
  {
    name = "probe exception",
    duckdb_exception = "DuckDB probe exploded",
    needle = "could not run DuckDB probe",
  },
}) do
  local runtime = fixture(case)
  local report = runtime.probe()
  expect(not report.ok, case.name .. " unexpectedly passed")
  contains(joined_errors(report), case.needle, case.name .. " diagnostic")
end

do
  local runtime, state = fixture({ platform = "Darwin" })
  local report = runtime.probe()
  expect(not report.ok, "non-Linux resolver unexpectedly passed")
  expect(report.platform == "Darwin", "non-Linux platform missing")
  contains(
    joined_errors(report),
    "data queries are supported only on Linux",
    "non-Linux diagnostic"
  )
  expect(state.exepath_calls == 0, "non-Linux resolver looked up Bubblewrap")
  for _, call in ipairs(state.system_calls) do
    expect(call.command[1] ~= "/usr/bin/bwrap", "non-Linux resolver launched Bubblewrap")
  end
end

do
  local runtime = fixture({ path_candidate = "relative/bwrap" })
  local report = runtime.probe()
  expect(report.ok, joined_errors(report))
  expect(report.sandbox.path == "/usr/bin/bwrap", "unsafe PATH candidate displaced fallback")
end

do
  local runtime, state = fixture({
    executables = { ["/usr/bin/bwrap"] = false, ["/bin/bwrap"] = true },
    metadata = { ["/bin/bwrap"] = { mode = 33261, type = "file", uid = 0 } },
    path_candidate = "",
    realpaths = { ["/bin/bwrap"] = "/bin/bwrap" },
  })
  local report = runtime.probe()
  expect(report.ok, joined_errors(report))
  expect(report.sandbox.path == "/bin/bwrap", "/bin Bubblewrap fallback was not selected")
  expect(
    vim.tbl_contains(state.executable_calls, "/usr/bin/bwrap"),
    "/usr fallback was not checked"
  )
end

do
  local runtime, state = fixture({
    path_candidate = "/opt/bin/bwrap",
    realpaths = { ["/opt/bin/bwrap"] = "/usr/bin/bwrap" },
  })
  local report = runtime.probe()
  expect(report.ok, joined_errors(report))
  local version_calls = 0
  for _, call in ipairs(state.system_calls) do
    if call.command[2] == "--version" then
      version_calls = version_calls + 1
    end
  end
  expect(version_calls == 1, "canonical Bubblewrap candidates were probed more than once")
end

for _, case in ipairs({
  {
    name = "not executable",
    executables = { ["/usr/bin/bwrap"] = false },
    needle = "unavailable or not executable",
  },
  {
    name = "not a file",
    metadata = { ["/usr/bin/bwrap"] = { mode = 16877, type = "directory", uid = 0 } },
    needle = "must be a regular file",
  },
  {
    name = "not root owned",
    metadata = { ["/usr/bin/bwrap"] = { mode = 33261, type = "file", uid = 1000 } },
    needle = "must be owned by root",
  },
  {
    name = "group writable",
    metadata = { ["/usr/bin/bwrap"] = { mode = 33277, type = "file", uid = 0 } },
    needle = "must not be group-writable or world-writable",
  },
  {
    name = "world writable",
    metadata = { ["/usr/bin/bwrap"] = { mode = 33263, type = "file", uid = 0 } },
    needle = "must not be group-writable or world-writable",
  },
  {
    name = "bad version",
    version_results = {
      ["/usr/bin/bwrap"] = { code = 0, signal = 0, stderr = "", stdout = "bwrap 0.11.2\n" },
    },
    needle = "returned an invalid version",
  },
  {
    name = "namespace failure",
    namespace_results = {
      ["/usr/bin/bwrap"] = { code = 1, signal = 0, stderr = "namespace denied", stdout = "" },
    },
    needle = "Bubblewrap namespace probe failed",
  },
  {
    name = "namespace timeout",
    namespace_results = {
      ["/usr/bin/bwrap"] = { code = 124, signal = 0, stderr = "", stdout = "" },
    },
    needle = "Bubblewrap namespace probe timed out after 10000 ms",
  },
  {
    name = "namespace output mismatch",
    namespace_results = {
      ["/usr/bin/bwrap"] = { code = 0, signal = 0, stderr = "", stdout = "wrong\n" },
    },
    needle = "Bubblewrap namespace probe returned unexpected output",
  },
}) do
  local runtime = fixture(case)
  local report = runtime.probe()
  expect(not report.ok, case.name .. " unexpectedly passed")
  contains(joined_errors(report), case.needle, case.name .. " diagnostic")
end

do
  local runtime, state = fixture()
  expect(runtime.probe().ok, "sandbox argv fixture failed")
  local namespace_call
  for _, call in ipairs(state.system_calls) do
    if call.command[1] == "/usr/bin/bwrap" and call.command[2] == "--ro-bind" then
      namespace_call = call
    end
  end
  expect(namespace_call ~= nil, "namespace probe was not launched")
  eq(vim.list_slice(namespace_call.command, 1, 39), {
    "/usr/bin/bwrap",
    "--ro-bind",
    "/",
    "/",
    "--proc",
    "/proc",
    "--dev",
    "/dev",
    "--tmpfs",
    "/tmp",
    "--unshare-all",
    "--unshare-user",
    "--disable-userns",
    "--cap-drop",
    "ALL",
    "--die-with-parent",
    "--new-session",
    "--clearenv",
    "--setenv",
    "HOME",
    "/nonexistent",
    "--setenv",
    "PATH",
    "/usr/bin:/bin",
    "--setenv",
    "LANG",
    "C.UTF-8",
    "--setenv",
    "LC_ALL",
    "C.UTF-8",
    "--setenv",
    "PYTHONNOUSERSITE",
    "1",
    "--setenv",
    "PYTHONDONTWRITEBYTECODE",
    "1",
    "--setenv",
    "PYTHONUTF8",
    "1",
  }, "namespace hardening prefix")
  local script = namespace_call.command[#namespace_call.command]
  eq(vim.list_slice(namespace_call.command, 40), {
    "--chdir",
    "/",
    python,
    "-I",
    "-B",
    "-c",
    script,
  }, "namespace probe suffix")
  for _, name in ipairs({
    "VIRTUAL_ENV",
    "CONDA_PREFIX",
    "PYTHONPATH",
    "AWS_ACCESS_KEY_ID",
    "GOOGLE_APPLICATION_CREDENTIALS",
    "HTTP_PROXY",
  }) do
    contains(script, name, "namespace probe does not reject inherited " .. name)
  end
end

for _, case in ipairs({
  {
    name = "not a file source",
    raw_module_source = "=data_query.tool",
    needle = "local absolute file",
  },
  {
    name = "relative source",
    raw_module_source = "@relative/tool.lua",
    needle = "local absolute file",
  },
  {
    name = "unexpected layout",
    raw_module_source = "@/config/nvim/lua/query/tool.lua",
    needle = "expected nvim/lua/data_query/tool.lua layout",
  },
  {
    name = "runner escape",
    realpaths = { [runner] = "/outside/data-query-runner.py" },
    metadata = { ["/outside/data-query-runner.py"] = { mode = 33188, type = "file", uid = 1000 } },
    readable = { [runner] = false, ["/outside/data-query-runner.py"] = true },
    needle = "runner resolves outside the Neovim root",
  },
  {
    name = "runner directory",
    metadata = { [runner] = { mode = 16877, type = "directory", uid = 1000 } },
    needle = "runner must be a regular file",
  },
  {
    name = "runner unreadable",
    readable = { [runner] = false },
    needle = "runner is not readable",
  },
}) do
  local runtime = fixture(case)
  local report = runtime.probe()
  expect(not report.ok, case.name .. " unexpectedly passed")
  contains(joined_errors(report), case.needle, case.name .. " diagnostic")
end

-- File-level Home Manager deployment leaves the config directory real while
-- individual modules and runners resolve into a shared immutable source tree.
do
  local parent =
    assert(vim.env.DOTFILES_TEST_HOME or vim.env.TMPDIR, "private test parent required")
  local root = vim.fs.joinpath(parent, "runner-trust")
  expect(vim.uv.fs_lstat(root) == nil, "runner fixture already exists")
  expect(vim.fn.mkdir(root, "p", 448) == 1, "runner fixture creation")
  local config = root .. "/config/nvim"
  local tree = root .. "/source/nvim"
  local other = root .. "/other/nvim"
  for _, base in ipairs({ config, tree, other }) do
    vim.fn.mkdir(base .. "/lua/data_query", "p", 448)
    vim.fn.mkdir(base .. "/scripts", "p", 448)
  end
  local lexical_module = config .. "/lua/data_query/tool.lua"
  local canonical_module = tree .. "/lua/data_query/tool.lua"
  local lexical_runner = config .. "/scripts/data-query-runner.py"
  local canonical_runner = tree .. "/scripts/data-query-runner.py"
  expect(
    vim.fn.writefile(vim.fn.readfile(nvim_root .. "/lua/data_query/tool.lua"), canonical_module)
      == 0,
    "module fixture"
  )
  expect(vim.fn.writefile({ "# fixture" }, canonical_runner) == 0, "runner fixture")
  expect(vim.uv.fs_symlink(canonical_module, lexical_module), "module link")
  expect(vim.uv.fs_symlink(canonical_runner, lexical_runner), "runner link")
  local runtime = fixture({ module_path = lexical_module, fs_root = root })
  local report = runtime.probe()
  expect(report.ok, "same-tree file links must succeed: " .. joined_errors(report))
  expect(report.runner.path == canonical_runner, "runner must be canonical")

  expect(vim.uv.fs_unlink(lexical_runner), "remove runner link")
  local foreign_runner = other .. "/scripts/data-query-runner.py"
  vim.fn.writefile({ "# foreign" }, foreign_runner)
  expect(vim.uv.fs_symlink(foreign_runner, lexical_runner), "foreign runner link")
  report = fixture({ module_path = lexical_module, fs_root = root }).probe()
  contains(
    joined_errors(report),
    "runner resolves outside the Neovim root",
    "foreign tree rejection"
  )

  expect(vim.uv.fs_unlink(lexical_module), "remove module link")
  local wrong_module = tree .. "/wrong.lua"
  vim.fn.writefile({ "return {}" }, wrong_module)
  expect(vim.uv.fs_symlink(wrong_module, lexical_module), "wrong layout link")
  report = fixture({ module_path = lexical_module, fs_root = root }).probe()
  contains(
    joined_errors(report),
    "expected nvim/lua/data_query/tool.lua layout",
    "canonical layout rejection"
  )
  expect(vim.uv.fs_unlink(lexical_module), "remove wrong layout link")
  expect(vim.uv.fs_symlink(canonical_module, lexical_module), "restore module link")
  expect(vim.uv.fs_unlink(lexical_runner), "remove foreign runner link")
  expect(vim.uv.fs_symlink(canonical_runner, lexical_runner), "restore runner link")

  expect(vim.uv.fs_chmod(canonical_runner, 0), "make runner unreadable")
  report = fixture({ module_path = lexical_module, fs_root = root }).probe()
  contains(joined_errors(report), "runner is not readable", "real unreadable file rejection")
  expect(vim.uv.fs_chmod(canonical_runner, 384), "restore runner permissions")
  expect(vim.uv.fs_unlink(canonical_runner), "remove runner file")
  vim.fn.mkdir(canonical_runner, "p", 448)
  report = fixture({ module_path = lexical_module, fs_root = root }).probe()
  contains(joined_errors(report), "runner must be a regular file", "real directory rejection")
end

local default_request = {
  result = result,
  source = source,
  visible_name = "sales.csv",
  workspace = workspace,
}

local expected_command = {
  "/usr/bin/bwrap",
  "--ro-bind",
  "/",
  "/",
  "--proc",
  "/proc",
  "--dev",
  "/dev",
  "--tmpfs",
  "/tmp",
  "--unshare-all",
  "--unshare-user",
  "--disable-userns",
  "--cap-drop",
  "ALL",
  "--die-with-parent",
  "--new-session",
  "--clearenv",
  "--setenv",
  "HOME",
  "/nonexistent",
  "--setenv",
  "PATH",
  "/usr/bin:/bin",
  "--setenv",
  "LANG",
  "C.UTF-8",
  "--setenv",
  "LC_ALL",
  "C.UTF-8",
  "--setenv",
  "PYTHONNOUSERSITE",
  "1",
  "--setenv",
  "PYTHONDONTWRITEBYTECODE",
  "1",
  "--setenv",
  "PYTHONUTF8",
  "1",
  "--dir",
  "/tmp/dotfiles-data-query-source",
  "--bind",
  workspace,
  workspace,
  "--ro-bind",
  source,
  "/tmp/dotfiles-data-query-source/sales.csv",
  "--chdir",
  "/tmp/dotfiles-data-query-source",
  python,
  "-I",
  "-B",
  runner,
  "--source",
  "/tmp/dotfiles-data-query-source/sales.csv",
  "--workspace",
  workspace,
  "--result",
  result,
}

do
  local runtime = fixture()
  local argv, virtual_source, command_error = runtime.command(vim.deepcopy(default_request))
  expect(command_error == nil, "ready command returned an error")
  eq(argv, expected_command, "Bubblewrap query argument vector")
  expect(virtual_source == "/tmp/dotfiles-data-query-source/sales.csv", "virtual source")
  for _, argument in ipairs(argv) do
    expect(not argument:find("SELECT", 1, true), "SQL leaked into the argument vector")
  end
  local ready = runtime.runtime()
  expect(ready and ready.ok, "runtime did not return the ready report")
  ready.ok = false
  expect(runtime.runtime().ok, "runtime report was not defensively copied")
end

local function assert_command_failure(case, request, needle)
  local runtime = fixture(case)
  local argv, virtual_source, command_error = runtime.command(request)
  expect(argv == nil and virtual_source == nil, "invalid command returned an argument vector")
  expect(type(command_error) == "string", "invalid command returned no diagnostic")
  contains(command_error, needle, "command failure diagnostic")
end

for _, invalid in ipairs({
  { field = "source", value = "relative.csv", needle = "source must be a safe absolute path" },
  { field = "source", value = "/data/bad\n.csv", needle = "source must be a safe absolute path" },
  {
    field = "workspace",
    value = "relative-run",
    needle = "workspace must be a safe absolute path",
  },
  { field = "result", value = "relative.parquet", needle = "result must be a safe absolute path" },
  { field = "visible_name", value = "../sales.csv", needle = "visible name must be a basename" },
  {
    field = "visible_name",
    value = "bad\t.csv",
    needle = "visible name contains control characters",
  },
  {
    field = "visible_name",
    value = "sales.json",
    needle = "visible name must end in .parquet, .csv, or .tsv",
  },
  {
    field = "visible_name",
    value = "sales.CSV",
    needle = "visible name must end in .parquet, .csv, or .tsv",
  },
}) do
  local request = vim.deepcopy(default_request)
  request[invalid.field] = invalid.value
  assert_command_failure({}, request, invalid.needle)
end

assert_command_failure(
  { realpaths = { [source] = "/data/retargeted.csv" } },
  vim.deepcopy(default_request),
  "source no longer resolves to its canonical path"
)
assert_command_failure(
  { metadata = { [source] = { mode = 16877, type = "directory", uid = 1000 } } },
  vim.deepcopy(default_request),
  "source must be a regular file"
)
assert_command_failure(
  { readable = { [source] = false } },
  vim.deepcopy(default_request),
  "source is not readable"
)
assert_command_failure(
  { realpaths = { [workspace] = "/cache/other" } },
  vim.deepcopy(default_request),
  "workspace must not be a symlink"
)
assert_command_failure(
  { metadata = { [workspace] = { mode = 16877, type = "directory", uid = 1000 } } },
  vim.deepcopy(default_request),
  "workspace must have mode 0700"
)
assert_command_failure(
  { metadata = { [workspace] = { mode = 16832, type = "directory", uid = 2000 } } },
  vim.deepcopy(default_request),
  "workspace must be owned by the current user"
)
assert_command_failure(
  { metadata = { [spill] = { mode = 41471, type = "link", uid = 1000 } } },
  vim.deepcopy(default_request),
  "spill must be a non-symlink directory"
)
assert_command_failure(
  { metadata = { [spill] = { mode = 16877, type = "directory", uid = 1000 } } },
  vim.deepcopy(default_request),
  "spill must have mode 0700"
)
assert_command_failure(
  { metadata = { [spill] = { mode = 16832, type = "directory", uid = 2000 } } },
  vim.deepcopy(default_request),
  "spill must be owned by the current user"
)

do
  local request = vim.deepcopy(default_request)
  request.result = "/cache/elsewhere.parquet"
  assert_command_failure({}, request, "result must be a direct child of the workspace")
end

do
  local request = vim.deepcopy(default_request)
  request.result = workspace .. "/nested/result.parquet"
  assert_command_failure({}, request, "result must be a direct child of the workspace")
end

assert_command_failure(
  { metadata = { [result] = { mode = 33152, type = "file", uid = 1000 } } },
  vim.deepcopy(default_request),
  "result must not already exist"
)
assert_command_failure(
  { lstat_errors = { [result] = "EACCES: permission denied" } },
  vim.deepcopy(default_request),
  "could not prove that the result is absent"
)
assert_command_failure(
  { result_realpath = result },
  vim.deepcopy(default_request),
  "result path unexpectedly resolves"
)
assert_command_failure(
  { realpath_errors = { [result] = "EACCES: permission denied" } },
  vim.deepcopy(default_request),
  "result realpath is ambiguous"
)

do
  local runtime = fixture({
    parquet_report = parquet_report({ errors = { "DuckDB missing" }, ok = false }),
  })
  local report, runtime_error = runtime.runtime()
  expect(report == nil, "failed runtime returned a report")
  contains(runtime_error, "DuckDB missing", "runtime diagnostic detail")
  contains(runtime_error, "run the dotfiles bootstrap", "runtime bootstrap action")
  local argv, virtual_source, command_error = runtime.command(vim.deepcopy(default_request))
  expect(argv == nil and virtual_source == nil, "failed runtime built a command")
  contains(command_error, "run the dotfiles bootstrap", "command bootstrap action")
end

print("data query tool assertions: ok")
