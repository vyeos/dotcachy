--!nonstrict
-- Status key: a coffee cup while caffeine keeps the screen awake and a moon
-- while night light is forced on. Each glyph is its own key; clicking one turns
-- it off. With both off the widget (and its divider) disappears.

local S = require("./style.luau")
S.fonts()

local caffeine = noctalia.state.get("graphite.caffeine") == true
local night = noctalia.state.get("graphite.night") == true
local H = S.hover(function() render() end)

local function icon(id, glyph)
  return S.key({
    key = id,
    hovered = H.id == id,
    paddingH = 7,
    onHover = H.fn(id),
    onClick = function() S.svc(id, "off") end,
  }, { S.glyph(glyph, { color = S.C.text }) })
end

function render()
  if not caffeine and not night then
    barWidget.setVisible(false)
    return
  end
  barWidget.setVisible(true)
  local kids = {}
  if caffeine then table.insert(kids, icon("caffeine", "coffee")) end
  if night then table.insert(kids, icon("night", "moon")) end
  table.insert(kids, S.divider("status-div"))
  barWidget.render(ui.row({ gap = 0, align = "center" }, kids))
end

S.watch("graphite.caffeine", function(v) caffeine = v == true; render() end)
S.watch("graphite.night", function(v) night = v == true; render() end)

render()
