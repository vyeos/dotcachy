--!nonstrict
-- Emoji picker (SUPER + .): a flat search line, a strip of category keys with
-- the active one underlined, and a square grid. Arrows move the selection
-- (sunk into the well), Enter or a click copies the emoji and closes.
-- Data: Noctalia's own emoji.json. Recents: pluginDataDir/emoji-recent.json.

local S = require("./style.luau")
S.fonts()

local COLS = 10
local CELL = 44
local GAP = 2
local MAX_RESULTS = 300
local MAX_RECENT = 30

local CATS = {
  { id = "recent", glyph = "clock", label = "Recent" },
  { id = "people", glyph = "mood-smile", label = "People" },
  { id = "animals", glyph = "paw", label = "Animals" },
  { id = "nature", glyph = "leaf", label = "Nature" },
  { id = "food", glyph = "apple", label = "Food" },
  { id = "activity", glyph = "ball-football", label = "Activity" },
  { id = "travel", glyph = "plane", label = "Travel" },
  { id = "objects", glyph = "bulb", label = "Objects" },
  { id = "symbols", glyph = "hash", label = "Symbols" },
  { id = "flags", glyph = "flag", label = "Flags" },
}

local all = {}
do
  local raw = noctalia.readFile("/usr/share/noctalia/assets/emoji.json")
  local d = if raw then noctalia.json.decode(raw) else nil
  if type(d) == "table" then
    for _, e in d do
      local hay = string.lower((e.name or "") .. " " .. table.concat(e.keywords or {}, " "))
      table.insert(all, { e = e.emoji, name = e.name or "", cat = e.category or "", hay = hay })
    end
  end
end
local byEmoji = {}
for _, x in all do byEmoji[x.e] = x end

local dataDir = noctalia.pluginDataDir()
local recentPath = if dataDir then dataDir .. "/emoji-recent.json" else nil
local recent = {}
if recentPath then
  local raw = noctalia.readFile(recentPath)
  local r = if raw then noctalia.json.decode(raw) else nil
  if type(r) == "table" then recent = r end
end

local query = ""
local cat = "people"
local sel = 1
local hovered = nil
local hoveredCat = nil
local shown = {}
local opens = 0

