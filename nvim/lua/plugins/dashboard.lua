-- Start screen: the vyeos name in block letters in place of the LazyVim logo.
-- The shortcut menu and the startup line below it are LazyVim's own. A window
-- narrower than the big name (58 columns) gets the small three-row name instead,
-- the same pair fastfetch uses. Chosen when Neovim starts.
local BIG = {
  "██      ██  ██      ██  ██████████    ██████      ████████",
  "██      ██    ██  ██    ██          ██      ██  ██        ",
  "██      ██      ██      ████████    ██      ██    ██████  ",
  "  ██  ██        ██      ██          ██      ██          ██",
  "    ██          ██      ██████████    ██████    ████████  ",
}
local SMALL = {
  "█   █ ▀▄ ▄▀ █▀▀▀▀ ▄▀▀▀▄ ▄▀▀▀▀",
  "▀▄ ▄▀   █   █▀▀▀  █   █  ▀▀▀▄",
  "  ▀     ▀   ▀▀▀▀▀  ▀▀▀  ▀▀▀▀ ",
}

return {
  {
    "folke/snacks.nvim",
    opts = function(_, opts)
      opts.dashboard = opts.dashboard or {}
      opts.dashboard.preset = opts.dashboard.preset or {}
      local lines = vim.o.columns >= 64 and BIG or SMALL
      opts.dashboard.preset.header = table.concat(lines, "\n")
    end,
  },
}
