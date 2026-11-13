// Command square-mask rebuilds ../fonts/noctalia-tabler.ttf from the stock Noctalia
// icon font with the "circle-filled" glyph (U+F671, the lock screen's password mark)
// redrawn as a square, then points noctalia-start's STOCK_SHA at the stock font it
// was built from.
//
//	cd ~/.config/noctalia/assets/square-mask && go run .
//
// Noctalia centres each mark in a cell one em wide, so the square's size sets the gap:
// side 580 of 1000 leaves ~42% of the cell empty (the stock circle filled ~92%).
//
// Standard library only: the font is patched in place at the table level. Every other
// glyph keeps its original bytes; glyf, loca and hmtx are rewritten, and the table
// checksums and head.checkSumAdjustment recomputed.
package main

import (
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
)

const (
	stockFont = "/usr/share/noctalia/assets/fonts/noctalia-tabler.ttf"
	mark      = 0xF671 // circle-filled
)

func main() {
	cfg := os.Getenv("XDG_CONFIG_HOME")
	if cfg == "" {
		home, _ := os.UserHomeDir()
		cfg = filepath.Join(home, ".config")
	}
	side := flag.Int("side", 580, "square side in font units (em = 1000); smaller = wider gap")
	out := flag.String("out", filepath.Join(cfg, "noctalia/assets/fonts/noctalia-tabler.ttf"), "font to write")
	start := flag.String("start", filepath.Join(cfg, "noctalia/bin/noctalia-start"), "script whose STOCK_SHA to update (\"\" to skip)")
	flag.Parse()

	stock, err := os.ReadFile(stockFont)
	check(err)
	font, box, err := squareMark(stock, *side)
	check(err)
	// Never overwrite a font Noctalia has mmapped: write beside it and rename.
	check(os.WriteFile(*out+".tmp", font, 0o644))
	check(os.Rename(*out+".tmp", *out))
	fmt.Printf("U+%X -> square %v, wrote %s\n", mark, box, *out)

	if *start != "" {
		sum := sha256.Sum256(stock)
		check(setStockSHA(*start, hex.EncodeToString(sum[:])))
	}
}

func check(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, "square-mask:", err)
		os.Exit(1)
	}
}

func setStockSHA(path, sha string) error {
	raw, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	re := regexp.MustCompile(`(?m)^STOCK_SHA=[0-9a-f]*$`)
	if !re.Match(raw) {
		return errors.New("no STOCK_SHA= line in " + path)
	}
	edited := re.ReplaceAll(raw, []byte("STOCK_SHA="+sha))
	if string(edited) == string(raw) {
		fmt.Println("STOCK_SHA already current")
		return nil
	}
	info, err := os.Stat(path)
	if err != nil {
		return err
	}
	if err := os.WriteFile(path+".tmp", edited, info.Mode().Perm()); err != nil {
		return err
	}
	fmt.Println("STOCK_SHA set to", sha)
	return os.Rename(path+".tmp", path)
}

// ── TrueType ───────────────────────────────────────────────────────────────

var be = binary.BigEndian

type table struct {
	tag  string
	data []byte
}

func readTables(f []byte) (uint32, []table, error) {
	if len(f) < 12 {
		return 0, nil, errors.New("not a font")
	}
	version := be.Uint32(f)
	n := int(be.Uint16(f[4:]))
	var ts []table
	for i := 0; i < n; i++ {
		r := f[12+16*i:]
		off, length := be.Uint32(r[8:]), be.Uint32(r[12:])
		if int(off+length) > len(f) {
			return 0, nil, errors.New("table out of range")
		}
		ts = append(ts, table{string(r[:4]), f[off : off+length]})
	}
	return version, ts, nil
}

func find(ts []table, tag string) []byte {
	for _, t := range ts {
		if t.tag == tag {
			return t.data
		}
	}
	return nil
}

func set(ts []table, tag string, data []byte) {
	for i := range ts {
		if ts[i].tag == tag {
			ts[i].data = data
		}
	}
}

