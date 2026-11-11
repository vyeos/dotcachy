--!nonstrict
-- Every kind of result the launcher can show, and what each one's Ctrl+K menu offers.
-- An item's `run` is a plain command line, so a keybind can run it with the panel closed.

local S = require("./style.luau")
local E = require("./calc-eval.luau")
local CATS = require("./calc-units.luau")

local Src = {}

local dir = noctalia.pluginDir() or "."
local dataDir = noctalia.pluginDataDir() or "."
local BIN = dir .. "/bin/graphite"
local PREFIX_MAX = 60

Src.KIND_ORDER = { "Defaults", "Apps", "Web apps", "Windows", "Toggles", "Connections", "Power", "Panels", "Quicklinks", "Files", "Shortcuts" }

local function helper(...) return { BIN, ... } end
local function copyCmd(text) return { "wl-copy", "--", text } end
local function msg(...) return { "noctalia", "msg", ... } end
local function panelCmd(id) return msg("panel-toggle", "vyeos/graphite:" .. id) end

function Src.helper(...) return helper(...) end

local function item(kind, id, name, comment, extra)
  local it = extra or {}
  it.kind, it.id, it.name, it.comment = kind, id, name, comment or ""
  it.lname = string.lower(name)
  it.squash = string.gsub(it.lname, "[^%w]", "")
  it.hay = (it.hay or "") .. " " .. string.lower(it.comment)
  return it
end

local function urlEncode(s)
  return (string.gsub(s, "[^%w%-%._~]", function(c) return string.format("%%%02X", string.byte(c)) end))
end

-- ── Fixed lists ─────────────────────────────────────────────────────────────

local function service(event, payload)
  local c = msg("plugin", "vyeos/graphite:service", "all", event)
  if payload then table.insert(c, payload) end
  return c
end

local function truth(v) return if v == true then "on" else "off" end

local function toggles()
  local wifi, bt, vol, notif = S.read("graphite.wifi") or {}, S.read("graphite.bt") or {}, S.read("graphite.vol") or {}, S.read("graphite.notif") or {}
  local power = S.read("graphite.power") or {}
  local T = {
    { "caffeine", "Caffeine", "Keep the screen awake", "coffee", truth(noctalia.state.get("graphite.caffeine")), service("caffeine"), "awake sleep idle" },
    { "night", "Night Light", "Warmer colours", "moon", truth(noctalia.state.get("graphite.night")), service("night"), "blue filter warm" },
    { "dnd", "Do Not Disturb", "Silence notifications", "bell-off", truth(notif.dnd), service("dnd"), "dnd quiet notifications" },
    { "wifi", "Wi-Fi", "Turn the radio on or off", "wifi", truth(wifi.radio), service("wifi"), "wireless network internet" },
    { "bt", "Bluetooth", "Turn the radio on or off", "bluetooth", truth(bt.powered), service("bt"), "wireless" },
    { "mute", "Mute Output", "Silence speakers", "volume-off", truth(vol.muted), service("mute", "out"), "sound audio speaker volume" },
    { "mute-in", "Mute Microphone", "Silence the mic", "microphone-off", truth(vol.inMuted), service("mute", "in"), "sound audio mic input" },
  }
  local out = {}
  for _, t in T do
    table.insert(out, item("Toggles", "cmd:" .. t[1], t[2], t[3], { glyph = t[4], state = t[5], run = t[6], hay = t[7], fuzzy = true, pinnable = true }))
  end
  local label = S.PROFILE_LABEL[power.profile or ""]
  table.insert(out, item("Toggles", "cmd:profile", "Power Profile: Next", if label then "Currently " .. label else "Cycle power profiles",
    { glyph = "gauge", run = service("profile", "next"), hay = "performance balanced saver battery", fuzzy = true, pinnable = true }))
  return out
end

local function powerItems()
  local P = {
    { "lock", "Lock", "Lock the screen", "lock", false },
    { "lock-and-suspend", "Sleep", "Lock and suspend", "zzz", false },
    { "logout", "Log Out", "Asks first", "logout", true },
    { "reboot", "Reboot", "Asks first", "refresh", true },
    { "shutdown", "Shut Down", "Asks first", "power", true },
    { "windows", "Reboot to Windows", "Asks first", "windows-squares", true },
  }
  local out = {}
  for _, p in P do
    table.insert(out, item("Power", "power:" .. p[1], p[2], p[3], {
      glyph = p[4], run = if p[1] == "windows" then S.REBOOT_WINDOWS else msg("session", p[1]),
      hay = if p[1] == "windows" then "session restart reboot windows dual boot games" else "session power off suspend restart", fuzzy = true, pinnable = true,
      confirm = if p[5] then p[2] else nil,
      -- A keybind can't ask first, so these open the session panel, which does.
      bindRun = if p[5] then panelCmd("session-panel") else nil,
    }))
  end
  return out
