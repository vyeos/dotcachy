--!nonstrict
-- Workspaces: one shape per workspace, no numbers. The active workspace is a
-- wide bar, a workspace with windows a filled square, an empty one a hollow
-- square. Click a shape to switch, scroll to step through them. An engraved
-- divider closes the group.

local S = require("./style.luau")
S.fonts()

local list = S.read("graphite.ws") or {}
local active = S.read("graphite.wsActive") or 1
local H = S.hover(function() render() end)

local function minCount()
  local n = tonumber(noctalia.getConfig("min_workspaces")) or 5
  return math.clamp(math.floor(n), 1, 10)
end

-- Switch to a workspace; shared by clicks and the "select" IPC event.
function selectWorkspace(id)
  S.dispatch(`hl.dsp.focus(\{ workspace = {id} \})`)
  active = id
  render()
end

local function shape(isActive, occupied, isHover)
  if isActive then
    return ui.box({ width = 18, height = 6, radius = 0, fill = S.C.text })
  elseif occupied then
    return ui.box({ width = 6, height = 6, radius = 0, fill = if isHover then S.C.text else S.C.sub })
  end
  return ui.box({ width = 6, height = 6, radius = 0, fill = S.C.clear,
    border = if isHover then S.C.sub else S.C.dim, borderWidth = 1 })
end

local function cell(id, windows)
  local isActive = id == active
  local occupied = windows > 0
  local isHover = H.id == id and not isActive
  return ui.row({
    key = `ws-{id}`,
    height = S.KEY_H,
    paddingH = 5,
    radius = 0,
    fill = if isHover then S.C.keyHover else S.C.clear,
    align = "center",
    justify = "center",
    onHover = H.fn(id),
    onClick = function()
      selectWorkspace(id)
    end,
  }, { shape(isActive, occupied, isHover) })
end

function render()
  local byId = {}
  local maxId = minCount()
  for _, w in list do
    byId[w.id] = w.windows
    if w.id > maxId then maxId = w.id end
  end
  if active > maxId then maxId = active end
  local cells = {}
  for id = 1, maxId do
    table.insert(cells, cell(id, byId[id] or 0))
  end
  barWidget.render(ui.row({ gap = 0, align = "center" }, {
    ui.row({ gap = 1, align = "center" }, cells),
    S.divider("ws-div"),
  }))
end

function onScroll(axis, steps)
  if axis ~= "vertical" then return end
  local s = tonumber(steps) or 0
  if s == 0 then return end
  local rel = if s > 0 then "e+1" else "e-1"
  S.dispatch(`hl.dsp.focus(\{ workspace = "{rel}" \})`)
end

-- IPC: noctalia msg plugin vyeos/graphite:workspaces all select <n>
function onIpc(event, payload)
  if event == "select" then
    local n = tonumber(payload)
    if n then selectWorkspace(n) end
  end
end

S.watch("graphite.ws", function(v)
  list = v or {}
  render()
end)
S.watch("graphite.wsActive", function(v)
  if type(v) == "number" then active = v end
  render()
end)

render()
