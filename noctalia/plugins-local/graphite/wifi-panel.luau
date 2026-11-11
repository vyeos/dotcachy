--!nonstrict
-- Wi-Fi panel, attached under the Wi-Fi key. Radio on/off, live download and
-- upload speed, ping to the router and the internet, a speed test, sharing the
-- current network as a QR code, showing and copying its password, the network
-- list (current first, then saved, then by signal, saved networks out of range
-- last), join with an inline password field, disconnect, and forget a saved
-- network.

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
local statusKind = "info" -- info | ok | warn
local H = S.hover(function() render() end)
local HX = S.hover(function() render() end)  -- the forget box
local A = S.confirm(function() render() end)
local rx, tx = nil, nil           -- bytes/s, nil until two samples exist
local lastBytes = nil             -- { rx, tx, ms }

-- The connected network: read when the panel opens, forgotten when it closes.
local cur = nil                   -- { uuid, ssid, keymgmt, psk }
local showPw = false
local sharing = false
local qrPath = nil                -- PNG of the share code, deleted on close
local qrGen = 0
local qrNote = ""
local ping = nil                  -- { router = ms|nil, net = ms|nil } or "busy"
local bands = {}                  -- ssid -> { g24 = signal|nil, g5 = signal|nil }, from the scan
local switching = nil             -- band being switched to
local speed = { phase = "idle" }  -- idle | down | up | done | fail, with down/up in Mbps
local dataDir = noctalia.pluginDataDir() or "/tmp"

-- nmcli -g escapes ':' and '\' even for one field; g() takes them back out.
local NM_GET = [[g() { nmcli -s -g "$1" connection show uuid "$uuid" | sed 's/\\\(.\)/\1/g'; }]]
local ACTIVE_UUID = [[uuid=$(nmcli -t -f UUID,TYPE connection show --active | awk -F: '$2=="802-11-wireless"{print $1; exit}'); [ -n "$uuid" ] || exit 1]]

local INFO_SH = ACTIVE_UUID .. "\n" .. NM_GET .. "\n" .. [[
dev=$(nmcli -t -f DEVICE,TYPE,STATE device | awk -F: '$2=="wifi" && $3=="connected" {print $1; exit}')
link=$(iw dev "$dev" link 2>/dev/null)
freq=$(printf '%s\n' "$link" | awk '/freq:/ {printf "%d", $2; exit}')
rate=$(printf '%s\n' "$link" | awk '/rx bitrate:/ {printf "%d", $3; exit}')
printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n' "$uuid" "$(g 802-11-wireless.ssid)" "$(g 802-11-wireless-security.key-mgmt)" "$(g 802-11-wireless-security.psk)" "$(g 802-11-wireless.band)" "$freq" "$rate"]]

-- Lock the saved connection to a band ("a" 5 GHz, "bg" 2.4 GHz) and reconnect.
-- The channel the panel's scan saw on that band is pinned only while connecting, so
-- NetworkManager checks that one channel instead of scanning the whole band (which
-- took ~25 s here); it's cleared again right after, so a router that later moves
-- channels is still found.
local BAND_SH = [[uuid=$1 band=$2 ch=$3 prev=$4
nmcli connection modify uuid "$uuid" 802-11-wireless.band "$band" 802-11-wireless.channel "$ch" || exit 1
if nmcli --wait 25 connection up uuid "$uuid" >/dev/null 2>&1; then
  nmcli connection modify uuid "$uuid" 802-11-wireless.channel ""
  exit 0
fi
# Couldn't come up on that band (weak signal shows up as a failed handshake,
# which NetworkManager then takes for a wrong password). Put the previous band
# back and reconnect rather than leaving the laptop offline.
nmcli connection modify uuid "$uuid" 802-11-wireless.band "$prev" 802-11-wireless.channel ""
nmcli --wait 25 connection up uuid "$uuid" >/dev/null 2>&1
echo "REVERTED" >&2
exit 1]]
-- Auto: drop the lock and stay on the current connection, no reconnect needed.
local BAND_AUTO_SH = [[nmcli connection modify uuid "$1" 802-11-wireless.band "" 802-11-wireless.channel ""]]

-- Builds the standard WIFI: string inside the shell and pipes it to qrencode, so
-- the password never shows up in a process list or a file of its own.
local QR_SH = [[uuid=$1 out=$2
]] .. NM_GET .. [[

e() { printf '%s' "$1" | sed 's/[\;,:"]/\\&/g'; }
ssid=$(g 802-11-wireless.ssid); km=$(g 802-11-wireless-security.key-mgmt)
case $km in
  wpa-psk|sae) t=WPA ;;
  none) t=WEP ;;
  "") t=nopass ;;
  *) echo "Enterprise networks can't be shared as a code" >&2; exit 2 ;;
