--!nonstrict
-- Wi-Fi panel, attached under the Wi-Fi key. Radio on/off, live download and
-- upload speed, the network list (current first, then saved, then by signal,
-- saved networks out of range last), join with an inline password field,
-- disconnect, and forget a saved network.

local S = require("./style.luau")
S.fonts()

local radio = (S.read("graphite.wifi") or { radio = true }).radio == true
local connected = (S.read("graphite.wifi") or {}).connected == true
local isOpen = false
local loaded = false  -- the network list has been read at least once
local pending = 0     -- list reads in flight
local device = nil
local nets = {}
local scanning = false
local busy = nil      -- ssid being joined
local pwFor = nil     -- ssid waiting for a password
local pw = ""
local status = ""
local H = S.hover(function() render() end)
local HX = S.hover(function() render() end)  -- the forget box
local A = S.confirm(function() render() end)
local rx, tx = nil, nil           -- bytes/s, nil until two samples exist
local lastBytes = nil             -- { rx, tx, ms }

-- Total bytes for the Wi-Fi device (or every non-loopback interface).
local function readBytes()
  local raw = noctalia.readFile("/proc/net/dev")
  if not raw then return nil end
  local r, t = 0, 0
  for name, rest in string.gmatch(raw, "%s*([%w%-%._]+):%s*([^\n]+)") do
    if (device and name == device) or (not device and name ~= "lo") then
      local nums = {}
      for n in string.gmatch(rest, "%d+") do table.insert(nums, tonumber(n)) end
      r += nums[1] or 0
      t += nums[9] or 0
    end
  end
  return { rx = r, tx = t, ms = noctalia.nowMs() }
end

local function sampleSpeed()
  local now = readBytes()
  if now and lastBytes and now.ms > lastBytes.ms then
    local dt = (now.ms - lastBytes.ms) / 1000
    rx = math.max(0, (now.rx - lastBytes.rx) / dt)
    tx = math.max(0, (now.tx - lastBytes.tx) / dt)
  end
  lastBytes = now
end

local function rate(bps)
  if bps == nil then return "—" end
  if bps >= 1024 * 1024 then return string.format("%.1f MB/s", bps / 1048576) end
  if bps >= 1024 then return string.format("%.0f KB/s", bps / 1024) end
  return string.format("%.0f B/s", bps)
end

local function sigGlyph(s)
  if s >= 67 then return "wifi" elseif s >= 34 then return "wifi-2" elseif s > 0 then return "wifi-1" end
  return "wifi-0"
end

local refresh

local function connect(ssid, password)
  local n = nil
  for _, x in nets do if x.ssid == ssid then n = x end end
  if not n then return end
  busy = ssid
  status = ""
  local argv
  if n.known then
    argv = { "nmcli", "connection", "up", "id", ssid }
  elseif n.secure then
    if not password or password == "" then
      pwFor = ssid; pw = ""; busy = nil
      render()
      return
    end
    argv = { "nmcli", "device", "wifi", "connect", ssid, "password", password }
  else
    argv = { "nmcli", "device", "wifi", "connect", ssid }
  end
  render()
  S.exec(argv, 45000, function(ok, msg)
    busy = nil
    if ok then
      pwFor = nil; pw = ""
      status = "Connected to " .. ssid
    else
      status = if msg ~= "" then msg else "Could not connect to " .. ssid
      if n.secure and not n.known then pwFor = ssid end
    end
    S.poke("net")
    refresh(false)
  end)
end

local function disconnect()
  if not device then return end
  S.exec({ "nmcli", "device", "disconnect", device }, 15000, function(ok, msg)
    status = if ok then "Disconnected" else msg
    S.poke("net")
    refresh(false)
  end)
end

local function forget(n)
  status = ""
  S.exec({ "nmcli", "connection", "delete", "id", n.ssid }, 15000, function(ok, msg)
    status = if ok then "Forgot " .. n.ssid elseif msg ~= "" then msg else "Could not forget " .. n.ssid
    S.poke("net")
    refresh(false)
  end)
end

local function setRadio(on)
  if on == radio then return end -- echo of a programmatic change
  S.svc("wifi", if on then "on" else "off")
end

refresh = function(rescan)
  pending += 1
  scanning = true
  render()
  local list = "nmcli -t -f IN-USE,SIGNAL,SECURITY,SSID device wifi list" .. (if rescan then " --rescan yes" else " --rescan no")
  local cmd = "nmcli -t -f DEVICE,TYPE device; echo '--'; nmcli -t -f NAME,TYPE connection show; echo '--'; " .. list .. " 2>/dev/null"
  noctalia.runAsync(cmd, function(r)
    local parts = S.parts(r.stdout)
    device = nil
    for line in string.gmatch(parts[1] or "", "[^\n]+") do
      local f = S.terse(line)
      if f[2] == "wifi" and not device then device = f[1] end
    end
    local known = {}
    for line in string.gmatch(parts[2] or "", "[^\n]+") do
      local f = S.terse(line)
      if f[2] == "802-11-wireless" then known[f[1]] = true end
    end
    local byName = {}
    for line in string.gmatch(parts[3] or "", "[^\n]+") do
      local f = S.terse(line)
      local ssid = f[4] or ""
      if ssid ~= "" then
        local sig = tonumber(f[2]) or 0
        local cur = byName[ssid]
        local entry = { ssid = ssid, signal = sig, secure = (f[3] or "") ~= "" and f[3] ~= "--", inUse = f[1] == "*", known = known[ssid] == true }
        if not cur or entry.inUse or (not cur.inUse and sig > cur.signal) then byName[ssid] = entry end
      end
    end
    nets = {}
    for _, n in byName do table.insert(nets, n) end
    for name in known do
      if not byName[name] then
        table.insert(nets, { ssid = name, signal = 0, secure = false, inUse = false, known = true, away = true })
      end
    end
    table.sort(nets, function(a, b)
      if (a.away == true) ~= (b.away == true) then return b.away == true end
      if a.inUse ~= b.inUse then return a.inUse end
      if a.known ~= b.known then return a.known end
      return a.signal > b.signal
    end)
    loaded = true
    pending -= 1
    scanning = pending > 0
    render()
  end, 20000)
