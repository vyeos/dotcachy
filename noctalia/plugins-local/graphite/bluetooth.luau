--!nonstrict
-- Bluetooth key: off / on / connected glyph, connected devices in the tooltip.
-- Click opens the Bluetooth panel under the key, right click toggles the radio.

local S = require("./style.luau")
S.fonts()

local info = S.read("graphite.bt") or { powered = false, devices = {} }
local H = S.hover(function() render() end)

function render()
  local devices = info.devices or {}
  local glyph = if not info.powered then "bluetooth-off" elseif #devices > 0 then "bluetooth-connected" else "bluetooth"
  local tip = if not info.powered then "Bluetooth off"
    elseif #devices > 0 then "Connected: " .. table.concat(devices, ", ")
    else "Bluetooth on · nothing connected"
  barWidget.render(S.key({
    key = "bt",
    hovered = H.id ~= nil,
    paddingH = 7,
    tooltip = tip,
    onHover = H.fn("on"),
    onClick = function() noctalia.togglePanel("vyeos/graphite:bluetooth-panel") end,
  }, {
    S.glyph(glyph, { color = if info.powered then S.C.sub else S.C.dim }),
  }))
end

function onRightClick()
  S.svc("bt")
end

S.watch("graphite.bt", function(v)
  if type(v) == "table" then info = v end
  render()
end)

render()

-- noctalia msg plugin vyeos/graphite:bluetooth all panel  (keybind: opens under this key)
function onIpc(event, _payload)
  if event == "panel" then noctalia.togglePanel("vyeos/graphite:bluetooth-panel-kb") end
end