esac
if [ "$t" = nopass ]; then
  printf 'WIFI:T:nopass;S:%s;;' "$(e "$ssid")"
else
  printf 'WIFI:T:%s;S:%s;P:%s;;' "$t" "$(e "$ssid")" "$(e "$(g 802-11-wireless-security.psk)")"
fi | qrencode -s 6 -m 2 --foreground=151618 --background=EDEDEB -o "$out"]]

local PING_SH = [[gw=$(ip -4 route show default | awk '{print $3; exit}')
p() { [ -n "$1" ] && ping -c 3 -i 0.3 -W 2 -q "$1" 2>/dev/null | awk -F/ '/^rtt|^round-trip/ {printf "%.0f", $5}'; }
printf '%s|%s\n' "$(p "$gw")" "$(p 1.1.1.1)"]]

-- Cloudflare's speed endpoints. Download chains 50 MB requests (its cap) for 8
-- seconds; upload streams zeros for 8 seconds. Both print Mbps.
local DOWN_SH = [[end=$(( $(date +%s) + 8 ))
while now=$(date +%s); [ "$now" -lt "$end" ]; do
  curl -s -o /dev/null --max-time $((end - now)) -w '%{size_download} %{time_total}\n' 'https://speed.cloudflare.com/__down?bytes=50000000' || [ $? = 28 ] || exit 1
done | awk '{b+=$1; t+=$2} END {if (t > 0 && b > 0) printf "%.1f\n", b*8/t/1e6; else exit 1}']]
local UP_SH = [[r=$(head -c 400000000 /dev/zero | curl -s -o /dev/null --max-time 8 -X POST -H 'Content-Type: application/octet-stream' -T - 'https://speed.cloudflare.com/__up' -w '%{speed_upload}')
awk -v r="$r" 'BEGIN {if (r + 0 > 0) printf "%.1f\n", r*8/1e6; else exit 1}']]

-- nmcli's errors are written for terminals; say what actually happened.
function friendly(msg, fallback)
  local m = noctalia.string.trim(msg or "")
  if m == "" then return fallback end
  if string.find(m, "Secrets were required", 1, true) or string.find(m, "password for", 1, true)
    or string.find(m, "802-11-wireless-security.psk", 1, true) or string.find(m, "no-secrets", 1, true) then
    return "Wrong password, or the network didn't answer. Check it and try again."
  end
  if string.find(m, "No network with SSID", 1, true) then return "That network is out of range now." end
  if string.find(m, "Timeout", 1, true) or string.find(m, "timed out", 1, true) then return "The network took too long to answer." end
  m = string.gsub(m, "^Error:%s*", "")
  m = string.gsub(m, "^Connection activation failed:%s*", "")
  m = string.gsub(m, "%s*·.*$", "") -- first line only
  return (string.gsub(m, "^%l", string.upper))
end

function notice(kind, text)
  statusKind, status = kind, text or ""
end

local function sh(script, ...)
  return { "sh", "-c", script, "sh", ... }
end

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

local function clearQr()
  sharing, qrPath, qrNote = false, nil, ""
  noctalia.runAsync({ "sh", "-c", 'rm -f "$1"/wifi-qr-*.png', "sh", dataDir })
end

local function loadInfo()
  if not connected then cur = nil; render(); return end
  noctalia.runAsync(sh(INFO_SH), function(r)
    if r.exitCode ~= 0 or r.timedOut then cur = nil; render(); return end
    local l = string.split(r.stdout or "", "\n")
    cur = { uuid = l[1] or "", ssid = l[2] or "", keymgmt = l[3] or "", psk = l[4] or "",
      band = l[5] or "", freq = tonumber(l[6] or ""), rate = tonumber(l[7] or "") }
    render()
  end, 8000)
end

