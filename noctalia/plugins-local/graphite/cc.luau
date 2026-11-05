--!nonstrict
-- Graphite control center: a single Home page, sized to its content. Clock and
-- uptime, six quick toggles, and brightness. Opened from the clock or by
-- right-clicking the logo. Wi-Fi, Bluetooth, audio and power have their own
-- panels under their bar keys; the tiles here only flip the radios and modes.

local S = require("./style.luau")
S.fonts()

local hovered = nil

local wifi = S.read("graphite.wifi") or {}
local bt = S.read("graphite.bt") or { devices = {} }
local notif = S.read("graphite.notif") or {}
local caffeine = noctalia.state.get("graphite.caffeine") == true
local night = noctalia.state.get("graphite.night") == true
local profile = ""
local bright = { dev = nil, pct = 0 }
local vol = { pct = 0, muted = false, loaded = false }
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

local function readBrightness()
  noctalia.runAsync({ "brightnessctl", "-l", "-m", "-c", "backlight" }, function(r)
    local pick, pickPct = nil, 0
    for line in string.gmatch(r.stdout or "", "[^\n]+") do
      local dev, pct = string.match(line, "^([^,]+),backlight,%d+,(%d+)%%")
      -- prefer the panel's own backlight over a discrete GPU's
      if dev and (pick == nil or string.find(pick, "nvidia", 1, true)) then pick, pickPct = dev, tonumber(pct) or 0 end
    end
    bright.dev, bright.pct = pick, pickPct
    render()
  end, 3000)
end

local function readVolume()
  noctalia.runAsync({ "wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@" }, function(r)
    local v = tonumber(string.match(r.stdout or "", "Volume:%s*([%d%.]+)"))
    if v then
      vol.pct = math.floor(v * 100 + 0.5)
      vol.muted = string.find(r.stdout, "MUTED", 1, true) ~= nil
      vol.loaded = true
    end
    render()
  end, 3000)
end

local function readProfile()
  noctalia.runAsync({ "powerprofilesctl", "get" }, function(r)
    profile = trim(r.stdout)
    render()
  end, 3000)
end

-- ── actions ─────────────────────────────────────────────────────────────────

-- Sliders also report programmatic value changes: ignore a value we already hold.
local function setBrightness(pct)
  if not bright.dev or pct == bright.pct then return end
  bright.pct = pct
  S.run({ "brightnessctl", "-q", "-d", bright.dev, "set", `{math.max(1, pct)}%` })
end

-- Same guard for volume: only after the real reading, and never an echoed value.
local function setVolume(pct)
  if not vol.loaded or pct == vol.pct then return end
  local before = S.volumeGlyph(vol.pct, vol.muted)
  vol.pct = pct
  S.exec({ "wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", string.format("%.2f", pct / 100) }, 3000, function() S.poke("vol") end)
  -- Redraw mid-drag only when the icon changes. Safe: the guard above drops the echoed onChange.
  if S.volumeGlyph(vol.pct, vol.muted) ~= before then render() end
end

local function toggleMute()
  S.exec({ "wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle" }, 3000, function()
    S.poke("vol")
    readVolume()
  end)
end

local PROFILES = { "power-saver", "balanced", "performance" }
local PROFILE_LABEL = { ["power-saver"] = "Saver", balanced = "Balanced", performance = "Performance" }
local function cycleProfile()
  local i = 1
  for k, p in PROFILES do if p == profile then i = k end end
  local nextP = PROFILES[(i % #PROFILES) + 1]
  profile = nextP
  render()
  S.exec({ "powerprofilesctl", "set", nextP }, 4000, function() readProfile() end)
end

-- ── pieces ──────────────────────────────────────────────────────────────────

local function hoverFn(id)
  return function(st)
    hovered = if st == "true" then id elseif hovered == id then nil else hovered
    render()
  end
end

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
    fill = if on then S.C.text elseif hovered == "tile-" .. id then S.C.keyHover else S.C.key,
    align = "start",
    justify = "center",
    onClick = onClick,
    onHover = hoverFn("tile-" .. id),
  }, {
    ui.glyph({ name = glyph, size = 18, color = if on then "surface" else S.C.sub }),
    ui.label({ text = label, fontFamily = S.sans, fontSize = 13, color = if on then "surface" else S.C.text }),
    ui.label({ text = sub, fontFamily = S.mono, fontSize = 10.5, color = if on then "surface/0.7" else S.C.dim, maxWidth = 130, maxLines = 1 }),
  })
end

-- ── page ────────────────────────────────────────────────────────────────────

