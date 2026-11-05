--!nonstrict
-- Wi-Fi key: signal glyph, network name in the tooltip. Click opens the Wi-Fi
-- panel under the key; right click toggles the radio.

local S = require("./style.luau")
S.fonts()

local info = S.read("graphite.wifi") or {}
local hovered = false

local function glyph()
  if info.wired then return "network" end
  if not info.radio then return "wifi-off" end
  if not info.connected then return "wifi-0" end
  local s = info.signal or 0
  if s >= 67 then return "wifi" elseif s >= 34 then return "wifi-2" end
  return "wifi-1"
end

local function tooltip()
  if info.wired then return "Wired connection" end
  if not info.radio then return "Wi-Fi off" end
  if not info.connected then return "Wi-Fi on · not connected" end
  return `{info.ssid} · {info.signal}%`
end

local function render()
  barWidget.render(S.key({
    key = "wifi",
    hovered = hovered,
    paddingH = 7,
    tooltip = tooltip(),
    onHover = function(state)
      hovered = state == "true"
      render()
    end,
    onClick = function() noctalia.togglePanel("vyeos/graphite:wifi-panel") end,
  }, {
    S.glyph(glyph(), { color = if info.connected or info.wired then S.C.sub else S.C.dim }),
  }))
end

function onRightClick()
  S.svc("wifi")
end

S.watch("graphite.wifi", function(v)
  if type(v) == "table" then info = v end
  render()
end)

render()

-- noctalia msg plugin vyeos/graphite:wifi all panel  (keybind: opens under the key)
function onIpc(event, _payload)
  if event == "panel" then noctalia.togglePanel("vyeos/graphite:wifi-panel") end
end
