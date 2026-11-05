--!nonstrict
-- Evaluator + unit checks, run inside the panel via IPC "selftest" (no luau CLI
-- here). Writes PASS/FAIL lines to pluginDataDir/calc-test.txt.
local T = {}

local NUM = {
  { "1+2*3", "7" }, { "(1+2)*3", "9" }, { "0.1+0.2", "0.3" }, { "1-0.9", "0.1" }, { "1.1*1.1", "1.21" },
  { "2^3^2", "512" }, { "-2^2", "-4" }, { "(-2)^2", "4" }, { "2^-1", "0.5" }, { "2**3", "8" },
  { "10/4", "2.5" }, { "7%3", "1" }, { "7 mod 3", "1" }, { "-7%3", "2" },
  { "100+10%", "110" }, { "100-10%", "90" }, { "200*10%", "20" }, { "50%", "0.5" }, { "(50)%", "0.5" }, { "100+10%+10%", "121" },
  { "2pi", "6.2831853071796" }, { "3(4)", "12" }, { "(1+1)(2+2)", "8" }, { "2sin(90)", "2" },
  { "5!", "120" }, { "0!", "1" }, { "3!+1", "7" }, { "2x3", "6" }, { "6÷3×2", "4" }, { "5−2", "3" },
  { "sin(30)", "0.5" }, { "sin(180)", "0" }, { "cos(90)", "0" }, { "tan(45)", "1" }, { "sin30", "0.5" },
  { "asin(1)", "90" }, { "atan(1)", "45" }, { "sqrt(16)", "4" }, { "√16", "4" }, { "cbrt(27)", "3" }, { "cbrt(-8)", "-2" },
  { "log(1000)", "3" }, { "ln(e)", "1" }, { "log2(8)", "3" }, { "exp(0)", "1" }, { "abs(-3)", "3" },
  { "floor(2.7)", "2" }, { "ceil(2.1)", "3" }, { "round(2.5)", "3" }, { "1e3", "1000" }, { "2e", "5.4365636569181" },
  { "1.5e3+1", "1501" }, { ".5+.5", "1" }, { "(1+2", "3" }, { "sqrt(9", "3" }, { "1,000+1", "1001" },
  { "ans+1", "42" }, { "1/3", "0.33333333333333" }, { "1e20", "1e20" }, { "1/1e7", "1e-7" }, { "123456789*1000", "123456789000" },
  { "10^15", "1e15" }, { "2^0.5", "1.4142135623731" }, { "sinh(0)", "0" },
}
local RAD = { { "sin(pi)", "0" }, { "cos(pi)", "-1" }, { "sin(pi/2)", "1" }, { "atan(1)*4", "3.1415926535898" } }
local BAD = {
  { "1/0", "Can't divide by zero" }, { "5%0", "Can't divide by zero" }, { "sqrt(-1)", "Undefined" }, { "log(-1)", "Undefined" },
  { "tan(90)", "Undefined" }, { "171!", "Out of range" }, { "2.5!", "Whole numbers only" }, { "foo(2)", "Unknown: foo" },
  { "1+", "Incomplete" }, { "sin", "Incomplete" }, { "", "Incomplete" }, { "2*", "Incomplete" }, { "1)", "Syntax error" },
  { "10^400", "Out of range" }, { "..", "Syntax error" },
}
local GROUP = { { "1234567.5", "1,234,567.5" }, { "-1000", "-1,000" }, { "999", "999" }, { "1e20", "1e20" }, { "100000", "100,000" } }

