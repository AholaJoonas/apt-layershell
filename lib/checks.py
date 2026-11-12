"""checks.py - setup / health checks shared by `apt-layer doctor` (text) and the control window (JSON).

Each check: {"id", "group", "level", "text", "fix"?}
  level: ok | info | suggest (optional improvement) | warn | fail (APT Layer can't work)
  fix:   {"type": "install", "packages", "command"?, "url"?}   - packages to install (we never run sudo)
         {"type": "build"}                                     - `apt-layer build` (preload library)
         {"type": "choose-apt", "url"}                         - pick / download Awakened PoE Trade
         {"type": "restart-apt"} | {"type": "menu-entry"}
"""
import ctypes, os, re, shutil, subprocess, sys

QUICKSHELL_URL = "https://quickshell.org/docs/guide/install-setup/"
APT_RELEASES_URL = "https://github.com/SnosMe/awakened-poe-trade/releases"

# Package names per distro family (best effort; the text always names the component too).
PKGS = {
    "arch":   {"cmd": "sudo pacman -S --needed {}", "webengine": "qt6-webengine", "build": "base-devel pkgconf qt6-base",
               "python": "python", "iproute": "iproute2", "util-linux": "util-linux", "xdg-utils": "xdg-utils"},
    "fedora": {"cmd": "sudo dnf install {}", "webengine": "qt6-qtwebengine", "build": "gcc-c++ make pkgconf-pkg-config qt6-qtbase-devel",
               "python": "python3", "iproute": "iproute", "util-linux": "util-linux", "xdg-utils": "xdg-utils"},
    "debian": {"cmd": "sudo apt install {}", "webengine": "qml6-module-qtwebengine", "build": "g++ make pkg-config qt6-base-dev",
               "python": "python3", "iproute": "iproute2", "util-linux": "util-linux", "xdg-utils": "xdg-utils"},
    "suse":   {"cmd": "sudo zypper install {}", "webengine": "qt6-webengine-imports", "build": "gcc-c++ make pkgconf qt6-base-devel",
               "python": "python3", "iproute": "iproute2", "util-linux": "util-linux", "xdg-utils": "xdg-utils"},
    "nixos":  {"cmd": "add to environment.systemPackages: {}", "webengine": "qt6.qtwebengine", "build": "gcc gnumake pkg-config qt6.qtbase",
               "python": "python3", "iproute": "iproute2", "util-linux": "util-linux", "xdg-utils": "xdg-utils"},
}


def distro_family():
    info = {}
    try:
        with open("/etc/os-release") as f:
            for line in f:
                k, _, v = line.strip().partition("=")
                info[k] = v.strip('"')
    except OSError:
        pass
    ids = (info.get("ID", "") + " " + info.get("ID_LIKE", "")).split()
    for fam, keys in (("arch", {"arch"}), ("nixos", {"nixos"}), ("fedora", {"fedora", "rhel"}),
                      ("debian", {"debian", "ubuntu"}), ("suse", {"suse", "opensuse", "opensuse-tumbleweed", "sles"})):
        if keys & set(ids):
            return fam
    return None


def install_fix(component):
    fam = distro_family()
    p = PKGS.get(fam)
    if not p:
        return {"type": "install", "packages": component}
    pk = p[component]
    return {"type": "install", "packages": pk, "command": p["cmd"].format(pk)}


def _run(*cmd, timeout=3):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return 1, ""


def _qml_dir():
    for q in (["qtpaths6", "--query", "QT_INSTALL_QML"], ["qmake6", "-query", "QT_INSTALL_QML"]):
        code, out = _run(*q)
        if code == 0 and out:
            return out.splitlines()[0]
    return "/usr/lib/qt6/qml"


def _x_display():
    d = os.environ.get("DISPLAY")
    if d:
        return d
    _, out = _run("pgrep", "-a", "xwayland-satellite")
    m = re.search(r"xwayland-satellite\s+(:\d+)", out)
    return m.group(1) if m else None


