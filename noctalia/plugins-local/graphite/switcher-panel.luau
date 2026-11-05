--!nonstrict
-- Window switcher (SUPER + Tab): open windows in focus order, most recent
-- first, with the previous window pre-selected. Tab / Shift+Tab / arrows move,
-- Enter or a click focuses, Ctrl+W (or the x on a row) closes that window.
-- A shell panel never sees SUPER being released, so switching needs Enter.

local S = require("./style.luau")
S.fonts()

local ROW_H = 46

local wins = {}
local sel = 1
local H = S.hover(function() render() end)
local HX = S.hover(function() render() end)
local iconCache = {}
local loading = false

local function icon(cls)
  if cls == "" then return nil end
  local c = iconCache[cls]
  if c == nil then
    c = noctalia.appIconPath(cls, 56) or noctalia.appIconPath(string.lower(cls), 56) or false
    iconCache[cls] = c
  end
  return c or nil
end

local function wsLabel(w)
  local name = (w.workspace and w.workspace.name) or ""
  if string.sub(name, 1, 8) == "special:" then return "special" end
  return "ws " .. name
end

local function focus(w)
  if not w then return end
  panel.close()
  S.dispatch(`hl.dsp.focus(\{ window = {S.lstr("address:" .. w.address)} \})`)
end

local function closeWin(w)
  if not w then return end
  S.dispatch(`hl.dsp.window.close(\{ window = {S.lstr("address:" .. w.address)} \})`)
  for i, x in wins do
    if x.address == w.address then table.remove(wins, i); break end
  end
  sel = math.clamp(sel, 1, math.max(1, #wins))
  render()
end

local function row(i, w)
  local isSel = sel == i
  local ic = icon(w.class or "")
  local lead = if ic then ui.image({ path = ic, width = 26, height = 26, fit = "contain" })
    else ui.row({ width = 26, height = 26, fill = S.C.well, align = "center", justify = "center" }, {
      ui.glyph({ name = "app-window", size = 14, color = S.C.sub }),
    })
  return S.item({
    key = "w-" .. w.address,
    height = ROW_H,
    selected = isSel,
    hovered = H.id == i,
    onClick = function() focus(w) end,
    onHover = H.fn(i),
  }, {
    lead,
    ui.column({ flexGrow = 1, gap = 1, justify = "center" }, {
      ui.label({ text = if (w.title or "") ~= "" then w.title else w.class, fontFamily = S.sans, fontSize = S.FS.body,
        color = if isSel then S.C.text else S.C.sub, maxWidth = 440, maxLines = 1 }),
      S.caption(w.class or ""),
    }),
    S.caption(wsLabel(w), if isSel then S.C.sub else S.C.dim),
    ui.row({
      key = "x-" .. w.address, width = 24, height = 24, align = "center", justify = "center",
      fill = if HX.id == i then S.C.keyHover else S.C.clear,
      opacity = if isSel or H.id == i or HX.id == i then 1 else 0,
      onClick = function() closeWin(w) end,
      onHover = HX.fn(i),
    }, { ui.glyph({ name = "x", size = 13, color = S.C.sub }) }),
  })
end

function render()
  local rows = {}
  for i, w in wins do table.insert(rows, row(i, w)) end
  if #wins == 0 then
    table.insert(rows, ui.column({ paddingV = 50, align = "center" }, {
      S.caption(if loading then "…" else "no open windows"),
    }))
  end
  panel.render(ui.column({ gap = 8, flexGrow = 1, align = "stretch" }, {
    ui.row({ align = "center", gap = 10, height = 30 }, {
      ui.glyph({ name = "app-window", size = 17, color = S.C.sub }),
      ui.label({ text = "Windows", fontFamily = S.sans, fontSize = S.FS.lg, color = S.C.text, flexGrow = 1 }),
      S.caption(tostring(#wins)),
    }),
    S.hline("h1"),
    ui.scroll({ key = "list", flexGrow = 1, gap = 0, revealKey = if wins[sel] then "w-" .. wins[sel].address else nil }, rows),
    S.hline("h2"),
    ui.row({ align = "center", gap = 14, height = 20 }, {
      ui.spacer({ flexGrow = 1 }),
      S.caption("tab next"),
      S.caption("↵ focus"),
      S.caption("^w close"),
    }),
  }))
end

local function refresh()
  loading = true
  noctalia.runAsync({ "hyprctl", "-j", "clients" }, function(r)
    loading = false
    local d = noctalia.json.decode(r.stdout or "")
    wins = {}
    if type(d) == "table" then
      for _, c in d do
        if c.mapped ~= false and (c.class or "") ~= "" then table.insert(wins, c) end
      end
      table.sort(wins, function(a, b) return (a.focusHistoryID or 99) < (b.focusHistoryID or 99) end)
    end
    sel = if #wins >= 2 then 2 else 1
    render()
  end, 3000)
end

local function move(d)
  if #wins == 0 then return end
  sel = S.step(sel, d, #wins)
  H.id = nil
  render()
end

local MOVES = { tab = 1, down = 1, right = 1, ["shift+tab"] = -1, up = -1, left = -1 }
local R = S.repeater(function(k) move(MOVES[k]) end, { "tab", "down", "right", "shift+tab", "up", "left" })
function onFrameTick(dt) R.tick(dt) end

function onKey(key, pressed)
  if R.key(key, pressed) then return end
  if pressed == false then return end
  local k = string.lower(tostring(key))
  if k == "return" or k == "kp_enter" or k == "space" then focus(wins[sel])
  elseif k == "ctrl+w" then closeWin(wins[sel])
  end
end

function onOpen(_context)
  R.stop()
  H.id = nil
  HX.id = nil
  refresh()
  render()
end

render()
