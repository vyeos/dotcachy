#!/usr/bin/env python3
"""Read Hyprland's Lua binds file and write the shortcuts list as JSON.

Usage: binds.py <binds.lua> <out.json>

Each hl.bind(...) becomes {group, keys: [..], desc}. Groups come from the big
"---- NAME ----" headers. Binds inside `for i = 1, NUM_WPM` loops collapse to a
single "1-0" row, since their keys and descriptions come out identical. Descriptions come from the table below; an unknown action
falls back to the line's trailing comment, then to the raw dispatcher.
"""
import json
import os
import re
import sys

KEY_NAMES = {
    "SUPER": "Super", "CONTROL": "Ctrl", "CTRL": "Ctrl", "SHIFT": "Shift", "ALT": "Alt",
    "Return": "Enter", "Escape": "Esc", "Space": "Space", "Tab": "Tab", "period": ".",
    "comma": ",", "slash": "/", "Minus": "-", "minus": "-", "Plus": "+", "plus": "+",
    "mouse:272": "LMB drag", "mouse:273": "RMB drag", "mouse_up": "Scroll up",
    "mouse_down": "Scroll down", "code:82": "Num -", "code:86": "Num +", "Print": "Print",
    "XF86AudioRaiseVolume": "Vol +", "XF86AudioLowerVolume": "Vol -", "XF86AudioMute": "Mute",
    "XF86AudioMicMute": "Mic mute", "XF86AudioPlay": "Play", "XF86AudioPause": "Pause",
    "XF86AudioNext": "Next", "XF86AudioPrev": "Prev", "XF86MonBrightnessUp": "Bright +",
    "XF86MonBrightnessDown": "Bright -", "XF86Calculator": "Calc",
}

# Small comment headings that start their own group (the rest stay under the
# big header above them).
SUBGROUPS = [("Graphite panels", "Panels"), ("Quick toggles", "Quick Toggles")]
GROUP_RENAME = {"Launcher": "Apps & Shell"}

# (regex on the action text, description). First match wins; order matters.
DESCS = [
    (r"window\.close", "Close window"),
    (r"hyprctl kill", "Kill a window (click it)"),
    (r"window\.float", "Toggle floating"),
    (r"fullscreen\(\{ mode = 1", "Maximize window"),
    (r"window\.fullscreen\(", "Fullscreen"),
    (r"togglesplit", "Toggle split direction"),
    (r"focus\(\{ direction = \"(\w+)\"", "Focus window {0}"),
    (r"cycle_next", "Cycle windows"),
    (r"graphite:switcher", "Window switcher"),
    (r"move\(\{ direction = \"u\"", "Move window up"),
    (r"move\(\{ direction = \"d\"", "Move window down"),
    (r"move\(\{ direction = \"l\"", "Move window left"),
    (r"move\(\{ direction = \"r\"", "Move window right"),
    (r"move\(\{ monitor = \"-1\"", "Move window to previous monitor"),
    (r"move\(\{ monitor = \"\+1\"", "Move window to next monitor"),
    (r"move\(\{ workspace = \"m~\" \.\. i, follow = false", "Move window to workspace (stay)"),
    (r"move\(\{ workspace = \"m~\"", "Move window to workspace"),
    (r"move\(\{ workspace = \"m\+1\"", "Move window to next workspace"),
    (r"move\(\{ workspace = \"m-1\"", "Move window to previous workspace"),
    (r"move\(\{ workspace = \"special\"", "Move window to scratchpad"),
    (r"window\.drag", "Move window"),
    (r"window\.resize", "Resize window"),
    (r"zoomfunction\(-", "Zoom out"),
    (r"zoomfunction\(", "Zoom in"),
    (r"btop", "System monitor (btop)"),
    (r"TERMINAL", "Terminal"),
    (r"FILE_MANAGER", "File manager"),
    (r"EDITOR", "Editor"),
    (r"graphite:calc", "Calculator"),
    (r"BROWSER", "Browser"),
    (r"settings-toggle", "Noctalia settings"),
    (r"clock all panel", "Control center"),
    (r"clock all calendar", "Calendar"),
    (r"graphite:session-panel", "Session menu"),
    (r"graphite:launcher", "App launcher"),
    (r"graphite:emoji", "Emoji picker"),
    (r"graphite:shortcuts", "Keyboard shortcuts"),
    (r"session lock", "Lock screen"),
    (r"battery all panel", "Power panel"),
    (r"audio all panel", "Audio panel"),
    (r"bluetooth all panel", "Bluetooth panel"),
    (r"wifi all panel", "Wi-Fi panel"),
    (r"drawer toggle", "Notifications"),
    (r"caffeine toggle", "Toggle caffeine"),
    (r"night toggle", "Toggle night light"),
    (r"\"bt toggle", "Toggle Bluetooth"),
    (r"\"wifi toggle", "Toggle Wi-Fi"),
    (r"profile next", "Cycle power profile"),
    (r"dnd toggle", "Toggle do not disturb"),
    (r"volume-up", "Volume up"),
    (r"volume-down", "Volume down"),
    (r"volume-mute", "Mute audio"),
    (r"mic-mute", "Mute microphone"),
    (r"media toggle", "Play / pause"),
    (r"media next", "Next track"),
    (r"media previous", "Previous track"),
    (r"brightness-up", "Brightness up"),
    (r"brightness-down", "Brightness down"),
    (r"hyprpicker", "Color picker"),
    (r"screenshot-region", "Screenshot region"),
    (r"screenshot-fullscreen", "Screenshot screen"),
    (r"graphite-shot annotate", "Annotate last screenshot"),
    (r"graphite:wallpaper", "Wallpaper picker"),
    (r"graphite:clip", "Clipboard history"),
    (r"focus\(\{ workspace = i \}", "Go to workspace"),
    (r"focus\(\{ workspace = \"m~\"", "Go to workspace on this monitor"),
    (r"focus\(\{ workspace = \"m\+1\"", "Next workspace"),
    (r"focus\(\{ workspace = \"m-1\"", "Previous workspace"),
    (r"focus\(\{ workspace = \"emptym\"", "Next empty workspace"),
    (r"toggle_special", "Toggle scratchpad"),
]


