--!nonstrict
-- Shared look for every Graphite bar widget: palette roles, fonts, flat square
-- cells (no boxes at rest) and engraved dividers between groups.

local S = {}

-- Palette roles, so everything follows the Graphite palette.
S.C = {
  text = "on_surface",          -- g9
  body = "on_surface/0.85",     -- list text that is not selected
  sub = "on_surface_variant",   -- g7
  dim = "on_surface_variant/0.55",
  faint = "on_surface_variant/0.3",
  key = "surface_container",    -- g2, raised tile
  keyHover = "hover",           -- g3
  edge = "outline_variant",     -- g4, panel rim
  panel = "surface",            -- g1, the drawer's face
  well = "shadow",              -- g0, recessed trays
  inv = "surface",              -- ink on an inverted (light) face
  invDim = "surface/0.7",
  clear = "#00000000",
}

-- Type scale. Larger display numbers in the calculator auto-fit and stay local to it.
S.FS = {
  xs = 10.5,     -- captions, badges
  sm = 11.5,     -- secondary mono readouts
  md = 12.5,     -- small labels
  body = 13,     -- list rows
  lg = 14,       -- search fields, tabs
  xl = 15,       -- headers, the bar clock
  title = 16,    -- calendar month
  icon = 20,     -- emoji preview
  emoji = 24,
  big = 34,      -- large readouts
}

S.KEY_H = 34
S.EDGE_GAP = 6         -- matches Hyprland's gaps_out
S.DRAWER_W = 380

S.PROFILE_LABEL = { ["power-saver"] = "Saver", balanced = "Balanced", performance = "Performance" }
S.PROFILE_GLYPH = { ["power-saver"] = "leaf", balanced = "gauge", performance = "rocket" }

function S.barThickness()
  return tonumber(noctalia.getSetting("bar.default.thickness")) or 38
end

local fontsLoaded = false
function S.fonts()
  if fontsLoaded then return end
  fontsLoaded = true
  S.mono = noctalia.loadFont("fonts/GraphiteMono.ttf")
  S.sans = noctalia.loadFont("fonts/GraphiteSans.ttf")
end

function S.run(argv)
  noctalia.runAsync(argv)
end

-- Reboot into Windows once: set the firmware's one-shot BootNext to Windows Boot
-- Manager, then reboot the normal way. An argv, so the launcher can bind it too.
-- Needs `sudo sh ~/.config/noctalia/bin/windows-bootnext install` once.
S.REBOOT_WINDOWS = { "sh", "-c", "if out=$(sudo -n /usr/local/bin/windows-bootnext 2>&1); then noctalia msg session reboot; "
  .. "else notify-send -a Session \"Can't reboot to Windows\" \"${out:-Run: pkexec sh ~/.config/noctalia/bin/windows-bootnext install}\"; fi" }

-- Hyprland dispatch: takes a dispatcher expression such as hl.dsp.focus({ workspace = 2 }).
function S.dispatch(luaExpr)
  noctalia.runAsync({ "hyprctl", "dispatch", luaExpr })
end

-- Lua string literal for a dispatcher argument.
function S.lstr(s)
  return '"' .. string.gsub(string.gsub(s, "\\", "\\\\"), '"', '\\"') .. '"'
end

-- JSON string -> value; nil when absent or invalid.
function S.decode(raw)
  if type(raw) ~= "string" then return raw end
  local v = noctalia.json.decode(raw)
  return v
end

-- Read a value published by the service.
function S.read(key)
  return S.decode(noctalia.state.get(key))
end

function S.watch(key, fn)
  noctalia.state.watch(key, function(raw) fn(S.decode(raw)) end)
end

-- Hover state for flat keys and rows. local H = S.hover(function() render() end);
-- then onHover = H.fn(id), and H.id is whatever the pointer is on.
function S.hover(redraw)
  local H = { id = nil }
  function H.fn(id)
    return function(st)
      if st == "true" then H.id = id elseif H.id == id then H.id = nil end
      redraw()
    end
  end
  return H
end

-- Split "a\n--\nb\n--\nc" command output into its sections.
function S.parts(text)
  local parts = {}
  for chunk in string.gmatch((text or "") .. "\n--\n", "(.-)\n%-%-\n") do table.insert(parts, chunk) end
  return parts
