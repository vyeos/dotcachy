package main

// Lists launchable desktop apps as JSON for the launcher.
//
//	graphite apps OUT.json
//
// Prints "fresh" and does nothing when no source changed since OUT.json.

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

var iconSizes = []string{"scalable", "64x64", "64", "48x48", "48", "128x128", "128", "96x96", "256x256", "32x32", "32"}

const desktopName = "Hyprland"

type scannedApp struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	Comment    string `json:"comment"`
	Hay        string `json:"hay"`
	Icon       string `json:"icon"`
	Terminal   bool   `json:"terminal"`
	WMClass    string `json:"wmclass"`
	Path       string `json:"path"`
	Categories string `json:"categories"`
	Exec       string `json:"exec"`
}

// iniSection returns the keys of one [section] of an ini-style file, or nil if absent.
func iniSection(path, section string) map[string]string {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	var out map[string]string
	inside := false
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || line[0] == '#' || line[0] == ';' {
			continue
		}
		if line[0] == '[' {
			inside = line == "["+section+"]"
			if inside && out == nil {
				out = map[string]string{}
			}
			continue
		}
		if k, v, ok := strings.Cut(line, "="); ok && inside {
			out[strings.TrimSpace(k)] = strings.TrimSpace(v)
		}
	}
	return out
}

func iconBases() []string {
	h := homeDir()
	return []string{h + "/.local/share/icons", h + "/.icons", "/usr/local/share/icons", "/usr/share/icons",
		"/var/lib/flatpak/exports/share/icons", h + "/.local/share/flatpak/exports/share/icons"}
}

func themeChain(name string, seen *[]string) {
	for _, s := range *seen {
		if s == name {
			return
		}
	}
	*seen = append(*seen, name)
	for _, base := range iconBases() {
		idx := filepath.Join(base, name, "index.theme")
		if _, err := os.Stat(idx); err != nil {
			continue
		}
		for _, parent := range strings.Split(iniSection(idx, "Icon Theme")["Inherits"], ",") {
			if p := strings.TrimSpace(parent); p != "" {
				themeChain(p, seen)
			}
		}
		break
	}
}

func addIcons(index map[string]string, dir string) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	for _, e := range entries {
		ext := filepath.Ext(e.Name())
		stem := strings.TrimSuffix(e.Name(), ext)
		if ext != ".svg" && ext != ".png" {
			continue
		}
		if _, taken := index[stem]; !taken {
			index[stem] = filepath.Join(dir, e.Name())
		}
	}
}

// buildIconIndex maps icon name to path; first theme and best size win.
func buildIconIndex(themes []string) map[string]string {
	index := map[string]string{}
	for _, theme := range append(themes, "hicolor") {
		for _, base := range iconBases() {
			root := filepath.Join(base, theme)
			if fi, err := os.Stat(root); err != nil || !fi.IsDir() {
				continue
			}
			for _, size := range iconSizes {
				addIcons(index, filepath.Join(root, size, "apps"))
				addIcons(index, filepath.Join(root, "apps", size))
			}
		}
	}
	addIcons(index, "/usr/share/pixmaps")
	return index
}

func listContains(semi, want string) bool {
	for _, p := range strings.Split(semi, ";") {
		if p == want {
			return true
		}
	}
	return false
}

func parseDesktop(path string) map[string]string {
	e := iniSection(path, "Desktop Entry")
	if e == nil || e["Type"] != "Application" || e["NoDisplay"] == "true" || e["Hidden"] == "true" {
		return nil
	}
	if e["OnlyShowIn"] != "" && strings.Trim(e["OnlyShowIn"], ";") != "" && !listContains(e["OnlyShowIn"], desktopName) {
		return nil
	}
	if listContains(e["NotShowIn"], desktopName) || e["Name"] == "" || e["Exec"] == "" {
		return nil
	}
	return e
}

func appDirs() []string {
	h := homeDir()
	return []string{h + "/.local/share/applications", h + "/.local/share/flatpak/exports/share/applications",
		"/var/lib/flatpak/exports/share/applications", "/usr/local/share/applications", "/usr/share/applications"}
}

func mtime(path string) (int64, bool) {
	fi, err := os.Stat(path)
	if err != nil {
		return 0, false
	}
	return fi.ModTime().UnixNano(), true
}

var fieldCodeRe = regexp.MustCompile(`\s*%[a-zA-Z]`)

func cmdApps(out string) {
	gtk := homeDir() + "/.config/gtk-3.0/settings.ini"
	if built, ok := mtime(out); ok {
		exe, _ := os.Executable()
		stale := false
		for _, p := range append(appDirs(), gtk, exe) {
			if t, ok := mtime(p); ok && t > built {
				stale = true
				break
			}
		}
		if !stale {
			fmt.Println("fresh")
			return
		}
	}
	theme := iniSection(gtk, "Settings")["gtk-icon-theme-name"]
	if theme == "" {
		theme = "hicolor"
	}
	var chain []string
	themeChain(theme, &chain)
	icons := buildIconIndex(chain)

	seen := map[string]bool{}
	apps := []scannedApp{}
	for _, dir := range appDirs() {
		entries, err := os.ReadDir(dir)
		if err != nil {
			continue
		}
		names := make([]string, 0, len(entries))
		for _, e := range entries {
			names = append(names, e.Name())
		}
		sort.Strings(names)
		for _, f := range names {
			if !strings.HasSuffix(f, ".desktop") {
				continue
			}
			id := strings.TrimSuffix(f, ".desktop")
			if seen[id] {
				continue
			}
			seen[id] = true // earlier (user) dirs shadow later ones, even when hidden
			path := filepath.Join(dir, f)
			e := parseDesktop(path)
			if e == nil {
				continue
			}
			icon := icons[e["Icon"]]
			if strings.HasPrefix(e["Icon"], "/") {
				if _, err := os.Stat(e["Icon"]); err == nil {
					icon = e["Icon"]
				}
			}
			comment := e["Comment"]
			if comment == "" {
				comment = e["GenericName"]
			}
			apps = append(apps, scannedApp{
				ID: id, Name: e["Name"], Comment: comment,
				Hay:  strings.ToLower(strings.Join([]string{e["GenericName"], comment, e["Keywords"], id}, " ")),
				Icon: icon, Terminal: e["Terminal"] == "true", WMClass: e["StartupWMClass"], Path: path,
				Categories: ";" + strings.Trim(e["Categories"], ";") + ";",
				Exec:       fieldCodeRe.ReplaceAllString(e["Exec"], ""),
			})
		}
	}
	if writeAtomic(out, []byte(jsonText(apps))) == nil {
		fmt.Println(len(apps))
	}
}
