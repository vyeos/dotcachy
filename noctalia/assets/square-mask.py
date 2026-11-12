# Rebuild fonts/noctalia-tabler.ttf from the stock Noctalia icon font with the
# "circle-filled" glyph (U+F671, the lock screen's password mark) redrawn as a square.
# Noctalia centres each mark in a cell one em wide, so the square's size sets the gap:
# SIDE 580 of 1000 leaves ~42% of the cell empty (the stock circle filled ~92%).
# Needs fontTools:  python square-mask.py   (writes next to this file, then update STOCK_SHA in
# ../bin/noctalia-start with: sha256sum /usr/share/noctalia/assets/fonts/noctalia-tabler.ttf)
import os
from fontTools.ttLib import TTFont
from fontTools.pens.ttGlyphPen import TTGlyphPen

SIDE = 580
here = os.path.dirname(os.path.abspath(__file__))
t = TTFont("/usr/share/noctalia/assets/fonts/noctalia-tabler.ttf")
name = t.getBestCmap()[0xF671]
glyf = t["glyf"]
old = glyf[name]
cx = 500                                  # em centre: Noctalia aligns the em, not the ink, horizontally
cy = round((old.yMin + old.yMax) / 2)     # keep the circle's vertical centre
h = SIDE // 2
x0, x1, y0, y1 = cx - h, cx + h, cy - h, cy + h
p = TTGlyphPen(None)
p.moveTo((x0, y0)); p.lineTo((x0, y1)); p.lineTo((x1, y1)); p.lineTo((x1, y0)); p.closePath()
glyf[name] = p.glyph()
glyf[name].recalcBounds(glyf)
adv, _ = t["hmtx"][name]
t["hmtx"][name] = (adv, x0)
out = os.path.join(here, "fonts", "noctalia-tabler.ttf")
t.save(out + ".tmp")
os.replace(out + ".tmp", out)             # never overwrite a font Noctalia has mmapped
print(name, (x0, y0, x1, y1))
