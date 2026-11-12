# APT Layer — technical notes

How APT Layer works, what it changes on your system, and the full command reference. How APT's own UI is
adapted: [apt-integration.md](apt-integration.md).

## How it works

```
apt-layer-launch → APT (--no-overlay, X11) ──xdg-open http://localhost:<port>/ → lib/xdg-open-shim → apt-layer
apt-layer → qs -p quickshell/   (LD_PRELOAD lib/libqs-webengine-shim.so)
  quickshell/shell.qml   PanelWindow on WlrLayer.Overlay, transparent WebEngineView, input region = widgets
  quickshell/adapter/    injected into APT's page: claims to be Electron, shims APT's /events websocket
  lib/x-watch.py         X RECORD on the game's X server: clicks / Esc / overlay key, mouse-away tracking,
                         and an X grab of the overlay key so the game never sees it
apt-layer ui → qs -p quickshell-ui/   control window; reads `apt-layer status --json` (lib/ctl.py)
```

- niri runs X11 apps through xwayland-satellite, which can't show APT's X11 overlay window. So APT runs
  headless (`--no-overlay`) and its UI — a local web page — is shown in a transparent wlr-layer-shell surface.
- **Modes**: idle (empty input region, fully click-through), shown (input region = the widgets, the game keeps
  the keyboard), focused (whole surface, exclusive keyboard).
- **Preload library**: Quickshell constructs `QGuiApplication` with `argc = 0`, and QtWebEngine aborts without
  a program name. `lib/qs-webengine-shim.cpp` wraps that constructor (argc = 1, `AA_ShareOpenGLContexts`) and
  removes itself from `LD_PRELOAD` for child processes. A Quickshell fix upstream would make it unnecessary.
  It's built for portability: any Qt 6 (no Qt version tag), glibc ≥ 2.34, no libstdc++ features beyond the ABI
  guard; `apt-layer doctor` checks that it loads.
- **Bundled python-xlib** (`lib/vendor`, LGPL-2.1-or-later, with `six`, MIT), used only if the system has none.

## Memory

About 450 MB (PSS) for the overlay, on top of APT's own ~195 MB without its window (measured on one system:
`qs` ~285 MB, Chromium's renderer ~120 MB, its other helper processes and the input watcher the rest).

- APT is an Electron app: its UI is a web page, and on Windows / X11 APT's own Chromium draws that page in its
  overlay window. On niri that window can't be shown as an overlay (xwayland-satellite doesn't support X11
  override-redirect windows), so APT runs with `--no-overlay` and only serves the page on `localhost`.
- Something has to draw the page, and the overlay needs a **wlr-layer-shell** surface. Chromium / Electron
  can't create those, so the page is shown by a web engine embedded in a layer-shell-capable toolkit:
  Quickshell + Qt WebEngine, which is Chromium-based — the same engine APT itself uses, so the page renders
  and behaves exactly as in APT.
- Lighter option, not done: WebKitGTK with gtk4-layer-shell would likely use less memory, but needs other
  packages and isn't tested with APT's page (WebKit renders and schedules differently from Chromium).

## Launching

- `apt-layer-launch` (the control window's **Start**, the "APT Layer" menu entry) starts APT with
  `--ozone-platform=x11 --no-overlay` and `lib/xdg-open-shim` first on its `PATH`. When APT opens its UI, the
  shim hands the URL to `apt-layer`, which starts the overlay (or points a running one at the new port).
  If APT already runs, only the overlay is started; if APT runs without `--no-overlay`, it's restarted.
- APT, the overlay and the control window run as transient **systemd user services** (`apt-layer-apt-*`,
  `apt-layer-*`, `apt-layer-ui-*` in `app.slice`), like an app launcher would start them — not as children of
  the terminal or window they were started from, so they don't inherit its per-app settings (cgroup limits,
  per-app network rules). APT's output: `journalctl --user -u 'apt-layer-apt-*'`. Without a systemd user
  session, or with `APT_LAYER_NO_SYSTEMD=1`, they're started with `setsid`.
- The overlay quits when APT exits (it checks for the `awakened-poe-tr` process every 5 s). Closing the control
  window leaves both running: while APT runs, its ✕ and the compositor's close (e.g. niri's Mod+Q) ask whether
  to quit APT too (the close request is refused until you choose).
- With `OUTPUT=auto` (the default) the overlay follows the monitor PoE's window is on: it's checked when the
  overlay starts and then every 3 s via niri (so also when PoE starts or moves), and the overlay only moves
  while it's idle. Before PoE runs, it uses the focused monitor.
- **One overlay at a time**, even across several copies of the folder (Quickshell matches instances by shell
  ID); `--foreground` and `--test` replace a running one.
- **One UI per APT**: APT sends price checks to the page that connected last, so a browser tab with APT's UI
  steals them.

## Finding Awakened PoE Trade

