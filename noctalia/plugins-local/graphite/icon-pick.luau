--!nonstrict
-- Choosing an image, inside a panel: a path field with suggestions under it.
-- Typing a word searches the images in your home (newest first); typing a path
-- (/ or ~) lists that folder, hidden ones too once the name starts with a dot.
-- Tab completes the highlighted row into the field, Enter takes it (a folder
-- opens), an https link is used as typed.
--
-- P.start(o)  o: { helper, pick(path, done) }   done(err) shows err, or nothing
-- P.top() / P.body() / P.hints() build the view; P.enter(), P.move(d),
-- P.complete() drive it.

local S = require("./style.luau")

local P = {}

local ROW_H = 40
local MAX_ROWS = 60
local THUMB_MAX = 400000 -- bigger images get a glyph, not a live decode
local IMAGE_EXT = { png = true, svg = true, jpg = true, jpeg = true, webp = true, gif = true, ico = true }

local home = string.match(noctalia.pluginDataDir() or "", "^(/home/[^/]+)") or "/root"
local o = nil
local text, gen = "", 0
local index = nil -- { {path, size, lpath} } from `graphite images`, newest first
local rows, sel = {}, 1
local busy, err = false, nil
local redraw = function() end
local H = S.hover(function() redraw() end)

local function tilde(path) return (string.gsub(path, "^" .. home, "~", 1)) end
local function expand(path)
  if path == "~" or string.sub(path, 1, 2) == "~/" then return home .. string.sub(path, 2) end
  return path
end
local function isLink(t) return string.find(t, "^https?://") ~= nil end
local function isPath(t) return string.find(t, "^[~/]") ~= nil end
local function ext(name) return string.lower(string.match(name, "%.(%w+)$") or "") end

