--!nonstrict
-- Current window: app glyph and title on a key. The tooltip carries the full title.

local S = require("./style.luau")
S.fonts()

local win = S.read("graphite.win") or { cls = "", title = "" }
local hovered = false

local GLYPHS = {
  { "kitty", "terminal-2" }, { "alacritty", "terminal-2" }, { "foot", "terminal-2" },
  { "wezterm", "terminal-2" }, { "ghostty", "terminal-2" }, { "konsole", "terminal-2" },
  { "firefox", "brand-firefox" }, { "zen", "world" }, { "chrom", "brand-chrome" },
  { "brave", "world" }, { "code", "brand-vscode" }, { "steam", "brand-steam" },
  { "discord", "brand-discord" }, { "vesktop", "brand-discord" }, { "spotify", "brand-spotify" },
  { "telegram", "brand-telegram" }, { "nautilus", "folder" }, { "thunar", "folder" },
  { "dolphin", "folder" }, { "nemo", "folder" }, { "obs", "player-record" },
  { "blender", "brand-blender" }, { "mpv", "video" },
}

local function glyphFor(cls)
  local c = string.lower(cls or "")
  for _, pair in GLYPHS do
    if string.find(c, pair[1], 1, true) then return pair[2] end
  end
  return "app-window"
end

local function render()
  local empty = (win.cls or "") == "" and (win.title or "") == ""
  local title = if empty then "Desktop" else (if (win.title or "") ~= "" then win.title else win.cls)
  barWidget.render(S.key({
    key = "win",
    hovered = hovered,
    tooltip = if empty then "No focused window" else `{win.cls}\n{win.title}`,
    onHover = function(state)
      hovered = state == "true"
      render()
    end,
  }, {
    S.glyph(if empty then "layout-dashboard" else glyphFor(win.cls), { color = S.C.sub }),
    S.label(title, { color = if empty then S.C.dim else "on_surface/0.85", maxWidth = 300 }),
  }))
end

S.watch("graphite.win", function(v)
  if type(v) == "table" then win = v end
  render()
end)

render()
