# APT integration — findings and adapter design

Read-only study of Awakened PoE Trade **v3.29.108** (source tag `v3.29.108`, commit `543423a`, plus the
bundled `app.asar` of the installed AppImage), 2026-11-12. Paths below are relative to the APT repo.

## How APT's UI decides it is an overlay

- `renderer/src/web/background/IPC.ts`: `get isElectron () { return navigator.userAgent.includes('Electron') }`.
  That single check switches the whole UI between **overlay mode** and **browser mode**.
- In browser mode `Host.onEvent()` silently **does not register** any `MAIN->OVERLAY::*` handler
  (`focus-change`, `visibility`, `hide-exclusive-widget`, `overlay-attached`).
- Browser mode differences that matter for us (`overlay/OverlayWindow.vue`, `price-check/PriceCheckWindow.vue`):
  - `active` is always `true` → `invisible-on-blur` widgets (the widget menu) are always shown, and the
    full-screen `overlayBackground` tint (`rgba(129,139,149,.15)` by default) is always painted.
  - `poePanelWidth` is `0` → a price check of a **stash** item is drawn at x=0, on top of the stash. In overlay
    mode it sits next to PoE's side panel (`height × 986/1600` ≈ 887 px at 1440p).
  - No `track-area`, no hold-key / move-away close, no hide-on-blur. Closing = background click (hides the
    exclusive widget) or the title-bar close button.
  - Esc is **not** handled by the page in either mode — in Electron, main handles Esc / Ctrl+W in
    `before-input-event` of its overlay window (`OverlayWindow.ts`) and calls `assertGameActive()`.
- `index.html` has `<meta name="color-scheme" content="dark">` → Chromium may paint a dark canvas behind a page
  with no background. Needs injected CSS (to verify live).

## What main does in `--no-overlay` mode

- `OverlayWindow` creates no window; `loadAppPage()` → `shell.openExternal(url)` (our xdg-open shim).
- PoE is still tracked: `OverlayController.attachByTitle(undefined, title)` = electron-overlay-window
  **tracking mode**; `focus`/`blur` → `GameWindow.isActive` → broadcast `MAIN->OVERLAY::focus-change
  {game, overlay: isInteractable, usingHotkey}`. Hotkeys (Electron `globalShortcut`, i.e. X key grabs) are
  registered only while PoE is active.
