--!nonstrict
-- Expression evaluator for the calculator panel: a small recursive-descent
-- parser. Understands + - * / ^ ! %, "mod", implicit multiplication (2pi, 3(4)),
-- functions and constants. Unclosed brackets at the end are closed for you.
-- "100+10%" means 110 (percent of the left side), like a pocket calculator.

local E = {}

local PI = math.pi

local function fail(msg, incomplete)
  error({ msg = msg, incomplete = incomplete == true }, 0)
end

local function fact(n)
  if n < 0 or n ~= math.floor(n) then fail("Whole numbers only") end
  if n > 170 then fail("Out of range") end
  local r = 1
  for i = 2, n do r *= i end
  return r
end

-- Snap the float dust of sin(pi) and friends, and call tan(pi/2) undefined.
local function clean(x)
  if math.abs(x) < 1e-15 then return 0 end
  return x
end

local function makeFuncs(deg)
  local toRad = if deg then PI / 180 else 1
  local fromRad = if deg then 180 / PI else 1
  local F = {}
  function F.sin(x)
    if deg then
      local a = x % 360
      if a % 180 == 0 then return 0 end
      if a == 90 then return 1 end
      if a == 270 then return -1 end
    end
    return clean(math.sin(x * toRad))
  end
  function F.cos(x)
    if deg then
      local a = x % 360
      if a == 90 or a == 270 then return 0 end
      if a == 0 then return 1 end
      if a == 180 then return -1 end
    end
    return clean(math.cos(x * toRad))
  end
  function F.tan(x)
    if deg then
      local a = x % 180
      if a == 0 then return 0 end
      if a == 90 then fail("Undefined") end
    end
    local v = math.tan(x * toRad)
    if math.abs(v) > 1e15 then fail("Undefined") end
    return clean(v)
  end
  function F.asin(x) return math.asin(x) * fromRad end
  function F.acos(x) return math.acos(x) * fromRad end
  function F.atan(x) return math.atan(x) * fromRad end
  F.sinh = math.sinh
  F.cosh = math.cosh
  F.tanh = math.tanh
  F.sqrt = math.sqrt
  function F.cbrt(x)
    if x < 0 then return -((-x) ^ (1 / 3)) end
    return x ^ (1 / 3)
  end
  F.abs = math.abs
  function F.ln(x) return math.log(x) end
  function F.log(x) return math.log10(x) end
  function F.log10(x) return math.log10(x) end
  function F.log2(x) return math.log(x, 2) end
  F.exp = math.exp
  F.floor = math.floor
  F.ceil = math.ceil
  function F.round(x) return math.floor(x + 0.5) end
  return F
end

local function normalize(s)
  s = string.lower(s)
  s = string.gsub(s, "×", "*")
  s = string.gsub(s, "÷", "/")
  s = string.gsub(s, "−", "-")
  s = string.gsub(s, "π", "pi")
  s = string.gsub(s, "√", "sqrt")
  s = string.gsub(s, "²", "^2")
  s = string.gsub(s, "³", "^3")
  s = string.gsub(s, ",", "")
  s = string.gsub(s, "%*%*", "^")
  s = string.gsub(s, "%f[%a]x%f[%A]", "*") -- 2 x 3
  return s
end

