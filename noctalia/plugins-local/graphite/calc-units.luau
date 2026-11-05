--!nonstrict
-- Conversion tables. Each unit is { label, factor to the category's base unit }.
-- Temperature is not a plain ratio, so its units carry to/from functions instead.

local PI = math.pi

return {
  { name = "Length", from = 5, to = 8, units = {
    { "Nanometre (nm)", 1e-9 }, { "Micrometre (µm)", 1e-6 }, { "Millimetre (mm)", 1e-3 }, { "Centimetre (cm)", 0.01 },
    { "Metre (m)", 1 }, { "Kilometre (km)", 1000 }, { "Inch (in)", 0.0254 }, { "Foot (ft)", 0.3048 },
    { "Yard (yd)", 0.9144 }, { "Mile (mi)", 1609.344 }, { "Nautical mile", 1852 },
  } },
  { name = "Area", from = 3, to = 7, units = {
    { "Square mm", 1e-6 }, { "Square cm", 1e-4 }, { "Square metre", 1 }, { "Hectare", 1e4 }, { "Square km", 1e6 },
    { "Square inch", 6.4516e-4 }, { "Square foot", 0.09290304 }, { "Square yard", 0.83612736 },
    { "Acre", 4046.8564224 }, { "Square mile", 2589988.110336 },
  } },
  { name = "Volume", from = 2, to = 10, units = {
    { "Millilitre (mL)", 0.001 }, { "Litre (L)", 1 }, { "Cubic metre (m³)", 1000 },
    { "Teaspoon (US)", 0.00492892159375 }, { "Tablespoon (US)", 0.01478676478125 }, { "Fluid ounce (US)", 0.0295735295625 },
    { "Cup (US)", 0.2365882365 }, { "Pint (US)", 0.473176473 }, { "Quart (US)", 0.946352946 },
    { "Gallon (US)", 3.785411784 }, { "Gallon (UK)", 4.54609 },
  } },
  { name = "Mass", from = 3, to = 6, units = {
    { "Milligram (mg)", 1e-6 }, { "Gram (g)", 0.001 }, { "Kilogram (kg)", 1 }, { "Tonne (t)", 1000 },
    { "Ounce (oz)", 0.028349523125 }, { "Pound (lb)", 0.45359237 }, { "Stone (st)", 6.35029318 }, { "Carat (ct)", 0.0002 },
  } },
  { name = "Temperature", from = 1, to = 2, units = {
    { "Celsius (°C)", to = function(x) return x end, back = function(x) return x end },
    { "Fahrenheit (°F)", to = function(x) return (x - 32) * 5 / 9 end, back = function(x) return x * 9 / 5 + 32 end },
    { "Kelvin (K)", to = function(x) return x - 273.15 end, back = function(x) return x + 273.15 end },
  } },
  { name = "Speed", from = 2, to = 3, units = {
    { "Metre/second", 1 }, { "Kilometre/hour", 1 / 3.6 }, { "Mile/hour", 0.44704 },
    { "Knot", 1852 / 3600 }, { "Foot/second", 0.3048 },
  } },
  { name = "Time", from = 3, to = 2, units = {
    { "Millisecond", 0.001 }, { "Second", 1 }, { "Minute", 60 }, { "Hour", 3600 }, { "Day", 86400 },
    { "Week", 604800 }, { "Year (365.25 d)", 31557600 },
  } },
  { name = "Data", from = 5, to = 4, units = {
    { "Bit", 0.125 }, { "Byte (B)", 1 }, { "Kilobyte (KB)", 1e3 }, { "Megabyte (MB)", 1e6 }, { "Gigabyte (GB)", 1e9 },
    { "Terabyte (TB)", 1e12 }, { "Petabyte (PB)", 1e15 }, { "Kibibyte (KiB)", 1024 }, { "Mebibyte (MiB)", 1048576 },
    { "Gibibyte (GiB)", 1073741824 }, { "Tebibyte (TiB)", 1099511627776 },
  } },
  { name = "Pressure", from = 3, to = 5, units = {
    { "Pascal (Pa)", 1 }, { "Kilopascal (kPa)", 1000 }, { "Bar", 1e5 }, { "Atmosphere (atm)", 101325 },
    { "PSI", 6894.757293168 }, { "mmHg", 133.322387415 },
  } },
  { name = "Energy", from = 4, to = 6, units = {
    { "Joule (J)", 1 }, { "Kilojoule (kJ)", 1000 }, { "Calorie (cal)", 4.184 }, { "Kilocalorie (kcal)", 4184 },
    { "Watt-hour (Wh)", 3600 }, { "Kilowatt-hour (kWh)", 3.6e6 }, { "BTU", 1055.05585262 }, { "Electronvolt (eV)", 1.602176634e-19 },
  } },
  { name = "Power", from = 2, to = 4, units = {
    { "Watt (W)", 1 }, { "Kilowatt (kW)", 1000 }, { "Megawatt (MW)", 1e6 }, { "Horsepower (hp)", 745.69987158227 },
  } },
  { name = "Angle", from = 1, to = 2, units = {
    { "Degree", 1 }, { "Radian", 180 / PI }, { "Gradian", 0.9 }, { "Turn", 360 }, { "Arcminute", 1 / 60 }, { "Arcsecond", 1 / 3600 },
  } },
}