end

-- nmcli -t output escapes ':' and '\' with a backslash.
function S.terse(line)
  local fields, cur, i = {}, {}, 1
  while i <= #line do
    local c = string.sub(line, i, i)
    if c == "\\" and i < #line then
      table.insert(cur, string.sub(line, i + 1, i + 1)); i += 2
    elseif c == ":" then
      table.insert(fields, table.concat(cur)); cur = {}; i += 1
    else
      table.insert(cur, c); i += 1
    end
  end
  table.insert(fields, table.concat(cur))
  return fields
end

-- "now", "5m", "3h", "2d"
function S.ago(t)
  local d = math.max(0, os.time() - (t or 0))
  if d < 60 then return "now" end
  if d < 3600 then return `{d // 60}m` end
  if d < 86400 then return `{d // 3600}h` end
  return `{d // 86400}d`
end

-- A flat, square-cornered cell. Nothing at rest: just the content on the bar.
-- Hover fills the cell one shade lighter.
-- o: { key, hovered, onClick, onHover, tooltip, gap, paddingH, minWidth, height }
function S.key(o, children)
  local hovered = o.hovered == true
  local h = o.height or S.KEY_H
  return ui.row({
    key = o.key,
    height = h,
    minWidth = o.minWidth or h,
    paddingH = o.paddingH or 10,
    radius = 0,
    fill = if hovered then S.C.keyHover else S.C.clear,
    align = "center",
    justify = "center",
    gap = o.gap or 7,
    onClick = o.onClick,
    onHover = o.onHover,
    tooltip = o.tooltip,
  }, children)
end

-- An engraved divider: a dark groove beside a light lip, like a line cut into
-- a machined panel. Separates groups instead of boxing every widget.
function S.divider(key)
  return ui.row({ key = key, height = 18, gap = 0, paddingH = 6, align = "center" }, {
    ui.box({ width = 1, height = 18, fill = S.C.well }),
    ui.box({ width = 1, height = 18, fill = S.C.keyHover }),
  })
end

function S.label(text, o)
  o = o or {}
  return ui.label({
    text = text,
    color = o.color or S.C.sub,
    fontSize = o.size or S.FS.body,
    fontFamily = o.font or S.sans,
    fontWeight = o.weight,
    maxWidth = o.maxWidth,
    maxLines = o.maxWidth and 1 or nil,
  })
end

-- Output volume icon, shared by the bar key and the sliders: a speaker with
-- one wave below 40%, two from 40% up, the cross only at 0%, the struck-through
-- speaker only when muted.
function S.volumeGlyph(pct, muted)
  if muted then return "volume-off" end
  pct = pct or 0
  if pct == 0 then return "volume-3" end
  if pct < 40 then return "volume-2" end
  return "volume"
end

function S.glyph(name, o)
  o = o or {}
  return ui.glyph({ name = name, size = o.size or 16, color = o.color or S.C.sub })
end

-- Battery readout, shared by the bar key and the lock screen: a drawn battery
-- whose fill turns bright with a bright outline below 20%, a bolt while
-- charging, and the percentage in mono. Returns the row's children.
function S.batteryParts(info)
  local BODY_W, BODY_H, INNER_W = 24, 13, 19
  local pct = math.clamp(info.pct or 0, 0, 100)
  local charging = info.status == "Charging"
  local low = pct < 20 and not charging
  local ink = if low then S.C.text else S.C.sub
  local fillW = math.max(1, math.floor(INNER_W * pct / 100 + 0.5))

  local kids = {
    ui.row({ align = "center", gap = 1 }, {
      ui.row({
        width = BODY_W,
        height = BODY_H,
        radius = 0,
        border = ink,
        borderWidth = 1.5,
        padding = 2.5,
        align = "center",
      }, { ui.box({ width = fillW, height = BODY_H - 6, radius = 0, fill = ink }), ui.spacer({ flexGrow = 1 }) }),
      ui.box({ width = 2, height = 5, radius = 0, fill = ink }),
    }),
  }
  if charging then
    table.insert(kids, S.glyph("bolt", { size = 13, color = S.C.text }))
  end
  table.insert(kids, S.label(`{pct}%`, { font = S.mono, size = S.FS.md, color = ink }))
  return kids
