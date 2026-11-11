--!nonstrict
-- Logo: the pixel V, five squares of the workspace kind set in a V. Click opens
-- the launcher, and the squares light up one at a time from left to right; right
-- click opens the control center.

local S = require("./style.luau")
S.fonts()

local CELL, STEP = 4, 5      -- square size and pitch: the V is 24 x 14
-- column of each square, row by row, so the light can sweep left to right
local ROWS = { { 0, 4 }, { 1, 3 }, { 2 } }
local FRAMES = 6             -- dim, then columns 0..4 lit one per frame

local frame = 0              -- 0 = at rest (all lit)
local spinning = false
local H = S.hover(function() render() end)

local function lit(col)
  if not spinning then return true end
  return col < frame
end

local function mark()
  local rows = {}
  for _, cols in ROWS do
    local kids, x = {}, 0
    for _, col in cols do
      local left = col * STEP
      if left > x then table.insert(kids, ui.box({ width = left - x, height = CELL, fill = S.C.clear })) end
      table.insert(kids, ui.box({ width = CELL, height = CELL, radius = 0, fill = if lit(col) then S.C.text else S.C.faint }))
      x = left + CELL
    end
    table.insert(rows, ui.row({ gap = 0, height = CELL }, kids))
  end
  return ui.column({ gap = STEP - CELL, width = 4 * STEP + CELL }, rows)
end

function render()
  barWidget.render(ui.row({ gap = 0, align = "center" }, {
    S.key({
      key = "logo",
      hovered = H.id ~= nil,
      paddingH = 7,
      onHover = H.fn("on"),
      onClick = function()
        noctalia.togglePanel("vyeos/graphite:launcher")
        spinning = true
        frame = 0
        noctalia.setUpdateInterval(45)
        render()
      end,
    }, { mark() }),
    S.divider("logo-div"),
  }))
end

function update()
  if not spinning then return end
  frame += 1
  if frame >= FRAMES then
    frame = 0
    spinning = false
    noctalia.setUpdateInterval(60000)
  end
  render()
end

function onRightClick()
  noctalia.togglePanel("vyeos/graphite:cc")
end

noctalia.setUpdateInterval(60000)
render()