def run_checks(ctl):
    """ctl = the lib/ctl.py module (TREE, config, APT discovery, menu entries, niri helpers)."""
    tree = ctl.TREE
    shim = os.path.join(tree, "lib", "libqs-webengine-shim.so")
    out = []
    add = lambda id, group, level, text, fix=None: out.append(
        {"id": id, "group": group, "level": level, "text": text, **({"fix": fix} if fix else {})})

    # Session
    if os.environ.get("WAYLAND_DISPLAY"):
        add("wayland", "Session", "ok", f"Wayland session ({os.environ['WAYLAND_DISPLAY']})")
    else:
        add("wayland", "Session", "fail", "No Wayland session (WAYLAND_DISPLAY is not set)")
    code, ver = _run("niri", "msg", "version")
    if code == 0:
        m = re.search(r"[Cc]ompositor[^:]*:\s*(.+)", ver)
        add("niri", "Session", "ok", "niri " + (m.group(1) if m else ""))
    else:
        add("niri", "Session", "warn", "niri not detected: other compositors need wlr-layer-shell, and the automatic "
            "monitor choice needs niri (pick a monitor in Settings)")

    # Overlay host
    if shutil.which("qs"):
        add("quickshell", "Overlay", "ok", "Quickshell: " + _run("qs", "--version")[1].splitlines()[0][:80])
    else:
        add("quickshell", "Overlay", "fail", "Quickshell (qs) is not installed",
            {"type": "install", "packages": "quickshell", "url": QUICKSHELL_URL})
    qml = _qml_dir()
    if os.path.isfile(os.path.join(qml, "QtWebEngine", "qmldir")):
        add("webengine", "Overlay", "ok", "Qt WebEngine (QML module)")
    else:
        add("webengine", "Overlay", "fail", "Qt WebEngine's QML module is missing (it shows APT's page)",
            install_fix("webengine"))
    can_build = (os.path.isfile(os.path.join(tree, "Makefile")) and shutil.which("make") and shutil.which("c++")
                 and shutil.which("pkg-config") and _run("pkg-config", "--exists", "Qt6Core")[0] == 0)
    if os.path.isfile(shim):
        try:
            ctypes.CDLL(shim)
            add("preload", "Overlay", "ok", "Preload library (lets Quickshell host Qt WebEngine)")
        except OSError as e:
            add("preload", "Overlay", "fail", "The preload library doesn't load on this system: " + str(e).split(":")[-1].strip(),
                {"type": "build"} if can_build else install_fix("build"))
    elif can_build:
        add("preload", "Overlay", "warn", "The preload library isn't built yet (needed once after a git clone)",
            {"type": "build"})
    else:
        add("preload", "Overlay", "fail", "The preload library isn't built, and building it needs a C++ compiler, "
            "make, pkg-config and Qt 6 headers (or use a release tarball, which has it prebuilt)", install_fix("build"))

    # Game side (X11)
    if not shutil.which("python3"):
        add("python", "Game", "fail", "python3 is not installed", install_fix("python"))
    vendor = os.path.join(tree, "lib", "vendor")
    try:
        import Xlib  # noqa: F401
        add("xlib", "Game", "ok", "python-xlib (system)")
    except ImportError:
        sys.path.append(vendor)
        try:
            import Xlib  # noqa: F401,F811
            add("xlib", "Game", "ok", "python-xlib (bundled)")
        except ImportError:
            add("xlib", "Game", "fail", "python-xlib can't be imported (lib/vendor is missing?)")
    d = _x_display()
    if not d:
        add("xdisplay", "Game", "fail", "No X display: Path of Exile and APT must run on X11 (Xwayland / xwayland-satellite)")
    else:
        try:
            if vendor not in sys.path:
                sys.path.append(vendor)
            from Xlib import display
            ok = display.Display(d).has_extension("RECORD")
        except Exception:
            ok = False
        sat = " (xwayland-satellite)" if _run("pgrep", "-f", "^xwayland-satellite")[0] == 0 else ""
        if ok:
            add("xdisplay", "Game", "ok", f"X display {d}{sat} with RECORD")
        else:
            add("xdisplay", "Game", "fail", f"X display {d}: can't connect, or no RECORD extension (needed to see clicks and keys in the game)")

    poe = ctl.poe_status(ctl.niri("windows"), ctl.niri("workspaces"))
    if not poe["running"]:
        add("poe-x11", "Game", "info", "Path of Exile isn't running (its window is checked while it runs)")
    elif poe["x11"]:
        add("poe-x11", "Game", "ok", "Path of Exile runs on X11")
    elif poe["x11"] is False:
        add("poe-x11", "Game", "fail", "Path of Exile runs as a native Wayland window. APT and APT Layer need it on "
            "X11: remove PROTON_ENABLE_WAYLAND (or other Wayland options) from its Steam launch options, then "
            "restart the game")
    else:
        add("poe-x11", "Game", "warn", "Can't tell whether Path of Exile runs on X11 (no X display to ask)")

    # Tools
    for tool, comp in (("ss", "iproute"), ("setsid", "util-linux"), ("xdg-open", "xdg-utils")):
        if shutil.which(tool):
            add(tool, "Tools", "ok", tool)
        else:
            add(tool, "Tools", "fail", f"{tool} is missing", install_fix(comp))
    if os.environ.get("APT_LAYER_NO_SYSTEMD"):
        add("systemd", "Tools", "info", "APT_LAYER_NO_SYSTEMD is set: APT and the overlay run as children of whatever started them")
    elif shutil.which("systemd-run") and _run("systemctl", "--user", "show-environment")[0] == 0:
        add("systemd", "Tools", "ok", "systemd user session (APT and the overlay run as their own user services)")
    else:
        add("systemd", "Tools", "info", "No systemd user session: APT and the overlay run as children of whatever started them")

    # Awakened PoE Trade
    exe, how = ctl.find_apt_info()
    if not exe:
        add("apt", "Awakened PoE Trade", "fail", "Awakened PoE Trade wasn't found",
            {"type": "choose-apt", "url": APT_RELEASES_URL})
    elif not os.path.exists(exe):
        add("apt", "Awakened PoE Trade", "fail", f"{exe} doesn't exist ({how})", {"type": "choose-apt", "url": APT_RELEASES_URL})
    elif not os.access(exe, os.X_OK):
        add("apt", "Awakened PoE Trade", "fail", f"{exe} is not executable (chmod +x it, or choose another)",
            {"type": "choose-apt", "url": APT_RELEASES_URL})
    else:
        add("apt", "Awakened PoE Trade", "ok", f"{exe} ({how})")
    procs = ctl.apt_main_processes()
    if not procs:
        add("apt-running", "Awakened PoE Trade", "info", "Not running right now")
    elif any(b"--no-overlay" in a for _, a in procs):
        add("apt-running", "Awakened PoE Trade", "ok", "Running for APT Layer")
    else:
        add("apt-running", "Awakened PoE Trade", "warn", "Running, but not started for APT Layer (e.g. from an AppImage "
            "manager's menu entry), so its UI can't reach the overlay", {"type": "restart-apt"})

    # Settings
    cfg = ctl.read_config()
    want = ctl.effective("OUTPUT", cfg)
    out_name = want
    if want == "auto":
        # Without PoE running, "auto" isn't decided yet (it picks PoE's monitor when the overlay starts).
        out_name = poe["output"]
    outputs = {o["name"]: o for o in ctl.outputs_list(ctl.niri("outputs"))}
    o = outputs.get(out_name)
    if want == "auto" and not out_name:
        add("output", "Settings", "ok", "Monitor: automatic (the one Path of Exile is on)")
    elif o and (o["x"], o["y"], o["scale"]) != (0, 0, 1):
        add("output", "Settings", "warn", f"Monitor {out_name} is at {o['x']},{o['y']} with scale {o['scale']}: only a "
            "monitor at 0,0 with scale 1 is tested (mouse-away closing and click areas may be off)")
    else:
        add("output", "Settings", "ok", f"Monitor: {out_name or 'first screen'} (setting: {want})")
    if not ctl.desktop_status("ui")["exists"]:
        add("menu-entry", "Settings", "suggest", "No app-menu shortcut for the APT Layer UI yet", {"type": "menu-entry"})
    elif not ctl.desktop_status("ui")["pointsHere"]:
        add("menu-entry", "Settings", "suggest", "The app-menu shortcut opens another copy of APT Layer", {"type": "menu-entry"})
    else:
        add("menu-entry", "Settings", "ok", "App-menu shortcut for the APT Layer UI")
    return out


