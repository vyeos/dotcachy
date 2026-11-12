--!nonstrict
-- Lock screen mark: the pixel V from the bar and fastfetch, larger, above the clock.

local S = require("./style.luau")
S.fonts()

local CELL = 9                 -- one pixel of the V: the mark is 45 x 45
local ROWS = { { 0, 4 }, { 0, 4 }, { 0, 4 }, { 1, 3 }, { 2 } }

local function render()
  local rows = {}
  for _, cols in ROWS do
    local kids, x = {}, 0
    for _, col in cols do
      local left = col * CELL
      if left > x then table.insert(kids, ui.box({ width = left - x, height = CELL, fill = S.C.clear })) end
      table.insert(kids, ui.box({ width = CELL, height = CELL, radius = 0, fill = S.C.text }))
      x = left + CELL
    end
    table.insert(rows, ui.row({ gap = 0, height = CELL }, kids))
  end
  desktopWidget.render(ui.column({ gap = 0, width = 5 * CELL }, rows))
end

render()
