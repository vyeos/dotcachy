--!nonstrict
-- Tasks drawer: a chevron key showing how many watched apps are running (and a
-- breathing dot while OBS is recording). Hovering slides the drawer open one key at a
-- time; leaving closes it 0.6s later. Click a task to focus its window.

local S = require("./style.luau")
S.fonts()

local CLOSE_DELAY_MS = 600
local STEP_MS = 55

local tasks = S.read("graphite.tasks") or {}
local rec = S.read("graphite.rec") or { recording = false }
local open = false
local shown = 0          -- drawer keys currently revealed
local closeAt = nil      -- nowMs when a pending close fires
local hoveredKey = nil
local fast = false

-- Timers are only on screen while the drawer is open or OBS records; otherwise sleep.
local function live()
  return shown > 0 or rec.recording == true
end

local function applyInterval()
  noctalia.setUpdateInterval(if fast then STEP_MS elseif live() then 1000 else 60000)
end

local function setFast(on)
  if on ~= fast then
    fast = on
    applyInterval()
  end
end

local function elapsed(startedMs)
  local secs = math.max(0, math.floor((noctalia.nowMs() - startedMs) / 1000))
  local h = secs // 3600
  local m = (secs // 60) % 60
  local s = secs % 60
  if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
  return string.format("%d:%02d", m, s)
end

-- Entering any key (chevron or drawer) opens the drawer and cancels a pending
-- close; leaving one schedules the close. Moving between keys re-enters before
-- the delay runs out, so the drawer stays open while the pointer is on it.
local function hoverFn(id)
  return function(state)
    if state == "true" then
      hoveredKey = id
      open = true
      closeAt = nil
    else
      if hoveredKey == id then hoveredKey = nil end
      closeAt = noctalia.nowMs() + CLOSE_DELAY_MS
    end
    setFast(true)
    render()
  end
end

local function taskKey(t)
  local recNow = t.rec and rec.recording == true
  local timeText = if recNow then "REC " .. elapsed(rec.startedMs) else elapsed(t.startedMs)
  return S.key({
    key = "task-" .. t.id,
    hovered = hoveredKey == t.id,
    onHover = hoverFn(t.id),
    onClick = function()
      local sel = `class:(?i)^{t.cls}$`
      S.dispatch(`hl.dsp.focus(\{ window = {S.lstr(sel)} \})`)
    end,
  }, {
    S.glyph(t.glyph, { color = S.C.sub }),
    S.label(t.label, { color = S.C.text }),
    S.label(timeText, { font = S.mono, size = S.FS.sm, color = if recNow then S.C.text else S.C.dim }),
  })
end

local function recording()
  return rec.recording == true
end

function render()
  local children = {}
  local total = #tasks

  if total == 0 and shown > 0 then
    table.insert(children, S.key({ key = "task-none" }, {
      S.label("Nothing running", { color = S.C.dim }),
    }))
  else
    -- reveal from the chevron outwards: the key nearest the chevron appears first
    for i = math.max(1, total - shown + 1), total do
      table.insert(children, taskKey(tasks[i]))
    end
  end

  local chevronKids = {}
  if total > 0 then
    table.insert(chevronKids, S.label(tostring(total), { font = S.mono, size = S.FS.sm, color = S.C.sub }))
  end
  if recording() then
    local pulse = (os.time() % 2) == 0
    table.insert(chevronKids, ui.box({ width = 6, height = 6, radius = 0, fill = S.C.text, opacity = if pulse then 1 else 0.3 }))
  end
  table.insert(chevronKids, S.glyph(if open then "chevron-right" else "chevron-left", { size = 15, color = if total > 0 then S.C.sub else S.C.dim }))

  table.insert(children, S.key({
    key = "chevron",
    hovered = hoveredKey == "chevron" or open,
    paddingH = 8,
    gap = 6,
    onHover = hoverFn("chevron"),
    onClick = function()
      open = not open
      closeAt = nil
      setFast(true)
      render()
    end,
  }, chevronKids))

  table.insert(children, S.divider("tasks-div"))
  barWidget.render(ui.row({ gap = 0, align = "center" }, children))
end

-- Pointer over any part of the widget (drawer or chevron).
function onHover(entered)
  if entered then
    open = true
    closeAt = nil
  else
    closeAt = noctalia.nowMs() + CLOSE_DELAY_MS
    hoveredKey = nil
  end
  setFast(true)
  render()
end

function update()
  local draw = fast or live() -- decided first: the step that ends the animation still draws
  local now = noctalia.nowMs()
  if closeAt and now >= closeAt then
    open = false
    closeAt = nil
  end
  local target = if open then math.max(#tasks, 1) else 0
  if shown < target then
    shown += 1
  elseif shown > target then
    shown -= 1
  end
  if shown == target and closeAt == nil then
    setFast(false)
    applyInterval()
  end
  if draw then render() end
end

S.watch("graphite.rec", function(v)
  rec = if type(v) == "table" then v else { recording = false }
  applyInterval()
  render()
end)

S.watch("graphite.tasks", function(v)
  tasks = if type(v) == "table" then v else {}
  if open then
    shown = math.min(shown, math.max(#tasks, 1))
  end
  render()
end)

applyInterval()
render()

-- IPC: noctalia msg plugin vyeos/graphite:tasks all drawer open|close|toggle
-- (handy for a keybind). An IPC-opened drawer stays open until closed again.
function onIpc(event, payload)
  -- hover on|off runs the same path as the pointer entering / leaving the widget
  if event == "hover" then
    onHover(payload == "on")
    return
  end
  if event ~= "drawer" then return end
  local want = if payload == "open" then true elseif payload == "close" then false else not open
  open = want
  closeAt = nil
  setFast(true)
  render()
end
