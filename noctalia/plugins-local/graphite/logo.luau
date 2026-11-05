--!nonstrict
-- Logo: an etched hexagon with a solid core. Click opens the launcher and turns
-- the hexagon a sixth; right click opens the control center.

local S = require("./style.luau")
S.fonts()

local frame = 0
local spinning = false
local H = S.hover(function() render() end)

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
      end,
    }, {
      ui.image({ path = `assets/logo-{frame}.svg`, width = 18, height = 18, fit = "contain" }),
    }),
    S.divider("logo-div"),
  }))
end

function update()
  if not spinning then return end
  frame += 1
  if frame > 3 then
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
