--!nonstrict
-- Bluetooth panel, attached under the Bluetooth key. Power on/off, paired
-- devices (click to connect or disconnect, forget from the row), and a scan
-- for nearby devices (click to pair, trust and connect).

local S = require("./style.luau")
S.fonts()

local powered = (S.read("graphite.bt") or {}).powered == true
local isOpen = false
local loaded = false    -- the device list has been read at least once
local devices = {}      -- { mac, name, paired, connected }
local scanning = false
local busy = nil        -- mac being worked on
local status = ""
local H = S.hover(function() render() end)
local HX = S.hover(function() render() end)  -- the forget box
local A = S.confirm(function() render() end)

-- Second ticks drive the scan's list polling and expire an armed forget.
local function syncTicks()
  panel.setWantsSecondTicks(scanning or A.id ~= nil)
end

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
  local cmd = "bluetoothctl devices 2>/dev/null; echo '--'; bluetoothctl devices Paired 2>/dev/null; echo '--'; bluetoothctl devices Connected 2>/dev/null"
  noctalia.runAsync(cmd, function(r)
    local parts = S.parts(r.stdout)
    local function macs(text)
      local set = {}
      for mac in string.gmatch(text or "", "Device (%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)") do set[mac] = true end
      return set
    end
    local paired, connected = macs(parts[2]), macs(parts[3])
    local list = {}
    for line in string.gmatch(parts[1] or "", "[^\n]+") do
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
    loaded = true
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

local function forget(d)
  busy = d.mac
  status = ""
  render()
  -- remove also disconnects, and takes the pairing and trust with it
  S.exec({ "bluetoothctl", "remove", d.mac }, 15000, function(ok, msg)
    busy = nil
    status = if ok then "Forgot " .. d.name elseif msg ~= "" then msg else "Could not forget " .. d.name
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
  syncTicks()
  S.exec({ "bluetoothctl", "--timeout", "12", "scan", "on" }, 20000, function(_ok, _msg)
    scanning = false
    syncTicks()
    refresh()
  end)
end

local tick = 0
function update()
  if A.tick() then
    syncTicks()
    render()
  end
  if not scanning then return end
  tick += 1
  if tick % 2 == 0 then refresh() end
end

local function setPower(on)
  if on == powered then return end -- echo of a programmatic change
  S.svc("bt", if on then "on" else "off")
end

local function devRow(d)
  local state = if busy == d.mac then "working" elseif d.connected then "connected" elseif d.paired then "paired" else "pair"
  local mine = d.paired or d.connected
  local armed = A.id == d.mac
  local kids = {
    ui.glyph({ name = glyphFor(d.name), size = 16, color = if d.connected then S.C.text else S.C.sub }),
    ui.label({ text = d.name, fontFamily = S.sans, fontSize = S.FS.body, color = if d.connected then S.C.text else S.C.body, flexGrow = 1, maxWidth = if mine then 170 else 200, maxLines = 1 }),
  }
  if not armed then table.insert(kids, S.caption(state, if d.connected then S.C.sub else S.C.dim)) end
  if mine then
    table.insert(kids, S.forget({
      key = "forget-" .. d.mac,
      armed = armed,
      shown = H.id == d.mac or HX.id == d.mac,
      hovered = HX.id == d.mac,
      onHover = HX.fn(d.mac),
      onClick = function()
        if busy ~= nil then return end
        A.click(d.mac, function() forget(d) end)
        syncTicks()
      end,
    }))
  end
  return S.item({
    key = "dev-" .. d.mac,
    hovered = H.id == d.mac,
    selected = d.connected,
    tooltip = d.mac,
    onHover = H.fn(d.mac),
    onClick = function() if busy == nil then act(d) end end,
  }, kids)
end

function render()
  local rows = {}
  if not powered then
    table.insert(rows, S.placeholder("bluetooth-off", "Bluetooth is off"))
  elseif not loaded then
    table.insert(rows, S.placeholder("bluetooth", "Reading devices…"))
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
      S.switch({ key = "power", on = powered, hovered = H.id == "power-switch", onHover = H.fn("power-switch"),
        onClick = function() setPower(not powered) end }),
    }),
    S.hline("h1"),
    S.list("devs", rows),
  }
  if status ~= "" then
    table.insert(body, S.status(status))
  end
  panel.render(ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, body))
end

-- The service owns the radio; follow it and re-read the list when it changes.
S.watch("graphite.bt", function(v)
  if type(v) ~= "table" then return end
  local was = powered
  powered = v.powered == true
  if isOpen and (powered ~= was or scanning == false) then refresh() else render() end
end)

function onOpen(_context)
  isOpen = true
  status = ""
  local v = S.read("graphite.bt")
  if type(v) == "table" then powered = v.powered == true end
  refresh()
end

function onClose()
  isOpen = false
  A.id, H.id, HX.id = nil, nil, nil
  panel.setWantsSecondTicks(false)
end

render()
