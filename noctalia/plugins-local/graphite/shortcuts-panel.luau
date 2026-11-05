--!nonstrict
-- Keyboard shortcuts (SUPER + CTRL + /): every Hyprland bind, grouped, with a
-- search line. binds.py reads ~/.config/hypr/config/binds.lua on each open, so
-- the list follows the config. Every word typed must appear in the action,
-- the keys or the group (so "ctrl c" or "screenshot" both work). Up/Down and
-- Page Up/Down move a selection (held keys repeat); a strip of category keys,
-- like the emoji picker's, jumps between groups on click or Tab / Shift+Tab.

local S = require("./style.luau")
S.fonts()

local ROW_H = 32

local dataDir = noctalia.pluginDataDir()
local outPath = if dataDir then dataDir .. "/binds.json" else nil
local script = (noctalia.pluginDir() or ".") .. "/binds.py"
local bindsLua = (noctalia.getenv("HOME") or "~") .. "/.config/hypr/config/binds.lua"

local binds = {}
local shown = {}
local query = ""
local opens = 0
local sel = 1
local H = S.hover(function() render() end)
local HCat = S.hover(function() render() end)

-- Short labels for the category strip; unknown groups use their own name.
local SHORT = {
  ["Window Management"] = "Windows", ["Apps & Shell"] = "Apps", ["Quick Toggles"] = "Toggles",
  ["Hardware Controls"] = "Hardware", ["Workspaces & Monitors"] = "Workspaces",
}
local groups = {} -- every group in file order: { name, first = index in shown or nil }

local function load()
  local raw = if outPath then noctalia.readFile(outPath) else nil
  local d = if raw then noctalia.json.decode(raw) else nil
  binds = {}
  if type(d) ~= "table" then return end
  for _, b in d do
    b.hay = string.lower(b.desc .. " " .. table.concat(b.keys, " ") .. " " .. b.group)
    table.insert(binds, b)
  end
end