end

-- ── Panels ──────────────────────────────────────────────────────────────────
-- Shared pieces for the Graphite panels: flat, square, engraved.

-- Engraved horizontal rule: dark groove over a light lip.
function S.hline(key)
  return ui.column({ key = key, gap = 0, align = "stretch" }, {
    ui.separator({ orientation = "horizontal", thickness = 1, spacing = 0, color = S.C.well }),
    ui.separator({ orientation = "horizontal", thickness = 1, spacing = 0, color = S.C.keyHover }),
  })
end

-- Small uppercase mono caption for section labels and states.
function S.caption(text, color)
  return ui.label({ text = string.upper(text), fontFamily = S.mono, fontSize = S.FS.xs, color = color or S.C.dim })
end

-- Panel header: glyph, title, then whatever controls go on the right.
function S.header(glyph, title, right)
  local kids = {
    ui.glyph({ name = glyph, size = 18, color = S.C.text }),
    ui.label({ text = title, fontFamily = S.sans, fontSize = S.FS.xl, color = S.C.text, flexGrow = 1 }),
  }
  for _, k in right or {} do table.insert(kids, k) end
  return ui.row({ align = "center", gap = 10, height = 34 }, kids)
end

-- A list row: flat square cell, lighter on hover, sunk when selected.
-- o: { key, hovered, selected, onClick, onHover, tooltip, height }
function S.item(o, children)
  return ui.row({
    key = o.key,
    height = o.height or 40,
    paddingH = 10,
    gap = 10,
    align = "center",
    radius = 0,
    fill = if o.selected then S.C.well elseif o.hovered then S.C.keyHover else S.C.clear,
    onClick = o.onClick,
    onHover = o.onHover,
    tooltip = o.tooltip,
  }, children)
end

-- Two-click confirm for a destructive row action. A.click(id, run) arms id on
-- the first click and runs on a second click before it expires; A.tick() drops
-- an expired arm and says so.
function S.confirm(redraw, ms)
  local A = { id = nil, at = 0 }
  function A.click(id, run)
    if A.id == id then
      A.id = nil
      run()
    else
      A.id = id
      A.at = noctalia.nowMs()
    end
    redraw()
  end
  function A.tick()
    if A.id and noctalia.nowMs() - A.at >= (ms or 4000) then
      A.id = nil
      return true
    end
    return false
  end
  return A
end

-- Forget box at the end of a list row: a trash glyph while the row is hovered,
-- inverted and asking once armed. o: { key, shown, armed, hovered, onClick, onHover }
function S.forget(o)
  return ui.row({
    key = o.key, width = if o.armed then 62 else 24, height = 24, align = "center", justify = "center", radius = 0,
    fill = if o.armed then S.C.text elseif o.hovered then S.C.keyHover else S.C.clear,
    onClick = o.onClick,
    onHover = o.onHover,
  }, {
    if o.armed then S.caption("forget?", S.C.inv)
    else ui.glyph({ name = "trash", size = 13, color = if o.shown then S.C.sub else S.C.clear }),
  })
end

-- Run a command and hand back (ok, message) with a trimmed, single-line message.
function S.exec(argv, timeoutMs, cb)
  noctalia.runAsync(argv, function(r)
    local out = noctalia.string.trim((r.stderr or "") ~= "" and r.stderr or (r.stdout or ""))
    out = string.gsub(out, "%s*\n%s*", " · ")
    cb(r.exitCode == 0 and not r.timedOut, out)
  end, timeoutMs or 15000)
end

-- Flip something through the service, so the bar, panels and keybinds all see it:
-- caffeine, night, dnd, bt, wifi [on|off|toggle], profile [<name>|next], mute out|in.
function S.svc(event, payload)
  noctalia.state.set("graphite.cmd", `{event}:{payload or "toggle"}:{noctalia.nowMs()}`)
end

-- Ask the service for a fresh read ("net", "bt", "power", "gpu", "vol").
function S.poke(what)
  noctalia.state.set("graphite.poke", what .. ":" .. tostring(noctalia.nowMs()))
end

