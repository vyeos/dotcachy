#!/bin/sh
# Install the graphite greeter config. Run: sudo sh ~/.config/noctalia/greeter/install.sh
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
STATE=/var/lib/noctalia-greeter
U=/home/vyeos

# 1. Graphite fonts system-wide (greeter user can't see ~/.local/share/fonts)
install -d -m 755 /usr/local/share/fonts/Graphite
install -m 644 "$U"/.local/share/fonts/Graphite/*.ttf /usr/local/share/fonts/Graphite/
fc-cache -f /usr/local/share/fonts/Graphite

# 2. Wallpaper (same image as the desktop)
install -o greeter -g greeter -m 644 "$U/Pictures/Wallpapers/wallhaven-5ypy88.jpg" "$STATE/wallpaper.jpg"

# 3. Config (back up any existing one first)
[ -f "$STATE/greeter.toml" ] && cp -a "$STATE/greeter.toml" "$STATE/greeter.toml.bak-$(date +%Y%m%d%H%M%S)"
install -o greeter -g greeter -m 644 "$HERE/greeter.toml" "$STATE/greeter.toml"

echo "Installed. Preview: log out (greeter re-reads appearance on start)."
echo "Check fonts: fc-list | grep -i 'Graphite Sans'"
