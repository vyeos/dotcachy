package main

// The Wedge shapes. Each is drawn on a 32-unit grid and fitted to the box the
// matching Bibata Modern Ice cursor fills (bibata.json, measured from its 48px
// frames), so every cursor is the size people are used to.

import (
	"fmt"
	"math"
	"regexp"
	"strconv"
	"strings"
)

var G = [10]string{"#0e0f10", "#151618", "#1c1d20", "#26282b", "#33363a", "#4b4f54", "#7a7f86", "#a6abb1", "#d3d6d9", "#ededeb"}

type pt [2]float64
type subpath []pt

// ── path geometry ──────────────────────────────────────────────────────────

var pathTok = regexp.MustCompile(`[MLHVZmlhvz]|-?\d*\.?\d+`)

// parse reads the path subset the shapes use: M L H V Z, h v.
func parse(d string) []subpath {
	var subs []subpath
	toks := pathTok.FindAllString(d, -1)
	var x, y float64
	cmd := ""
	cur := -1
	num := func(s string) float64 { v, _ := strconv.ParseFloat(s, 64); return v }
	for i := 0; i < len(toks); i++ {
		t := toks[i]
		if strings.ContainsAny(t[:1], "MLHVZmlhvz") {
			cmd = t
			if cmd == "Z" || cmd == "z" {
				cur = -1
			}
			continue
		}
		n := num(t)
		switch cmd {
		case "M":
			i++
			x, y = n, num(toks[i])
			subs = append(subs, subpath{{x, y}})
			cur = len(subs) - 1
			cmd = "L"
		case "L":
			i++
			x, y = n, num(toks[i])
			subs[cur] = append(subs[cur], pt{x, y})
		case "H":
			x = n
			subs[cur] = append(subs[cur], pt{x, y})
		case "V":
			y = n
			subs[cur] = append(subs[cur], pt{x, y})
		case "h":
			x += n
			subs[cur] = append(subs[cur], pt{x, y})
		case "v":
			y += n
			subs[cur] = append(subs[cur], pt{x, y})
		}
	}
	return subs
}

func mapPts(subs []subpath, fn func(pt) pt) []subpath {
	out := make([]subpath, len(subs))
	for i, s := range subs {
		out[i] = make(subpath, len(s))
		for j, p := range s {
			out[i][j] = fn(p)
		}
	}
	return out
}

func rotAround(deg, cx, cy float64) func(pt) pt {
	a := deg * math.Pi / 180
	c, s := math.Cos(a), math.Sin(a)
	return func(p pt) pt {
		return pt{cx + (p[0]-cx)*c - (p[1]-cy)*s, cy + (p[0]-cx)*s + (p[1]-cy)*c}
	}
}

// num prints like the original JS: rounded to 0.01, shortest form, no "-0".
func num(v float64) string {
	r := math.Floor(v*100+0.5) / 100
	if r == 0 {
		r = 0
	}
	return strconv.FormatFloat(r, 'f', -1, 64)
}

func jsNum(v float64) string {
	if v == 0 {
		v = 0
	}
	return strconv.FormatFloat(v, 'f', -1, 64)
}

func toD(subs []subpath, closed bool) string {
	parts := make([]string, len(subs))
	for i, s := range subs {
		pts := make([]string, len(s))
		for j, p := range s {
			pts[j] = num(p[0]) + "," + num(p[1])
		}
		parts[i] = "M" + strings.Join(pts, " L")
		if closed {
			parts[i] += " Z"
		}
	}
	return strings.Join(parts, " ")
}

func bboxOf(list [][]subpath) (x0, y0, w, h float64) {
	x0, y0 = 1e9, 1e9
	x1, y1 := -1e9, -1e9
	for _, subs := range list {
		for _, s := range subs {
			for _, p := range s {
				x0, y0 = math.Min(x0, p[0]), math.Min(y0, p[1])
				x1, y1 = math.Max(x1, p[0]), math.Max(y1, p[1])
			}
		}
	}
	return x0, y0, x1 - x0, y1 - y0
}

// ── shape library ──────────────────────────────────────────────────────────

