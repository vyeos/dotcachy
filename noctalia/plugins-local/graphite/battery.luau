--!nonstrict
-- Battery key: a drawn battery whose fill turns bright with a bright outline
-- below 20%, a bolt while charging, and the percentage in mono. Click opens the
-- power panel under the key. Hides itself on machines without a battery.

local S = require("./style.luau")
S.fonts()

local info = S.read("graphite.batt") or { present = true, pct = 0, status = "Unknown" }
local hovered = false

local BODY_W, BODY_H, INNER_W = 24, 13, 19

local function render()
  if info.present == false then
    barWidget.setVisible(false)
    return
  end
  barWidget.setVisible(true)

  local pct = math.clamp(info.pct or 0, 0, 100)
  local charging = info.status == "Charging"
  local full = info.status == "Full" or info.status == "Not charging"
  local low = pct < 20 and not charging
  local fillW = math.max(1, math.floor(INNER_W * pct / 100 + 0.5))

  local fill = ui.box({ width = fillW, height = BODY_H - 6, radius = 0, fill = if low then S.C.text else S.C.sub })

  local battery = ui.row({ align = "center", gap = 1 }, {
    ui.row({
      width = BODY_W,
      height = BODY_H,
      radius = 0,
      border = if low then S.C.text else S.C.sub,
      borderWidth = 1.5,
      padding = 2.5,
      align = "center",
    }, { fill, ui.spacer({ flexGrow = 1 }) }),
    ui.box({ width = 2, height = 5, radius = 0, fill = if low then S.C.text else S.C.sub }),
  })

  local kids = { battery }
  if charging then
    table.insert(kids, S.glyph("bolt", { size = 13, color = S.C.text }))
  end
  table.insert(kids, S.label(`{pct}%`, { font = S.mono, size = 12, color = if low then S.C.text else S.C.sub }))

  local state = if charging then "charging" elseif full then "plugged in" else "on battery"
  barWidget.render(ui.row({ gap = 0, align = "center" }, { S.key({
    key = "batt",
    hovered = hovered,
    gap = 6,
    tooltip = `Battery {pct}% · {state}`,
    onHover = function(st)
      hovered = st == "true"
      render()
    end,
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
  if event == "panel" then noctalia.togglePanel("vyeos/graphite:power-panel") end
end