end

-- Bar-key panels have a keyboard version pinned under the keys (see plugin.toml).
local KEYBOARD_PANEL = { ["wifi-panel"] = true, ["bluetooth-panel"] = true, ["audio-panel"] = true, ["gpu-panel"] = true, ["power-panel"] = true }

local function panelItems()
  local P = {
    { "cc", "Control Center", "Quick settings, volume and brightness" }, { "calendar", "Calendar", "This month at a glance" },
    { "wifi-panel", "Wi-Fi Panel", "Join and manage networks" }, { "bluetooth-panel", "Bluetooth Panel", "Pair and connect devices" },
    { "audio-panel", "Audio Panel", "Volume and output devices" }, { "power-panel", "Battery and Power", "Battery level and power profile" },
    { "gpu-panel", "GPU Mode", "Integrated, hybrid or dedicated graphics" }, { "session-panel", "Session", "Lock, sleep, log out, reboot, shut down" },
    { "emoji", "Emoji Picker", "Browse and copy emoji" }, { "clip", "Clipboard History", "Everything you copied recently" },
    { "switcher", "Window Switcher", "Jump between open windows" }, { "shortcuts", "Keyboard Shortcuts", "Every keybind in one list" },
    { "wallpaper", "Wallpaper Picker", "Browse and apply wallpapers" }, { "calc", "Calculator", "Sums and unit conversion" },
  }
  local out = {}
  for _, p in P do
    table.insert(out, item("Panels", "panel:" .. p[1], p[2], p[3], {
      glyph = "layout-grid", run = panelCmd(if KEYBOARD_PANEL[p[1]] then p[1] .. "-kb" else p[1]), location = dir, fuzzy = true, pinnable = true,
    }))
  end
  return out
end

-- ── Built from scans ────────────────────────────────────────────────────────

Src.ROLES = {
  terminal = { label = "Terminal", category = "TerminalEmulator" },
  browser = { label = "Browser", category = "WebBrowser" },
  files = { label = "File Manager", category = "FileManager" },
  editor = { label = "Text Editor", category = "TextEditor" },
}

-- The apps that could fill a role.
function Src.candidates(apps, role)
  local out = {}
  local want = ";" .. Src.ROLES[role].category .. ";"
  for _, a in apps do
    if string.find(a.categories or "", want, 1, true) then table.insert(out, a) end
  end
  table.sort(out, function(x, y) return x.lname < y.lname end)
  return out
end

local function appItem(a, role)
  local url = string.match(a.exec or "", "%-%-app=(https?://[^\"%s]*)")
  local kind = if string.sub(a.id, 1, 7) == "webapp-" then "Web apps" elseif role then "Defaults" else "Apps"
  local name, comment, hay = a.name, a.comment, a.hay
  if role then
    -- The default stands in for the app, so "terminal" and "kitty" find the same one row.
    name = Src.ROLES[role].label
    comment = "Default · " .. a.name
    hay = string.lower(a.name) .. " default " .. a.hay
  end
  local categories = {}
  for r, info in Src.ROLES do
    if r ~= role and string.find(a.categories or "", ";" .. info.category .. ";", 1, true) then table.insert(categories, r) end
  end
  return item(kind, a.id, name, comment, {
    icon = a.icon, hay = hay, fuzzy = true, pinnable = true, url = url, webapp = kind == "Web apps", isApp = true,
    role = role, canBecome = categories, alt = if role then "default " .. string.lower(a.name) else nil,
    run = helper("app", a.id), location = a.path,
  })
end

local function fileItem(f)
  local base = string.match(f.path, "([^/]+)$") or f.path
  local home = string.gsub(f.path, "^/home/[^/]+", "~", 1)
  return item("Files", "file:" .. f.path, base, home, {
    glyph = if f.dir then "folder" else "file", hay = string.lower(home), weight = -50,
    run = { "xdg-open", f.path }, location = f.path, copy = f.path, pinnable = false,
  })
end

