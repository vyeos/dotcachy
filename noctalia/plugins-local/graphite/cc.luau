--!nonstrict
-- Graphite control center: a single Home page, sized to its content. Clock and
-- uptime with the battery opposite, six quick toggles, volume and brightness. Opened from the clock or by
-- right-clicking the logo. Wi-Fi, Bluetooth, audio and power have their own
-- panels under their bar keys; the tiles here only flip the radios and modes.

local S = require("./style.luau")
S.fonts()

local H = S.hover(function() render() end)

local wifi = S.read("graphite.wifi") or {}
local bt = S.read("graphite.bt") or { devices = {} }
local notif = S.read("graphite.notif") or {}
local power = S.read("graphite.power") or {}
local batt = S.read("graphite.batt") or { present = false }
local caffeine = noctalia.state.get("graphite.caffeine") == true
local night = noctalia.state.get("graphite.night") == true
local bright = { dev = nil, pct = 0 }
local vol = S.read("graphite.vol")
local who = { user = "", host = "", uptime = 0 }

local function trim(s) return noctalia.string.trim(s or "") end

local function fmtUptime(secs)
  local d, h, m = secs // 86400, (secs // 3600) % 24, (secs // 60) % 60
  if d > 0 then return `{d}d {h}h` end
  if h > 0 then return `{h}h {m}m` end
  return `{m}m`
end

-- ── readers ─────────────────────────────────────────────────────────────────

local function readUptime()
  local u = noctalia.readFile("/proc/uptime")
  who.uptime = math.floor(tonumber(string.match(u or "", "^([%d%.]+)")) or 0)
end

-- Straight from sysfs, synchronously, so the brightness row is there on the
-- panel's first frame instead of popping in after a brightnessctl call.
local function readBrightness()
  local base = "/sys/class/backlight"
  local pick = nil
  for _, dev in noctalia.listDir(base) or {} do
    -- prefer the panel's own backlight over a discrete GPU's
    if pick == nil or string.find(pick, "nvidia", 1, true) then pick = dev end
  end
  if not pick then bright.dev = nil; return end
  local cur = tonumber(string.match(noctalia.readFile(`{base}/{pick}/brightness`) or "", "%d+"))
  local max = tonumber(string.match(noctalia.readFile(`{base}/{pick}/max_brightness`) or "", "%d+"))
  if not cur or not max or max <= 0 then bright.dev = nil; return end
  bright.dev, bright.pct = pick, math.floor(cur * 100 / max + 0.5)
end

-- ── actions ─────────────────────────────────────────────────────────────────

local function setBrightness(pct)
  if not bright.dev or pct == bright.pct then return end
  bright.pct = pct
  S.run({ "brightnessctl", "-q", "-d", bright.dev, "set", `{math.max(1, pct)}%` })
  render()
end

local function setVolume(pct)
  if not vol or pct == vol.pct then return end
  vol.pct = pct
  S.run({ "wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", string.format("%.2f", pct / 100) })
  render()
end

-- ── pieces ──────────────────────────────────────────────────────────────────

-- Quick toggle tile. On = inverted (light face, dark ink), like the active
-- workspace bar and the notification badge.
local function tile(id, glyph, label, sub, on, onClick)
  return ui.column({
    key = "tile-" .. id,
    flexGrow = 1,
    paddingH = 12,
    paddingV = 12,
    gap = 4,
    radius = 0,
    fill = if on then S.C.text elseif H.id == "tile-" .. id then S.C.keyHover else S.C.key,
    align = "start",
    justify = "center",
    onClick = onClick,
    onHover = H.fn("tile-" .. id),
  }, {
    ui.glyph({ name = glyph, size = 18, color = if on then S.C.inv else S.C.sub }),
    ui.label({ text = label, fontFamily = S.sans, fontSize = S.FS.body, color = if on then S.C.inv else S.C.text }),
    ui.label({ text = sub, fontFamily = S.mono, fontSize = S.FS.xs, color = if on then S.C.invDim else S.C.dim, maxWidth = 130, maxLines = 1 }),
  })
