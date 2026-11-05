--!nonstrict
-- Graphite Bar service: gathers everything the bar widgets show and publishes it
-- through noctalia.state as JSON strings (graphite.*). Widgets only render.
--
--   graphite.ws        [{ id, windows }]          Hyprland workspaces, sorted
--   graphite.wsActive  number                     focused workspace id
--   graphite.win       { cls, title }             focused window
--   graphite.tasks     [{ id, label, glyph, cls, rec, startedMs }]
--   graphite.wifi      { radio, connected, ssid, signal, wired }
--   graphite.bt        { powered, devices = { names } }
--   graphite.batt      { present, pct, status }
--   graphite.power     { pct, state, timeLeft, rate, health, profile, profiles }
--   graphite.vol       { pct, muted }             default output
--   graphite.gpu       { mode, power, action, pending }   supergfxd state
--   graphite.rec       { recording, startedMs, file }   OBS recording, if any
--   graphite.notif     { unread, dnd }            notifications since last opened
--   graphite.notifs    [{ id, app, summary, body, t }]   history, newest first

noctalia.setUpdateInterval(120)

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
local function publish(key, value)
  local s = noctalia.json.encode(value)
  if s and cache[key] ~= s then
    cache[key] = s
    noctalia.state.set(key, s)
  end
end

local function decode(s)
  local v = noctalia.json.decode(s or "")
  return v
end

-- ── Hyprland ────────────────────────────────────────────────────────────────

local dirty = true
local lastFull = 0

local function refreshHypr()
  noctalia.runAsync({ "hyprctl", "-j", "workspaces" }, function(r)
    if r.exitCode ~= 0 then return end
    local list = decode(r.stdout)
    if type(list) ~= "table" then return end
    local out = {}
    for _, w in list do
      if type(w.id) == "number" and w.id > 0 then
        table.insert(out, { id = w.id, windows = w.windows or 0 })
      end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    publish("graphite.ws", out)
  end, 2000)
  noctalia.runAsync({ "hyprctl", "-j", "activeworkspace" }, function(r)
    local d = decode(r.stdout)
    if type(d) == "table" and type(d.id) == "number" then publish("graphite.wsActive", d.id) end
  end, 2000)
  noctalia.runAsync({ "hyprctl", "-j", "activewindow" }, function(r)
    local d = decode(r.stdout)
    if type(d) ~= "table" then d = {} end
    publish("graphite.win", { cls = d.class or "", title = d.title or "" })
  end, 2000)
end

local dir = noctalia.pluginDir() or "."
noctalia.runStream("python3 -u '" .. dir .. "/hypr-events.py'", function(_line)
  dirty = true
end)

-- Clipboard history: wl-paste runs clip.py on every selection change; clip.py
-- prints "changed" after it rewrites clip-index.json, the clip panel reloads.
do
  local clipDir = noctalia.pluginDataDir()
  if clipDir then
    noctalia.runStream("wl-paste --watch python3 -u '" .. dir .. "/clip.py' '" .. clipDir .. "' store", function(_line)
      noctalia.state.set("graphite.clipRev", tostring(noctalia.nowMs()))
    end)
  end
end

-- ── Long-running tasks ──────────────────────────────────────────────────────

local function watchedSet()
  local raw = noctalia.getConfig("task_processes")
  if type(raw) ~= "string" or raw == "" then
    raw = "steam,obs,discord,spotify,syncthing,qbittorrent,blender"
  end
  local set, order = {}, {}
  for name in string.gmatch(raw, "[^,%s]+") do
    if not set[name] then
      set[name] = true
      table.insert(order, name)
    end
  end
  return set, order
end

local refreshRecording -- defined in the OBS section below

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
    refreshRecording(found.obs ~= nil)
  end, 3000)
end

-- ── OBS recording ───────────────────────────────────────────────────────────
-- While OBS records it keeps the output file open. Look for an open video file
-- among OBS's file descriptors and time the recording from the file's birth
-- time (or from when it was first seen, on filesystems without birth times).
-- No obs-websocket needed.

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

refreshRecording = function(obsRunning)
  if not obsRunning then
    recFirstSeen = {}
    publish("graphite.rec", { recording = false })
    return
  end
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
-- is opened. DND comes from Noctalia itself.
--   graphite.notifs   [{ id, app, summary, body, t }]   newest first
--   graphite.drawer   "open" | "closed"                 the right-edge drawer
-- Commands from the drawer arrive on graphite.notifCmd: "dismiss:<id>", "clear".