end

local function netRow(n)
  local armed = A.id == n.ssid
  local kids = {
    ui.glyph({ name = sigGlyph(n.signal), size = 16, color = if n.inUse then S.C.text else S.C.sub }),
    -- saved rows give up width to the forget box
    ui.label({ text = n.ssid, fontFamily = S.sans, fontSize = S.FS.body, color = if n.inUse then S.C.text else S.C.body, flexGrow = 1, maxWidth = if n.known then 130 else 190, maxLines = 1 }),
  }
  if not armed then
    if busy == n.ssid then
      table.insert(kids, S.caption("joining"))
    elseif n.inUse then
      table.insert(kids, S.caption("connected", S.C.sub))
    elseif n.away then
      table.insert(kids, S.caption("out of range"))
    elseif n.known then
      table.insert(kids, S.caption("saved"))
    end
    if n.secure then table.insert(kids, ui.glyph({ name = "lock", size = 13, color = S.C.dim })) end
    if not n.away then
      table.insert(kids, ui.label({ text = `{n.signal}`, fontFamily = S.mono, fontSize = S.FS.sm, color = S.C.dim }))
    end
  end
  if n.known then
    table.insert(kids, S.forget({
      key = "forget-" .. n.ssid,
      armed = armed,
      shown = H.id == n.ssid or HX.id == n.ssid,
      hovered = HX.id == n.ssid,
      onHover = HX.fn(n.ssid),
      onClick = function() A.click(n.ssid, function() forget(n) end) end,
    }))
  end
  return S.item({
    key = "net-" .. n.ssid,
    hovered = H.id == n.ssid,
    selected = n.inUse,
    tooltip = if n.away then nil elseif n.inUse then "Click to disconnect" else "Click to join",
    onHover = H.fn(n.ssid),
    onClick = function()
      if n.away then return end
      if n.inUse then disconnect() else connect(n.ssid, nil) end
    end,
  }, kids)
end

function render()
  local rows = {}
  local inRange = 0
  for _, n in nets do if not n.away then inRange += 1 end end
  if not radio then
    table.insert(rows, S.placeholder("wifi-off", "Wi-Fi is off"))
  elseif #nets == 0 then
    table.insert(rows, S.placeholder("wifi-0", if scanning or not loaded then "Looking for networks…" else "No networks found"))
  else
    for _, n in nets do
      table.insert(rows, netRow(n))
      if pwFor == n.ssid then
        table.insert(rows, ui.row({ key = "pw-row-" .. n.ssid, gap = 8, align = "center", paddingH = 10, height = 44 }, {
          ui.input({ key = "pw-" .. n.ssid, password = true, placeholder = "Password for " .. n.ssid, flexGrow = 1, focus = true,
            onChange = function(v) pw = v end,
            onSubmit = function(v) connect(n.ssid, v) end }),
          ui.button({ text = "Join", variant = "primary", onClick = function() connect(n.ssid, pw) end }),
        }))
      end
    end
  end

  local body = {
    S.header("wifi", "Wi-Fi", {
      ui.button({ glyph = "refresh", variant = "ghost", tooltip = "Scan again", enabled = radio and not scanning, onClick = function() refresh(true) end }),
      ui.toggle({ checked = radio, onChange = function(v) setRadio(v == "true") end }),
    }),
    S.hline("h1"),
    ui.row({ align = "center", gap = 8, height = 22 }, {
      ui.glyph({ name = "arrow-down", size = 14, color = S.C.sub }),
      ui.label({ text = rate(rx), fontFamily = S.mono, fontSize = S.FS.md, color = S.C.text, flexGrow = 1 }),
      ui.glyph({ name = "arrow-up", size = 14, color = S.C.sub }),
      ui.label({ text = rate(tx), fontFamily = S.mono, fontSize = S.FS.md, color = S.C.text, flexGrow = 1 }),
    }),
    S.hline("h1b"),
    ui.row({ align = "center", gap = 8 }, {
      S.caption("Networks"),
      ui.spacer({ flexGrow = 1 }),
      S.caption(if scanning then "scanning" elseif loaded then `{inRange} found` else ""),
    }),
    ui.scroll({ flexGrow = 1, gap = 1 }, rows),
  }
  if status ~= "" then
    table.insert(body, S.status(status))
  end
  panel.render(ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, body))
end

-- The service owns the radio. Follow it, and re-read the list when it changes.
S.watch("graphite.wifi", function(v)
  if type(v) ~= "table" then return end
  local wasRadio, wasConnected = radio, connected
  radio, connected = v.radio == true, v.connected == true
  if not radio then nets = {} end
  if isOpen and (radio ~= wasRadio or connected ~= wasConnected) then
    refresh(radio and not wasRadio)
  else
    render()
  end
end)

function onOpen(_context)
  isOpen = true
  status = ""
  pwFor = nil
  local v = S.read("graphite.wifi")
  if type(v) == "table" then radio, connected = v.radio == true, v.connected == true end
  rx, tx, lastBytes = nil, nil, nil
  sampleSpeed()
  panel.setWantsSecondTicks(true)
  refresh(false)
  if radio then refresh(true) end
end

function update()
  A.tick()
  sampleSpeed()
  render()
end

function onClose()
  isOpen = false
  A.id, H.id, HX.id = nil, nil, nil
  panel.setWantsSecondTicks(false)
end

render()
