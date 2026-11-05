#!/bin/sh
# Snapshot capture hook. Noctalia runs this only after a successful capture,
# with the PNG on stdin and the saved file in $NOCTALIA_SCREENSHOT_PATH.
#   $1  plugin data dir (records the last capture for the menu's preview)
#   $2  1 = show the notification, 0 = stay quiet
data_dir=$1
notify=${2:-1}

cat >/dev/null # drain the piped image; the file on disk is what we use

path=$NOCTALIA_SCREENSHOT_PATH
[ -n "$path" ] && [ -f "$path" ] || exit 0

if [ -n "$data_dir" ]; then
  mkdir -p "$data_dir" && printf '%s\n' "$path" > "$data_dir/last"
fi

[ "$notify" = 1 ] || exit 0
# Detach: notify-send blocks until the notification is clicked or dismissed.
setsid -f sh "$(dirname "$0")/notify.sh" "$path" >/dev/null 2>&1 </dev/null
