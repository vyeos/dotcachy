// vyeos login screen: a Quickshell greeter for greetd.
// Layout is the "Your pick" mock (https://claude.ai/artifact/657eQBB7K39hPjvnf26N1g),
// drawn on a 1440x900 grid and scaled to the output.
//
// Installed to /etc/greetd/vyeos/ by ../install-quickshell.sh, run by run.sh inside cage.
// Preview in a normal session: quickshell -p ~/.config/noctalia/greeter/quickshell/shell.qml
// (without greetd it opens as a 1440x900 window, and login and power keys only report).

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Greetd
import Quickshell.Services.UPower

ShellRoot {
    id: root

    readonly property string user: "vyeos"
    readonly property var session: ["/usr/bin/start-hyprland"]
    readonly property var sessionEnv: ["XDG_SESSION_TYPE=wayland", "XDG_CURRENT_DESKTOP=Hyprland", "XDG_SESSION_DESKTOP=Hyprland"]
    readonly property bool preview: !Greetd.available

    // graphite ramp (palettes/Graphite.json)
    readonly property color well: "#0e0f10"
    readonly property color surface: "#151618"
    readonly property color hover: "#26282b"
    readonly property color edge: "#33363a"
    readonly property color edgeHi: "#4b4f54"
    readonly property color primary: "#d3d6d9"
    readonly property color ink: "#ededeb"
    readonly property color sub: "#a6abb1"
    readonly property color err: "#c9a3a0"

    property string pending: ""
    property bool busy: false
    property string notice: ""

    function fail(msg) {
        busy = false;
        pending = "";
        notice = msg;
        noticeTimer.restart();
        if (Greetd.state !== GreetdState.Inactive)
            Greetd.cancelSession();
        pw.text = "";
        pw.forceActiveFocus();
    }

    function submit() {
        if (busy || pw.text.length === 0)
            return;
        if (preview) {
            notice = "Preview: greetd is not running";
            noticeTimer.restart();
            pw.text = "";
            return;
        }
        busy = true;
        notice = "";
        pending = pw.text;
        if (Greetd.state !== GreetdState.Inactive)
            Greetd.cancelSession();
        Greetd.createSession(user);
    }

    Connections {
        target: Greetd
        function onAuthMessage(message, error, responseRequired, echoResponse) {
            if (responseRequired) {
                Greetd.respond(root.pending);
                root.pending = "";
            } else if (error) {
                root.fail(message);
            }
        }
        function onReadyToLaunch() {
            Greetd.launch(root.session, root.sessionEnv, true);
        }
        function onAuthFailure(message) {
            root.fail("Wrong password");
        }
        function onError(error) {
            root.fail(error);
        }
    }

    Timer {
        id: noticeTimer
        interval: 2600
        onTriggered: root.notice = ""
    }

    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }

    // Power keys arm on the first click (the key inverts) and run on a second within 4 s.
    property int armed: -1
    Timer {
        id: armTimer
        interval: 4000
        onTriggered: root.armed = -1
    }
    Process { id: runner }
    readonly property var actions: [
        { icon: "cpu", label: "firmware", cmd: ["systemctl", "reboot", "--firmware-setup"] },
        { icon: "windows", label: "windows", cmd: ["/usr/local/bin/greeter-reboot-windows"] },
        { icon: "refresh", label: "reboot", cmd: ["systemctl", "reboot"] },
        { icon: "power", label: "shut down", cmd: ["systemctl", "poweroff"] }
    ]
    function press(i) {
        if (armed !== i) {
            armed = i;
            armTimer.restart();
            return;
        }
        armed = -1;
        armTimer.stop();
        if (preview) {
            notice = "Preview: would " + actions[i].label;
            noticeTimer.restart();
            return;
        }
        runner.exec(actions[i].cmd);
    }

    FloatingWindow {
        id: win
        title: "vyeos-greeter"
        color: root.well
        implicitWidth: 1440
        implicitHeight: 900

        Item {
            id: screen
            anchors.fill: parent
            // one unit = one px of the 1440x900 mock
            readonly property real s: Math.min(width / 1440, height / 900)

            Image {
                anchors.fill: parent
                source: Qt.resolvedUrl("wallpaper.png")
                fillMode: Image.PreserveAspectCrop
                smooth: true
                asynchronous: false
            }

            // date over time
            Column {
                anchors.horizontalCenter: parent.horizontalCenter
                y: 118 * screen.s
                spacing: 6 * screen.s
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: Qt.formatDateTime(clock.date, "dddd, dd MMMM")
                    font.family: "Graphite Sans"
                    font.weight: Font.Bold
                    font.pixelSize: 23 * screen.s
                    color: Qt.rgba(0.93, 0.93, 0.92, 0.85)
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: Qt.formatDateTime(clock.date, "HH:mm")
                    font.family: "Graphite Sans"
                    font.weight: Font.Bold
                    font.pixelSize: 150 * screen.s
                    font.letterSpacing: -3 * screen.s
                    color: Qt.rgba(0.93, 0.93, 0.92, 0.92)
                }
            }

            // battery, top right
            Row {
                id: batt
                visible: UPower.displayDevice.ready && UPower.displayDevice.energyCapacity > 0
                readonly property real pct: {
                    const p = UPower.displayDevice.percentage;
                    return Math.round(p <= 1 ? p * 100 : p);
                }
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.rightMargin: 36 * screen.s
                anchors.topMargin: 26 * screen.s
                spacing: 6 * screen.s
                Row {
                    anchors.verticalCenter: parent.verticalCenter
                    Rectangle {
                        width: 24 * screen.s
                        height: 13 * screen.s
                        color: "transparent"
                        border.color: root.ink
                        border.width: Math.max(1, 1.5 * screen.s)
                        Rectangle {
                            x: 3 * screen.s
                            y: 3 * screen.s
                            height: parent.height - 6 * screen.s
                            width: Math.max(1, (parent.width - 6 * screen.s) * batt.pct / 100)
                            color: root.ink
                        }
                    }
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 2 * screen.s
                        height: 5 * screen.s
                        color: root.ink
                    }
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: batt.pct
                    font.family: "Graphite Mono"
                    font.pixelSize: 14 * screen.s
                    color: root.ink
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "%"
                    font.family: "Graphite Mono"
                    font.pixelSize: 13 * screen.s
                    color: root.sub
                }
            }

            // password field, low and centred
            Rectangle {
                id: field
                width: 280 * screen.s
                height: 40 * screen.s
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 70 * screen.s
                color: Qt.rgba(0.08, 0.086, 0.094, 0.55)
                border.width: Math.max(1, screen.s)
                border.color: root.notice.length && !root.preview ? root.err : pw.activeFocus ? root.primary : root.edgeHi

                TextInput {
                    id: pw
                    anchors.fill: parent
                    anchors.leftMargin: 12 * screen.s
                    anchors.rightMargin: 12 * screen.s
                    verticalAlignment: TextInput.AlignVCenter
                    horizontalAlignment: TextInput.AlignHCenter
                    clip: true          // long passwords scroll inside the box
                    echoMode: TextInput.Password
                    passwordCharacter: "•"
                    font.family: "Graphite Mono"
                    font.pixelSize: 26 * screen.s
                    font.letterSpacing: 3 * screen.s
                    color: root.ink
                    selectionColor: root.edgeHi
                    cursorDelegate: Rectangle { width: Math.max(1, screen.s); color: root.ink; visible: pw.activeFocus && pw.text.length > 0 }
                    readOnly: root.busy
                    focus: true
                    Component.onCompleted: forceActiveFocus()
                    Keys.onReturnPressed: root.submit()
                    Keys.onEnterPressed: root.submit()
                    Keys.onEscapePressed: { text = ""; root.armed = -1; }
                }
                Text {
                    anchors.centerIn: parent
                    visible: pw.text.length === 0
                    text: root.busy ? "Signing in" : root.notice.length ? root.notice : "Enter Password"
                    font.family: "Graphite Mono"
                    font.pixelSize: 13 * screen.s
                    font.letterSpacing: 0.5 * screen.s
                    color: root.notice.length && !root.preview ? root.err : root.sub
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.IBeamCursor
                    onClicked: pw.forceActiveFocus()
                }
            }

            // power keys, bottom right: firmware, Windows, reboot, shut down
            Row {
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.rightMargin: 17 * screen.s
                anchors.bottomMargin: 23 * screen.s
                spacing: 6 * screen.s
                Repeater {
                    model: root.actions.length
                    delegate: Rectangle {
                        id: key
                        required property int index
                        readonly property var a: root.actions[index]
                        readonly property bool isArmed: root.armed === index
                        readonly property color fg: isArmed ? root.surface : root.ink
                        width: 37 * screen.s
                        height: 37 * screen.s
                        color: isArmed ? root.ink : mouse.containsMouse ? root.hover : Qt.rgba(0.08, 0.086, 0.094, 0.6)
                        border.width: Math.max(1, screen.s)
                        border.color: mouse.containsMouse || isArmed ? root.edgeHi : root.edge

                        Image {
                            visible: key.a.icon !== "windows"
                            anchors.centerIn: parent
                            width: 19 * screen.s
                            height: 19 * screen.s
                            sourceSize: Qt.size(width, height)
                            source: key.a.icon === "windows" ? "" : Qt.resolvedUrl("icons/" + key.a.icon + (key.isArmed ? "-inv" : "") + ".svg")
                        }
                        // four flat squares, as in the session panel (style.luau windowsMark)
                        Grid {
                            visible: key.a.icon === "windows"
                            anchors.centerIn: parent
                            readonly property int gap: Math.max(1, Math.round(17 * screen.s * 0.1))
                            readonly property int cell: Math.floor((17 * screen.s - gap) / 2)
                            columns: 2
                            spacing: gap
                            Repeater {
                                model: 4
                                Rectangle { width: parent.cell; height: parent.cell; color: key.fg }
                            }
                        }
                        MouseArea {
                            id: mouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.press(key.index)
                        }
                    }
                }
            }
        }
    }
}
