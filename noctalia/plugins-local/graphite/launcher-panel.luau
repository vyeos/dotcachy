--!nonstrict
-- App launcher (SUPER + Space): a flat search line over a list of apps.
-- A–Z when the search is empty; name matches rank above comment / keyword
-- matches when searching. Up/Down move (selection sinks into the well),
-- Enter or a click launches through uwsm, like the keybinds do.
-- Usage counts live in pluginDataDir/launcher-usage.json (seeded once from
-- Noctalia's own usage_counts.json).

local S = require("./style.luau")
S.fonts()

local ROW_H = 44
local MAX_ROWS = 80

local dataDir = noctalia.pluginDataDir()
local usagePath = if dataDir then dataDir .. "/launcher-usage.json" else nil

local apps = {}
local usage = {}
local shown = {}
local query = ""
local sel = 1
local hovered = nil
local opens = 0

local function loadUsage()
  local raw = if usagePath then noctalia.readFile(usagePath) else nil
  local u = if raw then noctalia.json.decode(raw) else nil
  if type(u) == "table" then usage = u; return end
  -- first run: borrow Noctalia's counts (keyed by .desktop path)
  local nraw = noctalia.readFile("~/.local/state/noctalia/usage_counts.json")
  local n = if nraw then noctalia.json.decode(nraw) else nil
  usage = {}
  if type(n) == "table" and type(n.Applications) == "table" then
    for path, c in n.Applications do
      local id = string.match(path, "([^/]+)%.desktop$")
      if id then usage[id] = c end
    end
  end
end

local appsPath = if dataDir then dataDir .. "/apps.json" else nil
local appsScript = (noctalia.pluginDir() or ".") .. "/apps.py"

local function loadApps()
  local raw = if appsPath then noctalia.readFile(appsPath) else nil
  local d = if raw then noctalia.json.decode(raw) else nil
  apps = {}
  if type(d) == "table" then
    for _, a in d do
      a.lname = string.lower(a.name)
      table.insert(apps, a)
    end
  end
end

-- Rescan in the background (apps.py, ~0.2 s); the cached list shows meanwhile.
local function scan()
  if not appsPath then return end
  noctalia.runAsync({ "python3", appsScript, appsPath }, function(r)
    if r.exitCode == 0 then
      loadApps(); compute(); render()
    end
  end, 15000)
end

local function icon(a)
  if a.icon and a.icon ~= "" then return a.icon end
  return nil
end

function compute()
  shown = {}
  local q = string.lower(noctalia.string.trim(query))
  if q == "" then
    for _, a in apps do table.insert(shown, a) end
    table.sort(shown, function(x, y) return x.lname < y.lname end)
  else
    local scored = {}
    for _, a in apps do
      local s = nil
      if string.sub(a.lname, 1, #q) == q then s = 0
      elseif string.find(a.lname, " " .. q, 1, true) then s = 1
      elseif string.find(a.lname, q, 1, true) then s = 2
      elseif string.find(a.hay, q, 1, true) then s = 3 end
      if s then table.insert(scored, { a = a, s = s }) end
    end
    table.sort(scored, function(x, y)
      if x.s ~= y.s then return x.s < y.s end
      return x.a.lname < y.a.lname
    end)
    for _, it in scored do table.insert(shown, it.a) end
  end
  sel = math.clamp(sel, 1, math.max(1, #shown))
end

local function launch(a)
  if not a then return end
  usage[a.id] = (usage[a.id] or 0) + 1
  if usagePath then noctalia.writeFile(usagePath, noctalia.json.encode(usage)) end
  panel.close()
  noctalia.runAsync({ "uwsm", "app", "--", a.id .. ".desktop" }, function(r)
    if r.exitCode ~= 0 then noctalia.runAsync({ "gtk-launch", a.id }) end
  end, 10000)
end

local function row(i, a)
  local isSel = sel == i
  local ic = icon(a)
  local lead = if ic then ui.image({ path = ic, width = 26, height = 26, fit = "contain" })
    else ui.row({ width = 26, height = 26, fill = S.C.well, align = "center", justify = "center" }, {
      ui.label({ text = string.upper(string.sub(a.name, 1, 1)), fontFamily = S.mono, fontSize = 12, color = S.C.sub }),
    })
  return S.item({
    key = "a-" .. a.id,
    height = ROW_H,
    selected = isSel,
    hovered = hovered == i,
    onClick = function() launch(a) end,
    onHover = function(st)
      hovered = if st == "true" then i elseif hovered == i then nil else hovered
      render()
    end,
  }, {
    lead,
    ui.column({ flexGrow = 1, gap = 1, justify = "center" }, {
      ui.label({ text = a.name, fontFamily = S.sans, fontSize = 13.5,
        color = if isSel then S.C.text else S.C.sub, maxWidth = 470, maxLines = 1 }),
      ui.label({ text = a.comment, fontFamily = S.sans, fontSize = 11.5, color = S.C.dim, maxWidth = 470, maxLines = 1 }),
    }),
    S.caption(if isSel then "↵" else ""),
  })
end

function render()
  local rows = {}
  for i, a in shown do
    if i > MAX_ROWS then break end
    table.insert(rows, row(i, a))
  end
  if #shown == 0 then
    table.insert(rows, ui.column({ paddingV = 60, align = "center" }, { S.caption("no matching apps") }))
  end
  panel.render(ui.column({ gap = 8, flexGrow = 1, align = "stretch" }, {
    ui.row({ align = "center", gap = 10, height = 34 }, {
      ui.glyph({ name = "search", size = 17, color = S.C.sub }),
      ui.input({
        key = "q-" .. opens,
        value = query,
        placeholder = "Search apps",
        frameVisible = false,
        focus = true,
        fontSize = 14,
        controlSize = "sm",
        flexGrow = 1,
        onChange = function(v) query = v or ""; sel = 1; compute(); render() end,
        onSubmit = function() launch(shown[sel]) end,
      }),
      S.caption(tostring(#shown)),
    }),
    S.hline("h1"),
    ui.scroll({ key = "list", flexGrow = 1, gap = 0, revealKey = if shown[sel] then "a-" .. shown[sel].id else nil }, rows),
    S.hline("h2"),
    ui.row({ align = "center", gap = 14, height = 20 }, {
      S.caption(if query == "" then "a – z" else "search"),
      ui.spacer({ flexGrow = 1 }),
      S.caption("↑↓ move"),
      S.caption("↵ open"),
      S.caption("esc close"),
    }),
  }))
end

local function move(d)
  if #shown == 0 then return end
  sel = S.step(sel, d, math.min(#shown, MAX_ROWS))
  hovered = nil
  render()
end

local MOVES = { up = -1, ["shift+tab"] = -1, down = 1, tab = 1, page_up = -8, page_down = 8 }
local R = S.repeater(function(k) move(MOVES[k]) end, { "up", "down", "tab", "shift+tab", "page_up", "page_down" })
function onFrameTick(dt) R.tick(dt) end

function onKey(key, pressed)
  if R.key(key, pressed) then return end
  if pressed == false then return end
  local k = string.lower(tostring(key))
  if false then
  elseif k == "return" or k == "kp_enter" then launch(shown[sel])
  end
end

function onOpen(_context)
  R.stop()
  opens += 1
  query = ""
  sel = 1
  hovered = nil
  compute()
  scan() -- picks up newly installed apps
  render()
end

loadUsage()
loadApps()
compute()
render()
scan()