function render()
  local now = os.time()
  local devices = bt.devices or {}
  local btSub = if not bt.powered then "Off" elseif #devices > 0 then devices[1] else "On"
  local wifiSub = if wifi.wired then "Wired" elseif not wifi.radio then "Off" elseif wifi.connected then wifi.ssid else "Not connected"

  local kids = {
    ui.row({ align = "end", gap = 14 }, {
      ui.label({ text = noctalia.formatTime("%H:%M", now), fontFamily = S.mono, fontSize = 34, color = S.C.text }),
      ui.column({ gap = 2, flexGrow = 1 }, {
        S.caption(noctalia.formatTime("%A %d %B", now), S.C.sub),
        ui.label({ text = `{who.user}@{who.host} · up {fmtUptime(who.uptime)}`, fontFamily = S.mono, fontSize = 11, color = S.C.dim }),
      }),
    }),
    S.hline("hh1"),
    ui.row({ gap = 6 }, {
      tile("wifi", if wifi.radio then "wifi" else "wifi-off", "Wi-Fi", wifiSub, wifi.radio == true, function()
        S.svc("wifi", if wifi.radio then "off" else "on")
        wifi.radio = not wifi.radio
        render()
      end),
      tile("bt", if bt.powered then "bluetooth" else "bluetooth-off", "Bluetooth", btSub, bt.powered == true, function()
        S.svc("bt", if bt.powered then "off" else "on")
        bt.powered = not bt.powered
        render()
      end),
      tile("dnd", "bell-z", "Do not disturb", if notif.dnd then "On" else "Off", notif.dnd == true, function()
        notif.dnd = not notif.dnd
        S.setDnd(notif.dnd)
        render()
      end),
    }),
    ui.row({ gap = 6 }, {
      tile("night", "moon", "Night light", if night then "On" else "Off", night, function()
        night = not night
        S.svc("night", if night then "on" else "off")
        render()
      end),
      tile("caffeine", "coffee", "Caffeine", if caffeine then "Awake" else "Off", caffeine, function()
        caffeine = not caffeine
        S.svc("caffeine", if caffeine then "on" else "off")
        render()
      end),
      tile("profile", if profile == "performance" then "rocket" elseif profile == "balanced" then "gauge" else "leaf",
        "Power profile", PROFILE_LABEL[profile] or "—", false, cycleProfile),
    }),
  }
  table.insert(kids, S.hline("hh2"))
  if vol.loaded then
    table.insert(kids, ui.row({ key = "vol", gap = 10, align = "center", height = 34 }, {
      ui.button({ glyph = S.volumeGlyph(vol.pct, vol.muted), variant = "ghost", onClick = toggleMute }),
      ui.slider({ key = "vol-s", min = 0, max = 100, step = 1, value = math.clamp(vol.pct, 0, 100), flexGrow = 1,
        onChange = function(v) setVolume(math.floor(tonumber(v) or 0)) end }),
      ui.label({ text = if vol.muted then "MUTE" else `{vol.pct}%`, fontFamily = S.mono, fontSize = 12, color = if vol.muted then S.C.dim else S.C.text, width = 44, textAlign = "end" }),
    }))
  else
    table.insert(kids, ui.spacer({ height = 34 }))
  end
  if bright.dev then
    table.insert(kids, ui.row({ key = "bri", gap = 10, align = "center", height = 34 }, {
      ui.button({ glyph = "brightness-half", variant = "ghost" }),
      ui.slider({ key = "bri-s", min = 0, max = 100, step = 1, value = math.clamp(bright.pct, 0, 100), flexGrow = 1,
        onChange = function(v) setBrightness(math.floor(tonumber(v) or 0)) end }),
      ui.label({ text = `{bright.pct}%`, fontFamily = S.mono, fontSize = 12, color = S.C.text, width = 44, textAlign = "end" }),
    }))
  end
  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, kids))
end

-- clock and uptime tick while open
function update()
  readUptime()
  render()
end

function onOpen(_context)
  who.host = trim(noctalia.readFile("/etc/hostname"))
  who.user = noctalia.getenv("USER") or ""
  readUptime()
  vol.loaded = false
  readVolume()
  readBrightness()
  readProfile()
  panel.setWantsSecondTicks(true)
  render()
end

function onClose()
  panel.setWantsSecondTicks(false)
end

S.watch("graphite.wifi", function(v) if type(v) == "table" then wifi = v; render() end end)
S.watch("graphite.bt", function(v) if type(v) == "table" then bt = v; render() end end)
S.watch("graphite.notif", function(v) if type(v) == "table" then notif = v; render() end end)

render()
