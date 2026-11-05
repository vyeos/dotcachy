--!nonstrict
-- Calculator (SUPER + C): Basic, Advanced and Convert modes, flat and square.
-- Type expressions freely or use the keys; the result updates as you type.
-- Opens empty. Results show at most 3 decimals but carry on at full precision.
-- Tab switches mode, Up/Down walk the history, Enter commits (Enter again copies),
-- clicking the result copies it. State: pluginDataDir/calc-state.json.

local S = require("./style.luau")
local E = require("./calc-eval.luau")
local CATS = require("./calc-units.luau")
S.fonts()

local MODES = { "basic", "advanced", "convert" }
local MODE_LABEL = { basic = "Basic", advanced = "Advanced", convert = "Convert" }
local KEY_H = 50
local INNER_W = 452 -- panel width minus the host's padding
local MAX_HISTORY = 40

local mode = "basic"
local expr = ""
local fresh = false -- expr is a committed result: the next digit starts over
local gen = 0 -- a new input key re-seeds the uncontrolled field and refocuses it
local err = nil
local ans = 0
local deg = true
local history = {}
local histPos = nil
local carry = nil -- the committed result on screen: { text, value }
local lastLine = nil -- line above the field; empty until something is committed
local copied = false
local hovered = nil
local actions = {}

local conv = { cat = 1, expr = "", units = {} }
local convCarry = nil

local dataDir = noctalia.pluginDataDir()
local statePath = if dataDir then dataDir .. "/calc-state.json" else nil

local function load()
  if not statePath then return end
  local raw = noctalia.readFile(statePath)
  local d = if raw then noctalia.json.decode(raw) else nil
  if type(d) ~= "table" then return end
  if MODE_LABEL[d.mode] then mode = d.mode end
  if type(d.ans) == "number" then ans = d.ans end
  if type(d.deg) == "boolean" then deg = d.deg end
  if type(d.history) == "table" then history = d.history end
  if type(d.conv) == "table" then
    if CATS[d.conv.cat] then conv.cat = d.conv.cat end
    if type(d.conv.units) == "table" then conv.units = d.conv.units end
  end
end

local function save()
  if not statePath then return end
  noctalia.writeFile(statePath, noctalia.json.encode({
    mode = mode, ans = ans, deg = deg, history = history, conv = { cat = conv.cat, units = conv.units },
  }))
end

-- ── Calculator ──────────────────────────────────────────────────────────────

local function setExpr(s)
  expr = s
  err = nil
  copied = false
  gen += 1
  render()
end

local function copy(text)
  noctalia.copyToClipboard(text, "text/plain;charset=utf-8")
  copied = true
  render()
end

local function evalNow()
  return E.eval(E.substitute(expr, carry), { deg = deg, ans = ans })
end

local function commit()
  if expr == "" then return end
  if fresh then copy(expr); return end
  local v, msg = evalNow()
  if v == nil then
    err = msg
    render()
    return
  end
  local r = E.show(v)
  table.insert(history, { e = expr, r = r, ct = if carry then carry.text else nil, cv = if carry then carry.value else nil })
  lastLine = expr .. " = " .. E.group(r)
  while #history > MAX_HISTORY do table.remove(history, 1) end
  histPos = nil
  ans = v
  fresh = true
  carry = { text = r, value = v }
  setExpr(r)
  save()
end

-- Add text at the end. Values start over after a committed result; operators
-- carry on from it.
local function insert(text, isValue)
  local base = if fresh and isValue then "" else expr
  if fresh and isValue then carry = nil end
  fresh = false
  histPos = nil
  setExpr(base .. text)
end

local function backspace()
  if fresh or expr == "" then
    fresh = false
    carry = nil
    setExpr("")
    return
  end
  local cut = string.match(expr, "^(.-)%a+%($") -- a whole "sin(" at once
  if not cut then
    local at = utf8.offset(expr, -1)
    cut = string.sub(expr, 1, (at or 1) - 1)
  end
  histPos = nil
  setExpr(cut)
