package main

// The launcher's background jobs: gathering live data, keybinds, default apps and
// editing web apps. These print one JSON object with "status" when they report back.

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

var fileSkip = []string{"node_modules", "bower_components", "jspm_packages", "vendor", "target", "__pycache__", "venv",
	"site-packages", "dist-packages", "Pods", "Carthage", "elm-stuff", "deps", "_build", "zig-cache",
	"zig-out", "CMakeFiles", "dist"}

const fileMax = "3000"

func bindsLua() string     { return configDir() + "/hypr/config/binds.lua" }
func userBindsLua() string { return configDir() + "/hypr/config/launcher_binds.lua" }
func variablesLua() string { return configDir() + "/hypr/config/variables.lua" }

// ── Live data ───────────────────────────────────────────────────────────────

type fileRow struct {
	Path string `json:"path"`
	Dir  bool   `json:"dir"`
}

type networkRow struct {
	Name      string `json:"name"`
	Connected bool   `json:"connected"`
}

type deviceRow struct {
	MAC       string `json:"mac"`
	Name      string `json:"name"`
	Connected bool   `json:"connected"`
}

func nmcliFields(line string) []string {
	// Split on colons that aren't escaped with a backslash.
	var fields []string
	var cur strings.Builder
	for i := 0; i < len(line); i++ {
		if line[i] == '\\' && i+1 < len(line) {
			i++
			cur.WriteByte(line[i])
		} else if line[i] == ':' {
			fields = append(fields, cur.String())
			cur.Reset()
		} else {
			cur.WriteByte(line[i])
		}
	}
	return append(fields, cur.String())
}

func wifiNetworks() []networkRow {
	active := map[string]bool{}
	for _, l := range strings.Split(output(3*time.Second, "nmcli", "-t", "-f", "NAME,TYPE", "connection", "show", "--active"), "\n") {
		active[nmcliFields(l)[0]] = true
	}
	out := []networkRow{}
	for _, l := range strings.Split(output(3*time.Second, "nmcli", "-t", "-f", "NAME,TYPE", "connection", "show"), "\n") {
		if f := nmcliFields(l); len(f) == 2 && f[1] == "802-11-wireless" {
			out = append(out, networkRow{f[0], active[f[0]]})
		}
	}
	return out
}

var btDeviceRe = regexp.MustCompile(`^Device (\S+) (.+)`)

func btList(which string) map[string]string {
	found := map[string]string{}
	for _, l := range strings.Split(output(2*time.Second, "bluetoothctl", "devices", which), "\n") {
		if m := btDeviceRe.FindStringSubmatch(l); m != nil {
			found[m[1]] = m[2]
		}
	}
	return found
}

