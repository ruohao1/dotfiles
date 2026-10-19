return {
  {
    "folke/tokyonight.nvim",
    version = "v4.14.1",
    lazy = false,
    priority = 1000,
    opts = {
      style = "night",
      transparent = false,
      terminal_colors = true,
      on_highlights = function(highlights)
        highlights.MiniStarterCurrent = { link = "Visual" }
      end,
      styles = {
        comments = { italic = true },
        keywords = { italic = true },
        sidebars = "dark",
        floats = "dark",
      },
    },
    config = function(_, opts)
      require("tokyonight").setup(opts)
      vim.cmd.colorscheme("tokyonight-night")
    end,
  },
}