end

local function clearAll()
  fresh = false
  carry = nil
  histPos = nil
  setExpr("")
end

local function negate()
  local inner = string.match(expr, "^%-%((.*)%)$")
  fresh = false
  if inner then setExpr(inner)
  elseif expr == "" then setExpr("-")
  elseif string.find(expr, "^%-?[%d%.]+$") then
    setExpr(if string.sub(expr, 1, 1) == "-" then string.sub(expr, 2) else "-" .. expr)
  else setExpr("-(" .. expr .. ")") end
end

local function wrap(prefix, suffix)
  fresh = false
  setExpr(prefix .. expr .. suffix)
end

local function recall(d)
  if #history == 0 then return end
  local i = (histPos or (#history + 1)) + d
  if i > #history then
    histPos = nil
    fresh = false
    carry = nil
    setExpr("")
    return
  end
  histPos = math.max(1, i)
  fresh = false
  local h = history[histPos]
  carry = if h.ct and h.cv then { text = h.ct, value = h.cv } else nil
  setExpr(h.e)
end

local function onExprChange(v)
  v = v or ""
  if v == expr then return end
  -- Typing "=" commits.
  if string.sub(v, -1) == "=" then
    expr = string.sub(v, 1, -2)
    fresh = false
    commit()
    return
  end
  -- A value typed right after a result starts a new expression.
  if fresh and #v == #expr + 1 and string.sub(v, 1, #expr) == expr then
    local c = string.sub(v, -1)
    if string.find(c, "[%d%.%a%(]") then
      fresh = false
      carry = nil
      setExpr(c)
      return
    end
  end
  fresh = false
  histPos = nil
  expr = v
  err = nil
  copied = false
  render()
end

-- ── Converter ───────────────────────────────────────────────────────────────

local function unitsFor(catIndex)
  local c = CATS[catIndex]
  local key = c.name
  local u = conv.units[key]
  if type(u) ~= "table" or not c.units[u.from] or not c.units[u.to] then
    u = { from = c.from, to = c.to }
    conv.units[key] = u
  end
  return c, u
end

local function convertNow()
  local v, msg, incomplete = E.eval(E.substitute(conv.expr, convCarry), { deg = deg, ans = ans })
  if v == nil then return nil, msg, incomplete end
  local c, u = unitsFor(conv.cat)
  local a, b = c.units[u.from], c.units[u.to]
  local base = if a.to then a.to(v) else v * a[2]
  return if b.back then b.back(base) else base / b[2]
end

local function setConv(s)
  conv.expr = s
  copied = false
  gen += 1
  render()
end

local function onConvChange(v)
  v = v or ""
  if v == conv.expr then return end
  conv.expr = v
  copied = false
  render()
end

local function convBackspace()
  local at = utf8.offset(conv.expr, -1)
  setConv(string.sub(conv.expr, 1, (at or 1) - 1))
end

local function convNegate()
  local e = conv.expr
  if string.sub(e, 1, 1) == "-" then setConv(string.sub(e, 2)) else setConv("-" .. e) end
end

-- Same quantity from the other side: the old result becomes the value.
local function convSwap()
  local v = convertNow()
  local _, u = unitsFor(conv.cat)
  u.from, u.to = u.to, u.from
  if v ~= nil then
    local shown = E.show(v)
    convCarry = { text = shown, value = v }
    conv.expr = shown
  end
  gen += 1
  copied = false
  save()
  render()
end

local function convCopy()
  local v = convertNow()
  if v ~= nil then copy(E.show(v)) end
end

-- ── Pieces ──────────────────────────────────────────────────────────────────

local function hoverFn(id)
  return function(st)
    hovered = if st == "true" then id elseif hovered == id then nil else hovered
    render()
  end
end

-- One keypad cell. o: { id, label, glyph, tone = "num"|"op"|"fn"|"eq", run }
local function cell(o)
  actions[o.id] = o.run
  local eq = o.tone == "eq"
  local color = if eq then "surface" elseif o.tone == "num" then S.C.text else S.C.sub
  local size = if o.tone == "fn" then 13 else 18
  local fill = "#00000000"
  if eq then fill = S.C.text elseif hovered == o.id then fill = S.C.keyHover end
  return ui.row({
    key = "k-" .. o.id,
    height = KEY_H,
    width = if mode == "advanced" then (INNER_W - 2) / 8 else INNER_W / 4,
    radius = 0,
    fill = fill,
    align = "center",
    justify = "center",
    onClick = o.run,
    onHover = hoverFn(o.id),
  }, {
    if o.glyph then ui.glyph({ name = o.glyph, size = 19, color = color })
    else ui.label({ text = o.label, fontFamily = S.mono, fontSize = size, color = color }),
  })
end

local function groove(key)
  return ui.row({ key = key, gap = 0, height = KEY_H, width = 2 }, {
    ui.box({ width = 1, height = KEY_H, fill = S.C.well }),
    ui.box({ width = 1, height = KEY_H, fill = S.C.keyHover }),
  })
end

local function tabs()
  local kids = {}
  for _, m in MODES do
    local id = "tab-" .. m
    local active = mode == m
    actions[id] = function()
      mode = m
      hovered = nil
      err = nil
      copied = false
      gen += 1
      save()
      render()
    end
    table.insert(kids, ui.column({
      key = id, height = 32, paddingH = 10, gap = 0, align = "center", justify = "end",
      fill = if hovered == id and not active then S.C.keyHover else "#00000000",
      onClick = actions[id],
      onHover = hoverFn(id),
    }, {
      ui.row({ flexGrow = 1, align = "center" }, {
        ui.label({ text = MODE_LABEL[m], fontFamily = S.sans, fontSize = 14,
          color = if active then S.C.text else S.C.dim }),
      }),
      ui.box({ width = 34, height = 2, radius = 0, fill = if active then S.C.text else "#00000000" }),
    }))
  end
  table.insert(kids, ui.spacer({ flexGrow = 1 }))
  table.insert(kids, S.caption(if copied then "copied" else ""))
  return ui.row({ align = "center", gap = 2, height = 32 }, kids)
end

local function fieldRow(key, value, onChange, onSubmit)
  return ui.input({
    key = key,
    value = value,
    frameVisible = false,
    focus = true,
    fontSize = 16,
    controlSize = "sm",
    flexGrow = 1,
    onChange = onChange,
    onSubmit = onSubmit,
  })
end

-- A big right-aligned number; clicking it copies.
local function resultLine(text, color, onClick)
  local n = #text
  local size = if n > 22 then 16 elseif n > 15 then 22 else 32
  return ui.row({ key = "result", height = 46, align = "center", justify = "end", onClick = onClick }, {
    ui.label({ text = text, fontFamily = S.mono, fontSize = size, color = color, maxLines = 1 }),
  })
end

-- ── Modes ───────────────────────────────────────────────────────────────────

local function numKey(d)
  return cell({ id = d, label = d, tone = "num", run = function() insert(d, true) end })
end
local function opKey(id, label, text)
  return cell({ id = id, label = label, tone = "op", run = function() insert(text, false) end })
end
local function fnKey(id, label, text)
  return cell({ id = id, label = label, tone = "fn", run = function() insert(text, true) end })
end
-- Function-row key that carries on from a result: ")", x², xʸ, n!
local function fnOp(id, label, text)
  return cell({ id = id, label = label, tone = "fn", run = function() insert(text, false) end })
end

local function padRows()
  return {
    { cell({ id = "clear", label = "C", tone = "op", run = clearAll }),
      cell({ id = "back", glyph = "backspace", tone = "op", run = backspace }),
      opKey("pct", "%", "%"), opKey("div", "÷", "÷") },
    { numKey("7"), numKey("8"), numKey("9"), opKey("mul", "×", "×") },
    { numKey("4"), numKey("5"), numKey("6"), opKey("sub", "-", "-") },
    { numKey("1"), numKey("2"), numKey("3"), opKey("add", "+", "+") },
    { cell({ id = "neg", label = "±", tone = "op", run = negate }), numKey("0"), numKey("."),
      cell({ id = "eq", label = "=", tone = "eq", run = commit }) },
  }
end

local function fnRows()
  return {
    { fnKey("lp", "(", "("), fnOp("rp", ")", ")"), fnOp("sq", "x²", "^2"), fnOp("pow", "xʸ", "^") },
    { fnKey("sin", "sin", "sin("), fnKey("cos", "cos", "cos("), fnKey("tan", "tan", "tan("), fnKey("sqrt", "√", "sqrt(") },
    { fnKey("asin", "asin", "asin("), fnKey("acos", "acos", "acos("), fnKey("atan", "atan", "atan("),
      cell({ id = "inv", label = "1/x", tone = "fn", run = function() wrap("1/(", ")") end }) },
    { fnKey("ln", "ln", "ln("), fnKey("log", "log", "log("), fnKey("exp", "eˣ", "exp("), fnOp("fact", "n!", "!") },
    { fnKey("pi", "π", "pi"), fnKey("e", "e", "e"), fnKey("ans", "Ans", "ans"),
      cell({ id = "angle", label = if deg then "DEG" else "RAD", tone = "fn", run = function()
        deg = not deg
        save()
        render()
      end }) },
  }
end

local function calcView()
  local preview, color = "", S.C.text
  if err then
    preview, color = err, S.C.sub
  elseif expr ~= "" then
    local v = evalNow()
    if v ~= nil then
      preview = E.group(E.show(v))
    else
      preview, color = "", S.C.dim
    end
  end

  local pad = padRows()
  local rows = {}
  if mode == "advanced" then
    local fns = fnRows()
    for i, r in pad do
      local kids = {}
      for _, c in fns[i] do table.insert(kids, c) end
      table.insert(kids, groove("g" .. i))
      for _, c in r do table.insert(kids, c) end
      table.insert(rows, ui.row({ key = "r" .. i, gap = 0 }, kids))
    end
  else
    for i, r in pad do
      table.insert(rows, ui.row({ key = "r" .. i, gap = 0 }, r))
    end
  end

  return {
    ui.row({ height = 18, align = "center", justify = "end" }, {
      ui.label({ text = lastLine or " ",
        fontFamily = S.mono, fontSize = 11.5, color = S.C.dim, maxLines = 1 }),
    }),
    ui.row({ height = 30, align = "center" }, {
      fieldRow("expr-" .. gen, expr, onExprChange, function() commit() end),
    }),
    resultLine(preview, color, function()
      if expr == "" or err then return end
      local v = evalNow()
      if v ~= nil then copy(E.show(v)) end
    end),
    S.hline("h2"),
    ui.column({ gap = 0, align = "stretch" }, rows),
  }
end

local function unitOptions(c)
  local o = {}
  for _, u in c.units do table.insert(o, u[1]) end
  return o
end

local function indexOfName(list, text, index)
  for i, v in list do
    if v == text then return i end
  end
  return (tonumber(index) or 0) + 1
end

local function convertView()
  local c, u = unitsFor(conv.cat)
  local catNames = {}
  for _, x in CATS do table.insert(catNames, x.name) end
  local options = unitOptions(c)

  local v, msg = convertNow()
  local text, color = "", S.C.dim
  if conv.expr == "" then
    text = ""
  elseif v ~= nil then
    text, color = E.group(E.show(v)), S.C.text
  elseif msg and msg ~= "Incomplete" then
    text, color = msg, S.C.sub
  end

  local function d(x)
    return cell({ id = x, label = x, tone = "num", run = function() setConv(conv.expr .. x) end })
  end
  local rows = {
    { d("7"), d("8"), d("9"), cell({ id = "back", glyph = "backspace", tone = "op", run = convBackspace }) },
    { d("4"), d("5"), d("6"), cell({ id = "clear", label = "C", tone = "op", run = function() setConv("") end }) },
    { d("1"), d("2"), d("3"), cell({ id = "swap", glyph = "arrows-up-down", tone = "op", run = convSwap }) },
    { cell({ id = "neg", label = "±", tone = "op", run = convNegate }), d("0"), d("."),
      cell({ id = "copy", glyph = "copy", tone = "op", run = convCopy }) },
  }
  local padRowsUi = {}
  for i, r in rows do
    table.insert(padRowsUi, ui.row({ key = "r" .. i, gap = 0 }, r))
  end

  return {
    ui.select({
      key = "cat",
      options = catNames,
      selectedIndex = conv.cat - 1,
      controlSize = "sm",
      onChange = function(index, name)
        conv.cat = indexOfName(catNames, name, index)
        copied = false
        gen += 1
        save()
        render()
      end,
    }),
    ui.row({ align = "center", gap = 10, height = 36 }, {
      fieldRow("conv-" .. gen, conv.expr, onConvChange, function() convCopy() end),
      ui.select({
        key = "from-" .. conv.cat,
        width = 190,
        options = options,
        selectedIndex = u.from - 1,
        controlSize = "sm",
        onChange = function(index, name)
          u.from = indexOfName(options, name, index)
          copied = false
          save()
          render()
        end,
      }),
    }),
    S.hline("h3"),
    ui.row({ align = "center", gap = 10, height = 46 }, {
      ui.row({ key = "result", width = INNER_W - 200, height = 46, align = "center", onClick = function() convCopy() end }, {
        ui.label({ text = text, fontFamily = S.mono, fontSize = if #text > 15 then 15 elseif #text > 10 then 19 else 26,
          color = color, maxLines = 1 }),
      }),
      ui.select({
        key = "to-" .. conv.cat,
        width = 190,
        options = options,
        selectedIndex = u.to - 1,
        controlSize = "sm",
        onChange = function(index, name)
          u.to = indexOfName(options, name, index)
          copied = false
          save()
          render()
        end,
      }),
    }),
    S.hline("h4"),
    ui.column({ gap = 0, align = "stretch" }, padRowsUi),
  }
end

function render()
  actions = {}
  local kids = { tabs(), S.hline("h1") }
  local body = if mode == "convert" then convertView() else calcView()
  for _, k in body do table.insert(kids, k) end
  panel.render(ui.column({ flexGrow = 1, gap = 6, align = "stretch" }, kids))
end

-- ── Host ────────────────────────────────────────────────────────────────────

function onKey(key, pressed)
  if pressed == false then return end
  local k = string.lower(tostring(key))
  if k == "tab" or k == "shift+tab" then
    local i = table.find(MODES, mode) or 1
    i = ((i - 1 + (if k == "tab" then 1 else -1)) % #MODES) + 1
    actions["tab-" .. MODES[i]]()
  elseif mode ~= "convert" and k == "up" then recall(-1)
  elseif mode ~= "convert" and k == "down" then recall(1)
  elseif k == "kp_enter" then
    if mode == "convert" then convCopy() else commit() end
  end
end

function onOpen(_context)
  hovered = nil
  copied = false
  err = nil
  histPos = nil
  expr = ""
  fresh = false
  carry = nil
  lastLine = nil
  conv.expr = ""
  convCarry = nil
  gen += 1
  render()
end

function onClose()
  save()
end

-- Test hooks: noctalia msg plugin vyeos/graphite:calc all press <key id> | selftest
function onIpc(event, payload)
  if event == "press" and payload and actions[payload] then
    actions[payload]()
  elseif event == "selftest" then
    local T = require("./dev/calc-test.luau")
    if dataDir then noctalia.writeFile(dataDir .. "/calc-test.txt", T.run(E, CATS)) end
  end
end

load()
render()
