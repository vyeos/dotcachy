package main

// Reads Hyprland's Lua binds and writes the shortcuts list as JSON.
//
//	graphite binds BINDS.lua OUT.json
//
// Each hl.bind(...) becomes {group, keys, desc, target}. target names the launcher
// result that bind runs, so a result can show its keybind instead of a second row.
// Binds inside `for i = 1, NUM_WPM` loops collapse to a single "1-0" row.

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

var keyNames = map[string]string{
	"SUPER": "Super", "CONTROL": "Ctrl", "CTRL": "Ctrl", "SHIFT": "Shift", "ALT": "Alt",
	"Return": "Enter", "Escape": "Esc", "Space": "Space", "Tab": "Tab", "period": ".",
	"comma": ",", "slash": "/", "Minus": "-", "minus": "-", "Plus": "+", "plus": "+",
	"mouse:272": "LMB drag", "mouse:273": "RMB drag", "mouse_up": "Scroll up",
	"mouse_down": "Scroll down", "code:82": "Num -", "code:86": "Num +", "Print": "Print",
	"XF86AudioRaiseVolume": "Vol +", "XF86AudioLowerVolume": "Vol -", "XF86AudioMute": "Mute",
	"XF86AudioMicMute": "Mic mute", "XF86AudioPlay": "Play", "XF86AudioPause": "Pause",
	"XF86AudioNext": "Next", "XF86AudioPrev": "Prev", "XF86MonBrightnessUp": "Bright +",
	"XF86MonBrightnessDown": "Bright -", "XF86Calculator": "Calc",
}

// Small comment headings that start their own group.
var bindSubgroups = [][2]string{{"Graphite panels", "Panels"}, {"Quick toggles", "Quick Toggles"}}
var bindGroupRename = map[string]string{"Launcher": "Apps & Shell"}

type descRule struct {
	re   *regexp.Regexp
	text string
}

func rules(pairs ...string) []descRule {
	out := make([]descRule, 0, len(pairs)/2)
	for i := 0; i < len(pairs); i += 2 {
		out = append(out, descRule{regexp.MustCompile(pairs[i]), pairs[i+1]})
	}
	return out
}

