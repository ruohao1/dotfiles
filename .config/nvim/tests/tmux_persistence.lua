local persistence = require("integrations.tmux_persistence")
local test = persistence._test

local function eq(actual, expected, label)
  assert(
    vim.deep_equal(actual, expected),
    string.format("%s\nexpected: %s\nactual: %s", label, vim.inspect(expected), vim.inspect(actual))
  )
end

eq(test.valid_pane("%12"), true, "numeric pane")
eq(test.valid_pane("%bad"), false, "invalid pane")
eq(
  test.session_options(),
  { "blank", "buffers", "curdir", "folds", "help", "tabpages", "winsize" },
  "restricted native session options"
)
assert(
  test.path_within(
    "/state/dotfiles/tmux",
    "/state/dotfiles/tmux/snapshots/.staging-x/nvim/pane.vim"
  )
)
assert(not test.path_within("/state/dotfiles/tmux", "/state/dotfiles/tmux-other/session.vim"))

local calls = {}
local controller = test.new({
  socket = "/tmp/private socket",
  origin = { socket = "/tmp/private socket", pid = "20", session = "$3", pane = "%12" },
  pane = "%12",
  owner = "12_34",
  server = "/tmp/nvim.sock",
  system = function(argv)
    table.insert(calls, argv)
    return {
      wait = function()
        return { code = 0, signal = 0, stdout = "dotfiles-nvim-persistence:12_34\n", stderr = "" }
      end,
    }
  end,
})
controller:start()
eq(vim.list_slice(calls[1], 1, 8), {
  "tmux",
  "-u",
  "-S",
  "/tmp/private socket",
  "if-shell",
  "-F",
  "-t",
  "$3:%12",
}, "RPC registration targets the explicit socket and session")
assert(calls[1][9]:find("#{==:#{pid},20}", 1, true), "registration checks server identity")
assert(
  calls[1][10]:find("@dotfiles_nvim_server '/tmp/nvim.sock'", 1, true),
  "RPC registration preserves the pane protocol"
)

controller:stop()