- **`OverlayController.activateOverlay()` throws in tracking mode** (`'You are using the library in tracking
  mode'`, `dist/index.js`). It's reached via `assertOverlayActive()` from:
  - the overlay key (Shift+Space, `toggle-overlay`) → throws inside a `globalShortcut` callback
    (`isInteractable` is set to `true` *before* the throw, so main's state gets out of sync);
  - locked price check (Ctrl+Alt+D, `focusOverlay`) — only if `wasUsedRecently`, which is the last
    `CLIENT->MAIN::used-recently {isOverlay}` value. Browser mode sends `isOverlay: false` → never reached.
    (On a websocket close leaving one client, main emits `isOverlay: true` itself.)
  - `WidgetAreaTracker` (after a `track-area` event) when the mouse enters the widget area.
- `focusTarget()` works in tracking mode (`lib.focusTarget()` focuses PoE via X11).
- `OverlayVisibility` still broadcasts `MAIN->OVERLAY::visibility` (hold Alt hides the UI).
- `MAIN->CLIENT::item-text {target, clipboard, position, focusOverlay}` goes to the **last-active** client;
  `position` is `screen.getCursorScreenPoint()` = X coordinates (they match the overlay's coordinates only on an
  output at 0,0 with scale 1).

## APT's real overlay UX (what we want to reproduce)

- **Ctrl+D (unlocked)**: price check shown, overlay **not** focused — the game keeps the keyboard.
  Main tracks the mouse (`track-area`): holding Ctrl and moving into the panel → overlay becomes interactive;
  moving > `2.5 × fontSize` px away from the press point without holding Ctrl → `hide-exclusive-widget`.
- **Ctrl+Alt+D (locked)**: price check shown **and** overlay focused at once.
- **Overlay key (Shift+Space)**: overlay focused; the whole screen is the overlay (tinted background, widget
  menu visible). Clicking the background → `focus-game`.
- **Overlay focused → game** (Esc, Ctrl+W, background click, `focus-game` from the UI, PoE regains focus):
  `focus-change {overlay:false}` → the UI hides `hide-on-blur` widgets (the price check has it).

## Recommended adapter: be APT's overlay half

The overlay page **claims to be Electron** and an injected script **shims the `/events` websocket**, so APT's UI
runs its real overlay logic while our host plays the role of main's (broken) overlay half. Injected with a
`WebEngineScript` at `DocumentCreation` in the main world, before APT's bundle runs.

1. `navigator.userAgent` gets `Electron` appended (in the page only; real HTTP requests keep the normal UA).
2. **Outgoing** (page → main):
   - `CLIENT->MAIN::used-recently` → rewrite `isOverlay: false` (keeps us last-active, but main never calls the
     throwing `assertOverlayActive()` for locked checks).
   - `OVERLAY->MAIN::focus-game` → swallow; host goes **idle**.
   - `OVERLAY->MAIN::track-area` → swallow; host implements the hold/move-away logic (see 4).
3. **Incoming** (main → page): pass everything except `MAIN->OVERLAY::focus-change`, which the shim replaces
   with its own `{game, overlay}` (main's `game:true` transitions are still used as "PoE regained focus" → idle).
4. **Host states** (Quickshell):

   | State | Trigger | Input region | Keyboard | Page sees |
   |---|---|---|---|---|
   | idle | start, Esc, background click, click on PoE, PoE refocused | empty | None | `focus-change {game:true, overlay:false}` |
   | shown | `item-text` with `focusOverlay:false` | widget rects | None (PoE keeps keys, APT hotkeys keep working) | — |
   | focused | `item-text` with `focusOverlay:true`, overlay key, Ctrl+mouse into the panel, click in the panel | whole surface | Exclusive | `focus-change {game:false, overlay:true}` |

   - shown → idle when the pointer moves > threshold from the press point without the hold key: needs pointer
     motion + modifier state from the X RECORD watcher (pointer over PoE); clicks on PoE → idle (watcher, done).
   - focused → idle on Esc / Ctrl+W (page keydown, like main's `before-input-event`) and background click
     (`focus-game`).
   - Overlay key: the X watcher sees Shift+Space → focused/idle toggle. The adapter strips the `toggle-overlay`
     shortcut from `update-host-config`, so main doesn't register it and can't throw (confirmed: the error
     dialog appeared before this). `x-watch.py` grabs the key on X instead (else PoE gets Space down but never
     Space up, and a Space-bound "move" keeps going).
5. **Input rects** for the shown state: visible `#widget-<id>` roots; where a root is `pointer-events: none`
   (the price check's full-size wrapper), use its `pointer-events: auto` descendants (`#price-window`).
6. **CSS**: `html, body` transparent (and check the `color-scheme: dark` canvas).

Why not plain browser mode: no stash-side placement, the tint and widget menu are always on, and every overlay
behaviour would have to be rebuilt by poking Vue internals instead of feeding APT the events it already handles.

## Launch plumbing

- `apt-layer-launch` starts APT with `--ozone-platform=x11 --no-overlay` and `lib/xdg-open-shim` first on
  APT's `PATH`. APT opens its UI with `xdg-open http://localhost:<port>/index.html` (at start and from the tray's
  "Open in Browser"); the shim hands that URL to `apt-layer`, other URLs go to the real `xdg-open`.
- `apt-layer URL` starts the overlay, or calls `setUrl` on a running one (APT restarted on a new port).
- The overlay polls for APT every 5 s and quits when it's gone.
- The overlay page must be APT's only websocket client: a browser tab with APT's UI steals price checks.

## Verified (2026-11-12, niri 26.04, APT 3.29.108, PoE in Windowed Fullscreen and Fullscreen)

- The adapter is injected before APT's bundle (UA override + websocket shim work; `update-host-config` is seen).
- The page is fully transparent with `html, body, #app { background: transparent }` — no dark canvas.
- Synthetic `focus-change` drives APT's overlay mode (widget menu, tint) and hides `hide-on-blur` widgets.
- In game: Ctrl+D (shown, auto-hide on mouse-away via `track-area`), Ctrl+Alt+D (focused), the overlay key,
  Esc, click-to-idle, panel placement next to the stash / inventory panel, and links (opened externally).
- xwayland-satellite does change the active X window when the overlay takes the keyboard: main reports
  `focus-change {game:false}` (and unregisters its hotkeys) while focused, `game:true` afterwards.
- Before the `toggle-overlay` filter, Shift+Space showed Electron's "A JavaScript error occurred in the main
  process … tracking mode" dialog; with the filter it doesn't.

## Open

- Outputs not at 0,0 or with fractional scale: `window.screenX` in the layer surface, X pointer coordinates
  and the overlay's coordinates need a mapping (untested).
- APT's built-in browser (`<webview>`) could be a second WebEngineView inside the overlay instead of an
  external browser.