local MAX_HISTORY = 50
local DRAWER_W = 380
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
local function finishNotify(lines)
  local text = table.concat(lines, "\n") .. "\n"
  local strs = {}
  for v in string.gmatch(text, 'string "(.-)"\n') do table.insert(strs, v) end
  local app, summary, body = strs[1] or "", strs[3] or "", strs[4] or ""
  if summary == "" and body == "" then return end
  table.insert(history, 1, { id = nextId, app = app, summary = summary, body = body, t = os.time() })
  nextId += 1
  while #history > MAX_HISTORY do table.remove(history) end
  if noctalia.state.get("graphite.drawer") ~= "open" then
    notif.unread = math.min(notif.unread + 1, 999)
  end
  publishHistory()
  publishNotif()
end

noctalia.runStream(
  "dbus-monitor --session \"type='method_call',interface='org.freedesktop.Notifications',member='Notify'\"",
  function(line)
    if string.find(line, "member=Notify", 1, true) and string.find(line, "method call", 1, true) then
      collecting = {}
    elseif collecting then
      if string.match(line, "^%s*array %[") then
        local lines = collecting
        collecting = nil
        finishNotify(lines)
      else
        table.insert(collecting, line)
      end
    end
  end
)

function refreshDnd()
  noctalia.runAsync({ "noctalia", "msg", "notification-dnd-status" }, function(r)
    local out = string.lower(noctalia.string.trim(r.stdout or ""))
    notif.dnd = out == "on" or out == "true" or out == "enabled"
    publishNotif()
  end, 3000)
end

noctalia.state.watch("graphite.notifClear", function(_v)
  notif.unread = 0
  publishNotif()
end)
noctalia.state.watch("graphite.notifDndPoll", function(_v)
  refreshDnd()
end)
-- Every DND switch (control center, drawer, bell) asks for an explicit state;
-- the service sets it and only then reads it back, so the reading is never stale.
noctalia.state.watch("graphite.dndSet", function(v)
  local want = string.match(tostring(v or ""), "^(%a+)")
  if want ~= "on" and want ~= "off" then return end
  notif.dnd = want == "on"
  publishNotif()
  noctalia.runAsync({ "noctalia", "msg", "notification-dnd-set", want }, function(_r)
    refreshDnd()
  end, 4000)
end)
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
local function barThickness()
  return tonumber(noctalia.getSetting("bar.default.thickness")) or 38
