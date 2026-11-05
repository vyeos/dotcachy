#!/bin/sh
# Shows the capture notification and reacts to it:
#   click (default action) -> open the Noctalia annotator on the image
#   "Open folder"          -> open the save folder
path=$1
dir=$(dirname "$path")
name=$(basename "$path")
stem=$(printf '%s' "${name%.*}" | sed 's/%/%%/g')

action=$(timeout 900 notify-send \
  --app-name=Snapshot \
  --icon="$path" \
  --hint=string:image-path:"$path" \
  --action=default=Annotate \
  --action=annotate=Annotate \
  --action=open="Open folder" \
  "Screenshot copied" \
  "$name — click to annotate")

case $action in
  default|annotate)
    exec noctalia msg annotate "$path" \
      --directory "$dir" --filename-pattern "${stem}_annotated" --copy-to-clipboard ;;
  open)
    exec xdg-open "$dir" ;;
esac