local function windowItem(w, iconFor)
  return item("Windows", "win:" .. w.address, w.title, `Workspace {w.workspace} · {w.class}`, {
    glyph = "app-window", icon = iconFor[w.app], hay = string.lower(w.class), weight = -100, fuzzy = false,
    run = helper("focus", w.address), location = if w.path ~= "" then w.path else nil, address = w.address, transient = true,
    -- Window addresses don't last, so a keybind targets the window's app.
    bindRun = if w.app ~= "" then helper("app", w.app) else nil, bindId = if w.app ~= "" then w.app else nil, noBind = w.app == "",
  })
end

local function connectionItems(live)
  local out = {}
  for _, n in live.wifi or {} do
    table.insert(out, item("Connections", "wifi:" .. n.name, (if n.connected then "Disconnect from " else "Connect to ") .. n.name, "Wi-Fi network", {
      glyph = "wifi", state = if n.connected then "on" else nil, hay = "wifi network", pinnable = true,
      run = { "nmcli", "connection", if n.connected then "down" else "up", "id", n.name },
      forget = { "nmcli", "connection", "delete", "id", n.name },
    }))
  end
  for _, d in live.bluetooth or {} do
    table.insert(out, item("Connections", "bt:" .. d.mac, (if d.connected then "Disconnect from " else "Connect to ") .. d.name, "Bluetooth device", {
      glyph = "bluetooth", state = if d.connected then "on" else nil, hay = "bluetooth device", pinnable = true,
      run = { "bluetoothctl", if d.connected then "disconnect" else "connect", d.mac },
      forget = { "bluetoothctl", "remove", d.mac },
    }))
  end
  return out
end

local bindsRaw, bindsList = nil, nil

-- Put each keybind on the result it runs. Only binds with no result of their own
-- (window management and the like) get a row.
local function attachShortcuts(out, roleItems)
  local raw = noctalia.readFile(dataDir .. "/binds.json")
  if raw ~= bindsRaw then
    bindsRaw = raw
    bindsList = if raw then noctalia.json.decode(raw) else nil
  end
  local list = bindsList
  Src.boundKeys = {}
  if type(list) ~= "table" then return end
  local byId = {}
  for _, it in out do byId[it.id] = it end
  for role, it in roleItems do byId["default:" .. role] = it end
  for i, b in list do
    local keys = table.concat(b.keys or {}, " + ")
    local owner = if b.target then byId[b.target] else nil
    local prefixed = b.target and string.find(b.target, "^[ecw][mla][oi][^:]*:") ~= nil -- emoji:, clip:, wall:
    if owner then
      if not owner.keybind then owner.keybind, owner.bindId = keys, b.target end
    elseif prefixed then
      Src.boundKeys[b.target] = keys -- these results are built later, behind their prefix
    else
      table.insert(out, item("Shortcuts", "bind:" .. i, b.desc or keys, b.group or "", {
        glyph = "keyboard", hay = string.lower(b.group or ""), weight = -80, keybind = keys,
        -- Run what the bind runs; only binds that can't be replayed (mouse drags, zoom) open the list.
        run = if b.cmd then { "sh", "-c", b.cmd } elseif b.dispatch then helper("dispatch", b.dispatch) else panelCmd("shortcuts"),
        direct = b.cmd ~= nil or b.dispatch ~= nil, copy = keys, configDir = true, bindId = "desc:" .. (b.desc or keys), transient = true, noBind = b.fixed == true,
      }))
    end
  end
end

local function quicklinkItems()
  local out = {}
  for _, q in Src.links do
    local home = string.gsub(q.url, "[?&][^?&]*{query}.*$", "")
    home = string.gsub(home, "{query}", "")
    table.insert(out, item("Quicklinks", "link:" .. q.id, q.name, `Quicklink · type {q.keyword} and your search`, {
      glyph = "link", hay = string.lower(q.keyword), alt = string.lower(q.keyword), fuzzy = true, pinnable = true,
      run = helper("web", home), url = home, link = q,
    }))
  end
  return out
end

