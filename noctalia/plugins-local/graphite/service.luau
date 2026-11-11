--!nonstrict
-- Graphite service: gathers what the bar and panels show and publishes it through
-- noctalia.state as JSON strings (graphite.*). Widgets only render, and every switch
-- goes through here (S.svc in-process, `noctalia msg plugin ...:service` from
-- keybinds) so all of them stay in sync.
--
--   graphite.ws        [{ id, windows }]          Hyprland workspaces, sorted
--   graphite.wsActive  number                     focused workspace id
--   graphite.win       { cls, title }             focused window
--   graphite.tasks     [{ id, label, glyph, cls, rec, startedMs }]
--   graphite.wifi      { radio, connected, ssid, signal, wired }
--   graphite.bt        { powered, devices = { names } }
--   graphite.batt      { present, pct, status }
--   graphite.power     { pct, state, timeLeft, rate, health, profile, profiles }
--   graphite.vol       { pct, muted, inPct, inMuted }   default output and input
--   graphite.gpu       { mode, power, action, pending } read at start and while the GPU panel is open
--   graphite.rec       { recording, startedMs, file }   OBS recording, if any
--   graphite.notif     { unread, dnd }            notifications since last opened
--   graphite.notifs    [{ id, nid, app, summary, body, t }]   history, newest first
--   graphite.caffeine, graphite.night             booleans
--   graphite.clipRev, graphite.audioRev, graphite.drawerTick   change counters
--
-- Changes arrive through bin/graphite-events; the timers below only catch what has no event
-- (Wi-Fi signal, say) and stop while the session is idle.

local S = require("./style.luau")

local TICK_MS = 1000
local IDLE_AFTER_SECS = 120
local POLL = { wifi = 30000, bt = 120000, batt = 60000, power = 60000, dnd = 60000, tasks = 60000 }
local REC_MS = 3000
local SETTLE_MS = 1500   -- a radio takes this long to report its new state
local AGAIN_MS = 5000    -- bluez can be slower still: read once more

noctalia.setUpdateInterval(TICK_MS)

local KNOWN = {
  steam = { label = "Steam", glyph = "brand-steam", cls = "steam" },
  obs = { label = "OBS", glyph = "player-record", cls = "com.obsproject.Studio", rec = true },
  discord = { label = "Discord", glyph = "brand-discord", cls = "discord" },
  Discord = { label = "Discord", glyph = "brand-discord", cls = "discord" },
  spotify = { label = "Spotify", glyph = "brand-spotify", cls = "spotify" },
  syncthing = { label = "Syncthing", glyph = "refresh", cls = "syncthing" },
  qbittorrent = { label = "qBittorrent", glyph = "download", cls = "org.qbittorrent.qBittorrent" },
  blender = { label = "Blender", glyph = "brand-blender", cls = "blender" },
}

local cache = {}
local function publishText(key, s)
  if s and cache[key] ~= s then
    cache[key] = s
    noctalia.state.set(key, s)
  end
end
local function publish(key, value)
  publishText(key, noctalia.json.encode(value))
end
local function current(key)
  return S.decode(cache[key]) or {}
end

local due = {}
local again = {}
local hold = {}   -- nowMs until which a read would overwrite a switch still settling
local idle = false

local function holding(kind)
  return hold[kind] ~= nil and noctalia.nowMs() < hold[kind]
end

-- ── Long-running tasks ──────────────────────────────────────────────────────

local function watchedSet()
  local raw = noctalia.getConfig("task_processes")
  local set, order = {}, {}
  for name in string.gmatch(if type(raw) == "string" then raw else "", "[^,%s]+") do
    if not set[name] then
      set[name] = true
      table.insert(order, name)
    end
  end
  return set, order
end

local obsRunning = false

