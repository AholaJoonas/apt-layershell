#!/usr/bin/env python3
"""ctl.py - status and config helpers for bin/apt-layer (and the control window).

  ctl.py status [--json]        APT, PoE, overlay, outputs, config (text, or JSON for the control window)
  ctl.py config-get KEY         effective value (env APT_LAYER_KEY > config file > default)
  ctl.py config-set KEY VALUE   write KEY=VALUE to the config file (VALUE "" removes the line)
  ctl.py checks [--json]        setup / health checks (`apt-layer doctor`; the window's Setup list)
  ctl.py version                APT Layer's version (plus the commit for git checkouts)
  ctl.py find-apt [--why]        the APT executable that apt-layer-launch would start
  ctl.py apt-state              none | ok (runs with --no-overlay) | wrong (started some other way)
  ctl.py stop-apt               quit a running APT (waits up to ~40 s)
  ctl.py desktop-entry print|add|remove [ui|launch]
                                app-menu entry for this copy: ui = "APT Layer UI" (the control window),
                                launch = "APT Layer" (starts APT + overlay); in $XDG_DATA_HOME/applications

Config file: $XDG_CONFIG_HOME/apt-layer/config (KEY=value lines; same format bin/* read).
"""
import json, os, re, shlex, shutil, signal, subprocess, sys, time

TREE = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
QS_CFG = os.path.join(TREE, "quickshell")
CONFIG_FILE = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"),
                           "apt-layer", "config")
KEYS = {
    "OUTPUT": ("auto", lambda v: v == "auto" or re.fullmatch(r"[\w.:-]+", v)),
    "KEYBOARD": ("exclusive", lambda v: v in ("exclusive", "ondemand")),
    "APPIMAGE": ("", lambda v: v == "" or os.path.isabs(os.path.expanduser(v))),
}


def version():
    """VERSION, plus the commit for git checkouts between releases: "0.1.0", "0.1.0+git abc1234 (modified)"."""
    try:
        with open(os.path.join(TREE, "VERSION")) as f:
            v = f.read().strip() or "0"
    except OSError:
        v = "unknown"
    if not os.path.exists(os.path.join(TREE, ".git")) or not shutil.which("git"):
        return v                                        # release tarball / installed copy
    git = lambda *a: run("git", "-C", TREE, *a)
    modified = git("status", "--porcelain")[1].strip() != ""
    code, tag = git("describe", "--tags", "--exact-match")
    if code == 0 and tag.strip() == "v" + v and not modified:
        return v                                        # exactly a release
    code, commit = git("rev-parse", "--short", "HEAD")
    return v + (f"+git {commit.strip()}" if code == 0 else "+git") + (" (modified)" if modified else "")


def run(*cmd, timeout=3):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout
    except (OSError, subprocess.TimeoutExpired):
        return 1, ""


def read_config():
    vals = {}
    try:
        with open(CONFIG_FILE) as f:
            for line in f:
                m = re.match(r"\s*([A-Z_]+)\s*=\s*(.*?)\s*$", line)
                if m and not line.lstrip().startswith("#"):
                    vals[m.group(1)] = m.group(2).strip('"')
    except OSError:
        pass
    return vals


def effective(key, cfg=None):
    cfg = read_config() if cfg is None else cfg
    return os.environ.get(f"APT_LAYER_{key}") or cfg.get(key) or KEYS[key][0]


def config_set(key, value):
    if key not in KEYS:
        sys.exit(f"unknown key {key} (known: {', '.join(KEYS)})")
    if value != "" and not KEYS[key][1](value):   # "" = remove the line (back to the default)
        sys.exit(f"invalid value for {key}: {value!r}")
    os.makedirs(os.path.dirname(CONFIG_FILE), exist_ok=True)
    try:
        with open(CONFIG_FILE) as f:
            lines = f.read().splitlines()
    except OSError:
        lines = ["# apt-layer config (see share/config.example)"]
    pat = re.compile(rf"\s*{key}\s*=")
    out, done = [], False
    for line in lines:
        if pat.match(line):
            if value != "" and not done:
                out.append(f"{key}={value}")
                done = True
            continue
        out.append(line)
    if value != "" and not done:
        out.append(f"{key}={value}")
    tmp = CONFIG_FILE + ".tmp"
    with open(tmp, "w") as f:
        f.write("\n".join(out) + "\n")
    os.replace(tmp, CONFIG_FILE)


