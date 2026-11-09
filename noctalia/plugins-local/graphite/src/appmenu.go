package main

// The options a running app offers itself, for the tasks drawer's right-click menu:
// its tray menu (StatusNotifierItem + DBusMenu) and the actions in its .desktop file.
// D-Bus goes through busctl, which keeps this file to the standard library.

import (
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const busTimeout = 1500 * time.Millisecond

type menuRow struct {
	Kind    string `json:"kind"` // item, header or sep
	ID      int32  `json:"id,omitempty"`
	Label   string `json:"label,omitempty"`
	Enabled bool   `json:"enabled,omitempty"`
	Toggle  string `json:"toggle,omitempty"` // checkmark or radio
	Checked bool   `json:"checked,omitempty"`
}

type desktopAction struct {
	Name  string `json:"name"`
	Label string `json:"label"`
}

type taskMenu struct {
	Service string          `json:"service"`
	Path    string          `json:"path"`
	Items   []menuRow       `json:"items"`
	Desktop string          `json:"desktop"`
	Actions []desktopAction `json:"actions"`
}

// busctl wraps every reply as {"type": ..., "data": ...}, variants included.
type variant struct {
	Data json.RawMessage `json:"data"`
}

// busOut runs busctl on the session bus and unmarshals the reply's data.
func busOut(into any, args ...string) bool {
	// "--": GetLayout's depth argument is -1, which busctl would take for an option.
	argv := append([]string{"busctl", "--user", "--json=short", "--timeout=1", "--"}, args...)
	raw := outputBytes(busTimeout, nil, argv...)
	if raw == nil {
		return false
	}
	var v variant
	return json.Unmarshal(raw, &v) == nil && json.Unmarshal(v.Data, into) == nil
}

func busProperty(into any, service, path, iface, name string) bool {
	return busOut(into, "get-property", service, path, iface, name)
}

const (
	watcherName = "org.kde.StatusNotifierWatcher"
	itemIface   = "org.kde.StatusNotifierItem"
	menuIface   = "com.canonical.dbusmenu"
)

// ownerComm names the process that owns a bus name.
func ownerComm(service string) string {
	var reply []uint32
	if !busOut(&reply, "call", "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
		"GetConnectionUnixProcessID", "s", service) || len(reply) == 0 {
		return ""
	}
	raw, err := os.ReadFile(fmt.Sprintf("/proc/%d/comm", reply[0]))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(raw))
}

// findTray returns the tray item of the app whose process or item id matches.
func findTray(id, class string) (service, path string) {
	var items []string
	if !busProperty(&items, watcherName, "/StatusNotifierWatcher", watcherName, "RegisteredStatusNotifierItems") {
		return "", ""
	}
	id, class = strings.ToLower(id), strings.ToLower(class)
	for _, entry := range items {
		service, path, found := strings.Cut(entry, "/")
		if found {
			path = "/" + path
		} else {
			path = "/StatusNotifierItem"
		}
		var itemID string
		busProperty(&itemID, service, path, itemIface, "Id")
		for _, name := range []string{strings.ToLower(ownerComm(service)), strings.ToLower(itemID)} {
			if name != "" && (name == id || name == class || strings.HasPrefix(name, id)) {
				return service, path
			}
		}
	}
	return "", ""
}

type menuNode struct {
	ID       int32
	Props    map[string]variant
	Children []menuNode
}

// A DBusMenu node is the struct (id, properties, children as variants).
func (n *menuNode) UnmarshalJSON(raw []byte) error {
	var fields []json.RawMessage
	if err := json.Unmarshal(raw, &fields); err != nil {
		return err
	}
	if len(fields) != 3 {
		return fmt.Errorf("menu node has %d fields", len(fields))
	}
	var kids []variant
	if err := json.Unmarshal(fields[0], &n.ID); err != nil {
		return err
	}
	if err := json.Unmarshal(fields[1], &n.Props); err != nil {
		return err
	}
	if err := json.Unmarshal(fields[2], &kids); err != nil {
		return err
	}
	n.Children = make([]menuNode, len(kids))
	for i, kid := range kids {
		if err := json.Unmarshal(kid.Data, &n.Children[i]); err != nil {
			return err
		}
	}
	return nil
}

func (n menuNode) str(key string) string {
	var s string
	if v, ok := n.Props[key]; ok {
		json.Unmarshal(v.Data, &s)
	}
	return s
}

func (n menuNode) flag(key string, fallback bool) bool {
	if v, ok := n.Props[key]; ok {
		json.Unmarshal(v.Data, &fallback)
	}
	return fallback
}

func (n menuNode) toggled() bool {
	var state int32
	if v, ok := n.Props["toggle-state"]; ok {
		json.Unmarshal(v.Data, &state)
	}
	return state == 1
}

func menuLayout(service, path string) (menuNode, bool) {
	// Reply is (revision, root node); busctl hands the two back as an array.
	var reply []json.RawMessage
	var root menuNode
	ok := busOut(&reply, "call", service, path, menuIface, "GetLayout", "iias", "0", "-1", "0") &&
		len(reply) == 2 && json.Unmarshal(reply[1], &root) == nil
	return root, ok
}