local function refreshTasks()
  noctalia.runAsync({ "ps", "-eo", "comm=,etimes=" }, function(r)
    if r.exitCode ~= 0 then return end
    local set, order = watchedSet()
    local found = {}
    for line in string.gmatch(r.stdout, "[^\n]+") do
      local comm, et = string.match(line, "^%s*(.-)%s+(%d+)%s*$")
      if comm and set[comm] then
        local secs = tonumber(et) or 0
        if not found[comm] or secs > found[comm] then found[comm] = secs end
      end
    end
    local now = noctalia.nowMs()
    local out = {}
    for _, name in order do
      local secs = found[name]
      if secs then
        local k = KNOWN[name] or { label = name, glyph = "app-window", cls = name }
        -- round the start time to whole seconds so the published value stays stable
        local started = math.floor((now - secs * 1000) / 1000) * 1000
        table.insert(out, { id = name, label = k.label, glyph = k.glyph, cls = k.cls, rec = k.rec == true, startedMs = started })
      end
    end
    publish("graphite.tasks", out)
    obsRunning = found.obs ~= nil
    if not obsRunning then publish("graphite.rec", { recording = false }) end
  end, 3000)
end

-- ── OBS recording ───────────────────────────────────────────────────────────
-- While OBS records it keeps the output file open. Look for an open video file
-- among OBS's file descriptors and time the recording from the file's birth
-- time (or from when it was first seen, on filesystems without birth times).
-- No obs-websocket needed. Only runs while OBS does.

