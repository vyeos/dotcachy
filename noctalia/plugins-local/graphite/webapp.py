#!/usr/bin/env python3
"""Create a browser-backed web app for the graphite launcher.

  webapp.py NAME URL [ICON]

ICON is a local path or an image link. Without it the icon is looked up on the
site: web manifest, <link> icons, the usual root paths, then DuckDuckGo's favicon
service as a last resort (the only time the host name leaves for a third party).

Prints one JSON object, always with "status":
  ok        id, name, url, icon   the launcher entry exists
  no-icon   host                  nothing usable found, call again with ICON
  bad-icon  message               ICON could not be used
  bad-name | bad-url | exists     nothing was written
"""
import http.client
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from html.parser import HTMLParser
from urllib.parse import quote, urljoin, urlsplit, urlunsplit
from urllib.request import Request, urlopen

BROWSER = "brave-origin"
HOME = os.path.expanduser("~")
APPS = f"{HOME}/.local/share/applications"
ICONS = f"{HOME}/.local/share/icons/webapps"

UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"
PAGE_MAX = 2_000_000
ICON_MAX = 5_000_000
BUDGET_S = 25         # the panel gives up at 40 s
GOOD_SIZE = 96        # stop looking once an icon is at least this big
MIN_SIZE = 16
ICON_SIZE = 256


def say(status, **fields):
    print(json.dumps({"status": status, **fields}, ensure_ascii=False))


def normalize_url(raw):
    raw = raw.strip()
    if "://" not in raw:
        raw = "https://" + raw
    try:
        p = urlsplit(raw)
        host = p.hostname or ""
        p.port  # raises on a malformed port
        netloc = p.netloc.encode("idna").decode()
    except (ValueError, UnicodeError):
        return None
    if p.scheme not in ("http", "https") or re.search(r"\s", raw):
        return None
    if "." not in host and host != "localhost":
        return None
    # Percent-encode what a desktop file's Exec= could trip over ($, backtick, quotes).
    safe = "%:/?#[]@!&'()*+,;=~-._"
    return urlunsplit((p.scheme, netloc, quote(p.path, safe) or "/", quote(p.query, safe), quote(p.fragment, safe)))


def app_id(name, host):
    slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    return "webapp-" + (slug or re.sub(r"[^a-z0-9]+", "-", host.lower()).strip("-"))


def get(url, limit, deadline):
    """(body, final url), or (None, url) on any failure."""
    left = deadline - time.monotonic()
    if left <= 0:
        return None, url
    try:
        with urlopen(Request(url, headers={"User-Agent": UA, "Accept": "*/*"}), timeout=min(left, 6)) as r:
            data = r.read(limit + 1)
            return (None, url) if len(data) > limit else (data, r.geturl())
    except (OSError, ValueError, http.client.HTTPException):
        return None, url


def declared(sizes, href, kind, fallback):
    if href.lower().split("?")[0].endswith(".svg") or "svg" in (kind or ""):
        return 512
    sizes = (sizes or "").lower()
    if "any" in sizes:
        return 512
    found = [int(w) for w in re.findall(r"(\d+)x\d+", sizes)]
    return max(found) if found else fallback


