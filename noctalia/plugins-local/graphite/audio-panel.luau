--!nonstrict
-- Audio panel, attached under the audio key: output volume and device, input
-- volume and device. Levels come from the service, so the panel follows volume keys
-- while open. A slider value equal to the current level is ignored, so opening the
-- panel can never change a level by itself. The panel's height follows its content
-- (plugin.toml height = "content"); the device lists are cached in graphite.audioDevs,
-- so a reopened panel draws at its final size straight away.

local S = require("./style.luau")
S.fonts()

local vol = S.read("graphite.vol")
local cached = S.read("graphite.audioDevs")
local sinks, sources = {}, {}
local defSink, defSource = "", ""
local devicesLoaded = false
if type(cached) == "table" then
  sinks, sources = cached.sinks or {}, cached.sources or {}
  defSink, defSource = cached.defSink or "", cached.defSource or ""
  devicesLoaded = true
end
local isOpen = false
local H = S.hover(function() render() end)

local function trim(s) return noctalia.string.trim(s or "") end

local function readDevices()
  noctalia.runAsync("pactl -f json list sinks; echo; echo '--'; pactl -f json list sources; echo; echo '--'; pactl get-default-sink; echo '--'; pactl get-default-source", function(r)
    local parts = S.parts(r.stdout)
    local function list(raw, skipMonitors)
      local out = {}
      local d = noctalia.json.decode(trim(raw))
      if type(d) == "table" then
        for _, x in d do
          if not (skipMonitors and string.find(x.name or "", ".monitor", 1, true)) then
            table.insert(out, { name = x.name, desc = x.description or x.name })
          end
        end
      end
      return out
    end
    sinks = list(parts[1], false)
    sources = list(parts[2], true)
    defSink, defSource = trim(parts[3]), trim(parts[4])
    devicesLoaded = true
    noctalia.state.set("graphite.audioDevs", noctalia.json.encode({
      sinks = sinks, sources = sources, defSink = defSink, defSource = defSource,
    }))
    render()
  end, 5000)
end

local function setVolume(which, pct)
  if not vol then return end
  local field = if which == "out" then "pct" else "inPct"
  if pct == vol[field] then return end
  vol[field] = pct
  local target = if which == "out" then "@DEFAULT_AUDIO_SINK@" else "@DEFAULT_AUDIO_SOURCE@"
  S.run({ "wpctl", "set-volume", target, string.format("%.2f", pct / 100) })
  render()
end

local function setDefault(kind, name)
  if kind == "sink" then defSink = name else defSource = name end
  render()
  S.exec({ "pactl", if kind == "sink" then "set-default-sink" else "set-default-source", name }, 4000, function()
    readDevices()
  end)
end

-- Mute key, level meter, readout. While the pointer is over the meter the
-- readout shows the level a click would set.
local function levelRow(key, glyph, muted, value, onSet, onGlyph)
  local meter, preview = S.meter({ key = key .. "-m", value = value, H = H, onSet = onSet })
  local text = if preview then `{preview}%` elseif muted then "MUTE" else `{value}%`
  return ui.row({ key = key, gap = 10, align = "center", height = 34 }, {
    S.glyphKey({ key = key .. "-g", glyph = glyph, color = if muted then S.C.dim else S.C.sub,
      hovered = H.id == key .. "-g", onHover = H.fn(key .. "-g"),
      tooltip = if muted then "Unmute" else "Mute", onClick = onGlyph }),
    meter,
    ui.label({ text = text, fontFamily = S.mono, fontSize = S.FS.md,
      color = if preview then S.C.sub elseif muted then S.C.dim else S.C.text, width = 44, textAlign = "end" }),
  })
end

local function deviceRow(kind, d, isDefault)
  local id = kind .. "-" .. d.name
  return S.item({
    key = id,
    height = 34,
    hovered = H.id == id,
    selected = isDefault,
    onHover = H.fn(id),
    onClick = function() if not isDefault then setDefault(kind, d.name) end end,
  }, {
    ui.glyph({ name = if kind == "sink" then "device-speaker" else "microphone", size = 15, color = if isDefault then S.C.text else S.C.sub }),
    ui.label({ text = d.desc, fontFamily = S.sans, fontSize = S.FS.md, color = if isDefault then S.C.text else S.C.body, flexGrow = 1, maxWidth = 260, maxLines = 1 }),
    S.caption(if isDefault then "in use" else "", S.C.sub),
  })
end

function render()
  local body = { S.header("volume", "Audio", {}), S.hline("h1") }
  if not vol or not devicesLoaded then
    table.insert(body, S.placeholder("volume", "Reading audio devices…"))
  else
    local outs = {}
    for _, d in sinks do table.insert(outs, deviceRow("sink", d, d.name == defSink)) end
    local ins = {}
    for _, d in sources do table.insert(ins, deviceRow("source", d, d.name == defSource)) end
    for _, x in {
      S.caption("Output", S.C.sub),
      levelRow("out", S.volumeGlyph(vol.pct, vol.muted), vol.muted, vol.pct,
        function(v) setVolume("out", v) end, function() S.svc("mute", "out") end),
      ui.column({ gap = 1, align = "stretch" }, outs),
      S.hline("h2"),
      S.caption("Input", S.C.sub),
      levelRow("in", if vol.inMuted then "microphone-off" else "microphone", vol.inMuted, vol.inPct,
        function(v) setVolume("in", v) end, function() S.svc("mute", "in") end),
      ui.column({ gap = 1, align = "stretch" }, ins),
    } do table.insert(body, x) end
  end
  -- no flexGrow: the panel takes this column's height
  panel.render(ui.column({ gap = 10, align = "stretch" }, body))
end

S.watch("graphite.vol", function(v)
  if type(v) == "table" then vol = v; render() end
end)
-- a device appeared or went away, or the default moved
noctalia.state.watch("graphite.audioRev", function(_v)
  if isOpen then readDevices() end
end)

function onOpen(_context)
  isOpen = true
  vol = S.read("graphite.vol")
  S.poke("vol")
  readDevices()
  render()
end

function onClose()
  isOpen = false
end

render()
