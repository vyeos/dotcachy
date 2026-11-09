--!nonstrict
-- Lock screen battery: the bar's readout on its own, fed by the service's
-- graphite.batt state. Draws nothing on machines without a battery.

local S = require("./style.luau")
S.fonts()

local info = S.read("graphite.batt") or { present = true, pct = 0, status = "Unknown" }

local function render()
  local kids = if info.present == false then {} else S.batteryParts(info)
  desktopWidget.render(ui.row({ gap = 6, align = "center" }, kids))
end

S.watch("graphite.batt", function(v)
  if type(v) == "table" then info = v end
  render()
end)

render()
