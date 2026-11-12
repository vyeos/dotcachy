#!/bin/sh
# vyeos login screen (Quickshell greeter under greetd).
#
#   sudo sh ~/.config/noctalia/greeter/install-quickshell.sh          install files, keep the current greeter
#   quickshell -p ~/.config/noctalia/greeter/quickshell/shell.qml     preview it as a window first
#   sudo sh ~/.config/noctalia/greeter/install-quickshell.sh enable   switch greetd to it
#   sudo sh ~/.config/noctalia/greeter/install-quickshell.sh disable  fall back to agreety (text login)
#
# If the new screen ever fails to come up: Ctrl+Alt+F2, log in, run the disable line.
# agreety ships with greetd (greetd-agreety) and logs in to Hyprland from the console.
set -eu
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
U=/home/vyeos
DEST=/etc/greetd/vyeos
CONF=/etc/greetd/config.toml
FALLBACK_CMD="agreety --cmd /usr/bin/start-hyprland"

set_command() {
  [ -f "$CONF.bak-noctalia" ] || cp -a "$CONF" "$CONF.bak-noctalia"   # original, from the noctalia-greeter days
  sed -i "s|^command = .*|command = \"$1\"|" "$CONF"
  grep -n '^command' "$CONF"
}

install_files() {
  pacman -S --needed quickshell cage

  # Graphite fonts system-wide (the greeter user can't see ~/.local/share/fonts)
  install -d -m 755 /usr/local/share/fonts/Graphite
  install -m 644 "$U"/.local/share/fonts/Graphite/*.ttf /usr/local/share/fonts/Graphite/
  fc-cache -f /usr/local/share/fonts/Graphite

  install -d -m 755 "$DEST" "$DEST/icons"
  install -m 644 "$HERE/quickshell/shell.qml" "$DEST/shell.qml"
  install -m 644 "$HERE"/quickshell/icons/*.svg "$DEST/icons/"
  install -m 644 "$HERE/wallpaper.png" "$DEST/wallpaper.png"
  install -m 755 "$HERE/quickshell/run.sh" "$DEST/run.sh"

  # Windows key: next boot only goes to Windows, then reboot. The greeter user
  # gets its own sudoers rule for windows-bootnext.
  if [ -x /usr/local/bin/windows-bootnext ]; then
    cat > /usr/local/bin/greeter-reboot-windows <<'EOF'
#!/bin/sh
# Greeter power key: next boot only goes to Windows, then reboot.
sudo -n /usr/local/bin/windows-bootnext && exec systemctl reboot
EOF
    chmod 0755 /usr/local/bin/greeter-reboot-windows
    printf 'greeter ALL=(root) NOPASSWD: /usr/local/bin/windows-bootnext\n' > /etc/sudoers.d/greeter-windows.tmp
    chmod 0440 /etc/sudoers.d/greeter-windows.tmp
    visudo -cf /etc/sudoers.d/greeter-windows.tmp >/dev/null
    mv /etc/sudoers.d/greeter-windows.tmp /etc/sudoers.d/greeter-windows
  else
    echo "Windows key will do nothing: install windows-bootnext first (sudo sh ~/.config/noctalia/bin/windows-bootnext install)."
  fi
  echo "Installed to $DEST."
}

case "${1:-install}" in
  install)
    install_files
    echo "Preview: quickshell -p $HERE/quickshell/shell.qml"
    echo "Switch:  sudo sh $0 enable"
    ;;
  enable)
    install_files
    set_command "$DEST/run.sh"
    echo "greetd now starts the vyeos greeter on the next logout or boot."
    ;;
  disable)
    set_command "$FALLBACK_CMD"
    echo "greetd now uses agreety, a text login on tty1."
    ;;
  *)
    echo "usage: sudo sh $0 [install|enable|disable]" >&2; exit 2 ;;
esac
