--!nonstrict
-- What the launcher remembers: how often and how recently each result is picked,
-- which result each typed term ends up meaning, pins, aliases, past searches and
-- quicklinks. Stored in the plugin's data folder and never sent anywhere.

local R = {}

local HALF_LIFE = 14 * 86400 -- a pick counts half as much after two weeks
local TERM_MAX = 24          -- longer searches aren't worth remembering
local SECTION_MAX = 5
local HISTORY_MAX = 50
local RESULT_MAX = 60
local BASE = { 1000, 800, 600, 400, 250, 100 } -- by match tier, best first

local path = nil
local data = { use = {}, terms = {}, pins = {}, aliases = {}, history = {}, quicklinks = nil }

local SEED_LINKS = {
  { id = "yt", name = "YouTube", keyword = "yt", url = "https://www.youtube.com/results?search_query={query}" },
  { id = "gh", name = "GitHub", keyword = "gh", url = "https://github.com/search?q={query}" },
}

function R.load(dir)
  if not dir then return end
  path = dir .. "/launcher-usage.json"
  local raw = noctalia.readFile(path)
  local d = if raw then noctalia.json.decode(raw) else nil
  if type(d) == "table" then
    for _, field in { "use", "terms", "pins", "aliases", "history", "quicklinks" } do
      if type(d[field]) == "table" then data[field] = d[field] end
    end
  end
  if not data.quicklinks then data.quicklinks = table.clone(SEED_LINKS) end
end

local function save()
  if path then noctalia.writeFile(path, noctalia.json.encode(data)) end
end

local function frecency(id, now)
  local u = data.use[id]
  if not u then return 0 end
  return u.score * 0.5 ^ (math.max(0, now - u.last) / HALF_LIFE)
end

-- Note that result id was picked after typing term (may be empty).
function R.record(id, term)
  local now = os.time()
  data.use[id] = { score = frecency(id, now) + 1, last = now }
  local t = string.lower(noctalia.string.trim(term or ""))
  if t ~= "" and #t <= TERM_MAX then
    local m = data.terms[t] or {}
    m[id] = (m[id] or 0) + 1
    data.terms[t] = m
  end
  save()
end

function R.pushHistory(term)
  local t = noctalia.string.trim(term or "")
  if t == "" then return end
  local i = table.find(data.history, t)
  if i then table.remove(data.history, i) end
  table.insert(data.history, 1, t)
  while #data.history > HISTORY_MAX do table.remove(data.history) end
  save()
end

function R.history() return data.history end

function R.isPinned(id) return table.find(data.pins, id) ~= nil end

-- Returns true when the result is now pinned.
function R.togglePin(id)
  local i = table.find(data.pins, id)
  if i then table.remove(data.pins, i) else table.insert(data.pins, id) end
  save()
  return i == nil
end

function R.aliasOf(id)
  for alias, target in data.aliases do
    if target == id then return alias end
  end
  return nil
end

-- An empty text removes the alias.
function R.setAlias(id, text)
  local old = R.aliasOf(id)
  if old then data.aliases[old] = nil end
  local t = string.lower(noctalia.string.trim(text or ""))
  if t ~= "" then data.aliases[t] = id end
  save()
end

function R.quicklinks() return data.quicklinks or {} end

function R.saveQuicklink(q)
  for i, old in data.quicklinks do
    if old.id == q.id then data.quicklinks[i] = q; save(); return end
  end
  table.insert(data.quicklinks, q)
  save()
end

function R.deleteQuicklink(id)
  for i, q in data.quicklinks do
    if q.id == id then table.remove(data.quicklinks, i); save(); return end
  end
end

-- Three reused rows: this runs for many words on every keystroke, and Noctalia
-- stops a script that spends too long in one callback.
local row2, row1, row0 = table.create(40, 0), table.create(40, 0), table.create(40, 0)

-- True when q is within limit edits of the first lb bytes of word, a swap of
-- neighbours counting as one.
local function near(q, word, lb, limit)
  local la = #q
  if math.abs(la - lb) > limit then return false end
  for j = 0, lb do row1[j] = j end
  for i = 1, la do
    local ca = string.byte(q, i)
    row0[0] = i
    for j = 1, lb do
      local cb = string.byte(word, j)
      local v = row1[j - 1] + (if ca == cb then 0 else 1)
      if row1[j] + 1 < v then v = row1[j] + 1 end
      if row0[j - 1] + 1 < v then v = row0[j - 1] + 1 end
      if i > 1 and j > 1 and ca == string.byte(word, j - 1) and string.byte(q, i - 1) == cb and row2[j - 2] + 1 < v then
        v = row2[j - 2] + 1
      end
      row0[j] = v
    end
    row2, row1, row0 = row1, row0, row2
  end
  return row1[lb] <= limit
