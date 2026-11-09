// Command graphite is the Graphite shell's native helper.
//
//	graphite app ID [new]         switch to the app's window, or start it; "new" always starts it
//	graphite focus|close|move-here ADDRESS
//	graphite close-app ID         close all of the app's windows
//	graphite reveal PATH          show PATH in Thunar
//	graphite web URL [new]        open URL in Brave: a tab in the open window, or a new window
//	graphite windows              print the open windows as JSON
//	graphite dispatch EXPR        send a Hyprland dispatcher expression
//	graphite gather               write live data (windows, files, connections) for the panel
//	graphite apps OUT             scan desktop apps
//	graphite binds LUA OUT        parse Hyprland binds
//	graphite clip DIR VERB [ID]   clipboard history
//	graphite bind ID LABEL COMBO CMD...   set, change or remove a keybind
//	graphite set-default ROLE ID  change the default terminal, browser, files or editor
//	graphite webapp NAME URL [ICON], webapp-rename, webapp-icon, webapp-delete
//	graphite task-menu ID CLASS   print a running app's tray menu and .desktop actions as JSON
//	graphite task-menu-click SERVICE MENUPATH ITEM   activate a tray menu item
//	graphite task-action DESKTOPFILE ACTION          run a .desktop action
//
// Only the standard library is used, so build.sh needs nothing but Go.
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"time"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: graphite <command> [args]")
		os.Exit(2)
	}
	args := os.Args[2:]
	switch os.Args[1] {
	case "app":
		cmdApp(args[0], len(args) > 1)
	case "focus":
		focus(args[0])
	case "close":
		closeWindow(args[0])
	case "move-here":
		moveHere(args[0])
	case "close-app":
		closeApp(args[0])
	case "reveal":
		reveal(args[0])
	case "web":
		openWeb(args[0], len(args) > 1)
	case "windows":
		printWindows()
	case "dispatch":
		dispatch(args[0])
	case "gather":
		cmdGather()
	case "apps":
		cmdApps(args[0])
	case "binds":
		cmdBinds(args[0], args[1])
	case "clip":
		cmdClip(args)
	case "bind":
		cmdBind(args)
	case "set-default":
		cmdSetDefault(args[0], args[1])
	case "webapp":
		cmdWebapp(args)
	case "webapp-rename":
		cmdWebappRename(args[0], args[1])
	case "webapp-icon":
		cmdWebappIcon(args[0], args[1])
	case "webapp-delete":
		cmdWebappDelete(args[0])
	case "task-menu":
		cmdTaskMenu(args[0], args[1])
	case "task-menu-click":
		cmdTaskMenuClick(args[0], args[1], args[2])
	case "task-action":
		cmdTaskAction(args[0], args[1])
	default:
		fmt.Fprintln(os.Stderr, "unknown command:", os.Args[1])
		os.Exit(2)
	}
}

func hyprSocket(name string) string {
	return filepath.Join(os.Getenv("XDG_RUNTIME_DIR"), "hypr", os.Getenv("HYPRLAND_INSTANCE_SIGNATURE"), name)
}

// hyprRequest sends one command on Hyprland's request socket and returns the reply.
func hyprRequest(cmd string) ([]byte, error) {
	conn, err := net.Dial("unix", hyprSocket(".socket.sock"))
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(2 * time.Second))
	if _, err := conn.Write([]byte(cmd)); err != nil {
		return nil, err
	}
	var reply []byte
	buf := make([]byte, 65536)
	for {
		n, err := conn.Read(buf)
		reply = append(reply, buf[:n]...)
		if err != nil {
			if err == io.EOF {
				return reply, nil
			}
			return nil, err
		}
	}
}

func hyprJSON(cmd string, into any) error {
	reply, err := hyprRequest(cmd)
	if err != nil {
		return err
	}
	return json.Unmarshal(reply, into)
}
