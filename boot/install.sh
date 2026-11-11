#!/bin/sh
# vyeos boot look: the Plymouth splash and the Limine menu. Needs root:
#   sudo sh ~/.config/boot/install.sh            install or update
#   sudo sh ~/.config/boot/install.sh restore    back to the CachyOS splash and menu
#
# Limine: our options go in a "# vyeos-begin ... # vyeos-end" block at the top of
# /boot/limine.conf, replacing any global option of the same name. A dated backup
# of limine.conf is kept next to it. Running it again is safe.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
conf=/boot/limine.conf
keys='wallpaper|wallpaper_style|backdrop|interface_branding|interface_branding_colou?r|interface_help_hidden|term_margin|term_margin_gradient|term_background|term_foreground|term_foreground_bright|term_background_bright|term_palette|term_palette_bright'

[ "$(id -u)" = 0 ] || { echo "Run it with sudo: sudo sh $0 ${1:-}"; exit 1; }
[ -f "$conf" ] || { echo "No $conf, is Limine your boot loader?"; exit 1; }

cp "$conf" "$conf.bak-vyeos-$(date +%Y%m%d-%H%M%S)"

# limine.conf without our block and without the global options we set
# (globals = lines before the first "/" entry)
strip() {
  awk -v keys="^[ \t]*(${keys})[ \t]*:" '
    /^# vyeos-begin/ { skip = 1; next }
    /^# vyeos-end/   { skip = 0; next }
    skip             { next }
    /^[ \t]*\//      { entries = 1 }
    !entries && $0 ~ keys { next }
    { print }' "$conf"
}

if [ "${1:-}" = "restore" ]; then
  strip > "$conf.new" && mv "$conf.new" "$conf"
  rm -f /boot/vyeos-limine.png
  plymouth-set-default-theme cachyos
  limine-mkinitcpio
  echo "Restored the CachyOS splash and the default Limine look."
  exit 0
fi

# 1. Splash
install -d /usr/share/plymouth/themes/vyeos
install -m 644 "$here"/plymouth/vyeos.plymouth "$here"/plymouth/vyeos.script \
  "$here"/plymouth/v.png "$here"/plymouth/on.png "$here"/plymouth/off.png /usr/share/plymouth/themes/vyeos/
plymouth-set-default-theme vyeos

# 2. Boot menu
install -m 644 "$here/limine/vyeos-limine.png" /boot/vyeos-limine.png
{ cat "$here/limine/globals.conf"; strip; } > "$conf.new"
mv "$conf.new" "$conf"

# 3. Rebuild the initramfs (it carries the splash) and refresh the Limine entries
limine-mkinitcpio

# A config hash enrolled into Limine would refuse an edited limine.conf: re-enroll.
if grep -q '^ENABLE_ENROLL_LIMINE_CONFIG=yes' /etc/limine-entry-tool.conf /etc/default/limine 2>/dev/null; then
  limine-enroll-config
fi

echo "Done. Reboot to see the vyeos boot menu and splash."
