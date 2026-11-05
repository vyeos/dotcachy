--!nonstrict
-- Session panel (SUPER + Escape): the five session actions as a row of flat
-- square tiles, each with its number key in an inverted corner badge.
-- 1-5 or click picks an action. Lock and Sleep run at once; Log Out, Reboot and
-- Shut Down arm first and run on Enter or a click on the armed tile (however it
-- was armed). Left/Right move the selection
-- (and disarm), Enter runs the selected/armed action, Escape closes.

local S = require("./style.luau")
S.fonts()

local ACTIONS = {
  { id = "lock", label = "Lock", glyph = "lock" },
  { id = "lock-and-suspend", label = "Sleep", glyph = "zzz" },
  { id = "logout", label = "Log Out", glyph = "logout", confirm = true },
  { id = "reboot", label = "Reboot", glyph = "refresh", confirm = true },
  { id = "shutdown", label = "Shut Down", glyph = "power", confirm = true },
}

local selected = nil -- index picked with the keyboard
local hovered = nil
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
  S.run({ "noctalia", "msg", "session", a.id })
end

local function tile(i, a)
  local isArmed = armed == i
  local lit = isArmed or selected == i
  local ink = if isArmed then "surface" else (if lit then S.C.text else S.C.sub)
  local badge = ui.row({
    width = 16, height = 16, radius = 0, align = "center", justify = "center",
    fill = if isArmed then "surface" else S.C.well,
  }, {
    ui.label({ text = tostring(i), fontFamily = S.mono, fontSize = 10, color = if isArmed then S.C.text else S.C.sub }),
  })
  return ui.column({
    key = "t-" .. a.id,
    width = 132,
    height = 104,
    radius = 0,
    padding = 6,
    gap = 0,
    fill = if isArmed then S.C.text elseif lit or hovered == i then S.C.keyHover else S.C.key,
    align = "stretch",
    onClick = function() run(i, "mouse") end,
    onHover = function(st)
      hovered = if st == "true" then i elseif hovered == i then nil else hovered
      render()
    end,
  }, {
    ui.row({ align = "center" }, { ui.spacer({ flexGrow = 1 }), badge }),
    ui.column({ flexGrow = 1, gap = 8, align = "center", justify = "center" }, {
      ui.glyph({ name = a.glyph, size = 22, color = ink }),
      ui.label({ text = if not isArmed then a.label elseif armedBy == "mouse" then "Click again" else "Press Enter",
        fontFamily = S.sans, fontSize = 13, color = ink }),
    }),
    ui.row({ height = 16, align = "center", justify = "center" }, {
      ui.label({ text = if not isArmed then "" elseif armedBy == "mouse" then "or press Enter" else "or click",
        fontFamily = S.mono, fontSize = 10.5, color = "surface/0.7" }),
    }),
  })
end

function render()
  local row = {}
  for i, a in ACTIONS do table.insert(row, tile(i, a)) end
  panel.render(ui.row({ gap = 6, align = "center", justify = "center", flexGrow = 1 }, row))
end

function onKey(key, ...)
  -- onKey fires for press (true) and release (false); act on presses only,
  -- or one tap moves two tiles and Enter would arm on press and run on release.
  local pressed = ...
  if pressed == false then return end
  local k = string.lower(tostring(key))
  local n = tonumber(k)
  if n and ACTIONS[n] then
    run(n, "key")
  elseif k == "left" or k == "h" then
    selected = math.max(1, (selected or 2) - 1); armed = nil; hovered = nil; render()
  elseif k == "right" or k == "l" or k == "tab" then
    selected = math.min(#ACTIONS, (selected or 0) + 1); armed = nil; hovered = nil; render()
  elseif k == "return" or k == "enter" or k == "kp_enter" then
    local i = armed or selected
    if i then
      run(i, if armed == i or not ACTIONS[i].confirm then "enter" else "key")
    end
  elseif k == "escape" then
    panel.close()
  end
end

function onOpen(_context)
  selected = nil
  hovered = nil
  armed = nil
  armedBy = nil
  render()
end

render()
