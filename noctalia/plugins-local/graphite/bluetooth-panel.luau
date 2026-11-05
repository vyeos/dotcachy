--!nonstrict
-- Bluetooth panel, attached under the Bluetooth key. Power on/off, paired
-- devices (click to connect or disconnect), and a scan for nearby devices
-- (click to pair, trust and connect).

local S = require("./style.luau")
S.fonts()

local powered = false
local devices = {}      -- { mac, name, paired, connected }
local scanning = false
local busy = nil        -- mac being worked on
local status = ""
local hovered = nil

local function glyphFor(name)
  local n = string.lower(name or "")
  for _, p in {
    { "bud", "headphones" }, { "pod", "headphones" }, { "head", "headphones" }, { "wh-", "headphones" },
    { "wf-", "headphones" }, { "earph", "headphones" }, { "mouse", "mouse" }, { "mx ", "mouse" },
    { "keyboard", "keyboard" }, { "keys", "keyboard" }, { "speaker", "device-speaker" }, { "soundbar", "device-speaker" },
    { "controller", "device-gamepad" }, { "pad", "device-gamepad" }, { "phone", "device-mobile" },
    { "pixel", "device-mobile" }, { "galaxy", "device-mobile" }, { "iphone", "device-mobile" },
  } do
    if string.find(n, p[1], 1, true) then return p[2] end
  end
  return "bluetooth"
end

local refresh

refresh = function()
  local cmd = "bluetoothctl show 2>/dev/null | grep -m1 'Powered:'; echo '--'; bluetoothctl devices 2>/dev/null; echo '--'; bluetoothctl devices Paired 2>/dev/null; echo '--'; bluetoothctl devices Connected 2>/dev/null"
  noctalia.runAsync(cmd, function(r)
    local parts = {}
    for chunk in string.gmatch((r.stdout or "") .. "\n--\n", "(.-)\n%-%-\n") do table.insert(parts, chunk) end
    powered = string.find(parts[1] or "", "yes", 1, true) ~= nil
    local function macs(text)
      local set = {}
      for mac in string.gmatch(text or "", "Device (%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)") do set[mac] = true end
      return set
    end
    local paired, connected = macs(parts[3]), macs(parts[4])
    local list = {}
    for line in string.gmatch(parts[2] or "", "[^\n]+") do
      local mac, name = string.match(line, "^Device (%x%x:%x%x:%x%x:%x%x:%x%x:%x%x) (.+)$")
      if mac then
        -- unnamed scan results show their MAC as the name; keep them, they are pairable
        table.insert(list, { mac = mac, name = name, paired = paired[mac] == true, connected = connected[mac] == true })
      end
    end
    table.sort(list, function(a, b)
      if a.connected ~= b.connected then return a.connected end
      if a.paired ~= b.paired then return a.paired end
      return string.lower(a.name) < string.lower(b.name)
    end)
    devices = list
    render()
  end, 8000)
end

local function act(d)
  busy = d.mac
  status = ""
  render()
  local argv
  if d.connected then
    argv = { "bluetoothctl", "disconnect", d.mac }
  elseif d.paired then
    argv = { "bluetoothctl", "connect", d.mac }
  else
    argv = { "sh", "-c", 'bluetoothctl pair "$1" && bluetoothctl trust "$1" && bluetoothctl connect "$1"', "sh", d.mac }
  end
  S.exec(argv, 40000, function(ok, msg)
    busy = nil
    local verb = if d.connected then "Disconnected" elseif d.paired then "Connected" else "Paired"
    status = if ok then `{verb} {d.name}` else (if msg ~= "" then msg else "Failed: " .. d.name)
    S.poke("bt")
    refresh()
  end)
end

local function scan()
  if scanning then return end
  scanning = true
  status = ""
  render()
  -- poll the list while the scan runs so devices appear as they are found
  panel.setWantsSecondTicks(true)
  S.exec({ "bluetoothctl", "--timeout", "12", "scan", "on" }, 20000, function(_ok, _msg)
    scanning = false
    panel.setWantsSecondTicks(false)
    refresh()
  end)
end

local tick = 0
function update()
  if not scanning then return end
  tick += 1
  if tick % 2 == 0 then refresh() end
end

local function setPower(on)
  powered = on
  render()
  S.exec({ "bluetoothctl", "power", if on then "on" else "off" }, 10000, function(ok, msg)
    if not ok then status = msg end
    S.poke("bt")
    refresh()
  end)
end

local function devRow(d)
  local state = if busy == d.mac then "working" elseif d.connected then "connected" elseif d.paired then "paired" else "pair"
  return S.item({
    key = "dev-" .. d.mac,
    hovered = hovered == d.mac,
    selected = d.connected,
    tooltip = d.mac,
    onHover = function(st)
      hovered = if st == "true" then d.mac elseif hovered == d.mac then nil else hovered
      render()
    end,
    onClick = function() if busy == nil then act(d) end end,
  }, {
    ui.glyph({ name = glyphFor(d.name), size = 16, color = if d.connected then S.C.text else S.C.sub }),
    ui.label({ text = d.name, fontFamily = S.sans, fontSize = 13, color = if d.connected then S.C.text else "on_surface/0.85", flexGrow = 1, maxWidth = 200, maxLines = 1 }),
    S.caption(state, if d.connected then S.C.sub else S.C.dim),
  })
end

function render()
  local rows = {}
  if not powered then
    table.insert(rows, ui.column({ height = 120, align = "center", justify = "center", gap = 8 }, {
      ui.glyph({ name = "bluetooth-off", size = 26, color = S.C.dim }),
      ui.label({ text = "Bluetooth is off", color = S.C.dim, fontFamily = S.sans }),
    }))
  else
    local mine, nearby = {}, {}
    for _, d in devices do
      if d.paired or d.connected then table.insert(mine, d) else table.insert(nearby, d) end
    end
    table.insert(rows, S.caption("My devices"))
    if #mine == 0 then
      table.insert(rows, ui.label({ text = "No paired devices yet", color = S.C.dim, fontFamily = S.sans }))
    end
    for _, d in mine do table.insert(rows, devRow(d)) end
    table.insert(rows, ui.spacer({ height = 8 }))
    table.insert(rows, ui.row({ align = "center" }, {
      S.caption("Nearby"),
      ui.spacer({ flexGrow = 1 }),
      S.caption(if scanning then "scanning" else ""),
    }))
    if #nearby == 0 then
      table.insert(rows, ui.label({ text = if scanning then "Looking for devices…" else "Scan to find devices", color = S.C.dim, fontFamily = S.sans }))
    end
    for _, d in nearby do table.insert(rows, devRow(d)) end
  end

  local body = {
    S.header("bluetooth", "Bluetooth", {
      ui.button({ glyph = "refresh", variant = "ghost", tooltip = "Scan for devices", enabled = powered and not scanning, onClick = scan }),
      ui.toggle({ checked = powered, onChange = function(v) setPower(v == "true") end }),
    }),
    S.hline("h1"),
    ui.scroll({ flexGrow = 1, gap = 1 }, rows),
  }
  if status ~= "" then
    table.insert(body, ui.label({ text = status, fontFamily = S.mono, fontSize = 11, color = S.C.sub, maxLines = 2 }))
  end
  panel.render(ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, body))
end

function onOpen(_context)
  status = ""
  refresh()
end

function onClose()
  panel.setWantsSecondTicks(false)
end

render()
