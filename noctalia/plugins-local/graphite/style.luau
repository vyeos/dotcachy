--!nonstrict
-- Shared look for every Graphite bar widget: palette roles, fonts, flat square
-- cells (no boxes at rest) and engraved dividers between groups.

local S = {}

-- Palette roles, so the bar follows the Graphite palette (and its light variant).
S.C = {
  text = "on_surface",          -- g9
  sub = "on_surface_variant",   -- g7
  dim = "on_surface_variant/0.55",
  faint = "on_surface_variant/0.3",
  key = "surface_container",    -- g2, raised key face
  keyHover = "hover",           -- g3
  edge = "outline_variant",     -- g4, key rim
  pressed = "surface",          -- g1, a key pushed into the bar
  well = "shadow",              -- g0, recessed trays
}

S.KEY_H = 34

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

-- Hyprland dispatch. 0.57+ (Lua config) takes a dispatcher expression such as
-- hl.dsp.focus({ workspace = 2 }); older releases take "dispatcher args". Try the
-- new form first and fall back when hyprctl reports an error.
function S.dispatch(luaExpr, legacyArgs)
  noctalia.runAsync({ "hyprctl", "dispatch", luaExpr }, function(r)
    local out = string.lower((r.stdout or "") .. (r.stderr or ""))
    if r.exitCode ~= 0 or string.find(out, "error", 1, true) then
      local argv = { "hyprctl", "dispatch" }
      for _, a in legacyArgs do table.insert(argv, a) end
      noctalia.runAsync(argv)
    end
  end, 3000)
end

-- Lua string literal for a dispatcher argument.
function S.lstr(s)
  return '"' .. string.gsub(string.gsub(s, "\\", "\\\\"), '"', '\\"') .. '"'
end

function S.panel(context)
  local argv = { "noctalia", "msg", "panel-toggle", "control-center" }
  if context then table.insert(argv, context) end
  noctalia.runAsync(argv)
end

-- Decode a JSON value published by the service; nil when absent or invalid.
function S.read(key)
  local raw = noctalia.state.get(key)
  if type(raw) ~= "string" then return raw end
  local v = noctalia.json.decode(raw)
  return v
end

function S.watch(key, fn)
  noctalia.state.watch(key, function(raw)
    if type(raw) == "string" then
      fn(noctalia.json.decode(raw))
    else
      fn(raw)
    end
  end)
end

-- A flat, square-cornered cell. Nothing at rest: just the content on the bar.
-- Hover fills the cell one shade lighter; pressed sinks it to the darkest well.
-- o: { key, hovered, pressed, onClick, onHover, tooltip, gap, paddingH, minWidth, height }
function S.key(o, children)
  local hovered = o.hovered == true
  local pressed = o.pressed == true
  local h = o.height or S.KEY_H
  return ui.row({
    key = o.key,
    height = h,
    minWidth = o.minWidth or h,
    paddingH = o.paddingH or 10,
    radius = 0,
    fill = if pressed then S.C.well elseif hovered then S.C.keyHover else "#00000000",
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
    fontSize = o.size or 13,
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
  return ui.label({ text = string.upper(text), fontFamily = S.mono, fontSize = 10.5, color = color or S.C.dim })
end

-- Panel header: glyph, title, then whatever controls go on the right.
function S.header(glyph, title, right)
  local kids = {
    ui.glyph({ name = glyph, size = 18, color = S.C.text }),
    ui.label({ text = title, fontFamily = S.sans, fontSize = 15, color = S.C.text, flexGrow = 1 }),
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
    fill = if o.selected then S.C.well elseif o.hovered then S.C.keyHover else "#00000000",
    onClick = o.onClick,
    onHover = o.onHover,
    tooltip = o.tooltip,
  }, children)
end

-- Run a command and hand back (ok, message) with a trimmed, single-line message.
function S.exec(argv, timeoutMs, cb)
  noctalia.runAsync(argv, function(r)
    local out = noctalia.string.trim((r.stderr or "") ~= "" and r.stderr or (r.stdout or ""))
    out = string.gsub(out, "%s*\n%s*", " · ")
    cb(r.exitCode == 0 and not r.timedOut, out)
  end, timeoutMs or 15000)
end

-- Turn Do Not Disturb on or off through the service (explicit, never a toggle).
function S.setDnd(on)
  noctalia.state.set("graphite.dndSet", (if on then "on:" else "off:") .. tostring(noctalia.nowMs()))
end

-- Ask the service to re-poll something right away (e.g. "net", "bt", "power").
-- Ask the service to switch something (caffeine, night, dnd, bt, wifi) so the
-- bar, panels and keybinds all see the same state.
function S.svc(event, payload)
  noctalia.runAsync({ "noctalia", "msg", "plugin", "vyeos/graphite:service", "all", event, payload or "toggle" })
end

function S.poke(what)
  noctalia.state.set("graphite.poke", what .. ":" .. tostring(noctalia.nowMs()))
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