// First match wins, so order matters.
var bindDescs = rules(
	`window\.close`, "Close window",
	`hyprctl kill`, "Kill a window (click it)",
	`window\.float`, "Toggle floating",
	`fullscreen\(\{ mode = 1`, "Maximize window",
	`window\.fullscreen\(`, "Fullscreen",
	`togglesplit`, "Toggle split direction",
	`focus\(\{ direction = "(\w+)"`, "Focus window $1",
	`cycle_next`, "Cycle windows",
	`graphite:switcher`, "Window switcher",
	`move\(\{ direction = "u"`, "Move window up",
	`move\(\{ direction = "d"`, "Move window down",
	`move\(\{ direction = "l"`, "Move window left",
	`move\(\{ direction = "r"`, "Move window right",
	`move\(\{ monitor = "-1"`, "Move window to previous monitor",
	`move\(\{ monitor = "\+1"`, "Move window to next monitor",
	`move\(\{ workspace = "m~" \.\. i, follow = false`, "Move window to workspace (stay)",
	`move\(\{ workspace = "m~"`, "Move window to workspace",
	`move\(\{ workspace = "m\+1"`, "Move window to next workspace",
	`move\(\{ workspace = "m-1"`, "Move window to previous workspace",
	`move\(\{ workspace = "special"`, "Move window to scratchpad",
	`window\.drag`, "Move window",
	`window\.resize`, "Resize window",
	`zoomfunction\(-`, "Zoom out",
	`zoomfunction\(`, "Zoom in",
	`btop`, "System monitor (btop)",
	`TERMINAL`, "Terminal",
	`FILE_MANAGER`, "File manager",
	`EDITOR`, "Editor",
	`graphite:calc`, "Calculator",
	`BROWSER`, "Browser",
	`settings-toggle`, "Noctalia settings",
	`clock all panel|graphite:cc"`, "Control center",
	`clock all calendar|graphite:calendar`, "Calendar",
	`graphite:session-panel`, "Session menu",
	`graphite:launcher`, "App launcher",
	`graphite:emoji`, "Emoji picker",
	`graphite:shortcuts`, "Keyboard shortcuts",
	`session lock`, "Lock screen",
	`battery all panel|graphite:power-panel`, "Power panel",
	`audio all panel|graphite:audio-panel`, "Audio panel",
	`bluetooth all panel|graphite:bluetooth-panel`, "Bluetooth panel",
	`wifi all panel|graphite:wifi-panel`, "Wi-Fi panel",
	`drawer toggle`, "Notifications",
	`caffeine toggle`, "Toggle caffeine",
	`night toggle`, "Toggle night light",
	`"bt toggle`, "Toggle Bluetooth",
	`"wifi toggle`, "Toggle Wi-Fi",
	`profile next`, "Cycle power profile",
	`dnd toggle`, "Toggle do not disturb",
	`volume-up`, "Volume up",
	`volume-down`, "Volume down",
	`volume-mute`, "Mute audio",
	`mic-mute`, "Mute microphone",
	`media toggle`, "Play / pause",
	`media next`, "Next track",
	`media previous`, "Previous track",
	`brightness-up`, "Brightness up",
	`brightness-down`, "Brightness down",
	`hyprpicker`, "Color picker",
	`screenshot-region`, "Screenshot region",
	`screenshot-fullscreen`, "Screenshot screen",
	`graphite-shot annotate`, "Annotate last screenshot",
	`graphite:wallpaper`, "Wallpaper picker",
	`graphite:clip`, "Clipboard history",
	`focus\(\{ workspace = i \}`, "Go to workspace",
	`focus\(\{ workspace = "m~"`, "Go to workspace on this monitor",
	`focus\(\{ workspace = "m\+1"`, "Next workspace",
	`focus\(\{ workspace = "m-1"`, "Previous workspace",
	`focus\(\{ workspace = "emptym"`, "Next empty workspace",
	`toggle_special`, "Toggle scratchpad",
)

// Which launcher result a bind's action runs. Empty text means none.
var bindTargets = rules(
	`btop`, "",
	`TERMINAL`, "default:terminal",
	`FILE_MANAGER`, "default:files",
	`EDITOR`, "default:editor",
	`BROWSER`, "default:browser",
	`panel-toggle vyeos/graphite:([\w-]+?)(?:-kb)?"`, "panel:$1",
	`clock all panel`, "panel:cc",
	`clock all calendar`, "panel:calendar",
	`battery all panel`, "panel:power-panel",
	`audio all panel`, "panel:audio-panel",
	`bluetooth all panel`, "panel:bluetooth-panel",
	`wifi all panel`, "panel:wifi-panel",
	`session lock`, "power:lock",
	`caffeine toggle`, "cmd:caffeine",
	`night toggle`, "cmd:night",
	`"bt toggle`, "cmd:bt",
	`"wifi toggle`, "cmd:wifi",
	`profile next`, "cmd:profile",
	`dnd toggle`, "cmd:dnd",
	`volume-mute`, "cmd:mute",
	`mic-mute`, "cmd:mute-in",
)

func applyRules(list []descRule, action string) (string, bool) {
	for _, r := range list {
		if m := r.re.FindStringSubmatchIndex(action); m != nil {
			return string(r.re.ExpandString(nil, r.text, action, m)), true
		}
	}
	return "", false
}

type bindEntry struct {
	Group  string   `json:"group"`
	Keys   []string `json:"keys"`
	Desc   string   `json:"desc"`
	Target string   `json:"target,omitempty"`
	Fixed  bool     `json:"fixed,omitempty"` // part of a loop or multi-line, so not editable here
	// How to replay the bind: a shell command, or a Hyprland dispatcher expression.
	Cmd      string `json:"cmd,omitempty"`
	Dispatch string `json:"dispatch,omitempty"`

	// Where it came from, for changing it in place.
	line    int
	keyExpr string
	single  bool
}

