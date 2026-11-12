#!/usr/bin/env python3
"""x-watch - report mouse clicks, a few keys and (on request) pointer tracking on the X server.

Used by APT Layer's overlay: while the overlay is up its input region covers only the
widgets, so input anywhere else on PoE lands on xwayland-satellite instead.

Uses X RECORD (like APT's own hotkeys, via uiohook): events are observed,
not consumed. Output lines:
  click <button> <active-window-title>   buttons 1-3 (scroll wheel ignored)
  key <Escape|space> <mods>              mods = comma list of shift,ctrl,alt (may be empty)
  track hide | track enter               result of area tracking (see below); tracking then stops
  track hold <0|1>                       hold key pressed/released while tracking
Only Escape and space are reported, so typed text never shows up in logs.

Area tracking = APT's WidgetAreaTracker (main/src/windowing/WidgetAreaTracker.ts), driven by stdin:
  track <fromX> <fromY> <threshold> <areaX> <areaY> <areaW> <areaH> <Ctrl|Alt|none>
  untrack
While tracking, on pointer motion: without the hold key, moving more than <threshold> px away
from <from> -> "track hide"; with it held, entering the area -> "track enter". A click inside the
area -> "track enter" (instead of a click line).

Overlay key grab, driven by stdin (APT's own grab of the overlay key is disabled, see adapter.js):
  grab <key> <mods>    e.g. "grab Space shift" - XGrabKey on the root window, so the game never sees
                       the key (else PoE gets Space down, the overlay takes the keyboard, PoE never
                       gets Space up and keeps "holding" it). Presses are still reported via RECORD.
  ungrab

Display: $DISPLAY, else the one xwayland-satellite serves.
"""
import math, os, re, subprocess, sys, threading
# Bundled python-xlib (lib/vendor) for systems without it; a system copy wins.
sys.path.append(os.path.join(os.path.dirname(os.path.realpath(__file__)), "vendor"))
import Xlib.threaded  # noqa: F401 - gdisp is used from two threads (grab/ungrab, event drain)
from Xlib import X, XK, display, error
from Xlib.ext import record
from Xlib.protocol import rq


def satellite_display():
    if os.environ.get("DISPLAY"):
        return os.environ["DISPLAY"]
    out = subprocess.run(["pgrep", "-a", "xwayland-satellite"], capture_output=True, text=True).stdout
    m = re.search(r"xwayland-satellite\s+(:\d+)", out)
    return m.group(1) if m else ":0"


disp = satellite_display()
local = display.Display(disp)
rec = display.Display(disp)
gdisp = display.Display(disp)   # holds the overlay-key grab; drained by grab_loop()
groot = gdisp.screen().root
grabbed = None                  # (keycode, modmask)
root = local.screen().root
NET_ACTIVE = local.intern_atom("_NET_ACTIVE_WINDOW")
NET_NAME = local.intern_atom("_NET_WM_NAME")
WATCH_KEYS = {local.keysym_to_keycode(XK.string_to_keysym(n)): n for n in ("Escape", "space")}
MOD_KEYS = {}
for name, mod in (("Control_L", "Ctrl"), ("Control_R", "Ctrl"), ("Alt_L", "Alt"), ("Alt_R", "Alt")):
    MOD_KEYS[local.keysym_to_keycode(XK.string_to_keysym(name))] = mod

out_lock = threading.Lock()
track = None        # dict while tracking
held = {"Ctrl": False, "Alt": False}


def emit(line):
    with out_lock:
        print(line, flush=True)


def mods(state):
    return ",".join(n for n, m in (("shift", X.ShiftMask), ("ctrl", X.ControlMask), ("alt", X.Mod1Mask)) if state & m)


def active_title():
    try:
        wid = root.get_full_property(NET_ACTIVE, X.AnyPropertyType).value[0]
        w = local.create_resource_object("window", wid)
        name = w.get_wm_name()
        if not name:
            p = w.get_full_property(NET_NAME, X.AnyPropertyType)
            name = p.value if p else ""
        return name.decode(errors="replace") if isinstance(name, bytes) else (name or "")
    except Exception:
        return ""


def keysym_name(key):
    """APT/uiohook key name -> X keysym name ("Space" -> "space", "A" -> "a", "F5" -> "F5")."""
    return key if re.fullmatch(r"F\d+", key) else key.lower()