local function compute()
  shown = {}
  if query ~= "" then
    local terms = {}
    for w in string.gmatch(string.lower(query), "%S+") do table.insert(terms, w) end
    for _, x in all do
      local ok = true
      for _, t in terms do
        if not string.find(x.hay, t, 1, true) then ok = false; break end
      end
      if ok then
        table.insert(shown, x)
        if #shown >= MAX_RESULTS then break end
      end
    end
  elseif cat == "recent" then
    for _, e in recent do
      table.insert(shown, byEmoji[e] or { e = e, name = "", cat = "" })
    end
  else
    for _, x in all do
      if x.cat == cat then table.insert(shown, x) end
    end
  end
  sel = math.clamp(sel, 1, math.max(1, #shown))
end

local function pick(x)
  if not x then return end
  noctalia.copyToClipboard(x.e, "text/plain;charset=utf-8")
  local nr = { x.e }
  for _, e in recent do
    if e ~= x.e and #nr < MAX_RECENT then table.insert(nr, e) end
  end
  recent = nr
  if recentPath then noctalia.writeFile(recentPath, noctalia.json.encode(recent)) end
  panel.close()
end

local function catKey(c)
  local active = query == "" and cat == c.id
  local lit = active or hoveredCat == c.id
  return ui.column({
    key = "cat-" .. c.id,
    width = 40, height = 34, gap = 0, align = "center", justify = "end",
    fill = if hoveredCat == c.id and not active then S.C.keyHover else "#00000000",
    tooltip = nil,
    onClick = function()
      cat = c.id; sel = 1
      if query ~= "" then query = ""; opens += 1 end -- fresh, empty search field
      compute(); render()
    end,
    onHover = function(st)
      hoveredCat = if st == "true" then c.id elseif hoveredCat == c.id then nil else hoveredCat
      render()
    end,
  }, {
    ui.row({ flexGrow = 1, align = "center", justify = "center" }, {
      ui.glyph({ name = c.glyph, size = 17, color = if lit then S.C.text else S.C.dim }),
    }),
    ui.box({ width = 22, height = 2, radius = 0, fill = if active then S.C.text else "#00000000" }),
  })
end

local function cell(i, x)
  local isSel = sel == i
  return ui.row({
    key = "e-" .. i,
    width = CELL, height = CELL, radius = 0, align = "center", justify = "center",
    fill = if isSel then S.C.well elseif hovered == i then S.C.keyHover else "#00000000",
    onClick = function() pick(x) end,
    onHover = function(st)
      hovered = if st == "true" then i elseif hovered == i then nil else hovered
      render()
    end,
  }, {
    ui.label({ text = x.e, fontSize = 24, baseline = "pictographic" }),
  })
end

function render()
  local cats = {}
  for _, c in CATS do table.insert(cats, catKey(c)) end

  local rows = {}
  local row = {}
  for i, x in shown do
    table.insert(row, cell(i, x))
    if #row == COLS or i == #shown then
      table.insert(rows, ui.row({ key = "r-" .. i, gap = GAP, height = CELL }, row))
      row = {}
    end
  end
  if #shown == 0 then
    table.insert(rows, ui.column({ flexGrow = 1, align = "center", justify = "center", paddingV = 60 }, {
      S.caption(if query ~= "" then "no matches" elseif cat == "recent" then "nothing used yet" else "empty"),
    }))
  end

  local cur = shown[sel]
  local title = "Emoji"
  for _, c in CATS do if c.id == cat then title = c.label end end
  if query ~= "" then title = "Search" end

  panel.render(ui.column({ gap = 8, flexGrow = 1, align = "stretch" }, {
    ui.row({ align = "center", gap = 10, height = 34 }, {
      ui.glyph({ name = "search", size = 17, color = S.C.sub }),
      ui.input({
        key = "q-" .. opens,
        value = query,
        placeholder = "Search emoji",
        frameVisible = false,
        focus = true,
        fontSize = 14,
        controlSize = "sm",
        flexGrow = 1,
        onChange = function(v)
          query = v or ""; sel = 1; compute(); render()
        end,
        onSubmit = function() pick(shown[sel]) end,
      }),
      S.caption(tostring(#shown)),
    }),
    S.hline("h1"),
    ui.row({ gap = 0, align = "center", justify = "space_between" }, cats),
    ui.scroll({ key = "grid", flexGrow = 1, gap = GAP, revealKey = "e-" .. sel }, rows),
    S.hline("h2"),
    ui.row({ align = "center", gap = 10, height = 30 }, {
      ui.label({ text = if cur then cur.e else " ", fontSize = 20, baseline = "pictographic" }),
      ui.label({ text = if cur then cur.name else "", fontFamily = S.sans, fontSize = 13, color = S.C.text,
        maxWidth = 260, maxLines = 1 }),
      ui.spacer({ flexGrow = 1 }),
      S.caption(string.upper(title)),
      S.caption("↵ copy"),
    }),
  }))
end

local function move(d)
  if #shown == 0 then return end
  sel = S.step(sel, d, #shown, COLS)
  hovered = nil
  render()
end

local MOVES = { left = -1, right = 1, up = -COLS, down = COLS }
local R = S.repeater(function(k) move(MOVES[k]) end, { "left", "right", "up", "down" })
function onFrameTick(dt) R.tick(dt) end

function onKey(key, pressed)
  if R.key(key, pressed) then return end
  if pressed == false then return end
  local k = string.lower(tostring(key))
  if false then
  elseif k == "return" or k == "kp_enter" then pick(shown[sel])
  elseif k == "tab" or k == "shift+tab" then
    local idx = 1
    for i, c in CATS do if c.id == cat then idx = i end end
    idx = ((idx - 1 + (if k == "tab" then 1 else -1)) % #CATS) + 1
    cat = CATS[idx].id
    if query ~= "" then query = ""; opens += 1 end
    sel = 1; compute(); render()
  end
end

function onOpen(_context)
  R.stop()
  opens += 1
  query = ""
  sel = 1
  hovered = nil
  hoveredCat = nil
  cat = if #recent > 0 then "recent" else "people"
  compute()
  render()
end

compute()
render()
