--!nonstrict
-- GPU panel, attached under the GPU key: the graphics modes supergfxd supports.
--
-- A switch ends the session, so clicking a mode only selects it; the footer then
-- names the consequence and the button there runs it. supergfxd drops a switch
-- when no logout follows within 30 s (hardcoded in 5.2.7, logout_timeout_s is not
-- read), so the logout has to run right after the mode is set, not be left to the user.

local S = require("./style.luau")
S.fonts()

local MODES = {
  Integrated = { label = "Integrated", glyph = "leaf", desc = "AMD only, NVIDIA off" },
  Hybrid = { label = "Hybrid", glyph = "gauge", desc = "AMD by default, NVIDIA on demand" },
  AsusMuxDgpu = { label = "Dedicated", glyph = "rocket", desc = "NVIDIA only, through the MUX" },
}
local ORDER = { "Integrated", "Hybrid", "AsusMuxDgpu" }
local POWER = {
  active = "NVIDIA awake",
  suspended = "NVIDIA asleep",
  off = "NVIDIA off",
  asus_disabled = "NVIDIA off",
  asus_mux_discreet = "NVIDIA only",
}

local info = S.read("graphite.gpu") or {}
local supported = nil  -- set of mode names; nil until read
local armed = nil      -- mode waiting for confirmation
local busy = false
local err = ""
local H = S.hover(function() render() end)

local function needsReboot(from, to)
  return from == "AsusMuxDgpu" or to == "AsusMuxDgpu"
end

local function session(action)
  S.run({ "noctalia", "msg", "session", action })
end

local function fail(r)
  busy = false
  local msg = noctalia.string.trim((string.gsub(r.stderr or "", "\27%[[%d;]*m", "")))
  err = if msg ~= "" then (string.match(msg, "[^\n]+$") or msg) else "Switch failed. See journalctl -u supergfxd."
  render()
end

local function switch(mode)
  armed, busy, err = nil, true, ""
  render()
  noctalia.runAsync({ "supergfxctl", "-m", mode }, function(r)
    if r.exitCode ~= 0 or r.timedOut then return fail(r) end
    -- Trust what the daemon asks for rather than our own table.
    local out = string.lower(r.stdout or "")
    if string.find(out, "reboot", 1, true) then
      -- The MUX write runs in the background after the call returns.
      noctalia.runAsync({ "sleep", "2" }, function() session("reboot") end, 5000)
    elseif string.find(out, "logout", 1, true) then
      session("logout")
    else
      busy = false
      S.poke("gpu")
      render()
    end
  end, 15000)
end

local function modeRow(name)
  local m = MODES[name]
  local current = name == info.mode
  local selected = name == armed
  local waiting = name == info.pending
  return S.item({
    key = name,
    height = 46,
    hovered = H.id == name or selected,
    selected = current,
    onHover = H.fn(name),
    onClick = function()
      if busy then return end
      err = ""
      armed = if current or selected then nil else name
      render()
    end,
  }, {
    ui.glyph({ name = m.glyph, size = 16, color = if current or selected then S.C.text else S.C.sub }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = m.label, fontFamily = S.sans, fontSize = S.FS.body, color = if current or selected then S.C.text else S.C.body }),
      ui.label({ text = m.desc, fontFamily = S.sans, fontSize = S.FS.sm, color = S.C.dim, maxLines = 1 }),
    }),
    S.caption(
      if current then "in use" elseif waiting then "pending" elseif selected then "selected" else "",
      S.C.sub
    ),
  })
end

local function note(text, color)
  return ui.label({ text = text, fontFamily = S.sans, fontSize = S.FS.md, color = color or S.C.dim, flexGrow = 1, maxLines = 2 })
end

local function footer()
  local kids
  if busy then
    kids = { note("Switching…", S.C.sub) }
  elseif armed then
    local reboot = needsReboot(info.mode, armed)
    kids = {
      note(if reboot then "Reboots now. Apps will close." else "Logs you out. Apps will close.", S.C.text),
      ui.button({ key = "cancel", text = "Cancel", variant = "outline", onClick = function()
        armed = nil
        render()
      end }),
      ui.button({
        key = "go",
        text = if reboot then "Reboot" else "Log Out",
        glyph = if reboot then "refresh" else "logout",
        variant = "primary",
        onClick = function() switch(armed) end,
      }),
    }
  elseif MODES[info.pending or ""] then
    -- Started outside this panel (supergfxctl -m), still waiting for the session to end.
    local reboot = string.find(string.lower(info.action or ""), "reboot", 1, true) ~= nil
    kids = {
      note(`{MODES[info.pending].label} is waiting for you.`, S.C.text),
      ui.button({
        key = "finish",
        text = if reboot then "Reboot" else "Log Out",
        glyph = if reboot then "refresh" else "logout",
        variant = "primary",
        onClick = function() session(if reboot then "reboot" else "logout") end,
      }),
    }
  elseif err ~= "" then
    kids = { note(err, S.C.text) }
  elseif not info.mode then
    kids = { note("Can't reach supergfxd.", S.C.text) }
  else
    kids = { note("Switching closes your apps.") }
  end
  return ui.row({ key = "footer", height = 36, gap = 6, align = "center" }, kids)
end

function render()
  local rows = {}
  for _, name in ORDER do
    if not supported or supported[name] then table.insert(rows, modeRow(name)) end
  end
  local power = POWER[info.power or ""] or ""
  panel.render(ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, {
    S.header("cpu", "Graphics", { S.caption(power, S.C.sub) }),
    S.hline("h1"),
    ui.column({ gap = 1, align = "stretch" }, rows),
    S.hline("h2"),
    footer(),
  }))
end

S.watch("graphite.gpu", function(v)
  if type(v) == "table" then info = v end
  render()
end)

function onOpen(_context)
  armed, err = nil, ""
  S.poke("gpu")
  panel.setWantsSecondTicks(true)
  noctalia.runAsync({ "supergfxctl", "-s" }, function(r)
    if r.exitCode ~= 0 then return end
    local set = {}
    for name in string.gmatch(r.stdout or "", "%a+") do set[name] = true end
    supported = set
    render()
  end, 3000)
  render()
end

-- The service only reads supergfxctl when asked: every few seconds while this is open.
local POLL_SECS = 5
local tick = 0
function update()
  tick += 1
  if tick % POLL_SECS == 0 then S.poke("gpu") end
end

function onClose()
  panel.setWantsSecondTicks(false)
end

-- Test hook: `noctalia msg plugin vyeos/graphite:gpu-panel all arm <mode>` shows the
-- confirmation state. It only selects; nothing here can start a switch.
function onIpc(event, payload)
  if event == "arm" then
    armed = if MODES[payload or ""] and payload ~= info.mode then payload else nil
    render()
  end
end

render()
