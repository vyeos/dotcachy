-- Auto-start config
-- if you dont use UWSM add your auto start programs here, otherwise use XDG autostart https://wiki.archlinux.org/title/XDG_Autostart

hl.on("hyprland.start", function ()
    hl.exec_cmd("dbus-update-activation-environment --systemd --all")
    -- noctalia-start restarts the shell if it freezes on start (see the script)
    hl.exec_cmd("/home/vyeos/.config/noctalia/bin/noctalia-start")
    hl.exec_cmd("xhost +SI:localuser:root")
end)
