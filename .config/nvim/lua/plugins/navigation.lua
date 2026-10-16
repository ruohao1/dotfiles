local function oil_workspace()
  require("navigation.oil").toggle()
end

local function picker(name)
  return function()
    require("navigation.pickers")[name]()
  end
end

local function never()
  return false
end

return {
  {
    "nvim-mini/mini.icons",
    version = "*",
    lazy = true,
    main = "mini.icons",
    opts = {},
  },
  {
    "ibhagwan/fzf-lua",
    version = false,
    cmd = "FzfLua",
    init = function()
      require("clipboard.history").setup()
      local pins = require("navigation.location_pins")
      pins.setup()
      for _, mapping in ipairs({
        { "<leader>ha", pins.add, "Add line pin" },
        { "<leader>hh", pins.find, "Find line pins" },
        { "<leader>hd", pins.delete_current, "Delete current line pin" },
        { "<leader>hc", pins.clear, "Clear session line pins" },
      }) do
        vim.keymap.set("n", mapping[1], mapping[2], { desc = mapping[3] })
      end
    end,
    dependencies = { "nvim-mini/mini.icons" },
    keys = {
      { "<leader>ff", picker("files"), desc = "Find files" },
      { "<leader>fg", picker("grep"), desc = "Live grep" },
      { "<leader>fb", picker("buffers"), desc = "Find buffers" },
      { "<leader>fr", picker("recent"), desc = "Recent files" },
      { "<leader>fh", picker("help"), desc = "Help tags" },
      { "<leader>fl", picker("lsp_locations"), desc = "LSP locations" },
      { "<leader>fs", picker("document_symbols"), desc = "Document symbols" },
      { "<leader>fS", picker("workspace_symbols"), desc = "Workspace symbols" },
      { "<leader>fd", picker("document_diagnostics"), desc = "Document diagnostics" },
      { "<leader>fD", picker("all_diagnostics"), desc = "All diagnostics" },
      { "<leader>p", picker("clipboard_history"), mode = { "n", "x" }, desc = "Paste history" },
    },
    opts = function()
      local actions = require("fzf-lua.actions")

      return {
        [1] = "border-fused",
        defaults = { file_icons = "mini" },
        files = { hidden = true, no_ignore = false, previewer = true },
        keymap = {
          builtin = {
            ["<F1>"] = "toggle-help",
            ["<F2>"] = "toggle-fullscreen",
            ["<F3>"] = "toggle-preview-wrap",
            ["<F4>"] = "toggle-preview",
            ["<F5>"] = "toggle-preview-cw",
            ["<F6>"] = "toggle-preview-behavior",
            ["<F7>"] = "toggle-preview-ts-ctx",
            ["<F8>"] = "preview-ts-ctx-dec",
            ["<F9>"] = "preview-ts-ctx-inc",
            ["<S-Left>"] = "preview-reset",
            ["<S-down>"] = "preview-page-down",
            ["<S-up>"] = "preview-page-up",
          },
          fzf = {
            ["ctrl-z"] = "abort",
            ["ctrl-u"] = "unix-line-discard",
            ["ctrl-f"] = "half-page-down",
            ["ctrl-b"] = "half-page-up",
            ["ctrl-a"] = "beginning-of-line",
            ["ctrl-e"] = "end-of-line",
            ["f3"] = "toggle-preview-wrap",
            ["f4"] = "toggle-preview",
            ["shift-down"] = "preview-page-down",
            ["shift-up"] = "preview-page-up",
          },
        },
        actions = {
          files = {
            enter = actions.file_edit,
            ["ctrl-s"] = actions.file_split,
            ["ctrl-v"] = actions.file_vsplit,
            ["ctrl-t"] = actions.file_tabedit,
          },
        },
        buffers = { actions = { ["ctrl-x"] = false } },
        helptags = {
          actions = {
            enter = actions.help_curwin,
            ["ctrl-s"] = actions.help,
            ["ctrl-v"] = actions.help_vert,
            ["ctrl-t"] = actions.help_tab,
          },
        },
      }
    end,
  },
  {
    "stevearc/oil.nvim",
    version = false,
    lazy = false,
    dependencies = { "nvim-mini/mini.icons" },
    keys = {
      { "<leader><Tab>", oil_workspace, mode = "n", desc = "Toggle Oil workspace" },
    },
    opts = {
      default_file_explorer = true,
      columns = { "icon" },
      delete_to_trash = true,
      skip_confirm_for_simple_edits = true,
      prompt_save_on_select_new_entry = true,
      lsp_file_methods = {
        enabled = true,
        timeout_ms = 1000,
        autosave_changes = false,
      },
      watch_for_changes = false,
      use_default_keymaps = true,
      float = { border = "rounded" },
      keymaps_help = { border = "rounded" },
      keymaps = { ["g\\"] = false },
      view_options = { show_hidden = false },
      git = { add = never, mv = never, rm = never },
    },
  },
}