local function runPing()
  if not connected or ping == "busy" then return end
  ping = "busy"
  render()
  noctalia.runAsync(sh(PING_SH), function(r)
    local a, b = string.match(r.stdout or "", "^(%d*)|(%d*)")
    ping = { router = tonumber(a or ""), net = tonumber(b or "") }
    render()
  end, 15000)
end

local function runSpeed()
  if speed.phase == "down" or speed.phase == "up" then return end
  speed = { phase = "down" }
  render()
  noctalia.runAsync(sh(DOWN_SH), function(r)
    local down = tonumber(noctalia.string.trim(r.stdout or ""))
    if not down then speed = { phase = "fail" }; render(); return end
    speed = { phase = "up", down = down }
    render()
    noctalia.runAsync(sh(UP_SH), function(r2)
      speed = { phase = "done", down = down, up = tonumber(noctalia.string.trim(r2.stdout or "")) }
      render()
    end, 20000)
  end, 20000)
end

local function toggleShare()
  if sharing then clearQr(); render(); return end
  if not cur then return end
  sharing, qrNote = true, "Making the code…"
  qrGen += 1
  local gen = qrGen
  local out = `{dataDir}/wifi-qr-{gen}.png` -- new name each time, so the image isn't served from cache
  render()
  noctalia.runAsync(sh('rm -f "$3"/wifi-qr-*.png; ' .. QR_SH, cur.uuid, out, dataDir), function(r)
    if gen ~= qrGen or not sharing then return end
    if r.exitCode == 0 and not r.timedOut then
      qrPath, qrNote = out, ""
    else
      local why = noctalia.string.trim(r.stderr or "")
      qrNote = if why ~= "" then why else "Could not make the code"
    end
    render()
  end, 8000)
end

local function pingText(ms)
  return if ms then `{ms} ms` else "—"
end

local function speedText()
  local ph = speed.phase
  if ph == "down" then return "testing download…" end
  if ph == "up" then return `↓ {speed.down}  ·  testing upload…` end
  if ph == "done" then return `↓ {speed.down}  ↑ {if speed.up then tostring(speed.up) else "—"} Mbps` end
  if ph == "fail" then return "test failed" end
  return "not run"
end

local function bandOf(mhz)
  if not mhz then return nil end
  if mhz < 3000 then return "2.4 GHz", math.floor((mhz - 2407) / 5) end
  if mhz < 5925 then return "5 GHz", math.floor((mhz - 5000) / 5) end
  return "6 GHz", math.floor((mhz - 5950) / 5)
end

local function setBand(b)
  if not cur or switching or b == cur.band then return end
  local argv
  if b == "" then
    argv = sh(BAND_AUTO_SH, cur.uuid)
  else
    local seen = bands[cur.ssid] or {}
    local _, ch = bandOf(if b == "a" then seen.g5f else seen.g24f)
    argv = sh(BAND_SH, cur.uuid, b, tostring(ch or ""), cur.band)
  end
  switching = b
  status = ""
  render()
  S.exec(argv, 45000, function(ok, msg)
    switching = nil
    local name = if b == "a" then "5 GHz" else "2.4 GHz"
    if ok then
      notice("ok", if b == "" then "Band set to automatic" else `Staying on {name}`)
    elseif string.find(msg, "REVERTED", 1, true) then
      notice("warn", `Couldn't connect on {name}, the signal is probably too weak here. Went back to the previous band.`)
    else
      notice("warn", friendly(msg, "Couldn't switch band"))
    end
    S.poke("net")
    loadInfo()
    refresh(false)
  end)
end

-- Every row in the details block has this height, so nothing moves when values change.
local ROW_H = 26
local STAT_PAD = 8 -- inset, so a hovered row's fill doesn't touch its text
local LABEL_W = 76

-- A labelled row: caption on the left, value in the middle, controls on the right.
local function stat(key, label, value, right, o)
  local kids = {
    ui.row({ width = LABEL_W, align = "center" }, { S.caption(label) }),
    ui.row({ flexGrow = 1, align = "center", gap = 6 }, value),
  }
  for _, k in right or {} do table.insert(kids, k) end
  o = o or {}
  local hid = "\0row" .. key
  return ui.row({ key = key, height = ROW_H, align = "center", gap = 6, radius = 0, paddingH = STAT_PAD,
    fill = if o.onClick and H.id == hid then S.C.keyHover else nil,
    tooltip = o.tooltip, onClick = o.onClick, onHover = if o.onClick then H.fn(hid) else nil }, kids)
