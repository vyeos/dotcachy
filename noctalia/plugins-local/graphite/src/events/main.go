// Command graphite-events is everything the Graphite service reacts to, as one stream of tagged lines.
//
// One process replaces the service's polling loops: it holds the Hyprland event
// socket, answers it over the request socket (no hyprctl spawns), and supervises
// the event watchers below, restarting any that exit. Output, one per line:
//
//	ws<TAB>json  wsActive<TAB>id  win<TAB>json  windows    Hyprland
//	vol  dev                                               sink/source changed, added/removed
//	net  bt  power                                         NetworkManager, BlueZ, UPower + profiles
//	clip                                                   clipboard history changed
//	notif<TAB>line                                         raw dbus-monitor output
//
// It exits with its parent, and takes its children along: PDEATHSIG covers a kill,
// the stdout check covers the pipe going away, the ppid check covers the rest.
// dbus-monitor must not be started bare, it ignores SIGPIPE and would never exit.
//
// It always runs, so it's a separate binary: linking the web code from bin/graphite
// into it would add about 5 MB of resident memory.
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"runtime"
	"runtime/debug"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

const prSetPdeathsig = 1

var (
	outMu    sync.Mutex
	children sync.Map // *exec.Cmd -> struct{}
)

func cleanup() {
	children.Range(func(k, _ any) bool {
		if c := k.(*exec.Cmd); c.Process != nil {
			c.Process.Signal(syscall.SIGTERM)
		}
		return true
	})
}

func emit(tag string, payload ...string) {
	line := tag
	if len(payload) > 0 {
		line += "\t" + payload[0]
	}
	outMu.Lock()
	defer outMu.Unlock()
	if _, err := os.Stdout.WriteString(line + "\n"); err != nil {
		cleanup()
		os.Exit(0)
	}
}

// Debounce: a burst of changes becomes one line, 150 ms after the first.
var (
	marksMu sync.Mutex
	marks   = map[string]struct{}{}
	markCh  = make(chan struct{}, 1)
)

func mark(tag string) {
	marksMu.Lock()
	marks[tag] = struct{}{}
	marksMu.Unlock()
	select {
	case markCh <- struct{}{}:
	default:
	}
}

func flusher() {
	for range markCh {
		time.Sleep(150 * time.Millisecond)
		marksMu.Lock()
		tags := make([]string, 0, len(marks))
		for t := range marks {
			tags = append(tags, t)
		}
		clear(marks)
		marksMu.Unlock()
		for _, t := range tags {
			emit(t)
		}
	}
}

// ── Hyprland ────────────────────────────────────────────────────────────────

func hyprSocket(name string) string {
	return filepath.Join(os.Getenv("XDG_RUNTIME_DIR"), "hypr", os.Getenv("HYPRLAND_INSTANCE_SIGNATURE"), name)
}

func hyprJSON(cmd string, into any) error {
	conn, err := net.Dial("unix", hyprSocket(".socket.sock"))
	if err != nil {
		return err
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(2 * time.Second))
	if _, err := conn.Write([]byte(cmd)); err != nil {
		return err
	}
	reply, err := io.ReadAll(conn)
	if err != nil {
		return err
	}
	return json.Unmarshal(reply, into)
}

type wantSet struct{ ws, active, win bool }

var lastHypr = map[string]string{}

func publish(tag string, value any) {
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	if enc.Encode(value) != nil {
		return
	}
	text := strings.TrimRight(b.String(), "\n")
	if lastHypr[tag] != text {
		lastHypr[tag] = text
		emit(tag, text)
	}
}

type wsRow struct {
	ID      int `json:"id"`
	Windows int `json:"windows"`
}

type winInfo struct {
	Class string `json:"cls"`
	Title string `json:"title"`
}

func query(want wantSet) error {
	if want.ws {
		var all []wsRow
		if err := hyprJSON("j/workspaces", &all); err != nil {
			return err
		}
		rows := make([]wsRow, 0, len(all))
		for _, w := range all {
			if w.ID > 0 {
				rows = append(rows, w)
			}
		}
		sort.Slice(rows, func(i, j int) bool { return rows[i].ID < rows[j].ID })
		publish("ws", rows)
	}
	if want.active {
		var d struct {
			ID *int `json:"id"`
		}
		if err := hyprJSON("j/activeworkspace", &d); err != nil {
			return err
		}
		if d.ID != nil {
			publish("wsActive", *d.ID)
		}
	}
	if want.win {
		var d struct {
			Class string `json:"class"`
			Title string `json:"title"`
		}
		if err := hyprJSON("j/activewindow", &d); err != nil {
			return err
		}
		publish("win", winInfo{d.Class, d.Title})
	}
	return nil
}

func eventWant(ev string, want *wantSet) {
	switch ev {
	case "activewindow", "activewindowv2", "windowtitle", "windowtitlev2":
		want.win = true
	case "createworkspace", "createworkspacev2", "destroyworkspace", "destroyworkspacev2":
		want.ws = true
	case "workspace", "workspacev2", "focusedmon", "focusedmonv2", "movewindow", "movewindowv2", "openwindow", "closewindow":
		*want = wantSet{true, true, true}
	}
	if ev == "openwindow" || ev == "closewindow" {
		mark("windows")
	}
}