DESKTOP = {"ui": "apt-layer", "launch": "apt-layer-launch"}
APPS_DIR = os.path.join(os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share"), "applications")


def desktop_text(kind):
    with open(os.path.join(TREE, "share", DESKTOP[kind] + ".desktop.in")) as f:
        t = f.read()
    return (t.replace("@BINDIR@", os.path.join(TREE, "bin"))
             .replace("@SHAREDIR@", os.path.join(TREE, "share")))


def desktop_status(kind):
    path = os.path.join(APPS_DIR, DESKTOP[kind] + ".desktop")
    st = {"path": path, "exists": os.path.exists(path), "pointsHere": False, "target": None}
    if st["exists"]:
        try:
            with open(path) as f:
                # Exec="/path with spaces/bin/apt-layer" ui -> the program (quoted or not)
                m = re.search(r'^Exec=(?:"([^"]+)"|(\S+))', f.read(), re.M)
        except OSError:
            m = None
        if m:
            st["target"] = m.group(1) or m.group(2)
            st["pointsHere"] = os.path.realpath(st["target"]) == os.path.realpath(
                os.path.join(TREE, "bin", "apt-layer" if kind == "ui" else "apt-layer-launch"))
    return st


def desktop_entry(action, kind):
    if kind not in DESKTOP:
        sys.exit(f"unknown entry {kind!r} (ui or launch)")
    path = os.path.join(APPS_DIR, DESKTOP[kind] + ".desktop")
    if action == "print":
        sys.stdout.write(desktop_text(kind))
        return
    if action == "add":
        os.makedirs(APPS_DIR, exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            f.write(desktop_text(kind))
        os.chmod(tmp, 0o755)
        os.replace(tmp, path)
    elif action == "remove":
        try:
            os.remove(path)
        except FileNotFoundError:
            pass
    else:
        sys.exit(f"unknown action {action!r} (print, add, remove)")
    run("update-desktop-database", APPS_DIR)  # optional; launchers that cache entries pick it up sooner
    print(path)


def niri(*args):
    code, out = run("niri", "msg", "-j", *args)
    try:
        return json.loads(out) if code == 0 else None
    except ValueError:
        return None


# --- Finding APT --------------------------------------------------------------------------------
# AppImage managers put and name the file differently: AppImageLauncher keeps it in ~/Applications,
# Gear Lever uses ~/AppImages and often a lowercase "*.appimage" name, AM installs
# /opt/awakened-poe-trade/awakened-poe-trade (or ~/Applications/...) plus a command on PATH. Most of them
# also write a menu entry that starts it - the most reliable hint about where it is.
APT_NAME = re.compile(r"awakened[-_ .]?poe[-_ .]?trade", re.I)
APT_DIRS = ["~/.local/bin", "~/Applications", "~/AppImages", "~/.local/share/AppImages", "~/Downloads", "/opt"]


def _is_apt_file(path):
    name = os.path.basename(path)
    return (APT_NAME.search(name) is not None
            and (name.lower().endswith(".appimage") or APT_NAME.fullmatch(name) is not None)
            and os.path.isfile(path) and os.access(path, os.X_OK))


def _ours(path):
    real = os.path.realpath(path)
    return real.startswith(TREE + os.sep)


def _exec_target(line):
    """Program of a desktop entry's Exec= value (skips `env VAR=x`, field codes and quotes)."""
    try:
        words = shlex.split(line)
    except ValueError:
        return None
    for w in words:
        if w == "env" or re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", w) or w.startswith("%"):
            continue
        return w if os.path.isabs(w) else shutil.which(w)
    return None


def _menu_entry_candidates():
    dirs = [APPS_DIR] + [os.path.join(d, "applications") for d in
                         (os.environ.get("XDG_DATA_DIRS") or "/usr/local/share:/usr/share").split(":") if d]
    found = []
    for d in dirs:
        try:
            names = os.listdir(d)
        except OSError:
            continue
        for n in names:
            if not n.endswith(".desktop") or n.startswith("apt-layer"):
                continue
            try:
                with open(os.path.join(d, n), errors="replace") as f:
                    m = re.search(r"^Exec\s*=\s*(.+)$", f.read(), re.M)
            except OSError:
                continue
            t = _exec_target(m.group(1)) if m else None
            if t and not _ours(t) and _is_apt_file(t):
                found.append((t, "menu entry " + os.path.join(d, n)))
    return found


def _folder_candidates():
    found = []
    for d in map(os.path.expanduser, APT_DIRS):
        try:
            entries = os.listdir(d)
        except OSError:
            continue
        for n in entries:
            p = os.path.join(d, n)
            if os.path.isdir(p) and APT_NAME.search(n):          # AM: <dir>/awakened-poe-trade/<file>
                try:
                    found += [(os.path.join(p, m), "folder " + p) for m in os.listdir(p)
                              if _is_apt_file(os.path.join(p, m))]
                except OSError:
                    pass
            elif _is_apt_file(p):
                found.append((p, "folder " + d))
    return found


def find_apt_info(cfg=None):
    """(path, how it was found) of the APT executable to start; ("", reason) if none."""
    cfg = read_config() if cfg is None else cfg
    a = effective("APPIMAGE", cfg)
    if a:
        return os.path.expanduser(a), "setting APPIMAGE"
    cands = {}
    for path, src in _folder_candidates() + _menu_entry_candidates():   # menu entry wins for the label
        cands[os.path.realpath(path)] = (path, src)
    if cands:
        return max(cands.values(), key=lambda c: os.path.getmtime(c[0]))
    for name in ("awakened-poe-trade", "Awakened-PoE-Trade"):
        w = shutil.which(name)
        if w and not _ours(w):
            return w, "PATH"
    return "", "not found"


def find_apt(cfg=None):
    return find_apt_info(cfg)[0]


# --- APT processes --------------------------------------------------------------------------------
def apt_main_processes():
    """[(pid, args)] of APT's main process (the "awakened-poe-trade" binary, not its --type= children)."""
    procs = []
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                args = f.read().split(b"\0")
        except OSError:
            continue
        exe = os.path.basename(args[0].decode(errors="replace")) if args else ""
        if exe == "awakened-poe-trade" and not any(a.startswith(b"--type=") for a in args):
            procs.append((int(pid), args))
    return procs


def stop_apt(timeout=40):
    """Quit APT (SIGTERM; it can take ~20 s), SIGKILL after `timeout`. True when it's gone."""
    pids = [p for p, _ in apt_main_processes()]
    for p in pids:
        try:
            os.kill(p, signal.SIGTERM)
        except ProcessLookupError:
            pass
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if not apt_main_processes():
            return True
        time.sleep(0.5)
    for p, _ in apt_main_processes():
        try:
            os.kill(p, signal.SIGKILL)
        except ProcessLookupError:
            pass
    time.sleep(1)
    return not apt_main_processes()


def apt_status(cfg):
    procs = [a for _, a in apt_main_processes()]
    _, out = run("ss", "-ltnpH")
    m = re.search(r":(\d+)\s.*awakened", out, re.I)
    port = int(m.group(1)) if m else None
    exe, src = find_apt_info(cfg)
    return {
        "running": bool(procs) or port is not None,
        "port": port,
        "url": f"http://localhost:{port}/index.html" if port else None,
        "noOverlay": any(b"--no-overlay" in a for a in procs) if procs else None,
        "executable": exe,
        "executableSource": src,
    }


POE_TITLE = "Path of Exile"
POE_STEAM_APPID = "238960"   # Path of Exile (1); APT is for PoE 1


def steam_available():
    """A handler for steam:// links is registered (Steam installed natively or as a Flatpak)."""
    code, out = run("xdg-mime", "query", "default", "x-scheme-handler/steam")
    return code == 0 and out.strip() != ""


def x_display():
    d = os.environ.get("DISPLAY")
    if d:
        return d
    _, out = run("pgrep", "-a", "-f", "^xwayland-satellite")
    m = re.search(r"xwayland-satellite\s+(:\d+)", out)
    return m.group(1) if m else None


def poe_on_x11():
    """True/False: is there an X11 window titled "Path of Exile" on the game's X server; None if X can't be asked.
    APT (hotkeys, item copy) and APT Layer's input watcher only work with PoE on X11."""
    d = x_display()
    if not d:
        return None
    vendor = os.path.join(TREE, "lib", "vendor")
    if vendor not in sys.path:
        sys.path.append(vendor)
    try:
        from Xlib import X, display
        dpy = display.Display(d)
        root = dpy.screen().root
        net_list = dpy.intern_atom("_NET_CLIENT_LIST")
        net_name = dpy.intern_atom("_NET_WM_NAME")
        prop = root.get_full_property(net_list, X.AnyPropertyType)
        wins = [dpy.create_resource_object("window", w) for w in prop.value] if prop else root.query_tree().children
        found = False
        for w in wins:
            try:
                name = w.get_wm_name()
                if not name:
                    p = w.get_full_property(net_name, X.AnyPropertyType)
                    name = p.value if p else ""
                if isinstance(name, bytes):
                    name = name.decode(errors="replace")
                if name == POE_TITLE:
                    found = True
                    break
            except Exception:
                continue
        dpy.close()
        return found
    except Exception:
        return None


def poe_status(windows, workspaces, check_x11=True):
    """PoE's window: running, output (niri), x11 (True / False = native Wayland / None = unknown)."""
    w = next((w for w in windows or [] if w.get("title") == POE_TITLE), None)
    out = None
    if w is not None:
        out = next((ws.get("output") for ws in workspaces or [] if ws.get("id") == w.get("workspace_id")), None)
    # Ask X only when it matters: PoE seen by niri, or no niri to ask.
    x11 = poe_on_x11() if check_x11 and (w is not None or windows is None) else None
    running = w is not None or (windows is None and bool(x11))
    return {"running": running, "output": out, "x11": x11 if running else None}


def overlay_status():
    code, out = run("qs", "-p", QS_CFG, "ipc", "call", "overlay", "statusJson")
    if code != 0 or not out.strip():
        return {"running": False}
    try:
        st = json.loads(out)
    except ValueError:
        return {"running": True}
    st["running"] = True
    return st


def outputs_list(raw):
    res = []
    for name, o in sorted((raw or {}).items(), key=lambda kv: ((kv[1].get("logical") or {}).get("x", 0), kv[0])):
        lg = o.get("logical") or {}
        label = " ".join(x for x in (o.get("make"), o.get("model")) if x and x != "Unknown").strip()
        res.append({"name": name, "label": label or name, "x": lg.get("x"), "y": lg.get("y"),
                    "width": lg.get("width"), "height": lg.get("height"), "scale": lg.get("scale")})
    return res


def status():
    cfg = read_config()
    windows, workspaces = niri("windows"), niri("workspaces")
    focused = (niri("focused-output") or {}).get("name")
    poe = poe_status(windows, workspaces)
    want = effective("OUTPUT", cfg)
    resolved = (poe["output"] or focused) if want == "auto" else want
    return {
        "version": version(),
        "niri": windows is not None,
        "apt": apt_status(cfg),
        "poe": poe,
        "overlay": overlay_status(),
        "steam": steam_available(),
        "outputs": outputs_list(niri("outputs")),
        "focusedOutput": focused,
        "resolvedOutput": resolved,
        "menuEntries": {k: desktop_status(k) for k in DESKTOP},
        "config": {"file": CONFIG_FILE, "exists": os.path.exists(CONFIG_FILE),
                   **{k: effective(k, cfg) for k in KEYS}},
        "tree": TREE,
    }


def status_text(st):
    yn = lambda b: "yes" if b else "no"
    a, p, o = st["apt"], st["poe"], st["overlay"]
    lines = [f"Awakened PoE Trade: {'running on port ' + str(a['port']) if a['running'] and a['port'] else yn(a['running'])}"
             + ("" if a["noOverlay"] in (None, True) else "  (WARNING: not started with --no-overlay)"),
             f"  executable: {a['executable'] or 'not found'}" + (f"  ({a['executableSource']})" if a['executable'] else ""),
             f"Path of Exile: {'running on ' + (p['output'] or '?') if p['running'] else 'not running'}"]
    if o.get("running"):
        lines.append(f"Overlay: {o.get('mode', '?')} on {o.get('output') or '?'}, "
                     f"{'connected to APT' if o.get('connected') else 'not connected'}, "
                     f"overlay key {o.get('overlayKey', '?')} {'grabbed' if o.get('keyGrab') == 'ok' else 'NOT grabbed'}")
    else:
        lines.append("Overlay: not running")
    c = st["config"]
    lines.append(f"Config: OUTPUT={c['OUTPUT']} (-> {st['resolvedOutput'] or 'first screen'}), KEYBOARD={c['KEYBOARD']}"
                 + (f", APPIMAGE={c['APPIMAGE']}" if c["APPIMAGE"] else "") + f"  [{c['file']}{'' if c['exists'] else ', not created'}]")
    lines.append("Outputs: " + ", ".join(f"{x['name']} ({x['label']}, {x['width']}x{x['height']} at {x['x']},{x['y']})" for x in st["outputs"]))
    return "\n".join(lines)


def main(argv):
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd == "status":
        st = status()
        print(json.dumps(st) if "--json" in argv else status_text(st))
    elif cmd == "config-get" and len(argv) == 3:
        print(effective(argv[2]))
    elif cmd == "config-set" and len(argv) == 4:
        config_set(argv[2], argv[3])
    elif cmd == "checks":
        sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
        import checks
        res = checks.run_checks(sys.modules[__name__])
        if "--json" in argv:
            print(json.dumps(res))
            return 0
        return checks.print_text(res, TREE, version())
    elif cmd == "version":
        print(version())
    elif cmd == "find-apt":
        path, src = find_apt_info()
        if not path:
            return 1
        print(f"{path}\t{src}" if "--why" in argv else path)
    elif cmd == "apt-state":                       # none | ok (--no-overlay) | wrong (started some other way)
        procs = apt_main_processes()
        print("none" if not procs else "ok" if any(b"--no-overlay" in a for _, a in procs) else "wrong")
    elif cmd == "stop-apt":
        return 0 if stop_apt() else 1
    elif cmd == "desktop-entry" and len(argv) in (3, 4):
        desktop_entry(argv[2], argv[3] if len(argv) == 4 else "ui")
    else:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
