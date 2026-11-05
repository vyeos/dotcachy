--!nonstrict
-- Power panel, attached under the battery key. Battery readout (charge, time
-- left, draw, health) and the power profile switcher. Session actions live in
-- the session panel (SUPER + Escape).

local S = require("./style.luau")
S.fonts()

-- The service keeps graphite.power current, so this has real values at once.
local info = S.read("graphite.power")
local batt = if type(info) == "table" then info else { pct = 0, state = "unknown", timeLeft = "", rate = "", health = "" }
local profiles = batt.profiles or {}
local profile = batt.profile or ""
local status = ""

local PROFILE_LABEL = { ["power-saver"] = "Saver", balanced = "Balanced", performance = "Performance" }
local PROFILE_GLYPH = { ["power-saver"] = "leaf", balanced = "gauge", performance = "rocket" }

local function apply(v)
  if type(v) ~= "table" then return end
  batt = v
  profiles = v.profiles or {}
  profile = v.profile or ""
  render()
end

local function setProfile(name)
  profile = name
  render()
  S.exec({ "powerprofilesctl", "set", name }, 6000, function(ok, msg)
    status = if ok then "" else msg
    if ok then
      S.poke("power")
      render()
    else
      apply(S.read("graphite.power"))  -- undo the optimistic highlight
    end
  end)
end

function render()
  local charging = batt.state == "charging" or batt.state == "fully-charged"
  local detail = {}
  if batt.timeLeft ~= "" then table.insert(detail, batt.timeLeft) end
  if batt.rate ~= "" then table.insert(detail, batt.rate) end

  local profileRow = {}
  for _, name in profiles do
    table.insert(profileRow, ui.button({
      key = "p-" .. name,
      text = PROFILE_LABEL[name] or name,
      glyph = PROFILE_GLYPH[name] or "gauge",
      variant = if name == profile then "primary" else "outline",
      flexGrow = 1,
      onClick = function() setProfile(name) end,
    }))
  end

  local body = {
    S.header(if charging then "bolt" else "battery-2", "Power", {}),
    S.hline("h1"),
    ui.row({ align = "end", gap = 14 }, {
      ui.label({ text = `{math.floor(batt.pct + 0.5)}%`, fontFamily = S.mono, fontSize = 34, color = S.C.text }),
      ui.column({ gap = 3, flexGrow = 1 }, {
        S.caption((string.gsub(batt.state, "%-", " ")), S.C.sub),
        ui.label({ text = table.concat(detail, " · "), fontFamily = S.mono, fontSize = 11, color = S.C.dim }),
      }),
    }),
    ui.progress({ height = 4, progress = batt.pct / 100, radius = 0, fill = S.C.text, track = S.C.well }),
    ui.row({ align = "center" }, {
      S.caption(batt.health),
    }),
  }
  if #profiles > 0 then
    table.insert(body, S.hline("h2"))
    table.insert(body, S.caption("Power profile"))
    table.insert(body, ui.row({ gap = 6 }, profileRow))
  end
  if status ~= "" then
    table.insert(body, ui.label({ text = status, fontFamily = S.mono, fontSize = 11, color = S.C.sub, maxLines = 2 }))
  end
  panel.render(ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, body))
end

function onOpen(_context)
  status = ""
  apply(S.read("graphite.power"))
  S.poke("power")
  panel.setWantsSecondTicks(true)
end

local tick = 0
function update()
  tick += 1
  if tick % 10 == 0 then S.poke("power") end
end

function onClose()
  panel.setWantsSecondTicks(false)
end

S.watch("graphite.power", apply)

render()
