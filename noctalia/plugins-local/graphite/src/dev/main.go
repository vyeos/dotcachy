// Command dev drives real input through Wayland, for testing the shell by hand.
//
//	go run ./dev kbd "<script>"   zwp_virtual_keyboard (keymap from xkbcli, us layout)
//	go run ./dev ptr "<script>"   zwlr_virtual_pointer
//
// A script is semicolon-separated commands:
//
//	kbd: key NAME, hold NAME SECONDS, chord ctrl+shift+f, type some_text (_ is a space)
//	ptr: move X Y, click, mclick, wheel N
//	both: sleep SECONDS, shot NAME X Y W H (grim, scale 2, into $OUT/NAME.png)
//
// EXT_W and EXT_H set the logical screen size for ptr (default 1440x900).
package main

import (
	"encoding/binary"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

type conn struct {
	c   *net.UnixConn
	buf []byte
}

func dial() *conn {
	display := os.Getenv("WAYLAND_DISPLAY")
	if display == "" {
		display = "wayland-0"
	}
	c, err := net.DialUnix("unix", nil, &net.UnixAddr{Name: filepath.Join(os.Getenv("XDG_RUNTIME_DIR"), display), Net: "unix"})
	if err != nil {
		fatal(err)
	}
	return &conn{c: c}
}

func fatal(v ...any) {
	fmt.Fprintln(os.Stderr, v...)
	os.Exit(1)
}

func u32s(vals ...uint32) []byte {
	out := make([]byte, 0, 4*len(vals))
	for _, v := range vals {
		out = binary.LittleEndian.AppendUint32(out, v)
	}
	return out
}

func wlString(s string) []byte {
	raw := append([]byte(s), 0)
	out := u32s(uint32(len(raw)))
	out = append(out, raw...)
	for len(out)%4 != 0 {
		out = append(out, 0)
	}
	return out
}

func (c *conn) send(obj, opcode uint32, payload []byte, fds ...int) {
	msg := append(u32s(obj, uint32(8+len(payload))<<16|opcode), payload...)
	var oob []byte
	if len(fds) > 0 {
		oob = syscall.UnixRights(fds...)
	}
	if _, _, err := c.c.WriteMsgUnix(msg, oob, nil); err != nil {
		fatal(err)
	}
}

type event struct {
	obj, op uint32
	body    []byte
}

func (c *conn) readUntil(obj, op uint32) []event {
	var events []event
	tmp := make([]byte, 65536)
	for {
		for len(c.buf) >= 8 {
			so := binary.LittleEndian.Uint32(c.buf[4:])
			size := int(so >> 16)
			if len(c.buf) < size {
				break
			}
			ev := event{binary.LittleEndian.Uint32(c.buf), so & 0xffff, append([]byte(nil), c.buf[8:size]...)}
			c.buf = c.buf[size:]
			events = append(events, ev)
			if ev.obj == obj && ev.op == op {
				return events
			}
		}
		n, err := c.c.Read(tmp)
		if err != nil {
			fatal("compositor closed the connection")
		}
		c.buf = append(c.buf, tmp[:n]...)
	}
}

type global struct{ name, version uint32 }

func (c *conn) globals() map[string]global {
	c.send(1, 1, u32s(2)) // wl_display.get_registry -> 2
	c.send(1, 0, u32s(3)) // wl_display.sync -> 3
	found := map[string]global{}
	for _, ev := range c.readUntil(3, 0) {
		if ev.obj == 2 && ev.op == 0 {
			name := binary.LittleEndian.Uint32(ev.body)
			n := binary.LittleEndian.Uint32(ev.body[4:])
			iface := string(ev.body[8 : 8+n-1])
			version := binary.LittleEndian.Uint32(ev.body[8+(n+3)&^3:])
			found[iface] = global{name, version}
		}
	}
	return found
}

func (c *conn) bind(g global, iface string, version, id uint32) {
	c.send(2, 0, append(append(u32s(g.name), wlString(iface)...), u32s(version, id)...))
}

func sleep(seconds string) {
	f, _ := strconv.ParseFloat(seconds, 64)
	time.Sleep(time.Duration(f * float64(time.Second)))
}

func shot(p []string) {
	out := os.Getenv("OUT")
	if out == "" {
		out = "."
	}
	region := fmt.Sprintf("%s,%s %sx%s", p[1], p[2], p[3], p[4])
	if err := exec.Command("grim", "-g", region, "-s", "2", filepath.Join(out, p[0]+".png")).Run(); err != nil {
		fatal(err)
	}
	fmt.Println("shot", p[0])
}

var keyCodes = map[string]uint32{"Escape": 1, "1": 2, "2": 3, "3": 4, "4": 5, "5": 6, "6": 7, "7": 8, "8": 9, "9": 10, "0": 11,
	"minus": 12, "equal": 13, "BackSpace": 14, "Tab": 15, "Return": 28, "semicolon": 39, "dot": 52, "slash": 53, "space": 57,
	"Up": 103, "Left": 105, "Right": 106, "Down": 108, "Page_Up": 104, "Page_Down": 109, "bracketleft": 26, "bracketright": 27, "grave": 41}

var modCodes = map[string]struct{ code, bit uint32 }{"ctrl": {29, 4}, "shift": {42, 1}, "alt": {56, 8}}

func init() {
	for start, row := range map[uint32]string{16: "qwertyuiop", 30: "asdfghjkl", 44: "zxcvbnm"} {
		for i, ch := range row {
			keyCodes[string(ch)] = start + uint32(i)
		}
	}
}

func runKbd(script string) {
	c := dial()
	g := c.globals()
	if _, ok := g["zwp_virtual_keyboard_manager_v1"]; !ok {
		fatal("compositor lacks zwp_virtual_keyboard_manager_v1")
	}
	c.bind(g["wl_seat"], "wl_seat", 1, 4)
	c.bind(g["zwp_virtual_keyboard_manager_v1"], "zwp_virtual_keyboard_manager_v1", 1, 5)
	c.send(5, 0, u32s(4, 6)) // create_virtual_keyboard(seat, id=6)

	km, err := exec.Command("xkbcli", "compile-keymap", "--layout", "us").Output()
	if err != nil {
		fatal(err)
	}
	km = append(km, 0)
	f, err := os.CreateTemp("", "vkbd-keymap")
	if err != nil {
		fatal(err)
	}
	os.Remove(f.Name())
	f.Write(km)
	f.Seek(0, 0)
	c.send(6, 0, u32s(1, uint32(len(km))), int(f.Fd())) // keymap(xkb_v1, fd, size)
	f.Close()
	c.send(1, 0, u32s(7))
	c.readUntil(7, 0)

	t0 := time.Now()
	ms := func() uint32 { return uint32(time.Since(t0).Milliseconds()) }
	press := func(code, state uint32) { c.send(6, 1, u32s(ms(), code, state)) }
	mods := func(bits uint32) { c.send(6, 2, u32s(bits, 0, 0, 0)) }
	tap := func(code uint32) {
		press(code, 1)
		time.Sleep(30 * time.Millisecond)
		press(code, 0)
		time.Sleep(30 * time.Millisecond)
	}
	shifted := map[rune]string{'{': "bracketleft", '}': "bracketright", '?': "slash", '&': "7", '~': "grave", ':': "semicolon", '%': "5", '+': "equal", '*': "8", '(': "9", ')': "0", '<': "dot"}
	plain := map[rune]string{' ': "space", '-': "minus", '.': "dot", '/': "slash", '=': "equal", ';': "semicolon"}

	for _, cmd := range strings.Split(script, ";") {
		p := strings.Fields(cmd)
		if len(p) == 0 {
			continue
		}
		switch p[0] {
		case "key":
			tap(keyCodes[p[1]])
		case "hold":
			press(keyCodes[p[1]], 1)
			sleep(p[2])
			press(keyCodes[p[1]], 0)
			time.Sleep(40 * time.Millisecond)
		case "chord":
			parts := strings.Split(p[1], "+")
			var bits uint32
			for _, m := range parts[:len(parts)-1] {
				press(modCodes[m].code, 1)
				bits |= modCodes[m].bit
			}
			mods(bits)
			time.Sleep(40 * time.Millisecond)
			tap(keyCodes[parts[len(parts)-1]])
			for _, m := range parts[:len(parts)-1] {
				press(modCodes[m].code, 0)
			}
			mods(0)
			time.Sleep(40 * time.Millisecond)
		case "type":
			for _, ch := range strings.ReplaceAll(strings.Join(p[1:], " "), "_", " ") {
				name, shift := shifted[ch]
				if ch >= 'A' && ch <= 'Z' {
					name, shift = string(ch+32), true
				}
				if !shift {
					if name = plain[ch]; name == "" {
						name = string(ch)
					}
				}
				if shift {
					press(42, 1)
					mods(1)
					time.Sleep(15 * time.Millisecond)
				}
				tap(keyCodes[name])
				if shift {
					press(42, 0)
					mods(0)
					time.Sleep(15 * time.Millisecond)
				}
			}
		case "sleep":
			sleep(p[1])
		case "shot":
			shot(p[1:])
		}
	}
	c.send(1, 0, u32s(8))
	c.readUntil(8, 0)
	c.send(6, 3, nil)
}

func envInt(name string, fallback uint32) uint32 {
	if n, err := strconv.Atoi(os.Getenv(name)); err == nil {
		return uint32(n)
	}
	return fallback
}

func runPtr(script string) {
	c := dial()
	g := c.globals()
	mgr, ok := g["zwlr_virtual_pointer_manager_v1"]
	if !ok {
		fatal("compositor lacks zwlr_virtual_pointer_manager_v1")
	}
	c.bind(mgr, "zwlr_virtual_pointer_manager_v1", min(mgr.version, 2), 4)
	c.send(4, 0, u32s(0, 5)) // create_virtual_pointer(seat=null, id=5)
	extW, extH := envInt("EXT_W", 1440), envInt("EXT_H", 900)

	t0 := time.Now()
	ms := func() uint32 { return uint32(time.Since(t0).Milliseconds()) }
	frame := func() { c.send(5, 4, nil) }
	button := func(code uint32) {
		c.send(5, 2, u32s(ms(), code, 1))
		frame()
		time.Sleep(50 * time.Millisecond)
		c.send(5, 2, u32s(ms(), code, 0))
		frame()
	}
	for _, cmd := range strings.Split(script, ";") {
		p := strings.Fields(cmd)
		if len(p) == 0 {
			continue
		}
		switch p[0] {
		case "move":
			x, _ := strconv.ParseFloat(p[1], 64)
			y, _ := strconv.ParseFloat(p[2], 64)
			c.send(5, 1, u32s(ms(), uint32(x), uint32(y), extW, extH))
			frame()
		case "wheel":
			n, _ := strconv.ParseFloat(p[1], 64)
			c.send(5, 3, u32s(ms(), 0, uint32(int32(n*256))))
			frame()
		case "click":
			button(0x110)
		case "mclick":
			button(0x112)
		case "sleep":
			sleep(p[1])
		case "shot":
			shot(p[1:])
		}
	}
	c.send(5, 8, nil)
}

func main() {
	if len(os.Args) != 3 {
		fatal(`usage: dev kbd|ptr "<script>"`)
	}
	if os.Args[1] == "kbd" {
		runKbd(os.Args[2])
	} else {
		runPtr(os.Args[2])
	}
}
