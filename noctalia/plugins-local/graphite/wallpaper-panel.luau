--!nonstrict
-- Wallpaper picker (SUPER + SHIFT + W): a filter line over a grid of square-
-- cornered thumbnails from Noctalia's wallpaper folder. The current wallpaper
-- carries an inverted corner badge; the selection gets a light frame.
-- Arrows move, Enter or a double click applies (noctalia.setWallpaper).
-- Thumbnails are made with ImageMagick into pluginDataDir/thumbs, named after the
-- source's path, modification time and size: an image changed in place gets a new
-- thumbnail (and a new image path, so nothing cached shows the old one), and the
-- stale one is deleted.

local S = require("./style.luau")
S.fonts()

local COLS = 3
local TW = 196
local TH = 110
local GAP = 8
local EXT = { jpg = true, jpeg = true, png = true, webp = true, jxl = true, bmp = true, gif = true }

local dataDir = noctalia.pluginDataDir() or ""
local thumbDir = dataDir .. "/thumbs"
noctalia.mkdirAll(thumbDir)

local files = {}
local shown = {}
local thumbs = {}   -- path -> thumb path (once made, for the source as it is now)
local pending = {}
local queue = {}    -- thumbnails still to make; at most MAX_JOBS run at once
local running = 0
local MAX_JOBS = 2
local query = ""
local sel = 1
local H = S.hover(function() render() end)
local opens = 0
local lastClick = { i = 0, t = 0 }
local current = nil
local dir = nil

local function stem(path)
  return (string.gsub(path, "[^%w%.%-]", "_"))
end

local function thumbFor(path, src)
  return `{thumbDir}/{stem(path)}@{math.floor(src.mtime or 0)}-{src.size or 0}.jpg`
end