var (
	quotedRe     = regexp.MustCompile(`"([^"]*)"`)
	digitCodeRe  = regexp.MustCompile(`digitCode\(\w+\)`)
	bindHeaderRe = regexp.MustCompile(`^-+\s*([A-Za-z&][A-Za-z &]+?)\s*-+$`)
	bindNoteRe   = regexp.MustCompile(`\)\s*--\s*(.+)$`)
	spacesRe     = regexp.MustCompile(`\s+`)
)

func keyParts(expr string) []string {
	expr = strings.ReplaceAll(expr, "mainMod", `"SUPER"`)
	expr = digitCodeRe.ReplaceAllString(expr, `"1-0"`)
	var text strings.Builder
	for _, m := range quotedRe.FindAllStringSubmatch(expr, -1) {
		text.WriteString(m[1])
	}
	var out []string
	for _, p := range strings.Split(text.String(), "+") {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		name, ok := keyNames[p]
		if !ok {
			name = p
			if len(p) == 1 {
				name = strings.ToUpper(p)
			}
		}
		out = append(out, name)
	}
	return out
}

func describeBind(action, comment string) string {
	if d, ok := applyRules(bindDescs, action); ok {
		return d
	}
	if comment != "" {
		return strings.ToUpper(comment[:1]) + comment[1:]
	}
	s := spacesRe.ReplaceAllString(action, " ")
	if len(s) > 60 {
		s = s[:60]
	}
	return s
}

func titleCase(s string) string {
	words := strings.Fields(s)
	for i, w := range words {
		words[i] = strings.ToUpper(w[:1]) + strings.ToLower(w[1:])
	}
	return strings.Join(words, " ")
}

func splitBind(inner string) (string, string, bool) {
	depth := 0
	for i, ch := range inner {
		switch ch {
		case '(', '{':
			depth++
		case ')', '}':
			depth--
		case ',':
			if depth == 0 {
				return inner[:i], inner[i+1:], true
			}
		}
	}
	return "", "", false
}

// parseBinds reads the hl.bind statements of a Lua file. userIDs maps a bind's
// combo to its launcher result, for binds the launcher generated.
func parseBinds(text string, userIDs map[string]string) []bindEntry {
	group := "General"
	var binds []bindEntry
	vars := bindVariables(text)
	stmt, depth, start, active := "", 0, 0, false
	seen := map[string]bool{}
	for n, raw := range strings.Split(text, "\n") {
		line := strings.TrimSpace(raw)
		if !active {
			if h := bindHeaderRe.FindStringSubmatch(line); h != nil {
				group = titleCase(h[1])
				if r, ok := bindGroupRename[group]; ok {
					group = r
				}
				continue
			}
			if strings.HasPrefix(line, "--") {
				for _, sg := range bindSubgroups {
					if strings.HasPrefix(strings.TrimLeft(line, "-# "), sg[0]) {
						group = sg[1]
					}
				}
				continue
			}
			if !strings.Contains(line, "hl.bind(") {
				continue
			}
			stmt, depth, start, active = "", 0, n, true
		}
		stmt += " " + line
		depth += strings.Count(line, "(") - strings.Count(line, ")")
		if depth > 0 {
			continue
		}
		active = false
		s, comment := strings.TrimSpace(stmt), ""
		if m := bindNoteRe.FindStringSubmatchIndex(s); m != nil {
			comment = strings.TrimSpace(s[m[2]:m[3]])
			s = s[:m[0]+1]
		}
		inner := s[strings.Index(s, "hl.bind(")+8:]
		keyExpr, action, ok := splitBind(inner)
		if !ok {
			continue
		}
		keys := keyParts(keyExpr)
		if len(keys) == 0 {
			continue
		}
		desc := describeBind(action, comment)
		sig := strings.Join(keys, "\x00") + "\x00" + desc
		if seen[sig] {
			continue
		}
		seen[sig] = true
		target, _ := applyRules(bindTargets, action)
		if m := quotedRe.FindStringSubmatch(keyExpr); m != nil && userIDs[m[1]] != "" {
			target = userIDs[m[1]]
		}
		single := n == start && !strings.Contains(keyExpr, "digitCode")
		cmd, dispatch := replayBind(action, vars)
		binds = append(binds, bindEntry{Group: group, Keys: keys, Desc: desc, Target: target, Fixed: !single, Cmd: cmd, Dispatch: dispatch,
			line: start, keyExpr: keyExpr, single: single})
	}
	return binds
}

