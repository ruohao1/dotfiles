local M = {}

local versions = {
  duckdb = "1.5.5",
  pyarrow = "25.0.0",
  uv = "0.11.6",
  visidata = "3.4",
}
local timeout = 10000
local virtual_directory = "/tmp/dotfiles-data-query-source"
local success_marker = "data-query-sandbox-ok"
local module_source = debug.getinfo(1, "S").source

local duckdb_probe = table.concat({
  "import duckdb,json",
  "print(json.dumps({'path': duckdb.__file__, 'version': duckdb.__version__}, sort_keys=True))",
}, "; ")

local namespace_probe = table.concat({
  "import os,tempfile",
  "forbidden=('VIRTUAL_ENV','CONDA_PREFIX','CONDA_DEFAULT_ENV','PYTHONPATH','PYTHONHOME','AWS_ACCESS_KEY_ID','AWS_SECRET_ACCESS_KEY','AWS_SESSION_TOKEN','GOOGLE_APPLICATION_CREDENTIALS','AZURE_CLIENT_ID','AZURE_CLIENT_SECRET','HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','NO_PROXY','http_proxy','https_proxy','all_proxy','no_proxy','DUCKDB_EXTENSION_REPOSITORY')",
  "assert not (set(forbidden) & set(os.environ))",
  "fd,path=tempfile.mkstemp(dir='/tmp')",
  "os.close(fd)",
  "os.unlink(path)",
  "print('data-query-sandbox-ok')",
}, "; ")

local resolver_environment = {
  PYTHONDONTWRITEBYTECODE = "1",
  PYTHONNOUSERSITE = "1",
  UV_OFFLINE = "1",
}

local function trimmed_text(value)
  if type(value) ~= "string" then
    return nil
  end
  value = value:match("^%s*(.-)%s*$")
  return value ~= "" and value or nil
end

local function exact_text(value)
  return type(value) == "string" and value ~= "" and value:find("%c") == nil and value or nil
end

local function is_safe_absolute(path, allow_root)
  return type(path) == "string"
    and path ~= ""
    and path:find("%c") == nil
    and path:sub(1, 1) == "/"
    and (allow_root or path ~= "/")
end

