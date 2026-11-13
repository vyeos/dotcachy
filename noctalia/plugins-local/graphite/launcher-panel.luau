--!nonstrict
-- Launcher (SUPER + Space): one search line for apps, windows, toggles, power,
-- panels, maths, files, the web and more. Pinned apps and recents show
-- before anything is typed; ranked results after. Enter runs the highlighted
-- result, Ctrl+Enter opens its file location, Ctrl+K lists what else it can do.

local S = require("./style.luau")
local W = require("./webapp-form.luau")
local Pick = require("./icon-pick.luau")
local Rank = require("./launcher-rank.luau")
local Src = require("./launcher-sources.luau")
S.fonts()

local ROW_H = 44

local dataDir = noctalia.pluginDataDir()
local appsPath = if dataDir then dataDir .. "/apps.json" else nil
local livePath = if dataDir then dataDir .. "/launcher-live.json" else nil

local apps, live, items = {}, {}, {}
local shown, heads = {}, {} -- heads: shown index -> section title drawn above that row
local query, sel, opens = "", 1, 0
local histPos = nil         -- position in past searches while recalling them with Up
local note = nil            -- short message in the footer
local mode = "list"         -- list | menu | prompt | confirm | form | icon
local current = nil         -- the result a menu, prompt or confirm is about
local menu, menuSel = {}, 1
local prompt = nil          -- { title, label, value, placeholder, submit(text, done) }
local promptGen = 0
local confirm = nil         -- { text, action }
local lastSubmit = 0        -- Enter can reach both onKey and an input's onSubmit
local follow = true         -- scroll to the selection on the next draw (keyboard only, so the wheel isn't undone)
local H = S.hover(function() render() end)

-- ── Data ────────────────────────────────────────────────────────────────────

local function readJson(path)
  local raw = if path then noctalia.readFile(path) else nil
  local d = if raw then noctalia.json.decode(raw) else nil
  return if type(d) == "table" then d else nil
end

local function readApps()
  apps = readJson(appsPath) or {}
  for _, a in apps do a.lname = string.lower(a.name) end
end

local function rebuild()
  items = Src.root(apps, live, Rank.quicklinks())
end

-- Rescan apps in the background; the cached list shows meanwhile.
local function scan()
  if not appsPath then return end
  noctalia.runAsync(Src.helper("apps", appsPath), function(r)
    if r.exitCode == 0 and noctalia.string.trim(r.stdout or "") ~= "fresh" then
      readApps(); rebuild(); computeLater()
    end
  end, 15000)
end

local function gather()
  noctalia.runAsync(Src.helper("gather"), function(r)
    if r.exitCode ~= 0 then return end
    live = readJson(livePath) or {}
    rebuild()
    computeLater()
  end, 10000)
end

-- Rebuilding and ranking in one callback can exceed Noctalia's per-callback CPU
-- limit, so the ranking waits for the next frame.
local pendingCompute = false

function computeLater()
  pendingCompute = true
  panel.setNeedsFrameTick(true)
end

function compute()
  follow = true
  shown, heads = {}, {}
  local q = string.lower(noctalia.string.trim(query))
  local function section(title, list)
    if #list == 0 then return end
    heads[#shown + 1] = title
    for _, it in list do table.insert(shown, it) end
  end
  if q == "" then
    for _, s in Rank.home(items) do section(s.title, s.items) end
  else
    local title, prefixed = Src.prefixed(query, function() compute(); render() end)
    if title then
      section(title, prefixed)
    else
      local maths = Src.maths(query)
      if maths then section("Maths", { maths }) end
      local link = Src.quicklinkHit(query)
      if link then section("Quicklink", { link }) end
      local ranked = Rank.rank(items, q)
      if ranked[1] then section("Top result", { ranked[1] }) end
      for _, kind in Src.KIND_ORDER do
        local group = {}
        for i = 2, #ranked do
          if ranked[i].kind == kind then table.insert(group, ranked[i]) end
        end
        section(kind, group)
      end
      section("Search the web", { Src.webItem(query) })
    end
  end
  sel = math.clamp(sel, 1, math.max(1, #shown))
end

local function backToList(message)
  mode, current, prompt, confirm, note = "list", nil, nil, nil, message
  Pick.cancel()
  opens += 1 -- a new key rebuilds the search line, which gives it focus again
  compute()
  render()
end

-- ── Running things ──────────────────────────────────────────────────────────

local function close() panel.close() end

local function remember(it)
  if not it.transient then Rank.record(it.id, query) end
  Rank.pushHistory(query)
end

local function run(it, argv)
  remember(it)
  close()
  noctalia.runAsync(argv)
end

local function askPrompt(p)
  promptGen += 1
  prompt, note, mode = p, nil, "prompt"
  render()
end

local function askConfirm(it, text, action)
  current, confirm, note, mode = it, { text = text, action = action }, nil, "confirm"
  render()
end

local function reveal(it)
  if it.configDir then
    local path = string.gsub(noctalia.pluginDir() or "", "/noctalia/.*$", "/hypr/config/binds.lua")
    run(it, Src.helper("reveal", path))
  elseif it.location then
    run(it, Src.helper("reveal", it.location))
  else
    note = "This result has no file location"
    render()
  end
end

local function hasLocation(it) return it ~= nil and (it.location ~= nil or it.configDir == true) end

-- Run a helper that prints {status=...}, then hand the decoded reply to cb.
local function callHelper(argv, cb)
  noctalia.runAsync(argv, function(r)
    local d = if r.exitCode == 0 then noctalia.json.decode(noctalia.string.trim(r.stdout or "")) else nil
    cb(if type(d) == "table" then d else { status = "failed" })
  end, 20000)
end

local function askQuicklink(old)
  local v = { name = if old then old.name else "", keyword = if old then old.keyword else "", url = if old then old.url else "" }
  local function askUrl()
    askPrompt({ title = "Quicklink", label = "Link, with {query} where your search goes", value = v.url, placeholder = "https://www.youtube.com/results?search_query={query}",
      submit = function(text, done)
        if not string.find(text, "^https?://") then done("Start the link with https://"); return end
        Rank.saveQuicklink({ id = if old then old.id else tostring(os.time()), name = v.name, keyword = v.keyword, url = text })
        rebuild()
        done(nil, "Saved " .. v.name)
      end })
  end
  local function askKeyword()
    askPrompt({ title = "Quicklink", label = "Keyword you type before your search", value = v.keyword, placeholder = "yt",
      submit = function(text, done)
        if string.find(text, "%s") then done("Use one word"); return end
        v.keyword = string.lower(text)
        askUrl()
      end })
  end
  askPrompt({ title = "Quicklink", label = "Name", value = v.name, placeholder = "YouTube",
    submit = function(text, _done)
      v.name = text
      askKeyword()
    end })
end

local OPS = {}

function OPS.reveal(it) reveal(it) end

function OPS.pin(it)
  local now = Rank.togglePin(it.id)
  backToList((if now then "Pinned " else "Unpinned ") .. it.name)
end

function OPS.alias(it)
  askPrompt({ title = it.name, label = "Short name that finds this. Leave empty to remove it", value = Rank.aliasOf(it.id) or "", placeholder = "ff", allowEmpty = true,
    submit = function(text, done)
      Rank.setAlias(it.id, text)
      done(nil, if text == "" then "Alias removed" else `{text} now opens {it.name}`)
    end })
end

function OPS.bind(it)
  noctalia.state.set("graphite.bindTarget", noctalia.json.encode({
    id = it.bindId or it.id, name = it.name, keybind = it.keybind, run = it.bindRun or it.run,
  }))
  close()
  noctalia.togglePanel("vyeos/graphite:bind-record")
end

function OPS.rename(it)
  askPrompt({ title = it.name, label = "New name", value = it.name, placeholder = "WhatsApp",
    submit = function(text, done)
      callHelper(Src.helper("webapp-rename", it.id, text), function(d)
        if d.status == "ok" then scan(); done(nil, "Renamed to " .. text) else done("Couldn't rename it") end
      end)
    end })
end

function OPS.icon(it)
  mode, note = "icon", nil
  Pick.start({
    helper = Src.helper("images"),
    pick = function(path, done)
      callHelper(Src.helper("webapp-icon", it.id, path), function(d)
        if mode ~= "icon" then return end
        if d.status == "ok" then scan(); backToList("Icon changed") else done(d.message or "Couldn't use that image") end
      end)
    end,
  })
  render()
end

local function setDefault(role, appId)
  callHelper(Src.helper("set-default", role, appId), function(d)
    if d.status == "ok" then gather() end
    backToList(if d.status == "ok" then Src.ROLES[role].label .. " changed" else "Couldn't change the default")
  end)
end

OPS["change-default"] = function(it)
  local m = {}
  for _, a in Src.candidates(apps, it.role) do
    table.insert(m, { label = a.name, hint = if a.id == it.id then "current" else "", op = "pick-default", role = it.role, appId = a.id })
  end
  menu, menuSel = m, 1
  render()
end

OPS["pick-default"] = function(it, e)
  if e.appId == it.id then backToList(nil) else setDefault(e.role, e.appId) end
end

OPS["set-default"] = function(_it, e) setDefault(e.role, e.appId) end

OPS["delete-webapp"] = function(it)
  askConfirm(it, `Delete {it.name}? Its launcher and icon are removed.`, function()
    callHelper(Src.helper("webapp-delete", it.id), function(d)
      if d.status == "ok" then scan() end
      backToList(if d.status == "ok" then "Deleted " .. it.name else "Couldn't delete it")
    end)
  end)
end

function OPS.forget(it)
  askConfirm(it, `Forget {it.name}? You would have to pair or sign in again.`, function()
    close()
    noctalia.runAsync(it.forget)
  end)
end

OPS["edit-quicklink"] = function(it) askQuicklink(it.link) end

OPS["delete-quicklink"] = function(it)
  askConfirm(it, `Delete the {it.name} quicklink?`, function()
    Rank.deleteQuicklink(it.link.id)
    rebuild()
    backToList("Deleted " .. it.name)
  end)
end

local function activate(it)
  if not it then return end
  if it.action == "webapp" then
    mode, note = "form", nil
    H.id = nil
    W.start()
    render()
  elseif it.action == "quicklink" then
    askQuicklink(nil)
  elseif it.action == "prefix" then
    query, sel, note = it.prefix, 1, nil
    opens += 1 -- ui.input only takes a new value through a new key
    compute(); render()
  elseif it.confirm then
    askConfirm(it, it.confirm .. " now?", function() run(it, it.run) end)
  else
    run(it, it.run)
  end
end

local function openMenu()
  local it = shown[sel]
  if not it then return end
  current = it
  it.pinned = Rank.isPinned(it.id)
  it.aliasText = Rank.aliasOf(it.id)
  menu, menuSel, mode, note = Src.menu(it), 1, "menu", nil
  H.id = nil
  render()
end

local function runEntry(e)
  if not e or not current then return end
  if e.first then activate(current)
  elseif e.run then run(current, e.run)
  elseif e.op and OPS[e.op] then OPS[e.op](current, e) end
end

local function submitPrompt()
  if not prompt then return end
  local text = noctalia.string.trim(prompt.value or "")
  if text == "" and not prompt.allowEmpty then
    note = "Enter something first"
    render()
    return
  end
  local mine = prompt
  mine.submit(text, function(err, ok)
    if prompt ~= mine then return end
    if err then note = err; render() else backToList(ok) end
  end)
end

local function submit()
  local now = noctalia.nowMs()
  if now - lastSubmit < 200 then return end
  lastSubmit = now
  if mode == "list" then activate(shown[sel])
  elseif mode == "menu" then runEntry(menu[menuSel])
  elseif mode == "prompt" then submitPrompt()
  elseif mode == "confirm" then confirm.action()
  elseif mode == "icon" then Pick.enter()
  end
end

-- ── Drawing ─────────────────────────────────────────────────────────────────

local function lead(it, compact)
  if it.wallpaper then
    local w, h = if compact then 46 else 112, if compact then 26 else 63
    if it.preview then return ui.image({ path = it.preview, width = w, height = h, fit = "cover" }) end
    return ui.row({ width = w, height = h, fill = S.C.well, align = "center", justify = "center" }, { S.glyph("photo", { size = 18, color = S.C.dim }) })
  end
  if it.icon and it.icon ~= "" then return ui.image({ path = it.icon, width = 26, height = 26, fit = "contain" }) end
  if it.lead then
    return ui.row({ width = 26, height = 26, align = "center", justify = "center" }, { ui.label({ text = it.lead, fontSize = S.FS.emoji - 6 }) })
  end
  if it.glyph then
    return ui.row({ width = 26, height = 26, align = "center", justify = "center" }, { S.glyph(it.glyph, { size = 20 }) })
  end
  return ui.row({ width = 26, height = 26, fill = S.C.well, align = "center", justify = "center" }, {
    ui.label({ text = string.upper(string.sub(it.name, 1, 1)), fontFamily = S.mono, fontSize = S.FS.md, color = S.C.sub }),
  })
end

local function stateTag(it)
  if it.state == "on" then
    return ui.row({ paddingH = 5, height = 16, fill = S.C.text, align = "center" }, { S.caption("on", S.C.inv) })
  end
  if it.state == "off" then return S.caption("off") end
  return nil
end

local function row(i, it)
  local isSel = sel == i
  local kids = {
    lead(it),
    ui.column({ flexGrow = 1, gap = 1, justify = "center" }, {
      ui.label({ text = it.name, fontFamily = S.sans, fontSize = S.FS.body, color = if isSel then S.C.text else S.C.sub, maxWidth = 360, maxLines = 1 }),
      ui.label({ text = it.comment, fontFamily = S.sans, fontSize = S.FS.sm, color = S.C.dim, maxWidth = 360, maxLines = 1 }),
    }),
  }
  if it.keybind then table.insert(kids, S.caption(it.keybind)) end
  local tag = stateTag(it)
  if tag then table.insert(kids, tag) end
  if isSel then table.insert(kids, S.caption("↵")) end
  return S.item({
    key = "a-" .. it.id,
    height = if it.wallpaper then 76 else ROW_H,
    selected = isSel,
    hovered = H.id == i,
    onClick = function() sel = i; activate(it) end,
    onHover = H.fn(i),
  }, kids)
end

local function footer(left, hints)
  local kids = { S.caption(note or left), ui.spacer({ flexGrow = 1 }) }
  for _, h in hints do table.insert(kids, S.caption(h)) end
  return ui.row({ align = "center", gap = 14, height = 20 }, kids)
end

local function frame(top, body, foot)
  return ui.column({ gap = 8, flexGrow = 1, align = "stretch" }, { top, S.hline("h1"), body, S.hline("h2"), foot })
end

local function viewList()
  local rows = {}
  for i, it in shown do
    if heads[i] then
      table.insert(rows, ui.row({ key = "s-" .. heads[i], height = 26, paddingH = 10, align = "center" }, { S.caption(heads[i]) }))
    end
    table.insert(rows, row(i, it))
  end
  if #shown == 0 then
    local blank = noctalia.string.trim(query) == ""
    table.insert(rows, ui.column({ paddingV = 60, align = "center" }, { S.caption(if blank then "type to search everything" else "no matches") }))
  end
  local hints = { "↑↓ move", "↵ open" }
  if hasLocation(shown[sel]) then table.insert(hints, "ctrl ↵ location") end
  table.insert(hints, "ctrl k more")
  return frame(
    S.search({ key = "q-" .. opens, value = query, placeholder = "Search everything", count = #shown, onSubmit = submit,
      onChange = function(v)
        v = v or ""
        if v == query then return end
        query, sel, histPos, note = v, 1, nil, nil
        compute(); render()
      end }),
    ui.scroll({ key = "list", flexGrow = 1, gap = 0, revealKey = if follow and shown[sel] then "a-" .. shown[sel].id else nil }, rows),
    footer(if query == "" then "for you" else "search", hints))
end

local function viewMenu()
  local rows = {}
  for i, e in menu do
    table.insert(rows, S.item({ key = "m-" .. i, height = 38, selected = menuSel == i, hovered = H.id == -i,
      onClick = function() menuSel = i; runEntry(e) end, onHover = H.fn(-i) }, {
      ui.label({ text = e.label, fontFamily = S.sans, fontSize = S.FS.body, color = if menuSel == i then S.C.text else S.C.sub, flexGrow = 1 }),
      S.caption(e.hint),
    }))
  end
  return frame(
    ui.row({ align = "center", gap = 10, height = 34 }, { lead(current, true),
      ui.label({ text = current.name, fontFamily = S.sans, fontSize = S.FS.xl, color = S.C.text, maxWidth = 520, maxLines = 1 }) }),
    ui.scroll({ key = "menu", flexGrow = 1, gap = 0, revealKey = "m-" .. menuSel }, rows),
    footer("actions", { "↑↓ move", "↵ run", "ctrl k back" }))
end

local function viewPrompt()
  return frame(
    S.header("pencil", prompt.title),
    ui.column({ flexGrow = 1, gap = 14, paddingV = 10, align = "stretch" }, {
      ui.column({ gap = 6, align = "stretch" }, {
        S.caption(prompt.label),
        ui.row({ height = 40, paddingH = 10, fill = S.C.well, align = "center" }, {
          ui.input({ key = "p-" .. promptGen, value = prompt.value, placeholder = prompt.placeholder, frameVisible = false, focus = true,
            fontSize = S.FS.lg, controlSize = "sm", flexGrow = 1, onSubmit = submit,
            onChange = function(v) prompt.value = v or "" end }),
        }),
      }),
    }),
    footer("", { "↵ save", "ctrl k back" }))
end

local function viewIcon()
  return frame(
    ui.column({ gap = 8, align = "stretch" }, {
      ui.row({ align = "center", gap = 10, height = 34 }, { lead(current, true),
        ui.label({ text = "Icon for " .. current.name, fontFamily = S.sans, fontSize = S.FS.xl, color = S.C.text, maxWidth = 520, maxLines = 1 }) }),
      Pick.field(submit),
    }),
    Pick.body(),
    ui.row({ align = "center", gap = 14, height = 20 }, (function()
      local kids = { S.caption(Pick.note() or "images"), ui.spacer({ flexGrow = 1 }) }
      for _, h in Pick.hints() do table.insert(kids, S.caption(h)) end
      return kids
    end)()))
end

local function viewConfirm()
  return frame(
    ui.row({ align = "center", gap = 10, height = 34 }, { lead(current, true),
      ui.label({ text = current.name, fontFamily = S.sans, fontSize = S.FS.xl, color = S.C.text, maxWidth = 520, maxLines = 1 }) }),
    ui.column({ flexGrow = 1, align = "center", justify = "center" }, {
      ui.label({ text = confirm.text, fontFamily = S.sans, fontSize = S.FS.lg, color = S.C.text, maxWidth = 520, maxLines = 3 }),
    }),
    footer("", { "↵ yes", "ctrl k no" }))
end

function render()
  if mode == "form" then panel.render(W.view())
  elseif mode == "menu" then panel.render(viewMenu())
  elseif mode == "prompt" then panel.render(viewPrompt())
  elseif mode == "confirm" then panel.render(viewConfirm())
  elseif mode == "icon" then panel.render(viewIcon())
  else panel.render(viewList()) end
  follow = false
end

-- ── Keys ────────────────────────────────────────────────────────────────────

local function setQuery(text)
  query, sel, note = text, 1, nil
  opens += 1 -- ui.input only takes a new value through a new key
  compute(); render()
end

local function recall(older)
  local past = Rank.history()
  local pos = (histPos or 0) + (if older then 1 else -1)
  if pos < 1 or pos > #past then return false end
  histPos = pos
  setQuery(past[pos])
  return true
end

local function moveList(d)
  if d == -1 and sel == 1 and (query == "" or histPos) and recall(true) then return end
  if #shown == 0 then return end
  sel = S.step(sel, d, #shown)
  H.id = nil
  follow = true
  render()
end

local function move(d)
  if mode == "menu" then
    menuSel = S.step(menuSel, d, #menu)
    H.id = nil
    render()
  elseif mode == "list" then
    moveList(d)
  elseif mode == "icon" then
    Pick.move(d)
  end
end

local MOVES = { up = -1, ["shift+tab"] = -1, down = 1, tab = 1, page_up = -8, page_down = 8 }
local R = S.repeater(function(k) move(MOVES[k]) end, { "up", "down", "tab", "shift+tab", "page_up", "page_down" })
function onFrameTick(dt)
  if pendingCompute then
    pendingCompute = false
    local keep = if shown[sel] then shown[sel].id else nil -- results can shift under the selection
    compute()
    for i, it in shown do
      if it.id == keep then sel = i; break end
    end
    render()
    if not R.chord then panel.setNeedsFrameTick(false) end
  end
  R.tick(dt)
end

-- Jump to the next or previous section.
local function jump(d)
  local i = sel + d
  while i >= 1 and i <= #shown do
    if heads[i] then
      sel = i
      follow = true
      render()
      return
    end
    i += d
  end
end

local function copySelected()
  local it = shown[sel]
  local text = it and (it.copy or it.url or it.name)
  if not text then return end
  noctalia.copyToClipboard(text, "text/plain;charset=utf-8")
  note = "Copied"
  render()
end

local function pinSelected()
  local it = shown[sel]
  if it and it.pinnable then OPS.pin(it) end
end

function onKey(key, pressed)
  local k = string.lower(tostring(key))
  if mode == "form" then
    if pressed == false then return end
    if k == "ctrl+k" then
      W.cancel()
      backToList(nil)
    else
      W.key(k)
    end
    return
  end
  if mode == "icon" and pressed ~= false then
    if k == "tab" then Pick.complete(); return end
  end
  if (mode == "list" or mode == "menu" or mode == "icon") and R.key(key, pressed) then
    if pendingCompute then panel.setNeedsFrameTick(true) end
    return
  end
  if pressed == false then return end
  if k == "return" or k == "kp_enter" then submit()
  elseif k == "ctrl+k" then
    if mode == "list" then openMenu() else backToList(nil) end
  elseif mode ~= "list" then return
  elseif k == "ctrl+return" or k == "ctrl+kp_enter" then if shown[sel] then reveal(shown[sel]) end
  elseif k == "ctrl+shift+f" then pinSelected()
  elseif k == "ctrl+shift+c" then copySelected()
  elseif k == "ctrl+up" then jump(-1)
  elseif k == "ctrl+down" then jump(1)
  end
end

function onOpen(_context)
  R.stop()
  opens += 1
  query, sel, histPos, note = "", 1, nil, nil
  H.id = nil
  mode, current, prompt, confirm = "list", nil, nil, nil
  W.cancel()
  Pick.cancel()
  live.windows = nil -- window addresses go stale; never offer yesterday's
  pendingCompute = false
  readApps()
  rebuild()
  compute()
  scan() -- picks up newly installed apps
  gather()
  render()
end

Pick.init({ redraw = function() render() end })

W.init({
  redraw = function() render() end,
  exit = function() backToList(nil) end,
  rescan = function() scan() end,
  launch = function(id)
    panel.close()
    noctalia.runAsync(Src.helper("app", id))
  end,
})

Rank.load(dataDir)
live = readJson(livePath) or {}
live.windows = nil
readApps()
rebuild()
compute()
render()
