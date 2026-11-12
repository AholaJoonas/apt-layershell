# APT Layer

**Awakened PoE Trade's overlay on layer-shell — for niri & others.**

[Awakened PoE Trade](https://github.com/SnosMe/awakened-poe-trade) (APT) on Linux normally draws its price checks as an X11
overlay over Path of Exile. On niri that overlay can't be shown.

**TL;DR:** niri runs X11 apps through xwayland-satellite, which can't show APT's overlay windows. This project draws APT's UI in a Quickshell layer-shell overlay instead.

Status: early. Built and used on niri with APT 3.29.108 and Path of Exile 1.

## Requirements

- A Wayland compositor with layer-shell: **niri** (tested); Hyprland, Sway, KDE and others may work. Not GNOME.
- Path of Exile and APT running on **X11** (Xwayland / xwayland-satellite). Don't add Wayland options like
  `PROTON_ENABLE_WAYLAND=1` to the game's launch options (some Proton versions ignore it, others don't) — the
  APT Layer UI warns if the game runs as a Wayland window.
- **Quickshell** with **Qt WebEngine**, and **python3**.
- **Awakened PoE Trade** (the AppImage version (if there even is anything else)).

Not sure what you have? Just install Quickshell and run `./apt-layer-ui`: the APT Layer UI checks the rest
and tells you what's missing and how to install it.

## Getting started

1. **Get it:** `git clone https://github.com/AholaJoonas/apt-layershell`, or download and unpack the latest
   [release](https://github.com/AholaJoonas/apt-layershell/releases) (it has the preload library prebuilt).
2. **Install [Quickshell](https://quickshell.org/docs/guide/install-setup/)** if you don't have it.
3. **Run `./apt-layer-ui`** in the folder.
4. If everything is ok - press **Start APT + overlay** and start PoE.

Nothing is installed into your system; keep the folder anywhere (`make install` is optional). Prefer the
terminal? `bin/apt-layer doctor` checks everything and `bin/apt-layer-launch` starts APT + the overlay; more in
[docs/technical.md](docs/technical.md).

## Issues & limitations

- The game should fill its monitor: PoE's *Windowed Fullscreen* and *Fullscreen* both work (Wayland has no
  exclusive fullscreen); in *Windowed* mode APT's panels may land next to the game instead of its inventory.
- Only tested with the game on a monitor at position 0,0 and scale 1; other layouts may misplace clicks.
- Depends on APT's internals (tested with 3.29.108); an APT update may need an APT Layer update.
- APT's built-in browser opens in your normal browser instead.
- Bit of a memory hog - Uses about 450 MB of memory on top of APT. APT's UI is a web page that APT normally shows in its own
  window; that window can't be an overlay on niri, so APT Layer shows the page itself, with a Chromium-based
  engine (Qt WebEngine). [Why not lighter?](docs/technical.md#memory)

## More

- [docs/technical.md](docs/technical.md) — how it works, launching, all commands, install / development.
- [docs/apt-integration.md](docs/apt-integration.md) — how APT's UI is adapted.

## License

MIT — see [LICENSE](LICENSE). Bundled python-xlib (LGPL-2.1-or-later) and six (MIT): see `lib/vendor`.
Awakened PoE Trade is a separate project you install yourself. Not affiliated with Grinding Gear Games or the
APT authors.
