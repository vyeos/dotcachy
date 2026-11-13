package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

// Cursor themes: listed from the usual icon folders, applied everywhere a theme
// name is kept so new apps, running GTK apps and Hyprland all agree.

func cursorDirs() []string {
	home := homeDir()
	return []string{home + "/.local/share/icons", home + "/.icons", "/usr/share/icons"}
}

// cursorTheme returns the folder of an installed cursor theme, or "".
func cursorTheme(name string) string {
	if name == "" || name == "default" || strings.ContainsAny(name, "/\n") {
		return ""
	}
	for _, d := range cursorDirs() {
		p := filepath.Join(d, name)
		if st, err := os.Stat(filepath.Join(p, "cursors")); err == nil && st.IsDir() {
			return p
		}
	}
	return ""
}

// cmdCursors prints the installed cursor themes as JSON: [{name, label, hypr, current}].
func cmdCursors() {
	current := currentCursor()
	seen := map[string]bool{}
	type theme struct {
		Name    string `json:"name"`
		Label   string `json:"label"`
		Hypr    bool   `json:"hypr"`
		Current bool   `json:"current"`
	}
	out := []theme{}
	for _, d := range cursorDirs() {
		entries, _ := os.ReadDir(d)
		for _, e := range entries {
			n := e.Name()
			if seen[n] || cursorTheme(n) == "" {
				continue
			}
			seen[n] = true
			label := n
			if raw, err := os.ReadFile(filepath.Join(d, n, "index.theme")); err == nil {
				if m := regexp.MustCompile(`(?m)^Name\s*=\s*"?([^"\n]+)"?`).FindSubmatch(raw); m != nil {
					label = strings.TrimSpace(string(m[1]))
				}
			}
			_, herr := os.Stat(filepath.Join(d, n, "manifest.hl"))
			out = append(out, theme{n, label, herr == nil, n == current})
		}
	}
	sort.Slice(out, func(i, j int) bool { return strings.ToLower(out[i].Label) < strings.ToLower(out[j].Label) })
	fmt.Println(jsonText(out))
}

func envLua() string         { return configDir() + "/hypr/config/environment.lua" }
func envD() string           { return configDir() + "/environment.d/graphite.conf" }
func gtkIni(v string) string { return configDir() + "/gtk-" + v + ".0/settings.ini" }

func currentCursor() string {
	raw, _ := os.ReadFile(envLua())
	if m := regexp.MustCompile(`hl\.env\("XCURSOR_THEME",\s*"([^"]*)"\)`).FindSubmatch(raw); m != nil {
		return string(m[1])
	}
	return ""
}

func cursorSize() string {
	raw, _ := os.ReadFile(envLua())
	if m := regexp.MustCompile(`hl\.env\("XCURSOR_SIZE",\s*"(\d+)"\)`).FindSubmatch(raw); m != nil {
		return string(m[1])
	}
	return "24"
}

// setLine replaces the first line matching re with line, or adds line after the
// line matching after (or at the end) when there is none.
func setLine(raw []byte, re *regexp.Regexp, line string, after *regexp.Regexp) []byte {
	if loc := re.FindIndex(raw); loc != nil {
		return append(append(append([]byte{}, raw[:loc[0]]...), line...), raw[loc[1]:]...)
	}
	if after != nil {
		if loc := after.FindIndex(raw); loc != nil {
			end := loc[1]
			return append(append(append([]byte{}, raw[:end]...), "\n"+line...), raw[end:]...)
		}
	}
	if len(raw) > 0 && raw[len(raw)-1] != '\n' {
		raw = append(raw, '\n')
	}
	return append(raw, line+"\n"...)
}

func editFile(path string, edit func([]byte) []byte) error {
	raw, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	edited := edit(raw)
	if string(edited) == string(raw) {
		return nil
	}
	return writeAtomic(path, edited)
}

func cmdCursor(name string) {
	if cursorTheme(name) == "" {
		sayStatus("missing", map[string]any{"theme": name})
		return
	}
	size := cursorSize()
	var failed []string
	note := func(what string, err error) {
		if err != nil {
			failed = append(failed, what)
		}
	}

	note("hyprland", editFile(envLua(), func(raw []byte) []byte {
		luaEnv := func(key string) *regexp.Regexp {
			return regexp.MustCompile(`(?m)^hl\.env\("` + key + `",\s*"[^"]*"\)`)
		}
		line := func(key, v string) string { return fmt.Sprintf(`hl.env("%s", "%s")`, key, v) }
		raw = setLine(raw, luaEnv("XCURSOR_THEME"), line("XCURSOR_THEME", name), nil)
		raw = setLine(raw, luaEnv("HYPRCURSOR_THEME"), line("HYPRCURSOR_THEME", name), luaEnv("XCURSOR_SIZE"))
		raw = setLine(raw, luaEnv("HYPRCURSOR_SIZE"), line("HYPRCURSOR_SIZE", size), luaEnv("HYPRCURSOR_THEME"))
		return raw
	}))
	note("environment.d", editFile(envD(), func(raw []byte) []byte {
		kv := func(key string) *regexp.Regexp { return regexp.MustCompile(`(?m)^` + key + `=.*$`) }
		raw = setLine(raw, kv("XCURSOR_THEME"), "XCURSOR_THEME="+name, nil)
		raw = setLine(raw, kv("HYPRCURSOR_THEME"), "HYPRCURSOR_THEME="+name, kv("XCURSOR_SIZE"))
		raw = setLine(raw, kv("HYPRCURSOR_SIZE"), "HYPRCURSOR_SIZE="+size, kv("HYPRCURSOR_THEME"))
		return raw
	}))
	for _, v := range []string{"3", "4"} {
		note("gtk-"+v, editFile(gtkIni(v), func(raw []byte) []byte {
			settings := regexp.MustCompile(`(?m)^\[Settings\]$`)
			raw = setLine(raw, regexp.MustCompile(`(?m)^gtk-cursor-theme-name=.*$`), "gtk-cursor-theme-name="+name, settings)
			raw = setLine(raw, regexp.MustCompile(`(?m)^gtk-cursor-theme-size=.*$`), "gtk-cursor-theme-size="+size, regexp.MustCompile(`(?m)^gtk-cursor-theme-name=.*$`))
			return raw
		}))
	}
	// X apps that ignore XCURSOR_THEME fall back to the "default" theme.
	def := homeDir() + "/.icons/default"
	os.MkdirAll(def, 0o755)
	note("icons/default", writeAtomic(def+"/index.theme", []byte("[Icon Theme]\nName=Default\nComment=Default Cursor Theme\nInherits="+name+"\n")))

	note("gsettings", exec.Command("gsettings", "set", "org.gnome.desktop.interface", "cursor-theme", name).Run())
	note("gsettings", exec.Command("gsettings", "set", "org.gnome.desktop.interface", "cursor-size", size).Run())
	// Let Hyprland's config watcher settle on the edited environment.lua first.
	time.Sleep(300 * time.Millisecond)
	reply, err := hyprRequest("setcursor " + name + " " + size)
	if err != nil || strings.TrimSpace(string(reply)) != "ok" {
		failed = append(failed, "hyprctl")
	}
	if len(failed) > 0 {
		sayStatus("partial", map[string]any{"theme": name, "failed": failed})
		return
	}
	sayStatus("ok", map[string]any{"theme": name})
}