func aboutToShow(service, path string, id int32) {
	var ignored []bool
	busOut(&ignored, "call", service, path, menuIface, "AboutToShow", "i", strconv.Itoa(int(id)))
}

// announceSubmenus tells the app its submenus are opening; some only fill them then.
func announceSubmenus(service, path string, n menuNode) (announced bool) {
	for _, kid := range n.Children {
		if len(kid.Children) > 0 || kid.str("children-display") == "submenu" {
			aboutToShow(service, path, kid.ID)
			announceSubmenus(service, path, kid)
			announced = true
		}
	}
	return announced
}

var mnemonics = strings.NewReplacer("__", "_", "_", "")

// flatten lists a menu top to bottom; a submenu becomes a heading over its items.
func flatten(n menuNode, rows []menuRow) []menuRow {
	for _, kid := range n.Children {
		switch {
		case !kid.flag("visible", true):
		case kid.str("type") == "separator":
			rows = append(rows, menuRow{Kind: "sep"})
		case len(kid.Children) > 0:
			rows = append(rows, menuRow{Kind: "header", Label: mnemonics.Replace(kid.str("label"))})
			rows = flatten(kid, rows)
		default:
			rows = append(rows, menuRow{
				Kind: "item", ID: kid.ID, Label: mnemonics.Replace(kid.str("label")),
				Enabled: kid.flag("enabled", true), Toggle: kid.str("toggle-type"), Checked: kid.toggled(),
			})
		}
	}
	return rows
}

// tidySeparators drops separators at the ends and repeats of them.
func tidySeparators(rows []menuRow) []menuRow {
	tidy := make([]menuRow, 0, len(rows))
	for _, row := range rows {
		if row.Kind == "sep" && (len(tidy) == 0 || tidy[len(tidy)-1].Kind == "sep") {
			continue
		}
		tidy = append(tidy, row)
	}
	if len(tidy) > 0 && tidy[len(tidy)-1].Kind == "sep" {
		tidy = tidy[:len(tidy)-1]
	}
	return tidy
}

func trayRows(service, path string) (items []menuRow, menuPath string) {
	if service == "" || !busProperty(&menuPath, service, path, itemIface, "Menu") || menuPath == "" || menuPath == "/NO_DBUSMENU" {
		return []menuRow{}, ""
	}
	aboutToShow(service, menuPath, 0)
	root, ok := menuLayout(service, menuPath)
	if !ok {
		return []menuRow{}, ""
	}
	if announceSubmenus(service, menuPath, root) {
		if again, ok := menuLayout(service, menuPath); ok {
			root = again
		}
	}
	return tidySeparators(flatten(root, nil)), menuPath
}

// desktopSections splits a .desktop file into {group: {key: value}}.
func desktopSections(file string) map[string]map[string]string {
	raw, err := os.ReadFile(file)
	if err != nil {
		return nil
	}
	sections := map[string]map[string]string{}
	var current map[string]string
	for _, line := range strings.Split(string(raw), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			current = map[string]string{}
			sections[line[1:len(line)-1]] = current
		} else if key, value, ok := strings.Cut(line, "="); ok && current != nil && !strings.HasPrefix(line, "#") {
			current[strings.TrimSpace(key)] = strings.TrimSpace(value)
		}
	}
	return sections
}

func taskDesktopFile(id, class string) string {
	for _, a := range loadApps() {
		if strings.EqualFold(a.ID, id) || owns(&a, class) || owns(&a, id) {
			return a.Path
		}
	}
	return ""
}

func desktopActions(file string) []desktopAction {
	actions := []desktopAction{}
	sections := desktopSections(file)
	for _, name := range strings.Split(sections["Desktop Entry"]["Actions"], ";") {
		if group := sections["Desktop Action "+name]; name != "" && group["Name"] != "" && group["Exec"] != "" {
			actions = append(actions, desktopAction{Name: name, Label: group["Name"]})
		}
	}
	return actions
}

func cmdTaskMenu(id, class string) {
	service, path := findTray(id, class)
	items, menuPath := trayRows(service, path)
	desktop := taskDesktopFile(id, class)
	fmt.Println(jsonText(taskMenu{Service: service, Path: menuPath, Items: items, Desktop: desktop, Actions: desktopActions(desktop)}))
}

func cmdTaskMenuClick(service, menuPath, id string) {
	var ignored []any
	busOut(&ignored, "call", service, menuPath, menuIface, "Event", "isvu", id, "clicked", "s", "", "0")
}

var fieldCodes = regexp.MustCompile(`%[fFuUdDnNickvm]`)

func cmdTaskAction(file, name string) {
	command := desktopSections(file)["Desktop Action "+name]["Exec"]
	if command == "" {
		return
	}
	command = strings.ReplaceAll(fieldCodes.ReplaceAllString(command, ""), "%%", "%")
	spawn("sh", "-c", "exec "+command)
}
