local git = require("ui.startup.git")
local function eq(actual, expected, label)
  assert(
    vim.deep_equal(actual, expected),
    (label or "values differ") .. "\n" .. vim.inspect(actual)
  )
end
local function status(records, head, oid)
  return "# branch.oid "
    .. (oid or string.rep("a", 40))
    .. "\0# branch.head "
    .. (head or "main")
    .. "\0"
    .. table.concat(records or {}, "\0")
    .. (#(records or {}) > 0 and "\0" or "")
end
local hash = string.rep("a", 40)
local ordinary = "1 .M N... 100644 100644 100644 " .. hash .. " " .. hash .. " "
local rename = "2 R. N... 100644 100644 100644 " .. hash .. " " .. hash .. " R100 "
local conflict = "u UU N... 100644 100644 100644 100644 "
  .. hash
  .. " "
  .. hash
  .. " "
  .. hash
  .. " "

local model = assert(git._test.parse_status(
  "/repo",
  status({
    "# branch.upstream origin/main",
    "# branch.ab +3 -2",
    ordinary .. "dir/file\t\n.lua",
    rename .. "new name",
    "old\nname",
    conflict .. "conflict",
    "? raw" .. string.char(255),
  })
))
eq(model.kind, "repository")
eq(model.root, "/repo")
eq(model.branch, {
  oid = hash,
  head = "main",
  upstream = "origin/main",
  ahead = 3,
  behind = 2,
  detached = false,
  unborn = false,
})
eq(
  model.changes[1],
  { path = "dir/file\t\n.lua", xy = ".M", index = ".", worktree = "M", kind = "modified" }
)
eq(model.changes[2].original_path, "old\nname")
eq(model.changes[4].path, "raw" .. string.char(255))
eq(
  model.counts,
  { total = 4, modified = 1, added = 0, deleted = 0, renamed = 1, conflicted = 1, untracked = 1 }
)
eq(assert(git._test.parse_status("/repo", status({}, "(detached)"))).branch.detached, true)
eq(assert(git._test.parse_status("/repo", status({}, "new", "(initial)"))).branch.unborn, true)
local mixed = assert(
  git._test.parse_status(
    "/repo",
    status({ ordinary:gsub("1 .M", "1 AM") .. "a", ordinary:gsub("1 .M", "1 .D") .. "b" })
  )
)
eq(
  mixed.counts,
  { total = 2, modified = 1, added = 1, deleted = 1, renamed = 0, conflicted = 0, untracked = 0 }
)

for _, output in ipairs({
  status({ ordinary .. "file" }):sub(1, -2),
  status({ rename .. "new" }),
  status({ "1 broken" }),
  status({ "? " }),
  status({ "? ../escape" }),
  status({ "? /absolute" }),
  status({ "# branch.head duplicate" }),
  status({ "# branch.ab +a -2" }),
  status({ "! ignored" }),
  "# branch.head main\0",
  status({}, "main", "invalid"),
  status({ ordinary:gsub("1 .M", "1 UU") .. "invalid conflict" }),
  status({ rename:gsub("2 R%.", "2 .M") .. "new", "old" }),
  status({ conflict:gsub("u UU", "u MM") .. "invalid conflict" }),
}) do
  local parsed, problem = git._test.parse_status("/repo", output)
  assert(
    parsed == nil and type(problem) == "string",
    "malformed status accepted: " .. vim.inspect(output)
  )
end
eq(
  git.sanitize("name\tline\n\r\0\27\127" .. string.char(255)),
  "name\\tline\\n\\r\\x00\\x1B\\x7F\\xFF"
)
eq(git.sanitize("é漢é"), "é漢é")
eq(git.sanitize(string.char(0xC0, 0xAF, 0xED, 0xA0, 0x80)), "\\xC0\\xAF\\xED\\xA0\\x80")
eq(git.sanitize("a\226\128\174b"), "a\\u202Eb")

local history = assert(
  git._test.parse_history(
    "*   \0abc1234\0merge\27title\0\n|\\  \n| * \0def5678\0second\nsubject\0\n|/  \n* \0abc5678\0é\0\n"
  )
)
eq(history, {
  { graph = "*   ", oid = "abc1234", subject = "merge\\x1Btitle" },
  { graph = "|\\  " },
  { graph = "| * ", oid = "def5678", subject = "second\\nsubject" },
  { graph = "|/  " },
  { graph = "* ", oid = "abc5678", subject = "é" },
})
eq(assert(git._test.parse_history("")), {})
for _, output in ipairs({
  "* \0abc1234\0missing",
  "* \0oops\0subject\0\n",
  "bad\n",
  "|\0abc1234\0subject\0\n",
  "* \0abc1234\0subject\0junk",
}) do
  local parsed, problem = git._test.parse_history(output)
  assert(parsed == nil and type(problem) == "string", "malformed history accepted")
end

local function harness(overrides)
  local h = { calls = {}, scheduled = {}, views = {}, timers = {} }
  local dependencies = {
    exepath = function()
      return "/usr/bin/git"
    end,
    environ = function()
      return {
        PATH = "/test/bin",
        HOME = "/secret",
        GIT_DIR = "/secret/repo",
        GIT_CONFIG_COUNT = "1",
      }
    end,
    schedule = function(callback)
      h.scheduled[#h.scheduled + 1] = callback
    end,
    new_timer = function()
      local timer = { starts = 0, closed = false, stopped = false }
      function timer:start(timeout, repeat_ms, callback)
        self.starts, self.timeout, self.repeat_ms, self.callback =
          self.starts + 1, timeout, repeat_ms, callback
      end
      function timer:stop()
        self.stopped = true
      end
      function timer:close()
        self.closed = true
      end
      h.timers[#h.timers + 1] = timer
      return timer
    end,
    system = function(argv, options, callback)
      local child = { argv = argv, options = options, callback = callback, kills = 0 }
      function child:kill(signal)
        eq(signal, 9)
        self.kills = self.kills + 1
      end
      h.calls[#h.calls + 1] = child
      return child
    end,
  }
  for key, value in pairs(overrides or {}) do
    dependencies[key] = value
  end
  h.collector = git._test.new(dependencies)
  function h:start()
    self.request = self.collector.collect("/repo/sub", function(view)
      self.views[#self.views + 1] = view
    end)
    return self.request
  end
  function h:complete(index, code, output, stderr)
    self.calls[index].callback({
      code = code or 0,
      signal = 0,
      stdout = output or "",
      stderr = stderr or "",
    })
  end
  function h:discover()
    self:complete(1, 0, "/repo\n")
    eq(#self.calls, 2, "filter preflight precedes status/history")
    assert(vim.tbl_contains(self.calls[2].argv, "config"))
    self:complete(2, 1, "")
    eq(#self.calls, 3, "gitlink preflight precedes status/history")
    assert(vim.tbl_contains(self.calls[3].argv, "ls-files"))
    self:complete(3, 0, "")
  end
  function h:drain()
    local queue = self.scheduled
    self.scheduled = {}
    for _, callback in ipairs(queue) do
      callback()
    end
  end
  return h
end

local h = harness()
h:start()
eq(#h.calls, 1, "discovery starts alone")
eq(#h.views, 0, "collector never delivers synchronously")
eq(h.calls[1].argv, {
  "/usr/bin/git",
  "--no-pager",
  "-c",
  "core.fsmonitor=false",
  "-c",
  "core.hooksPath=/dev/null",
  "-c",
  "gc.auto=0",
  "-C",
  "/repo/sub",
  "rev-parse",
  "--show-toplevel",
})
eq(h.calls[1].options.clear_env, true)
eq(h.calls[1].options.env, {
  PATH = "/test/bin",
  LC_ALL = "C",
  LANG = "C",
  GIT_CONFIG_NOSYSTEM = "1",
  GIT_CONFIG_GLOBAL = "/dev/null",
  GIT_CONFIG_SYSTEM = "/dev/null",
  GIT_ATTR_NOSYSTEM = "1",
  GIT_OPTIONAL_LOCKS = "0",
  GIT_TERMINAL_PROMPT = "0",
  GIT_PAGER = "cat",
})
h:discover()
eq(#h.calls, 5, "status and history launch concurrently after preflight")
assert(vim.tbl_contains(h.calls[4].argv, "status") and vim.tbl_contains(h.calls[4].argv, "-z"))
assert(
  vim.tbl_contains(h.calls[5].argv, "log") and vim.tbl_contains(h.calls[5].argv, "--max-count=5")
)
assert(vim.tbl_contains(h.calls[4].argv, "--no-show-stash"))
h:complete(5, 0, "* \0abc1234\0first\0\n")
eq(#h.views, 0, "history waits for status")
h:complete(4, 0, status({ ordinary .. "file" }))
eq(h.timers[1].closed, true)
eq(h.timers[1].starts, 1)
eq(h.timers[1].timeout, 3000)
h:drain()
eq(#h.views, 1)
eq(h.views[1].history[1].subject, "first")
eq(h.views[1].counts.total, 1)
eq(h.request.cancel(), false, "delivered request cannot cancel")
h:complete(4, 0, status({}))
h.timers[1].callback()
h:drain()
eq(#h.views, 1, "late callbacks cannot deliver twice")

local nonrepo = harness()
nonrepo:start()
nonrepo:complete(
  1,
  128,
  "",
  "fatal: not a git repository (or any of the parent directories): .git\n"
)
nonrepo:drain()
eq(nonrepo.views, { { kind = "non_repository" } })
eq(#nonrepo.calls, 1)
local unexpected = harness()
unexpected:start()
unexpected:complete(1, 128, "", "fatal: unsafe repository /secret/path\27")
unexpected:drain()
eq(unexpected.views[1].kind, "error")
assert(not unexpected.views[1].message:find("secret", 1, true))

for _, unborn in ipairs({ true, false }) do
  local unborn_case = harness()
  unborn_case:start()
  unborn_case:discover()
  unborn_case:complete(5, 128, "", "fatal: your current branch does not have any commits yet")
  unborn_case:complete(4, 0, status({}, unborn and "new" or "main", unborn and "(initial)" or hash))
  unborn_case:drain()
  eq(unborn_case.views[1].kind, unborn and "repository" or "error")
end

local unborn_failure = harness()
unborn_failure:start()
unborn_failure:discover()
unborn_failure:complete(4, 0, status({}, "new", "(initial)"))
unborn_failure:complete(5, 128, "", "fatal: permission denied /secret")
unborn_failure:drain()
eq(
  unborn_failure.views[1].kind,
  "error",
  "unborn repositories must not hide unexpected history failures"
)

local bad_status = harness()
bad_status:start()
bad_status:discover()
bad_status:complete(4, 0, "bad")
bad_status:drain()
eq(bad_status.views[1].kind, "error")
eq(bad_status.calls[5].kills, 1, "failed status cancels history")
bad_status:complete(5, 0, "")
bad_status:drain()
eq(#bad_status.views, 1)

local timed = harness()
timed:start()
timed:discover()
timed.timers[1].callback()
timed:drain()
eq(timed.views[1].kind, "error")
eq(timed.calls[1].kills, 0)
eq(timed.calls[4].kills, 1)
eq(timed.calls[5].kills, 1)
assert(timed.timers[1].closed and timed.timers[1].stopped)
timed:complete(4, 0, status({}))
timed:complete(5, 0, "")
timed:drain()
eq(#timed.views, 1)

local canceled = harness()
canceled:start()
eq(canceled.request.cancel(), true)
eq(canceled.request.cancel(), false)
canceled:complete(1, 0, "/repo\n")
canceled:drain()
eq(#canceled.calls, 1)
eq(#canceled.views, 0)
eq(canceled.calls[1].kills, 1)
eq(canceled.timers[1].closed, true)
local queued = harness()
queued:start()
queued:complete(
  1,
  128,
  "",
  "fatal: not a git repository (or any of the parent directories): .git\n"
)
eq(queued.request.cancel(), true, "cancellation suppresses queued delivery")
queued:drain()
eq(#queued.views, 0)

for _, overrides in ipairs({
  {
    exepath = function()
      return ""
    end,
  },
  {
    system = function()
      error("spawn failure /secret")
    end,
  },
}) do
  local failed = harness(overrides)
  failed:start()
  failed:drain()
  eq(failed.views[1].kind, "error")
end
local redirected = harness()
redirected:start()
redirected:complete(1, 0, "/elsewhere\n")
redirected:drain()
eq(redirected.views[1].kind, "error", "worktree redirect outside captured directory rejected")

for _, output in ipairs({
  "filter.private.clean\nsecret helper\0",
  "filter.private.process\nsecret helper\0",
  "malformed",
}) do
  local filters = harness()
  filters:start()
  filters:complete(1, 0, "/repo\n")
  eq(#filters.calls, 2)
  filters:complete(2, 0, output)
  filters:drain()
  eq(filters.views[1].kind, "error", "unsafe/malformed effective filters are declined")
  assert(not filters.views[1].message:find("secret", 1, true))
  eq(#filters.calls, 2, "filter preflight never starts status/history")
end
local preflight_timeout = harness()
preflight_timeout:start()
preflight_timeout:complete(1, 0, "/repo\n")
preflight_timeout.timers[1].callback()
preflight_timeout:drain()
eq(preflight_timeout.calls[2].kills, 1)
preflight_timeout:complete(2, 1, "")
eq(#preflight_timeout.calls, 2, "late preflight cannot spawn status/history")
eq(preflight_timeout.timers[1].starts, 1, "preflight shares the sole deadline")
local empty_filter = harness()
empty_filter:start()
empty_filter:complete(1, 0, "/repo\n")
empty_filter:complete(2, 0, "filter.unused.clean\n\0filter.unused.process\n\0")
empty_filter:complete(3, 0, "")
eq(#empty_filter.calls, 5, "empty filter values do not disable summary")
empty_filter.request.cancel()

for _, output in ipairs({ "160000 " .. hash .. " 0\tchild\0", "malformed" }) do
  local gitlinks = harness()
  gitlinks:start()
  gitlinks:complete(1, 0, "/repo\n")
  gitlinks:complete(2, 1, "")
  gitlinks:complete(3, 0, output)
  gitlinks:drain()
  eq(gitlinks.views[1].kind, "error", "gitlinks and malformed index records decline safely")
  eq(#gitlinks.calls, 3, "gitlinks never start status/history")
end
for _, phase in ipairs({ 2, 3 }) do
  for _, cancel in ipairs({ true, false }) do
    local pending = harness()
    pending:start()
    pending:complete(1, 0, "/repo\n")
    if phase == 3 then
      pending:complete(2, 1, "")
    end
    if cancel then
      pending.request.cancel()
    else
      pending.timers[1].callback()
    end
    pending:complete(phase, phase == 2 and 1 or 0, "")
    pending:drain()
    eq(pending.calls[phase].kills, 1, "preflight child canceled under the shared deadline")
    eq(#pending.calls, phase, "late preflight cannot launch further commands")
    eq(#pending.views, cancel and 0 or 1)
  end
end

local fixture = vim.fn.tempname()
assert(
  fixture:sub(1, #vim.env.TMPDIR + 1) == vim.env.TMPDIR .. "/",
  "fixture escaped private TMPDIR"
)
assert(vim.fn.mkdir(fixture, "p") == 1)
local function write(path, value)
  local file = assert(io.open(path, "wb"))
  assert(file:write(value))
  assert(file:close())
end
local executable = vim.fn.exepath("git")
local function command(cwd, arguments)
  local argv = {
    executable,
    "-c",
    "core.fsmonitor=false",
    "-c",
    "core.hooksPath=/dev/null",
    "-c",
    "user.name=Starter test",
    "-c",
    "user.email=starter@example.invalid",
    "-c",
    "commit.gpgSign=false",
    "-C",
    cwd,
  }
  vim.list_extend(argv, arguments)
  local result = vim
    .system(argv, {
      text = false,
      clear_env = true,
      env = {
        PATH = vim.env.PATH,
        HOME = vim.env.HOME,
        LC_ALL = "C",
        GIT_CONFIG_NOSYSTEM = "1",
        GIT_CONFIG_GLOBAL = "/dev/null",
      },
    })
    :wait(5000)
  assert(result.code == 0 and result.signal == 0, result.stderr)
  return result.stdout
end
local function collect(directory)
  local views = {}
  local request = git.collect(directory, function(view)
    views[#views + 1] = view
  end)
  assert(
    vim.wait(5000, function()
      return #views > 0
    end, 10),
    "real Git collection timed out"
  )
  eq(#views, 1)
  eq(request.cancel(), false)
  return views[1]
end
local inherited = {}
for _, key in ipairs({
  "GIT_DIR",
  "GIT_WORK_TREE",
  "GIT_CONFIG_GLOBAL",
  "GIT_CONFIG_COUNT",
  "GIT_CONFIG_KEY_0",
  "GIT_CONFIG_VALUE_0",
}) do
  inherited[key] = vim.env[key] or false
end
local fixture_ok, fixture_error = xpcall(function()
  local repo = fixture .. "/repository\n "
  assert(vim.fn.mkdir(repo .. "/nested", "p") == 1)
  command(repo, { "init", "--initial-branch=main", "--quiet" })
  eq(collect(repo).branch.unborn, true, "real unborn repository remains visible")
  write(repo .. "/old\nfile", "first\n")
  command(repo, { "add", "--", "old\nfile" })
  command(repo, { "commit", "--quiet", "-m", "first" })
  command(repo, { "checkout", "--quiet", "-b", "side" })
  write(repo .. "/side", "side\n")
  command(repo, { "add", "side" })
  command(repo, { "commit", "--quiet", "-m", "side" })
  command(repo, { "checkout", "--quiet", "main" })
  write(repo .. "/main", "main\n")
  command(repo, { "add", "main" })
  command(repo, { "commit", "--quiet", "-m", "main" })
  command(repo, { "merge", "--quiet", "--no-ff", "side", "-m", "merge" })
  write(repo .. "/main", "stash change\n")
  command(repo, { "stash", "push", "--quiet", "-m", "starter fixture" })
  command(repo, { "config", "status.showStash", "true" })
  eq(
    collect(repo).kind,
    "repository",
    "local stash display settings do not break porcelain parsing"
  )
  command(repo, { "config", "log.showSignature", "true" })
  local trap = fixture .. "/fsmonitor"
  write(trap, "#!/bin/sh\ntouch '" .. fixture .. "/unexpected-helper'\n")
  assert(vim.uv.fs_chmod(trap, 448))
  command(repo, { "config", "core.fsmonitor", trap })
  command(repo, { "mv", "--", "old\nfile", "new\tfile" })
  write(repo .. "/new\tfile", "first\nsecond\n")
  for index = 1, 14 do
    write(repo .. "/untracked" .. index, "new\n")
  end
  write(repo .. "/invalid" .. string.char(255), "invalid UTF8 path\n")
  local poison = fixture .. "/global-config"
  write(poison, "[core]\nworktree = /secret\n[include]\npath = /secret/config\n")
  vim.env.GIT_DIR, vim.env.GIT_WORK_TREE, vim.env.GIT_CONFIG_GLOBAL = "/secret", "/secret", poison
  vim.env.GIT_CONFIG_COUNT, vim.env.GIT_CONFIG_KEY_0, vim.env.GIT_CONFIG_VALUE_0 =
    "1", "core.worktree", "/secret"
  local actual = collect(repo .. "/nested")
  eq(actual.kind, "repository")
  eq(actual.root, repo, "raw newline/space root retained")
  eq(actual.name, "repository\\n ")
  eq(actual.counts.total, 16, "all paths counted before display limit")
  eq(actual.counts.renamed, 1)
  eq(actual.counts.untracked, 15)
  eq(actual.history[1].subject, "merge")
  local commits, connectors = 0, 0
  for _, row in ipairs(actual.history) do
    if row.oid then
      commits = commits + 1
    else
      connectors = connectors + 1
    end
  end
  eq(commits, 4)
  assert(connectors > 0, "real merge graph connector rows missing")
  eq(vim.uv.fs_stat(fixture .. "/unexpected-helper"), nil, "fsmonitor helper never executes")
  local linked = fixture .. "/linked"
  command(repo, { "worktree", "add", "--quiet", "--detach", linked })
  local linked_view = collect(linked)
  eq(linked_view.kind, "repository", "linked .git-file repository discovered")
  eq(linked_view.root, linked)
  eq(linked_view.branch.detached, true)
  eq(linked_view.counts.total, 0)
  eq(collect(fixture).kind, "non_repository", "no inherited GIT_DIR fallback")
  local filter = fixture .. "/filter-helper"
  write(filter, '#!/bin/sh\n: > "$0.executed"\ncat\n')
  assert(vim.uv.fs_chmod(filter, 448))
  write(repo .. "/.git/info/attributes", "main filter=guard\n")
  write(repo .. "/main", "filter-triggering change\n")
  command(repo, { "config", "filter.guard.clean", filter })
  eq(collect(repo).kind, "error", "configured clean filters decline before status can execute them")
  eq(vim.uv.fs_stat(filter .. ".executed"), nil, "clean filter helper never executes")
  command(repo, { "config", "--unset", "filter.guard.clean" })
  local include = fixture .. "/included-config"
  write(include, '[filter "guard"]\nclean = ' .. filter .. "\n")
  command(repo, { "config", "include.path", include })
  eq(collect(repo).kind, "error", "effective included filter configuration is checked")
  eq(vim.uv.fs_stat(filter .. ".executed"), nil, "included helper never executes")
  command(repo, { "config", "--unset", "include.path" })
  command(repo, { "config", "extensions.worktreeConfig", "true" })
  command(linked, { "config", "--worktree", "filter.unused.process", filter })
  eq(collect(linked).kind, "error", "worktree filter configuration is checked even when unused")
  eq(vim.uv.fs_stat(filter .. ".executed"), nil, "worktree helper never executes")
  local parent, child = fixture .. "/submodule-parent", fixture .. "/submodule-parent/child"
  assert(vim.fn.mkdir(child, "p") == 1)
  command(parent, { "init", "--initial-branch=main", "--quiet" })
  command(child, { "init", "--initial-branch=main", "--quiet" })
  write(child .. "/tracked", "original\n")
  command(child, { "add", "tracked" })
  command(child, { "commit", "--quiet", "-m", "child fixture" })
  local child_oid = command(child, { "rev-parse", "HEAD" }):gsub("\n$", "")
  command(parent, { "update-index", "--add", "--cacheinfo", "160000," .. child_oid .. ",child" })
  write(child .. "/.git/info/attributes", "tracked filter=guard\n")
  command(child, { "config", "filter.guard.clean", filter })
  write(child .. "/tracked", "filter-triggering child change\n")
  eq(
    collect(parent).kind,
    "error",
    "tracked gitlinks decline before status can execute child filters"
  )
  eq(vim.uv.fs_stat(filter .. ".executed"), nil, "submodule-only helper never executes")
  for _, cancel in ipairs({ true, false }) do
    local wrapper = fixture .. (cancel and "/cancel-resistant" or "/timeout-resistant")
    write(wrapper, '#!/bin/sh\ntrap "" TERM\n: > "$0.ready"\nwhile :; do :; done\n')
    assert(vim.uv.fs_chmod(wrapper, 448))
    local process, view
    local resistant = git._test.new({
      exepath = function()
        return wrapper
      end,
      environ = vim.fn.environ,
      schedule = vim.schedule,
      new_timer = vim.uv.new_timer,
      system = function(argv, options, callback)
        process = vim.system(argv, options, callback)
        return process
      end,
    })
    local request = resistant.collect(repo, function(result)
      view = result
    end)
    local child_ok, child_error = xpcall(function()
      assert(
        vim.wait(1000, function()
          return vim.uv.fs_stat(wrapper .. ".ready") ~= nil
        end, 10),
        "resistant child did not start"
      )
      if cancel then
        eq(request.cancel(), true)
      else
        assert(
          vim.wait(4000, function()
            return view ~= nil
          end, 10),
          "request deadline did not expire"
        )
        eq(view.kind, "error")
      end
      local result = process:wait(1000)
      eq(result.signal, 9, "owned resistant child is terminated and reaped")
      if cancel then
        eq(view, nil, "canceled real child never delivers")
      end
    end, debug.traceback)
    request.cancel()
    if process then
      pcall(process.kill, process, 9)
      process:wait(1000)
    end
    assert(child_ok, child_error)
  end
end, debug.traceback)
for key, value in pairs(inherited) do
  vim.env[key] = value ~= false and value or nil
end
assert(vim.fn.delete(fixture, "rf") == 0, "private Git fixture cleanup failed")
assert(fixture_ok, fixture_error)

print("Startup Git assertions: ok")
