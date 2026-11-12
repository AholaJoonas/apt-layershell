//@ pragma ShellId apt-layer-ui
//@ pragma AppId apt-layer
// apt-layer control window: status of APT / PoE / the overlay, settings, start/stop.
// Started with `apt-layer ui`. All work is done by bin/apt-layer; this only shows and calls it.

import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

ShellRoot {
    id: root

    readonly property string bin: Quickshell.shellPath("../bin/apt-layer")
    readonly property string ctl: Quickshell.shellPath("../bin/apt-layerctl")
    readonly property string launcher: Quickshell.shellPath("../bin/apt-layer-launch")

    property var st: null                // `apt-layer status --json`
    property string pending: ""          // action in progress ("" = none)
    property string outputText: ""       // doctor / log output
    property string outputTitle: ""

    readonly property bool aptRunning: st?.apt?.running ?? false
    readonly property bool overlayRunning: st?.overlay?.running ?? false
    readonly property bool testPage: overlayRunning && st?.overlay?.adapter === false
    // APT runs, but wasn't started for APT Layer (no --no-overlay; e.g. an AppImage manager's menu entry).
    readonly property bool aptWrong: aptRunning && st?.apt?.noOverlay === false
    readonly property bool poeRunning: st?.poe?.running ?? false
    // "Launch Path of Exile" was pressed; cleared when the game's window shows up (or after a minute).
    property bool gameLaunching: false
    onPoeRunningChanged: if (poeRunning) gameLaunching = false
    Timer { id: gameLaunchTimer; interval: 60000; onTriggered: root.gameLaunching = false }

    function refresh() { if (!statusProc.running) statusProc.running = true; }

    // Run a command; the buttons stay disabled for `ms` (or until the status shows it worked).
    function act(label, cmd, ms) {
        pending = label;
        Quickshell.execDetached(cmd);
        pendingTimer.interval = ms ?? 4000;
        pendingTimer.restart();
        quickRefresh.restart();
    }

    function setConfig(key, value) {
        configProc.command = [bin, "config", key, value];
        configProc.running = true;
    }

    // ---- Setup checks (`apt-layer doctor --json`, lib/checks.py) ----------------------------------
    property var checks: []
    readonly property var setupItems: checks.filter(c => c.level === "fail" || c.level === "warn" || c.level === "suggest")
    readonly property bool setupBlocked: checks.some(c => c.level === "fail")

    Process {
        id: checksProc
        command: [root.bin, "doctor", "--json"]
        stdout: StdioCollector {
            onStreamFinished: { try { root.checks = JSON.parse(text); } catch (e) { console.warn("bad checks:", e); } }
        }
    }
    function refreshChecks() { if (!checksProc.running) checksProc.running = true; }
    Timer { interval: 10000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.refreshChecks() }

    Process {
        id: buildProc
        command: ["sh", "-c", "\"$0\" build 2>&1", root.bin]
        stdout: StdioCollector { onStreamFinished: { root.outputTitle = "Build"; root.outputText = text || "(no output)"; } }
        onExited: { root.refreshChecks(); root.refresh(); }
    }
    function openUrl(url) { Quickshell.execDetached(["xdg-open", url]); }

    function showOutput(title, cmd) {
        outputTitle = title;
        outputText = "…";
        outputProc.command = cmd;
        outputProc.running = true;
    }

    function outputLabel(o) {
        return `${o.name} — ${o.label} (${o.width}×${o.height} at ${o.x},${o.y}${o.scale !== 1 ? ", scale " + o.scale : ""})`;
    }

    component Dot: Rectangle {
        property string level: "off"   // ok | warn | off
        implicitWidth: 10; implicitHeight: 10; radius: 5
        color: level === "ok" ? "#4caf6a" : level === "warn" ? "#d6a33a" : level === "fail" ? "#d9534f"
             : level === "suggest" ? "#5b9bd5" : "#5c616b"
    }

    Process {
        id: statusProc
        command: [root.bin, "status", "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.st = JSON.parse(text); } catch (e) { console.warn("bad status:", e); return; }
                if ((root.pending === "Starting" || root.pending === "Restarting APT") && !root.aptWrong
                    && root.overlayRunning && root.st.overlay.connected) root.pending = "";
            }
        }
    }
    Timer { interval: 2000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.refresh() }
    Timer { id: quickRefresh; interval: 700; onTriggered: root.refresh() }
    Timer { id: pendingTimer; interval: 15000; onTriggered: root.pending = "" }

    Process {
        id: configProc
        stderr: StdioCollector { onStreamFinished: if (text.trim()) root.showMessage(text.trim()) }
        onExited: { root.refresh(); root.refreshChecks(); }
    }
    function showMessage(m) { outputTitle = "Message"; outputText = m; }

    Process {
        id: menuProc
        stderr: StdioCollector { onStreamFinished: if (text.trim()) root.showMessage(text.trim()) }
        onExited: { root.refresh(); root.refreshChecks(); }
    }
    function menuEntry(action, kind) {
        menuProc.command = [bin, "menu-entry", action, kind];
        menuProc.running = true;
    }

    Process {
        id: outputProc
        stdout: StdioCollector {
            onStreamFinished: root.outputText = text.replace(/\x1b\[[0-9;]*m/g, "") || "(no output)"
        }
    }

    FloatingWindow {
        id: win
        title: "APT Layer UI"
        implicitWidth: 620
        implicitHeight: 700
        minimumSize: Qt.size(520, 520)
        // Quickshell keeps running without windows; closing the window ends the control window for good.
        onClosed: Qt.quit()
        color: pane.palette.window

        Pane {
            id: pane
            anchors.fill: parent
            padding: 16
            palette.window: "#1d1f24"
            palette.base: "#25282e"
            palette.alternateBase: "#2b2e35"
            palette.button: "#30343b"
            palette.text: "#e4e6eb"
            palette.windowText: "#e4e6eb"
            palette.buttonText: "#e4e6eb"
            palette.placeholderText: "#80858f"
            palette.highlight: "#c08a2e"
            palette.highlightedText: "#111111"
            palette.mid: "#3a3e46"
            palette.dark: "#15171b"
            palette.light: "#3d414a"

            // Inside the window: Qt's built-in dialog (used when there is no file-chooser portal) needs a
            // parent window to draw in. With the portal (bin/apt-layer ui sets it) it's the system dialog.
            // The compositor's close (e.g. niri's close-window / Mod+Q) arrives as a close event on the window:
            // while APT runs, refuse it and ask instead, like the ✕ button.
            Connections {
                target: pane.Window.window
                function onClosing(close) {
                    if (root.aptRunning) {
                        close.accepted = false;
                        quitDialog.open();
                    }
                }
            }

            Dialog {
                id: quitDialog
                title: "Confirm quit"
                modal: true
                parent: Overlay.overlay
                anchors.centerIn: parent
                width: 460
                // Fixed widths (not bound to the dialog's own size) - avoids a layout binding loop.
                Label {
                    width: 460 - quitDialog.leftPadding - quitDialog.rightPadding
                    wrapMode: Text.Wrap
                    text: "Do you want to quit Awakened PoE Trade too?\nNOTE: can take a few seconds to close"
                }
                footer: DialogButtonBox {
                    Button { text: "Keep it running"; highlighted: true; DialogButtonBox.buttonRole: DialogButtonBox.AcceptRole }
                    Button { text: "Quit APT too"; DialogButtonBox.buttonRole: DialogButtonBox.DestructiveRole }
                    Button { text: "Cancel"; DialogButtonBox.buttonRole: DialogButtonBox.RejectRole }
                    onAccepted: Qt.quit()
                    onRejected: quitDialog.close()
                    onClicked: button => {
                        if (button.DialogButtonBox.buttonRole === DialogButtonBox.DestructiveRole) {
                            Quickshell.execDetached([root.bin, "quit"]);
                            Qt.quit();
                        }
                    }
                }
            }

            FileDialog {
                id: appImageDialog
                title: "Awakened PoE Trade executable"
                nameFilters: ["AppImage (*.AppImage)", "All files (*)"]
                currentFolder: {
                    const exe = root.st?.config?.APPIMAGE || root.st?.apt?.executable || "";
                    return exe ? "file://" + exe.substring(0, exe.lastIndexOf("/")) : "";
                }
                onAccepted: root.setConfig("APPIMAGE", decodeURIComponent(selectedFile.toString().replace(/^file:\/\//, "")))
            }

            ColumnLayout {
                anchors.fill: parent
                spacing: 14

                // ---- Status --------------------------------------------------------------
                RowLayout {
                    Layout.fillWidth: true
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 2
                        RowLayout {
                            spacing: 8
                            Label { text: "APT Layer"; font.bold: true; font.pixelSize: 20 }
                            Label {
                                Layout.alignment: Qt.AlignBaseline
                                text: root.st?.version ? "v" + root.st.version : ""
                                color: "#80858f"
                                font.pixelSize: 12
                            }
                        }
                        Label { text: "Awakened PoE Trade's overlay on layer-shell — for niri & others"; color: "#9aa0aa"; font.pixelSize: 12 }
                    }
                    Item { Layout.fillWidth: true }   // pushes the close button to the right edge
                    ToolButton {
                        Layout.alignment: Qt.AlignTop | Qt.AlignRight
                        text: "✕"
                        font.pixelSize: 18
                        ToolTip.visible: hovered
                        ToolTip.text: "Close"
                        // Ask only if something is still running; closing the window alone keeps it running.
                        onClicked: root.aptRunning ? quitDialog.open() : Qt.quit()
                    }
                }

                // ---- Setup (only while something needs attention) -----------------------------
                ColumnLayout {
                    visible: root.setupItems.length > 0
                    Layout.fillWidth: true
                    spacing: 8

                    Label {
                        text: "Setup"; font.bold: true; font.pixelSize: 15; Layout.topMargin: 4
                    }
                    Label {
                        Layout.fillWidth: true
                        wrapMode: Text.Wrap
                        color: "#9aa0aa"
                        text: root.setupBlocked
                            ? "A few things are missing before APT Layer can run. Work through the list from the top (red ones are required); it updates by itself."
                            : "APT Layer can run. These are optional, or only matter in some setups."
                    }

                    Repeater {
                        model: root.setupItems
                        delegate: RowLayout {
                            required property var modelData
                            readonly property var fix: modelData.fix ?? {}
                            Layout.fillWidth: true
                            spacing: 10

                            Dot { level: modelData.level; Layout.alignment: Qt.AlignTop; Layout.topMargin: 5 }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 4
                                Label { Layout.fillWidth: true; wrapMode: Text.Wrap; text: modelData.text }
                                RowLayout {
                                    visible: fix.type === "install" && (fix.command ?? "") !== ""
                                    Layout.fillWidth: true
                                    TextField {
                                        Layout.fillWidth: true
                                        readOnly: true
                                        selectByMouse: true
                                        font.family: "monospace"
                                        text: fix.command ?? ""
                                    }
                                    Button { text: "Copy"; onClicked: Quickshell.clipboardText = fix.command }
                                }
                                Label {
                                    visible: fix.type === "install" && (fix.command ?? "") === ""
                                    Layout.fillWidth: true
                                    wrapMode: Text.Wrap
                                    color: "#9aa0aa"
                                    text: "Install: " + (fix.packages ?? "")
                                }
                                RowLayout {
                                    spacing: 8
                                    Button {
                                        visible: fix.type === "install" && (fix.url ?? "") !== ""
                                        text: "Open install guide"
                                        onClicked: root.openUrl(fix.url)
                                    }
                                    Button {
                                        visible: fix.type === "build"
                                        text: buildProc.running ? "Building…" : "Build"
                                        enabled: !buildProc.running
                                        onClicked: { root.outputTitle = "Build"; root.outputText = "…"; buildProc.running = true; }
                                    }
                                    Button {
                                        visible: fix.type === "choose-apt"
                                        text: "Choose…"
                                        onClicked: appImageDialog.open()
                                    }
                                    Button {
                                        visible: fix.type === "choose-apt"
                                        text: "Get Awakened PoE Trade"
                                        onClicked: root.openUrl(fix.url)
                                    }
                                    Button {
                                        visible: fix.type === "restart-apt"
                                        text: "Restart APT"
                                        enabled: root.pending === ""
                                        onClicked: root.act("Restarting APT", [root.launcher], 60000)
                                    }
                                    Button {
                                        visible: fix.type === "menu-entry"
                                        text: "Add to app menu"
                                        enabled: !menuProc.running
                                        onClicked: root.menuEntry("add", "ui")
                                    }
                                }
                            }
                        }
                    }
                }

                Label { text: "Status"; font.bold: true; font.pixelSize: 15; Layout.topMargin: 4 }

                GridLayout {
                    columns: 3
                    columnSpacing: 10
                    rowSpacing: 6
                    Layout.fillWidth: true

                    Dot {
                        level: !root.aptRunning ? "off" : root.st.apt.noOverlay === false ? "warn" : "ok"
                    }
                    Label { text: "Awakened PoE Trade"; font.bold: true }
                    Label {
                        Layout.fillWidth: true
                        wrapMode: Text.Wrap
                        text: !root.st ? "…"
                            : !root.aptRunning ? (root.st.apt.executable ? "Not running" : "Not running — executable not found (set it below)")
                            : root.aptWrong ? "Running, but not started for APT Layer (e.g. from another app's menu"
                                              + " entry) — its UI can't reach the overlay. Use “Restart APT”."
                            : "Running on port " + root.st.apt.port
                    }

                    Dot { level: !root.st?.poe?.running ? "off" : root.st.poe.x11 === false ? "fail" : "ok" }
                    Label { text: "Path of Exile"; font.bold: true }
                    Label {
                        Layout.fillWidth: true
                        wrapMode: Text.Wrap
                        text: !root.st ? "…"
                            : !root.st.poe.running ? "Not running"
                            : "Running on " + (root.st.poe.output ?? "?")
                              + (root.st.poe.x11 === false ? " — as a native Wayland window, but APT Layer needs it on X11 (see Setup)" : "")
                    }

                    Dot {
                        level: !root.overlayRunning ? "off"
                            : root.testPage ? "warn"
                            : (root.st.overlay.connected && root.st.overlay.keyGrab === "ok") ? "ok" : "warn"
                    }
                    Label { text: "APT Layer"; font.bold: true }
                    Label {
                        Layout.fillWidth: true
                        wrapMode: Text.Wrap
                        // Short when all is well; details only for what's wrong.
                        text: {
                            if (!root.st) return "…";
                            const o = root.st.overlay;
                            if (!o.running) return "Not running";
                            if (o.adapter === false) return "Showing the test page (Restart overlay to go back to APT)";
                            const problems = [];
                            if (!o.connected) problems.push("not connected to APT yet");
                            if (o.keyGrab !== "ok") problems.push(`the overlay key (${o.overlayKey}) couldn't be grabbed`);
                            return problems.length ? "Running, but " + problems.join(" and ") : "Running, connected to APT";
                        }
                    }
                }

                // ---- Actions -------------------------------------------------------------
                RowLayout {
                    spacing: 8
                    Button {
                        text: root.pending !== "" ? root.pending + "…"
                            : !root.aptRunning ? "Start APT + overlay"
                            : root.aptWrong ? "Restart APT"
                            : !root.overlayRunning || root.testPage ? "Start overlay" : "Running"
                        highlighted: true
                        enabled: root.st !== null && root.pending === "" && !root.setupBlocked
                                 && !(root.aptRunning && !root.aptWrong && root.overlayRunning && !root.testPage)
                        ToolTip.visible: hovered && (root.aptWrong || root.setupBlocked)
                        ToolTip.text: root.setupBlocked ? "Finish the setup above first"
                            : "Quits Awakened PoE Trade (can take ~20 s) and starts it again for APT Layer"
                        // apt-layer-launch handles every case: start APT, restart a wrongly started one,
                        // or start just the overlay.
                        onClicked: root.testPage ? root.act("Starting", [root.bin, "--restart"])
                                 : root.aptWrong ? root.act("Restarting APT", [root.launcher], 60000)
                                 : root.act("Starting", [root.launcher], root.aptRunning ? 4000 : 20000)
                    }
                    Button {
                        text: root.poeRunning ? "Path of Exile running"
                            : root.gameLaunching ? "Launching Path of Exile…" : "Launch Path of Exile"
                        enabled: root.st !== null && root.st.steam && !root.poeRunning && !root.gameLaunching
                        ToolTip.visible: hovered && root.st !== null && !root.st.steam
                        ToolTip.text: "Needs Steam (no handler for steam:// links found)"
                        onClicked: {
                            root.gameLaunching = true;
                            gameLaunchTimer.restart();
                            Quickshell.execDetached([root.bin, "launch-game"]);
                        }
                    }
                    Button {
                        text: "Restart overlay"
                        enabled: root.aptRunning && root.pending === ""
                        onClicked: root.act("Restarting", [root.bin, "--restart"])
                    }
                    Button {
                        text: "Stop overlay"
                        enabled: root.overlayRunning && root.pending === ""
                        onClicked: root.act("Stopping", [root.ctl, "kill"])
                    }
                    Button {
                        text: "Test page"
                        enabled: root.pending === "" && !root.testPage
                        ToolTip.visible: hovered
                        ToolTip.text: "Shows a test panel instead of APT (replaces APT's UI in the overlay until you restart it)"
                        onClicked: root.act("Starting test", [root.bin, "--test"])
                    }
                }

                // ---- Settings ------------------------------------------------------------
                Label { text: "Settings"; font.bold: true; font.pixelSize: 15; Layout.topMargin: 6 }

                GridLayout {
                    columns: 2
                    columnSpacing: 12
                    rowSpacing: 8
                    Layout.fillWidth: true

                    Label { text: "Monitor" }
                    ComboBox {
                        id: outputBox
                        Layout.fillWidth: true
                        readonly property var values: ["auto"].concat((root.st?.outputs ?? []).map(o => o.name))
                        model: ["Auto — the monitor Path of Exile is on"]
                            .concat((root.st?.outputs ?? []).map(o => root.outputLabel(o)))
                        currentIndex: Math.max(0, values.indexOf(root.st?.config?.OUTPUT ?? "auto"))
                        onActivated: idx => root.setConfig("OUTPUT", values[idx])
                    }
                    Item { width: 1; height: 1 }
                    Label {
                        Layout.fillWidth: true
                        wrapMode: Text.Wrap
                        color: "#9aa0aa"
                        font.pixelSize: 12
                        text: {
                            if (!root.st) return "";
                            const out = (root.st.outputs ?? []).find(o => o.name === root.st.resolvedOutput);
                            const auto = (root.st.config.OUTPUT ?? "auto") === "auto";
                            let s = root.overlayRunning ? "The overlay is on " + root.st.overlay.output
                                : "The overlay will start on " + (root.st.resolvedOutput || "the first screen");
                            s += auto ? " (checked when the overlay starts and when PoE starts)." : ".";
                            if (out && (out.x !== 0 || out.y !== 0 || out.scale !== 1))
                                s += " Note: only a monitor at 0,0 with scale 1 is tested — mouse-away closing and click areas may be off here.";
                            return s;
                        }
                    }


                    Label { text: "APT executable" }
                    RowLayout {
                        Layout.fillWidth: true
                        TextField {
                            Layout.fillWidth: true
                            readOnly: true
                            text: root.st?.config?.APPIMAGE ?? ""
                            placeholderText: root.st?.apt?.executable
                                ? "Automatic: " + root.st.apt.executable + "  (" + root.st.apt.executableSource + ")"
                                : "Automatic: not found — choose it"
                        }
                        Button { text: "Choose…"; onClicked: appImageDialog.open() }
                        Button {
                            text: "Automatic"
                            enabled: (root.st?.config?.APPIMAGE ?? "") !== ""
                            onClicked: root.setConfig("APPIMAGE", "")
                        }
                    }
                }

                // ---- App menu ------------------------------------------------------------
                Label { text: "App menu"; font.bold: true; font.pixelSize: 15; Layout.topMargin: 6 }

                GridLayout {
                    columns: 3
                    columnSpacing: 12
                    rowSpacing: 6
                    Layout.fillWidth: true

                    Repeater {
                        model: [
                            { kind: "ui", name: "APT Layer UI", what: "Add a shortcut to start this UI from your launcher/desktop" },
                            { kind: "launch", name: "APT Layer", what: "Add a shortcut to start the APT Layer without this UI" }
                        ]
                        delegate: RowLayout {
                            required property var modelData
                            readonly property var e: root.st?.menuEntries?.[modelData.kind] ?? null
                            Layout.columnSpan: 3
                            Layout.fillWidth: true
                            spacing: 10

                            Dot { level: !e?.exists ? "off" : e.pointsHere ? "ok" : "warn" }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 0
                                Label { text: modelData.name + "  "; font.bold: true }
                                Label {
                                    Layout.fillWidth: true
                                    elide: Text.ElideMiddle
                                    color: "#9aa0aa"
                                    font.pixelSize: 12
                                    // The dot and the buttons show whether the shortcut exists; only a shortcut
                                    // that opens a different copy gets its own text.
                                    text: e?.exists && !e.pointsHere
                                        ? "The existing shortcut opens another copy: " + (e.target ?? "?")
                                        : modelData.what
                                }
                            }
                            Button {
                                text: !e?.exists ? "Add" : "Use this copy"
                                visible: !e?.exists || !e?.pointsHere
                                enabled: e !== null && !menuProc.running
                                onClicked: root.menuEntry("add", modelData.kind)
                            }
                            Button {
                                text: "Remove"
                                visible: e?.exists ?? false
                                enabled: !menuProc.running
                                onClicked: root.menuEntry("remove", modelData.kind)
                            }
                        }
                    }
                }

                // ---- Diagnostics ---------------------------------------------------------
                RowLayout {
                    Layout.topMargin: 6
                    spacing: 8
                    Label { text: "Diagnostics"; font.bold: true; font.pixelSize: 15; Layout.fillWidth: true }
                    Button { text: "Run checks"; onClicked: root.showOutput("Checks", [root.bin, "doctor"]) }
                    Button { text: "Show log"; onClicked: root.showOutput("Overlay log (last 60 lines)", [root.ctl, "log", "-t", "60"]) }
                }

                Label {
                    visible: root.outputTitle !== ""
                    text: root.outputTitle
                    color: "#9aa0aa"
                }
                ScrollView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: root.outputTitle !== ""
                    TextArea {
                        readOnly: true
                        wrapMode: TextEdit.NoWrap
                        font.family: "monospace"
                        font.pixelSize: 12
                        text: root.outputText
                    }
                }
                Item { Layout.fillHeight: true; visible: root.outputTitle === "" }

                Label {
                    Layout.fillWidth: true
                    elide: Text.ElideMiddle
                    color: "#80858f"
                    font.pixelSize: 11
                    text: root.st ? "Config: " + root.st.config.file + (root.st.config.exists ? "" : " (not created yet — defaults)") : ""
                }
            }
        }
    }
}