end

local function mono(text, color)
  return ui.label({ text = text, fontFamily = S.mono, fontSize = S.FS.md, color = color or S.C.text, maxLines = 1 })
end

local function iconBtn(glyph, tip, onClick, enabled, active)
  return ui.button({ glyph = glyph, variant = if active then "primary" else "ghost", controlSize = "sm", tooltip = tip,
    enabled = enabled ~= false, onClick = onClick })
end

-- Auto / 2.4 GHz / 5 GHz, flat cells, the picked one inverted.
local function bandPicker()
  local seen = bands[cur.ssid] or {}
  local opts = {
    { id = "", label = "Auto", sig = nil, ok = true },
    { id = "bg", label = "2.4 GHz", sig = seen.g24, ok = seen.g24 ~= nil },
    { id = "a", label = "5 GHz", sig = seen.g5, ok = seen.g5 ~= nil },
  }
  local cells = {}
  for _, o in opts do
    local picked = (switching or cur.band) == o.id
    local hid = "\0band" .. o.id
    local ink = if picked then S.C.inv elseif o.ok then S.C.body else S.C.dim
    local kids = { ui.label({ text = o.label, fontFamily = S.mono, fontSize = S.FS.sm, color = ink }) }
    if o.sig then
      table.insert(kids, ui.label({ text = tostring(o.sig), fontFamily = S.mono, fontSize = S.FS.xs, color = if picked then S.C.invDim else S.C.dim }))
    end
    table.insert(cells, ui.row({
      key = "band-" .. (if o.id == "" then "auto" else o.id),
      flexGrow = 1, height = ROW_H, radius = 0, gap = 6, align = "center", justify = "center",
      fill = if picked then S.C.text elseif H.id == hid and o.ok then S.C.keyHover else S.C.key,
      tooltip = if not o.ok then "This network isn't seen on that band here"
        elseif o.id == "" then "Let the laptop pick the band"
        else `Stay on {o.label}{if o.sig then ` (signal {o.sig})` else ""}`,
      onHover = H.fn(hid),
      onClick = function() if o.ok then setBand(o.id) end end,
    }, kids))
  end
  return ui.row({ key = "bands", gap = 2, align = "center" }, cells)
end

-- The network we're on: name, band and link, band picker, then the stat rows.
local function details()
  local out = {}
  if cur then
    local band = bandOf(cur.freq)
    local name = {
      ui.label({ text = cur.ssid, fontFamily = S.sans, fontSize = S.FS.lg, color = S.C.text, maxLines = 1 }),
    }
    if band then
      table.insert(name, ui.label({ text = band, fontFamily = S.mono, fontSize = S.FS.sm, color = S.C.sub,
        tooltip = if cur.rate then `{cur.rate} Mbit/s link` else nil }))
    end
    table.insert(name, ui.spacer({ flexGrow = 1 }))
    table.insert(name, S.caption(if switching then "switching" else "connected", S.C.sub))
    table.insert(out, ui.row({ key = "cur", align = "center", gap = 10, height = 24, paddingH = STAT_PAD }, name))
    table.insert(out, bandPicker())
  end

  local stats = {}
  -- two value columns, shared by traffic and ping so they line up
  local COL_W = 112
  local function col(kids) return ui.row({ width = COL_W, align = "center", gap = 6 }, kids) end
  local function tag(text) return ui.label({ text = text, fontFamily = S.mono, fontSize = S.FS.xs, color = S.C.dim }) end

  if connected then
    table.insert(stats, stat("traffic", "Traffic", {
      col({ ui.glyph({ name = "arrow-down", size = 13, color = S.C.sub }), mono(rate(rx)) }),
      col({ ui.glyph({ name = "arrow-up", size = 13, color = S.C.sub }), mono(rate(tx)) }),
    }))
    local p = if type(ping) == "table" then ping else nil
    table.insert(stats, stat("ping", "Ping", {
      col({ mono(if ping == "busy" then "…" elseif p then pingText(p.router) else "—"), tag(if p then "router" else "") }),
      col({ mono(if p then pingText(p.net) else ""), tag(if p then "internet" else "") }),
    }, nil, { onClick = runPing, tooltip = "Click to ping again" }))
    local busySpeed = speed.phase == "down" or speed.phase == "up"
    table.insert(stats, stat("speed", "Speed", { mono(speedText(), if speed.phase == "idle" then S.C.dim else S.C.text) },
      { iconBtn("player-play", "Run a speed test (about 16 s, uses 100 MB or more)", runSpeed, not busySpeed) }))
    if cur then
      local hasPw = cur.psk ~= ""
      table.insert(stats, stat("pw", "Password", {
        mono(if not hasPw then "none" elseif showPw then cur.psk else "••••••••••", if showPw then S.C.text else S.C.sub),
      }, {
        iconBtn(if showPw then "eye-off" else "eye", if showPw then "Hide" else "Show the password",
          function() showPw = not showPw; render() end, hasPw),
        iconBtn("copy", "Copy the password", function()
          noctalia.copyToClipboard(cur.psk); notice("ok", "Password copied"); render()
        end, hasPw),
        iconBtn("qrcode", if sharing then "Back to networks" else "Share as a QR code", toggleShare, true, sharing),
      }))
    end
  end
  if #stats > 0 then
    table.insert(out, ui.column({ key = "stats", gap = 2, align = "stretch" }, stats))
  end
  return out
