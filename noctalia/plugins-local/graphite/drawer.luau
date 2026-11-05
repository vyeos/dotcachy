--!nonstrict
-- Notifications drawer: a full-height layer that slides in from the right
-- screen edge under the bar. Lists the captured notification history (newest
-- first) with per-item dismiss, Clear all, and a Do Not Disturb switch.
-- Opened by the bell (graphite.drawer = "open"); this script slides itself in
-- on load and slides out before hiding when the state turns "closed".

local S = require("./style.luau")
S.fonts()

local W = 380
local GAP = 6
local SLIDE_MS = 220

local list = S.read("graphite.notifs") or {}
local info = S.read("graphite.notif") or { dnd = false }
local hovered = nil

-- slide state: dir 1 = sliding in, -1 = sliding out, 0 = still
local t = 0
local dir = 1

local function barThickness()
  return tonumber(noctalia.getSetting("bar.default.thickness")) or 38
end

local function place(p)
  local e = 1 - (1 - p) ^ 3 -- ease out cubic
  local right = math.floor(-(W + 20) + (W + 20 + GAP) * e + 0.5)
  noctalia.layer.configure("notifs", {
    margins = { top = barThickness() + GAP, right = right, bottom = GAP },
  })
end

local function ago(ts)
  local d = math.max(0, os.time() - (ts or 0))
  if d < 60 then return "now" end
  if d < 3600 then return `{d // 60}m` end
  if d < 86400 then return `{d // 3600}h` end
  return `{d // 86400}d`
end

local function closeDrawer()
  noctalia.state.set("graphite.drawer", "closed")
end

local function card(n)
  local isHover = hovered == n.id
  local kids = {
    ui.row({ align = "center", gap = 8 }, {
      S.caption(if (n.app or "") ~= "" then n.app else "notification", S.C.sub),
      ui.spacer({ flexGrow = 1 }),
      S.caption(ago(n.t)),
      ui.button({ glyph = "x", variant = "ghost", controlSize = "sm", tooltip = "Dismiss",
        opacity = if isHover then 1 else 0.35,
        onClick = function() noctalia.state.set("graphite.notifCmd", `dismiss:{n.id}:{noctalia.nowMs()}`) end }),
    }),
  }
  if (n.summary or "") ~= "" then
    table.insert(kids, ui.label({ text = n.summary, fontFamily = S.sans, fontSize = 13.5, color = S.C.text, maxLines = 2, maxWidth = W - 60 }))
  end
  if (n.body or "") ~= "" then
    table.insert(kids, ui.label({ text = n.body, fontFamily = S.sans, fontSize = 12.5, color = S.C.sub, maxLines = 4, maxWidth = W - 60 }))
  end
  return ui.column({
    key = `n-{n.id}`,
    gap = 3,
    paddingH = 12,
    paddingV = 10,
    radius = 0,
    fill = if isHover then S.C.keyHover else S.C.key,
    align = "stretch",
    onHover = function(st)
      hovered = if st == "true" then n.id elseif hovered == n.id then nil else hovered
      render()
    end,
  }, kids)
end

function render()
  local items = {}
  if #list == 0 then
    table.insert(items, ui.column({ height = 220, align = "center", justify = "center", gap = 10 }, {
      ui.glyph({ name = "bell-off", size = 28, color = S.C.dim }),
      ui.label({ text = "No notifications", fontFamily = S.sans, color = S.C.dim }),
    }))
  else
    for _, n in list do table.insert(items, card(n)) end
  end

  layer.render(ui.column({
    flexGrow = 1,
    gap = 12,
    padding = 14,
    radius = 0,
    fill = S.C.pressed,
    border = S.C.edge,
    borderWidth = 1,
    align = "stretch",
  }, {
    S.header("bell", "Notifications", {
      S.caption(`{#list}`),
      ui.button({ glyph = "chevron-right", variant = "ghost", tooltip = "Close", onClick = closeDrawer }),
    }),
    S.hline("h1"),
    ui.scroll({ flexGrow = 1, gap = 6 }, items),
    S.hline("h2"),
    ui.row({ align = "center", gap = 10 }, {
      ui.glyph({ name = "bell-z", size = 15, color = S.C.sub }),
      ui.label({ text = "Do not disturb", fontFamily = S.sans, fontSize = 13, color = S.C.sub, flexGrow = 1 }),
      ui.toggle({ checked = info.dnd == true, onChange = function(v)
        local want = v == "true"
        if want == (info.dnd == true) then return end -- echo of a programmatic change
        info.dnd = want
        S.setDnd(want)
        render()
      end }),
    }),
    ui.button({ text = "Clear all", glyph = "trash", variant = "outline", enabled = #list > 0,
      onClick = function()
        -- clear the drawer's history and Noctalia's own (pop-ups and history), then slide away
        noctalia.state.set("graphite.notifCmd", `clear:{noctalia.nowMs()}`)
        S.run({ "noctalia", "msg", "notification-clear-active" })
        S.run({ "noctalia", "msg", "notification-clear-history" })
        closeDrawer()
      end }),
  }))
end

function onFrameTick(deltaMs)
  if dir == 0 then return end
  t += (tonumber(deltaMs) or 16) * dir
  if t >= SLIDE_MS then
    t = SLIDE_MS
    dir = 0
    layer.setNeedsFrameTick(false)
  elseif t <= 0 then
    t = 0
    dir = 0
    layer.setNeedsFrameTick(false)
    noctalia.layer.hide("notifs")
    return
  end
  place(t / SLIDE_MS)
end

S.watch("graphite.notifs", function(v)
  list = if type(v) == "table" then v else {}
  render()
end)
S.watch("graphite.notif", function(v)
  if type(v) == "table" then info = v end
  render()
end)
noctalia.state.watch("graphite.drawer", function(v)
  if v == "closed" and dir ~= -1 then
    dir = -1
    layer.setNeedsFrameTick(true)
  elseif v == "open" and dir ~= 1 then
    dir = 1
    layer.setNeedsFrameTick(true)
  end
end)

-- relative times tick over while the drawer is up
function onIpc(event, _payload)
  if event == "close" then closeDrawer() end
end

render()
dir = 1
t = 0
layer.setNeedsFrameTick(true)