local previous = {
  tmux = vim.env.TMUX,
  pane = vim.env.TMUX_PANE,
  system = vim.system,
  notify = vim.notify,
  integration = vim.g.dotfiles_tmux_integration,
}
local socket = "/literal socket/'$(touch NEVER)"
local probe = "20\t$3\t%12\t0\toff\n"
local setup_calls = {}
vim.env.TMUX, vim.env.TMUX_PANE = socket .. ",20,3", "%12"
vim.notify = function() end
vim.system = function(argv)
  setup_calls[#setup_calls + 1] = argv
  return {
    wait = function()
      local acknowledgment = table.concat(argv, " "):match("dotfiles%-nvim%-persistence:%d+_%d+")
      return { code = 0, signal = 0, stdout = acknowledgment or probe, stderr = "" }
    end,
  }
end
eq(persistence.setup({ server = "/tmp/editor.sock" }), nil, "ordinary tmux has no RPC registration")
eq(#setup_calls, 1, "ordinary tmux only probes availability")
probe = "20\t$3\t%12\t1\toff\n"
vim.g.dotfiles_tmux_integration = false
setup_calls = {}
eq(persistence.setup({ server = "/tmp/editor.sock" }), nil, "opt-out disables RPC registration")
eq(#setup_calls, 0, "opt-out avoids tmux calls")
vim.g.dotfiles_tmux_integration = nil
probe = "21\t$3\t%12\t1\toff\n"
eq(persistence.setup({ server = "/tmp/editor.sock" }), nil, "replaced server refuses registration")
probe = "20\t$4\t%12\t1\toff\n"
eq(persistence.setup({ server = "/tmp/editor.sock" }), nil, "changed session refuses registration")
vim.env.TMUX = "malformed"
setup_calls = {}
eq(persistence.setup({ server = "/tmp/editor.sock" }), nil, "invalid origin refuses registration")
eq(#setup_calls, 0, "invalid origin avoids tmux calls")
vim.env.TMUX = socket .. ",20,3"
probe = "20\t$3\t%12\t1\toff\n"
setup_calls = {}
local configured = assert(persistence.setup({ server = "/tmp/editor.sock" }))
eq(
  vim.list_slice(setup_calls[2], 1, 4),
  { "tmux", "-u", "-S", socket },
  "registration routes to the literal originating socket"
)
local replacement = assert(persistence.setup({ server = "/tmp/replacement.sock" }))
eq(#setup_calls, 5, "repeated setup withdraws previous registration before replacing it")
configured:stop()
eq(#setup_calls, 5, "replaced controller stop is idempotent")
replacement:stop()
replacement:stop()
eq(#setup_calls, 6, "active controller cleanup runs once")
local failed_calls = 0
vim.system = function(argv)
  failed_calls = failed_calls + 1
  return {
    wait = function()
      return { code = failed_calls == 1 and 0 or 1, signal = 0, stdout = probe, stderr = "failed" }
    end,
  }
end
eq(
  persistence.setup({ server = "/tmp/editor.sock" }),
  nil,
  "failed registration leaves no controller"
)
eq(failed_calls, 3, "failed registration only attempts guarded cleanup")
vim.env.TMUX, vim.env.TMUX_PANE = previous.tmux, previous.pane
vim.system, vim.notify = previous.system, previous.notify
vim.g.dotfiles_tmux_integration = previous.integration

local state_root = vim.fs.joinpath(vim.env.XDG_STATE_HOME, "dotfiles", "tmux")
local generation = string.format(".staging-test-%d", vim.fn.getpid())
local session_directory = vim.fs.joinpath(state_root, "snapshots", generation, "nvim")
local session_file = vim.fs.joinpath(session_directory, "pane-12.vim")
local project = vim.fn.tempname()
vim.fn.mkdir(session_directory, "p", 448)
vim.fn.mkdir(project, "p", 448)

local first_file = vim.fs.joinpath(project, "first.lua")
local second_file = vim.fs.joinpath(project, "second.lua")
vim.fn.writefile({ "return 'first'" }, first_file)
vim.fn.writefile({ "return 'second'" }, second_file)

vim.cmd("silent only")
vim.cmd("silent tabonly")
vim.cmd("cd " .. vim.fn.fnameescape(project))
vim.cmd("edit " .. vim.fn.fnameescape(first_file))
vim.cmd("vsplit " .. vim.fn.fnameescape(second_file))
vim.cmd("tabnew " .. vim.fn.fnameescape(first_file))
vim.cmd("split")
vim.cmd("enew")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved-secret-must-not-persist" })
vim.bo.modified = true
vim.cmd("botright split")
vim.cmd("enew")
local terminal_sentinel = "tmux-persistence-terminal-secret"
vim.fn.jobstart({ "/bin/sh", "-c", "sleep 30 # " .. terminal_sentinel }, { term = true })

local expected_tabs = vim.fn.tabpagenr("$")
local expected_windows = {}
for tab = 1, expected_tabs do
  local restorable = 0
  for _, window in ipairs(vim.fn.gettabinfo(tab)[1].windows) do
    local buffer = vim.api.nvim_win_get_buf(window)
    if vim.bo[buffer].buftype ~= "terminal" then
      restorable = restorable + 1
    end
  end
  expected_windows[tab] = restorable
end
local previous_sessionoptions = vim.o.sessionoptions
eq(
  persistence.checkpoint(project .. "/outside.vim"),
  "error:invalid checkpoint path",
  "checkpoint refuses paths outside workspace state"
)
eq(
  persistence.checkpoint(state_root .. "/session.vim"),
  "error:invalid checkpoint path",
  "checkpoint requires a staging generation"
)
local symlink_file = session_directory .. "/symlink.vim"
assert(vim.uv.fs_symlink(first_file, symlink_file))
eq(
  persistence.checkpoint(symlink_file),
  "error:invalid checkpoint path",
  "checkpoint refuses an existing symlink"
)
local escaped_parent = session_directory .. "/escape"
vim.fn.mkdir(project .. "/snapshots/.staging-x/nvim", "p", 448)
assert(vim.uv.fs_symlink(project, escaped_parent))
eq(
  persistence.checkpoint(escaped_parent .. "/snapshots/.staging-x/nvim/escape.vim"),
  "error:invalid checkpoint path",
  "checkpoint refuses parent symlink escape"
)
local directory_file = session_directory .. "/directory.vim"
vim.fn.mkdir(directory_file)
assert(
  persistence.checkpoint(directory_file):find("error:", 1, true) == 1,
  "session write failure is reported"
)
eq(vim.o.sessionoptions, previous_sessionoptions, "sessionoptions restored after failure")
eq(persistence.checkpoint(session_file), "ok", "native checkpoint")
eq(vim.o.sessionoptions, previous_sessionoptions, "sessionoptions restored")

local session_stat = assert(vim.uv.fs_stat(session_file), "native session was not written")
eq(session_stat.type, "file", "native session type")
eq(session_stat.mode % 512, 384, "native session mode")
local session_text = table.concat(vim.fn.readfile(session_file), "\n")
assert(
  not session_text:find("unsaved-secret-must-not-persist", 1, true),
  "unsaved text entered session"
)
assert(not session_text:find(terminal_sentinel, 1, true), "terminal command entered session")

local result_file = vim.fs.joinpath(project, "restored.json")
local inspect_command = string.format(
  [[lua local counts = {}; for tab = 1, vim.fn.tabpagenr("$") do counts[tab] = #vim.fn.gettabinfo(tab)[1].windows end; local names = {}; for _, buffer in ipairs(vim.api.nvim_list_bufs()) do local name = vim.api.nvim_buf_get_name(buffer); if name ~= "" then table.insert(names, name) end end; table.sort(names); vim.fn.writefile({vim.json.encode({cwd=vim.fn.getcwd(),tabs=vim.fn.tabpagenr("$"),windows=counts,names=names})}, %q)]],
  result_file
)
local restored = vim
  .system({
    "env",
    "-u",
    "NVIM",
    "-u",
    "NVIM_LISTEN_ADDRESS",
    "nvim",
    "--headless",
    "-i",
    "NONE",
    "-u",
    "NONE",
    "-S",
    session_file,
    "-c",
    inspect_command,
    "-c",
    "qa!",
  }, { text = true })
  :wait()
eq(restored.code, 0, "clean Neovim session restore")
local restored_state = vim.json.decode(table.concat(vim.fn.readfile(result_file), "\n"))
eq(restored_state.cwd, project, "restored cwd")
eq(restored_state.tabs, expected_tabs, "restored tabs")
eq(restored_state.windows, expected_windows, "restored split counts")
assert(vim.tbl_contains(restored_state.names, first_file), "first named buffer was not restored")
assert(vim.tbl_contains(restored_state.names, second_file), "second named buffer was not restored")

vim.fn.delete(vim.fs.joinpath(state_root, "snapshots", generation), "rf")
vim.fn.delete(project, "rf")

print("tmux persistence: ok")
