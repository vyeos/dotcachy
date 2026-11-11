-- Use the local Graphite colorscheme (colors/graphite.lua) everywhere,
-- including lualine, which picks its theme from the active colorscheme.
return {
  { "LazyVim/LazyVim", opts = { colorscheme = "graphite" } },
  {
    "nvim-lualine/lualine.nvim",
    opts = function(_, opts)
      local g = { bg = "#151618", raised = "#26282b", fg = "#d3d6d9", dim = "#7a7f86", hi = "#ededeb", ink = "#151618" }
      local section = function(a_bg)
        return {
          a = { fg = g.ink, bg = a_bg, gui = "bold" },
          b = { fg = g.fg, bg = g.raised },
          c = { fg = g.dim, bg = g.bg },
        }
      end
      opts.options = opts.options or {}
      opts.options.theme = {
        normal = section(g.fg),
        insert = section(g.hi),
        visual = section("#a6abb1"),
        replace = section("#c9a3a0"),
        command = section(g.hi),
        inactive = section(g.dim),
      }
      opts.options.section_separators = { left = "", right = "" }
      opts.options.component_separators = { left = "│", right = "│" }
    end,
  },
}
