--!nonstrict
-- Shared capture logic for every entry (panel, bar button, tile, service).
-- Captures go through Noctalia's native engine: it saves the file, copies it to
-- the clipboard and pipes the PNG into on-capture.sh, which shows the notification.

local M = {}

M.DEFAULT_DIR = "~/Pictures/Screenshots"

local SUBCOMMANDS = {
  region = "screenshot-region",
  window = "screenshot-window",
  fullscreen = "screenshot-fullscreen",
  all = "screenshot-fullscreen",
}

local function shq(s: string): string
  return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

function M.directory(): string
  local dir = noctalia.getConfig("directory")
  if type(dir) ~= "string" or noctalia.string.trim(dir) == "" then
    dir = M.DEFAULT_DIR
  end
  return noctalia.expandPath(dir)
end

-- Path of the most recent capture (written by on-capture.sh), or nil.
function M.lastPath(): string?
  local dataDir = noctalia.pluginDataDir()
  if not dataDir then return nil end
  local contents = noctalia.readFile(dataDir .. "/last")
  if not contents then return nil end
  local path = noctalia.string.trim(contents)
  if path ~= "" and noctalia.fileExists(path) then return path end
  return nil
end

-- mode: "region" | "window" | "fullscreen" | "all"
-- leadMs: extra wait before capturing (lets a closing panel fade out first).
function M.capture(mode: string, leadMs: number?)
  local sub = SUBCOMMANDS[mode]
  if not sub then
    noctalia.notifyError("Snapshot", `Unknown capture mode '{mode}'`)
    return
  end

  local dir = M.directory()
  local ok, err = noctalia.mkdirAll(dir)
  if not ok then
    noctalia.notifyError("Snapshot", `Cannot create {dir}: {err or "?"}`)
    return
  end

  local pattern = noctalia.getConfig("filename_pattern")
  if type(pattern) ~= "string" or noctalia.string.trim(pattern) == "" then
    pattern = "screenshot_%Y%m%d_%H%M%S"
  end

  local pluginDir = noctalia.pluginDir() or "."
  local dataDir = noctalia.pluginDataDir() or ""
  local notify = noctalia.getConfig("notify") ~= false
  local hook = `sh {shq(pluginDir .. "/on-capture.sh")} {shq(dataDir)} {if notify then "1" else "0"}`

  local argv = { "noctalia", "msg", sub }
  if mode == "all" then table.insert(argv, "all") end
  for _, flag in {
    "--save-to-file",
    "--copy-to-clipboard",
    "--no-annotate",
    "--pipe-to-command",
    if noctalia.getConfig("show_cursor") == true then "--show-cursor" else "--no-show-cursor",
    if noctalia.getConfig("freeze_screen") == false then "--no-freeze-screen" else "--freeze-screen",
  } do
    table.insert(argv, flag)
  end
  for _, kv in { { "--directory", dir }, { "--filename-pattern", pattern }, { "--pipe-command", hook } } do
    table.insert(argv, kv[1])
    table.insert(argv, kv[2])
  end

  local delay = tonumber(noctalia.getConfig("delay")) or 0
  local waitSec = math.max(0, delay) + (leadMs or 0) / 1000
  if waitSec > 0 then
    local quoted = {}
    for i, a in argv do quoted[i] = shq(a) end
    noctalia.runAsync(`sleep {waitSec}; exec {table.concat(quoted, " ")}`)
  else
    noctalia.runAsync(argv)
  end
end

-- Open the annotator on an existing image; saving writes <name>_annotated.png next to it.
function M.annotate(path: string)
  local dir = string.match(path, "^(.*)/[^/]*$") or "."
  local base = string.match(path, "([^/]+)$") or "screenshot"
  base = string.gsub(string.gsub(base, "%.[^.]*$", ""), "%%", "%%%%")
  noctalia.runAsync({
    "noctalia", "msg", "annotate", path,
    "--directory", dir,
    "--filename-pattern", base .. "_annotated",
    "--copy-to-clipboard",
  })
end

function M.openFolder()
  local dir = M.directory()
  noctalia.mkdirAll(dir)
  noctalia.runAsync({ "xdg-open", dir })
end

function M.prettyPath(path: string): string
  local home = noctalia.getenv("HOME")
  if home and string.sub(path, 1, #home) == home then
    return "~" .. string.sub(path, #home + 1)
  end
  return path
end

return M
