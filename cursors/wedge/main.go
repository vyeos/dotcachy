// Command wedge builds the Graphite-Wedge cursor theme (Xcursor + hyprcursor) and installs it.
//
//	go run .              build and install to ~/.local/share/icons/Graphite-Wedge
//	go run . -out DIR     build into DIR/Graphite-Wedge instead
//	go run . -svg DIR     only write each cursor's SVG frames to DIR (for checking shapes)
//
// Standard library only. Needs rsvg-convert (draws the PNG frames) and
// hyprcursor-util (packs the hyprcursor files), both already on the system.
package main

import (
	"bytes"
	_ "embed"
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"image"
	"image/png"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

const themeName = "Graphite-Wedge"

// Same nominal sizes as Bibata.
var sizes = []int{16, 20, 22, 24, 28, 32, 40, 48, 56, 64, 72, 80, 88, 96}

const frameDelay = 110 // ms, for the animated busy cursors

//go:embed bibata.json
var bibataJSON []byte

// bibata holds, per cursor, the box Bibata Modern Ice fills at 48px and the names it links to it.
var bibata map[string]struct {
	Box     [4]float64 `json:"box"`
	Aliases []string   `json:"aliases"`
}

func init() {
	if err := json.Unmarshal(bibataJSON, &bibata); err != nil {
		panic(err)
	}
}

func main() {
	out := flag.String("out", "", "install into this folder instead of ~/.local/share/icons")
	svgDir := flag.String("svg", "", "only write SVG frames to this folder")
	flag.Parse()

	if *svgDir != "" {
		check(writeSVGs(*svgDir))
		fmt.Println(len(cursors), "cursors")
		return
	}
	dest := *out
	if dest == "" {
		home, _ := os.UserHomeDir()
		dest = filepath.Join(home, ".local/share/icons")
	}
	check(os.MkdirAll(dest, 0o755))
	tmp, err := os.MkdirTemp(dest, ".wedge-") // same filesystem as dest, so the build can be moved in place
	check(err)
	defer os.RemoveAll(tmp)
	check(build(tmp, dest))
	fmt.Println("installed", filepath.Join(dest, themeName), fmt.Sprintf("(%d shapes)", len(cursors)))
}

func check(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, "wedge:", err)
		os.Exit(1)
	}
}

func writeSVGs(dir string) error {
	for _, c := range cursors {
		d := filepath.Join(dir, c.name)
		if err := os.MkdirAll(d, 0o755); err != nil {
			return err
		}
		for f := 0; f < c.frames; f++ {
			if err := os.WriteFile(filepath.Join(d, fmt.Sprintf("%d.svg", f)), []byte(svgOf(c, 32, f)), 0o644); err != nil {
				return err
			}
		}
	}
	return nil
}

func aliasesOf(name string) []string {
	var out []string
	for _, a := range bibata[name].Aliases {
		if a != name {
			out = append(out, a)
		}
	}
	sort.Strings(out)
	return out
}

func clampHot(v float64, size int) uint32 {
	h := int(v*float64(size)/32 + 0.5)
	return uint32(max(0, min(size-1, h)))
}

// render draws one SVG frame at size x size and returns premultiplied ARGB pixels.
func render(svg string, size int) ([]byte, error) {
	cmd := exec.Command("rsvg-convert", "-w", fmt.Sprint(size), "-h", fmt.Sprint(size))
	cmd.Stdin = strings.NewReader(svg)
	raw, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("rsvg-convert: %w", err)
	}
	img, err := png.Decode(bytes.NewReader(raw))
	if err != nil {
		return nil, err
	}
	return argb(img, size), nil
}

func argb(img image.Image, size int) []byte {
	px := make([]byte, 0, size*size*4)
	b := img.Bounds()
	for y := 0; y < size; y++ {
		for x := 0; x < size; x++ {
			r, g, bl, a := img.At(b.Min.X+x, b.Min.Y+y).RGBA() // already premultiplied, 16-bit
			px = binary.LittleEndian.AppendUint32(px, (a>>8)<<24|(r>>8)<<16|(g>>8)<<8|bl>>8)
		}
	}
	return px
}

type xImage struct {
	size, xhot, yhot, delay uint32
	px                      []byte
}

// xcursorFile encodes images in the Xcursor format (one image chunk per size and frame).
func xcursorFile(images []xImage) []byte {
	const header, tocEntry, chunkHeader, imageType = 16, 12, 36, 0xFFFD0002
	var buf bytes.Buffer
	le := func(v ...uint32) {
		for _, x := range v {
			binary.Write(&buf, binary.LittleEndian, x)
		}
	}
	buf.WriteString("Xcur")
	le(header, 0x10000, uint32(len(images)))
	pos := uint32(header + tocEntry*len(images))
	for _, im := range images {
		le(imageType, im.size, pos)
		pos += chunkHeader + uint32(len(im.px))
	}
	for _, im := range images {
		le(chunkHeader, imageType, im.size, 1, im.size, im.size, im.xhot, im.yhot, im.delay)
		buf.Write(im.px)
	}
	return buf.Bytes()
}

