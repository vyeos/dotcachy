--!nonstrict
-- Clock: time and date pressed straight into the bar with no key, set in mono.
-- Click opens the calendar, right click the control center; the tooltip carries
-- the full date.

local S = require("./style.luau")
S.fonts()

local function render()
  local now = os.time()
  barWidget.render(ui.row({
    key = "clock",
    align = "center",
    gap = 12,
    paddingH = 14,
    onClick = function()
      noctalia.togglePanel("vyeos/graphite:calendar")
    end,
    tooltip = noctalia.formatTime("%A, %d %B %Y", now),
  }, {
    ui.label({ text = noctalia.formatTime("%H:%M", now), fontFamily = S.mono, fontSize = 15, color = S.C.text }),
    ui.label({ text = string.upper(noctalia.formatTime("%a %d %b", now)), fontFamily = S.mono, fontSize = 11, color = S.C.dim }),
  }))
end

function onRightClick()
  noctalia.togglePanel("vyeos/graphite:cc")
end

function update()
  render()
end

noctalia.setUpdateInterval(1000)
render()

-- noctalia msg plugin vyeos/graphite:clock all panel  (keybind: opens under this key)
function onIpc(event, _payload)
  if event == "panel" then noctalia.togglePanel("vyeos/graphite:cc") end
  if event == "calendar" then noctalia.togglePanel("vyeos/graphite:calendar") end
end
