local function eq(actual, expected, label)
  assert(
    vim.deep_equal(actual, expected),
    label .. "\nexpected: " .. vim.inspect(expected) .. "\nactual: " .. vim.inspect(actual)
  )
end
local context = require("navigation.location_pin_context")
local store = require("navigation.location_pin_store")
local pins = require("navigation.location_pins")
local root = vim.env.XDG_RUNTIME_DIR .. "/p"
assert(vim.fn.mkdir(root, "p", 448) == 1)
local socket = root .. "/tmux.sock"
local previous = {
  tmux = vim.env.TMUX,
  pane = vim.env.TMUX_PANE,
  hidden = vim.o.hidden,
  notify = vim.notify,
  select = vim.ui.select,
  cwd = vim.fn.getcwd(),
}
local notifications = {}
vim.notify = function(message)
  notifications[#notifications + 1] = message
end
local function tmux(...)
  local argv = { "tmux", "-u", "-S", socket }
  vim.list_extend(argv, { ... })
  local result = vim
    .system(argv, { text = true, env = { TMUX = false, TMUX_PANE = false, SHELL = "/bin/sh" } })
    :wait(5000)
  assert(result.code == 0, result.stderr)
  return (result.stdout:gsub("\n$", ""))
end
local ok, err = xpcall(function()
  vim.api.nvim_set_current_dir(root)
  vim.env.TMUX, vim.env.TMUX_PANE = nil, nil
  local outside, reason = context.resolve()
  assert(outside == nil and reason:find("tmux", 1, true), "outside tmux is an informative no-op")
  pins.setup()
  for _, action in ipairs({ pins.add, pins.find, pins.delete_current, pins.clear }) do
    local before = #notifications
    action()
    assert(#notifications > before, "actions explain the missing context")
  end
  tmux("-f", "/dev/null", "new-session", "-d", "-s", "pins")
  tmux("new-session", "-d", "-s", "other")
  local pid = tmux("display-message", "-p", "-t", "=pins:", "#{pid}")
  local pane = tmux("display-message", "-p", "-t", "=pins:", "#{pane_id}")
  vim.env.TMUX, vim.env.TMUX_PANE = socket .. "," .. pid .. ",0", pane
  local ctx = assert(context.resolve())
  local function unavailable(label)
    pins.setup()
    eq(
      tmux("show-options", "-pqv", "-t", pane, "@dotfiles_line_pin_session"),
      "",
      label .. " setup never associates the pane"
    )
    for _, action in ipairs({ pins.add, pins.find, pins.delete_current, pins.clear }) do
      local before = #notifications
      action()
      assert(#notifications > before, label .. " explains unavailable actions")
    end
    eq(
      tmux("show-options", "-pqv", "-t", pane, "@dotfiles_line_pin_session"),
      "",
      label .. " never associates the pane"
    )
    assert(not pins.open(ctx, string.rep("a", 64)), label .. " refuses captured selections")
    assert(not context.remember(ctx), label .. " rejects explicit association")
    for _, action in ipairs({ store.list, store.add, store.delete, store.clear }) do
      local result, err = action(ctx, {})
      assert(not result and type(err) == "string", label .. " refuses helper actions")
    end
  end
  unavailable("ordinary tmux")
  tmux("set-option", "-g", "@dotfiles_foundation_loaded", "1")
  tmux("set-option", "-t", "$0", "status", "off")
  ctx = assert(context.resolve())
  eq(ctx.status_enabled, false, "status disabled does not disable configured origin")
  vim.g.dotfiles_tmux_integration = false
  unavailable("opt-out")
  vim.g.dotfiles_tmux_integration = nil
  local helper_root = vim.env.DOTFILES_NVIM_ROOT
  vim.env.DOTFILES_NVIM_ROOT = root .. "/no-helpers/nvim"
  unavailable("missing pin helper")
  local persistence = require("integrations.tmux_persistence")
  local literal_server = root .. "/editor '$(touch NEVER);.sock"
  local registration = assert(
    persistence.setup({ server = literal_server }),
    "missing pin helper leaves persistence enabled with status off"
  )
  eq(
    tmux("show-options", "-pqv", "-t", pane, "@dotfiles_nvim_server"),
    literal_server,
    "persistence retains the literal RPC path"
  )
  registration:stop()
  eq(
    tmux("show-options", "-pqv", "-t", pane, "@dotfiles_nvim_server"),
    "",
    "successful stop removes its own RPC registration"
  )
  local system = vim.system
  vim.system = function(argv, options)
    local process = system(argv, options)
    if argv[5] ~= "list-panes" then
      return {
        wait = function(_, timeout)
          local result = process:wait(timeout)
          result.stdout = ""
          return result
        end,
      }
    end
    return process
  end
  assert(not persistence.setup({ server = literal_server }), "unacknowledged registration fails")
  vim.system = system
  eq(
    tmux("show-options", "-pqv", "-t", pane, "@dotfiles_nvim_server"),
    "",
    "failed registration withdraws its own partially written fields"
  )
  registration = assert(persistence.setup({ server = literal_server }))
  tmux("set-option", "-p", "-t", pane, "@dotfiles_nvim_persistence_owner", "999_999")
  registration:stop()
  eq(
    tmux("show-options", "-pqv", "-t", pane, "@dotfiles_nvim_server"),
    literal_server,
    "cleanup preserves a replacement editor's registration"
  )
  system = vim.system
  vim.system = function(argv, ...)
    if argv[5] ~= "list-panes" then
      vim.system = system
      tmux("set-option", "-g", "@dotfiles_foundation_loaded", "0")
    end
    return system(argv, ...)
  end
  local stale_registration = persistence.setup({ server = root .. "/stale.sock" })
  vim.system = system
  assert(not stale_registration, "marker removal between probe and write refuses registration")
  eq(
    tmux("show-options", "-pqv", "-t", pane, "@dotfiles_nvim_server"),
    literal_server,
    "guarded registration cannot overwrite an editor after capability changes"
  )
  tmux("set-option", "-g", "@dotfiles_foundation_loaded", "1")
  vim.env.DOTFILES_NVIM_ROOT = helper_root
  vim.env.TMUX = socket .. ",1,0"
  unavailable("replaced origin")
  vim.env.TMUX = "malformed"
  unavailable("invalid origin")
  vim.env.TMUX = socket .. "," .. pid .. ",0"
  if vim.env.DOTFILES_EDITOR_STANDALONE == "1" then
    -- The copied editor tree has no sibling helper, even with configured tmux.
    unavailable("standalone editor")
    return
  end
  eq(ctx.session, "$0", "resolves the editor session")
  -- A linked pane still belongs to the explicit originating session in TMUX.
  tmux("link-window", "-s", "$0:0", "-t", "$1:1")
  vim.env.TMUX = socket .. "," .. pid .. ",1"
  local linked_context = assert(context.resolve())
  eq(linked_context.session, "$1", "linked pane honors the explicit originating session")
  assert(store.add(linked_context, { path = "/other/session", line = 1, col = 0 }))
  vim.env.TMUX = socket .. "," .. pid .. ",0"
  eq(#assert(store.list(ctx)), 0, "linked sessions do not share pins")
  local path = root .. "/雪 #{} | ' $(touch NEVER) .txt"
  vim.fn.writefile({ "one", "a\t雪x", "last" }, path)
  local target = vim.fn.bufadd(path)
  vim.fn.bufload(target)
  vim.api.nvim_set_current_buf(target)
  vim.api.nvim_win_set_cursor(0, { 2, 5 })
  local added = assert(pins.add())
  eq(added.path, path, "capture preserves literal file path")
  eq({ added.line, added.col }, { 2, 5 }, "captures one-based line and byte column")
  pins.add()
  eq(#assert(store.list(ctx)), 1, "editor add is idempotent")
  tmux("rename-session", "-t", "$0", "renamed")
  assert(context.validate(ctx), "rename preserves editor context")
  local modified = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(modified)
  vim.api.nvim_buf_set_lines(modified, 0, -1, false, { "unsaved user text" })
  vim.o.hidden = false
  assert(not pins.open(ctx, added.id), "cannot hide an unsaved buffer when hidden is disabled")
  eq(vim.api.nvim_get_current_buf(), modified, "refused navigation preserves current buffer")
  vim.o.hidden = true
  vim.bo[modified].bufhidden = "wipe"
  assert(not pins.open(ctx, added.id), "cannot discard a modified wipe-on-hide buffer")
  vim.bo[modified].bufhidden = ""
  assert(pins.open(ctx, added.id), "opens pin with hidden buffers allowed")
  eq(vim.api.nvim_buf_get_name(0), path, "opens a literal path, not an Ex expression")
  eq(vim.api.nvim_win_get_cursor(0), { 2, 5 }, "opens saved location")
  eq(
    vim.api.nvim_buf_get_lines(modified, 0, -1, false),
    { "unsaved user text" },
    "hidden unsaved contents survive"
  )
  assert(vim.bo[modified].modified, "navigation never writes the previous buffer")
  assert(not vim.uv.fs_stat(root .. "/NEVER"), "path command substitution was not evaluated")
  vim.api.nvim_buf_set_lines(target, 0, -1, false, { "雪" })
  assert(pins.open(ctx, added.id), "opens a location after file contents shrink")
  eq(vim.api.nvim_win_get_cursor(0), { 1, 0 }, "clamps row and column at UTF-8 boundary")
  local missing = assert(store.add(ctx, { path = root .. "/missing", line = 2, col = 1 }))
  assert(not pins.open(ctx, missing.id), "missing file does not open an empty replacement")
  assert(store.delete(ctx, missing.id), "missing file pin remains deletable")
  assert(store.delete(ctx, added.id))
  assert(not pins.open(ctx, added.id), "stale deleted selection does not open")
  local fresh = assert(store.add(ctx, { path = path, line = 1, col = 0 }))
  local pending
  vim.ui.select = function(choices, _, callback)
    eq(choices, { "Clear pins", "Cancel" }, "clear is explicitly confirmed")
    pending = callback
  end
  pins.clear()
  pending("Cancel")
  eq(#assert(store.list(ctx)), 1, "cancel leaves pins intact")
  pins.clear()
  pending("Clear pins")
  eq(#assert(store.list(ctx)), 0, "confirmed clear removes pins")
  assert(store.add(ctx, { path = path, line = 1, col = 0 }))
  pins.clear()
  vim.env.TMUX = socket .. "," .. pid .. ",1"
  pending("Clear pins")
  assert(not context.validate(ctx), "changed session invalidates captured context")
  vim.env.TMUX = socket .. "," .. pid .. ",0"
  eq(#assert(store.list(ctx)), 1, "stale confirmation did not mutate old session")
  vim.env.TMUX = socket .. ",1,0"
  assert(not context.resolve(), "replaced server identity is rejected")
  vim.env.TMUX = socket .. "," .. pid .. ",0"
  local scratch = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(scratch)
  assert(not pins.add(), "non-file buffers cannot be pinned")
  vim.api.nvim_set_current_buf(target)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  assert(pins.delete_current(), "delete-current targets the exact location")
  eq(#assert(store.list(ctx)), 0, "delete-current removes captured pin")
  assert(fresh.id ~= "", "pin has stable identity")
  pins.setup()
  for _, name in ipairs({ "LinePinAdd", "LinePins", "LinePinDelete", "LinePinsClear" }) do
    assert(vim.fn.exists(":" .. name) == 2, "command is registered: " .. name)
  end
end, debug.traceback)
pcall(tmux, "kill-server")
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end
vim.env.TMUX, vim.env.TMUX_PANE = previous.tmux, previous.pane
vim.o.hidden, vim.notify, vim.ui.select = previous.hidden, previous.notify, previous.select
vim.api.nvim_set_current_dir(previous.cwd)
vim.fn.delete(root, "rf")
assert(ok, err)
print("Line-pin editor assertions: ok")