-- Every result that appears without a prefix.
function Src.root(apps, live, links)
  Src.links = links
  local out, iconFor = {}, {}
  local function addAll(list) for _, it in list do table.insert(out, it) end end
  local roleOf, roleItems = {}, {}
  for role, d in live.defaults or {} do
    if Src.ROLES[role] and d.app ~= "" then roleOf[d.app] = role end
  end
  for _, a in apps do
    local it = appItem(a, roleOf[a.id])
    table.insert(out, it)
    if it.role then roleItems[it.role] = it end
    iconFor[a.id] = a.icon
  end
  for _, w in live.windows or {} do table.insert(out, windowItem(w, iconFor)) end
  addAll(toggles())
  addAll(connectionItems(live))
  addAll(powerItems())
  addAll(panelItems())
  addAll(quicklinkItems())
  for _, f in live.files or {} do table.insert(out, fileItem(f)) end
  attachShortcuts(out, roleItems)
  table.insert(out, item("Apps", "create-webapp", "Create Web App", "Turn a website into an app",
    { action = "webapp", glyph = "world", hay = "webapp web app pwa site website new add install", fuzzy = true, transient = true, noBind = true }))
  table.insert(out, item("Quicklinks", "create-quicklink", "Create Quicklink", "Save a link you can search",
    { action = "quicklink", glyph = "plus", hay = "url bookmark new add link", fuzzy = true, transient = true, noBind = true }))
  return out
end

-- ── Results that depend on the text ─────────────────────────────────────────

local function unitOf(cat, word)
  for _, u in cat.units do
    local label = string.lower(u[1])
    local short = string.gsub(string.match(label, "%((.-)%)") or "", "°", "")
    local long = noctalia.string.trim((string.gsub(label, "%(.-%)", "")))
    if word == short or word == long or word .. "s" == long or word == long .. "s" then return u end
  end
  return nil
end

local function convert(text)
  local num, from, to = string.match(string.lower(text), "^%s*([%d%.]+)%s*([%a°]+)%s+[ti][on]%s+([%a°]+)%s*$")
  if not num then return nil end
  local v = tonumber(num)
  if not v then return nil end
  from, to = string.gsub(from, "°", ""), string.gsub(to, "°", "")
  for _, cat in CATS do
    local a, b = unitOf(cat, from), unitOf(cat, to)
    if a and b then
      local base = if a.to then a.to(v) else v * a[2]
      return if b.back then b.back(base) else base / b[2]
    end
  end
  return nil
end

-- A Maths item for text, or nil when it isn't a sum.
function Src.maths(text)
  local v = nil
  if string.find(text, "%a") and string.find(text, "%s[ti][on]%s") then v = convert(text) end
  if v == nil and string.find(text, "%d") and (string.find(text, "[%+%-%*/%^%%%(]") or string.find(text, "%a%(")) then
    local a, b = string.match(text, "^%s*([%d%.]+)%s*%%%s*[oO][fF]%s*(.+)$")
    local src = if a then `({a}/100)*({b})` else text
    local ok, r = pcall(E.eval, src, { deg = false })
    if ok and type(r) == "number" then v = r end
  end
  if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then return nil end
  local shown = E.show(v)
  local sum = noctalia.string.trim(text)
  return item("Maths", "maths", shown, sum .. " · Enter copies", {
    glyph = "calculator", run = copyCmd(shown), copy = shown, sum = `{sum} = {shown}`, transient = true, noBind = true,
  })
end

-- A quicklink item when text starts with a quicklink keyword and a search.
function Src.quicklinkHit(text)
  local key, rest = string.match(text, "^%s*(%S+)%s+(.-)%s*$")
  if not key or rest == "" then return nil end
  key = string.lower(key)
  for _, q in Src.links or {} do
    if string.lower(q.keyword) == key then
      local url = string.gsub(q.url, "{query}", (string.gsub(urlEncode(rest), "%%", "%%%%")))
      return item("Quicklinks", "linkhit:" .. q.id, `{q.name}: {rest}`, "Opens in your browser", {
        glyph = "link", run = helper("web", url), url = url, transient = true, noBind = true,
      })
    end
  end
  return nil
end

function Src.webItem(text)
  local q = noctalia.string.trim(text)
  local url = "https://duckduckgo.com/?q=" .. urlEncode(q)
  return item("Web", "web", "DuckDuckGo: " .. q, "New tab in your open browser", {
    glyph = "world-search", run = helper("web", url), url = url, copy = url, transient = true, noBind = true,
  })
end

-- ── Prefixes ────────────────────────────────────────────────────────────────

local emoji = nil
local emojiLoading = false

local function emojiResults(rest, redraw)
  if not emoji then
    if not emojiLoading then
      emojiLoading = true
      noctalia.readFileAsync("/usr/share/noctalia/assets/emoji.json", function(raw)
        local d = if raw then noctalia.json.decode(raw) else nil
        emoji = {}
        for _, e in (if type(d) == "table" then d else {}) do
          table.insert(emoji, { e = e.emoji, name = e.name, hay = string.lower(e.name .. " " .. table.concat(e.keywords or {}, " ")) })
        end
        redraw()
      end)
    end
    return {}
  end
  local out = {}
  for _, e in emoji do
    if rest == "" or string.find(e.hay, rest, 1, true) then
      table.insert(out, item("Emoji", "emoji:" .. e.e, e.name, "Copies " .. e.e, {
        lead = e.e, run = copyCmd(e.e), copy = e.e, transient = true,
      }))
      if #out == PREFIX_MAX then break end
    end
  end
  return out