func build(tmp, dest string) error {
	if err := os.MkdirAll(dest, 0o755); err != nil {
		return err
	}
	// Build next to the final folder, then swap, so a running session never reads a half-written theme.
	final := filepath.Join(dest, themeName)
	theme := final + ".new"
	os.RemoveAll(theme)
	defer os.RemoveAll(theme)
	xdir := filepath.Join(theme, "cursors")
	if err := os.MkdirAll(xdir, 0o755); err != nil {
		return err
	}

	// Xcursor
	for _, c := range cursors {
		hot := hotOf(c)
		var images []xImage
		for _, size := range sizes {
			for f := 0; f < c.frames; f++ {
				px, err := render(svgOf(c, 32, f), size)
				if err != nil {
					return fmt.Errorf("%s: %w", c.name, err)
				}
				delay := uint32(0)
				if c.frames > 1 {
					delay = frameDelay
				}
				images = append(images, xImage{uint32(size), clampHot(hot[0], size), clampHot(hot[1], size), delay, px})
			}
		}
		if err := os.WriteFile(filepath.Join(xdir, c.name), xcursorFile(images), 0o644); err != nil {
			return err
		}
		for _, a := range aliasesOf(c.name) {
			if _, err := os.Lstat(filepath.Join(xdir, a)); err == nil {
				continue
			}
			if err := os.Symlink(c.name, filepath.Join(xdir, a)); err != nil {
				return err
			}
		}
	}

	// hyprcursor: SVG frames, so it stays sharp at any size
	src := filepath.Join(tmp, "hypr-src")
	if err := os.MkdirAll(filepath.Join(src, "hyprcursors"), 0o755); err != nil {
		return err
	}
	manifest := fmt.Sprintf("name = %s\ndescription = Graphite wedge cursors\nversion = 1\ncursors_directory = hyprcursors\n", themeName)
	if err := os.WriteFile(filepath.Join(src, "manifest.hl"), []byte(manifest), 0o644); err != nil {
		return err
	}
	for _, c := range cursors {
		d := filepath.Join(src, "hyprcursors", c.name)
		if err := os.MkdirAll(d, 0o755); err != nil {
			return err
		}
		hot := hotOf(c)
		meta := []string{"resize_algorithm = none", fmt.Sprintf("hotspot_x = %.3f", hot[0]/32), fmt.Sprintf("hotspot_y = %.3f", hot[1]/32), ""}
		for f := 0; f < c.frames; f++ {
			file := fmt.Sprintf("%s-%d.svg", c.name, f)
			if err := os.WriteFile(filepath.Join(d, file), []byte(svgOf(c, 32, f)), 0o644); err != nil {
				return err
			}
			delay := 0
			if c.frames > 1 {
				delay = frameDelay
			}
			meta = append(meta, fmt.Sprintf("define_size = 0, %s, %d", file, delay))
		}
		meta = append(meta, "")
		for _, a := range aliasesOf(c.name) {
			meta = append(meta, "define_override = "+a)
		}
		if err := os.WriteFile(filepath.Join(d, "meta.hl"), []byte(strings.Join(meta, "\n")+"\n"), 0o644); err != nil {
			return err
		}
	}
	hout := filepath.Join(tmp, "hypr-out")
	if err := os.MkdirAll(hout, 0o755); err != nil { // hyprcursor-util aborts if it's missing
		return err
	}
	if out, err := exec.Command("hyprcursor-util", "--create", src, "--output", hout).CombinedOutput(); err != nil {
		return fmt.Errorf("hyprcursor-util: %v\n%s", err, out)
	}
	built := filepath.Join(hout, "theme_"+themeName)
	if err := os.Rename(filepath.Join(built, "hyprcursors"), filepath.Join(theme, "hyprcursors")); err != nil {
		return err
	}
	if err := os.Rename(filepath.Join(built, "manifest.hl"), filepath.Join(theme, "manifest.hl")); err != nil {
		return err
	}

	files := map[string]string{
		"index.theme":  "[Icon Theme]\nName=" + themeName + "\nComment=Flat graphite wedge cursors\n",
		"cursor.theme": "[Icon Theme]\nName=" + themeName + "\n",
	}
	for name, body := range files {
		if err := os.WriteFile(filepath.Join(theme, name), []byte(body), 0o644); err != nil {
			return err
		}
	}
	return swap(theme, final)
}

// swap replaces final with the freshly built theme.
func swap(theme, final string) error {
	old := final + ".old"
	os.RemoveAll(old)
	if _, err := os.Stat(final); err == nil {
		if err := os.Rename(final, old); err != nil {
			return err
		}
	}
	if err := os.Rename(theme, final); err != nil {
		return err
	}
	return os.RemoveAll(old)
}
