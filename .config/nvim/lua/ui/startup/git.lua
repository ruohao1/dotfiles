local M = {}

function M.sanitize(value)
  local result, index = {}, 1
  while index <= #value do
    local first = value:byte(index)
    local length = first < 0x80 and 1
      or first >= 0xC2 and first <= 0xDF and 2
      or first >= 0xE0 and first <= 0xEF and 3
      or first >= 0xF0 and first <= 0xF4 and 4
      or 0
    local point = length > 0 and first % (2 ^ (8 - length - (length == 1 and 0 or 1))) or 0
    local valid = length > 0 and index + length - 1 <= #value
    for offset = 1, length - 1 do
      local byte = value:byte(index + offset)
      if not byte or byte < 0x80 or byte > 0xBF then
        valid = false
        break
      end
      point = point * 64 + byte - 0x80
    end
    valid = valid
      and not (length == 3 and point < 0x800)
      and not (length == 4 and point < 0x10000)
      and not (point >= 0xD800 and point <= 0xDFFF)
      and point <= 0x10FFFF
    if not valid then
      result[#result + 1] = string.format("\\x%02X", first)
      index = index + 1
    else
      local special = ({ [9] = "\\t", [10] = "\\n", [13] = "\\r" })[point]
      local invisible = point < 32
        or (point >= 0x7F and point <= 0x9F)
        or point == 0xAD
        or point == 0x61C
        or (point >= 0x200B and point <= 0x200F)
        or (point >= 0x2028 and point <= 0x202E)
        or (point >= 0x2060 and point <= 0x206F)
        or point == 0xFEFF
      result[#result + 1] = special
        or (invisible and string.format(point < 256 and "\\x%02X" or "\\u%04X", point))
        or value:sub(index, index + length - 1)
      index = index + length
    end
  end
  return table.concat(result)
end

local function valid_hash(value)
  return value and (#value == 40 or #value == 64) and value:match("^%x+$") ~= nil
end

local function valid_path(value)
  return value ~= "" and value:sub(1, 1) ~= "/" and not ("/" .. value .. "/"):find("/../", 1, true)
end

local function parse_status(root, output)
  local function malformed()
    return nil, "Invalid Git status output"
  end
  if type(output) ~= "string" or output:sub(-1) ~= "\0" then
    return malformed()
  end
  local records = vim.split(output:sub(1, -2), "\0", { plain = true })
  local branch, changes = {}, {}
  local counts =
    { total = 0, modified = 0, added = 0, deleted = 0, renamed = 0, conflicted = 0, untracked = 0 }
  local seen, index = {}, 1
  while index <= #records do
    local record = records[index]
    if record:sub(1, 2) == "# " then
      local key, value = record:match("^# branch%.([a-z]+) (.+)$")
      if not key or seen[key] then
        return malformed()
      end
      seen[key] = true
      if key == "oid" then
        if value ~= "(initial)" and not valid_hash(value) then
          return malformed()
        end
        branch.oid, branch.unborn = value, value == "(initial)"
      elseif key == "head" or key == "upstream" then
        branch[key] = M.sanitize(value)
        if key == "head" then
          branch.detached = value == "(detached)"
        end
      elseif key == "ab" then
        local ahead, behind = value:match("^%+(%d+) %-(%d+)$")
        if not ahead then
          return malformed()
        end
        branch.ahead, branch.behind = tonumber(ahead), tonumber(behind)
      else
        return malformed()
      end
    else
      local tag, xy, sub, path, original
      tag = record:sub(1, 1)
      if tag == "?" then
        path, xy = record:match("^%? (.+)$"), "??"
      elseif tag == "1" or tag == "2" or tag == "u" then
        local field_count = tag == "1" and 8 or tag == "2" and 9 or 10
        local fields, cursor = {}, 1
        for _ = 1, field_count do
          local stop = record:find(" ", cursor, true)
          if not stop or stop == cursor then
            return malformed()
          end
          fields[#fields + 1], cursor = record:sub(cursor, stop - 1), stop + 1
        end
        xy, sub, path = fields[2], fields[3], record:sub(cursor)
        if
          not xy:match("^[.MTADRCU][.MTADRCU]$")
          or not sub:match("^N%.%.%.$") and not sub:match("^S[.C][.M][.U]$")
        then
          return malformed()
        end
        if
          tag == "1" and (not xy:match("^[.MTAD][.MTAD]$") or xy == "..")
          or tag == "2" and not xy:find("[RC]")
          or tag == "u"
            and not (
              { DD = true, AU = true, UD = true, UA = true, DU = true, AA = true, UU = true }
            )[xy]
        then
          return malformed()
        end
        local last_mode = tag == "u" and 7 or 6
        for field = 4, last_mode do
          if not fields[field]:match("^[0-7][0-7][0-7][0-7][0-7][0-7]$") then
            return malformed()
          end
        end
        for field = last_mode + 1, tag == "u" and 10 or 8 do
          if not valid_hash(fields[field]) then
            return malformed()
          end
        end
        if tag == "2" then
          local score = fields[9]:match("^[RC](%d+)$")
          if not score or tonumber(score) > 100 then
            return malformed()
          end
          index = index + 1
          original = records[index]
          if not original or not valid_path(original) then
            return malformed()
          end
        end
      end
      if not path or not valid_path(path) then
        return malformed()
      end
      local kind = tag == "?" and "untracked"
        or tag == "u" and "conflicted"
        or tag == "2" and "renamed"
        or xy:find("A", 1, true) and "added"
        or xy:find("D", 1, true) and "deleted"
        or "modified"
      counts.total = counts.total + 1
      if tag == "?" or tag == "u" or tag == "2" then
        counts[kind] = counts[kind] + 1
      else
        for marker, category in pairs({ M = "modified", T = "modified", A = "added", D = "deleted" }) do
          if xy:find(marker, 1, true) and (marker ~= "T" or not xy:find("M", 1, true)) then
            counts[category] = counts[category] + 1
          end
        end
      end
      changes[#changes + 1] = {
        path = path,
        original_path = original,
        xy = xy,
        index = xy:sub(1, 1),
        worktree = xy:sub(2, 2),
        kind = kind,
      }
    end
    index = index + 1
  end
  if not seen.oid or not seen.head or seen.ab and not seen.upstream then
    return malformed()
  end
  local name = root:match("([^/]+)/*$") or root
  return {
    kind = "repository",
    root = root,
    name = M.sanitize(name),
    branch = branch,
    changes = changes,
    counts = counts,
    history = {},
  }
end

local function parse_history(output)
  local rows, cursor = {}, 1
  local function malformed()
    return nil, "Invalid Git history output"
  end
  while cursor <= #output do
    local nul, newline = output:find("\0", cursor, true), output:find("\n", cursor, true)
    local stop = nul and newline and math.min(nul, newline) or nul or newline
    if not stop then
      return malformed()
    end
    local graph = output:sub(cursor, stop - 1)
    if graph == "" or graph:find("[^ *|/\\_.%-]") then
      return malformed()
    end
    if output:sub(stop, stop) == "\n" then
      if graph:find("*", 1, true) then
        return malformed()
      end
      rows[#rows + 1], cursor = { graph = graph }, stop + 1
    else
      local oid_end = output:find("\0", stop + 1, true)
      local subject_end = oid_end and output:find("\0", oid_end + 1, true)
      if not oid_end or not subject_end or output:sub(subject_end + 1, subject_end + 1) ~= "\n" then
        return malformed()
      end
      local oid = output:sub(stop + 1, oid_end - 1)
      if not graph:find("*", 1, true) or not oid:match("^%x+$") or #oid < 4 or #oid > 64 then
        return malformed()
      end
      rows[#rows + 1] =
        { graph = graph, oid = oid, subject = M.sanitize(output:sub(oid_end + 1, subject_end - 1)) }
      cursor = subject_end + 2
    end
  end
  return rows
end

local function new(dependencies)
  local function collect(directory, callback)
    local finished, canceled, delivered = false, false, false
    local children, timer = {}, nil
    local function cleanup()
      if timer then
        pcall(timer.stop, timer)
        pcall(timer.close, timer)
        timer = nil
      end
      for child in pairs(children) do
        children[child] = nil
        pcall(child.kill, child, 9)
      end
    end
    local function finish(view)
      if finished or canceled then
        return
      end
      finished = true
      cleanup()
      dependencies.schedule(function()
        if canceled or delivered then
          return
        end
        delivered = true
        callback(view)
      end)
    end
    local function fail(message)
      finish({ kind = "error", message = message })
    end
    local request = {
      cancel = function()
        if canceled or delivered then
          return false
        end
        canceled, finished = true, true
        cleanup()
        return true
      end,
    }
    local executable = dependencies.exepath("git")
    if not executable or executable:sub(1, 1) ~= "/" then
      fail("Git executable unavailable")
      return request
    end
    local environment = {
      PATH = dependencies.environ().PATH,
      LC_ALL = "C",
      LANG = "C",
      GIT_CONFIG_NOSYSTEM = "1",
      GIT_CONFIG_GLOBAL = "/dev/null",
      GIT_CONFIG_SYSTEM = "/dev/null",
      GIT_ATTR_NOSYSTEM = "1",
      GIT_OPTIONAL_LOCKS = "0",
      GIT_TERMINAL_PROMPT = "0",
      GIT_PAGER = "cat",
    }
    local function run(cwd, arguments, on_exit)
      if finished then
        return
      end
      local argv = {
        executable,
        "--no-pager",
        "-c",
        "core.fsmonitor=false",
        "-c",
        "core.hooksPath=/dev/null",
        "-c",
        "gc.auto=0",
        "-C",
        cwd,
      }
      vim.list_extend(argv, arguments)
      local child
      local ok, process = pcall(
        dependencies.system,
        argv,
        { env = environment, clear_env = true, text = false },
        function(result)
          if child then
            children[child] = nil
          end
          if not finished then
            on_exit(result)
          end
        end
      )
      if not ok then
        fail("Could not start Git")
      elseif not finished then
        child = process
        children[child] = true
      end
    end
    local timer_ok
    timer_ok, timer = pcall(dependencies.new_timer)
    if not timer_ok or not timer then
      timer = nil
      fail("Could not start Git deadline")
      return request
    end
    timer:start(3000, 0, function()
      fail("Git request timed out")
    end)
    directory = (dependencies.realpath and dependencies.realpath(directory)) or directory
    run(directory, { "rev-parse", "--show-toplevel" }, function(discovery)
      if discovery.code ~= 0 or discovery.signal ~= 0 then
        if
          discovery.code == 128
          and discovery.signal == 0
          and (
            (discovery.stderr or ""):match("^fatal: not a git repository")
            or (discovery.stderr or ""):match("^fatal: this operation must be run in a work tree")
          )
        then
          finish({ kind = "non_repository" })
        else
          fail("Could not discover Git repository")
        end
        return
      end
      local output = discovery.stdout or ""
      local root = output:sub(-1) == "\n" and output:sub(1, -2) or ""
      if
        root:sub(1, 1) ~= "/"
        or root:find("\0", 1, true)
        or not (root == "/" or root == directory or directory:sub(1, #root + 1) == root .. "/")
      then
        fail("Invalid Git repository directory")
        return
      end
      run(
        root,
        { "config", "--includes", "--null", "--get-regexp", "^filter\\..*\\.(clean|process)$" },
        function(configuration)
          local output = configuration.stdout or ""
          if
            configuration.signal ~= 0
            or not (configuration.code == 0 or configuration.code == 1 and output == "")
          then
            fail("Could not verify Git filter configuration")
            return
          end
          local cursor = 1
          while cursor <= #output do
            local stop = output:find("\0", cursor, true)
            local key, value
            if stop then
              key, value = output:sub(cursor, stop - 1):match("^(filter%..+)\n(.*)$")
            end
            local setting = key and key:match("%.([^%.]+)$")
            if not stop or not value or (setting ~= "clean" and setting ~= "process") then
              fail("Could not verify Git filter configuration")
              return
            end
            if value ~= "" then
              fail("Git summary unavailable for repositories with clean/process filters")
              return
            end
            cursor = stop + 1
          end
          run(root, { "ls-files", "--stage", "-z" }, function(index_result)
            if index_result.code ~= 0 or index_result.signal ~= 0 then
              fail("Could not verify Git submodule configuration")
              return
            end
            local index_output, cursor = index_result.stdout or "", 1
            while cursor <= #index_output do
              local stop = index_output:find("\0", cursor, true)
              local mode, oid, stage, path
              if stop then
                mode, oid, stage, path =
                  index_output:sub(cursor, stop - 1):match("^([0-7]+) (%x+) ([0-3])\t(.+)$")
              end
              if
                not mode
                or #mode ~= 6
                or not valid_hash(oid)
                or not stage
                or not valid_path(path)
              then
                fail("Could not verify Git submodule configuration")
                return
              end
              if mode == "160000" then
                fail("Git summary unavailable for repositories with tracked submodules")
                return
              end
              cursor = stop + 1
            end
            local model, history_result
            local function complete()
              if not model or not history_result then
                return
              end
              if history_result.code ~= 0 or history_result.signal ~= 0 then
                if
                  not model.branch.unborn
                  or history_result.code ~= 128
                  or history_result.signal ~= 0
                  or not (history_result.stderr or ""):match(
                    "^fatal: your current branch .-does not have any commits yet\n?$"
                  )
                then
                  fail("Could not read Git history")
                  return
                end
              else
                local rows, problem = parse_history(history_result.stdout or "")
                if not rows then
                  fail(problem)
                  return
                end
                model.history = rows
              end
              finish(model)
            end
            run(root, {
              "status",
              "--porcelain=v2",
              "--branch",
              "--untracked-files=all",
              "--ignore-submodules=none",
              "--no-show-stash",
              "-z",
            }, function(result)
              if result.code ~= 0 or result.signal ~= 0 then
                fail("Could not read Git status")
                return
              end
              local problem
              model, problem = parse_status(root, result.stdout or "")
              if not model then
                fail(problem)
                return
              end
              complete()
            end)
            run(root, {
              "log",
              "--graph",
              "--max-count=5",
              "--format=%x00%h%x00%s%x00",
              "--abbrev=7",
              "--no-color",
              "--no-decorate",
              "--no-show-signature",
            }, function(result)
              history_result = result
              complete()
            end)
          end)
        end
      )
    end)
    return request
  end
  return { collect = collect }
end

M.collect = new({
  system = vim.system,
  exepath = vim.fn.exepath,
  environ = vim.fn.environ,
  new_timer = vim.uv.new_timer,
  schedule = vim.schedule,
  realpath = vim.uv.fs_realpath,
}).collect
M._test = { parse_status = parse_status, parse_history = parse_history, new = new }
return M