def print_text(checks, tree, version=""):
    color = {"ok": "\033[32mok\033[0m   ", "info": "\033[36minfo\033[0m ", "suggest": "\033[36mtip\033[0m  ",
             "warn": "\033[33mwarn\033[0m ", "fail": "\033[31mFAIL\033[0m "}
    print(f"apt-layer {version} doctor  (tree: {tree})")
    group = None
    for c in checks:
        if c["group"] != group:
            group = c["group"]
            print(group)
        line = f"  {color[c['level']]} {c['text']}"
        fix = c.get("fix") or {}
        if fix.get("command"):
            line += f"\n         -> {fix['command']}"
        elif fix.get("type") == "install":
            line += f"\n         -> install: {fix['packages']}" + (f"  ({fix['url']})" if fix.get("url") else "")
        elif fix.get("type") == "build":
            line += "\n         -> apt-layer build"
        elif fix.get("type") == "choose-apt":
            line += f"\n         -> download it ({fix['url']}), or set it: apt-layer config APPIMAGE /path/to/AppImage"
        elif fix.get("type") == "restart-apt":
            line += "\n         -> apt-layer restart-apt"
        elif fix.get("type") == "menu-entry":
            line += "\n         -> apt-layer menu-entry add"
        print(line)
    fails = sum(c["level"] == "fail" for c in checks)
    print()
    print("No problems found." if not fails else f"{fails} problem(s) found.")
    return min(fails, 99)
