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

local function apply(v)
  if type(v) ~= "table" then return end
  batt = v
  profiles = v.profiles or {}
  profile = v.profile or ""
  render()
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
      text = S.PROFILE_LABEL[name] or name,
      glyph = S.PROFILE_GLYPH[name] or "gauge",
      variant = if name == profile then "primary" else "outline",
      flexGrow = 1,
      onClick = function() S.svc("profile", name) end,
    }))
  end

  local body = {
    S.header(if charging then "bolt" else "battery-2", "Power", {}),
    S.hline("h1"),
    ui.row({ align = "end", gap = 14 }, {
      ui.label({ text = `{math.floor(batt.pct + 0.5)}%`, fontFamily = S.mono, fontSize = S.FS.big, color = S.C.text }),
      ui.column({ gap = 3, flexGrow = 1 }, {
        S.caption((string.gsub(batt.state, "%-", " ")), S.C.sub),
        ui.label({ text = table.concat(detail, " · "), fontFamily = S.mono, fontSize = S.FS.sm, color = S.C.dim }),
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
  panel.render(ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, body))
end

function onOpen(_context)
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