local function folderRows(t)
  local dir, base = string.match(t, "^(.*/)([^/]*)$")
  if not dir then dir, base = t .. "/", "" end -- "~" alone
  local real = expand(dir)
  local lbase = string.lower(base)
  local names = noctalia.listDir(real)
  if type(names) ~= "table" then return {} end
  table.sort(names, function(a, b) return string.lower(a) < string.lower(b) end)
  local dirs, files = {}, {}
  for _, name in names do
    if #dirs + #files >= MAX_ROWS then break end
    local hidden = string.sub(name, 1, 1) == "."
    if (not hidden or string.sub(lbase, 1, 1) == ".") and string.sub(string.lower(name), 1, #lbase) == lbase then
      local full = real .. name
      if IMAGE_EXT[ext(name)] then
        local fi = noctalia.fileInfo(full)
        if fi and not fi.isDir then table.insert(files, { path = full, size = fi.size or 0 }) end
      else
        local fi = noctalia.fileInfo(full)
        if fi and fi.isDir then table.insert(dirs, { path = full, dir = true }) end
      end
    end
  end
  for _, f in files do table.insert(dirs, f) end
  return dirs
end

local function searchRows(t)
  local out = {}
  if not index then return out end
  local words = {}
  for w in string.gmatch(string.lower(t), "%S+") do table.insert(words, w) end
  for _, f in index do
    local ok = true
    for _, w in words do
      if not string.find(f.lpath, w, 1, true) then ok = false; break end
    end
    if ok then
      table.insert(out, f)
      if #out >= MAX_ROWS then break end
    end
  end
  return out
end

local function refilter()
  local t = noctalia.string.trim(text)
  if isLink(t) then rows = {}
  elseif isPath(t) then rows = folderRows(t)
  else rows = searchRows(t) end
  sel = math.clamp(sel, 1, math.max(1, #rows))
end

local function setText(t)
  text, gen = t, gen + 1 -- ui.input only takes a new value through a new key
  sel, err = 1, nil
  refilter()
  redraw()
end

function P.init(cb) redraw = cb.redraw end

function P.start(opts)
  o, busy, err, H.id = opts, false, nil, nil
  setText("")
  noctalia.runAsync(opts.helper, function(r)
    local d = if r.exitCode == 0 then noctalia.json.decode(noctalia.string.trim(r.stdout or "")) else nil
    if type(d) ~= "table" or not o then return end
    for _, f in d do f.lpath = string.lower(tilde(f.path)) end
    index = d
    refilter()
    redraw()
  end, 10000)
end

function P.cancel() o = nil end

local function take(path)
  if busy or not o then return end
  busy, err = true, nil
  redraw()
  local mine = o
  o.pick(path, function(e)
    if o ~= mine then return end
    busy, err = false, e
    redraw()
  end)
end

-- Tab: put the highlighted row in the field; a folder gets its slash so the
-- next Tab goes into it.
function P.complete()
  local r = rows[sel]
  if not r then return end
  setText(tilde(r.path) .. (if r.dir then "/" else ""))
end

function P.enter()
  local r = rows[sel]
  if r and r.dir then P.complete(); return end
  if r then take(r.path); return end
  local t = noctalia.string.trim(text)
  if t == "" then err = "Type a path, a name or a link"; redraw(); return end
  if isPath(t) and string.sub(t, -1) == "/" then err = "No images in this folder"; redraw(); return end
  take(t)
end

function P.move(d)
  if #rows == 0 then return end
  sel, H.id = S.step(sel, d, #rows), nil
  redraw()
end

-- ── View ────────────────────────────────────────────────────────────────────

local function thumb(r)
  if r.dir then
    return ui.row({ width = 28, height = 28, align = "center", justify = "center" }, { S.glyph("folder", { size = 20, color = S.C.sub }) })
  end
  if ext(r.path) == "svg" or (r.size or 0) <= THUMB_MAX then
    return ui.image({ path = r.path, width = 28, height = 28, fit = "contain" })
  end
  return ui.row({ width = 28, height = 28, fill = S.C.well, align = "center", justify = "center" }, { S.glyph("photo", { size = 16, color = S.C.dim }) })
end

local function row(i, r)
  local isSel = sel == i
  local name = string.match(r.path, "([^/]+)$") or r.path
  local where = tilde(string.match(r.path, "^(.*)/[^/]+$") or "")
  local kids = {
    thumb(r),
    ui.column({ flexGrow = 1, gap = 1, justify = "center" }, {
      ui.label({ text = name .. (if r.dir then "/" else ""), fontFamily = S.sans, fontSize = S.FS.body,
        color = if isSel then S.C.text else S.C.sub, maxWidth = 440, maxLines = 1 }),
      ui.label({ text = where, fontFamily = S.sans, fontSize = S.FS.sm, color = S.C.dim, maxWidth = 440, maxLines = 1 }),
    }),
  }
  if isSel then table.insert(kids, S.caption(if r.dir then "tab open" else "↵")) end
  return S.item({
    key = "i-" .. r.path,
    height = ROW_H,
    selected = isSel,
    hovered = H.id == i,
    onClick = function() sel = i; P.enter() end,
    onHover = H.fn(i),
  }, kids)
end

function P.field(onSubmit)
  return ui.row({ height = 40, paddingH = 10, gap = 10, fill = S.C.well, align = "center" }, {
    S.glyph("photo", { size = 17, color = S.C.sub }),
    ui.input({ key = "ip-" .. gen, value = text, placeholder = "Search images, or type ~/path or a link",
      frameVisible = false, focus = true, fontSize = S.FS.lg, controlSize = "sm", flexGrow = 1, onSubmit = onSubmit,
      onChange = function(v)
        v = v or ""
        if v == text then return end
        text, sel, err, H.id = v, 1, nil, nil
        refilter()
        redraw()
      end }),
    S.caption(tostring(#rows)),
  })
end

function P.body()
  local list = {}
  for i, r in rows do table.insert(list, row(i, r)) end
  if #list == 0 then
    local t = noctalia.string.trim(text)
    local msg = if isLink(t) then "enter downloads this link"
      elseif not index and not isPath(t) then "looking for images"
      else "no images here"
    table.insert(list, ui.column({ paddingV = 50, align = "center" }, { S.caption(msg) }))
  end
  return ui.scroll({ key = "icons", flexGrow = 1, gap = 0, revealKey = if rows[sel] then "i-" .. rows[sel].path else nil }, list)
end

function P.note()
  if busy then return "Adding icon…" end
  return err
end

function P.hints()
  return { "↑↓ move", "tab complete", "↵ use", "ctrl k back" }
end

return P
