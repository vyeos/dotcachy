--!nonstrict
-- Clipboard history (SUPER + V): filter line, then a flat list on the left and
-- the selected entry's preview in a recessed well on the right.
-- Up/Down move, Enter copies and closes, Ctrl+P pins, Shift+Delete deletes.
-- History is kept by clip.py (fed by `wl-paste --watch` in the service);
-- this panel only reads clip-index.json and asks clip.py for changes.

local S = require("./style.luau")
S.fonts()

local LIST_W = 300
local ROW_H = 46
local PV_W = 446 -- preview well size (panel 760 - list - divider - gaps)
local PV_H = 354

local dataDir = noctalia.pluginDataDir() or ""
local indexPath = dataDir .. "/clip-index.json"
local script = (noctalia.pluginDir() or ".") .. "/clip.py"

local items = {}
local shown = {}
local query = ""
local sel = 1
local H = S.hover(function() render() end)
local HAct = S.hover(function() render() end)
local armedClear = false
local opens = 0

local isOpen = false

local function firstLine(s)
  s = noctalia.string.trim(string.sub(s or "", 1, 400)) -- a title needs no more, and long text is slow
  local line = string.match(s, "^[^\n]*") or ""
  line = string.gsub(line, "%s+", " ")
  if string.find(s, "\n", 1, true) then line ..= "  ↵" end
  return line
end

local function load()
  local raw = noctalia.readFile(indexPath)
  local d = if raw then noctalia.json.decode(raw) else nil
  items = if type(d) == "table" then d else {}
  -- worked out once here: render and compute run on every hover and keystroke
  for _, it in items do
    if it.kind == "text" then
      it.title = firstLine(it.text)
      it.hay = string.lower(it.text or "")
    else
      it.title = `Image {it.w or "?"}×{it.h or "?"}`
      it.hay = "image"
    end
  end
end

