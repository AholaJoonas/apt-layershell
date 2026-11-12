#!/usr/bin/env python3
"""niri-query - small `niri msg -j` lookups for the shell scripts (so they don't need jq).

  niri-query.py poe-output        output PoE's window ("Path of Exile") is on
  niri-query.py focused-output    focused output's name
  niri-query.py geometry NAME     "x y scale" of an output (logical)
  niri-query.py focus APP_ID      focus the newest window with that app-id; exit 1 if there is none

Prints nothing (exit 0) when niri isn't reachable or there is no answer.
"""
import json, subprocess, sys


def niri(*args):
    try:
        out = subprocess.run(["niri", "msg", "-j", *args], capture_output=True, text=True, timeout=3)
        return json.loads(out.stdout) if out.returncode == 0 else None
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None


def main(argv):
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd == "poe-output":
        windows, workspaces = niri("windows") or [], niri("workspaces") or []
        ws_id = next((w.get("workspace_id") for w in windows if w.get("title") == "Path of Exile"), None)
        out = next((ws.get("output") for ws in workspaces if ws.get("id") == ws_id), None) if ws_id is not None else None
        if out:
            print(out)
    elif cmd == "focused-output":
        o = niri("focused-output") or {}
        if o.get("name"):
            print(o["name"])
    elif cmd == "geometry" and len(argv) > 2:
        lg = ((niri("outputs") or {}).get(argv[2]) or {}).get("logical") or {}
        if lg:
            print(lg.get("x"), lg.get("y"), lg.get("scale"))
    elif cmd == "focus" and len(argv) > 2:
        wins = [w for w in niri("windows") or [] if w.get("app_id") == argv[2]]
        if not wins:
            return 1
        wid = max(wins, key=lambda w: w.get("id", 0))["id"]
        return subprocess.run(["niri", "msg", "action", "focus-window", "--id", str(wid)],
                              capture_output=True).returncode
    else:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