class Head(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.icons, self.manifest, self.base = [], None, None

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        href = a.get("href")
        if not href:
            return
        if tag == "base" and not self.base:
            self.base = href
        if tag != "link":
            return
        rel = (a.get("rel") or "").lower().split()
        if "manifest" in rel:
            self.manifest = href
        elif "apple-touch-icon" in rel or "apple-touch-icon-precomposed" in rel:
            self.icons.append((href, declared(a.get("sizes"), href, a.get("type"), 180)))
        elif "icon" in rel:
            self.icons.append((href, declared(a.get("sizes"), href, a.get("type"), 32)))


def candidates(url, deadline):
    """Icon URLs the site offers, biggest declared size first."""
    found = []
    page, final = get(url, PAGE_MAX, deadline)
    if page:
        head = Head()
        try:
            head.feed(page.decode("utf-8", "replace"))
        except Exception:
            pass
        base = urljoin(final, head.base) if head.base else final
        found += [(urljoin(base, h), s) for h, s in head.icons]
        if head.manifest:
            murl = urljoin(base, head.manifest)
            raw, mfinal = get(murl, PAGE_MAX, deadline)
            try:
                for ic in json.loads(raw).get("icons", []) if raw else []:
                    if ic.get("src") and "monochrome" not in str(ic.get("purpose", "")):
                        found.append((urljoin(mfinal, ic["src"]), declared(ic.get("sizes"), ic["src"], ic.get("type"), 192)))
            except (ValueError, AttributeError):
                pass
    root = "{0.scheme}://{0.netloc}/".format(urlsplit(final))
    found += [(urljoin(root, "apple-touch-icon.png"), 180), (urljoin(root, "favicon.ico"), 16)]
    seen, out = set(), []
    for u, s in sorted(found, key=lambda x: -x[1]):
        if u not in seen and urlsplit(u).scheme in ("http", "https"):
            seen.add(u)
            out.append(u)
    return out[:10]


def sniff(data):
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "png"
    if data.startswith(b"\xff\xd8\xff"):
        return "jpeg"
    if data[:6] in (b"GIF87a", b"GIF89a"):
        return "gif"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "webp"
    if data[:4] == b"\x00\x00\x01\x00":
        return "ico"
    head = data[:4096].lstrip(b"\xef\xbb\xbf \t\r\n").lower()
    if b"<svg" in head and b"<html" not in head:
        return "svg"
    return None


def magick(args, tool=()):
    # The coder is always named explicitly from the sniffed bytes, so ImageMagick
    # never guesses a format from the content of a downloaded file.
    return subprocess.run(["magick", *tool, "-limit", "memory", "256MiB", "-limit", "time", "10", *args],
                          capture_output=True, text=True, timeout=15)


def to_icon(data, tmp, n):
    """Write data as an icon file in tmp. (path, size in px), or None if it isn't an image."""
    kind = sniff(data)
    if kind == "svg":
        path = os.path.join(tmp, f"{n}.svg")
        with open(path, "wb") as f:
            f.write(data)
        return path, 512
    if not kind:
        return None
    src = os.path.join(tmp, f"{n}.src")
    with open(src, "wb") as f:
        f.write(data)
    try:
        info = magick(["-format", "%w %h\n", f"{kind}:{src}"], tool=("identify",))
        frames = [tuple(map(int, line.split())) for line in info.stdout.splitlines() if line.strip()]
        if info.returncode != 0 or not frames:
            return None
        # An .ico holds several sizes; take the largest.
        idx = max(range(len(frames)), key=lambda i: frames[i][0] * frames[i][1])
        size = min(frames[idx])
        out = os.path.join(tmp, f"{n}.png")
        done = magick([f"{kind}:{src}[{idx}]", "-background", "none", "-resize", f"{ICON_SIZE}x{ICON_SIZE}>", f"PNG32:{out}"])
    except (ValueError, OSError, subprocess.TimeoutExpired):
        return None
    return (out, size) if done.returncode == 0 and os.path.exists(out) else None


def find_icon(url, host, tmp):
    deadline = time.monotonic() + BUDGET_S
    best = None
    for n, u in enumerate(candidates(url, deadline)):
        data, _ = get(u, ICON_MAX, deadline)
        got = to_icon(data, tmp, n) if data else None
        if got and got[1] >= MIN_SIZE and (not best or got[1] > best[1]):
            best = got
            if best[1] >= GOOD_SIZE:
                break
    if not best:
        data, _ = get(f"https://icons.duckduckgo.com/ip3/{host}.ico", ICON_MAX, deadline)
        got = to_icon(data, tmp, "ddg") if data else None
        if got and got[1] >= MIN_SIZE:
            best = got
    return best[0] if best else None


def user_icon(raw, tmp):
    """(path, None), or (None, reason) for an ICON the user gave."""
    raw = raw.strip()
    if raw.startswith("file://"):
        raw = raw[7:]
    if re.match(r"https?://", raw, re.I):
        data, _ = get(raw, ICON_MAX, time.monotonic() + BUDGET_S)
        if not data:
            return None, "Couldn't download that link"
    else:
        path = os.path.expanduser(raw)
        if not os.path.isabs(path):
            return None, "Use a full path, like ~/Pictures/icon.png"
        try:
            with open(path, "rb") as f:
                data = f.read(ICON_MAX + 1)
        except OSError:
            return None, "No readable file at that path"
        if len(data) > ICON_MAX:
            return None, "That file is over 5 MB"
    got = to_icon(data, tmp, "user")
    return (got[0], None) if got else (None, "That isn't a PNG, JPEG, WebP, GIF, ICO or SVG image")


def desktop_entry(name, url, host, icon):
    label = name.replace("\\", "\\\\")
    target = url.replace("%", "%%")  # % is a field code prefix in Exec=
    return (
        "[Desktop Entry]\n"
        "Type=Application\n"
        f"Name={label}\n"
        f"Comment=Web app · {host}\n"
        f'Exec={BROWSER} "--app={target}"\n'
        f"Icon={icon}\n"
        "Terminal=false\n"
        "Categories=Network;\n"
        "Keywords=webapp;\n"
    )


def write_atomic(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


def main():
    name = re.sub(r"[\x00-\x1f\x7f]", "", sys.argv[1]).strip()
    icon_arg = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3].strip() else None
    if not name:
        return say("bad-name")
    url = normalize_url(sys.argv[2])
    if not url:
        return say("bad-url")
    host = urlsplit(url).hostname
    id_ = app_id(name, host)
    entry = f"{APPS}/{id_}.desktop"
    if os.path.exists(entry):
        return say("exists", name=name)

    with tempfile.TemporaryDirectory() as tmp:
        if icon_arg:
            found, why = user_icon(icon_arg, tmp)
            if not found:
                return say("bad-icon", message=why)
        else:
            found = find_icon(url, host, tmp)
            if not found:
                return say("no-icon", host=host)
        os.makedirs(ICONS, exist_ok=True)
        os.makedirs(APPS, exist_ok=True)
        icon = f"{ICONS}/{id_}{os.path.splitext(found)[1]}"
        shutil.move(found, icon)

    write_atomic(entry, desktop_entry(name, url, host, icon))
    say("ok", id=id_, name=name, url=url, icon=icon)


if __name__ == "__main__":
    main()
