--!nonstrict
-- Records a keybind for a launcher result: press the shortcut, Enter saves it.
-- The launcher publishes the result as graphite.bindTarget and opens this panel.
-- Chords arrive over IPC from Hyprland's graphite-record submap, see
-- hypr/config/bind_recorder.lua; bin/graphite bind-record enters and leaves it.

local S = require("./style.luau")
S.fonts()

local BIN = (noctalia.pluginDir() or ".") .. "/bin/graphite"
local CLOSE_AFTER_SAVE_MS = 700

local ERRORS = {
  ["bad-combo"] = "Use a modifier and one key",
  rejected = "Hyprland refused that keybind",
  ["not-editable"] = "This shortcut is part of a group, change it in binds.lua",
}

local target = nil -- { id, name, keybind, run }
local isOpen = false
local chord = nil  -- "SUPER+SHIFT+G", the last chord pressed
local note = nil
local busy = false
local saved = false
local closeIn = 0
local H = S.hover(function() render() end)

local function record(action)
  noctalia.runAsync({ BIN, "bind-record", action })
end

local function finish(message)
  record("stop") -- the bind is saved, so shortcuts can run again right away
  saved, note = true, message
  closeIn = CLOSE_AFTER_SAVE_MS
  panel.setNeedsFrameTick(true)
  render()
end

local function save(comboText)
  if busy or saved or not target then return end
  busy, note = true, nil
  render()
  local argv = { BIN, "bind", target.id, target.name, comboText }
  for _, a in target.run or {} do table.insert(argv, a) end
  noctalia.runAsync(argv, function(r)
    busy = false
    if not isOpen then return end
    local d = if r.exitCode == 0 then noctalia.json.decode(noctalia.string.trim(r.stdout or "")) else nil
    local status = if type(d) == "table" then d.status else "failed"
    if status == "ok" then
      finish("Saved")
    elseif status == "removed" then
      chord = nil
      finish("Keybind removed")
    elseif status == "taken" then
      note = `Already used by {d.by}`
      render()
    else
      note = ERRORS[status] or "Couldn't save that keybind"
      record("start") -- a refused bind reloads Hyprland, which can leave the submap
      render()
    end
  end, 20000)
end

local function saveChord()
  if chord then save(chord) end
end

local function removeBind()
  if target and target.keybind then save("") end
end

local function keycap(text, key)
  return ui.row({ key = key, height = 42, minWidth = 42, paddingH = 12, radius = 0, fill = S.C.key, align = "center", justify = "center" }, {
    ui.label({ text = text, fontFamily = S.mono, fontSize = S.FS.lg, color = S.C.text }),
  })
end

local function capsRow()
  local kids = {}
  for part in string.gmatch(chord, "[^+]+") do
    if #kids > 0 then table.insert(kids, S.caption("+")) end
    table.insert(kids, keycap(if part == "CONTROL" then "CTRL" else part, "cap-" .. #kids))
  end
  return ui.row({ height = 42, gap = 8, align = "center", justify = "center" }, kids)
end

local function display()
  if chord then return capsRow() end
  return ui.row({ height = 42, align = "center", justify = "center" }, {
    ui.label({ text = "Press the new shortcut", fontFamily = S.sans, fontSize = S.FS.xl, color = S.C.sub }),
  })
end

local function statusLine()
  if busy then return S.caption("saving") end
  if note then return S.caption(note, S.C.text) end
  if target and target.keybind then return S.caption("current  " .. target.keybind) end
  return S.caption("hold modifiers, then press a key")
end

local function button(id, text, enabled, onClick)
  return S.key({ key = id, height = 26, hovered = enabled and H.id == id, onHover = if enabled then H.fn(id) else nil, onClick = if enabled then onClick else nil }, {
    S.caption(text, if enabled then S.C.sub else S.C.faint),
  })
end

function render()
  local foot = {}
  if target and target.keybind and not saved then
    table.insert(foot, button("remove", "del remove", not busy, removeBind))
  end
  table.insert(foot, ui.spacer({ flexGrow = 1 }))
  table.insert(foot, button("cancel", "esc cancel", true, function() panel.close() end))
  table.insert(foot, button("save", "↵ save", chord ~= nil and not busy and not saved, saveChord))
  panel.render(ui.column({ gap = 8, flexGrow = 1, align = "stretch" }, {
    S.header("keyboard", if target then target.name else "Keybind"),
    S.hline("h1"),
    ui.column({ flexGrow = 1, gap = 12, align = "center", justify = "center" }, { display(), statusLine() }),
    S.hline("h2"),
    ui.row({ height = 28, align = "center", gap = 6 }, foot),
  }))
end

function onFrameTick(dt)
  closeIn -= (tonumber(dt) or 16)
  if closeIn <= 0 then
    panel.setNeedsFrameTick(false)
    panel.close()
  end
end

function onKey(key, pressed)
  if pressed == false then return end
  local k = string.lower(tostring(key))
  if k == "return" or k == "kp_enter" then saveChord()
  elseif k == "delete" then removeBind()
  end
end

function onIpc(event, payload)
  if not isOpen then return end
  if event == "chord" and payload and not busy and not saved then
    chord, note = tostring(payload), nil
    render()
  elseif event == "expired" then
    panel.close()
  end
end

function onOpen(_context)
  target = S.read("graphite.bindTarget")
  isOpen, chord, note, busy, saved = true, nil, nil, false, false
  H.id = nil
  panel.setNeedsFrameTick(false)
  record("start")
  render()
end

function onClose()
  isOpen = false
  panel.setNeedsFrameTick(false)
  record("stop")
end

render()