// hyprSession serves one connection to the event socket, until it breaks.
func hyprSession() error {
	conn, err := net.Dial("unix", hyprSocket(".socket2.sock"))
	if err != nil {
		return err
	}
	defer conn.Close()
	if err := query(wantSet{true, true, true}); err != nil {
		return err
	}
	var pending []byte
	buf := make([]byte, 65536)
	for {
		conn.SetReadDeadline(time.Time{})
		n, err := conn.Read(buf)
		if err != nil {
			return err
		}
		data := append([]byte(nil), buf[:n]...)
		time.Sleep(40 * time.Millisecond) // let a burst pile up, then answer it once
		for {
			conn.SetReadDeadline(time.Now().Add(time.Millisecond))
			n, err := conn.Read(buf)
			data = append(data, buf[:n]...)
			if err != nil {
				break
			}
		}
		pending = append(pending, data...)
		lines := bytes.Split(pending, []byte("\n"))
		pending = append([]byte(nil), lines[len(lines)-1]...)
		var want wantSet
		for _, line := range lines[:len(lines)-1] {
			ev, _, _ := bytes.Cut(line, []byte(">>"))
			eventWant(string(ev), &want)
		}
		if want != (wantSet{}) {
			if err := query(want); err != nil {
				return err
			}
		}
	}
}

func hypr() {
	for {
		hyprSession()
		time.Sleep(2 * time.Second)
	}
}

// ── Watchers ────────────────────────────────────────────────────────────────

// watch runs argv forever, calling onLine for each line, and restarts it when it exits.
func watch(argv []string, onLine func(string)) {
	delay := 2 * time.Second
	for {
		started := time.Now()
		cmd := exec.Command(argv[0], argv[1:]...)
		// PDEATHSIG is tied to the thread that starts the child; Go only retires a
		// thread when a goroutine exits while locked to it, and none here lock.
		cmd.SysProcAttr = &syscall.SysProcAttr{Pdeathsig: syscall.SIGTERM}
		if stdout, err := cmd.StdoutPipe(); err == nil && cmd.Start() == nil {
			children.Store(cmd, struct{}{})
			readLines(stdout, onLine)
			cmd.Wait()
			children.Delete(cmd)
		}
		if time.Since(started) > 30*time.Second {
			delay = 2 * time.Second
		} else if delay *= 2; delay > time.Minute {
			delay = time.Minute
		}
		time.Sleep(delay)
	}
}

func readLines(r io.Reader, onLine func(string)) {
	br := bufio.NewReader(r)
	for {
		line, err := br.ReadString('\n')
		if line != "" {
			onLine(strings.ToValidUTF8(strings.TrimSuffix(line, "\n"), "�"))
		}
		if err != nil {
			return
		}
	}
}

var (
	pactlRe = regexp.MustCompile(`'(\w+)' on (sink|source|server)\b`)
	btRe    = regexp.MustCompile(`'(Powered|Connected)'|InterfacesAdded|InterfacesRemoved`)
)

func onPactl(line string) {
	m := pactlRe.FindStringSubmatch(line)
	if m == nil {
		return
	}
	if m[1] == "new" || m[1] == "remove" {
		mark("dev")
	}
	mark("vol")
}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: graphite-events DATA_DIR")
		os.Exit(2)
	}
	dataDir := os.Args[1]

	// An idle event pump: one scheduler thread and a tight heap keep it small.
	runtime.GOMAXPROCS(1)
	debug.SetGCPercent(50)

	syscall.RawSyscall(syscall.SYS_PRCTL, prSetPdeathsig, uintptr(syscall.SIGTERM), 0)
	parent := os.Getppid()
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		<-stop
		cleanup()
		os.Exit(0)
	}()

	self, _ := os.Executable()
	exe := filepath.Join(filepath.Dir(self), "graphite")

	go flusher()
	go hypr()
	go watch([]string{"pactl", "subscribe"}, onPactl)
	go watch([]string{"nmcli", "monitor"}, func(string) { mark("net") })
	go watch([]string{"gdbus", "monitor", "--system", "--dest", "org.bluez"}, func(l string) {
		if btRe.MatchString(l) {
			mark("bt")
		}
	})
	go watch([]string{"upower", "--monitor"}, func(string) { mark("power") })
	go watch([]string{"gdbus", "monitor", "--system", "--dest", "org.freedesktop.UPower.PowerProfiles"}, func(l string) {
		if strings.Contains(l, "ActiveProfile") {
			mark("power")
		}
	})
	go watch([]string{"dbus-monitor", "--session",
		"type='method_call',interface='org.freedesktop.Notifications',member='Notify'",
		"type='method_return',sender='org.freedesktop.Notifications'"},
		func(l string) { emit("notif", l) })
	go watch([]string{"wl-paste", "--watch", exe, "clip", dataDir, "store"}, func(string) { mark("clip") })

	for os.Getppid() == parent {
		time.Sleep(15 * time.Second)
	}
	cleanup()
}