var P = map[string]string{
	"wedge":       "M3,2 V20 L8.5,15 H17 Z",
	"wedgeR":      "M29,2 V20 L23.5,15 H15 Z",
	"up":          "M16,2 L25,26 L16,20.5 L7,26 Z",
	"help":        "M8,2 H24 V16 H18 V20 H13 V12 H19 V7 H13 V10 H8 Z M13,23 H18 V28 H13 Z",
	"hand":        "M10,3.5 L11,2.5 H13 L14,3.5 V11 H16.5 L17.5,12 H20 L21,13 H23 L24,14 V24 L21,28 H12 L8.5,23.5 L4.5,17.5 V16.5 L5.5,15.5 H7 L10,18 Z",
	"handLines":   "M14,11 V15.5 M17.5,12 V16 M21,13 V16.5",
	"open":        "M8,7 L9,6 H10.5 L11.5,7 V4 L12.5,3 H14 L15,4 V5 L16,4 H17.5 L18.5,5 V8.5 L19.5,7.5 H20.5 L21.5,8.5 V22 L18,28 H11 L7.5,24 L3,18.5 V17 L4,16 H5 L8,18.5 Z",
	"openLines":   "M11.5,7 V15 M15,5 V14.5 M18.5,8.5 V15",
	"fist":        "M8,11 L9,9.5 H11 L12,10.5 L13,9.5 H15 L16,10.5 L17,9.5 H19 L20,10.5 L21,9.5 H23 L24,11 V22 L21,26 H12 L8,22 Z",
	"fistLines":   "M12,10.5 V15 M16,10.5 V15 M20,10.5 V15 M8,15 H20.5 M8,19 H13.5 L15.5,21",
	"ibeam":       "M11,4 H21 V6.5 H17.25 V25.5 H21 V28 H11 V25.5 H14.75 V6.5 H11 Z",
	"gapcross":    "M15,3 H17 V12 H15 Z M15,20 H17 V29 H15 Z M3,15 H12 V17 H3 Z M20,15 H29 V17 H20 Z M15,15 H17 V17 H15 Z",
	"thincross":   "M15.25,4 H16.75 V15.25 H28 V16.75 H16.75 V28 H15.25 V16.75 H4 V15.25 H15.25 Z",
	"thickplus":   "M13,5 H19 V13 H27 V19 H19 V27 H13 V19 H5 V13 H13 Z",
	"longplus":    "M13.5,3 H18.5 V13.5 H29 V18.5 H18.5 V29 H13.5 V18.5 H3 V13.5 H13.5 Z",
	"block":       "M5,5 H27 V27 H5 Z M8,8 V24 H24 V8 Z M8,10.5 L10.5,8 L24,21.5 L21.5,24 Z",
	"target":      "M4,4 H28 V28 H4 Z M7,7 V25 H25 V7 Z M13,13 H19 V19 H13 Z",
	"ew":          "M2,16 L8,10 V14 H24 V10 L30,16 L24,22 V18 H8 V22 Z",
	"four":        "M16,2 L21,7 H18 V14 H25 V11 L30,16 L25,21 V18 H18 V25 H21 L16,30 L11,25 H14 V18 H7 V21 L2,16 L7,11 V14 H14 V7 H11 Z",
	"upArrow":     "M16,2 L25,11 H19 V30 H13 V11 H7 Z",
	"sideS":       "M4,26 H28 V29 H4 Z M16,23 L8,15 H13 V4 H19 V15 H24 Z",
	"cornerTL":    "M3,3 H20 V6 H6 V20 H3 Z M8,8 L18.25,10.47 L15.6,13.12 L23.38,20.9 L20.9,23.38 L13.12,15.6 L10.47,18.25 Z",
	"teeB":        "M14.5,4 H17.5 V25 H28 V28 H4 V25 H14.5 Z",
	"angleTL":     "M4,4 H28 V7.5 H7.5 V28 H4 Z",
	"pencil":      "M2,16 L9,11 H27 V21 H9 Z",
	"pencilLines": "M9,11 V21 M23,11 V21",
	"lens":        "M4,4 H22 V22 H4 Z M7,7 V19 H19 V7 Z M20,22.5 L22.5,20 L29,26.5 L26.5,29 Z",
	"lensPlus":    "M12,9.5 H14 V12 H16.5 V14 H14 V16.5 H12 V14 H9.5 V12 H12 Z",
	"lensMinus":   "M9.5,12 H16.5 V14 H9.5 Z",
	"wsquare":     "M4,4 H28 V28 H4 Z",
	"wglyph":      "M8,9 H11 L12.5,19 L15,12 H17 L19.5,19 L21,9 H24 L21,23 H18.5 L16,16 L13.5,23 H11 Z",
}

// part is one path of a cursor, with optional transforms applied in this order:
// scale+offset (s, dx, dy), rotation about rc, then the badge placement.
type part struct {
	d      string
	role   string
	open   bool
	s      float64 // 0 = no scale
	dx, dy float64
	rot    float64
	rc     *pt
	place  *placement
}

