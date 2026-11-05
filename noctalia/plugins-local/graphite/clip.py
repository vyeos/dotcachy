#!/usr/bin/env python3
"""Graphite clipboard history store.

The service runs `wl-paste --watch python3 -u clip.py <dir> store`, so every
selection change calls `store` once. The clip panel calls the other verbs.
This script is the only writer of <dir>/clip-index.json (guarded by a flock).

  clip.py DIR store          capture the current selection (stdin is drained)
  clip.py DIR copy ID        put entry ID back on the clipboard (moves it to top)
  clip.py DIR pin ID         toggle the pin on entry ID
  clip.py DIR del ID         delete entry ID
  clip.py DIR clear          delete every unpinned entry

clip-index.json: newest first, [{id, kind: "text"|"image", t, size, hash, pinned,
text (preview, at most TEXT_MAX bytes), full (path of the whole text when it is
longer than that), file (image path), w, h}]
"""
import fcntl
import hashlib
import json
import os
import struct
import subprocess
import sys
import time

MAX_UNPINNED = 100
TEXT_MAX = 8_000            # longer text lives in its own file; this much is indexed
SKIP_TYPES = ("x-kde-passwordManagerHint",)


def run(argv, stdin=None):
    try:
        return subprocess.run(argv, input=stdin, capture_output=True, timeout=5).stdout
    except Exception:
        return b""


def png_size(data):
    if data[:8] == b"\x89PNG\r\n\x1a\n" and len(data) >= 24:
        return struct.unpack(">II", data[16:24])
    return 0, 0


class Store:
    def __init__(self, root):
        self.root = root
        self.img = os.path.join(root, "clip")
        os.makedirs(self.img, exist_ok=True)
        self.path = os.path.join(root, "clip-index.json")
        self.lock = open(os.path.join(root, "clip.lock"), "w")
        fcntl.flock(self.lock, fcntl.LOCK_EX)
        try:
            with open(self.path, encoding="utf-8") as f:
                self.items = json.load(f)
        except Exception:
            self.items = []

    def save(self):
        unpinned = [i for i in self.items if not i.get("pinned")]
        for old in unpinned[MAX_UNPINNED:]:
            self.drop(old)
        tmp = self.path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(self.items, f, ensure_ascii=False)
        os.replace(tmp, self.path)
        print("changed", flush=True)

    def drop(self, item):
        if item in self.items:
            self.items.remove(item)
        for key in ("file", "full"):
            if item.get(key):
                try:
                    os.remove(item[key])
                except OSError:
                    pass

    def find(self, id_):
        return next((i for i in self.items if str(i["id"]) == str(id_)), None)

    def add(self, kind, data, **extra):
        h = hashlib.sha1(data).hexdigest()
        old = next((i for i in self.items if i.get("hash") == h), None)
        if old:  # seen before: just move it to the top
            self.items.remove(old)
            old["t"] = int(time.time())
            self.items.insert(0, old)
            return
        item = {"id": int(time.time() * 1000), "kind": kind, "t": int(time.time()),
                "size": len(data), "hash": h, "pinned": False}
        item.update(extra)
        self.items.insert(0, item)


def store(s):
    try:
        sys.stdin.buffer.read()  # drain what wl-paste handed us
    except Exception:
        pass
    types = run(["wl-paste", "--list-types"]).decode(errors="replace").split()
    if not types or any(t in SKIP_TYPES for t in types):
        return False
    img = next((t for t in types if t == "image/png"), None) or \
        next((t for t in types if t.startswith("image/")), None)
    texty = [t for t in types if t.startswith("text/plain") or t in ("UTF8_STRING", "STRING", "TEXT")]
    # Browsers offer an image alongside text/html; a copied picture has no plain text.
    if img and not texty:
        data = run(["wl-paste", "--no-newline", "--type", img])
        if not data:
            return False
        if img != "image/png":
            conv = run(["magick", "-", "png:-"], data)
            if conv:
                data, img = conv, "image/png"
        w, h = png_size(data)
        tmp = os.path.join(s.img, "incoming.png")
        with open(tmp, "wb") as f:
            f.write(data)
        before = len(s.items)
        s.add("image", data, w=w, h=h)
        top = s.items[0]
        if len(s.items) > before:  # new entry: keep the file
            top["file"] = os.path.join(s.img, f"{top['id']}.png")
            os.replace(tmp, top["file"])
        else:
            os.remove(tmp)
        return True
    if texty:
        pref = next((t for t in texty if "utf-8" in t.lower()), texty[0])
        data = run(["wl-paste", "--no-newline", "--type", pref])
        if not data.strip():
            return False
        before = len(s.items)
        s.add("text", data, text=data[:TEXT_MAX].decode(errors="ignore"))
        top = s.items[0]
        if len(s.items) > before and len(data) > TEXT_MAX:
            top["full"] = os.path.join(s.img, f"{top['id']}.txt")
            with open(top["full"], "wb") as f:
                f.write(data)
        return True
    return False


def copy(s, id_):
    item = s.find(id_)
    if not item:
        return False
    if item["kind"] == "image":
        with open(item["file"], "rb") as f:
            data = f.read()
        mime = "image/png"
    elif item.get("full"):
        with open(item["full"], "rb") as f:
            data = f.read()
        mime = "text/plain;charset=utf-8"
    else:
        data, mime = item["text"].encode(), "text/plain;charset=utf-8"
    subprocess.Popen(["wl-copy", "--type", mime], stdin=subprocess.PIPE).communicate(data)
    s.items.remove(item)
    item["t"] = int(time.time())
    s.items.insert(0, item)
    return True


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    s = Store(sys.argv[1])
    verb, arg = sys.argv[2], (sys.argv[3] if len(sys.argv) > 3 else None)
    changed = False
    if verb == "store":
        changed = store(s)
    elif verb == "copy":
        changed = copy(s, arg)
    elif verb == "pin":
        item = s.find(arg)
        if item:
            item["pinned"] = not item.get("pinned")
            changed = True
    elif verb == "del":
        item = s.find(arg)
        if item:
            s.drop(item)
            changed = True
    elif verb == "clear":
        for item in [i for i in s.items if not i.get("pinned")]:
            s.drop(item)
        changed = True
    if changed:
        s.save()


if __name__ == "__main__":
    main()