end

local function clipboardResults(rest)
  local raw = noctalia.readFile(dataDir .. "/clip-index.json")
  local list = if raw then noctalia.json.decode(raw) else nil
  local out = {}
  if type(list) ~= "table" then return out end
  for _, c in list do
    local text = c.text or ""
    if rest == "" or string.find(string.lower(text), rest, 1, true) then
      local line = string.gsub(string.sub(text, 1, 160), "%s+", " ")
      if c.kind == "image" then line = "Image" end
      table.insert(out, item("Clipboard", "clip:" .. tostring(c.id), line, S.ago(c.t) .. (if c.pinned then " · pinned" else ""), {
        glyph = "clipboard", run = helper("clip", dataDir, "copy", tostring(c.id)), clipId = tostring(c.id), copy = if c.kind == "text" then text else nil, transient = true,
      }))
      if #out == PREFIX_MAX then break end
    end
  end
  return out
end

local IMAGE_EXT = { jpg = true, jpeg = true, png = true, webp = true, jxl = true, bmp = true, gif = true } -- same as the wallpaper panel

-- Thumbnails are shared with the wallpaper panel: same folder, name and size.
local THUMB_W, THUMB_H, THUMB_JOBS = 392, 220, 2
local thumbQueue, thumbBusy, thumbRunning = {}, {}, 0

local function pumpThumbs(redraw)
  while thumbRunning < THUMB_JOBS and #thumbQueue > 0 do
    local job = table.remove(thumbQueue, 1)
    thumbRunning += 1
    noctalia.runAsync({ "magick", job.path .. "[0]", "-thumbnail", `{THUMB_W}x{THUMB_H}^`, "-gravity", "center",
      "-extent", `{THUMB_W}x{THUMB_H}`, "-quality", "85", job.thumb }, function(_r)
      thumbRunning -= 1
      thumbBusy[job.path] = nil
      pumpThumbs(redraw)
      redraw()
    end, 30000)
  end
end

-- The thumbnail's path if it's ready; otherwise starts making it and returns nil.
local function wallpaperThumb(path, redraw)
  noctalia.mkdirAll(dataDir .. "/thumbs")
  local thumb = dataDir .. "/thumbs/" .. string.gsub(path, "[^%w%.%-]", "_") .. ".jpg"
  local have, src = noctalia.fileInfo(thumb), noctalia.fileInfo(path)
  if have and src and have.mtime >= src.mtime then return thumb end
  if not thumbBusy[path] then
    thumbBusy[path] = true
    table.insert(thumbQueue, { path = path, thumb = thumb })
    pumpThumbs(redraw)
  end
  return nil
end

local function wallpaperResults(rest, redraw)
  local out = {}
  local folder = noctalia.wallpaperDirectory()
  local list = if folder then noctalia.listDir(folder) else nil
  if type(list) ~= "table" then return out end
  for _, f in list do
    local lf = string.lower(f)
    local ext = string.match(lf, "%.(%w+)$")
    if ext and IMAGE_EXT[ext] and (rest == "" or string.find(lf, rest, 1, true)) then
      local path = folder .. "/" .. f
      table.insert(out, item("Wallpapers", "wall:" .. path, f, "Wallpaper", {
        glyph = "photo", wallpaper = true, preview = wallpaperThumb(path, redraw),
        run = msg("wallpaper-set", path), location = path, copy = path, transient = true,
      }))
      if #out == PREFIX_MAX then break end
    end
  end
  return out
end

-- (section title, items) when text starts with a prefix, else nil.
function Src.prefixed(text, redraw)
  local lower = string.lower((string.gsub(text, "^%s+", "")))
  local title, results
  if string.sub(lower, 1, 1) == ":" then
    title, results = "Emoji", emojiResults(noctalia.string.trim(string.sub(lower, 2)), redraw)
  elseif string.sub(lower, 1, 3) == "cb " then
    title, results = "Clipboard", clipboardResults(noctalia.string.trim(string.sub(lower, 4)))
  elseif string.sub(lower, 1, 3) == "wp " then
    title, results = "Wallpapers", wallpaperResults(noctalia.string.trim(string.sub(lower, 4)), redraw)
  else
    return nil
  end
  for _, it in results do it.keybind = (Src.boundKeys or {})[it.id] end
  return title, results
