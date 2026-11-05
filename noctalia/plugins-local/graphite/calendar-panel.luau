--!nonstrict
-- Calendar: one month as a flat square grid, weeks starting Monday. Today is
-- inverted (light face, dark ink) like the active workspace; days from the
-- neighbouring months are faint. Opened by right-clicking the clock.

local S = require("./style.luau")
S.fonts()

local MONTHS = { "January", "February", "March", "April", "May", "June", "July",
  "August", "September", "October", "November", "December" }
local WEEKDAYS = { "MO", "TU", "WE", "TH", "FR", "SA", "SU" }
local CELL = 38

local today = { y = 2000, m = 1, d = 1 }
local view = { y = 2000, m = 1 }
local hovered = nil

local function readToday()
  local s = noctalia.formatTime("%Y-%m-%d", os.time())
  local y, m, d = string.match(s, "^(%d+)-(%d+)-(%d+)$")
  today = { y = tonumber(y), m = tonumber(m), d = tonumber(d) }
end

local function isLeap(y) return (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0 end

local function daysIn(y, m)
  if m == 2 then return if isLeap(y) then 29 else 28 end
  if m == 4 or m == 6 or m == 9 or m == 11 then return 30 end
  return 31
end

-- 0 = Monday … 6 = Sunday (Sakamoto's method).
local function weekday(y, m, d)
  local t = { 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 }
  if m < 3 then y -= 1 end
  local w = (y + y // 4 - y // 100 + y // 400 + t[m] + d) % 7 -- 0 = Sunday
  return (w + 6) % 7
end

local function shift(dm)
  local i = view.y * 12 + (view.m - 1) + dm
  view.y, view.m = i // 12, (i % 12) + 1
  render()
end

local function hoverFn(id)
  return function(st)
    hovered = if st == "true" then id elseif hovered == id then nil else hovered
    render()
  end
end

local function navKey(id, glyph, onClick)
  return S.key({ key = id, hovered = hovered == id, height = 30, paddingH = 6, onHover = hoverFn(id), onClick = onClick }, {
    S.glyph(glyph, { size = 16 }),
  })
end

local function cell(key, text, color, fill)
  return ui.row({ key = key, width = CELL, height = CELL - 4, radius = 0, fill = fill or "#00000000", align = "center", justify = "center" }, {
    ui.label({ text = text, fontFamily = S.mono, fontSize = 13, color = color }),
  })
end

function render()
  local y, m = view.y, view.m
  local isCurrent = y == today.y and m == today.m

  local title = ui.row({ align = "center", gap = 4, height = 34 }, {
    ui.label({ text = MONTHS[m], fontFamily = S.sans, fontSize = 16, color = S.C.text }),
    ui.label({ text = tostring(y), fontFamily = S.mono, fontSize = 13, color = S.C.dim, flexGrow = 1 }),
    if isCurrent then ui.spacer({ width = 1 }) else S.key({ key = "today", hovered = hovered == "today", height = 30, paddingH = 8,
      onHover = hoverFn("today"), onClick = function() view.y, view.m = today.y, today.m; render() end }, {
      S.caption("Today", S.C.sub),
    }),
    navKey("prev", "chevron-left", function() shift(-1) end),
    navKey("next", "chevron-right", function() shift(1) end),
  })

  local head = {}
  for i, w in WEEKDAYS do
    table.insert(head, cell("wd" .. i, w, if i >= 6 then S.C.faint else S.C.dim))
  end

  local rows = { title, S.hline("cal-h"), ui.row({ gap = 0 }, head) }

  local lead = weekday(y, m, 1)
  local py, pm = if m == 1 then y - 1 else y, if m == 1 then 12 else m - 1
  local prevDays = daysIn(py, pm)
  local n = daysIn(y, m)
  local weeks = 6 -- fixed height, so the panel never jumps between months
  for w = 0, weeks - 1 do
    local kids = {}
    for c = 0, 6 do
      local idx = w * 7 + c - lead + 1
      local key = `c{w}-{c}`
      if idx < 1 then
        table.insert(kids, cell(key, tostring(prevDays + idx), S.C.faint))
      elseif idx > n then
        table.insert(kids, cell(key, tostring(idx - n), S.C.faint))
      elseif isCurrent and idx == today.d then
        table.insert(kids, cell(key, tostring(idx), "surface", S.C.text))
      else
        table.insert(kids, cell(key, tostring(idx), if c >= 5 then S.C.sub else S.C.text))
      end
    end
    table.insert(rows, ui.row({ gap = 0 }, kids))
  end

  panel.render(ui.column({ flexGrow = 1, gap = 4, align = "stretch" }, rows))
end

function onOpen(_context)
  readToday()
  view.y, view.m = today.y, today.m
  hovered = nil
  render()
end

readToday()
view.y, view.m = today.y, today.m
render()
