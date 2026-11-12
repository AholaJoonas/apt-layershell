//@ pragma ShellId apt-layer
//@ pragma AppId apt-layer
// apt-layer: a transparent wlr-layer-shell surface (layer "overlay") on one output, showing
// Awakened PoE Trade's UI (with the adapter in ./adapter) or the dev test page in a WebEngineView.
//
// Started by bin/apt-layer (never plain `qs -p`: Quickshell passes argc=0 and QtWebEngine aborts
// without a program name — bin/apt-layer preloads lib/libqs-webengine-shim.so, which fixes that).
// Control: bin/apt-layerctl setMode idle|shown|focused | setActive true|false | toggle | status
//                             | reloadPage | setUrl <url> | kill | log
// Env (set by bin/apt-layer from ~/.config/apt-layer/config):
//         APT_LAYER_OUTPUT  output name (default: the first screen)
//         APT_LAYER_URL     page (default: dev/test-page)
//         APT_LAYER_ADAPTER=1 — inject the APT adapter and quit when APT exits
//         APT_LAYER_KEYBOARD = exclusive (default) | ondemand — keyboard mode while focused
//
// Modes:
//   idle    — no input region (fully click-through), keyboard None.
//   shown   — a widget is up but the game keeps the keyboard (APT's unlocked price check):
//             input region = the page's widget rects, keyboard None.
//   focused — the overlay is interactive (locked check, overlay key, click in a widget):
//             keyboard Exclusive; input region = whole surface with the adapter (like APT's overlay),
//             widget rects for the test page.
//   back to idle — Esc / background click (page), a click or Esc that reaches the X server (PoE),
//             or IPC. See docs/apt-integration.md for the APT side.