end
noctalia.state.set("graphite.drawer", "closed")
noctalia.state.watch("graphite.drawer", function(v)
  if v == "open" then
    notif.unread = 0
    publishNotif()
    noctalia.layer.configure("notifs", {
      layer = "overlay",
      anchors = { "top", "right", "bottom" },
      width = DRAWER_W,
      margins = { top = barThickness() + 6, right = -(DRAWER_W + 20), bottom = 6 },
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

local function refreshWifi()
  noctalia.runAsync("nmcli radio wifi; echo '--'; nmcli -t -f ACTIVE,SIGNAL,SSID dev wifi 2>/dev/null; echo '--'; nmcli -t -f TYPE,STATE dev 2>/dev/null", function(r)
    local parts = {}
    for chunk in string.gmatch(r.stdout .. "\n--\n", "(.-)\n%-%-\n") do table.insert(parts, chunk) end
    local radio = string.find(parts[1] or "", "enabled", 1, true) ~= nil
    local info = { radio = radio, connected = false, ssid = "", signal = 0, wired = false }
    for line in string.gmatch(parts[2] or "", "[^\n]+") do
      local active, sig, ssid = string.match(line, "^(%a+):(%d+):(.*)$")
      if active == "yes" then
        info.connected = true
        info.signal = tonumber(sig) or 0
        info.ssid = string.gsub(ssid, "\\:", ":")
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
    local head, rest = string.match(r.stdout, "^(.-)\n%-%-\n?(.*)$")
    head = head or r.stdout
    local info = { powered = string.find(head or "", "yes", 1, true) ~= nil, devices = {} }
    for line in string.gmatch(rest or "", "[^\n]+") do
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
    local parts = {}
    for chunk in string.gmatch((r.stdout or "") .. "\n--\n", "(.-)\n%-%-\n") do table.insert(parts, chunk) end
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
  noctalia.runAsync({ "wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@" }, function(r)
    local v = tonumber(string.match(r.stdout or "", "Volume:%s*([%d%.]+)"))
    if v then
      publish("graphite.vol", { pct = math.floor(v * 100 + 0.5), muted = string.find(r.stdout, "MUTED", 1, true) ~= nil })
    end
  end, 3000)
end

-- ── GPU ─────────────────────────────────────────────────────────────────────

-- Reads runtime_status through supergfxd, so polling never wakes the NVIDIA card.
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

-- ── Tick ────────────────────────────────────────────────────────────────────

local due = { tasks = 0, wifi = 0, bt = 0, batt = 0, power = 0, dnd = 0, vol = 0, gpu = 0 }

-- Panels call S.poke("net" | "bt" | "power") after changing something.
noctalia.state.watch("graphite.poke", function(v)
  local what = string.match(tostring(v or ""), "^(%a+)")
  if what == "net" then due.wifi = 0 elseif what == "bt" then due.bt = 0 elseif what == "power" then due.batt = 0; due.power = 0 elseif what == "vol" then due.vol = 0 elseif what == "gpu" then due.gpu = 0 end
end)

function update()
  local now = noctalia.nowMs()
  if now - lastFull > 5000 then
    dirty = true
  end
  if dirty then
    dirty = false
    lastFull = now
    refreshHypr()
  end
  if now >= due.tasks then due.tasks = now + 3000; refreshTasks() end
  if now >= due.wifi then due.wifi = now + 8000; refreshWifi() end
  if now >= due.bt then due.bt = now + 10000; refreshBt() end
  if now >= due.batt then due.batt = now + 15000; refreshBattery() end
  if now >= due.power then due.power = now + 15000; refreshPower() end
  if now >= due.dnd then due.dnd = now + 10000; refreshDnd() end
  if now >= due.vol then due.vol = now + 2000; refreshVolume() end
  if now >= due.gpu then due.gpu = now + 5000; refreshGpu() end
end

function onIpc(event, payload)
  -- noctalia msg plugin vyeos/graphite:service all drawer open|close|toggle
  if event == "drawer" then
    local open = noctalia.state.get("graphite.drawer") == "open"
    local want = if payload == "open" then true elseif payload == "close" then false else not open
    noctalia.state.set("graphite.drawer", if want then "open" else "closed")
    return
  end
  -- noctalia msg plugin vyeos/graphite:service all caffeine|night [on|off|toggle]
  -- Noctalia has no status query for these, so every switch (keybinds, control
  -- center, bar) goes through graphite.caffeine / graphite.night to stay in sync.
  if event == "caffeine" or event == "night" then
    local key = "graphite." .. event
    local cur = noctalia.state.get(key) == true
    local want = if payload == "on" then true elseif payload == "off" then false else not cur
    if want ~= cur then
      if event == "caffeine" then
        noctalia.runAsync({ "noctalia", "msg", if want then "caffeine-enable" else "caffeine-disable" })
      else
        noctalia.runAsync({ "noctalia", "msg", "nightlight-force-toggle" })
      end
      noctalia.state.set(key, want)
    end
    return
  end
  -- noctalia msg plugin vyeos/graphite:service all dnd [on|off|toggle]
  if event == "dnd" then
    local want = if payload == "on" then true elseif payload == "off" then false else not notif.dnd
    noctalia.state.set("graphite.dndSet", (if want then "on:" else "off:") .. tostring(noctalia.nowMs()))
    return
  end
  -- noctalia msg plugin vyeos/graphite:service all bt|wifi [on|off|toggle]
  -- Shows the new state on the bar right away, then reads it back once the
  -- radio has settled (and again a little later, bluez is slow to report).
  if event == "bt" or event == "wifi" then
    local key = if event == "bt" then "graphite.bt" else "graphite.wifi"
    local field = if event == "bt" then "powered" else "radio"
    local cur = decode(noctalia.state.get(key)) or {}
    local want = if payload == "on" then true elseif payload == "off" then false else not cur[field]
    cur[field] = want
    if not want then cur.connected = false; cur.devices = {} end
    publish(key, cur)
    local cmd = if event == "bt" then "bluetooth-" else "wifi-"
    noctalia.runAsync({ "noctalia", "msg", cmd .. (if want then "enable" else "disable") }, function(_r)
      local soon = noctalia.nowMs() + 1500
      if event == "bt" then due.bt = soon else due.wifi = soon end
    end, 8000)
    return
  end
  if event == "refresh" then
    dirty = true
    due = { tasks = 0, wifi = 0, bt = 0, batt = 0, power = 0, dnd = 0, vol = 0, gpu = 0 }
  end
end
