# Streams the Hyprland events the Graphite bar cares about, one per line.
# Run by service.luau through noctalia.runStream.
import os
import socket
import sys

WANTED = {
    b"workspace", b"workspacev2", b"createworkspace", b"createworkspacev2",
    b"destroyworkspace", b"destroyworkspacev2", b"focusedmon", b"focusedmonv2",
    b"activewindow", b"activewindowv2", b"openwindow", b"closewindow",
    b"movewindow", b"movewindowv2", b"windowtitle", b"windowtitlev2",
}

path = os.path.join(
    os.environ.get("XDG_RUNTIME_DIR", ""), "hypr",
    os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", ""), ".socket2.sock",
)
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(path)
buf = b""
while True:
    data = sock.recv(4096)
    if not data:
        break
    buf += data
    *lines, buf = buf.split(b"\n")
    for line in lines:
        if line.split(b">>", 1)[0] in WANTED:
            sys.stdout.write(line.decode("utf-8", "replace") + "\n")
            sys.stdout.flush()