end

-- Glyph key, level meter, readout. The readout shows the level a click would
-- set while the pointer is over the meter.
local function levelRow(key, glyph, value, valueText, dim, onSet, onGlyph)
  local meter, preview = S.meter({ key = key .. "-m", value = value, H = H, onSet = onSet })
  return ui.row({ key = key, gap = 10, align = "center", height = 34 }, {
    S.glyphKey({ key = key .. "-g", glyph = glyph, color = if dim then S.C.dim else S.C.sub,
      hovered = onGlyph ~= nil and H.id == key .. "-g", onHover = if onGlyph then H.fn(key .. "-g") else nil,
      onClick = onGlyph }),
    meter,
    ui.label({ text = if preview then `{preview}%` else valueText, fontFamily = S.mono, fontSize = S.FS.md,
      color = if preview then S.C.sub elseif dim then S.C.dim else S.C.text, width = 44, textAlign = "end" }),
  })
end

-- "43.0 minutes to full" -> "43 min to full", "2.5 hours left" -> "2.5 h left"
local function shortTime(t)
  t = string.gsub(t or "", "(%d+)%.0 ", "%1 ")
  t = string.gsub(t, " minutes?", " min")
  t = string.gsub(t, " hours?", " h")
  t = string.gsub(t, " seconds?", " s")
  return t
end

-- Battery, opposite the clock: the drawn battery, the charge in mono with the
-- bar's state slot after it (% / bolt / plug), and time left and draw below.
-- Click opens the power panel.
local function battery()
  local pct = math.clamp(batt.pct or 0, 0, 100)
  local state = S.batteryState(batt.status)
  local low = pct < 20 and state == "battery"
  local ink = if low then S.C.text else S.C.sub
  local mark
  if state == "charging" then
    mark = S.glyph("bolt", { size = 15, color = S.C.text })
  elseif state == "full" then
    mark = S.glyph("plug", { size = 15, color = S.C.sub })
  else
    mark = ui.label({ text = "%", fontFamily = S.mono, fontSize = S.FS.xl, color = S.C.text })
  end
  local detail = {}
  if (power.timeLeft or "") ~= "" then table.insert(detail, shortTime(power.timeLeft)) end
  if (power.rate or "") ~= "" then table.insert(detail, power.rate) end
  if #detail == 0 then
    table.insert(detail, if state == "full" then "full" elseif state == "charging" then "charging" else "on battery")
  end
  return ui.column({
    key = "batt",
    gap = 2,
    align = "end",
    onHover = H.fn("batt"),
    onClick = function() noctalia.togglePanel("vyeos/graphite:power-panel-kb") end,
  }, {
    ui.row({ align = "center", gap = 8 }, {
      S.batteryIcon(pct, ink, "big"),
      ui.row({ gap = 1, align = "center" }, {
        ui.label({ text = tostring(pct), fontFamily = S.mono, fontSize = S.FS.xl, color = S.C.text, width = 30, textAlign = "end" }),
        ui.row({ width = 15, align = "center", justify = "start" }, { mark }),
      }),
    }),
    -- flush with the tiles' edge, so hover brightens the line instead of filling a box
    ui.label({ text = table.concat(detail, " · "), fontFamily = S.mono, fontSize = S.FS.sm, color = if H.id == "batt" then S.C.sub else S.C.dim }),
  })
end

-- ── page ────────────────────────────────────────────────────────────────────