type placement struct {
	s, dx, dy float64
	abs       bool // already in final image space: not fitted to the Bibata box
}

func main_(d string) part { return part{d: d, role: "main"} }
func ink(d string) part   { return part{d: d, role: "inkLine", open: true} }

var ring = [8]pt{{0, 0}, {1, 0}, {2, 0}, {2, 1}, {2, 2}, {1, 2}, {0, 2}, {0, 1}}

func ringParts(lit []int, x0, y0, cell, gap float64, onRole, offRole string) []part {
	var on, off []string
	for i, c := range ring {
		x, y := x0+c[0]*(cell+gap), y0+c[1]*(cell+gap)
		sq := fmt.Sprintf("M%s,%s H%s V%s H%s Z", jsNum(x), jsNum(y), jsNum(x+cell), jsNum(y+cell), jsNum(x))
		isLit := false
		for _, l := range lit {
			isLit = isLit || l == i
		}
		if isLit {
			on = append(on, sq)
		} else {
			off = append(off, sq)
		}
	}
	return []part{{d: strings.Join(off, " "), role: offRole}, {d: strings.Join(on, " "), role: onRole}}
}

func litFor(f int) []int { return []int{f % 8, (f + 1) % 8, (f + 2) % 8} }

// Badges: a 13-unit square at (15,15) with a glyph; a placement moves the whole badge.
func glyph(kind string, frame int) []part {
	plus := "M20.5,17.5 H22.5 V20.5 H25.5 V22.5 H22.5 V25.5 H20.5 V22.5 H17.5 V20.5 H20.5 Z"
	switch kind {
	case "plus":
		return []part{{d: plus, role: "glyph"}}
	case "x":
		return []part{{d: plus, role: "glyph", rot: 45, rc: &pt{21.5, 21.5}}}
	case "help":
		return []part{{d: P["help"], role: "glyph", s: 0.3, dx: 16.7, dy: 17.3}}
	case "menu":
		return []part{{d: "M18,17.75 H25 V19.25 H18 Z M18,20.75 H25 V22.25 H18 Z M18,23.75 H25 V25.25 H18 Z", role: "glyph"}}
	case "link":
		return []part{{d: "M17.5,17.5 H23 V23 H17.5 Z M20,20 H25.5 V25.5 H20 Z", role: "glyphLine"}}
	case "move":
		return []part{{d: P["four"], role: "glyph", s: 0.3, dx: 16.7, dy: 16.7}}
	case "busy":
		return ringParts(litFor(frame), 16.5, 16.5, 3, 0.5, "glyph", "glyphDim")
	}
	panic("unknown glyph " + kind)
}

func badge(kind string, frame int, place *placement) []part {
	parts := append([]part{{d: "M15,15 H28 V28 H15 Z", role: "badge"}}, glyph(kind, frame)...)
	for i := range parts {
		parts[i].place = place
	}
	return parts
}

// at places a badge by its centre and size in the final 32-unit image (Bibata's spots).
func at(cx, cy, size float64) *placement {
	s := size / 13
	return &placement{s, cx - size/2 - 15*s, cy - size/2 - 15*s, true}
}

var (
	arrowBadge = at(20.7, 8.7, 13)    // top right, beside the arrow tip
	watchBadge = at(14.7, 19.7, 12.5) // low, over the arrow body
	fistBadge  = at(22.3, 21.6, 14)   // bottom right of the hand
)

// ── the set ────────────────────────────────────────────────────────────────

type cursor struct {
	name   string
	parts  func(frame int) []part
	hot    pt
	align  string // "", "tl", "tr", "top"
	same   string // reuse another cursor's fit
	rot    float64
	frames int
}

var cursors []*cursor
var byName = map[string]*cursor{}

func def(c cursor, parts ...part) {
	if c.parts == nil {
		c.parts = func(int) []part { return parts }
	}
	if c.frames == 0 {
		c.frames = 1
	}
	cp := c
	cursors = append(cursors, &cp)
	byName[c.name] = &cp
}

func with(base []part, more ...[]part) []part {
	out := append([]part{}, base...)
	for _, m := range more {
		out = append(out, m...)
	}
	return out
}