function compute()
  shown = {}
  local words = {}
  for w in string.gmatch(string.lower(query), "%S+") do table.insert(words, w) end
  for _, b in binds do
    local ok = true
    for _, w in words do
      if not string.find(b.hay, w, 1, true) then ok = false; break end
    end
    if ok then table.insert(shown, b) end
  end
  groups = {}
  local byName = {}
  for _, b in binds do
    if not byName[b.group] then
      byName[b.group] = { name = b.group, first = nil }
      table.insert(groups, byName[b.group])
    end
  end
  for i, b in shown do
    local g = byName[b.group]
    if g.first == nil then g.first = i end
  end
  sel = math.clamp(sel, 1, math.max(1, #shown))
end

local function scan()
  if not outPath then return end
  noctalia.runAsync({ "python3", script, bindsLua, outPath }, function(r)
    if r.exitCode == 0 and noctalia.string.trim(r.stdout or "") ~= "fresh" then load(); compute(); render() end
  end, 10000)
end

-- A key cap: square, recessed into the panel, mono ink.
local function cap(text, onWell)
  return ui.row({ height = 22, minWidth = 22, paddingH = 7, radius = 0, fill = if onWell then S.C.key else S.C.well, align = "center", justify = "center" }, {
    ui.label({ text = text, fontFamily = S.mono, fontSize = S.FS.sm, color = S.C.text }),
  })
end

-- Row key as render() builds it: a group's first row lives in its "g" block.
local function keyOf(i)
  if i == 1 or (shown[i - 1] and shown[i - 1].group ~= shown[i].group) then return "g" .. i end
  return "b" .. i
end

-- Jump the selection to the first row of a group (in the current results);
-- the list scrolls just enough to show its title.
local function jump(g)
  if g and g.first then sel = g.first; H.id = nil; render() end
end

-- Category key: label over an underline that marks the selection's group.
-- Groups with no matching rows go faint and do nothing.
function catKey(g, cur)
  local active = g.name == cur
  local empty = g.first == nil
  local lit = active or (HCat.id == g.name and not empty)
  return ui.column({
    key = "cat-" .. g.name,
    height = 30, paddingH = 8, gap = 0, align = "center", justify = "end",
    fill = if HCat.id == g.name and not active and not empty then S.C.keyHover else S.C.clear,
    onClick = function() jump(g) end,
    onHover = HCat.fn(g.name),
  }, {
    ui.row({ flexGrow = 1, align = "center", justify = "center" }, {
      S.caption(SHORT[g.name] or g.name, if lit then S.C.text elseif empty then S.C.faint else S.C.dim),
    }),
    ui.box({ height = 2, width = 24, radius = 0, fill = if active then S.C.text else S.C.clear }),
  })
end

-- Rows sink into the well when selected; their caps lift to the key face so
-- they stay visible.
local function row(i, b)
  local isSel = sel == i
  local keys = {}
  for k, key in b.keys do
    if k > 1 then table.insert(keys, ui.label({ text = "+", fontFamily = S.mono, fontSize = S.FS.xs, color = S.C.faint })) end
    table.insert(keys, cap(key, isSel))
  end
  return S.item({
    key = "b" .. i,
    height = ROW_H,
    selected = isSel,
    hovered = H.id == i,
    onClick = function() sel = i; render() end,
    onHover = H.fn(i),
  }, {
    ui.label({ text = b.desc, fontFamily = S.sans, fontSize = S.FS.body, color = if isSel then S.C.text else S.C.sub, flexGrow = 1, maxWidth = 300, maxLines = 1 }),
    ui.row({ gap = 4, align = "center" }, keys),
  })
end

function render()
  local rows = {}
  local last = nil
  for i, b in shown do
    if b.group ~= last then
      last = b.group
      table.insert(rows, ui.column({ key = "g" .. i, gap = 0, align = "stretch" }, {
        ui.row({ paddingH = 10, height = 30, align = "end" }, { S.caption(b.group, S.C.dim) }),
        row(i, b),
      }))
    else
      table.insert(rows, row(i, b))
    end
  end
  local cur = if shown[sel] then shown[sel].group else nil
  local strip = {}
  for _, g in groups do table.insert(strip, catKey(g, cur)) end
  local reveal = if shown[sel] then keyOf(sel) else nil
  if #shown == 0 then
    table.insert(rows, ui.column({ paddingV = 60, align = "center" }, {
      S.caption(if #binds == 0 then "reading binds…" else "no matching shortcuts"),
    }))
  end
  panel.render(ui.column({ gap = 8, flexGrow = 1, align = "stretch" }, {
    S.search({ glyph = "keyboard", key = "q-" .. opens, value = query, placeholder = "Search shortcuts", count = #shown,
      onChange = function(v) query = v or ""; sel = 1; compute(); render() end }),
    ui.row({ gap = 0, align = "center", justify = "space_between" }, strip),
    S.hline("h1"),
    ui.scroll({ key = "list", flexGrow = 1, gap = 0, revealKey = reveal }, rows),
    S.hline("h2"),
    ui.row({ align = "center", gap = 14, height = 20 }, {
      S.caption("hypr/config/binds.lua"),
      ui.spacer({ flexGrow = 1 }),
      S.caption("↑↓ move"),
      S.caption("tab category"),
      S.caption("esc close"),
    }),
  }))
end

local function move(d)
  if #shown == 0 then return end
  sel = S.step(sel, d, #shown)
  H.id = nil
  render()
end

-- Next / previous group that has rows, wrapping around.
local function jumpGroup(d)
  if #shown == 0 then return end
  local cur = shown[sel].group
  local idx = 1
  for i, g in groups do if g.name == cur then idx = i end end
  for _ = 1, #groups do
    idx = ((idx - 1 + d) % #groups) + 1
    if groups[idx].first then jump(groups[idx]); return end
  end
end

local MOVES = { up = -1, down = 1, page_up = -10, page_down = 10 }
local R = S.repeater(function(k) move(MOVES[k]) end, { "up", "down", "page_up", "page_down" })
function onFrameTick(dt) R.tick(dt) end
function onKey(key, pressed)
  if R.key(key, pressed) then return end
  if pressed == false then return end
  local k = string.lower(tostring(key))
  if k == "tab" then jumpGroup(1)
  elseif k == "shift+tab" then jumpGroup(-1)
  end
end

-- Context (optional) names a group to open at, by short or full name:
-- noctalia msg panel-toggle vyeos/graphite:shortcuts utilities
function onOpen(context)
  R.stop()
  opens += 1
  sel = 1
  H.id = nil
  HCat.id = nil
  query = ""
  compute()
  render()
  local want = string.lower(tostring(context or ""))
  if want ~= "" then
    for _, g in groups do
      if string.lower(g.name) == want or string.lower(SHORT[g.name] or "") == want then jump(g) end
    end
  end
  scan() -- picks up binds changed since last time
end

load()
compute()
render()