function render()
  local now = os.time()
  local devices = bt.devices or {}
  local btSub = if not bt.powered then "Off" elseif #devices > 0 then devices[1] else "On"
  local wifiSub = if wifi.wired then "Wired" elseif not wifi.radio then "Off" elseif wifi.connected then wifi.ssid else "Not connected"

  local top = {
    ui.label({ text = noctalia.formatTime("%H:%M", now), fontFamily = S.mono, fontSize = S.FS.big, color = S.C.text }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      S.caption(noctalia.formatTime("%A %d %B", now), S.C.sub),
      ui.label({ text = `{who.user}@{who.host} · up {fmtUptime(who.uptime)}`, fontFamily = S.mono, fontSize = S.FS.sm, color = S.C.dim }),
    }),
  }
  if batt.present ~= false then table.insert(top, battery()) end
  local kids = {
    ui.row({ align = "end", gap = 14 }, top),
    S.hline("hh1"),
    ui.row({ gap = 6 }, {
      tile("wifi", if wifi.radio then "wifi" else "wifi-off", "Wi-Fi", wifiSub, wifi.radio == true, function()
        S.svc("wifi", if wifi.radio then "off" else "on")
      end),
      tile("bt", if bt.powered then "bluetooth" else "bluetooth-off", "Bluetooth", btSub, bt.powered == true, function()
        S.svc("bt", if bt.powered then "off" else "on")
      end),
      tile("dnd", "bell-z", "Do not disturb", if notif.dnd then "On" else "Off", notif.dnd == true, function()
        S.svc("dnd", if notif.dnd then "off" else "on")
      end),
    }),
    ui.row({ gap = 6 }, {
      tile("night", "moon", "Night light", if night then "On" else "Off", night, function()
        S.svc("night", if night then "off" else "on")
      end),
      tile("caffeine", "coffee", "Caffeine", if caffeine then "Awake" else "Off", caffeine, function()
        S.svc("caffeine", if caffeine then "off" else "on")
      end),
      tile("profile", S.PROFILE_GLYPH[power.profile or ""] or "gauge",
        "Power profile", S.PROFILE_LABEL[power.profile or ""] or "—", false, function() S.svc("profile", "next") end),
    }),
  }
  table.insert(kids, S.hline("hh2"))
  if vol then
    table.insert(kids, levelRow("vol", S.volumeGlyph(vol.pct, vol.muted), vol.pct,
      if vol.muted then "MUTE" else `{vol.pct}%`, vol.muted, setVolume, function() S.svc("mute", "out") end))
  else
    table.insert(kids, ui.spacer({ height = 34 }))
  end
  if bright.dev then
    -- the glyph only marks the row; it doesn't click
    table.insert(kids, levelRow("bri", "brightness-half", bright.pct, `{bright.pct}%`, false, setBrightness, nil))
  end
  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, kids))
end

readBrightness()

-- clock, uptime and brightness tick while open
function update()
  readUptime()
  readBrightness() -- follows the brightness keys while open
  render()
end

function onOpen(_context)
  who.host = trim(noctalia.readFile("/etc/hostname"))
  who.user = noctalia.getenv("USER") or ""
  readUptime()
  vol = S.read("graphite.vol")
  power = S.read("graphite.power") or power
  batt = S.read("graphite.batt") or batt
  S.poke("power")
  readBrightness()
  panel.setWantsSecondTicks(true)
  render()
end

function onClose()
  panel.setWantsSecondTicks(false)
end

S.watch("graphite.wifi", function(v) if type(v) == "table" then wifi = v; render() end end)
S.watch("graphite.bt", function(v) if type(v) == "table" then bt = v; render() end end)
S.watch("graphite.notif", function(v) if type(v) == "table" then notif = v; render() end end)
S.watch("graphite.vol", function(v) if type(v) == "table" then vol = v; render() end end)
S.watch("graphite.power", function(v) if type(v) == "table" then power = v; render() end end)
S.watch("graphite.batt", function(v) if type(v) == "table" then batt = v; render() end end)
noctalia.state.watch("graphite.caffeine", function(v) caffeine = v == true; render() end)
noctalia.state.watch("graphite.night", function(v) night = v == true; render() end)

render()