end

-- ── Ctrl+K ──────────────────────────────────────────────────────────────────

-- What the first menu entry says, which is what Enter does.
local FIRST = {
  Apps = "Switch to it or open it", Defaults = "Switch to it or open it", ["Web apps"] = "Switch to it or open it", Windows = "Focus", Toggles = "Toggle", Power = "Run", Panels = "Open",
  Maths = "Copy answer", Emoji = "Copy", Clipboard = "Copy", Files = "Open", Wallpapers = "Apply", Shortcuts = "Open shortcuts panel",
  Web = "Search in a new tab", Quicklinks = "Open",
}

-- Entries are { label, hint, run = command } or { label, hint, op = name }; the panel carries out ops.
function Src.menu(it)
  local m = {}
  local function add(label, hint, field, value)
    table.insert(m, { label = label, hint = hint or "", [field] = value })
  end
  if it.action then
    add(it.name, "↵", "first", true) -- the Create rows do one thing
  elseif it.kind == "Connections" then
    add(if it.state == "on" then "Disconnect" else "Connect", "↵", "first", true)
  elseif it.direct then
    add("Run", "↵", "first", true)
    add("Open shortcuts panel", "", "run", panelCmd("shortcuts"))
  else
    add(FIRST[it.kind] or "Open", "↵", "first", true)
  end

  if it.isApp then
    add("Open new instance", "", "run", helper("app", it.id, "new"))
    add("Open file location", "ctrl enter", "op", "reveal")
    add("Close its windows", "", "run", helper("close-app", it.id))
    if it.webapp then
      add("Rename", "", "op", "rename")
      add("Change icon", "", "op", "icon")
      if it.url then add("Copy link", "", "run", copyCmd(it.url)) end
      add("Delete", "", "op", "delete-webapp")
    end
    if it.role then
      add("Change default " .. string.lower(Src.ROLES[it.role].label), "", "op", "change-default")
    end
    for _, role in it.canBecome or {} do
      table.insert(m, { label = "Set as default " .. string.lower(Src.ROLES[role].label), hint = "", op = "set-default", role = role, appId = it.id })
    end
  elseif it.kind == "Windows" then
    if it.location then add("Open file location", "ctrl enter", "op", "reveal") end
    add("Move to this workspace", "", "run", helper("move-here", it.address))
    add("Close window", "", "run", helper("close", it.address))
  elseif it.kind == "Connections" then
    add("Forget", "", "op", "forget")
  elseif it.kind == "Maths" then
    add("Copy with the sum", "", "run", copyCmd(it.sum))
    add("Open calculator", "", "run", panelCmd("calc"))
  elseif it.kind == "Emoji" then
    add("Copy name", "", "run", copyCmd(it.name))
  elseif it.kind == "Clipboard" then
    add("Pin in history", "", "run", helper("clip", dataDir, "pin", it.clipId))
    add("Delete from history", "", "run", helper("clip", dataDir, "del", it.clipId))
  elseif it.kind == "Files" then
    add("Open file location", "ctrl enter", "op", "reveal")
    add("Copy path", "ctrl shift c", "run", copyCmd(it.copy))
  elseif it.kind == "Wallpapers" then
    add("Open file location", "ctrl enter", "op", "reveal")
  elseif it.kind == "Panels" then
    add("Open file location", "ctrl enter", "op", "reveal")
  elseif it.kind == "Shortcuts" then
    add("Open file location", "ctrl enter", "op", "reveal")
    add("Copy key combo", "ctrl shift c", "run", copyCmd(it.copy))
  elseif it.kind == "Web" then
    add("Search in a new window", "", "run", helper("web", it.url, "new"))
    add("Copy link", "ctrl shift c", "run", copyCmd(it.url))
  elseif it.link then
    add("Edit", "", "op", "edit-quicklink")
    add("Copy link", "", "run", copyCmd(it.url))
    add("Delete", "", "op", "delete-quicklink")
  end

  if it.pinnable then
    add(it.pinned and "Unpin" or "Pin", "ctrl shift f", "op", "pin")
    add("Set alias", it.aliasText or "", "op", "alias")
  end
  if not it.noBind then
    add(if it.keybind then "Change keybind" else "Set keybind", it.keybind or "", "op", "bind")
  end
  return m
end

return Src