local function is_beneath(path, parent)
  return type(path) == "string"
    and type(parent) == "string"
    and path:sub(1, #parent + 1) == parent .. "/"
end

local function version_at_least(actual, required)
  local actual_parts = type(actual) == "string" and { actual:match("^(%d+)%.(%d+)%.(%d+)$") } or {}
  local required_parts = { required:match("^(%d+)%.(%d+)%.(%d+)$") }
  if #actual_parts ~= 3 or #required_parts ~= 3 then
    return false
  end
  for index = 1, 3 do
    local left = tonumber(actual_parts[index])
    local right = tonumber(required_parts[index])
    if left ~= right then
      return left > right
    end
  end
  return true
end

local function append_unique(errors, message)
  if type(message) ~= "string" or message == "" then
    return
  end
  for _, existing in ipairs(errors) do
    if existing == message then
      return
    end
  end
  errors[#errors + 1] = message
end

local function append_errors(errors, additions)
  if type(additions) ~= "table" then
    return
  end
  for _, message in ipairs(additions) do
    append_unique(errors, message)
  end
end

local function permission_bits(mode)
  if type(mode) ~= "number" or mode < 0 then
    return nil
  end
  return mode % 512
end

local function has_permission(mode, permission)
  local bits = permission_bits(mode)
  return bits ~= nil and math.floor(bits / permission) % 2 == 1
end

local function dirname(path)
  if type(path) ~= "string" then
    return nil
  end
  local parent = path:match("^(.*)/[^/]+$")
  return parent == "" and "/" or parent
end

local function hardening_prefix(bwrap)
  return {
    bwrap,
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
  }
end

local function new(deps)
  local cached

  local function normalize_absolute(path, allow_root)
    if not is_safe_absolute(path, allow_root) then
      return nil, "unsafe path"
    end
    local ok, normalized = pcall(deps.normalize, path, { expand_env = false })
    if not ok then
      return nil, tostring(normalized)
    end
    if not is_safe_absolute(normalized, allow_root) then
      return nil, "normalization returned an unsafe path"
    end
    return normalized
  end

  local function canonical_absolute(path, allow_root)
    local normalized, normalize_error = normalize_absolute(path, allow_root)
    if not normalized then
      return nil, normalize_error
    end
    local ok, canonical, detail = pcall(deps.realpath, normalized)
    if not ok then
      return nil, tostring(canonical)
    end
    if canonical == nil then
      return nil, tostring(detail or "realpath unavailable")
    end
    local safe, safe_error = normalize_absolute(canonical, allow_root)
    if not safe then
      return nil, safe_error
    end
    return safe
  end

  local function lstat(path)
    local ok, value, detail = pcall(deps.lstat, path)
    if not ok then
      return nil, tostring(value), false
    end
    return value, detail, true
  end

  local function readable(path)
    local ok, value = pcall(deps.readable, path)
    return ok and value == 1
  end

  local function executable(path)
    local ok, value = pcall(deps.executable, path)
    return ok and value == 1
  end

  local function run_process(command, label)
    local ok, result = pcall(deps.system, command, {
      clear_env = true,
      env = deps.deepcopy(resolver_environment),
      text = true,
    }, timeout)
    if not ok then
      return nil, "could not run " .. label .. ": " .. tostring(result)
    end
    if type(result) ~= "table" then
      return nil, label .. " returned an invalid process result"
    end
    if result.code == 124 then
      return nil, label .. " timed out after " .. timeout .. " ms"
    end
    if result.signal and result.signal ~= 0 then
      return nil, label .. " failed with signal " .. tostring(result.signal)
    end
    if result.code ~= 0 then
      local message = label .. " failed with exit " .. tostring(result.code)
      local detail = trimmed_text(result.stderr) or trimmed_text(result.stdout)
      if detail then
        message = message .. ": " .. detail
      end
      return nil, message
    end
    return result
  end

  local function copy_parquet_authority(report, options)
    local ok, upstream = pcall(deps.parquet_probe, options)
    if not ok then
      append_unique(report.errors, "Parquet resolver failed: " .. tostring(upstream))
      return nil
    end
    if type(upstream) ~= "table" then
      append_unique(report.errors, "Parquet resolver returned an invalid report")
      return nil
    end

    report.uv = type(upstream.uv) == "table" and deps.deepcopy(upstream.uv) or upstream.uv
    report.environment = upstream.environment
    report.python = upstream.python
    report.viewer = type(upstream.viewer) == "table" and deps.deepcopy(upstream.viewer)
      or upstream.viewer
    report.pyarrow = type(upstream.pyarrow) == "table" and deps.deepcopy(upstream.pyarrow)
      or upstream.pyarrow

    if upstream.ok ~= true then
      append_errors(report.errors, upstream.errors)
      append_unique(report.errors, "managed Parquet runtime is not ready")
      return nil
    end

    local complete = type(report.uv) == "table"
      and report.uv.ok == true
      and is_safe_absolute(report.uv.path, true)
      and version_at_least(report.uv.version, versions.uv)
      and type(report.viewer) == "table"
      and report.viewer.ok == true
      and is_safe_absolute(report.viewer.path, false)
      and report.viewer.version == versions.visidata
      and type(report.pyarrow) == "table"
      and report.pyarrow.ok == true
      and is_safe_absolute(report.pyarrow.path, false)
      and report.pyarrow.version == versions.pyarrow
      and is_safe_absolute(report.environment, false)
      and is_safe_absolute(report.python, false)
      and type(upstream.errors) == "table"
      and #upstream.errors == 0
    if not complete then
      append_unique(report.errors, "Parquet resolver report is incomplete or inconsistent")
      return nil
    end

    local canonical_environment, environment_error = canonical_absolute(report.environment, false)
    if not canonical_environment then
      append_unique(
        report.errors,
        "could not resolve canonical managed environment: " .. tostring(environment_error)
      )
      return nil
    end
    if canonical_environment ~= report.environment then
      append_unique(report.errors, "Parquet resolver environment is not canonical")
      return nil
    end
    return canonical_environment
  end

  local function probe_duckdb(report, canonical_environment)
    local result, process_error = run_process({
      report.python,
      "-I",
      "-B",
      "-c",
      duckdb_probe,
    }, "DuckDB probe")
    if not result then
      append_unique(report.errors, process_error)
      report.duckdb = { ok = false }
      return
    end

    local decoded_ok, decoded = pcall(deps.json_decode, result.stdout)
    if not decoded_ok or type(decoded) ~= "table" then
      append_unique(report.errors, "DuckDB probe returned invalid JSON")
      report.duckdb = { ok = false }
      return
    end

    local version = exact_text(decoded.version)
    local package_path = exact_text(decoded.path)
    local canonical_path, path_error
    if package_path then
      canonical_path, path_error = canonical_absolute(package_path, false)
    end
    report.duckdb = {
      ok = false,
      path = canonical_path or package_path,
      version = version,
    }
    local package_is_safe = false
    if not package_path then
      append_unique(report.errors, "DuckDB probe did not report a safe import path")
    elseif not canonical_path then
      append_unique(
        report.errors,
        "could not resolve canonical managed DuckDB: " .. tostring(path_error)
      )
    elseif not is_beneath(canonical_path, canonical_environment) then
      append_unique(report.errors, "managed DuckDB resolves outside the managed environment")
    else
      local metadata, metadata_error = lstat(canonical_path)
      if not metadata then
        append_unique(
          report.errors,
          "could not inspect canonical managed DuckDB: " .. tostring(metadata_error)
        )
      elseif metadata.type ~= "file" then
        append_unique(report.errors, "managed DuckDB import path must be a regular file")
      elseif not readable(canonical_path) then
        append_unique(report.errors, "managed DuckDB import path is not readable")
      else
        package_is_safe = true
      end
    end
    if version ~= versions.duckdb then
      append_unique(report.errors, "managed DuckDB 1.5.5 is required")
    end
    report.duckdb.ok = version == versions.duckdb
      and canonical_path ~= nil
      and is_beneath(canonical_path, canonical_environment)
      and package_is_safe
  end

  local function parse_bwrap_version(output)
    output = trimmed_text(output)
    return output and output:match("^bubblewrap (%d+%.%d+%.%d+)$") or nil
  end

  local function canonical_bwrap_candidate(path)
    if not is_safe_absolute(path, true) then
      return nil, "Bubblewrap candidate must be a safe absolute path"
    end
    local canonical, canonical_error = canonical_absolute(path, true)
    if not canonical then
      return nil, "could not resolve canonical Bubblewrap candidate: " .. tostring(canonical_error)
    end
    return canonical
  end

  local function validate_bwrap_file(canonical)
    if not executable(canonical) then
      return "Bubblewrap executable is unavailable or not executable"
    end
    local metadata, metadata_error = lstat(canonical)
    if not metadata then
      return "could not inspect Bubblewrap executable: " .. tostring(metadata_error)
    end
    if metadata.type ~= "file" then
      return "Bubblewrap executable must be a regular file"
    end
    if metadata.uid ~= 0 then
      return "Bubblewrap executable must be owned by root"
    end
    if type(metadata.mode) ~= "number" then
      return "Bubblewrap executable has invalid permission metadata"
    end
    if has_permission(metadata.mode, 16) or has_permission(metadata.mode, 2) then
      return "Bubblewrap executable must not be group-writable or world-writable"
    end
  end

  local function namespace_command(bwrap, python)
    local command = hardening_prefix(bwrap)
    vim.list_extend(command, {
      "--chdir",
      "/",
      python,
      "-I",
      "-B",
      "-c",
      namespace_probe,
    })
    return command
  end

  local function probe_sandbox(report)
    if report.platform ~= "Linux" then
      report.sandbox = { ok = false }
      append_unique(
        report.errors,
        "data queries are supported only on Linux (detected " .. tostring(report.platform) .. ")"
      )
      return
    end

    local candidates = {}
    local lookup_ok, path_candidate = pcall(deps.exepath, "bwrap")
    if lookup_ok then
      candidates[#candidates + 1] = path_candidate
    else
      candidates[#candidates + 1] = nil
    end
    candidates[#candidates + 1] = "/usr/bin/bwrap"
    candidates[#candidates + 1] = "/bin/bwrap"

    local rejected = {}
    if not lookup_ok then
      append_unique(
        rejected,
        "could not resolve Bubblewrap from PATH: " .. tostring(path_candidate)
      )
    end
    local seen = {}
    local last_state
    for _, candidate in ipairs(candidates) do
      if type(candidate) == "string" and candidate ~= "" then
        local canonical, candidate_error = canonical_bwrap_candidate(candidate)
        local duplicate = canonical ~= nil and seen[canonical] == true
        if canonical and not duplicate then
          seen[canonical] = true
        end
        if duplicate then
          candidate_error = nil
        elseif canonical then
          candidate_error = validate_bwrap_file(canonical)
        end
        if canonical and not duplicate and not candidate_error then
          local version_result, version_error =
            run_process({ canonical, "--version" }, "Bubblewrap version probe")
          local version = version_result and parse_bwrap_version(version_result.stdout) or nil
          last_state = { ok = false, path = canonical, version = version }
          if not version_result then
            append_unique(rejected, version_error)
          elseif not version then
            append_unique(rejected, "Bubblewrap version probe returned an invalid version")
          else
            local probe_result, probe_error =
              run_process(namespace_command(canonical, report.python), "Bubblewrap namespace probe")
            if not probe_result then
              append_unique(rejected, probe_error)
            elseif
              probe_result.stdout ~= success_marker .. "\n"
              or trimmed_text(probe_result.stderr) ~= nil
            then
              append_unique(rejected, "Bubblewrap namespace probe returned unexpected output")
            else
              report.sandbox = {
                ok = true,
                path = canonical,
                probe = success_marker,
                version = version,
              }
              return
            end
          end
        elseif candidate_error then
          append_unique(rejected, candidate_error)
        end
      elseif candidate ~= nil then
        append_unique(rejected, "Bubblewrap candidate must be a safe absolute path")
      end
    end

    report.sandbox = last_state or { ok = false }
    if #rejected == 0 then
      rejected[1] = "Bubblewrap is unavailable"
    end
    append_errors(report.errors, rejected)
  end

  local function probe_platform(report)
    local ok, platform = pcall(deps.platform)
    if not ok then
      report.platform = "unknown"
      append_unique(report.errors, "could not detect the current platform: " .. tostring(platform))
      return
    end
    platform = exact_text(platform)
    if not platform then
      report.platform = "unknown"
      append_unique(report.errors, "current platform is unavailable")
      return
    end
    report.platform = platform
  end

  local function probe_runner(report)
    local source_ok, source = pcall(deps.module_source)
    if not source_ok then
      report.runner = { ok = false }
      append_unique(report.errors, "could not resolve data-query tool source: " .. tostring(source))
      return
    end
    if type(source) ~= "string" or source:sub(1, 1) ~= "@" then
      report.runner = { ok = false }
      append_unique(report.errors, "data-query tool source must be a local absolute file")
      return
    end

    local lexical_module, module_error = normalize_absolute(source:sub(2), false)
    if not lexical_module then
      report.runner = { ok = false }
      append_unique(
        report.errors,
        "data-query tool source must be a local absolute file: " .. tostring(module_error)
      )
      return
    end

    local suffix = "/lua/data_query/tool.lua"
    if lexical_module:sub(-#suffix) ~= suffix then
      report.runner = { ok = false }
      append_unique(
        report.errors,
        "data-query tool source does not match the expected nvim/lua/data_query/tool.lua layout"
      )
      return
    end
    local lexical_root = lexical_module:sub(1, #lexical_module - #suffix)

    -- File-level deployment leaves lexical_root writable and real. Trust the
    -- canonical module's complete source tree, never a store-prefix heuristic.
    local canonical_module, canonical_module_error = canonical_absolute(lexical_module, false)
    if not canonical_module then
      report.runner = { ok = false }
      append_unique(
        report.errors,
        "could not resolve canonical data-query tool source: " .. tostring(canonical_module_error)
      )
      return
    end
    if canonical_module:sub(-#suffix) ~= suffix then
      report.runner = { ok = false }
      append_unique(
        report.errors,
        "data-query tool source does not match the expected nvim/lua/data_query/tool.lua layout"
      )
      return
    end
    local source_root = canonical_module:sub(1, #canonical_module - #suffix)
    local canonical_root, root_error = canonical_absolute(source_root, false)
    if not canonical_root then
      report.runner = { ok = false }
      append_unique(
        report.errors,
        "could not resolve canonical Neovim root: " .. tostring(root_error)
      )
      return
    end

    local join_ok, lexical_runner =
      pcall(deps.joinpath, lexical_root, "scripts", "data-query-runner.py")
    if not join_ok then
      report.runner = { ok = false }
      append_unique(
        report.errors,
        "could not derive data-query runner path: " .. tostring(lexical_runner)
      )
      return
    end
    local canonical_runner, runner_error = canonical_absolute(lexical_runner, false)
    report.runner = { ok = false, path = canonical_runner or lexical_runner }
    if not canonical_runner then
      append_unique(
        report.errors,
        "could not resolve data-query runner: " .. tostring(runner_error)
      )
      return
    end
    if not is_beneath(canonical_runner, canonical_root) then
      append_unique(report.errors, "data-query runner resolves outside the Neovim root")
      return
    end

    local metadata, metadata_error = lstat(canonical_runner)
    if not metadata then
      append_unique(
        report.errors,
        "could not inspect data-query runner: " .. tostring(metadata_error)
      )
      return
    end
    if metadata.type ~= "file" then
      append_unique(report.errors, "data-query runner must be a regular file")
      return
    end
    if not readable(canonical_runner) then
      append_unique(report.errors, "data-query runner is not readable")
      return
    end
    report.runner.ok = true
  end

  local function probe(options)
    options = type(options) == "table" and options or {}
    if options.refresh == true then
      cached = nil
    end
    if cached then
      return deps.deepcopy(cached)
    end

    local report = {
      errors = {},
      expected = deps.deepcopy(versions),
      ok = false,
    }
    local parquet_options = options.refresh == true and { refresh = true } or {}
    local canonical_environment = copy_parquet_authority(report, parquet_options)
    if not canonical_environment then
      return report
    end

    probe_duckdb(report, canonical_environment)
    probe_platform(report)
    probe_sandbox(report)
    probe_runner(report)
    report.ok = #report.errors == 0
      and type(report.duckdb) == "table"
      and report.duckdb.ok == true
      and type(report.sandbox) == "table"
      and report.sandbox.ok == true
      and type(report.runner) == "table"
      and report.runner.ok == true
    if report.ok then
      cached = deps.deepcopy(report)
      return deps.deepcopy(cached)
    end
    return report
  end

  local function runtime()
    local report = probe()
    if report.ok then
      return report
    end
    local detail = #report.errors > 0 and table.concat(report.errors, "; ")
      or "query runtime readiness could not be established"
    return nil,
      "data query runtime is unavailable: "
        .. detail
        .. "; run the dotfiles bootstrap, then run :DataQueryHealth"
  end

  local function validate_request(request)
    if type(request) ~= "table" then
      return nil, "data query command request must be a table"
    end

    local normalized_source = normalize_absolute(request.source, false)
    if not normalized_source then
      return nil, "source must be a safe absolute path"
    end
    if normalized_source ~= request.source then
      return nil, "source must be normalized"
    end
    local canonical_source = canonical_absolute(normalized_source, false)
    if not canonical_source or canonical_source ~= normalized_source then
      return nil, "source no longer resolves to its canonical path"
    end
    local source_metadata, source_error = lstat(normalized_source)
    if not source_metadata then
      return nil, "could not inspect source: " .. tostring(source_error)
    end
    if source_metadata.type ~= "file" then
      return nil, "source must be a regular file"
    end
    if not readable(normalized_source) then
      return nil, "source is not readable"
    end

    local visible_name = exact_text(request.visible_name)
    if not visible_name then
      if type(request.visible_name) == "string" and request.visible_name:find("%c") then
        return nil, "visible name contains control characters"
      end
      return nil, "visible name must be a non-empty basename"
    end
    if visible_name == "." or visible_name == ".." or visible_name:find("/", 1, true) then
      return nil, "visible name must be a basename"
    end
    local extension = visible_name:match("(%.[^.]+)$")
    if extension ~= ".parquet" and extension ~= ".csv" and extension ~= ".tsv" then
      return nil, "visible name must end in .parquet, .csv, or .tsv"
    end

    local normalized_workspace = normalize_absolute(request.workspace, false)
    if not normalized_workspace then
      return nil, "workspace must be a safe absolute path"
    end
    if normalized_workspace ~= request.workspace then
      return nil, "workspace must be normalized"
    end
    local workspace_metadata, workspace_error = lstat(normalized_workspace)
    if not workspace_metadata then
      return nil, "could not inspect workspace: " .. tostring(workspace_error)
    end
    if workspace_metadata.type ~= "directory" then
      return nil, "workspace must be a non-symlink directory"
    end
    local canonical_workspace = canonical_absolute(normalized_workspace, false)
    if not canonical_workspace or canonical_workspace ~= normalized_workspace then
      return nil, "workspace must not be a symlink"
    end

    local uid_ok, current_uid = pcall(deps.uid)
    if not uid_ok or type(current_uid) ~= "number" then
      return nil, "could not determine the current user"
    end
    if workspace_metadata.uid ~= current_uid then
      return nil, "workspace must be owned by the current user"
    end
    if permission_bits(workspace_metadata.mode) ~= 448 then
      return nil, "workspace must have mode 0700"
    end

    local join_ok, spill_path = pcall(deps.joinpath, normalized_workspace, "spill")
    if not join_ok or not is_safe_absolute(spill_path, false) then
      return nil, "could not derive the private spill path"
    end
    local spill_metadata, spill_error = lstat(spill_path)
    if not spill_metadata then
      return nil, "could not inspect spill: " .. tostring(spill_error)
    end
    if spill_metadata.type ~= "directory" then
      return nil, "spill must be a non-symlink directory"
    end
    local canonical_spill = canonical_absolute(spill_path, false)
    if not canonical_spill or canonical_spill ~= spill_path then
      return nil, "spill must be a non-symlink directory"
    end
    if spill_metadata.uid ~= current_uid then
      return nil, "spill must be owned by the current user"
    end
    if permission_bits(spill_metadata.mode) ~= 448 then
      return nil, "spill must have mode 0700"
    end

    local normalized_result = normalize_absolute(request.result, false)
    if not normalized_result then
      return nil, "result must be a safe absolute path"
    end
    if normalized_result ~= request.result then
      return nil, "result must be normalized"
    end
    if dirname(normalized_result) ~= normalized_workspace then
      return nil, "result must be a direct child of the workspace"
    end
    if normalized_result:sub(-8) ~= ".parquet" then
      return nil, "result must end in .parquet"
    end
    if
      normalized_result == normalized_source
      or normalized_result == normalized_workspace
      or normalized_result == spill_path
    then
      return nil, "result path conflicts with a protected path"
    end

    local result_metadata, result_error, result_checked = lstat(normalized_result)
    if not result_checked then
      return nil, "could not inspect result: " .. tostring(result_error)
    end
    if result_metadata then
      return nil, "result must not already exist"
    end
    if type(result_error) ~= "string" or not result_error:find("ENOENT", 1, true) then
      return nil, "could not prove that the result is absent"
    end
    local realpath_ok, result_realpath, realpath_error = pcall(deps.realpath, normalized_result)
    if not realpath_ok then
      return nil, "could not verify absent result path: " .. tostring(result_realpath)
    end
    if result_realpath ~= nil then
      return nil, "result path unexpectedly resolves"
    end
    if type(realpath_error) ~= "string" or not realpath_error:find("ENOENT", 1, true) then
      return nil, "result realpath is ambiguous"
    end

    return {
      result = normalized_result,
      source = normalized_source,
      visible_name = visible_name,
      workspace = normalized_workspace,
    }
  end

  local function command(request)
    local report, runtime_error = runtime()
    if not report then
      return nil, nil, runtime_error
    end

    local validated, request_error = validate_request(request)
    if not validated then
      return nil, nil, request_error
    end
    local join_ok, virtual_source = pcall(deps.joinpath, virtual_directory, validated.visible_name)
    if not join_ok or not is_safe_absolute(virtual_source, false) then
      return nil, nil, "could not derive the virtual source path"
    end

    local argv = hardening_prefix(report.sandbox.path)
    vim.list_extend(argv, {
      "--dir",
      virtual_directory,
      "--bind",
      validated.workspace,
      validated.workspace,
      "--ro-bind",
      validated.source,
      virtual_source,
      "--chdir",
      virtual_directory,
      report.python,
      "-I",
      "-B",
      report.runner.path,
      "--source",
      virtual_source,
      "--workspace",
      validated.workspace,
      "--result",
      validated.result,
    })
    return argv, virtual_source
  end

  return {
    command = command,
    invalidate = function()
      cached = nil
    end,
    probe = probe,
    runtime = runtime,
  }
end

local runtime = new({
  deepcopy = vim.deepcopy,
  executable = vim.fn.executable,
  exepath = vim.fn.exepath,
  joinpath = vim.fs.joinpath,
  json_decode = vim.json.decode,
  lstat = vim.uv.fs_lstat,
  module_source = function()
    return module_source
  end,
  normalize = vim.fs.normalize,
  parquet_probe = function(options)
    return require("parquet.tool").probe(options)
  end,
  platform = function()
    return vim.uv.os_uname().sysname
  end,
  readable = vim.fn.filereadable,
  realpath = vim.uv.fs_realpath,
  system = function(command, options, wait_timeout)
    return vim.system(command, options):wait(wait_timeout)
  end,
  uid = vim.uv.getuid,
})

M.command = runtime.command
M.invalidate = runtime.invalidate
M.probe = runtime.probe
M.runtime = runtime.runtime
M.versions = vim.deepcopy(versions)
M._test = { new = new }

return M
