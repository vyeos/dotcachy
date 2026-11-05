--!nonstrict
-- GPU key, right of audio: a chip glyph that shows the graphics mode and whether
-- the NVIDIA card is awake. Click opens the GPU panel under the key.

local S = require("./style.luau")
S.fonts()

local info = S.read("graphite.gpu") or {}
local hovered = false

local function look()
  if info.mode == "Integrated" then return "cpu-off", S.C.dim end
  if info.mode == "AsusMuxDgpu" or info.power == "active" then return "cpu", S.C.text end
  if info.mode == "Hybrid" then return "cpu", S.C.sub end
  return "cpu", S.C.dim
end

local function tip()
  if info.mode == "Integrated" then return "Integrated: NVIDIA off" end
  if info.mode == "AsusMuxDgpu" then return "Dedicated: NVIDIA only" end
  if info.mode == "Hybrid" then
    return if info.power == "active" then "Hybrid: NVIDIA awake" else "Hybrid: NVIDIA asleep"
  end
  return "Graphics mode unknown"
end

local function render()
  local glyph, color = look()
  barWidget.render(S.key({
    key = "gpu",
    hovered = hovered,
    paddingH = 7,
    tooltip = tip(),
    onHover = function(state)
      hovered = state == "true"
      render()
    end,
    onClick = function() noctalia.togglePanel("vyeos/graphite:gpu-panel") end,
  }, {
    S.glyph(glyph, { color = color }),
  }))
end

S.watch("graphite.gpu", function(v)
  if type(v) == "table" then info = v end
  render()
end)

render()

-- noctalia msg plugin vyeos/graphite:gpu all panel  (opens under this key)
function onIpc(event, _payload)
  if event == "panel" then noctalia.togglePanel("vyeos/graphite:gpu-panel") end
end
