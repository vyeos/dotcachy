--!nonstrict
-- Battery key: a drawn battery whose fill turns bright with a bright outline
-- below 20%, a bolt while charging, and the percentage in mono. Click opens the
-- power panel under the key. Hides itself on machines without a battery.

local S = require("./style.luau")
S.fonts()

local info = S.read("graphite.batt") or { present = true, pct = 0, status = "Unknown" }
local H = S.hover(function() render() end)

function render()
  if info.present == false then
    barWidget.setVisible(false)
    return
  end
  barWidget.setVisible(true)

  local pct = math.clamp(info.pct or 0, 0, 100)
  local charging = info.status == "Charging"
  local full = info.status == "Full" or info.status == "Not charging"
  local kids = S.batteryParts(info)

  local state = if charging then "charging" elseif full then "plugged in" else "on battery"
  barWidget.render(ui.row({ gap = 0, align = "center" }, { S.key({
    key = "batt",
    hovered = H.id ~= nil,
    gap = 6,
    tooltip = `Battery {pct}% · {state}`,
    onHover = H.fn("on"),
    onClick = function() noctalia.togglePanel("vyeos/graphite:power-panel") end,
  }, kids), S.divider("batt-div") }))
end

S.watch("graphite.batt", function(v)
  if type(v) == "table" then info = v end
  render()
end)

render()

-- noctalia msg plugin vyeos/graphite:battery all panel  (keybind: opens under this key)
function onIpc(event, _payload)
  if event == "panel" then noctalia.togglePanel("vyeos/graphite:power-panel-kb") end
end