end

-- Takes the network list's place while sharing, so nothing above it moves.
local function shareView()
  local kids = {}
  if qrPath then
    table.insert(kids, ui.image({ key = qrPath, path = qrPath, width = 172, height = 172, fit = "contain", radius = 0 }))
  else
    table.insert(kids, ui.column({ height = 172, align = "center", justify = "center" }, { S.status(qrNote) }))
  end
  return ui.column({ key = "share", flexGrow = 1, align = "center", justify = "center" }, kids)
end

local function sigGlyph(s)
  if s >= 67 then return "wifi" elseif s >= 34 then return "wifi-2" elseif s > 0 then return "wifi-1" end
  return "wifi-0"
end


local function connect(ssid, password)
  local n = nil
  for _, x in nets do if x.ssid == ssid then n = x end end
  if not n then return end
  local typed = password ~= nil and password ~= ""
  -- clicking the row of the open password field closes it again
  if not typed and pwFor == ssid then
    pwFor, pw = nil, ""
    render()
    return
  end
  local argv
  if n.secure and (pwFor == ssid or not n.known) and not typed then
    pwFor, pw = ssid, ""
    notice("info", "")
    render()
    return
  end
  if n.known and typed then
    -- a saved network whose password changed: update it, then connect
    argv = { "sh", "-c", 'nmcli connection modify id "$1" 802-11-wireless-security.psk "$2" && nmcli --wait 30 connection up id "$1"', "sh", ssid, password }
  elseif n.known then
    argv = { "nmcli", "--wait", "30", "connection", "up", "id", ssid }
  elseif n.secure then
    argv = { "nmcli", "--wait", "30", "device", "wifi", "connect", ssid, "password", password }
  else
    argv = { "nmcli", "--wait", "30", "device", "wifi", "connect", ssid }
  end
  busy = ssid
  notice("info", "")
  render()
  S.exec(argv, 45000, function(ok, msg)
    busy = nil
    if ok then
      pwFor, pw = nil, ""
      notice("ok", "Connected to " .. ssid)
    else
      notice("warn", friendly(msg, "Couldn't connect to " .. ssid))
      -- a password problem: ask for it right there
      if n.secure and string.find(status, "password", 1, true) then pwFor, pw = ssid, "" end
    end
    S.poke("net")
    refresh(false)
  end)
end

local function disconnect()
  if not device then return end
  S.exec({ "nmcli", "device", "disconnect", device }, 15000, function(ok, msg)
    if ok then notice("info", "Disconnected") else notice("warn", friendly(msg, "Couldn't disconnect")) end
    S.poke("net")
    refresh(false)
  end)
end

