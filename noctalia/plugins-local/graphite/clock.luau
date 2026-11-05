--!nonstrict
-- Clock: time and date pressed straight into the bar with no key, set in mono.
-- Click opens the calendar, right click the control center; the tooltip carries
-- the full date.

local S = require("./style.luau")
S.fonts()

local stamp = nil

local function render()
  local now = os.time()
  stamp = noctalia.formatTime("%Y%m%d%H%M", now)
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
    ui.label({ text = noctalia.formatTime("%H:%M", now), fontFamily = S.mono, fontSize = S.FS.xl, color = S.C.text }),
    ui.label({ text = string.upper(noctalia.formatTime("%a %d %b", now)), fontFamily = S.mono, fontSize = S.FS.sm, color = S.C.dim }),
  }))
end

function onRightClick()
  noctalia.togglePanel("vyeos/graphite:cc")
end

-- Redraw only when the minute changes. Waking at the boundary keeps it exact; the
-- cap is how late it can be after a suspend, when timers do not run.
local MAX_SLEEP_MS = 5000
function update()
  local now = os.time()
  noctalia.setUpdateInterval(math.clamp((60 - now % 60) * 1000, 1000, MAX_SLEEP_MS))
  if noctalia.formatTime("%Y%m%d%H%M", now) ~= stamp then render() end
end

noctalia.setUpdateInterval(1000)
render()

-- noctalia msg plugin vyeos/graphite:clock all panel  (keybind: opens under this key)
function onIpc(event, _payload)
  if event == "panel" then noctalia.togglePanel("vyeos/graphite:cc") end
  if event == "calendar" then noctalia.togglePanel("vyeos/graphite:calendar") end
end