-- Delete this source's other thumbnails: older versions, and the unversioned
-- name thumbnails had before.
local function dropStale(path, keep)
  local base = stem(path)
  for _, name in noctalia.listDir(thumbDir) or {} do
    local full = thumbDir .. "/" .. name
    if full ~= keep and (name == base .. ".jpg" or string.sub(name, 1, #base + 1) == base .. "@") then
      noctalia.removeFile(full)
    end
  end
end

function pump()
  while running < MAX_JOBS and #queue > 0 do
    local job = table.remove(queue, 1)
    running += 1
    noctalia.runAsync({ "magick", job.path .. "[0]", "-thumbnail", `{TW * 2}x{TH * 2}^`, "-gravity", "center",
      "-extent", `{TW * 2}x{TH * 2}`, "-quality", "85", job.thumb }, function(r)
      running -= 1
      pending[job.path] = nil
      if r.exitCode == 0 then
        thumbs[job.path] = job.thumb
        dropStale(job.path, job.thumb)
      end
      pump()
      render()
    end, 30000)
  end
end

local function ensureThumb(path)
  local src = noctalia.fileInfo(path)
  if not src then return end
  local t = thumbFor(path, src)
  if thumbs[path] == t or pending[path] == t then return end
  if noctalia.fileInfo(t) then thumbs[path] = t; return end
  -- the source changed (or is new): drop the old thumbnail until the new one is made
  thumbs[path] = nil
  pending[path] = t
  table.insert(queue, { path = path, thumb = t })
  pump()
end

-- The wallpaper on screen. A panel gets no focused output name, so fall back to
-- asking each output in turn; the first one with a wallpaper wins.
local function currentWallpaper()
  local names = { noctalia.focusedOutputName() }
  for _, o in noctalia.outputs() or {} do
    table.insert(names, if type(o) == "table" then (o.name or o.connector) else o)
  end
  for _, n in names do
    if type(n) == "string" and n ~= "" then
      local p = noctalia.wallpaperPath(n)
      if p and p ~= "" then return p end
    end
  end
  return nil
end

local function scan()
  dir = noctalia.wallpaperDirectory()
  files = {}
  if dir then
    local list = noctalia.listDir(dir)
    if type(list) == "table" then
      for _, f in list do
        local ext = string.lower(string.match(f, "%.(%w+)$") or "")
        if EXT[ext] then table.insert(files, { name = f, path = dir .. "/" .. f, lname = string.lower(f) }) end
      end
    end
  end
  table.sort(files, function(a, b) return a.lname < b.lname end)
  -- thumbnails of images no longer in the folder (renamed, deleted, another folder) go too
  if dir then
    local live = {}
    for _, f in files do live[stem(f.path)] = true end
    for _, name in noctalia.listDir(thumbDir) or {} do
      local base = string.match(name, "^(.*)@[^@]*%.jpg$") or string.match(name, "^(.*)%.jpg$")
      if base and not live[base] then noctalia.removeFile(thumbDir .. "/" .. name) end
    end
  end
  current = currentWallpaper()
end

local function compute()
  shown = {}
  local q = string.lower(query)
  for _, f in files do
    if q == "" or string.find(f.lname, q, 1, true) then table.insert(shown, f) end
  end
  sel = math.clamp(sel, 1, math.max(1, #shown))
  for _, f in shown do ensureThumb(f.path) end
end

local function apply(f)
  if not f then return end
  noctalia.setWallpaper(f.path)
  current = f.path
  render()
end

local function tile(i, f)
  local isSel = sel == i
  local isCur = current == f.path
  local t = thumbs[f.path]
  local img = if t then ui.image({ path = t, width = TW, height = TH, fit = "cover", radius = 0 })
    else ui.row({ width = TW, height = TH, fill = S.C.well, align = "center", justify = "center" }, { S.caption("…") })
  -- selection = a light frame around the picture; current = filled square
  return ui.column({
    key = "t-" .. i,
    width = TW + 6, gap = 4, radius = 0,
    onClick = function()
      -- single click selects, double click (same tile within 400 ms) applies
      local now = noctalia.nowMs()
      if lastClick.i == i and now - lastClick.t < 400 then
        lastClick = { i = 0, t = 0 }
        apply(f)
      else
        lastClick = { i = i, t = now }
        sel = i; render()
      end
    end,
    onHover = H.fn(i),
  }, {
    ui.row({ width = TW + 6, height = TH + 6, padding = 3, radius = 0,
      fill = if isSel then S.C.text elseif H.id == i then S.C.keyHover else S.C.clear }, { img }),
    ui.row({ width = TW + 6, height = 16, gap = 6, align = "center", paddingH = 3,
      fill = S.C.clear }, {
      ui.label({ text = f.name, fontFamily = S.mono, fontSize = S.FS.xs, maxWidth = TW - 24, maxLines = 1,
        color = if isSel then S.C.text else S.C.dim }),
      ui.spacer({ flexGrow = 1 }),
      ui.box({ width = 7, height = 7, radius = 0, fill = if isCur then S.C.text else S.C.clear }),
    }),
  })
end

function render()
  local rows, row = {}, {}
  for i, f in shown do
    table.insert(row, tile(i, f))
    if #row == COLS or i == #shown then
      table.insert(rows, ui.row({ key = "r-" .. i, gap = GAP }, row))
      row = {}
    end
  end
  if #shown == 0 then
    table.insert(rows, ui.column({ paddingV = 60, align = "center" }, {
      S.caption(if not dir then "no wallpaper folder set" elseif #files == 0 then "folder has no images" else "no matches"),
    }))
  end
  local cur = shown[sel]
  panel.render(ui.column({ gap = 8, flexGrow = 1, align = "stretch" }, {
    S.search({ glyph = "photo", key = "q-" .. opens, value = query, placeholder = "Filter wallpapers", count = #shown, onSubmit = function() apply(shown[sel]) end,
      onChange = function(v) query = v or ""; sel = 1; compute(); render() end }),
    S.hline("h1"),
    ui.scroll({ key = "grid", flexGrow = 1, gap = GAP, revealKey = "t-" .. sel }, rows),
    S.hline("h2"),
    ui.row({ align = "center", gap = 14, height = 20 }, {
      ui.label({ text = dir or "", fontFamily = S.mono, fontSize = S.FS.xs, color = S.C.dim, maxWidth = 300, maxLines = 1 }),
      ui.spacer({ flexGrow = 1 }),
      S.caption(if cur and cur.path == current then "current" else ""),
      S.caption("↵ apply"),
    }),
  }))
end

local function move(d)
  if #shown == 0 then return end
  sel = S.step(sel, d, #shown, COLS)
  H.id = nil
  render()
end

local MOVES = { left = -1, right = 1, up = -COLS, down = COLS }
local R = S.repeater(function(k) move(MOVES[k]) end, { "left", "right", "up", "down" })
function onFrameTick(dt) R.tick(dt) end

function onKey(key, pressed)
  if R.key(key, pressed) then return end
  if pressed == false then return end
  local k = string.lower(tostring(key))
  if k == "return" or k == "kp_enter" then apply(shown[sel])
  end
end

function onOpen(_context)
  R.stop()
  opens += 1
  query = ""
  H.id = nil
  scan()
  compute()
  sel = 1
  for i, f in shown do if f.path == current then sel = i end end
  render()
end

scan()
compute()
render()
