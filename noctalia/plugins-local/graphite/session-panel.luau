--!nonstrict
-- Session panel (SUPER + Escape): the six session actions as a row of flat
-- square tiles, each with its number key in an inverted corner badge.
-- 1-6 or click picks an action. Lock and Sleep run at once; Log Out, Reboot,
-- Windows and Shut Down arm first and run on Enter or a click on the armed tile (however it
-- was armed). Left/Right move the selection (and disarm), wrapping at the ends and
-- repeating while held. Enter runs the selected/armed action, Escape closes.

local S = require("./style.luau")
S.fonts()

local ACTIONS = {
  { id = "lock", label = "Lock", glyph = "lock" },
  { id = "lock-and-suspend", label = "Sleep", glyph = "zzz" },
  { id = "logout", label = "Log Out", glyph = "logout", confirm = true },
  { id = "reboot", label = "Reboot", glyph = "refresh", confirm = true },
  -- one-shot boot into Windows (see noctalia/bin/windows-bootnext), then a normal reboot
  { id = "windows", label = "Windows", glyph = "brand-windows", confirm = true },
  { id = "shutdown", label = "Shut Down", glyph = "power", confirm = true },
}

local selected = nil -- index picked with the keyboard
local H = S.hover(function() render() end)
local armed = nil    -- index waiting for Enter or a second click
local armedBy = nil  -- "mouse" | "key": decides the prompt

-- how: "mouse" (click), "key" (number key) or "enter". Confirm-actions only
-- arm on the first pick; Enter or a click on the armed tile runs them.
local function run(i, how)
  local a = ACTIONS[i]
  if not a then return end
  local confirmed = armed == i and (how == "enter" or how == "mouse")
  if a.confirm and not confirmed then
    armed = i
    armedBy = if how == "mouse" then "mouse" else "key"
    selected = i
    render()
    return
  end
  armed = nil
  panel.close()
  if a.id == "windows" then
    S.run(S.REBOOT_WINDOWS)
    return
  end
  S.run({ "noctalia", "msg", "session", a.id })
end

local function tile(i, a)
  local isArmed = armed == i
  local lit = isArmed or selected == i
  local ink = if isArmed then S.C.inv else (if lit then S.C.text else S.C.sub)
  local badge = ui.row({
    width = 16, height = 16, radius = 0, align = "center", justify = "center",
    fill = if isArmed then S.C.inv else S.C.well,
  }, {
    ui.label({ text = tostring(i), fontFamily = S.mono, fontSize = S.FS.xs, color = if isArmed then S.C.text else S.C.sub }),
  })
  return ui.column({
    key = "t-" .. a.id,
    width = 132,
    height = 104,
    radius = 0,
    padding = 6,
    gap = 0,
    fill = if isArmed then S.C.text elseif lit or H.id == i then S.C.keyHover else S.C.key,
    align = "stretch",
    onClick = function() run(i, "mouse") end,
    onHover = H.fn(i),
  }, {
    ui.row({ align = "center" }, { ui.spacer({ flexGrow = 1 }), badge }),
    ui.column({ flexGrow = 1, gap = 8, align = "center", justify = "center" }, {
      ui.glyph({ name = a.glyph, size = 22, color = ink }),
      ui.label({ text = if not isArmed then a.label elseif armedBy == "mouse" then "Click again" else "Press Enter",
        fontFamily = S.sans, fontSize = S.FS.body, color = ink }),
    }),
    ui.row({ height = 16, align = "center", justify = "center" }, {
      ui.label({ text = if not isArmed then "" elseif armedBy == "mouse" then "or press Enter" else "or click",
        fontFamily = S.mono, fontSize = S.FS.xs, color = S.C.invDim }),
    }),
  })
end

function render()
  local row = {}
  for i, a in ACTIONS do table.insert(row, tile(i, a)) end
  panel.render(ui.row({ gap = 6, align = "center", justify = "center", flexGrow = 1 }, row))
end

local MOVES = { left = -1, h = -1, ["shift+tab"] = -1, right = 1, l = 1, tab = 1 }
local R = S.repeater(function(k)
  local d = MOVES[k]
  if selected then
    selected = S.step(selected, d, #ACTIONS)
  else
    selected = if d > 0 then 1 else #ACTIONS
  end
  armed = nil
  H.id = nil
  render()
end, { "left", "h", "shift+tab", "right", "l", "tab" })
function onFrameTick(dt) R.tick(dt) end

function onKey(key, pressed)
  if R.key(key, pressed) then return end
  -- onKey fires for press (true) and release (false); act on presses only,
  -- or Enter would arm on press and run on release.
  if pressed == false then return end
  local k = string.lower(tostring(key))
  local n = tonumber(k)
  if n and ACTIONS[n] then
    run(n, "key")
  elseif k == "return" or k == "enter" or k == "kp_enter" then
    local i = armed or selected
    if i then
      run(i, if armed == i or not ACTIONS[i].confirm then "enter" else "key")
    end
  elseif k == "escape" then
    panel.close()
  end
end

-- Dim the rest of the screen while the panel is up (a Hyprland layer rule from
-- windowrules.lua; it's off unless we turn it on).
local function dim(on)
  S.run({ "hyprctl", "eval", `if GRAPHITE_PANEL_DIM then GRAPHITE_PANEL_DIM:set_enabled({on}) end` })
end

function onClose()
  R.stop()
  dim(false)
end

function onOpen(_context)
  dim(true)
  R.stop()
  selected = nil
  H.id = nil
  armed = nil
  armedBy = nil
  render()
end

render()
