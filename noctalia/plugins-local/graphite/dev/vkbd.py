"""Minimal Wayland client that types real keys through
zwp_virtual_keyboard_manager_v1 (pure stdlib, keymap from xkbcli).

Usage: python3 -I vkbd.py <script>
script: semicolon-separated commands
  key NAME          press + release
  hold NAME S       press, wait S seconds, release (Left Right Up Down Return Escape Tab space 1..5)
  sleep S           wait S seconds
  shot NAME X Y W H grim capture of a region (scale 2) into $OUT/NAME.png
"""
import array
import os
import socket
import struct
import subprocess
import sys
import time

OUT = os.environ.get("OUT", ".")
# evdev codes (us layout keymap is sent, so digits are the plain number row)
KEYS = {"Escape": 1, "1": 2, "2": 3, "3": 4, "4": 5, "5": 6, "Tab": 15, "Return": 28, "space": 57,
        "Up": 103, "Left": 105, "Right": 106, "Down": 108, "BackSpace": 14}
for row, start in (("qwertyuiop", 16), ("asdfghjkl", 30), ("zxcvbnm", 44)):
    for i, ch in enumerate(row):
        KEYS[ch] = start + i


def pad(b):
    return b + b"\0" * (-len(b) % 4)


def wl_string(s):
    raw = s.encode() + b"\0"
    return struct.pack("<I", len(raw)) + pad(raw)


class Conn:
    def __init__(self):
        path = os.path.join(os.environ["XDG_RUNTIME_DIR"], os.environ.get("WAYLAND_DISPLAY", "wayland-0"))
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.connect(path)
        self.buf = b""

    def send(self, obj, opcode, payload=b"", fds=None):
        size = 8 + len(payload)
        msg = struct.pack("<II", obj, (size << 16) | opcode) + payload
        if fds:
            self.s.sendmsg([msg], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", fds))])
        else:
            self.s.sendall(msg)

    def read_events(self, until_obj, until_opcode):
        events = []
        while True:
            while len(self.buf) >= 8:
                obj, so = struct.unpack("<II", self.buf[:8])
                size, op = so >> 16, so & 0xFFFF
                if len(self.buf) < size:
                    break
                events.append((obj, op, self.buf[8:size]))
                self.buf = self.buf[size:]
                if obj == until_obj and op == until_opcode:
                    return events
            data = self.s.recv(65536)
            if not data:
                raise RuntimeError("compositor closed the connection")
            self.buf += data


def main():
    c = Conn()
    c.send(1, 1, struct.pack("<I", 2))
    c.send(1, 0, struct.pack("<I", 3))
    g = {}
    for obj, op, body in c.read_events(3, 0):
        if obj == 2 and op == 0:
            name, ln = struct.unpack("<II", body[:8])
            iface = body[8:8 + ln - 1].decode()
            ver = struct.unpack("<I", body[8 + ((ln + 3) & ~3):][:4])[0]
            g[iface] = (name, ver)
    for need in ("wl_seat", "zwp_virtual_keyboard_manager_v1"):
        if need not in g:
            raise SystemExit("compositor lacks " + need)
    c.send(2, 0, struct.pack("<I", g["wl_seat"][0]) + wl_string("wl_seat") + struct.pack("<II", 1, 4))
    c.send(2, 0, struct.pack("<I", g["zwp_virtual_keyboard_manager_v1"][0]) + wl_string("zwp_virtual_keyboard_manager_v1") + struct.pack("<II", 1, 5))
    c.send(5, 0, struct.pack("<II", 4, 6))           # create_virtual_keyboard(seat, id=6)

    km = subprocess.run(["xkbcli", "compile-keymap", "--layout", "us"], capture_output=True, check=True).stdout + b"\0"
    fd = os.memfd_create("vkbd-keymap")
    os.write(fd, km)
    os.lseek(fd, 0, 0)
    c.send(6, 0, struct.pack("<II", 1, len(km)), fds=[fd])  # keymap(format=xkb_v1, fd, size)
    os.close(fd)
    c.send(1, 0, struct.pack("<I", 7)); c.read_events(7, 0)  # roundtrip
    t0 = time.monotonic()

    def ms():
        return int((time.monotonic() - t0) * 1000) & 0xFFFFFFFF

    for cmd in sys.argv[1].split(";"):
        parts = cmd.split()
        if not parts:
            continue
        if parts[0] == "key":
            code = KEYS[parts[1]]
            c.send(6, 1, struct.pack("<III", ms(), code, 1))
            time.sleep(0.04)
            c.send(6, 1, struct.pack("<III", ms(), code, 0))
            time.sleep(0.04)
        elif parts[0] == "hold":  # hold NAME SECONDS
            code = KEYS[parts[1]]
            c.send(6, 1, struct.pack("<III", ms(), code, 1))
            time.sleep(float(parts[2]))
            c.send(6, 1, struct.pack("<III", ms(), code, 0))
            time.sleep(0.04)
        elif parts[0] == "sleep":
            time.sleep(float(parts[1]))
        elif parts[0] == "shot":
            n, x, y, w, h = parts[1], *parts[2:6]
            subprocess.run(["grim", "-g", f"{x},{y} {w}x{h}", "-s", "2", os.path.join(OUT, n + ".png")], check=True)
            print("shot", n, flush=True)
    c.send(1, 0, struct.pack("<I", 8)); c.read_events(8, 0)
    c.send(6, 3)
    c.s.close()


main()