// glyphFor looks a code point up in the cmap (format 12, else format 4).
func glyphFor(cmap []byte, cp uint32) (int, error) {
	n := int(be.Uint16(cmap[2:]))
	var f4 []byte
	for i := 0; i < n; i++ {
		rec := cmap[4+8*i:]
		sub := cmap[be.Uint32(rec[4:]):]
		switch be.Uint16(sub) {
		case 12:
			groups := int(be.Uint32(sub[12:]))
			for g := 0; g < groups; g++ {
				gr := sub[16+12*g:]
				lo, hi, start := be.Uint32(gr), be.Uint32(gr[4:]), be.Uint32(gr[8:])
				if cp >= lo && cp <= hi {
					return int(start + cp - lo), nil
				}
			}
		case 4:
			f4 = sub
		}
	}
	if f4 != nil && cp <= 0xFFFF {
		segs := int(be.Uint16(f4[6:])) / 2
		ends, starts := f4[14:], f4[16+2*segs:]
		deltas, ranges := f4[16+4*segs:], f4[16+6*segs:]
		for s := 0; s < segs; s++ {
			end, start := uint32(be.Uint16(ends[2*s:])), uint32(be.Uint16(starts[2*s:]))
			if cp < start || cp > end {
				continue
			}
			delta, ro := be.Uint16(deltas[2*s:]), int(be.Uint16(ranges[2*s:]))
			if ro == 0 {
				return int(uint16(cp) + delta), nil
			}
			at := 16 + 6*segs + 2*s + ro + 2*int(cp-start)
			g := be.Uint16(f4[at:])
			if g == 0 {
				return 0, nil
			}
			return int(g + delta), nil
		}
	}
	return 0, fmt.Errorf("U+%X not in the font", cp)
}

// squareMark returns the font with the mark's glyph replaced by a square of the given side,
// centred on the em horizontally and on the old glyph vertically.
func squareMark(f []byte, side int) ([]byte, [4]int, error) {
	var box [4]int
	version, ts, err := readTables(f)
	if err != nil {
		return nil, box, err
	}
	head, maxp, hhea := find(ts, "head"), find(ts, "maxp"), find(ts, "hhea")
	cmap, loca, glyf, hmtx := find(ts, "cmap"), find(ts, "loca"), find(ts, "glyf"), find(ts, "hmtx")
	if head == nil || maxp == nil || hhea == nil || cmap == nil || loca == nil || glyf == nil || hmtx == nil {
		return nil, box, errors.New("not a glyf-based TrueType font")
	}
	gid, err := glyphFor(cmap, mark)
	if err != nil {
		return nil, box, err
	}
	numGlyphs := int(be.Uint16(maxp[4:]))
	long := be.Uint16(head[50:]) == 1
	offsets := make([]uint32, numGlyphs+1)
	for i := range offsets {
		if long {
			offsets[i] = be.Uint32(loca[4*i:])
		} else {
			offsets[i] = uint32(be.Uint16(loca[2*i:])) * 2
		}
	}
	old := glyf[offsets[gid]:offsets[gid+1]]
	if len(old) < 10 {
		return nil, box, errors.New("the mark's glyph is empty")
	}
	yMin, yMax := int(int16(be.Uint16(old[4:]))), int(int16(be.Uint16(old[8:])))
	cx := 500                             // em centre: Noctalia aligns the em, not the ink
	cy := int(float64(yMin+yMax)/2 + 0.5) // keep the circle's vertical centre
	h := side / 2
	x0, x1, y0, y1 := cx-h, cx+h, cy-h, cy+h
	box = [4]int{x0, y0, x1, y1}

	// One contour, four on-curve points: (x0,y0) (x0,y1) (x1,y1) (x1,y0), clockwise.
	var g []byte
	g = be.AppendUint16(g, 1)
	for _, v := range []int{x0, y0, x1, y1} {
		g = be.AppendUint16(g, uint16(int16(v)))
	}
	g = be.AppendUint16(g, 3) // last point index
	g = be.AppendUint16(g, 0) // no instructions
	g = append(g, 1, 1, 1, 1) // on curve, 16-bit x and y deltas
	px, py := []int{x0, x0, x1, x1}, []int{y0, y1, y1, y0}
	for _, ds := range [][]int{px, py} {
		prev := 0
		for _, v := range ds {
			g = be.AppendUint16(g, uint16(int16(v-prev)))
			prev = v
		}
	}
	for len(g)%4 != 0 {
		g = append(g, 0)
	}

	// glyf and loca: every other glyph's bytes are copied unchanged.
	var nglyf []byte
	nofs := make([]uint32, numGlyphs+1)
	for i := 0; i < numGlyphs; i++ {
		nofs[i] = uint32(len(nglyf))
		if i == gid {
			nglyf = append(nglyf, g...)
		} else {
			nglyf = append(nglyf, glyf[offsets[i]:offsets[i+1]]...)
			for len(nglyf)%2 != 0 { // short loca needs even offsets
				nglyf = append(nglyf, 0)
			}
		}
	}
	nofs[numGlyphs] = uint32(len(nglyf))
	if !long && nofs[numGlyphs]/2 > 0xFFFF {
		long = true
	}
	var nloca []byte
	for _, o := range nofs {
		if long {
			nloca = be.AppendUint32(nloca, o)
		} else {
			nloca = be.AppendUint16(nloca, uint16(o/2))
		}
	}
	nhead := append([]byte{}, head...)
	hhea = append([]byte{}, hhea...)
	if long {
		be.PutUint16(nhead[50:], 1)
	}

	// hmtx: left side bearing = x0, advance unchanged.
	nhmtx := append([]byte{}, hmtx...)
	numH := int(be.Uint16(hhea[34:]))
	if gid < numH {
		be.PutUint16(nhmtx[4*gid+2:], uint16(int16(x0)))
	} else {
		be.PutUint16(nhmtx[4*numH+2*(gid-numH):], uint16(int16(x0)))
	}

	recalcBounds(nhead, hhea, nhmtx, nglyf, nofs, numH)

	set(ts, "glyf", nglyf)
	set(ts, "loca", nloca)
	set(ts, "hmtx", nhmtx)
	set(ts, "head", nhead)
	set(ts, "hhea", hhea)
	return writeFont(version, ts), box, nil
}