def key_parts(expr):
    """`mainMod .. " + SHIFT + " .. digitCode(key)` -> ["Super", "Shift", "1-0"]."""
    expr = expr.replace("mainMod", '"SUPER"')
    expr = re.sub(r"digitCode\(\w+\)", '"1-0"', expr)
    text = "".join(re.findall(r'"([^"]*)"', expr))
    parts = [p.strip() for p in text.split("+")]
    out = []
    for i, p in enumerate(parts):
        if p == "":
            # "Plus" written as a literal "+" would split to empties; keep one
            continue
        out.append(KEY_NAMES.get(p, p if len(p) > 1 else p.upper()))
    return out


def describe(action, comment):
    for pat, desc in DESCS:
        m = re.search(pat, action)
        if m:
            return desc.format(*m.groups())
    if comment:
        return comment[0].upper() + comment[1:]
    return re.sub(r"\s+", " ", action)[:60]


def fresh(src, out):
    try:
        return os.path.getmtime(out) >= max(os.path.getmtime(src), os.path.getmtime(os.path.abspath(__file__)))
    except OSError:
        return False


def main():
    src, out = sys.argv[1], sys.argv[2]
    if fresh(src, out):
        print("fresh")
        return
    lines = open(src, encoding="utf-8").read().split("\n")
    group = "General"
    stmt = None
    depth = 0
    binds = []
    seen = set()
    for raw in lines:
        line = raw.strip()
        if stmt is None:
            h = re.match(r"^-+\s*([A-Za-z&][A-Za-z &]+?)\s*-+$", line)
            if h:
                group = h.group(1).strip().title()
                group = GROUP_RENAME.get(group, group)
                continue
            if line.startswith("--"):
                for pre, name in SUBGROUPS:
                    if line.lstrip("-# ").startswith(pre):
                        group = name
                continue
            if "hl.bind(" not in line:
                continue
            stmt, depth = "", 0
        stmt += " " + line
        depth += line.count("(") - line.count(")")
        if depth > 0:
            continue
        s, stmt = stmt.strip(), None
        comment = ""
        cm = re.search(r"\)\s*--\s*(.+)$", s)
        if cm:
            comment = cm.group(1).strip()
            s = s[: cm.start() + 1]
        inner = s[s.index("hl.bind(") + 8 :]
        # split the key expression from the action at the first top-level comma
        d, cut = 0, None
        for i, ch in enumerate(inner):
            if ch in "({":
                d += 1
            elif ch in ")}":
                d -= 1
            elif ch == "," and d == 0:
                cut = i
                break
        if cut is None:
            continue
        keys = key_parts(inner[:cut])
        action = inner[cut + 1 :]
        if not keys:
            continue
        desc = describe(action, comment)
        sig = (tuple(keys), desc)
        if sig in seen:
            continue
        seen.add(sig)
        binds.append({"group": group, "keys": keys, "desc": desc})
    with open(out + ".tmp", "w", encoding="utf-8") as f:
        json.dump(binds, f, ensure_ascii=False)
    os.replace(out + ".tmp", out)


if __name__ == "__main__":
    main()
