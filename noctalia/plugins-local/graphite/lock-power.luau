--!nonstrict
-- Lock screen power row: flat keys in the session panel's language. Sleep runs
-- at once; Log Out, Reboot and Shut Down arm on the first click (the key inverts
-- and asks) and run on a second click within ARM_SECS.
-- State stays in this script: changing a lock widget's settings while locked
-- segfaults Noctalia 5.4.1 (LockscreenWidgetsHost::syncSurfaces).

local S = require("./style.luau")
S.fonts()

local ACTIONS = {
  { id = "suspend", label = "Sleep", glyph = "zzz" },
  { id = "logout", label = "Log Out", glyph = "logout", confirm = true },
  { id = "reboot", label = "Reboot", glyph = "refresh", confirm = true },
  { id = "shutdown", label = "Shut Down", glyph = "power", confirm = true },
}

local ARM_SECS = 4
local IDLE_MS = 60000
local ARMED_MS = 200

local H = S.hover(function() render() end)
local armed = nil
local armedAt = 0

local function setArmed(i)
  armed = i
  armedAt = noctalia.nowMs()
  noctalia.setUpdateInterval(if i then ARMED_MS else IDLE_MS)
end

local function press(i)
  local a = ACTIONS[i]
  if a.confirm and armed ~= i then
    setArmed(i)
  else
    setArmed(nil)
    S.run({ "noctalia", "msg", "session", a.id })
  end
  render()
end

local function key(i, a)
  local isArmed = armed == i
  local ink = if isArmed then S.C.inv elseif H.id == i then S.C.text else S.C.sub
  return ui.row({
    key = "k-" .. a.id,
    width = 112,
    height = S.KEY_H,
    radius = 0,
    gap = 7,
    align = "center",
    justify = "center",
    fill = if isArmed then S.C.text elseif H.id == i then S.C.keyHover else S.C.clear,
    onClick = function() press(i) end,
    onHover = H.fn(i),
  }, {
    ui.glyph({ name = a.glyph, size = 15, color = ink }),
    ui.label({ text = if isArmed then a.label .. "?" else a.label, fontFamily = S.sans, fontSize = S.FS.body, color = ink }),
  })
end

function render()
  local row = {}
  for i, a in ACTIONS do
    table.insert(row, key(i, a))
    if i < #ACTIONS then table.insert(row, S.divider("d-" .. i)) end
  end
  desktopWidget.render(ui.row({ gap = 0, align = "center" }, row))
end

function update()
  if armed and noctalia.nowMs() - armedAt >= ARM_SECS * 1000 then
    setArmed(nil)
    render()
  end
end

noctalia.setUpdateInterval(IDLE_MS)
render()