def do_grab(key, modnames):
    global grabbed
    do_ungrab()
    keycode = gdisp.keysym_to_keycode(XK.string_to_keysym(keysym_name(key)))
    if not keycode:
        emit(f"grab-error unknown key {key}")
        return
    mask = 0
    for n in modnames:
        mask |= {"shift": X.ShiftMask, "ctrl": X.ControlMask, "alt": X.Mod1Mask}.get(n, 0)
    WATCH_KEYS[keycode] = key
    busy = error.CatchError(error.BadAccess)
    for extra in (0, X.LockMask, X.Mod2Mask, X.LockMask | X.Mod2Mask):   # CapsLock / NumLock variants
        groot.grab_key(keycode, mask | extra, False, X.GrabModeAsync, X.GrabModeAsync, onerror=busy)
    gdisp.sync()
    grabbed = (keycode, mask)
    if busy.get_error():   # another client (e.g. APT with the unfiltered config) holds it
        emit(f"grab-error {key} already grabbed by another X client")
    else:
        emit(f"grabbed {key} {','.join(modnames)}")


def do_ungrab():
    global grabbed
    if grabbed:
        keycode, mask = grabbed
        for extra in (0, X.LockMask, X.Mod2Mask, X.LockMask | X.Mod2Mask):
            groot.ungrab_key(keycode, mask | extra)
        gdisp.sync()
        grabbed = None


def grab_loop():
    while True:          # grabbed key events also come via RECORD; just keep the queue empty
        gdisp.next_event()


def stdin_loop():
    global track
    for line in sys.stdin:
        f = line.split()
        if not f:
            continue
        if f[0] == "track" and len(f) == 9:
            fx, fy, thr, ax, ay, aw, ah = map(float, f[1:8])
            track = {"from": (fx, fy), "thr": thr, "area": (ax, ay, aw, ah), "hold": f[8], "held": None}
        elif f[0] == "untrack":
            track = None
        elif f[0] == "grab" and len(f) >= 2:
            do_grab(f[1], [m for m in (f[2].split(",") if len(f) > 2 else []) if m])
        elif f[0] == "ungrab":
            do_ungrab()
    os._exit(0)  # parent closed stdin


def inside(x, y, area):
    ax, ay, aw, ah = area
    return ax < x < ax + aw and ay < y < ay + ah


def set_held(mod, value):
    held[mod] = value
    t = track
    if t is not None and t["hold"] == mod and t["held"] != value:
        t["held"] = value
        emit(f"track hold {int(value)}")


def on_motion(x, y, state):
    global track
    set_held("Ctrl", bool(state & X.ControlMask))
    set_held("Alt", bool(state & X.Mod1Mask))
    t = track
    if t is None:
        return
    modifier = "Ctrl" if state & X.ControlMask else ("Alt" if state & X.Mod1Mask else "none")
    if modifier != t["hold"]:
        if math.hypot(x - t["from"][0], y - t["from"][1]) > t["thr"]:
            track = None
            emit("track hide")
    elif inside(x, y, t["area"]):
        track = None
        emit("track enter")


def callback(reply):
    global track
    if reply.category != record.FromServer or reply.client_swapped:
        return
    if not len(reply.data) or reply.data[0] < 2:
        return
    data = reply.data
    while len(data):
        event, data = rq.EventField(None).parse_binary_value(data, rec.display, None, None)
        if event.type == X.MotionNotify:
            on_motion(event.root_x, event.root_y, event.state)
        elif event.type == X.ButtonPress and event.detail in (1, 2, 3):
            t = track
            if t is not None and inside(event.root_x, event.root_y, t["area"]):
                track = None
                emit("track enter")
            else:
                emit(f"click {event.detail} {active_title()}")
        elif event.type in (X.KeyPress, X.KeyRelease) and event.detail in MOD_KEYS:
            set_held(MOD_KEYS[event.detail], event.type == X.KeyPress)
        elif event.type == X.KeyPress and event.detail in WATCH_KEYS:
            emit(f"key {WATCH_KEYS[event.detail]} {mods(event.state)}")


threading.Thread(target=grab_loop, daemon=True).start()
threading.Thread(target=stdin_loop, daemon=True).start()
emit(f"watching {disp}")
ctx = rec.record_create_context(0, [record.AllClients], [{
    "core_requests": (0, 0), "core_replies": (0, 0),
    "ext_requests": (0, 0, 0, 0), "ext_replies": (0, 0, 0, 0),
    "delivered_events": (0, 0), "device_events": (X.KeyPress, X.MotionNotify),
    "errors": (0, 0), "client_started": False, "client_died": False,
}])
try:
    rec.record_enable_context(ctx, callback)
except BrokenPipeError:  # parent (Quickshell) went away
    sys.exit(0)
