"""Minimal Wayland client that drives a real pointer through
zwlr_virtual_pointer_manager_v1 (pure stdlib).

Usage: python3 -I vptr.py <script>
script: semicolon-separated commands
  move X Y          absolute move in logical px
  click             left button press + release
  sleep S           wait S seconds
  shot NAME X Y W H grim capture of a region (scale 2) into $OUT/NAME.png
"""
import os
import socket
import struct
import subprocess
import sys
import time

OUT = os.environ.get("OUT", ".")
EXT_W, EXT_H = 1440, 900


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

    def send(self, obj, opcode, payload=b""):
        size = 8 + len(payload)
        self.s.sendall(struct.pack("<II", obj, (size << 16) | opcode) + payload)

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
    c.send(1, 1, struct.pack("<I", 2))   # wl_display.get_registry -> 2
    c.send(1, 0, struct.pack("<I", 3))   # wl_display.sync -> 3 (callback done = op 0)
    globals_ = {}
    for obj, op, body in c.read_events(3, 0):
        if obj == 2 and op == 0:          # wl_registry.global(name, interface, version)
            name, ln = struct.unpack("<II", body[:8])
            iface = body[8:8 + ln - 1].decode()
            ver = struct.unpack("<I", body[8 + ((ln + 3) & ~3):][:4])[0]
            globals_[iface] = (name, ver)
        if obj == 1 and op == 0:
            raise RuntimeError("protocol error: %r" % body)
    if "zwlr_virtual_pointer_manager_v1" not in globals_:
        raise SystemExit("compositor lacks zwlr_virtual_pointer_manager_v1")
    name, ver = globals_["zwlr_virtual_pointer_manager_v1"]
    # wl_registry.bind(name, interface, version, new_id=4)
    c.send(2, 0, struct.pack("<I", name) + wl_string("zwlr_virtual_pointer_manager_v1") + struct.pack("<II", min(ver, 2), 4))
    # manager.create_virtual_pointer(seat=null, id=5)
    c.send(4, 0, struct.pack("<II", 0, 5))
    t0 = time.monotonic()

    def ms():
        return int((time.monotonic() - t0) * 1000) & 0xFFFFFFFF

    def frame():
        c.send(5, 4)                       # frame

    for cmd in sys.argv[1].split(";"):
        parts = cmd.split()
        if not parts:
            continue
        if parts[0] == "move":
            x, y = float(parts[1]), float(parts[2])
            # motion_absolute(time, x, y, x_extent, y_extent)
            c.send(5, 1, struct.pack("<IIIII", ms(), int(x), int(y), EXT_W, EXT_H))
            frame()
        elif parts[0] == "wheel":
            c.send(5, 3, struct.pack("<IIi", ms(), 0, int(float(parts[1]) * 256))); frame()
        elif parts[0] == "mclick":
            c.send(5, 2, struct.pack("<III", ms(), 0x112, 1)); frame()
            time.sleep(0.05)
            c.send(5, 2, struct.pack("<III", ms(), 0x112, 0)); frame()
        elif parts[0] == "click":
            c.send(5, 2, struct.pack("<III", ms(), 0x110, 1)); frame()
            time.sleep(0.05)
            c.send(5, 2, struct.pack("<III", ms(), 0x110, 0)); frame()
        elif parts[0] == "sleep":
            time.sleep(float(parts[1]))
        elif parts[0] == "shot":
            n, x, y, w, h = parts[1], *parts[2:6]
            subprocess.run(["grim", "-g", f"{x},{y} {w}x{h}", "-s", "2", os.path.join(OUT, n + ".png")], check=True)
            print("shot", n, round(time.monotonic() - t0, 3), flush=True)
    c.send(5, 8)                           # destroy
    c.s.close()


main()