local function compute()
  shown = {}
  local q = string.lower(query)
  -- pinned first, then newest
  for pass = 1, 2 do
    for _, it in items do
      if (pass == 1) == (it.pinned == true) then
        if q == "" or string.find(it.hay, q, 1, true) then table.insert(shown, it) end
      end
    end
  end
  sel = math.clamp(sel, 1, math.max(1, #shown))
end

local function bytes(n)
  n = n or 0
  if n < 1024 then return `{n} B` end
  if n < 1048576 then return string.format("%.1f KB", n / 1024) end
  return string.format("%.1f MB", n / 1048576)
end

local function clip(verb, id, after)
  local argv = { "python3", script, dataDir, verb }
  if id then table.insert(argv, tostring(id)) end
  noctalia.runAsync(argv, function(_r)
    load(); compute()
    if after then after() end
    render()
  end, 8000)
end

local function copySel()
  local it = shown[sel]
  if not it then return end
  if it.kind == "text" and not it.full then
    noctalia.copyToClipboard(it.text or "", "text/plain;charset=utf-8")
  else
    clip("copy", it.id)
  end
  panel.close()
end

local function row(i, it)
  local isSel = sel == i
  local lead
  if it.kind == "image" and it.file then
    lead = ui.image({ path = it.file, width = 28, height = 28, fit = "cover", radius = 0 })
  else
    lead = ui.row({ width = 28, height = 28, radius = 0, align = "center", justify = "center",
      fill = if isSel then S.C.keyHover else S.C.well }, {
      ui.glyph({ name = "align-left", size = 14, color = S.C.sub }),
    })
  end
  return S.item({
    key = "c-" .. it.id,
    height = ROW_H,
    selected = isSel,
    hovered = H.id == i,
    onClick = function()
      if sel == i then copySel() else sel = i; render() end
    end,
    onHover = H.fn(i),
  }, {
    lead,
    ui.column({ flexGrow = 1, gap = 2, justify = "center" }, {
      ui.label({ text = it.title, fontFamily = S.sans, fontSize = S.FS.body,
        color = if isSel then S.C.text else S.C.sub, maxWidth = LIST_W - 90, maxLines = 1 }),
      S.caption(`{S.ago(it.t)} · {bytes(it.size)}`),
    }),
    -- pinned: a filled square, like a workspace with windows
    ui.box({ width = 6, height = 6, radius = 0, fill = if it.pinned then S.C.text else S.C.clear }),
  })
end

local function action(id, glyph, label, hint, fn)
  local lit = HAct.id == id
  return ui.row({
    key = "a-" .. id, height = 30, paddingH = 10, gap = 7, align = "center", radius = 0,
    fill = if lit then S.C.keyHover else S.C.clear,
    onClick = fn,
    onHover = HAct.fn(id),
  }, {
    ui.glyph({ name = glyph, size = 15, color = if lit then S.C.text else S.C.sub }),
    ui.label({ text = label, fontFamily = S.sans, fontSize = S.FS.md, color = if lit then S.C.text else S.C.sub }),
    S.caption(hint),
  })
end

local function preview()
  local it = shown[sel]
  if not it then
    return ui.column({ flexGrow = 1, fill = S.C.well, align = "center", justify = "center" }, {
      S.caption(if #items == 0 then "history is empty" else "no matches"),
    })
  end
  local body
  if it.kind == "image" and it.file then
    -- edge to edge: full well width, height from the image's aspect ratio
    -- (shrunk to fit when a tall image would overflow the well)
    local iw, ih = tonumber(it.w) or 0, tonumber(it.h) or 0
    local w, h = PV_W, PV_H
    if iw > 0 and ih > 0 then
      h = PV_W * ih / iw
      if h > PV_H then h = PV_H; w = PV_H * iw / ih end
    end
    body = ui.column({ flexGrow = 1, fill = S.C.well, align = "center", justify = "center" }, {
      ui.image({ path = it.file, width = w, height = h, fit = "contain", radius = 0 }),
    })
  else
    local txt = it.text or ""
    if #txt > 6000 then txt = string.sub(txt, 1, 6000) .. "\n…" end
    body = ui.scroll({ key = "pv-" .. it.id, flexGrow = 1, fill = S.C.well, padding = 12 }, {
      ui.label({ text = txt, fontFamily = S.mono, fontSize = S.FS.md, color = S.C.text, maxWidth = 360 }),
    })
  end
  return ui.column({ flexGrow = 1, gap = 8 }, {
    ui.row({ align = "center", gap = 8, height = 20 }, {
      S.caption(if it.kind == "image" then "image" else "text", S.C.sub),
      S.caption(`· {bytes(it.size)} · {S.ago(it.t)}`),
      ui.spacer({ flexGrow = 1 }),
      S.caption(if it.pinned then "pinned" else ""),
    }),
    body,
    ui.row({ gap = 2, align = "center", justify = "end" }, {
      action("copy", "copy", "Copy", "↵", copySel),
      action("pin", if it.pinned then "pinned-off" else "pin", if it.pinned then "Unpin" else "Pin", "^P",
        function() clip("pin", it.id) end),
      action("del", "trash", "Delete", "⇧DEL", function() clip("del", it.id) end),
    }),
  })
end

function render()
  local rows = {}
  for i, it in shown do table.insert(rows, row(i, it)) end
  if #shown == 0 then
    table.insert(rows, ui.column({ paddingV = 40, align = "center" }, {
      S.caption(if #items == 0 then "copy something" else "no matches"),
    }))
  end

  panel.render(ui.column({ gap = 8, flexGrow = 1, align = "stretch" }, {
    S.search({ glyph = "clipboard", key = "q-" .. opens, value = query, placeholder = "Filter clipboard", count = #items,
      onSubmit = function() copySel() end,
      onChange = function(v) query = v or ""; sel = 1; compute(); render() end,
      right = { ui.row({
        key = "clear", height = 26, paddingH = 8, align = "center", radius = 0,
        fill = if armedClear then S.C.text elseif HAct.id == "clear" then S.C.keyHover else S.C.clear,
        onClick = function()
          if armedClear then armedClear = false; clip("clear") else armedClear = true; render() end
        end,
        onHover = function(st)
          HAct.fn("clear")(st)
          if st ~= "true" and armedClear then armedClear = false; render() end
        end,
      }, {
        ui.label({ text = if armedClear then "CLEAR ALL?" else "CLEAR", fontFamily = S.mono, fontSize = S.FS.xs,
          color = if armedClear then S.C.inv else S.C.dim }),
      }), } }),
    S.hline("h1"),
    ui.row({ flexGrow = 1, gap = 12, align = "stretch" }, {
      ui.scroll({ key = "list", width = LIST_W, gap = 0, revealKey = if shown[sel] then "c-" .. shown[sel].id else nil }, rows),
      ui.row({ width = 2, gap = 0, align = "stretch" }, {
        ui.separator({ orientation = "vertical", thickness = 1, spacing = 0, color = S.C.well }),
        ui.separator({ orientation = "vertical", thickness = 1, spacing = 0, color = S.C.keyHover }),
      }),
      preview(),
    }),
  }))
end

local function move(d)
  if #shown == 0 then return end
  sel = S.step(sel, d, #shown)
  H.id = nil
  render()
end

local MOVES = { up = -1, down = 1, page_up = -8, page_down = 8 }
local R = S.repeater(function(k) move(MOVES[k]) end, { "up", "down", "page_up", "page_down" })
function onFrameTick(dt) R.tick(dt) end

function onKey(key, pressed)
  if R.key(key, pressed) then return end
  if pressed == false then return end
  local k = string.lower(tostring(key))
  if k == "return" or k == "kp_enter" then copySel()
  elseif k == "ctrl+p" then
    local it = shown[sel]
    if it then clip("pin", it.id) end
  elseif k == "shift+delete" then
    local it = shown[sel]
    if it then clip("del", it.id) end
  end
end

-- Only while open: the next open reads the index anyway.
S.watch("graphite.clipRev", function(_v)
  if isOpen then load(); compute(); render() end
end)

function onClose()
  isOpen = false
  R.stop()
end

function onOpen(_context)
  isOpen = true
  R.stop()
  opens += 1
  query = ""
  sel = 1
  H.id = nil
  HAct.id = nil
  armedClear = false
  load(); compute(); render()
end

load()
compute()
render()