var (
	localStringRe = regexp.MustCompile(`(?m)^local (\w+) = (.+?)(?:\s+--.*)?$`)
	execCmdRe     = regexp.MustCompile(`^\s*hl\.dsp\.exec_cmd\((.*)\)\s*$`)
	plainDspRe    = regexp.MustCompile(`^\s*(hl\.dsp\.[\w.]+\(.*\))\s*$`)
	identRe       = regexp.MustCompile(`"[^"]*"|[A-Za-z_]\w*`)
)

// luaString evaluates a concatenation of string literals and known variables.
func luaString(expr string, vars map[string]string) (string, bool) {
	var out strings.Builder
	for _, part := range strings.Split(expr, "..") {
		part = strings.TrimSpace(part)
		if len(part) >= 2 && part[0] == '"' && part[len(part)-1] == '"' {
			out.WriteString(part[1 : len(part)-1])
		} else if v, ok := vars[part]; ok {
			out.WriteString(v)
		} else {
			return "", false
		}
	}
	return out.String(), true
}

// bindVariables reads the top-level string variables a binds file uses.
func bindVariables(text string) map[string]string {
	vars := map[string]string{}
	for role, name := range roleVars {
		if v := readDefaults()[role]; v != "" {
			vars[name] = v
		}
	}
	for _, m := range localStringRe.FindAllStringSubmatch(text, -1) {
		if v, ok := luaString(m[2], vars); ok {
			vars[m[1]] = v
		}
	}
	return vars
}

// replayBind works out how to run a bind's action from outside Hyprland's config.
func replayBind(action string, vars map[string]string) (string, string) {
	action = strings.TrimSuffix(strings.TrimSpace(action), ")") // hl.bind's own closing paren
	if first, _, ok := splitBind(action); ok {
		action = first // drop trailing options such as { repeating = true }
	}
	if m := execCmdRe.FindStringSubmatch(action); m != nil {
		cmd, _ := luaString(m[1], vars)
		return cmd, ""
	}
	m := plainDspRe.FindStringSubmatch(action)
	if m == nil {
		return "", ""
	}
	// A dispatcher can be sent as is only if it uses nothing but literals and field names.
	for _, tok := range identRe.FindAllString(m[1], -1) {
		if tok[0] != '"' && (tok == "i" || tok == "key" || tok == "digitCode" || tok == "function") {
			return "", ""
		}
	}
	if strings.Contains(m[1], "drag") || strings.Contains(m[1], "resize") {
		return "", ""
	}
	return "", m[1]
}

func cmdBinds(src, out string) {
	extra := filepath.Join(filepath.Dir(src), "launcher_binds.lua")
	if built, ok := mtime(out); ok {
		exe, _ := os.Executable()
		stale := false
		for _, p := range []string{src, extra, exe} {
			if t, ok := mtime(p); ok && t > built {
				stale = true
			}
		}
		if !stale {
			fmt.Println("fresh")
			return
		}
	}
	raw, err := os.ReadFile(src)
	if err != nil {
		return
	}
	binds := parseBinds(string(raw), nil)
	if rawExtra, err := os.ReadFile(extra); err == nil {
		userIDs := map[string]string{}
		for combo, b := range loadUserBinds() {
			userIDs[combo] = b.ID
		}
		binds = append(binds, parseBinds(string(rawExtra), userIDs)...)
	}
	if binds == nil {
		binds = []bindEntry{}
	}
	writeAtomic(out, []byte(jsonText(binds)))
}