import QtQuick
import QtWebEngine
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    id: root

    property string mode: "idle"
    readonly property bool active: mode !== "idle"

    // Both can be changed live over IPC (setOutput / setKeyboard, used by the control window).
    property string outputName: Quickshell.env("APT_LAYER_OUTPUT") || ""
    // OUTPUT=auto: follow the monitor PoE's window is on (checked every 3 s, e.g. when PoE starts).
    property bool outputAuto: Quickshell.env("APT_LAYER_OUTPUT_AUTO") === "1"
    readonly property bool adapter: Quickshell.env("APT_LAYER_ADAPTER") === "1"
    readonly property string pageUrl: Quickshell.env("APT_LAYER_URL")
        || "file://" + Quickshell.shellPath("../dev/test-page/index.html")
    property bool onDemandKeyboard: (Quickshell.env("APT_LAYER_KEYBOARD") || "") === "ondemand"
    // Status for the control window: APT's websocket seen, overlay key grabbed on X.
    property bool wsConnected: false
    property string keyGrab: ""

    // Current page; setUrl (IPC) switches it, e.g. when APT restarted on a new port.
    property string currentUrl: pageUrl

    // Only map the surface once the page loaded: a failed load must never cover the screen.
    property bool pageOk: false

    // Interactive rects reported by the page ([{x,y,w,h}] in CSS px = surface px at scale 1),
    // or null if the page has no rects function.
    property var rects: []
    readonly property bool pageHasRects: rects !== null

    // From APT's update-host-config (seen by the adapter).
    property string overlayKey: "Shift + Space"
    // APT's price-check hold key (Ctrl) is down — reported by x-watch.py while tracking.
    property bool holdHeld: false

    readonly property string rectsJs: adapter
        ? "JSON.stringify(window.__aptov ? window.__aptov.rects() : [])"
        : "JSON.stringify(typeof window.overlayRects === 'function' ? window.overlayRects() : null)"

    function applyRects(json) {
        const next = JSON.parse(json ?? "null");
        if (JSON.stringify(next) !== JSON.stringify(rects)) {
            rects = next;
            console.info("input rects:", json);
        }
    }

    function setMode(next, why) {
        if (next === mode) return;
        console.info(`mode: ${mode} -> ${next} (${why})`);
        const was = mode;
        mode = next;
        if (was === "shown") { xWatch.write("untrack\n"); holdHeld = false; }
        if (adapter) {
            if (next === "focused") view.runJavaScript("window.__aptov && window.__aptov.setFocus(false, true)");
            else if (next === "idle" && was === "focused") view.runJavaScript("window.__aptov && window.__aptov.setFocus(true, false)");
            else if (next === "idle" && was === "shown") view.runJavaScript("window.__aptov && window.__aptov.hideExclusive()");
        } else {
            view.runJavaScript(`window.setOverlayActive && window.setOverlayActive(${next !== "idle"})`);
        }
        view.runJavaScript(rectsJs, res => root.applyRects(res));
    }

    // Messages from the adapter (console.debug("__aptov {json}")).
    function onAdapterMessage(m) {
        switch (m.type) {
        case "item-text":
            console.info("item-text:", m.target, "focusOverlay:", m.focusOverlay, "at", JSON.stringify(m.position));
            if (m.focusOverlay) setMode("focused", "locked " + m.target);
            else if (mode !== "focused") setMode("shown", m.target);
            break;
        case "focus-game":
            setMode("idle", "page focus-game " + (m.why ?? ""));
            break;
        case "page-mousedown":
            if (mode === "shown") setMode("focused", "click in widget");
            break;
        case "page-pointer":
            if (mode === "shown" && holdHeld) setMode("focused", "pointer in widget with hold key");
            break;
        case "track-area": {
            // APT's WidgetAreaTracker, done by x-watch.py: close on move-away, focus on hold+enter.
            if (mode !== "shown") break;
            const a = m.area, hold = m.holdKey || "none";
            console.info("track-area: from", JSON.stringify(m.from), "threshold", m.closeThreshold, "hold", hold);
            xWatch.write(`track ${m.from.x} ${m.from.y} ${m.closeThreshold} ${a.x} ${a.y} ${a.width} ${a.height} ${hold}\n`);
            break;
        }
        case "open-url":
            openUrl(m.url, m.via);
            break;
        case "main-focus":
            console.info("main focus-change:", JSON.stringify(m));
            break;
        case "main-event":
            console.info("main event:", m.name, JSON.stringify(m.payload));
            if (m.name === "MAIN->OVERLAY::hide-exclusive-widget" && mode === "shown") setMode("idle", "main hide-exclusive-widget");
            break;
        case "ws-open":
            wsConnected = true;
            console.info("adapter:", JSON.stringify(m));
            break;
        case "host-config":
            if (m.overlayKey) overlayKey = m.overlayKey;
            grabOverlayKey();
            console.info("APT overlay key:", overlayKey, "- toggle-overlay shortcuts withheld from main:", m.droppedShortcuts ?? 0);
            break;
        default:
            console.info("adapter:", JSON.stringify(m));
        }
    }

    // Links from the page (window.open, target=_blank, APT's built-in browser) -> default browser.
    // bin/apt-layer removes APT's xdg-open shim from PATH, so this is the real xdg-open.
    function openUrl(url, via) {
        if (!/^https?:\/\//.test(url)) { console.warn("not opening", url); return; }
        console.info("open-url (" + via + "):", url);
        Quickshell.execDetached(["xdg-open", url]);
        setMode("idle", "opened link");
    }

    // APT's own grab of the overlay key is withheld (adapter.js), so grab it on X ourselves:
    // otherwise PoE sees Space down, the overlay takes the keyboard, and PoE never sees Space up.
    function grabOverlayKey() {
        if (!adapter) return;
        const parts = overlayKey.split(" + ");
        const key = parts[parts.length - 1];
        const mods = parts.slice(0, -1).map(p => p.toLowerCase()).join(",");
        xWatch.write(`grab ${key} ${mods}\n`);
    }

    // "Shift + Space" -> does an X key event (keysym name + mods) match?
    function matchesKey(spec, key, mods) {
        const parts = spec.split(" + ");
        const k = parts[parts.length - 1].toLowerCase();
        const want = { ctrl: parts.includes("Ctrl"), shift: parts.includes("Shift"), alt: parts.includes("Alt") };
        return key.toLowerCase() === k && want.ctrl === mods.includes("ctrl")
            && want.shift === mods.includes("shift") && want.alt === mods.includes("alt");
    }

    // Widgets can move/resize while up; poll cheaply.
    Timer {
        interval: 150
        repeat: true
        running: root.active && root.pageOk
        onTriggered: view.runJavaScript(root.rectsJs, res => root.applyRects(res))
    }

    // X RECORD watcher on PoE's X server: clicks and a few keys that reach the game.
    Process {
        id: xWatch
        command: ["python3", Quickshell.shellPath("../lib/x-watch.py")]
        running: true
        stdinEnabled: true
        stdout: SplitParser {
            onRead: line => {
                const f = line.split(" ");
                if (f[0] === "watching") { console.info("X watcher:", line); root.grabOverlayKey(); }
                else if (f[0] === "grabbed" || f[0] === "grab-error") {
                    console.info("X watcher:", line);
                    root.keyGrab = f[0] === "grabbed" ? "ok" : "busy";
                }
                else if (f[0] === "track") {
                    if (f[1] === "hold") root.holdHeld = f[2] === "1";
                    else if (f[1] === "hide" && root.mode === "shown") root.setMode("idle", "moved away");
                    else if (f[1] === "enter" && root.mode === "shown") root.setMode("focused", "entered widget area");
                }
                else if (f[0] === "click") {
                    if (root.active) root.setMode("idle", "X click " + f[1]);
                } else if (f[0] === "key") {
                    const key = f[1], mods = (f[2] ?? "").split(",");
                    if (key === "Escape" && root.mode === "shown") root.setMode("idle", "Esc in game");
                    else if (root.adapter && root.matchesKey(root.overlayKey, key, mods))
                        root.setMode(root.mode === "focused" ? "idle" : "focused", "overlay key in game");
                }
            }
        }
        stderr: SplitParser { onRead: line => console.warn("X watcher:", line) }
        onExited: (code, status) => {
            console.warn("X watcher exited:", code, "- restarting in 3 s");
            restartWatch.start();
        }
    }
    Timer { id: restartWatch; interval: 3000; onTriggered: xWatch.running = true }

    Process {
        id: poeOutput
        command: ["python3", Quickshell.shellPath("../lib/niri-query.py"), "poe-output"]
        stdout: StdioCollector {
            onStreamFinished: {
                const name = text.trim();
                // Move only while idle, so an open price check isn't yanked away.
                if (root.outputAuto && name !== "" && name !== root.outputName && root.mode === "idle") {
                    console.info("output (auto, PoE's monitor):", root.outputName, "->", name);
                    root.outputName = name;
                }
            }
        }
    }
    Timer {
        interval: 3000
        repeat: true
        running: root.outputAuto
        onTriggered: if (!poeOutput.running) poeOutput.running = true
    }

    // Quit with APT (adapter mode): the xdg-open shim starts a fresh overlay with the new port next time.
    Process {
        id: aptAlive
        // APT's process name: its binary "awakened-poe-trade" cut to 15 characters. Same however APT was
        // installed (the AppImage's /tmp/.mount_XXXXXX name follows the file name, which managers rename).
        command: ["pgrep", "-x", "awakened-poe-tr"]
        property int misses: 0
        onExited: (code, status) => {
            misses = code === 0 ? 0 : misses + 1;
            if (misses >= 2) { console.info("APT is gone - quitting"); Qt.quit(); }
        }
    }
    Timer {
        interval: 5000
        repeat: true
        running: root.adapter
        onTriggered: aptAlive.running = true
    }

    // Fixed pool of mask rects (unused ones are 0×0 and add nothing).
    component RectRegion: Region {
        required property int idx
        readonly property var r: (root.rects ?? [])[idx] ?? null
        x: r ? Math.floor(r.x) : 0
        y: r ? Math.floor(r.y) : 0
        width: r ? Math.ceil(r.w) : 0
        height: r ? Math.ceil(r.h) : 0
    }

    PanelWindow {
        id: win

        screen: Quickshell.screens.find(s => s.name === root.outputName) ?? Quickshell.screens[0] ?? null
        anchors { top: true; bottom: true; left: true; right: true }
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        visible: root.pageOk

        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "apt-layer"
        WlrLayershell.keyboardFocus: root.mode !== "focused" ? WlrKeyboardFocus.None
            : root.onDemandKeyboard ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.Exclusive

        // Empty region = no input (click-through); null = whole surface takes input.
        mask: root.mode === "idle" ? clickThrough
            : (root.mode === "focused" && root.adapter) ? null
            : root.pageHasRects ? widgetRegion : null
        Region { id: clickThrough }
        Region {
            id: widgetRegion
            RectRegion { idx: 0 }
            RectRegion { idx: 1 }
            RectRegion { idx: 2 }
            RectRegion { idx: 3 }
            RectRegion { idx: 4 }
            RectRegion { idx: 5 }
            RectRegion { idx: 6 }
            RectRegion { idx: 7 }
        }

        WebEngineView {
            id: view
            anchors.fill: parent
            backgroundColor: "transparent"
            settings.errorPageEnabled: false

            Component.onCompleted: {
                if (root.adapter) {
                    userScripts.collection = [{
                        name: "apt-adapter",
                        sourceUrl: "file://" + Quickshell.shellPath("adapter/adapter.js"),
                        injectionPoint: 2, // WebEngineScript.DocumentCreation
                        worldId: 0         // WebEngineScript.MainWorld
                    }, {
                        name: "apt-adapter-css",
                        sourceUrl: "file://" + Quickshell.shellPath("adapter/adapter-css.js"),
                        injectionPoint: 1, // WebEngineScript.DocumentReady
                        worldId: 0
                    }];
                    console.info("adapter scripts:", userScripts.collection.length);
                }
                url = root.currentUrl;
            }

            // Test page -> host: document.title. (APT sets its own title; the adapter uses the console.)
            onTitleChanged: {
                if (root.adapter) return;
                if (title === "apt-layer:idle") root.setMode("idle", "page");
                else if (title === "apt-layer:active") root.setMode("focused", "page");
            }
            onNewWindowRequested: request => root.openUrl(request.requestedUrl.toString(), "new window")
            onLoadingChanged: info => {
                console.info("page load:", info.status, info.url, info.errorString);
                if (info.status === WebEngineLoadingInfo.LoadSucceededStatus) root.pageOk = true;
                else if (info.status === WebEngineLoadingInfo.LoadFailedStatus) root.pageOk = false;
            }
            onJavaScriptConsoleMessage: (level, message, line, source) => {
                if (message.startsWith("__aptov ")) {
                    try { root.onAdapterMessage(JSON.parse(message.slice(8))); }
                    catch (e) { console.warn("bad adapter message:", message, e); }
                } else {
                    console.info("[page]", message);
                }
            }
        }
    }

    IpcHandler {
        target: "overlay"
        function setMode(m: string): void { root.setMode(m, "ipc"); }
        function setActive(on: bool): void { root.setMode(on ? "focused" : "idle", "ipc"); }
        function toggle(): void { root.setMode(root.active ? "idle" : "focused", "ipc"); }
        function reloadPage(): void { root.setMode("idle", "reload"); root.wsConnected = false; view.reload(); }
        function setUrl(url: string): void {
            root.setMode("idle", "new url");
            if (url === root.currentUrl) { view.reload(); return; }
            console.info("new page url:", url);
            root.pageOk = false;
            root.wsConnected = false;
            root.currentUrl = url;
            view.url = url;
        }
        function setOutput(name: string): void {
            console.info("output:", root.outputName, "->", name);
            root.setMode("idle", "output change");
            root.outputName = name;
        }
        function setKeyboard(kb: string): void { root.onDemandKeyboard = kb === "ondemand"; }
        function setOutputAuto(on: bool): void { root.outputAuto = on; }
        function statusJson(): string {
            return JSON.stringify({
                mode: root.mode,
                output: win.screen ? win.screen.name : "",
                requestedOutput: root.outputName,
                outputAuto: root.outputAuto,
                keyboard: root.onDemandKeyboard ? "ondemand" : "exclusive",
                adapter: root.adapter,
                url: root.currentUrl,
                pageLoaded: root.pageOk,
                connected: root.wsConnected,
                overlayKey: root.overlayKey,
                keyGrab: root.keyGrab
            });
        }
        function status(): string {
            return root.mode + " rects=" + JSON.stringify(root.rects)
                + " keyboard=" + (root.onDemandKeyboard ? "ondemand" : "exclusive")
                + " adapter=" + root.adapter + " url=" + view.url;
        }
    }
}
