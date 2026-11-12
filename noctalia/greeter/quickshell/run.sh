#!/bin/sh
# greetd runs this as the greeter user: cage hosts the Quickshell login screen.
# Log of the last start: /tmp/vyeos-greeter.log
export QT_QPA_PLATFORM=wayland
export QT_WAYLAND_DISABLE_WINDOWDECORATION=1
exec cage -s -m last -- quickshell -p /etc/greetd/vyeos/shell.qml >/tmp/vyeos-greeter.log 2>&1