func init() {
	wedge := main_(P["wedge"])
	fist := []part{main_(P["fist"]), ink(P["fistLines"])}
	// pointers
	def(cursor{name: "left_ptr", hot: pt{3, 2}, align: "tl"}, wedge)
	def(cursor{name: "right_ptr", hot: pt{29, 2}, align: "tr"}, main_(P["wedgeR"]))
	def(cursor{name: "center_ptr", hot: pt{16, 2}, align: "top"}, main_(P["up"]))
	def(cursor{name: "question_arrow", hot: pt{8, 2}}, main_(P["help"]))
	def(cursor{name: "left_ptr_watch", hot: pt{3, 2}, same: "left_ptr", frames: 8,
		parts: func(f int) []part { return with([]part{wedge}, badge("busy", f, watchBadge)) }})
	def(cursor{name: "wait", hot: pt{16, 16}, frames: 8,
		parts: func(f int) []part { return ringParts(litFor(f), 5, 5, 6, 2, "main", "dim") }})
	for _, b := range [][2]string{{"context-menu", "menu"}, {"copy", "plus"}, {"link", "link"}, {"pointer-move", "move"}, {"circle", "x"}} {
		def(cursor{name: b[0], hot: pt{3, 2}, same: "left_ptr"}, with([]part{wedge}, badge(b[1], 0, arrowBadge))...)
	}
	def(cursor{name: "crossed_circle", hot: pt{16, 16}}, main_(P["block"]))
	// hands
	def(cursor{name: "hand2", hot: pt{12, 2.5}, align: "top"}, main_(P["hand"]), ink(P["handLines"]))
	def(cursor{name: "hand1", hot: pt{14, 15}}, main_(P["open"]), ink(P["openLines"]))
	def(cursor{name: "grabbing", hot: pt{16, 16}}, fist...)
	for _, b := range [][2]string{{"dnd-ask", "help"}, {"dnd-copy", "plus"}, {"dnd-link", "link"}, {"dnd_no_drop", "x"}} {
		def(cursor{name: b[0], hot: pt{16, 16}, same: "grabbing"}, with(fist, badge(b[1], 0, fistBadge))...)
	}
	// text
	def(cursor{name: "xterm", hot: pt{16, 16}}, main_(P["ibeam"]))
	def(cursor{name: "vertical-text", hot: pt{16, 16}, rot: 90}, main_(P["ibeam"]))
	// window edges
	for _, e := range []struct {
		n string
		r float64
	}{{"top_side", 180}, {"bottom_side", 0}, {"left_side", 90}, {"right_side", 270}} {
		def(cursor{name: e.n, hot: pt{16, 27.5}, rot: e.r}, main_(P["sideS"]))
	}
	for _, e := range []struct {
		n string
		r float64
	}{{"top_left_corner", 0}, {"top_right_corner", 90}, {"bottom_right_corner", 180}, {"bottom_left_corner", 270}} {
		def(cursor{name: e.n, hot: pt{4.5, 4.5}, rot: e.r}, main_(P["cornerTL"]))
	}
	// two-way
	for _, e := range []struct {
		n string
		r float64
	}{{"sb_h_double_arrow", 0}, {"sb_v_double_arrow", 90}, {"bd_double_arrow", 45}, {"fd_double_arrow", -45}} {
		def(cursor{name: e.n, hot: pt{16, 16}, rot: e.r}, main_(P["ew"]))
	}
	def(cursor{name: "move", hot: pt{16, 16}}, main_(P["four"]))
	// single arrows
	for _, e := range []struct {
		n string
		r float64
	}{{"sb_up_arrow", 0}, {"sb_right_arrow", 90}, {"sb_down_arrow", 180}, {"sb_left_arrow", 270}} {
		def(cursor{name: e.n, hot: pt{16, 2}, rot: e.r}, main_(P["upArrow"]))
	}
	// tees and angles
	for _, e := range []struct {
		n string
		r float64
	}{{"top_tee", 180}, {"bottom_tee", 0}, {"left_tee", 270}, {"right_tee", 90}} {
		def(cursor{name: e.n, hot: pt{16, 26.5}, rot: e.r}, main_(P["teeB"]))
	}
	for _, e := range []struct {
		n string
		r float64
	}{{"ul_angle", 0}, {"ur_angle", 90}, {"lr_angle", 180}, {"ll_angle", 270}} {
		def(cursor{name: e.n, hot: pt{5.75, 5.75}, rot: e.r}, main_(P["angleTL"]))
	}
	// precision and tools
	def(cursor{name: "crosshair", hot: pt{16, 16}}, main_(P["gapcross"]))
	def(cursor{name: "cross", hot: pt{16, 16}}, main_(P["gapcross"]))
	def(cursor{name: "tcross", hot: pt{16, 16}}, main_(P["thincross"]))
	def(cursor{name: "plus", hot: pt{16, 16}}, main_(P["thickplus"]))
	def(cursor{name: "dotbox", hot: pt{16, 16}}, main_(P["target"]))
	def(cursor{name: "X_cursor", hot: pt{16, 16}, rot: 45}, main_(P["longplus"]))
	def(cursor{name: "pencil", hot: pt{2, 16}, rot: -45}, main_(P["pencil"]), ink(P["pencilLines"]))
	def(cursor{name: "zoom-in", hot: pt{13, 13}}, main_(P["lens"]), main_(P["lensPlus"]))
	def(cursor{name: "zoom-out", hot: pt{13, 13}}, main_(P["lens"]), main_(P["lensMinus"]))
	def(cursor{name: "wayland-cursor", hot: pt{16, 16}}, main_(P["wsquare"]), part{d: P["wglyph"], role: "ink"})
}