-- Returns value, or nil + message + incomplete (true when more typing could fix it).
function E.eval(text, opts)
  opts = opts or {}
  local src = normalize(text or "")
  local pos = 1
  local F = makeFuncs(opts.deg == true)
  local pct = false -- the factor just parsed ended in %

  local expr, term, unary, power, postfix, primary

  local function ws()
    pos = string.find(src, "%S", pos) or (#src + 1)
  end
  local function peek()
    ws()
    return string.sub(src, pos, pos)
  end
  local function startsValue(c)
    return c ~= "" and (string.find(c, "[%d%.%a%(]") ~= nil)
  end

  function primary()
    local c = peek()
    if c == "" then fail("Incomplete", true) end
    if c == "(" then
      pos += 1
      local v = expr()
      local n = peek()
      if n == ")" then pos += 1
      elseif n ~= "" then fail("Syntax error") end -- a missing final ) is fine
      return v
    end
    if string.find(c, "[%d%.]") then
      local num = string.match(src, "^%d*%.?%d*", pos)
      if not string.find(num, "%d") then fail("Syntax error") end
      pos += #num
      local exp = string.match(src, "^e[%+%-]?%d+", pos)
      if exp then num ..= exp; pos += #exp end
      local v = tonumber(num)
      if not v then fail("Syntax error") end
      return v
    end
    if string.find(c, "%a") then
      local name = string.match(src, "^log2", pos) or string.match(src, "^log10", pos) or string.match(src, "^%a+", pos)
      pos += #name
      if name == "pi" then return PI end
      if name == "e" then return math.exp(1) end
      if name == "ans" then return opts.ans or 0 end
      local fn = F[name]
      if not fn then fail("Unknown: " .. name) end
      if peek() == "" then fail("Incomplete", true) end
      if peek() == "(" then return fn(primary()) end
      return fn(power()) -- sin30
    end
    fail("Syntax error")
    return 0
  end

  function postfix()
    local v = primary()
    pct = false
    while true do
      local c = peek()
      if c == "!" then
        pos += 1
        v = fact(v)
        pct = false
      elseif c == "%" then
        -- 7%3 is modulo (handled in term); a % before anything else is percent.
        local save = pos
        pos += 1
        if startsValue(peek()) then pos = save; break end
        v /= 100
        pct = true
      else
        break
      end
    end
    return v
  end

  function power()
    local v = postfix()
    if peek() == "^" then
      pos += 1
      local r = unary()
      pct = false
      return v ^ r
    end
    return v
  end

  function unary()
    local c = peek()
    if c == "-" then pos += 1; return -unary() end
    if c == "+" then pos += 1; return unary() end
    return power()
  end

  function term()
    local v = unary()
    while true do
      local c = peek()
      if c == "*" then
        pos += 1
        v *= unary()
        pct = false
      elseif c == "/" then
        pos += 1
        local r = unary()
        if r == 0 then fail("Can't divide by zero") end
        v /= r
        pct = false
      elseif c == "%" or string.match(src, "^mod%f[%A]", pos) then
        pos += if c == "%" then 1 else 3
        local r = unary()
        if r == 0 then fail("Can't divide by zero") end
        v = v % r
        pct = false
      elseif startsValue(c) then
        v *= power() -- implicit: 2pi, 3(4), (1)(2)
        pct = false
      else
        return v
      end
    end
  end

  function expr()
    local v = term()
    while true do
      local c = peek()
      if c ~= "+" and c ~= "-" then return v end
      pos += 1
      local r = term()
      if pct then r *= v end -- 100+10% = 110
      pct = false
      v = if c == "+" then v + r else v - r
    end
  end

  local ok, res = pcall(function()
    if peek() == "" then fail("Incomplete", true) end
    local v = expr()
    if peek() ~= "" then fail("Syntax error") end
    return v
  end)
  if not ok then
    if type(res) == "table" then return nil, res.msg, res.incomplete end
    return nil, "Syntax error", false
  end
  if res ~= res then return nil, "Undefined", false end
  if res == math.huge or res == -math.huge then return nil, "Out of range", false end
  return res
end

-- Plain number text: at most 14 significant digits, which hides float dust
-- (0.1+0.2 is 0.3). Whole numbers below 1e15 print in full.
function E.format(v)
  if v == 0 then return "0" end
  if v == math.floor(v) and math.abs(v) < 1e15 then
    return string.format("%.0f", v)
  end
  local s = string.format("%.14g", v)
  s = string.gsub(s, "e%+?(%-?)0*(%d)", "e%1%2")
  return s
end

-- What the user sees: at most 3 decimals. Values too small to survive that, and
-- huge ones, use scientific notation rather than reading as a false 0.
function E.show(v)
  if v == 0 then return "0" end
  local a = math.abs(v)
  if a >= 1e15 or a < 0.001 then
    local s = string.format("%.3e", v)
    local m, x = string.match(s, "^(.-)e(.*)$")
    m = string.gsub(string.gsub(m, "0+$", ""), "%.$", "")
    x = string.gsub(x, "^%+?(%-?)0*(%d)", "%1%2")
    return m .. "e" .. x
  end
  local s = string.format("%.3f", v)
  s = string.gsub(string.gsub(s, "0+$", ""), "%.$", "")
  return s
end

-- Swap the rounded number on screen for the exact value it stands for, so that
-- 1/3 then x3 gives 1 and not 0.999. carry = { text, value }.
function E.substitute(text, carry)
  if not carry then return text end
  local from = 1
  while true do
    local i, j = string.find(text, carry.text, from, true)
    if not i then return text end
    local before = if i > 1 then string.sub(text, i - 1, i - 1) else ""
    local after = string.sub(text, j + 1, j + 1)
    if not string.find(before, "[%d%.]") and not string.find(after, "[%d%.e]") then
      return string.sub(text, 1, i - 1) .. "(" .. string.format("%.17g", carry.value) .. ")" .. string.sub(text, j + 1)
    end
    from = j + 1
  end
end

-- Commas in the whole part, for display only.
function E.group(s)
  local sign, whole, rest = string.match(s, "^(%-?)(%d+)(.*)$")
  if not whole or string.find(rest, "e", 1, true) then return s end
  local out = string.reverse(whole)
  out = string.gsub(out, "(%d%d%d)", "%1,")
  out = string.reverse(out)
  out = string.gsub(out, "^,", "")
  return sign .. out .. rest
end

return E
