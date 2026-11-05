#!/usr/bin/env python3
"""Everything the Graphite service reacts to, as one stream of tagged lines.

  events.py DATA_DIR

One process replaces the service's polling loops: it holds the Hyprland event
socket, answers it over the request socket (no hyprctl spawns), and supervises
the event watchers below, restarting any that exit. Output, one per line:

  ws<TAB>json  wsActive<TAB>id  win<TAB>json  windows    Hyprland
  vol  dev                                               sink/source changed, added/removed
  net  bt  power                                         NetworkManager, BlueZ, UPower + profiles
  clip                                                   clipboard history changed
  notif<TAB>line                                         raw dbus-monitor output

It exits with its parent, and takes its children along: PDEATHSIG covers a kill,
the stdout check covers the pipe going away, the ppid check covers the rest.
dbus-monitor must not be started bare, it ignores SIGPIPE and would never exit.
"""
import atexit
import ctypes
import json
import os
import re
import signal
import socket
import subprocess
import sys
import threading
import time

PR_SET_PDEATHSIG = 1
libc = ctypes.CDLL(None, use_errno=True)
HERE = os.path.dirname(os.path.abspath(__file__))
out_lock = threading.Lock()
children = set()


def die_with_parent():
    libc.prctl(PR_SET_PDEATHSIG, signal.SIGTERM)


def emit(tag, payload=None):
    line = tag if payload is None else f"{tag}\t{payload}"
    try:
        with out_lock:
            sys.stdout.write(line + "\n")
            sys.stdout.flush()
    except (BrokenPipeError, ValueError, OSError):
        os._exit(0)


# ── Debounce: a burst of changes becomes one line, 150 ms after the first. ──────

marks = set()
marks_cv = threading.Condition()


def mark(tag):
    with marks_cv:
        marks.add(tag)
        marks_cv.notify()


def flusher():
    while True:
        with marks_cv:
            while not marks:
                marks_cv.wait()
        time.sleep(0.15)
        with marks_cv:
            tags = list(marks)
            marks.clear()
        for t in tags:
            emit(t)


# ── Hyprland ────────────────────────────────────────────────────────────────────

WIN_EVENTS = {b"activewindow", b"activewindowv2", b"windowtitle", b"windowtitlev2"}
WS_EVENTS = {b"createworkspace", b"createworkspacev2", b"destroyworkspace", b"destroyworkspacev2"}
ALL_EVENTS = {b"workspace", b"workspacev2", b"focusedmon", b"focusedmonv2",
              b"movewindow", b"movewindowv2", b"openwindow", b"closewindow"}
WINDOW_LIST = {b"openwindow", b"closewindow"}


def hypr_dir():
    return os.path.join(os.environ.get("XDG_RUNTIME_DIR", ""), "hypr",
                        os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", ""))


def request(cmd):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(2)
    s.connect(os.path.join(hypr_dir(), ".socket.sock"))
    s.sendall(cmd.encode())
    buf = b""
    while True:
        d = s.recv(65536)
        if not d:
            break
        buf += d
    s.close()
    return json.loads(buf.decode("utf-8", "replace"))


last_hypr = {}


def publish(tag, value):
    text = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    if last_hypr.get(tag) != text:
        last_hypr[tag] = text
        emit(tag, text)


def query(want):
    if "ws" in want:
        rows = [{"id": w["id"], "windows": w.get("windows", 0)}
                for w in request("j/workspaces") if isinstance(w.get("id"), int) and w["id"] > 0]
        publish("ws", sorted(rows, key=lambda w: w["id"]))
    if "active" in want:
        d = request("j/activeworkspace")
        if isinstance(d.get("id"), int):
            publish("wsActive", d["id"])
    if "win" in want:
        d = request("j/activewindow") or {}
        publish("win", {"cls": d.get("class", ""), "title": d.get("title", "")})


def hypr():
    while True:
        try:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.connect(os.path.join(hypr_dir(), ".socket2.sock"))
            query({"ws", "active", "win"})
            buf = b""
            while True:
                sock.setblocking(True)
                data = sock.recv(4096)
                if not data:
                    break
                time.sleep(0.04)  # let a burst pile up, then answer it once
                sock.setblocking(False)
                try:
                    while True:
                        more = sock.recv(65536)
                        if not more:
                            break
                        data += more
                except BlockingIOError:
                    pass
                buf += data
                *lines, buf = buf.split(b"\n")
                want = set()
                for line in lines:
                    ev = line.split(b">>", 1)[0]
                    if ev in WIN_EVENTS:
                        want.add("win")
                    elif ev in WS_EVENTS:
                        want.add("ws")
                    elif ev in ALL_EVENTS:
                        want |= {"ws", "active", "win"}
                    if ev in WINDOW_LIST:
                        mark("windows")
                if want:
                    query(want)
        except (OSError, ValueError):
            pass
        time.sleep(2)


# ── Watchers ────────────────────────────────────────────────────────────────────


def watch(argv, on_line):
    """Run argv forever, calling on_line for each line; restart it when it exits."""
    delay = 2
    while True:
        started = time.time()
        try:
            p = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                 stdin=subprocess.DEVNULL, preexec_fn=die_with_parent)
            children.add(p)
            for raw in p.stdout:
                on_line(raw.decode("utf-8", "replace").rstrip("\n"))
            p.wait()
            children.discard(p)
        except OSError:
            pass
        delay = 2 if time.time() - started > 30 else min(delay * 2, 60)
        time.sleep(delay)


def on_pactl(line):
    m = re.search(r"'(\w+)' on (sink|source|server)\b", line)
    if not m:
        return
    if m.group(1) in ("new", "remove"):
        mark("dev")
    mark("vol")


BT_RE = re.compile(r"'(Powered|Connected)'|InterfacesAdded|InterfacesRemoved")


def spawn(argv, on_line):
    threading.Thread(target=watch, args=(argv, on_line), daemon=True).start()


def cleanup():
    for p in list(children):
        try:
            p.terminate()
        except OSError:
            pass


def main():
    data_dir = sys.argv[1]
    die_with_parent()
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    atexit.register(cleanup)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    parent = os.getppid()

    threading.Thread(target=flusher, daemon=True).start()
    threading.Thread(target=hypr, daemon=True).start()
    spawn(["pactl", "subscribe"], on_pactl)
    spawn(["nmcli", "monitor"], lambda _l: mark("net"))
    spawn(["gdbus", "monitor", "--system", "--dest", "org.bluez"],
          lambda l: BT_RE.search(l) and mark("bt"))
    spawn(["upower", "--monitor"], lambda _l: mark("power"))
    spawn(["gdbus", "monitor", "--system", "--dest", "org.freedesktop.UPower.PowerProfiles"],
          lambda l: "ActiveProfile" in l and mark("power"))
    spawn(["dbus-monitor", "--session",
           "type='method_call',interface='org.freedesktop.Notifications',member='Notify'",
           "type='method_return',sender='org.freedesktop.Notifications'"],
          lambda l: emit("notif", l))
    spawn(["wl-paste", "--watch", "python3", "-u", os.path.join(HERE, "clip.py"), data_dir, "store"],
          lambda _l: mark("clip"))

    while os.getppid() == parent:
        time.sleep(15)


if __name__ == "__main__":
    main()
