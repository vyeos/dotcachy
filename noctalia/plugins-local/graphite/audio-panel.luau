--!nonstrict
-- Audio panel, attached under the audio key: output volume and device, input
-- volume and device. Sliders appear only after the real levels are read, and a
-- slider value equal to the current level is ignored, so opening the panel can
-- never change a level by itself.

local S = require("./style.luau")
S.fonts()

local vol = { out = 0, outMuted = false, inp = 0, inpMuted = false, loaded = false }
local sinks, sources = {}, {}
local defSink, defSource = "", ""
local hovered = nil

local function trim(s) return noctalia.string.trim(s or "") end

local function readVolumes()
  noctalia.runAsync("wpctl get-volume @DEFAULT_AUDIO_SINK@; echo '--'; wpctl get-volume @DEFAULT_AUDIO_SOURCE@", function(r)
    local a, b = string.match(r.stdout or "", "^(.-)\n%-%-\n(.*)$")
    local function parse(s)
      local v = tonumber(string.match(s or "", "Volume:%s*([%d%.]+)")) or 0
      return math.floor(v * 100 + 0.5), string.find(s or "", "MUTED", 1, true) ~= nil
    end
    vol.out, vol.outMuted = parse(a)
    vol.inp, vol.inpMuted = parse(b)
    vol.loaded = string.find(r.stdout or "", "Volume:", 1, true) ~= nil
    render()
  end, 4000)
end

local function readDevices()
  noctalia.runAsync("pactl -f json list sinks; echo; echo '--'; pactl -f json list sources; echo; echo '--'; pactl get-default-sink; echo '--'; pactl get-default-source", function(r)
    local parts = {}
    for chunk in string.gmatch((r.stdout or "") .. "\n--\n", "(.-)\n%-%-\n") do table.insert(parts, chunk) end
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
    render()
  end, 5000)
end

local function setVolume(which, pct)
  if not vol.loaded then return end
  if pct == (if which == "out" then vol.out else vol.inp) then return end
  local target = if which == "out" then "@DEFAULT_AUDIO_SINK@" else "@DEFAULT_AUDIO_SOURCE@"
  local before = S.volumeGlyph(vol.out, vol.outMuted)
  if which == "out" then vol.out = pct else vol.inp = pct end
  S.exec({ "wpctl", "set-volume", target, string.format("%.2f", pct / 100) }, 3000, function() S.poke("vol") end)
  -- Redraw mid-drag only when the icon changes. Safe: the guard above drops the echoed onChange.
  if S.volumeGlyph(vol.out, vol.outMuted) ~= before then render() end
end

local function toggleMute(which)
  local target = if which == "out" then "@DEFAULT_AUDIO_SINK@" else "@DEFAULT_AUDIO_SOURCE@"
  S.exec({ "wpctl", "set-mute", target, "toggle" }, 3000, function()
    S.poke("vol")
    readVolumes()
  end)
end

local function setDefault(kind, name)
  if kind == "sink" then defSink = name else defSource = name end
  render()
  S.exec({ "pactl", if kind == "sink" then "set-default-sink" else "set-default-source", name }, 4000, function()
    S.poke("vol")
    readVolumes()
    readDevices()
  end)
end

local function hoverFn(id)
  return function(st)
    hovered = if st == "true" then id elseif hovered == id then nil else hovered
    render()
  end
end

local function sliderRow(key, glyph, muted, value, onChange, onGlyph)
  return ui.row({ key = key, gap = 10, align = "center", height = 34 }, {
    ui.button({ glyph = glyph, variant = "ghost", tooltip = if muted then "Unmute" else "Mute", onClick = onGlyph }),
    ui.slider({ key = key .. "-s", min = 0, max = 100, step = 1, value = math.clamp(value, 0, 100), flexGrow = 1, onChange = onChange }),
    ui.label({ text = if muted then "MUTE" else `{value}%`, fontFamily = S.mono, fontSize = 12, color = if muted then S.C.dim else S.C.text, width = 44, textAlign = "end" }),
  })
end

local function deviceRow(kind, d, isDefault)
  local id = kind .. "-" .. d.name
  return S.item({
    key = id,
    height = 34,
    hovered = hovered == id,
    selected = isDefault,
    onHover = hoverFn(id),
    onClick = function() if not isDefault then setDefault(kind, d.name) end end,
  }, {
    ui.glyph({ name = if kind == "sink" then "device-speaker" else "microphone", size = 15, color = if isDefault then S.C.text else S.C.sub }),
    ui.label({ text = d.desc, fontFamily = S.sans, fontSize = 12.5, color = if isDefault then S.C.text else "on_surface/0.85", flexGrow = 1, maxWidth = 260, maxLines = 1 }),
    S.caption(if isDefault then "in use" else "", S.C.sub),
  })
end

function render()
  local body = { S.header("volume", "Audio", {}), S.hline("h1") }
  if not vol.loaded then
    table.insert(body, ui.label({ text = "Reading audio devices…", fontFamily = S.sans, color = S.C.dim }))
  else
    table.insert(body, S.caption("Output", S.C.sub))
    table.insert(body, sliderRow("out", S.volumeGlyph(vol.out, vol.outMuted), vol.outMuted, vol.out,
      function(v) setVolume("out", math.floor(tonumber(v) or 0)) end, function() toggleMute("out") end))
    local outs = {}
    for _, d in sinks do table.insert(outs, deviceRow("sink", d, d.name == defSink)) end
    table.insert(body, ui.column({ gap = 1, align = "stretch" }, outs))
    table.insert(body, S.hline("h2"))
    table.insert(body, S.caption("Input", S.C.sub))
    table.insert(body, sliderRow("in", if vol.inpMuted then "microphone-off" else "microphone", vol.inpMuted, vol.inp,
      function(v) setVolume("in", math.floor(tonumber(v) or 0)) end, function() toggleMute("in") end))
    local ins = {}
    for _, d in sources do table.insert(ins, deviceRow("source", d, d.name == defSource)) end
    table.insert(body, ui.column({ gap = 1, align = "stretch" }, ins))
  end
  panel.render(ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, body))
end

function onOpen(_context)
  vol.loaded = false
  readVolumes()
  readDevices()
end

render()
