--!nonstrict
-- Bar button: left click opens the Snapshot menu, right click captures a region.

local capture = require("./capture.luau")

barWidget.setGlyph("camera")
barWidget.setTooltip({
  { key = "Left click", value = "Screenshot menu" },
  { key = "Right click", value = "Capture region" },
})

function onClick()
  noctalia.togglePanel("vyeos/snapshot:menu")
end

function onRightClick()
  capture.capture("region")
end
