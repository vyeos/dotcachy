--!nonstrict
-- Right-click menu for a task in the tasks drawer: what the app itself offers, from
-- its tray menu and the actions in its .desktop file. tasks.luau fetches them with
-- bin/graphite task-menu, publishes them as graphite.taskMenu and opens the panel width
-- that fits; clearing that key on close lets the drawer collapse again.

local S = require("./style.luau")
S.fonts()

local BIN = (noctalia.pluginDir() or ".") .. "/bin/graphite"
local ROW_H = 32
local MAX_ROWS = 13 -- more than this scrolls; the panel stops at max_height

local task = nil
local menu = nil
local H = S.hover(function() render() end)

local function choose(argv)
  S.run(argv)
  panel.close()
end

local function row(key, label, o, onClick)
  local enabled = onClick ~= nil
  local mark = if o.checked then S.glyph("check", { size = 14, color = S.C.text }) else ui.box({ width = 14, height = 14, fill = S.C.clear })
  local kids = {}
  if o.marks then table.insert(kids, mark) end
  table.insert(kids, S.label(label, { color = if enabled then S.C.text else S.C.dim, maxWidth = 240 }))
  return S.item({
    key = key,
    height = ROW_H,
    hovered = enabled and H.id == key,
    onHover = if enabled then H.fn(key) else nil,
    onClick = onClick,
  }, kids)
end

local function hasToggles(items)
  for _, it in items do
    if it.toggle and it.toggle ~= "" then return true end
  end
  return false
end

local function menuRows()
  local rows = {}
  for _, a in menu.actions or {} do
    table.insert(rows, row("act-" .. a.name, a.label, {}, function()
      choose({ BIN, "task-action", menu.desktop, a.name })
    end))
  end
  local items = menu.items or {}
  if #rows > 0 and #items > 0 then table.insert(rows, S.hline("actions-end")) end
  local marks = hasToggles(items)
  for i, it in items do
    if it.kind == "sep" then
      table.insert(rows, S.hline("sep-" .. i))
    elseif it.kind == "header" then
      table.insert(rows, ui.row({ key = "head-" .. i, height = 26, paddingH = 10, align = "center" }, { S.caption(it.label) }))
    else
      local click = if it.enabled then function()
        choose({ BIN, "task-menu-click", menu.service, menu.path, tostring(it.id) })
      end else nil
      table.insert(rows, row("item-" .. i, it.label, { marks = marks, checked = it.checked }, click))
    end
  end
  return rows
end

function render()
  if not task then
    panel.render(ui.column({}, {}))
    return
  end
  local rows = menuRows()
  local body
  if #rows == 0 then
    body = S.label("No extra options", { color = S.C.dim })
  elseif #rows > MAX_ROWS then
    body = ui.scroll({ key = "rows", height = MAX_ROWS * ROW_H, gap = 0 }, rows)
  else
    body = ui.column({ key = "rows", gap = 0, align = "stretch" }, rows)
  end
  panel.render(ui.column({ gap = 8, align = "stretch" }, {
    S.header(task.glyph, task.label, {}),
    S.hline("title-end"),
    body,
  }))
end

function onOpen(_context)
  local want = S.read("graphite.taskMenu")
  task = if type(want) == "table" and want.id then want else nil
  menu = if task then task.menu or {} else nil
  H.id = nil
  render()
end

-- Switching straight to another task's menu has already replaced the key.
function onClose()
  local now = S.read("graphite.taskMenu")
  if type(now) == "table" and task and now.nonce == task.nonce then
    noctalia.state.set("graphite.taskMenu", "")
  end
end

render()