// recalcBounds redoes the font-wide extents the way fontTools does when it saves:
// head's bounding box and hhea's side-bearing and extent fields, from every glyph.
func recalcBounds(head, hhea, hmtx, glyf []byte, offs []uint32, numH int) {
	i16 := func(b []byte) int { return int(int16(be.Uint16(b))) }
	xMin, yMin, xMax, yMax := 1<<30, 1<<30, -1<<30, -1<<30
	advMax, minL, minR, extMax := 0, 1<<30, 1<<30, -1<<30
	lastAdv := 0
	for g := 0; g+1 < len(offs); g++ {
		adv, lsb := lastAdv, 0
		if g < numH {
			adv, lsb = int(be.Uint16(hmtx[4*g:])), i16(hmtx[4*g+2:])
			lastAdv = adv
		} else {
			lsb = i16(hmtx[4*numH+2*(g-numH):])
		}
		advMax = max(advMax, adv)
		gl := glyf[offs[g]:offs[g+1]]
		if len(gl) < 10 || i16(gl) == 0 {
			continue // empty glyph: no bounds
		}
		x0, y0, x1, y1 := i16(gl[2:]), i16(gl[4:]), i16(gl[6:]), i16(gl[8:])
		xMin, yMin, xMax, yMax = min(xMin, x0), min(yMin, y0), max(xMax, x1), max(yMax, y1)
		minL = min(minL, lsb)
		minR = min(minR, adv-lsb-(x1-x0))
		extMax = max(extMax, lsb+(x1-x0))
	}
	for i, v := range []int{xMin, yMin, xMax, yMax} {
		be.PutUint16(head[36+2*i:], uint16(int16(v)))
	}
	be.PutUint16(hhea[10:], uint16(advMax))
	for i, v := range []int{minL, minR, extMax} {
		be.PutUint16(hhea[12+2*i:], uint16(int16(v)))
	}
}

func checksum(b []byte) uint32 {
	var sum uint32
	for i := 0; i < len(b); i += 4 {
		var w [4]byte
		copy(w[:], b[i:])
		sum += be.Uint32(w[:])
	}
	return sum
}

func writeFont(version uint32, ts []table) []byte {
	sort.Slice(ts, func(i, j int) bool { return ts[i].tag < ts[j].tag })
	n := len(ts)
	es, sr := 0, 1
	for sr*2 <= n {
		sr *= 2
		es++
	}
	out := be.AppendUint32(nil, version)
	out = be.AppendUint16(out, uint16(n))
	out = be.AppendUint16(out, uint16(sr*16))
	out = be.AppendUint16(out, uint16(es))
	out = be.AppendUint16(out, uint16(n*16-sr*16))
	off := 12 + 16*n
	headAt := -1
	var body []byte
	for _, t := range ts {
		data := t.data
		if t.tag == "head" {
			data = append([]byte{}, data...)
			be.PutUint32(data[8:], 0) // checkSumAdjustment is computed last
			headAt = off + len(body)
		}
		out = append(out, t.tag...)
		out = be.AppendUint32(out, checksum(data))
		out = be.AppendUint32(out, uint32(off+len(body)))
		out = be.AppendUint32(out, uint32(len(data)))
		body = append(body, data...)
		for len(body)%4 != 0 {
			body = append(body, 0)
		}
	}
	out = append(out, body...)
	if headAt >= 0 {
		be.PutUint32(out[headAt+8:], 0xB1B0AFBA-checksum(out))
	}
	return out
}