local recFirstSeen = {}
local REC_CMD = [[
for p in $(pgrep -x obs); do
  for f in /proc/$p/fd/*; do
    t=$(readlink "$f" 2>/dev/null) || continue
    case "$t" in
      *.mkv|*.mp4|*.mov|*.flv|*.ts|*.m3u8|*.webm|*.hybrid_mp4|*.fragmented_mp4|*.fragmented_mov)
        b=$(stat -c %W "$t" 2>/dev/null); echo "${b:-0} $t";;
    esac
  done
done
]]

local function refreshRecording()
  noctalia.runAsync(REC_CMD, function(r)
    local birth, file = string.match(r.stdout or "", "^(%d+) ([^\n]+)")
    if not file then
      recFirstSeen = {}
      publish("graphite.rec", { recording = false })
      return
    end
    local started = (tonumber(birth) or 0) * 1000
    if started <= 0 then
      recFirstSeen[file] = recFirstSeen[file] or math.floor(noctalia.nowMs() / 1000) * 1000
      started = recFirstSeen[file]
    end
    publish("graphite.rec", { recording = true, startedMs = started, file = file })
  end, 3000)
end

-- ── Notifications ───────────────────────────────────────────────────────────
-- Every Notify call on the session bus is captured (app, summary, body) into a
-- history of the last 50, kept on disk, and counted as unread until the drawer
-- is opened. DND comes from Noctalia itself. A notification that replaces an
-- earlier one (replaces_id, as progress updates do) takes over its entry, which
-- is why the daemon's reply is read too: it carries the id the replacement names.
--   graphite.drawer   "open" | "closed"                 the right-edge drawer
-- Commands from the drawer arrive on graphite.notifCmd: "dismiss:<id>", "clear".

local MAX_HISTORY = 50
local notif = { unread = 0, dnd = false }
local history = {}
local nextId = 1

local dataDir = noctalia.pluginDataDir()
local historyPath = if dataDir then dataDir .. "/notifications.json" else nil
if historyPath then
  local raw = noctalia.readFile(historyPath)
  local saved = if raw then noctalia.json.decode(raw) else nil
  if type(saved) == "table" then
    history = saved
    for _, n in history do
      if type(n.id) == "number" and n.id >= nextId then nextId = n.id + 1 end
    end
  end
end

local function publishNotif()
  publish("graphite.notif", { unread = notif.unread, dnd = notif.dnd })
end
local function publishHistory()
  publish("graphite.notifs", history)
  if historyPath then
    local s = noctalia.json.encode(history)
    if s then noctalia.writeFile(historyPath, s) end
  end
end

-- dbus-monitor prints the call header, then one argument per line:
--   string app_name, uint32 replaces_id, string app_icon, string summary,
--   string body, array actions, dict hints, int32 timeout.
-- Collect lines from the header up to the actions array, then read the strings.
local collecting = nil
local callKey = nil
local awaiting = {}   -- "sender:serial" -> history entry waiting for the daemon's id
local replyFor = nil

local function finishNotify(lines, key)
  local text = table.concat(lines, "\n") .. "\n"
  local strs = {}
  for v in string.gmatch(text, 'string "(.-)"\n') do table.insert(strs, v) end
  local app, summary, body = strs[1] or "", strs[3] or "", strs[4] or ""
  if summary == "" and body == "" then return end
  local replaces = tonumber(string.match(text, "uint32 (%d+)")) or 0
  local replaced = false
  if replaces ~= 0 then
    for i, n in history do
      if n.nid == replaces and n.app == app then
        table.remove(history, i)
        replaced = true
        break
      end
    end
  end
  local entry = { id = nextId, nid = if replaces ~= 0 then replaces else nil, app = app, summary = summary, body = body, t = os.time() }
  table.insert(history, 1, entry)
  nextId += 1
  if key then awaiting[key] = entry end
  while #history > MAX_HISTORY do table.remove(history) end
  if not replaced and noctalia.state.get("graphite.drawer") ~= "open" then
    notif.unread = math.min(notif.unread + 1, 999)
  end
  publishHistory()
  publishNotif()
end

local function onNotifLine(line)
  if string.sub(line, 1, 12) == "method call " then
    if string.find(line, "member=Notify", 1, true) then
      collecting = {}
      local sender, serial = string.match(line, "sender=(%S+).-serial=(%d+)")
      callKey = if sender and serial then sender .. ":" .. serial else nil
    end
  elseif string.sub(line, 1, 14) == "method return " then
    local dest, serial = string.match(line, "destination=(%S+).-reply_serial=(%d+)")
    local key = if dest and serial then dest .. ":" .. serial else nil
    replyFor = if key then awaiting[key] else nil
    if key then awaiting[key] = nil end
  elseif replyFor then
    local id = tonumber(string.match(line, "uint32 (%d+)"))
    if id then
      replyFor.nid = id
      publishHistory()
    end
    replyFor = nil
  elseif collecting then
    if string.match(line, "^%s*array %[") then
      local lines, key = collecting, callKey
      collecting, callKey = nil, nil
      finishNotify(lines, key)
    else
      table.insert(collecting, line)
    end
  end
end

local function refreshDnd()
  noctalia.runAsync({ "noctalia", "msg", "notification-dnd-status" }, function(r)
    local out = string.lower(noctalia.string.trim(r.stdout or ""))
    notif.dnd = out == "on" or out == "true" or out == "enabled"
    publishNotif()
  end, 3000)
end

noctalia.state.watch("graphite.notifCmd", function(v)
  if type(v) ~= "string" then return end
  local cmd, arg = string.match(v, "^(%a+):?([^:]*)")
  if cmd == "dismiss" then
    local id = tonumber(arg)
    for i, n in history do
      if n.id == id then table.remove(history, i); break end
    end
    publishHistory()
  elseif cmd == "clear" then
    history = {}
    publishHistory()
  end
end)

-- The drawer: placed off the right edge, then the layer script slides it in.
noctalia.state.set("graphite.drawer", "closed")
noctalia.state.watch("graphite.drawer", function(v)
  if v == "open" then
    notif.unread = 0
    publishNotif()
    noctalia.layer.configure("notifs", {
      layer = "overlay",
      anchors = { "top", "right", "bottom" },
      width = S.DRAWER_W,
      margins = { top = S.barThickness() + S.EDGE_GAP, right = -(S.DRAWER_W + 20), bottom = S.EDGE_GAP },
      exclusiveZone = -1,
      keyboard = "none",
      clickThrough = false,
      output = "focused",
    })
    noctalia.layer.show("notifs")
  end
end)
publishNotif()
publishHistory()

-- ── Network, Bluetooth, battery ─────────────────────────────────────────────

local WIFI_CMD = "nmcli radio wifi; echo '--'; nmcli -t -f IN-USE,SIGNAL,SSID device wifi list --rescan no 2>/dev/null; echo '--'; nmcli -t -f TYPE,STATE dev 2>/dev/null"

local function refreshWifi()
  noctalia.runAsync(WIFI_CMD, function(r)
    if holding("wifi") then return end
    local parts = S.parts(r.stdout)
    local info = { radio = string.find(parts[1] or "", "enabled", 1, true) ~= nil, connected = false, ssid = "", signal = 0, wired = false }
    for line in string.gmatch(parts[2] or "", "[^\n]+") do
      local f = S.terse(line)
      if f[1] == "*" then
        info.connected = true
        info.signal = tonumber(f[2]) or 0
        info.ssid = f[3] or ""
      end
    end
    for line in string.gmatch(parts[3] or "", "[^\n]+") do
      if string.match(line, "^ethernet:connected") then info.wired = true end
    end
    publish("graphite.wifi", info)
  end, 4000)
end

local function refreshBt()
  noctalia.runAsync("bluetoothctl show 2>/dev/null | grep -m1 'Powered:'; echo '--'; bluetoothctl devices Connected 2>/dev/null", function(r)
    if holding("bt") then return end
    local parts = S.parts(r.stdout)
    local info = { powered = string.find(parts[1] or "", "yes", 1, true) ~= nil, devices = {} }
    for line in string.gmatch(parts[2] or "", "[^\n]+") do
      local name = string.match(line, "^Device %S+ (.+)$")
      if name then table.insert(info.devices, name) end
    end
    publish("graphite.bt", info)
  end, 4000)
end

local battDir = nil
local function findBattery()
  local names = noctalia.listDir("/sys/class/power_supply")
  if not names then return nil end
  for _, n in names do
    if string.sub(n, 1, 3) == "BAT" then return "/sys/class/power_supply/" .. n end
  end
  return nil
end

local function refreshBattery()
  battDir = battDir or findBattery()
  if not battDir then
    publish("graphite.batt", { present = false })
    return
  end
  local cap = noctalia.readFile(battDir .. "/capacity")
  local status = noctalia.readFile(battDir .. "/status")
  publish("graphite.batt", {
    present = true,
    pct = tonumber(string.match(cap or "", "%d+")) or 0,
    status = noctalia.string.trim(status or "Unknown"),
  })
end

-- Everything the power panel shows, kept current here so the panel has values
-- the moment it opens. busctl instead of powerprofilesctl: 6 ms vs 150 ms.
local PPD = "org.freedesktop.UPower.PowerProfiles /org/freedesktop/UPower/PowerProfiles org.freedesktop.UPower.PowerProfiles"
local POWER_CMD = "upower -i $(upower -e | grep -m1 BAT) 2>/dev/null; echo '--'; "
  .. "busctl get-property " .. PPD .. " ActiveProfile 2>/dev/null; echo '--'; "
  .. "busctl get-property " .. PPD .. " Profiles 2>/dev/null"

local function refreshPower()
  noctalia.runAsync(POWER_CMD, function(r)
    if holding("power") then return end
    local parts = S.parts(r.stdout)
    local u = parts[1] or ""
    local function field(name) return noctalia.string.trim(string.match(u, name .. ":%s*([^\n]+)") or "") end
    local tte, ttf = field("time to empty"), field("time to full")
    local rate = tonumber(string.match(field("energy%-rate"), "([%d%.]+)"))
    local cap = tonumber(string.match(field("capacity"), "([%d%.]+)"))
    local profiles = {}
    for name in string.gmatch(parts[3] or "", '"Profile" s "([%w%-]+)"') do table.insert(profiles, name) end
    local order = { ["power-saver"] = 1, balanced = 2, performance = 3 }
    table.sort(profiles, function(a, b) return (order[a] or 9) < (order[b] or 9) end)
    publish("graphite.power", {
      pct = tonumber(string.match(field("percentage"), "([%d%.]+)")) or 0,
      state = field("state"),
      timeLeft = if ttf ~= "" then ttf .. " to full" elseif tte ~= "" then tte .. " left" else "",
      rate = if rate and rate > 0 then string.format("%.1f W", rate) else "",
      health = if cap then string.format("%d%% health", math.floor(cap + 0.5)) else "",
      profile = string.match(parts[2] or "", '"([%w%-]+)"') or "",
      profiles = profiles,
    })
  end, 6000)
end

-- ── Volume ──────────────────────────────────────────────────────────────────

local function refreshVolume()
  noctalia.runAsync("wpctl get-volume @DEFAULT_AUDIO_SINK@; echo '--'; wpctl get-volume @DEFAULT_AUDIO_SOURCE@", function(r)
    local parts = S.parts(r.stdout)
    local function parse(s)
      local v = tonumber(string.match(s or "", "Volume:%s*([%d%.]+)"))
      return if v then math.floor(v * 100 + 0.5) else nil, string.find(s or "", "MUTED", 1, true) ~= nil
    end
    local pct, muted = parse(parts[1])
    local inPct, inMuted = parse(parts[2])
    if pct then publish("graphite.vol", { pct = pct, muted = muted, inPct = inPct or 0, inMuted = inMuted }) end
  end, 3000)
end

-- ── GPU ─────────────────────────────────────────────────────────────────────

-- Reads runtime_status through supergfxd, so it never wakes the NVIDIA card. Read
-- once at start, then only when the GPU panel asks (S.poke("gpu"), while it is open).
local function refreshGpu()
  noctalia.runAsync({ "supergfxctl", "-g", "-S", "-p", "-P" }, function(r)
    if r.exitCode ~= 0 then
      publish("graphite.gpu", {})
      return
    end
    local lines = {}
    for line in string.gmatch(r.stdout or "", "[^\n]+") do table.insert(lines, line) end
    publish("graphite.gpu", { mode = lines[1], power = lines[2], action = lines[3], pending = lines[4] })
  end, 3000)
end

-- ── Events ──────────────────────────────────────────────────────────────────

local EVENT = {
  ws = function(v) publishText("graphite.ws", v) end,
  wsActive = function(v) publishText("graphite.wsActive", v) end,
  win = function(v) publishText("graphite.win", v) end,
  windows = refreshTasks,
  vol = refreshVolume,
  dev = function() noctalia.state.set("graphite.audioRev", tostring(noctalia.nowMs())) end,
  net = refreshWifi,
  bt = refreshBt,
  power = function() refreshBattery(); refreshPower() end,
  clip = function() noctalia.state.set("graphite.clipRev", tostring(noctalia.nowMs())) end,
  notif = onNotifLine,
}

local dir = noctalia.pluginDir() or "."
noctalia.runStream("sh '" .. dir .. "/build.sh' >/dev/null 2>&1; exec '" .. dir .. "/bin/graphite-events' '" .. (dataDir or "/tmp") .. "'", function(line)
  local tag, payload = string.match(line, "^([^\t]*)\t?(.*)$")
  local fn = EVENT[tag]
  if fn then fn(payload) end
end)

-- Panels call S.poke("net" | "bt" | "power" | "gpu" | "vol") when they need a fresh read.
local POKE = { net = refreshWifi, bt = refreshBt, gpu = refreshGpu, vol = refreshVolume,
  power = function() refreshBattery(); refreshPower() end }
noctalia.state.watch("graphite.poke", function(v)
  local fn = POKE[string.match(tostring(v or ""), "^(%a+)") or ""]
  if fn then fn() end
end)

-- ── Switches ────────────────────────────────────────────────────────────────

local function onOff(payload, cur)
  if payload == "on" then return true end
  if payload == "off" then return false end
  return not cur
end

-- Publish the new state at once, hold back reads until the hardware has settled,
-- then read it back (twice, bluez is slow to report).
local function settle(kind)
  hold[kind] = noctalia.nowMs() + SETTLE_MS
  due[kind] = hold[kind]
  again[kind] = hold[kind] + AGAIN_MS
end

local COMMAND = {}

-- Noctalia has no status query for caffeine and forced night light, so this is
-- their only record: every switch has to come through here.
function COMMAND.caffeine(payload)
  local cur = noctalia.state.get("graphite.caffeine") == true
  local want = onOff(payload, cur)
  if want == cur then return end
  noctalia.runAsync({ "noctalia", "msg", if want then "caffeine-enable" else "caffeine-disable" })
  noctalia.state.set("graphite.caffeine", want)
end

function COMMAND.night(payload)
  local cur = noctalia.state.get("graphite.night") == true
  local want = onOff(payload, cur)
  if want == cur then return end
  noctalia.runAsync({ "noctalia", "msg", "nightlight-force-toggle" })
  noctalia.state.set("graphite.night", want)
end

function COMMAND.dnd(payload)
  local want = onOff(payload, notif.dnd)
  notif.dnd = want
  publishNotif()
  noctalia.runAsync({ "noctalia", "msg", "notification-dnd-set", if want then "on" else "off" }, function(_r)
    refreshDnd()
  end, 4000)
end

local function radio(kind, key, field, verb, payload)
  local cur = current(key)
  local want = onOff(payload, cur[field] == true)
  cur[field] = want
  if not want then cur.connected = false; cur.devices = {} end
  publish(key, cur)
  hold[kind] = noctalia.nowMs() + 15000  -- until the command below returns
  noctalia.runAsync({ "noctalia", "msg", verb .. (if want then "enable" else "disable") }, function(_r)
    settle(kind)
  end, 8000)
end

function COMMAND.wifi(payload) radio("wifi", "graphite.wifi", "radio", "wifi-", payload) end
function COMMAND.bt(payload) radio("bt", "graphite.bt", "powered", "bluetooth-", payload) end

-- profile [<name>|next]
function COMMAND.profile(payload)
  local cur = current("graphite.power")
  local list = cur.profiles or {}
  local target = payload
  if target == nil or target == "" or target == "next" or target == "toggle" then
    local i = table.find(list, cur.profile or "") or 0
    target = list[(i % math.max(#list, 1)) + 1]
  end
  if not target then return end
  cur.profile = target
  publish("graphite.power", cur)
  hold.power = noctalia.nowMs() + 5000
  noctalia.runAsync({ "noctalia", "msg", "power-set", target }, function(_r)
    hold.power = nil
    refreshPower()
  end, 4000)
end

-- mute out|in
function COMMAND.mute(payload)
  local input = payload == "in"
  local cur = current("graphite.vol")
  local field = if input then "inMuted" else "muted"
  cur[field] = not cur[field]
  publish("graphite.vol", cur)
  noctalia.runAsync({ "wpctl", "set-mute", if input then "@DEFAULT_AUDIO_SOURCE@" else "@DEFAULT_AUDIO_SINK@", "toggle" })
end

-- drawer open|close|toggle
function COMMAND.drawer(payload)
  local open = noctalia.state.get("graphite.drawer") == "open"
  local want = if payload == "open" then true elseif payload == "close" then false else not open
  noctalia.state.set("graphite.drawer", if want then "open" else "closed")
end

-- notifs clear: dismiss everything, like the drawer's Clear all (pop-ups, Noctalia's
-- history and ours), and slide the drawer away if it is open
function COMMAND.notifs(payload)
  if payload ~= "clear" then return end
  history = {}
  publishHistory()
  notif.unread = 0
  publishNotif()
  noctalia.runAsync({ "noctalia", "msg", "notification-clear-active" })
  noctalia.runAsync({ "noctalia", "msg", "notification-clear-history" })
  noctalia.state.set("graphite.drawer", "closed")
end

local function pollAll()
  for k in POLL do due[k] = 0 end
end

function COMMAND.refresh()
  pollAll()
  refreshVolume()
  refreshGpu()
end

local function run(event, payload)
  local fn = COMMAND[event]
  if fn then fn(payload) end
end

-- Keybinds: noctalia msg plugin vyeos/graphite:service all <event> [payload]
function onIpc(event, payload)
  run(event, payload)
end

-- In-process: S.svc(event, payload) -> "event:payload:ms"
noctalia.state.watch("graphite.cmd", function(v)
  local event, payload = string.match(tostring(v or ""), "^([^:]*):([^:]*):")
  if event then run(event, payload) end
end)

-- ── Tick ────────────────────────────────────────────────────────────────────

local POLLERS = {
  wifi = refreshWifi, bt = refreshBt, batt = refreshBattery, power = refreshPower,
  dnd = refreshDnd, tasks = refreshTasks,
}

noctalia.idle.watch(IDLE_AFTER_SECS, function(isIdle)
  idle = isIdle
  if not isIdle then pollAll() end
end)

local lastMinute = 0
function update()
  local now = noctalia.nowMs()
  if not idle then
    for kind, fn in POLLERS do
      if now >= (due[kind] or 0) then
        due[kind] = now + POLL[kind]
        fn()
      end
    end
  end
  for kind, at in again do
    if now >= at then
      again[kind] = nil
      POLLERS[kind]()
    end
  end
  if obsRunning and now >= (due.rec or 0) then
    due.rec = now + REC_MS
    refreshRecording()
  end
  -- relative times in the open drawer
  local minute = now // 60000
  if minute ~= lastMinute then
    lastMinute = minute
    if noctalia.state.get("graphite.drawer") == "open" then
      noctalia.state.set("graphite.drawerTick", tostring(now))
    end
  end
end

refreshVolume()
refreshGpu()
