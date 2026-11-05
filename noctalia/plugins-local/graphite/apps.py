#!/usr/bin/env python3
"""List launchable desktop apps as JSON for the graphite launcher.

  apps.py OUT.json

Writes [{id, name, comment, hay, icon}] (icon = resolved file path or "").
Scanning in Luau blew the panel's CPU budget, so this runs async and the
launcher shows the previous cache until it finishes.
"""
import configparser
import json
import os
import sys

HOME = os.path.expanduser("~")
APP_DIRS = [
    f"{HOME}/.local/share/applications",
    f"{HOME}/.local/share/flatpak/exports/share/applications",
    "/var/lib/flatpak/exports/share/applications",
    "/usr/local/share/applications",
    "/usr/share/applications",
]
ICON_BASES = [f"{HOME}/.local/share/icons", f"{HOME}/.icons", "/usr/local/share/icons", "/usr/share/icons",
              "/var/lib/flatpak/exports/share/icons", f"{HOME}/.local/share/flatpak/exports/share/icons"]
SIZES = ["scalable", "64x64", "64", "48x48", "48", "128x128", "128", "96x96", "256x256", "32x32", "32"]
DESKTOP = "Hyprland"


def icon_theme():
    try:
        cp = configparser.ConfigParser(interpolation=None)
        cp.read(f"{HOME}/.config/gtk-3.0/settings.ini")
        return cp.get("Settings", "gtk-icon-theme-name", fallback="hicolor")
    except Exception:
        return "hicolor"


def theme_chain(name, seen=None):
    seen = seen or []
    if name in seen:
        return seen
    seen.append(name)
    for base in ICON_BASES:
        idx = os.path.join(base, name, "index.theme")
        if os.path.exists(idx):
            cp = configparser.ConfigParser(interpolation=None, strict=False)
            try:
                cp.read(idx)
                for parent in cp.get("Icon Theme", "Inherits", fallback="").split(","):
                    if parent.strip():
                        theme_chain(parent.strip(), seen)
            except Exception:
                pass
            break
    return seen


def build_icon_index(themes):
    """name -> path, first theme / best size wins."""
    index = {}
    for theme in themes + ["hicolor"]:
        for base in ICON_BASES:
            root = os.path.join(base, theme)
            if not os.path.isdir(root):
                continue
            for size in SIZES:
                for layout in (os.path.join(root, size, "apps"), os.path.join(root, "apps", size)):
                    if not os.path.isdir(layout):
                        continue
                    for f in os.listdir(layout):
                        stem, ext = os.path.splitext(f)
                        if ext in (".svg", ".png") and stem not in index:
                            index[stem] = os.path.join(layout, f)
    for f in os.listdir("/usr/share/pixmaps") if os.path.isdir("/usr/share/pixmaps") else []:
        stem, ext = os.path.splitext(f)
        if ext in (".svg", ".png") and stem not in index:
            index[stem] = os.path.join("/usr/share/pixmaps", f)
    return index


def parse(path):
    cp = configparser.ConfigParser(interpolation=None, strict=False)
    cp.optionxform = str
    try:
        cp.read(path, encoding="utf-8")
        e = cp["Desktop Entry"]
    except Exception:
        return None
    if e.get("Type") != "Application" or e.get("NoDisplay") == "true" or e.get("Hidden") == "true":
        return None
    only = [d for d in e.get("OnlyShowIn", "").split(";") if d]
    if only and DESKTOP not in only:
        return None
    if DESKTOP in e.get("NotShowIn", "").split(";"):
        return None
    if not e.get("Name") or not e.get("Exec"):
        return None
    return e


def main():
    out = sys.argv[1]
    icons = build_icon_index(theme_chain(icon_theme()))
    seen, apps = set(), []
    for d in APP_DIRS:
        if not os.path.isdir(d):
            continue
        for f in sorted(os.listdir(d)):
            if not f.endswith(".desktop"):
                continue
            id_ = f[:-8]
            if id_ in seen:
                continue
            seen.add(id_)  # earlier (user) dirs shadow later ones, even when hidden
            e = parse(os.path.join(d, f))
            if not e:
                continue
            icon = e.get("Icon", "")
            path = icon if icon.startswith("/") and os.path.exists(icon) else icons.get(icon, "")
            comment = e.get("Comment") or e.get("GenericName") or ""
            apps.append({
                "id": id_,
                "name": e["Name"],
                "comment": comment,
                "hay": " ".join([e.get("GenericName", ""), comment, e.get("Keywords", ""), id_]).lower(),
                "icon": path,
            })
    tmp = out + ".tmp"
    with open(tmp, "w") as f:
        json.dump(apps, f, ensure_ascii=False)
    os.replace(tmp, out)
    print(len(apps))


if __name__ == "__main__":
    main()
