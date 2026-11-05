--!nonstrict
-- IPC entry point for keybinds, so they capture with the plugin's settings:
--   noctalia msg plugin vyeos/snapshot:service all capture region|window|fullscreen|all
--   noctalia msg plugin vyeos/snapshot:service all annotate-last
--   noctalia msg plugin vyeos/snapshot:service all menu

local capture = require("./capture.luau")

function onIpc(event, payload)
  if event == "capture" then
    capture.capture(if payload and payload ~= "" then payload else "region")
  elseif event == "annotate-last" then
    local path = capture.lastPath()
    if path then
      capture.annotate(path)
    else
      noctalia.notify("Snapshot", "No screenshot taken yet")
    end
  elseif event == "menu" then
    noctalia.togglePanel("vyeos/snapshot:menu")
  else
    noctalia.log(`snapshot: unknown IPC event '{event}'`)
  end
end
