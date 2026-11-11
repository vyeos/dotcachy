--!nonstrict
-- Logo: the pixel V, drawn on the same 5 x 5 grid as the fastfetch V (vyeos-v.txt):
-- three rows of two uprights, then the two halves of the point, then the tip.
-- Hovering lights the V up one column at a time from left to right; click opens
-- the launcher, right click the control center.

local S = require("./style.luau")
S.fonts()

local CELL = 4               -- one pixel of the V: the mark is 20 x 20
-- lit columns of each row, top to bottom
local ROWS = { { 0, 4 }, { 0, 4 }, { 0, 4 }, { 1, 3 }, { 2 } }
local FRAMES = 6             -- dim, then columns 0..4 lit one per frame

local frame = 0              -- 0 = at rest (all lit)
local spinning = false
local H = S.hover(function() render() end)
local hoverFn = H.fn("on")

local function lit(col)
  if not spinning then return true end
  return col < frame
end

local function mark()
  local rows = {}
  for _, cols in ROWS do
    local kids, x = {}, 0
    for _, col in cols do
      local left = col * CELL
      if left > x then table.insert(kids, ui.box({ width = left - x, height = CELL, fill = S.C.clear })) end
      table.insert(kids, ui.box({ width = CELL, height = CELL, radius = 0, fill = if lit(col) then S.C.text else S.C.faint }))
      x = left + CELL
    end
    table.insert(rows, ui.row({ gap = 0, height = CELL }, kids))
  end
  return ui.column({ gap = 0, width = 5 * CELL }, rows)
end

function render()
  barWidget.render(ui.row({ gap = 0, align = "center" }, {
    S.key({
      key = "logo",
      hovered = H.id ~= nil,
      paddingH = 7,
      onHover = function(st)
        hoverFn(st)
        -- sweep the light across the V each time the pointer arrives
        if st == "true" and not spinning then startSweep() end
      end,
      onClick = function()
        noctalia.togglePanel("vyeos/graphite:launcher")
      end,
    }, { mark() }),
    S.divider("logo-div"),
  }))
end

-- The sweep is clocked by one short process that prints a line every 45 ms: bar
-- widgets have no frame ticks or timers, and update() runs at most about once a second.
local TICKS = "for i in 1 2 3 4 5 6; do sleep 0.045; echo $i; done"

function startSweep()
  spinning = true
  frame = 0
  render()
  noctalia.runStream(TICKS, function(line)
    local f = tonumber(line)
    if not f or not spinning then return end
    frame = f
    if frame >= FRAMES then
      frame = 0
      spinning = false
    end
    render()
  end)
end

function onRightClick()
  noctalia.togglePanel("vyeos/graphite:cc")
end

render()