-- category, value, from unit index, to unit index, expected
local UNITS = {
  { "Length", 1, "Mile (mi)", "Kilometre (km)", "1.609344" }, { "Length", 12, "Inch (in)", "Foot (ft)", "1" },
  { "Area", 1, "Hectare", "Acre", "2.4710538146717" }, { "Volume", 1, "Gallon (US)", "Litre (L)", "3.785411784" },
  { "Mass", 1, "Kilogram (kg)", "Pound (lb)", "2.2046226218488" }, { "Temperature", 100, "Celsius (°C)", "Fahrenheit (°F)", "212" },
  { "Temperature", 32, "Fahrenheit (°F)", "Celsius (°C)", "0" }, { "Temperature", 0, "Celsius (°C)", "Kelvin (K)", "273.15" },
  { "Temperature", -40, "Fahrenheit (°F)", "Celsius (°C)", "-40" },
  { "Speed", 100, "Kilometre/hour", "Mile/hour", "62.137119223733" }, { "Time", 1, "Day", "Hour", "24" },
  { "Data", 1, "Gibibyte (GiB)", "Megabyte (MB)", "1073.741824" }, { "Data", 1, "Byte (B)", "Bit", "8" },
  { "Pressure", 1, "Atmosphere (atm)", "Bar", "1.01325" }, { "Energy", 1, "Kilowatt-hour (kWh)", "Joule (J)", "3600000" },
  { "Power", 1, "Horsepower (hp)", "Watt (W)", "745.69987158227" }, { "Angle", 180, "Degree", "Radian", "3.1415926535898" },
}

-- value, shown text
local SHOW = {
  { 1 / 3, "0.333" }, { 2 / 3, "0.667" }, { 24, "24" }, { 2.5, "2.5" }, { 0.1 + 0.2, "0.3" }, { 3.14159, "3.142" },
  { -1.23456, "-1.235" }, { 0, "0" }, { 0.0004, "4e-4" }, { 1 / 3000, "3.333e-4" }, { 1e20, "1e20" }, { 1234.5678, "1234.568" },
  { 0.001, "0.001" }, { 1e-7, "1e-7" },
}
-- expression, carried text, carried value, result
local CARRY = {
  { "0.333×3", "0.333", 1 / 3, "1" }, { "1/(0.333)", "0.333", 1 / 3, "3" }, { "-(0.333)*3", "0.333", 1 / 3, "-1" },
  { "-0.333*3", "0.333", 1 / 3, "-1" }, { "0.3333*3", "0.333", 1 / 3, "0.9999" }, { "10.333", "0.333", 1 / 3, "10.333" },
  { "0.333+0.333", "0.333", 1 / 3, "0.66633333333333" },
}

function T.run(E, CATS)
  local out, pass, failed = {}, 0, 0
  local function check(label, got, want)
    if got == want then pass += 1
    else
      failed += 1
      table.insert(out, "FAIL " .. label .. " got=" .. tostring(got) .. " want=" .. tostring(want))
    end
  end
  for _, t in NUM do
    local v, m = E.eval(t[1], { deg = true, ans = 41 })
    check(t[1], if v ~= nil then E.format(v) else m, t[2])
  end
  for _, t in RAD do
    local v, m = E.eval(t[1], { deg = false })
    check("rad " .. t[1], if v ~= nil then E.format(v) else m, t[2])
  end
  for _, t in BAD do
    local v, m = E.eval(t[1], { deg = true })
    check("bad '" .. t[1] .. "'", if v ~= nil then E.format(v) else m, t[2])
  end
  for _, t in GROUP do check("group " .. t[1], E.group(t[1]), t[2]) end
  for _, t in UNITS do
    local cat, a, b
    for _, c in CATS do if c.name == t[1] then cat = c end end
    for _, u in cat.units do
      if u[1] == t[3] then a = u end
      if u[1] == t[4] then b = u end
    end
    local base = if a.to then a.to(t[2]) else t[2] * a[2]
    check(t[1] .. " " .. t[3] .. ">" .. t[4], E.format(if b.back then b.back(base) else base / b[2]), t[5])
  end
  for _, t in SHOW do check("show " .. t[2], E.show(t[1]), t[2]) end
  for _, t in CARRY do
    local v, m = E.eval(E.substitute(t[1], { text = t[2], value = t[3] }), { deg = true })
    check("carry " .. t[1], if v ~= nil then E.format(v) else m, t[4])
  end
  table.insert(out, 1, string.format("pass=%d fail=%d", pass, failed))
  return table.concat(out, "\n") .. "\n"
end

return T
