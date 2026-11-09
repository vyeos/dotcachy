-- Recording a keybind from the launcher (Ctrl+K, Set keybind).
--
-- Noctalia panels can't capture chords with SUPER, and Hyprland would run the real
-- shortcut first anyway. So while the recorder panel is open Hyprland sits in this
-- submap, where every chord does one thing: tell the panel what was pressed.
-- Keys without a modifier stay out of it and reach the panel (Enter, Delete, Escape).
-- bin/graphite bind-record enters and leaves it, and leaves by itself after two minutes.

local report = "noctalia msg plugin vyeos/graphite:bind-record all chord "

local MODS = { "SUPER", "CONTROL", "ALT", "SHIFT" }
local SHIFT_ONLY = 8 -- would stop capital letters being typed, so it can't be recorded

-- { name Hyprland binds, name the panel shows }
local KEYS = {}
for c = string.byte("A"), string.byte("Z") do
	local letter = string.char(c)
	KEYS[#KEYS + 1] = { letter, letter }
end
for d = 0, 9 do -- by keycode, as binds.lua does, so SHIFT + digit matches too
	KEYS[#KEYS + 1] = { "code:" .. (d == 0 and 19 or (9 + d)), tostring(d) }
end
for f = 1, 12 do
	KEYS[#KEYS + 1] = { "F" .. f, "F" .. f }
end
for _, name in ipairs({
	"minus", "equal", "bracketleft", "bracketright", "semicolon", "apostrophe", "grave", "backslash",
	"comma", "period", "slash", "Return", "Space", "Tab", "BackSpace", "Delete", "Insert", "Home", "End",
	"Page_Up", "Page_Down", "Up", "Down", "Left", "Right", "Escape", "Print",
}) do
	KEYS[#KEYS + 1] = { name, name }
end

hl.define_submap("graphite-record", function()
	for bits = 1, 15 do
		if bits ~= SHIFT_ONLY then
			local held = {}
			for i, mod in ipairs(MODS) do
				if math.floor(bits / 2 ^ (i - 1)) % 2 == 1 then
					held[#held + 1] = mod
				end
			end
			local prefix = table.concat(held, " + ")
			local shown = table.concat(held, "+")
			for _, key in ipairs(KEYS) do
				hl.bind(prefix .. " + " .. key[1], hl.dsp.exec_cmd(report .. shown .. "+" .. key[2]))
			end
		end
	end
end)