func btDevices() []deviceRow {
	connected, paired := btList("Connected"), btList("Paired")
	out := []deviceRow{}
	for mac, name := range paired {
		_, on := connected[mac]
		out = append(out, deviceRow{mac, name, on})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

func homeFiles() []fileRow {
	home := homeDir()
	argv := []string{"fd", "--no-ignore", "--max-results", fileMax, "--base-directory", home}
	for _, name := range fileSkip {
		argv = append(argv, "-E", name)
	}
	out := []fileRow{}
	for _, rel := range strings.Split(output(5*time.Second, argv...), "\n") {
		if rel != "" {
			out = append(out, fileRow{home + "/" + strings.TrimRight(rel, "/"), strings.HasSuffix(rel, "/")})
		}
	}
	return out
}

func windowRows() []windowRow {
	known := loadApps()
	rows := []windowRow{}
	for _, w := range clients() {
		row := windowRow{Address: w.Address, Title: w.Title, Class: w.class(), Workspace: fmt.Sprint(w.WS.Name)}
		if row.Title == "" {
			row.Title = row.Class
		}
		for i := range known {
			if owns(&known[i], row.Class) {
				row.App, row.Path = known[i].ID, known[i].Path
				break
			}
		}
		rows = append(rows, row)
	}
	return rows
}

func cmdGather() {
	if _, err := os.Stat(bindsLua()); err == nil {
		cmdBindsQuiet()
	}
	var (
		wg      sync.WaitGroup
		windows []windowRow
		files   []fileRow
		wifi    []networkRow
		bt      []deviceRow
	)
	jobs := []func(){
		func() { windows = windowRows() },
		func() { files = homeFiles() },
		func() { wifi = wifiNetworks() },
		func() { bt = btDevices() },
	}
	wg.Add(len(jobs))
	for _, job := range jobs {
		go func() {
			defer wg.Done()
			job()
		}()
	}
	wg.Wait()
	live := map[string]any{"windows": windows, "files": files, "wifi": wifi, "bluetooth": bt, "defaults": currentDefaults()}
	if writeAtomic(dataDir()+"/launcher-live.json", []byte(jsonText(live))) == nil {
		fmt.Println("ok")
	}
}

func cmdBindsQuiet() {
	stdout := os.Stdout
	if null, err := os.OpenFile(os.DevNull, os.O_WRONLY, 0); err == nil {
		os.Stdout = null
		defer func() { os.Stdout = stdout; null.Close() }()
	}
	cmdBinds(bindsLua(), dataDir()+"/binds.json")
}

// ── Default apps ────────────────────────────────────────────────────────────

var roleVars = map[string]string{"terminal": "TERMINAL", "browser": "BROWSER", "files": "FILE_MANAGER", "editor": "EDITOR"}

func readDefaults() map[string]string {
	out := map[string]string{}
	raw, err := os.ReadFile(variablesLua())
	if err != nil {
		return out
	}
	for role, name := range roleVars {
		re := regexp.MustCompile(`(?m)^` + name + `\s*=\s*"([^"]*)"`)
		if m := re.FindSubmatch(raw); m != nil {
			out[role] = string(m[1])
		}
	}
	return out
}

func defaultCommand(role, fallback string) string {
	if v := readDefaults()[role]; v != "" {
		return v
	}
	return fallback
}

type defaultRow struct {
	Value string `json:"value"`
	App   string `json:"app"`
}

// appForValue finds the app a variables.lua value starts, such as "kitty" or
// "kitty -e nvim", where the program is the last word.
func appForValue(value string, apps []app) string {
	for _, a := range apps {
		if a.Exec == value {
			return a.ID
		}
	}
	words := strings.Fields(value)
	if len(words) == 0 {
		return ""
	}
	want := filepath.Base(words[len(words)-1])
	for _, a := range apps {
		if parts := strings.Fields(a.Exec); len(parts) > 0 && filepath.Base(parts[0]) == want {
			return a.ID
		}
	}
	return ""
}

func currentDefaults() map[string]defaultRow {
	apps := loadApps()
	out := map[string]defaultRow{}
	for role, value := range readDefaults() {
		out[role] = defaultRow{value, appForValue(value, apps)}
	}
	return out
}

// retargetEditor keeps a terminal editor ("kitty -e nvim") on the new default terminal.
func retargetEditor(terminal string) {
	raw, err := os.ReadFile(variablesLua())
	if err != nil {
		return
	}
	re := regexp.MustCompile(`(?m)^(EDITOR\s*=\s*")[^"]*( -e [^"]*")`)
	writeAtomic(variablesLua(), re.ReplaceAll(raw, []byte("${1}"+terminal+"${2}")))
}

func cmdSetDefault(role, id string) {
	name, ok := roleVars[role]
	a := findApp(id)
	if !ok || a == nil {
		sayStatus("missing", nil)
		return
	}
	value := a.Exec
	if a.Terminal {
		value = defaultCommand("terminal", "kitty") + " -e " + a.Exec
	}
	raw, err := os.ReadFile(variablesLua())
	if err != nil {
		sayStatus("failed", nil)
		return
	}
	re := regexp.MustCompile(`(?m)^(` + name + `\s*=\s*)"[^"]*"`)
	if !re.Match(raw) {
		sayStatus("failed", nil)
		return
	}
	edited := re.ReplaceAllFunc(raw, func(m []byte) []byte {
		return append(re.FindSubmatch(m)[1], []byte(jsonText(value))...)
	})
	if writeAtomic(variablesLua(), edited) != nil {
		sayStatus("failed", nil)
		return
	}
	if role == "terminal" {
		retargetEditor(value)
	}
	switch role {
	case "browser":
		exec.Command("xdg-settings", "set", "default-web-browser", id+".desktop").Run()
	case "files":
		exec.Command("xdg-mime", "default", id+".desktop", "inode/directory").Run()
	}
	reloadHypr()
	sayStatus("ok", nil)
}

// ── Keybinds ────────────────────────────────────────────────────────────────

var comboMods = map[string]string{"SUPER": "SUPER", "WIN": "SUPER", "META": "SUPER", "CTRL": "CONTROL", "CONTROL": "CONTROL",
	"ALT": "ALT", "SHIFT": "SHIFT"}
var comboModOrder = []string{"SUPER", "CONTROL", "ALT", "SHIFT"}
var comboKeys = map[string]string{".": "period", ",": "comma", "/": "slash", ";": "semicolon", "-": "minus", "=": "equal",
	"enter": "Return", "return": "Return", "esc": "Escape", "escape": "Escape", "space": "Space", "tab": "Tab",
	"backspace": "BackSpace", "delete": "Delete", "up": "Up", "down": "Down", "left": "Left", "right": "Right"}

var (
	comboSplitRe = regexp.MustCompile(`[+\s]+`)
	fKeyRe       = regexp.MustCompile(`^[fF]\d{1,2}$`)
	keyNameRe    = regexp.MustCompile(`^[A-Za-z0-9_]+$`)
	bindLineRe   = regexp.MustCompile(`^\s*hl\.bind\((.+?),\s*hl\.`)
)

func digitCode(d int) string {
	if d == 0 {
		return "code:19"
	}
	return fmt.Sprintf("code:%d", 9+d)
}

// parseCombo returns the canonical "SUPER + ALT + G", or "" when text isn't
// at least one modifier plus exactly one key.
func parseCombo(text string) string {
	mods := map[string]bool{}
	var keys []string
	for _, p := range comboSplitRe.Split(strings.TrimSpace(text), -1) {
		if p == "" {
			continue
		}
		if m, ok := comboMods[strings.ToUpper(p)]; ok {
			mods[m] = true
		} else {
			keys = append(keys, p)
		}
	}
	if len(mods) == 0 || len(keys) != 1 {
		return ""
	}
	key := keys[0]
	switch {
	case len(key) == 1 && key[0] >= '0' && key[0] <= '9':
		key = digitCode(int(key[0] - '0'))
	case comboKeys[strings.ToLower(key)] != "":
		key = comboKeys[strings.ToLower(key)]
	case len(key) == 1:
		key = strings.ToUpper(key)
	case fKeyRe.MatchString(key):
		key = strings.ToUpper(key)
	case !strings.HasPrefix(key, "code:") && !keyNameRe.MatchString(key):
		return ""
	}
	parts := []string{}
	for _, m := range comboModOrder {
		if mods[m] {
			parts = append(parts, m)
		}
	}
	return strings.Join(append(parts, key), " + ")
}

func keyExprCombos(expr string) []string {
	var text []string
	for _, m := range quotedRe.FindAllStringSubmatch(expr, -1) {
		text = append(text, m[1])
	}
	joined := strings.Join(text, " ")
	if strings.Contains(expr, "mainMod") {
		joined = "SUPER " + joined
	}
	var out []string
	if strings.Contains(expr, "digitCode") {
		for d := 0; d < 10; d++ {
			if c := parseCombo(fmt.Sprintf("%s %d", joined, d)); c != "" {
				out = append(out, c)
			}
		}
	} else if c := parseCombo(joined); c != "" {
		out = append(out, c)
	}
	return out
}

// takenCombos lists every combo in binds.lua, leaving out one line number.
func takenCombos(skipLine int) map[string]bool {
	taken := map[string]bool{}
	raw, err := os.ReadFile(bindsLua())
	if err != nil {
		return taken
	}
	for n, line := range strings.Split(string(raw), "\n") {
		if n == skipLine {
			continue
		}
		if m := bindLineRe.FindStringSubmatch(line); m != nil {
			for _, c := range keyExprCombos(m[1]) {
				taken[c] = true
			}
		}
	}
	return taken
}

type userBind struct {
	ID    string `json:"id"`
	Label string `json:"label"`
	Cmd   string `json:"cmd"`
}

func loadUserBinds() map[string]userBind {
	binds := map[string]userBind{}
	loadJSON(dataDir()+"/launcher-binds.json", &binds)
	return binds
}

func writeUserBinds(binds map[string]userBind) {
	writeAtomic(dataDir()+"/launcher-binds.json", []byte(jsonText(binds)))
	combos := make([]string, 0, len(binds))
	for c := range binds {
		combos = append(combos, c)
	}
	sort.Strings(combos)
	var b bytes.Buffer
	b.WriteString("-- Generated by the graphite launcher (Ctrl+K, Set keybind). Edits here are overwritten.\n---- LAUNCHER KEYBINDS ----\n")
	for _, c := range combos {
		fmt.Fprintf(&b, "hl.bind(%s, hl.dsp.exec_cmd(%s)) -- %s\n", jsonText(c), jsonText(binds[c].Cmd), binds[c].Label)
	}
	writeAtomic(userBindsLua(), b.Bytes())
}

func reloadHypr() string {
	output(5*time.Second, "hyprctl", "reload")
	errs := strings.TrimSpace(output(3*time.Second, "hyprctl", "configerrors"))
	if errs == "no errors" {
		return ""
	}
	return errs
}

func shellQuote(args []string) string {
	safe := regexp.MustCompile(`^[\w@%+=:,./-]+$`)
	out := make([]string, len(args))
	for i, a := range args {
		if safe.MatchString(a) {
			out[i] = a
		} else {
			out[i] = "'" + strings.ReplaceAll(a, "'", `'"'"'`) + "'"
		}
	}
	return strings.Join(out, " ")
}

// systemBind finds the line of binds.lua that binds this result and can be edited in place.
func systemBind(id string) (bindEntry, []string, bool) {
	raw, err := os.ReadFile(bindsLua())
	if err != nil {
		return bindEntry{}, nil, false
	}
	lines := strings.Split(string(raw), "\n")
	for _, b := range parseBinds(string(raw), nil) {
		if (b.Target == id || "desc:"+b.Desc == id) && b.single {
			return b, lines, true
		}
	}
	return bindEntry{}, nil, false
}

// changeSystemBind rewrites the key of a bind in binds.lua, or comments the line out.
func changeSystemBind(b bindEntry, lines []string, comboText string) {
	before := strings.Join(lines, "\n")
	if strings.TrimSpace(comboText) == "" {
		lines[b.line] = "-- " + lines[b.line]
		writeAtomic(bindsLua(), []byte(strings.Join(lines, "\n")))
		reloadHypr()
		sayStatus("removed", nil)
		return
	}
	combo := parseCombo(comboText)
	if combo == "" {
		sayStatus("bad-combo", nil)
		return
	}
	if takenCombos(b.line)[combo] {
		sayStatus("taken", map[string]any{"combo": combo, "by": "an existing shortcut"})
		return
	}
	if u, ok := loadUserBinds()[combo]; ok {
		sayStatus("taken", map[string]any{"combo": combo, "by": u.Label})
		return
	}
	lines[b.line] = strings.Replace(lines[b.line], strings.TrimSpace(b.keyExpr), jsonText(combo), 1)
	writeAtomic(bindsLua(), []byte(strings.Join(lines, "\n")))
	if errs := reloadHypr(); errs != "" {
		writeAtomic(bindsLua(), []byte(before))
		reloadHypr()
		sayStatus("rejected", map[string]any{"message": errs})
		return
	}
	sayStatus("ok", map[string]any{"combo": combo})
}

func cmdBind(args []string) {
	id, label, comboText, argv := args[0], strings.NewReplacer("\r", " ", "\n", " ").Replace(args[1]), args[2], args[3:]
	if b, lines, ok := systemBind(id); ok {
		changeSystemBind(b, lines, comboText)
		return
	}
	if strings.HasPrefix(id, "desc:") {
		sayStatus("not-editable", nil)
		return
	}
	binds := loadUserBinds()
	before := map[string]userBind{}
	for c, b := range binds {
		before[c] = b
		if b.ID == id {
			delete(binds, c)
		}
	}
	if strings.TrimSpace(comboText) == "" {
		writeUserBinds(binds)
		reloadHypr()
		sayStatus("removed", nil)
		return
	}
	combo := parseCombo(comboText)
	if combo == "" {
		sayStatus("bad-combo", nil)
		return
	}
	if takenCombos(-1)[combo] {
		sayStatus("taken", map[string]any{"combo": combo, "by": "an existing shortcut"})
		return
	}
	if u, ok := binds[combo]; ok {
		sayStatus("taken", map[string]any{"combo": combo, "by": u.Label})
		return
	}
	binds[combo] = userBind{id, label, shellQuote(argv)}
	writeUserBinds(binds)
	if errs := reloadHypr(); errs != "" {
		writeUserBinds(before)
		reloadHypr()
		sayStatus("rejected", map[string]any{"message": errs})
		return
	}
	sayStatus("ok", map[string]any{"combo": combo})
}

// ── Recording a keybind ─────────────────────────────────────────────────────

// While recording, Hyprland runs no shortcuts at all, so a detached guard leaves the
// submap by itself in case the panel dies without saying so.
const recordLimit = 2 * time.Minute

func recordPidPath() string { return dataDir() + "/bind-record.pid" }

func setSubmap(name string) {
	output(3*time.Second, "hyprctl", "dispatch", fmt.Sprintf("hl.dsp.submap(%q)", name))
}

func stopRecordGuard() {
	raw, err := os.ReadFile(recordPidPath())
	if err != nil {
		return
	}
	os.Remove(recordPidPath())
	pid, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil {
		return
	}
	// The pid may have been reused since the guard started.
	cmdline, _ := os.ReadFile(fmt.Sprintf("/proc/%d/cmdline", pid))
	if bytes.Contains(cmdline, []byte("bind-record")) {
		syscall.Kill(pid, syscall.SIGTERM)
	}
}

func cmdBindRecord(action string) {
	switch action {
	case "start":
		stopRecordGuard()
		setSubmap("graphite-record")
		self, err := os.Executable()
		if err != nil {
			return
		}
		guard := exec.Command(self, "bind-record", "guard")
		guard.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
		if guard.Start() == nil {
			writeAtomic(recordPidPath(), []byte(strconv.Itoa(guard.Process.Pid)))
			guard.Process.Release()
		}
	case "stop":
		stopRecordGuard()
		setSubmap("reset")
	case "guard":
		time.Sleep(recordLimit)
		os.Remove(recordPidPath())
		output(3*time.Second, "noctalia", "msg", "plugin", "vyeos/graphite:bind-record", "all", "expired")
		setSubmap("reset")
	}
}
