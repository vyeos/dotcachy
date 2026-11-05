--!nonstrict
-- Status key: a coffee cup while caffeine keeps the screen awake and a moon
-- while night light is forced on. Each glyph is its own key; clicking one turns
-- it off. With both off the widget (and its divider) disappears.

local S = require("./style.luau")
S.fonts()

local caffeine = noctalia.state.get("graphite.caffeine") == true
local night = noctalia.state.get("graphite.night") == true
local hovered = nil

local function set(key, on)
  noctalia.runAsync({ "noctalia", "msg", "plugin", "vyeos/graphite:service", "all", key, if on then "on" else "off" })
end

local function icon(id, glyph)
  return S.key({
    key = id,
    hovered = hovered == id,
    paddingH = 7,
    onHover = function(st)
      hovered = if st == "true" then id elseif hovered == id then nil else hovered
      render()
    end,
    onClick = function() set(id, false) end,
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
