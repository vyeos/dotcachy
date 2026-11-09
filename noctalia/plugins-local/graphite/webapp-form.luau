--!nonstrict
-- "Create Web App" form, shown inside the launcher panel: name, then link, then the
-- icon is fetched; only if that fails does it ask for one. webapp.py does the work.

local S = require("./style.luau")

local W = {}

local helper = (noctalia.pluginDir() or ".") .. "/webapp.py"

local cb = nil        -- { redraw, exit, rescan, launch }
local step = "name"   -- name | link | busy | icon | done
local name, link, iconInput = "", "", ""
local err = nil
local host = nil
local result = nil
local busyText = ""
local run = 0         -- a closed or restarted form ignores late helper replies
local lastSubmit = 0  -- Enter can reach both onKey and the input's onSubmit

function W.init(callbacks) cb = callbacks end

function W.start()
  run += 1
  step, name, link, iconInput, err, host, result = "name", "", "", "", nil, nil, nil
  lastSubmit = noctalia.nowMs()
end

function W.cancel() run += 1 end

local function create(icon)
  run += 1
  local mine = run
  local from = if icon then "icon" else "link"
  local argv = { "python3", helper, name, link }
  if icon then table.insert(argv, icon) end
  busyText = if icon then "Adding icon…" else "Looking for an icon…"
  step, err = "busy", nil
  cb.redraw()
  noctalia.runAsync(argv, function(r)
    if mine ~= run then
      cb.rescan() -- it may still have created the app
      return
    end
    local d = if r.exitCode == 0 then noctalia.json.decode(noctalia.string.trim(r.stdout or "")) else nil
    local status = if type(d) == "table" then d.status else nil
    if status == "ok" then
      result, step = d, "done"
      cb.rescan()
    elseif status == "no-icon" then
      host, step = d.host, "icon"
    elseif status == "bad-icon" then
      step, err = "icon", d.message
    elseif status == "exists" then
      step, err = "name", `"{d.name}" already exists, pick another name`
    elseif status == "bad-url" then
      step, err = "link", "That doesn't look like a web address"
    elseif status == "bad-name" then
      step, err = "name", "Enter a name"
    else
      step, err = from, if r.timedOut then "Timed out, try again" else "Something went wrong, try again"
    end
    cb.redraw()
  end, 40000)
end

local function submit()
  local now = noctalia.nowMs()
  if now - lastSubmit < 200 then return end
  lastSubmit = now
  if step == "name" then
    if noctalia.string.trim(name) == "" then err = "Enter a name"; cb.redraw(); return end
    step, err = "link", nil
    cb.redraw()
  elseif step == "link" then
    if noctalia.string.trim(link) == "" then err = "Enter a link"; cb.redraw(); return end
    create(nil)
  elseif step == "icon" then
    if noctalia.string.trim(iconInput) == "" then err = "Enter a path or an image link"; cb.redraw(); return end
    create(iconInput)
  elseif step == "done" then
    cb.launch(result.id)
  end
end

local function back()
  if step == "name" then cb.exit()
  elseif step == "link" then step, err = "name", nil; cb.redraw()
  elseif step == "icon" then step, err = "link", nil; cb.redraw()
  end
end

function W.key(k)
  if k == "return" or k == "kp_enter" then submit()
  elseif k == "up" then back()
  end
end

local function field(title, id, value, placeholder, onChange)
  return ui.column({ gap = 6, align = "stretch" }, {
    S.caption(title),
    ui.row({ height = 40, paddingH = 10, fill = S.C.well, align = "center" }, {
      ui.input({
        key = `{id}-{run}`,
        value = value,
        placeholder = placeholder,
        frameVisible = false,
        focus = true,
        fontSize = S.FS.lg,
        controlSize = "sm",
        flexGrow = 1,
        onChange = onChange,
        onSubmit = submit,
      }),
    }),
  })
end

local function given(title, value)
  return ui.row({ gap = 12, align = "center", height = 18 }, {
    ui.row({ width = 44 }, { S.caption(title) }),
    ui.label({ text = value, fontFamily = S.sans, fontSize = S.FS.body, color = S.C.sub, maxWidth = 500, maxLines = 1 }),
  })
end

local function body()
  local kids = {}
  if step == "name" then
    table.insert(kids, field("Name", "wa-name", name, "WhatsApp", function(v) name = v or "" end))
  elseif step == "link" then
    table.insert(kids, given("Name", name))
    table.insert(kids, field("Link", "wa-link", link, "web.whatsapp.com", function(v) link = v or "" end))
  elseif step == "busy" then
    table.insert(kids, S.placeholder("world-download", busyText, { height = 260 }))
  elseif step == "icon" then
    table.insert(kids, given("Name", name))
    table.insert(kids, given("Link", link))
    table.insert(kids, ui.label({ text = `Couldn't find an icon for {host or "this site"}.`, fontFamily = S.sans, fontSize = S.FS.body, color = S.C.text }))
    table.insert(kids, field("Icon", "wa-icon", iconInput, "~/Pictures/icon.png or https://…/icon.png", function(v) iconInput = v or "" end))
  elseif step == "done" then
    table.insert(kids, ui.column({ height = 260, align = "center", justify = "center", gap = 12 }, {
      ui.image({ path = result.icon, width = 64, height = 64, fit = "contain" }),
      ui.label({ text = result.name, fontFamily = S.sans, fontSize = S.FS.title, color = S.C.text, maxWidth = 500, maxLines = 1 }),
      S.caption("added to your apps"),
    }))
  end
  if err then table.insert(kids, S.status(err)) end
  return kids
end

local function hints()
  local kids = { ui.spacer({ flexGrow = 1 }) }
  if step == "done" then
    table.insert(kids, S.caption("↵ open"))
  elseif step ~= "busy" then
    table.insert(kids, S.caption("↑ back"))
    table.insert(kids, S.caption(if step == "name" then "↵ next" else "↵ create"))
  end
  table.insert(kids, S.caption("esc close"))
  return kids
end

function W.view()
  return ui.column({ gap = 8, flexGrow = 1, align = "stretch" }, {
    S.header("world", "New Web App"),
    S.hline("wa-h1"),
    ui.column({ flexGrow = 1, gap = 14, paddingV = 10, align = "stretch" }, body()),
    S.hline("wa-h2"),
    ui.row({ align = "center", gap = 14, height = 20 }, hints()),
  })
end

return W
