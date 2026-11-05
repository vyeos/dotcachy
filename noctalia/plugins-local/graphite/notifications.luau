--!nonstrict
-- Notifications key: a bell that nudges while there are unread notifications,
-- with the count in an inverted square badge. Click slides the notifications
-- drawer in from the right edge (and clears the count); right click toggles Do Not Disturb.
-- "Unread" = notifications that arrived since you last opened the panel from
-- this key (counted by the service from the session bus).

local S = require("./style.luau")
S.fonts()

local info = S.read("graphite.notif") or { unread = 0, dnd = false }
local hovered = false
local ringing = false
local nextNudge = 0

-- Inverted square badge. Always rendered so the key keeps its width: at zero
-- it is an empty, transparent placeholder of the same size.
local function countRing(n)
  local show = n > 0
  local text = if n > 99 then "99+" elseif show then tostring(n) else ""
  return ui.row({ height = 16, minWidth = 16, radius = 0, fill = if show then S.C.text else "#00000000", paddingH = 4, align = "center", justify = "center" }, {
    ui.label({ text = text, fontFamily = S.mono, fontSize = 10, color = "surface" }),
  })
end

local function render()
  local unread = info.unread or 0
  local glyph = if info.dnd then "bell-off" elseif ringing then "bell-ringing" else "bell"
  local kids = { S.glyph(glyph, { color = if unread > 0 then S.C.text else S.C.sub }) }
  local shown = if info.dnd then 0 else unread
  if shown > 0 then table.insert(kids, countRing(shown)) end
  local tip = if info.dnd then "Do Not Disturb is on"
    elseif unread > 0 then `{unread} new notification{if unread == 1 then "" else "s"}`
    else "No new notifications"
  barWidget.render(S.key({
    key = "notif",
    hovered = hovered,
    paddingH = 7,
    minWidth = 51, -- bell + gap + badge, so a count never changes the width
    gap = 5,
    tooltip = tip,
    onHover = function(st)
      hovered = st == "true"
      render()
    end,
    onClick = function()
      local open = noctalia.state.get("graphite.drawer") == "open"
      noctalia.state.set("graphite.drawer", if open then "closed" else "open")
    end,
  }, kids))
end

function onRightClick()
  S.setDnd(not info.dnd)
end

-- Nudge the bell every few seconds while something is unread.
function update()
  local unread = info.unread or 0
  if unread == 0 or info.dnd then
    if ringing then ringing = false; render() end
    return
  end
  local now = noctalia.nowMs()
  if ringing and now >= nextNudge - 3600 then
    ringing = false
    render()
  elseif not ringing and now >= nextNudge then
    ringing = true
    nextNudge = now + 4000
    render()
  end
end

S.watch("graphite.notif", function(v)
  if type(v) == "table" then
    local before = info.unread or 0
    info = v
    if (info.unread or 0) > before then nextNudge = 0 end -- ring right away for new ones
  end
  render()
end)

noctalia.setUpdateInterval(200)
render()