// ── fit and render ─────────────────────────────────────────────────────────

type style struct {
	fill, stroke string
	sw           float64
}

var styles = map[string]style{
	"main":      {G[8], G[0], 1.25},
	"dim":       {G[5], G[0], 1.25},
	"badge":     {G[1], G[8], 1},
	"glyph":     {G[9], "", 0},
	"glyphDim":  {G[5], "", 0},
	"glyphLine": {"", G[9], 1.4},
	"ink":       {G[0], "", 0},
	"inkLine":   {"", G[0], 1.25},
}

type rawPart struct {
	subs []subpath
	role string
	open bool
	abs  bool
}

func rawParts(c *cursor, frame int) []rawPart {
	var out []rawPart
	for _, p := range c.parts(frame) {
		subs := parse(p.d)
		if p.s != 0 {
			s, dx, dy := p.s, p.dx, p.dy
			subs = mapPts(subs, func(q pt) pt { return pt{q[0]*s + dx, q[1]*s + dy} })
		}
		if p.rot != 0 {
			c := pt{16, 16}
			if p.rc != nil {
				c = *p.rc
			}
			subs = mapPts(subs, rotAround(p.rot, c[0], c[1]))
		}
		if p.place != nil {
			pl := p.place
			subs = mapPts(subs, func(q pt) pt { return pt{q[0]*pl.s + pl.dx, q[1]*pl.s + pl.dy} })
		}
		if c.rot != 0 {
			subs = mapPts(subs, rotAround(c.rot, 16, 16))
		}
		out = append(out, rawPart{subs, p.role, p.open, p.place != nil && p.place.abs})
	}
	return out
}

type fit struct{ s, tx, ty float64 }

var fitCache = map[string]fit{}

func fitOf(c *cursor) fit {
	if f, ok := fitCache[c.name]; ok {
		return f
	}
	if c.same != "" {
		f := fitOf(byName[c.same])
		fitCache[c.name] = f
		return f
	}
	var list [][]subpath
	for _, p := range rawParts(c, 0) {
		if !p.abs {
			list = append(list, p.subs)
		}
	}
	sx, sy, sw, sh := bboxOf(list)
	b := bibata[c.name].Box
	tx, ty, tw, th := b[0]/1.5, b[1]/1.5, b[2]/1.5, b[3]/1.5
	s := math.Min(tw/sw, th/sh)
	ox, oy := tx+(tw-sw*s)/2, ty+(th-sh*s)/2
	if c.align == "tl" || c.align == "top" {
		oy = ty
	}
	if c.align == "tl" {
		ox = tx
	}
	if c.align == "tr" {
		ox, oy = tx+tw-sw*s, ty
	}
	f := fit{s, ox - sx*s, oy - sy*s}
	fitCache[c.name] = f
	return f
}

func hotOf(c *cursor) pt {
	p := c.hot
	if c.rot != 0 {
		p = rotAround(c.rot, 16, 16)(p)
	}
	f := fitOf(c)
	return pt{p[0]*f.s + f.tx, p[1]*f.s + f.ty}
}

func svgOf(c *cursor, size, frame int) string {
	f := fitOf(c)
	var body strings.Builder
	for _, p := range rawParts(c, frame) {
		subs := p.subs
		if !p.abs {
			subs = mapPts(subs, func(q pt) pt { return pt{q[0]*f.s + f.tx, q[1]*f.s + f.ty} })
		}
		st := styles[p.role]
		fill, stroke := st.fill, st.stroke
		if fill == "" {
			fill = "none"
		}
		if stroke == "" {
			stroke = "none"
		}
		fmt.Fprintf(&body, `<path d="%s" fill="%s" stroke="%s" stroke-width="%s" stroke-linejoin="miter" stroke-miterlimit="10"/>`,
			toD(subs, !p.open), fill, stroke, jsNum(st.sw))
	}
	return fmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 32 32">%s</svg>`, size, size, body.String())
}
