package main

// What the launcher runs when a result is picked. Keybinds call the same commands,
// so none of this needs the panel to be open.

import (
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"syscall"
)

type app struct {
	ID       string `json:"id"`
	Exec     string `json:"exec"`
	WMClass  string `json:"wmclass"`
	Path     string `json:"path"`
	Terminal bool   `json:"terminal"`
}

type client struct {
	Address string `json:"address"`
	Class   any    `json:"class"`
	Title   string `json:"title"`
	Mapped  *bool  `json:"mapped"`
	Focus   *int   `json:"focusHistoryID"`
	WS      struct {
		Name any `json:"name"`
	} `json:"workspace"`
}

func (c client) class() string {
	s, _ := c.Class.(string)
	return s
}

func dataDir() string {
	state := os.Getenv("NOCTALIA_STATE_HOME")
	if state == "" {
		state = os.Getenv("XDG_STATE_HOME")
	}
	if state == "" {
		home, _ := os.UserHomeDir()
		state = home + "/.local/state"
	}
	return state + "/noctalia/plugins/data/vyeos/graphite"
}

func loadApps() []app {
	var list []app
	if raw, err := os.ReadFile(dataDir() + "/apps.json"); err == nil {
		json.Unmarshal(raw, &list)
	}
	return list
}

func findApp(id string) *app {
	for _, a := range loadApps() {
		if a.ID == id {
			return &a
		}
	}
	return nil
}

func clients() []client {
	var all []client
	if hyprJSON("j/clients", &all) != nil {
		return nil
	}
	wins := make([]client, 0, len(all))
	for _, w := range all {
		if (w.Mapped == nil || *w.Mapped) && w.class() != "" {
			wins = append(wins, w)
		}
	}
	order := func(c client) int {
		if c.Focus == nil {
			return 99
		}
		return *c.Focus
	}
	sort.SliceStable(wins, func(i, j int) bool { return order(wins[i]) < order(wins[j]) })
	return wins
}

var webAppRe = regexp.MustCompile(`--app=https?://([^"\s?#]*)`)

// owns reports whether a Hyprland window of this class belongs to the app.
func owns(a *app, class string) bool {
	class = strings.ToLower(class)
	if m := webAppRe.FindStringSubmatch(a.Exec); m != nil {
		// Chromium names app windows <browser>-<host>__<path>-<profile>.
		host, rest, _ := strings.Cut(m[1], "/")
		return strings.Contains(class, strings.ToLower(host+"__"+strings.ReplaceAll(rest, "/", "_")+"-"))
	}
	if class == strings.ToLower(a.ID) || (a.WMClass != "" && class == strings.ToLower(a.WMClass)) {
		return true
	}
	// Only a bare command: "thunar --bulk-rename" is a different tool from a Thunar window.
	parts := strings.Fields(a.Exec)
	return len(parts) == 1 && class == strings.ToLower(filepath.Base(parts[0]))
}

func dispatch(expr string) { hyprRequest("/dispatch " + expr) }

func focus(address string) {
	dispatch(fmt.Sprintf(`hl.dsp.focus({ window = "address:%s" })`, address))
}

func closeWindow(address string) {
	dispatch(fmt.Sprintf(`hl.dsp.window.close({ window = "address:%s" })`, address))
}

func moveHere(address string) {
	var ws struct {
		ID *int `json:"id"`
	}
	if hyprJSON("j/activeworkspace", &ws) != nil || ws.ID == nil {
		return
	}
	dispatch(fmt.Sprintf(`hl.dsp.window.move({ workspace = %s, window = "address:%s" })`, strconv.Itoa(*ws.ID), address))
	focus(address)
}

func spawn(argv ...string) {
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if cmd.Start() == nil {
		cmd.Process.Release()
	}
}

func startApp(a *app) {
	if a.Terminal {
		// LANG here is a non-UTF-8 locale, which btop refuses to start under.
		spawn("sh", "-c", "exec "+defaultCommand("terminal", "kitty")+" -e env LC_ALL=en_IN.UTF-8 "+a.Exec)
		return
	}
	spawn("gtk-launch", a.ID)
}

func cmdApp(id string, forceNew bool) {
	a := findApp(id)
	if a == nil {
		spawn("gtk-launch", id) // not scanned yet
		return
	}
	if !forceNew && !a.Terminal {
		for _, w := range clients() {
			if owns(a, w.class()) {
				focus(w.Address)
				return
			}
		}
	}
	startApp(a)
}

func closeApp(id string) {
	a := findApp(id)
	if a == nil {
		return
	}
	for _, w := range clients() {
		if owns(a, w.class()) {
			closeWindow(w.Address)
		}
	}
}

func reveal(path string) {
	trimmed := strings.TrimRight(path, "/")
	if trimmed == "" {
		trimmed = "/"
	}
	folder, name := filepath.Dir(trimmed), filepath.Base(trimmed)
	manager := defaultCommand("files", "thunar")
	if filepath.Base(manager) != "thunar" {
		spawn(manager, folder)
		return
	}
	uri := url.URL{Scheme: "file", Path: folder}
	err := exec.Command("gdbus", "call", "--session", "--dest", "org.xfce.FileManager",
		"--object-path", "/org/xfce/FileManager",
		"--method", "org.xfce.FileManager.DisplayFolderAndSelect",
		uri.String(), name, "", "").Run()
	if err != nil {
		spawn("thunar", folder)
	}
}

func openWeb(target string, newWindow bool) {
	browser := strings.Fields(defaultCommand("browser", "brave-origin"))
	if newWindow {
		spawn(append(browser, "--new-window", target)...)
		return
	}
	spawn(append(browser, target)...)
	// The tab opens in the browser's own window, which may be on another workspace.
	class := strings.ToLower(filepath.Base(browser[0]))
	for _, w := range clients() {
		if strings.ToLower(w.class()) == class {
			focus(w.Address)
			return
		}
	}
}

type windowRow struct {
	Address   string `json:"address"`
	Title     string `json:"title"`
	Class     string `json:"class"`
	Workspace string `json:"workspace"`
	App       string `json:"app"`
	Path      string `json:"path"`
}

func printWindows() {
	enc := json.NewEncoder(os.Stdout)
	enc.SetEscapeHTML(false)
	enc.Encode(windowRows())
}
