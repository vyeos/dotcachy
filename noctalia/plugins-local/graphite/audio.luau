--!nonstrict
-- Audio key: speaker glyph, same as the slider in the audio panel. Click opens the audio
-- panel under the key, scroll changes the volume in 5% steps, right click mutes.

local S = require("./style.luau")
S.fonts()

local info = S.read("graphite.vol") or { pct = 0, muted = false }
local H = S.hover(function() render() end)

function render()
  barWidget.render(S.key({
    key = "audio",
    hovered = H.id ~= nil,
    paddingH = 7,
    tooltip = if info.muted then "Muted" else `Volume {info.pct or 0}%`,
    onHover = H.fn("on"),
    onClick = function() noctalia.togglePanel("vyeos/graphite:audio-panel") end,
  }, {
    S.glyph(S.volumeGlyph(info.pct, info.muted), { color = if info.muted then S.C.dim else S.C.sub }),
  }))
end

function onScroll(axis, steps)
  if axis ~= "vertical" then return end
  local s = tonumber(steps) or 0
  if s == 0 then return end
  -- negative steps = wheel up = louder
  local sign = if s < 0 then "+" else "-"
  S.run({ "wpctl", "set-volume", "-l", "1.0", "@DEFAULT_AUDIO_SINK@", `5%{sign}` })
end

function onRightClick()
  S.svc("mute", "out")
end

S.watch("graphite.vol", function(v)
  if type(v) == "table" then info = v end
  render()
end)

render()

-- noctalia msg plugin vyeos/graphite:audio all panel  (keybind: opens under this key)
function onIpc(event, _payload)
  if event == "panel" then noctalia.togglePanel("vyeos/graphite:audio-panel-kb") end
end
