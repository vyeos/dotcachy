--!nonstrict
-- Snapshot menu panel: pick a capture mode, see/change the save folder, and act
-- on the most recent screenshot.

local capture = require("./capture.luau")

local PANEL_LEAD_MS = 300 -- let the panel fade out before the screen is captured

local lastPath = nil
local showClose = true

local function shoot(mode)
  panel.close()
  capture.capture(mode, PANEL_LEAD_MS)
end

local function modeTile(mode, glyph, text)
  return ui.column({
    key = "tile-" .. mode,
    flexGrow = 1,
    gap = 8,
    paddingV = 16,
    align = "center",
    radius = 12,
    fill = "primary/0.10",
    border = "primary/0.25",
    borderWidth = 1,
    tooltip = `Capture {string.lower(text)}`,
    onClick = function() shoot(mode) end,
  }, {
    ui.glyph({ name = glyph, size = 28, color = "primary" }),
    ui.label({ text = text, fontWeight = "medium", color = "on_surface" }),
  })
end

local function sectionTitle(text)
  return ui.label({ text = text, fontWeight = "medium", color = "on_surface_variant" })
end

local function summary()
  local parts = {}
  local delay = tonumber(noctalia.getConfig("delay")) or 0
  table.insert(parts, if delay > 0 then `{delay}s delay` else "No delay")
  table.insert(parts, if noctalia.getConfig("show_cursor") == true then "cursor shown" else "cursor hidden")
  if noctalia.getConfig("notify") == false then table.insert(parts, "no notification") end
  return table.concat(parts, " · ")
end

local function lastSection()
  if not lastPath then
    return ui.column({ gap = 8 }, {
      sectionTitle("Last screenshot"),
      ui.column({ height = 120, radius = 10, align = "center", justify = "center", gap = 6, fill = "on_surface/0.05" }, {
        ui.glyph({ name = "photo", size = 26, color = "on_surface_variant" }),
        ui.label({ text = "Nothing captured yet", color = "on_surface_variant" }),
      }),
    })
  end

  local name = string.match(lastPath, "([^/]+)$") or lastPath
  return ui.column({ gap = 8 }, {
    ui.row({ align = "center", gap = 8 }, {
      sectionTitle("Last screenshot"),
      ui.spacer({ flexGrow = 1 }),
      ui.label({ text = name, color = "on_surface_variant", fontSize = 11, maxLines = 1, maxWidth = 200 }),
    }),
    ui.image({
      key = lastPath,
      path = lastPath,
      height = 130,
      radius = 10,
      fit = "cover",
      border = "outline_variant",
      borderWidth = 1,
      tooltip = "Click to annotate",
      onClick = function()
        panel.close()
        capture.annotate(lastPath)
      end,
    }),
    ui.row({ gap = 8 }, {
      ui.button({
        text = "Annotate", glyph = "pencil", variant = "primary", flexGrow = 1,
        onClick = function()
          panel.close()
          capture.annotate(lastPath)
        end,
      }),
      ui.button({
        text = "Copy", glyph = "copy", variant = "outline", flexGrow = 1,
        onClick = function()
          noctalia.runAsync({ "sh", "-c", 'wl-copy --type image/png < "$1"', "sh", lastPath })
          noctalia.osd.show("copy", "Copied")
        end,
      }),
    }),
  })
end

local function render()
  local header = {
    ui.glyph({ name = "camera", size = 20, color = "primary" }),
    ui.label({ text = "Screenshot", fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
  }
  if showClose then
    table.insert(header, ui.button({ glyph = "x", variant = "ghost", onClick = function() panel.close() end }))
  end

  local dir = capture.prettyPath(capture.directory())

  panel.render(ui.column({ flexGrow = 1, gap = 16 }, {
    ui.row({ align = "center", gap = 10 }, header),

    ui.column({ gap = 8 }, {
      ui.row({ gap = 10 }, {
        modeTile("region", "crop", "Region"),
        modeTile("window", "app-window", "Window"),
        modeTile("fullscreen", "device-desktop", "Screen"),
      }),
      ui.button({
        text = "All monitors", glyph = "devices", variant = "ghost", controlSize = "sm",
        onClick = function() shoot("all") end,
      }),
    }),

    ui.column({ gap = 8 }, {
      sectionTitle("Save to"),
      ui.row({ align = "center", gap = 8, paddingH = 12, paddingV = 6, radius = 10, fill = "on_surface/0.05" }, {
        ui.glyph({ name = "folder", size = 16, color = "on_surface_variant" }),
        ui.label({ text = dir, color = "on_surface", maxLines = 1, flexGrow = 1 }),
        ui.button({
          glyph = "folder-open", variant = "ghost", controlSize = "sm", tooltip = "Open folder",
          onClick = function()
            panel.close()
            capture.openFolder()
          end,
        }),
        ui.button({
          glyph = "settings", variant = "ghost", controlSize = "sm", tooltip = "Change folder and options",
          onClick = function()
            panel.close()
            noctalia.openSettings()
          end,
        }),
      }),
      ui.label({ text = summary() .. " · copied to clipboard", fontSize = 11, color = "on_surface_variant" }),
    }),

    lastSection(),
  }))
end

function onOpen(_context)
  showClose = noctalia.getSetting("shell.show_close_buttons") ~= false
  lastPath = capture.lastPath()
  render()
end
