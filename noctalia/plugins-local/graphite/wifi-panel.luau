--!nonstrict
-- Wi-Fi panel, attached under the Wi-Fi key. Radio on/off, live download and
-- upload speed, the network list (current first, then saved, then by signal),
-- join with an inline password field, and disconnect.

local S = require("./style.luau")
S.fonts()

local radio = true
local device = nil
local nets = {}
local scanning = false
local busy = nil      -- ssid being joined
local pwFor = nil     -- ssid waiting for a password
local pw = ""
local status = ""
local hovered = nil
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

-- nmcli -t output escapes ':' and '\' with a backslash.
local function splitTerse(line)
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

local function setRadio(on)
  radio = on
  render()
  S.exec({ "nmcli", "radio", "wifi", if on then "on" else "off" }, 10000, function(_ok, _msg)
    S.poke("net")
    refresh(on)
  end)
end

refresh = function(rescan)
  scanning = true
  render()
  local list = "nmcli -t -f IN-USE,SIGNAL,SECURITY,SSID device wifi list" .. (if rescan then " --rescan yes" else " --rescan no")
  local cmd = "nmcli radio wifi; echo '--'; nmcli -t -f DEVICE,TYPE device; echo '--'; nmcli -t -f NAME,TYPE connection show; echo '--'; " .. list .. " 2>/dev/null"
  noctalia.runAsync(cmd, function(r)
    local parts = {}
    for chunk in string.gmatch((r.stdout or "") .. "\n--\n", "(.-)\n%-%-\n") do table.insert(parts, chunk) end
    radio = string.find(parts[1] or "", "enabled", 1, true) ~= nil
    device = nil
    for line in string.gmatch(parts[2] or "", "[^\n]+") do
      local f = splitTerse(line)
      if f[2] == "wifi" and not device then device = f[1] end
    end
    local known = {}
    for line in string.gmatch(parts[3] or "", "[^\n]+") do
      local f = splitTerse(line)
      if f[2] == "802-11-wireless" then known[f[1]] = true end
    end
    local byName = {}
    for line in string.gmatch(parts[4] or "", "[^\n]+") do
      local f = splitTerse(line)
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
    table.sort(nets, function(a, b)
      if a.inUse ~= b.inUse then return a.inUse end
      if a.known ~= b.known then return a.known end
      return a.signal > b.signal
    end)
    scanning = false
    render()
  end, 20000)
end

local function netRow(n)
  local kids = {
    ui.glyph({ name = sigGlyph(n.signal), size = 16, color = if n.inUse then S.C.text else S.C.sub }),
    ui.label({ text = n.ssid, fontFamily = S.sans, fontSize = 13, color = if n.inUse then S.C.text else "on_surface/0.85", flexGrow = 1, maxWidth = 190, maxLines = 1 }),
  }
  if busy == n.ssid then
    table.insert(kids, S.caption("joining"))
  elseif n.inUse then
    table.insert(kids, S.caption("connected", S.C.sub))
  elseif n.known then
    table.insert(kids, S.caption("saved"))
  end
  if n.secure then table.insert(kids, ui.glyph({ name = "lock", size = 13, color = S.C.dim })) end
  table.insert(kids, ui.label({ text = `{n.signal}`, fontFamily = S.mono, fontSize = 11, color = S.C.dim }))
  return S.item({
    key = "net-" .. n.ssid,
    hovered = hovered == n.ssid,
    selected = n.inUse,
    tooltip = if n.inUse then "Click to disconnect" else "Click to join",
    onHover = function(st)
      hovered = if st == "true" then n.ssid elseif hovered == n.ssid then nil else hovered
      render()
    end,
    onClick = function()
      if n.inUse then disconnect() else connect(n.ssid, nil) end
    end,
  }, kids)
end

function render()
  local rows = {}
  if not radio then
    table.insert(rows, ui.column({ height = 120, align = "center", justify = "center", gap = 8 }, {
      ui.glyph({ name = "wifi-off", size = 26, color = S.C.dim }),
      ui.label({ text = "Wi-Fi is off", color = S.C.dim, fontFamily = S.sans }),
    }))
  elseif #nets == 0 then
    table.insert(rows, ui.column({ height = 120, align = "center", justify = "center", gap = 8 }, {
      ui.glyph({ name = "wifi-0", size = 26, color = S.C.dim }),
      ui.label({ text = if scanning then "Looking for networks…" else "No networks found", color = S.C.dim, fontFamily = S.sans }),
    }))
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
      ui.label({ text = rate(rx), fontFamily = S.mono, fontSize = 12.5, color = S.C.text, flexGrow = 1 }),
      ui.glyph({ name = "arrow-up", size = 14, color = S.C.sub }),
      ui.label({ text = rate(tx), fontFamily = S.mono, fontSize = 12.5, color = S.C.text, flexGrow = 1 }),
    }),
    S.hline("h1b"),
    ui.row({ align = "center", gap = 8 }, {
      S.caption("Networks"),
      ui.spacer({ flexGrow = 1 }),
      S.caption(if scanning then "scanning" else (`{#nets} found`)),
    }),
    ui.scroll({ flexGrow = 1, gap = 1 }, rows),
  }
  if status ~= "" then
    table.insert(body, ui.label({ text = status, fontFamily = S.mono, fontSize = 11, color = S.C.sub, maxLines = 2 }))
  end
  panel.render(ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, body))
end

function onOpen(_context)
  status = ""
  pwFor = nil
  rx, tx, lastBytes = nil, nil, nil
  sampleSpeed()
  panel.setWantsSecondTicks(true)
  refresh(false)
  refresh(true)
end

function update()
  sampleSpeed()
  render()
end

function onClose()
  panel.setWantsSecondTicks(false)
end

render()