end

local function typo(q, name)
  if #q < 4 or #q > 24 then return false end
  local limit = if #q >= 8 then 2 else 1
  local c1, c2 = string.byte(q, 1, 2)
  for word in string.gmatch(name, "%w+") do
    -- A typo almost never hits both of the first two letters.
    local w1, w2 = string.byte(word, 1, 2)
    if w1 == c1 or w1 == c2 or w2 == c1 then
      for len = #q - 1, #q + 1 do
        if len <= #word and near(q, word, len, limit) then return true end
      end
    end
  end
  return false
end

local function inOrder(q, name)
  if #q < 2 then return false end
  local at = 1
  for i = 1, #q do
    local found = string.find(name, string.sub(q, i, i), at, true)
    if not found then return false end
    at = found + 1
  end
  return true
end

-- Index into BASE, or nil when a doesn't match q at all. Loose matching is limited
-- to results with a.fuzzy, which keeps long lists like files cheap and uncluttered.
local function tier(a, q)
  if string.sub(a.lname, 1, #q) == q or string.sub(a.squash, 1, #q) == q then return 1 end
  if a.alt and string.find(" " .. a.alt, " " .. q, 1, true) then return 1 end
  if string.find(a.lname, " " .. q, 1, true) then return 2 end
  if string.find(a.lname, q, 1, true) then return 3 end
  if string.find(a.hay, q, 1, true) then return 4 end
  if a.fuzzy then
    if typo(q, a.lname) then return 5 end
    if inOrder(q, a.lname) then return 6 end
  end
  return nil
end

-- Items matching q (lowercase, trimmed), best first.
function R.rank(items, q)
  local now = os.time()
  local alias = data.aliases[q]
  local learned = data.terms[q] or {}
  local scored = {}
  for _, a in items do
    local t = tier(a, q)
    local picks = learned[a.id]
    if t or picks or a.id == alias then
      local s = (if t then BASE[t] else 0) + math.min(frecency(a.id, now), 20) * 10 + (a.weight or 0)
      if picks then s += 1000 + math.min(picks, 50) end
      if a.id == alias then s += 5000 end
      table.insert(scored, { a = a, s = s })
    end
  end
  table.sort(scored, function(x, y)
    if x.s ~= y.s then return x.s > y.s end
    return x.a.lname < y.a.lname
  end)
  local out = {}
  for i, it in scored do
    if i > RESULT_MAX then break end
    table.insert(out, it.a)
  end
  return out
end

-- The view before anything is typed: { { title, items } }, empty sections left out.
-- Each result appears once. Recents claim theirs before suggestions, so suggestions
-- are the habits that a glance at recents wouldn't already show.
function R.home(items)
  local now = os.time()
  local byId, taken = {}, {}
  for _, a in items do byId[a.id] = a end

  local pinned = {}
  for _, id in data.pins do
    if byId[id] then table.insert(pinned, byId[id]); taken[id] = true end
  end

  local used = {}
  for id, u in data.use do
    if byId[id] and not taken[id] then table.insert(used, { a = byId[id], last = u.last, f = frecency(id, now) }) end
  end

  table.sort(used, function(x, y)
    if x.last ~= y.last then return x.last > y.last end
    return x.a.lname < y.a.lname
  end)
  local recents = {}
  for _, it in used do
    if #recents == SECTION_MAX then break end
    table.insert(recents, it.a)
    taken[it.a.id] = true
  end

  table.sort(used, function(x, y)
    if x.f ~= y.f then return x.f > y.f end
    return x.a.lname < y.a.lname
  end)
  local suggested = {}
  for _, it in used do
    if #suggested == SECTION_MAX then break end
    if not taken[it.a.id] then table.insert(suggested, it.a) end
  end

  local out = {}
  if #pinned > 0 then table.insert(out, { title = "Pinned", items = pinned }) end
  if #suggested > 0 then table.insert(out, { title = "Suggestions", items = suggested }) end
  if #recents > 0 then table.insert(out, { title = "Recents", items = recents }) end
  return out
end

return R