-- Search line shared by the floating panels.
-- o: { glyph, key, value, placeholder, count, onChange, onSubmit, right = { extra nodes } }
function S.search(o)
  local kids = {
    ui.glyph({ name = o.glyph or "search", size = 17, color = S.C.sub }),
    ui.input({
      key = o.key,
      value = o.value,
      placeholder = o.placeholder,
      frameVisible = false,
      focus = true,
      fontSize = S.FS.lg,
      controlSize = "sm",
      flexGrow = 1,
      onChange = o.onChange,
      onSubmit = o.onSubmit,
    }),
    S.caption(tostring(o.count)),
  }
  for _, k in o.right or {} do table.insert(kids, k) end
  return ui.row({ align = "center", gap = 10, height = 34 }, kids)
end

-- Short result line under a panel's list.
function S.status(text)
  return ui.label({ text = text, fontFamily = S.mono, fontSize = S.FS.sm, color = S.C.sub, maxLines = 2 })
end

-- A scrolling list whose rows don't move when its scrollbar comes and goes.
-- Noctalia's scroll gives the scrollbar room only once the content overflows, so
-- stretched rows would jump narrower. Instead the rows get a fixed width, left
-- aligned, that already leaves the scrollbar's lane free on the right. Sized for
-- a 360 px panel.
S.LIST_W = 310
function S.list(key, rows, o)
  o = o or {}
  -- align = "start": a scroll centers narrower content by default
  return ui.scroll({ key = key, flexGrow = 1, gap = 0, align = "start" }, {
    ui.column({ key = key .. "-col", width = S.LIST_W, gap = o.gap or 1, align = "stretch" }, rows),
  })
end

-- Centered glyph and line, for loading and empty lists.
function S.placeholder(glyph, text, o)
  o = o or {}
  return ui.column({ height = o.height or 120, align = "center", justify = "center", gap = o.gap or 8 }, {
    ui.glyph({ name = glyph, size = o.size or 26, color = S.C.dim }),
    ui.label({ text = text, color = S.C.dim, fontFamily = S.sans }),
  })
end

-- ── List navigation ─────────────────────────────────────────────────────────

-- Move a 1-based selection by d in a list of n (cols > 1 = a grid of that many
-- columns). Single steps and row steps wrap around: past the last row lands in
-- the same column of the first row, and the reverse. Larger jumps clamp.
function S.step(sel, d, n, cols)
  if n <= 0 then return 1 end
  cols = cols or 1
  if d == 1 or d == -1 then
    return ((sel - 1 + d) % n) + 1
  end
  if cols > 1 and (d == cols or d == -cols) then
    local t = sel + d
    if t > n then return ((sel - 1) % cols) + 1 end
    if t < 1 then
      local col = (sel - 1) % cols
      local lastRowStart = ((n - 1) // cols) * cols
      return math.min(lastRowStart + col + 1, n)
    end
    return t
  end
  return math.clamp(sel + d, 1, n)
end

-- Held-key repeat for panels. Captured chords arrive once on press and once on
-- release (the host filters key repeat), so this replays the move on frame
-- ticks while the key stays down. step(chord) performs one move.
-- Wire it with: onKey -> R.key(chord, pressed) (returns true when handled),
-- onFrameTick -> R.tick, onOpen -> R.stop.
local DELAY_MS, RATE_MS = 300, 40
function S.repeater(step, chords)
  local R = { chord = nil, t = 0, nextAt = 0 }
  local set = {}
  for _, c in chords do set[string.lower(c)] = true end
  function R.stop()
    if R.chord then R.chord = nil; panel.setNeedsFrameTick(false) end
  end
  function R.key(chord, pressed)
    local k = string.lower(tostring(chord))
    if not set[k] then return false end
    if pressed == false then
      if R.chord == k then R.stop() end
      return true
    end
    R.chord = k; R.t = 0; R.nextAt = DELAY_MS
    step(k)
    panel.setNeedsFrameTick(true)
    return true
  end
  function R.tick(dt)
    if not R.chord then return end
    R.t += (tonumber(dt) or 16)
    local n = 0
    while R.t >= R.nextAt and n < 3 do
      step(R.chord)
      R.nextAt += RATE_MS
      n += 1
    end
    if R.t >= R.nextAt then R.nextAt = R.t + RATE_MS end
  end
  return R
end

return S