local function forget(n)
  status = ""
  S.exec({ "nmcli", "connection", "delete", "id", n.ssid }, 15000, function(ok, msg)
    if ok then notice("info", "Forgot " .. n.ssid) else notice("warn", friendly(msg, "Couldn't forget " .. n.ssid)) end
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
  local list = "nmcli -t -f IN-USE,SIGNAL,SECURITY,FREQ,SSID device wifi list" .. (if rescan then " --rescan yes" else " --rescan no")
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
    bands = {}
    for line in string.gmatch(parts[3] or "", "[^\n]+") do
      local f = S.terse(line)
      local ssid = f[5] or ""
      if ssid ~= "" then
        local sig = tonumber(f[2]) or 0
        local mhz = tonumber(string.match(f[4] or "", "%d+"))
        if mhz then
          local b = bands[ssid] or {}
          local k = if mhz < 3000 then "g24" else "g5"
          if not b[k] or sig > b[k] then b[k] = sig; b[k .. "f"] = mhz end
          bands[ssid] = b
        end
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
            onSubmit = function() connect(n.ssid, pw) end }),
          ui.button({ text = "Join", variant = "primary", onClick = function() connect(n.ssid, pw) end }),
        }))
      end
    end
  end

  local body = {
    S.header("wifi", "Wi-Fi", {
      ui.button({ glyph = "refresh", variant = "ghost", tooltip = "Scan again", enabled = radio and not scanning, onClick = function() refresh(true) end }),
      S.switch({ key = "radio", on = radio, hovered = H.id == "radio-switch", onHover = H.fn("radio-switch"),
        onClick = function() setRadio(not radio) end }),
    }),
    S.hline("h1"),
  }
  if radio then
    local d = details()
    for _, x in d do table.insert(body, x) end
    if #d > 0 then table.insert(body, S.hline("h1b")) end
  end
  if sharing then
    table.insert(body, ui.row({ align = "center", gap = 8, height = 20, paddingH = STAT_PAD }, {
      S.caption("Scan with a phone to join " .. (if cur then cur.ssid else "")), ui.spacer({ flexGrow = 1 }),
    }))
    table.insert(body, shareView())
  else
    table.insert(body, ui.row({ align = "center", gap = 8, height = 20, paddingH = STAT_PAD }, {
      S.caption("Networks"),
      ui.spacer({ flexGrow = 1 }),
      S.caption(if scanning then "scanning" elseif loaded then `{inRange} found` else ""),
    }))
    table.insert(body, S.list("nets", rows))
  end
  if status ~= "" then
    local warn = statusKind == "warn"
    table.insert(body, ui.row({ key = "notice", gap = 10, align = "center", paddingH = 10, paddingV = 8, radius = 0,
      fill = if warn then S.C.key else S.C.clear, border = if warn then S.C.edge else nil, borderWidth = if warn then 1 else 0 }, {
      ui.glyph({ name = if warn then "alert-triangle" elseif statusKind == "ok" then "check" else "info-circle", size = 15,
        color = if warn then S.C.text else S.C.sub }),
      ui.label({ text = status, fontFamily = S.sans, fontSize = S.FS.md, color = if warn then S.C.text else S.C.sub,
        maxLines = 3, flexGrow = 1 }),
      ui.button({ glyph = "x", variant = "ghost", controlSize = "sm", tooltip = "Dismiss",
        onClick = function() notice("info", ""); render() end }),
    }))
  end
  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, body))
end

-- The service owns the radio. Follow it, and re-read the list when it changes.
S.watch("graphite.wifi", function(v)
  if type(v) ~= "table" then return end
  local wasRadio, wasConnected = radio, connected
  radio, connected = v.radio == true, v.connected == true
  if not radio then nets = {} end
  if isOpen and (radio ~= wasRadio or connected ~= wasConnected) then
    if connected ~= wasConnected then
      clearQr(); showPw = false; ping = nil; speed = { phase = "idle" }
      loadInfo()
      if connected then runPing() end
    end
    refresh(radio and not wasRadio)
  else
    render()
  end
end)

function onOpen(_context)
  isOpen = true
  notice("info", "")
  pwFor = nil
  local v = S.read("graphite.wifi")
  if type(v) == "table" then radio, connected = v.radio == true, v.connected == true end
  rx, tx, lastBytes = nil, nil, nil
  sampleSpeed()
  panel.setWantsSecondTicks(true)
  showPw = false
  ping = nil
  loadInfo()
  runPing()
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
  -- don't keep the password or its code around once the panel is gone
  cur, showPw = nil, false
  qrGen += 1
  clearQr()
end

render()