Order: the `APPIMAGE` setting; then the newest file from other apps' menu entries
(`~/.local/share/applications`, `$XDG_DATA_DIRS/applications`) and the usual folders (`~/.local/bin`,
`~/Applications` incl. one level of subfolders, `~/AppImages`, `~/.local/share/AppImages`, `~/Downloads`,
`/opt`), matching `awakened…poe…trade` case-insensitively; then an `awakened-poe-trade` command on `PATH`.
That covers AppImageLauncher, Gear Lever (renamed `*.appimage`), AM / AppMan and packages.
`apt-layer doctor` shows what was found and how.

## Settings

`~/.config/apt-layer/config` (`KEY=value`; example: `share/config.example`), also settable with
`apt-layer config KEY VALUE` or `APT_LAYER_<KEY>` environment variables. The control window shows the first two.

| Key | Default | |
|---|---|---|
| `OUTPUT` | `auto` | Monitor for the overlay: a niri output name, or `auto` = follow the one PoE is on |
| `APPIMAGE` | found automatically | The Awakened PoE Trade executable |
| `KEYBOARD` | `exclusive` | Advanced: `exclusive` gives the overlay the keyboard as soon as it's interactive (Esc works at once); `ondemand` only after a click on it. Only for compositors or other overlay tools that clash with the default |

## What gets written outside the folder

Quickshell's own cache and logs (`~/.cache/quickshell`, `$XDG_RUNTIME_DIR/quickshell`), the optional config
`~/.config/apt-layer/config`, app-menu entries you add (`~/.local/share/applications/apt-layer*.desktop`),
and APT's own settings. The overlay's web view keeps no profile on disk. The control window's app-id is
`apt-layer` (for niri window rules, e.g. to make it floating).

## Commands

| Command | |
|---|---|
| `apt-layer-ui` (top of the folder) | Open the control window (same as `bin/apt-layer ui`) |
| `apt-layer-launch [APT args]` | Start APT + the overlay (see *Launching*) |
| `apt-layer [URL]` | Start the overlay on APT's UI, or point a running one at URL (the `xdg-open` shim calls this) |
| `apt-layer --foreground [URL]` | Same, with logs in the terminal |
| `apt-layer --test` | A test page instead of APT (`dev/test-page/`), to check the overlay itself |
| `apt-layer --restart` | Restart the overlay on APT's UI |
| `apt-layer restart-apt` | Quit APT (however it was started) and start it again for APT Layer |
| `apt-layer quit` | Quit APT and the overlay (the control window's ✕ → *Quit APT too*) |
| `apt-layer launch-game` | Start Path of Exile through Steam (`steam://rungameid/238960`; your launch options apply) |
| `apt-layer ui` | Open the control window (focuses it if it's open) |
| `apt-layer status [--json]` | APT, PoE and overlay status |
| `apt-layer config KEY [VALUE]` | Show or set `OUTPUT` / `KEYBOARD` / `APPIMAGE` (`""` = default); applies to a running overlay |
| `apt-layer menu-entry add\|remove\|print [ui\|launch]` | App-menu entry for this copy |
| `apt-layer doctor [--json]` | Setup / health checks with fixes (the control window's Setup list) |
| `apt-layer build` | Build the preload library |
| `apt-layer --version` | Version (`VERSION`; git checkouts add the commit and whether files are modified) |
| `apt-layerctl status \| statusJson \| setMode idle\|shown\|focused \| setOutput NAME \| setKeyboard exclusive\|ondemand \| reloadPage \| setUrl URL \| kill \| log` | Control a running overlay (IPC) |

Logs: `apt-layerctl log | grep -E 'mode:|item-text|track|open-url'`. Config keys can also be set with
`APT_LAYER_<KEY>` environment variables.

## Install, dist, development

- `make` builds the preload library; `bin/*` run straight from the checkout.
- `make install` (`PREFIX=~/.local`) copies the tree to `$PREFIX/share/apt-layer` (same layout, so every script
  finds its files relative to itself), symlinks the commands into `$PREFIX/bin` and adds both menu entries;
  `make uninstall` removes exactly those files.
- `make dist` writes `build/apt-layer-VERSION.tar.gz`: the repo's files plus the prebuilt library.

## Versions and releases

The version lives in `VERSION` (semantic versioning; `0.x` until it has been used more widely). It's shown by
`apt-layer --version`, the first line of `apt-layer doctor` and the control window's title. A git checkout
between releases shows e.g. `0.1.0+git abc1234 (modified)`; a release tarball or an exactly tagged, clean
checkout shows just `0.1.0`.

To release: bump `VERSION`, commit, tag `vX.Y.Z` (must match `VERSION`), `make dist`, and attach
`build/apt-layer-X.Y.Z.tar.gz` to the GitHub release (it has the preload library prebuilt; GitHub's
automatic source archives don't).
