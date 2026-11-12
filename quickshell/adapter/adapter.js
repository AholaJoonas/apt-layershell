// Injected into APT's page (QtWebEngine user script, DocumentCreation, main world) before APT's bundle runs.
// Makes APT's UI run in its overlay mode and plays the overlay half of APT's main process,
// which is broken in --no-overlay mode. See docs/apt-integration.md.
//
// page -> host: console.debug("__aptov " + JSON)   (shell.qml parses onJavaScriptConsoleMessage)
// host -> page: window.__aptov.*                   (shell.qml runJavaScript)
(() => {
  if (window.__aptov) return;

  const post = (type, data = {}) => console.debug('__aptov ' + JSON.stringify({ type, ...data }));

  // 1. APT's UI checks navigator.userAgent.includes('Electron') to pick overlay mode.
  const ua = navigator.userAgent + ' Electron/apt-layer';
  Object.defineProperty(Navigator.prototype, 'userAgent', { get: () => ua, configurable: true });

  // 2. Shim the /events websocket (APT uses Sockette, which sets ws.onmessage and calls ws.send).
  const NativeWS = window.WebSocket;
  const onmessageDesc = Object.getOwnPropertyDescriptor(NativeWS.prototype, 'onmessage');
  let events = null;        // the /events socket
  let deliver = null;       // page's onmessage handler, for synthetic events

  const inject = (name, payload) => {
    if (deliver) deliver.call(events, new MessageEvent('message', { data: JSON.stringify({ name, payload }) }));
  };

  class ShimWebSocket extends NativeWS {
    constructor (url, protocols) {
      super(url, protocols);
      this.__isEvents = String(url).endsWith('/events');
      if (this.__isEvents) { events = this; post('ws-open', { url: String(url) }); }
    }

    set onmessage (fn) {
      this.__onmessage = fn;
      if (!this.__isEvents || typeof fn !== 'function') return onmessageDesc.set.call(this, fn);
      deliver = fn;
      onmessageDesc.set.call(this, (ev) => {
        let msg;
        try { msg = JSON.parse(ev.data); } catch { return fn.call(this, ev); }
        switch (msg.name) {
          case 'MAIN->OVERLAY::focus-change':
            // We own focus-change; main's view is only a hint ("PoE got focus back").
            post('main-focus', msg.payload);
            return;
          case 'MAIN->CLIENT::item-text':
            post('item-text', { target: msg.payload.target, focusOverlay: msg.payload.focusOverlay, position: msg.payload.position });
            break;
          case 'MAIN->OVERLAY::visibility':
          case 'MAIN->OVERLAY::hide-exclusive-widget':
          case 'MAIN->OVERLAY::overlay-attached':
            post('main-event', { name: msg.name, payload: msg.payload });
            break;
        }
        return fn.call(this, ev);
      });
    }

    get onmessage () { return this.__onmessage; }

    send (data) {
      if (this.__isEvents) {
        let msg = null;
        try { msg = JSON.parse(data); } catch {}
        switch (msg?.name) {
          case 'CLIENT->MAIN::used-recently':
            // Stay last-active, but never let main call its (throwing) assertOverlayActive().
            msg.payload = { isOverlay: false };
            return super.send(JSON.stringify(msg));
          case 'OVERLAY->MAIN::focus-game':
            post('focus-game');
            return;
          case 'OVERLAY->MAIN::track-area':
            post('track-area', msg.payload);
            return;
          case 'CLIENT->MAIN::update-host-config': {
            overlayKey = msg.payload.overlayKey || overlayKey;
            // Main's toggle-overlay handler calls activateOverlay(), which throws in --no-overlay mode
            // ("You are using the library in tracking mode" error dialog). Don't let main register the
            // overlay key; the host toggles via the X watcher instead.
            const before = msg.payload.shortcuts.length;
            msg.payload.shortcuts = msg.payload.shortcuts.filter(s => s.action?.type !== 'toggle-overlay');
            post('host-config', { overlayKey, droppedShortcuts: before - msg.payload.shortcuts.length });
            return super.send(JSON.stringify(msg));
          }
        }
      }
      return super.send(data);
    }
  }
  window.WebSocket = ShimWebSocket;

  // 3. Esc / Ctrl+W / the overlay key while the overlay has the keyboard = back to the game.
  //    (Main does this in Electron's before-input-event; same key naming as OverlayWindow.ts.)
  let overlayKey = 'Shift + Space';
  const keyName = (e) => {
    let code = e.code;
    if (code.startsWith('Key')) code = code.slice(3);
    else if (code.startsWith('Digit')) code = code.slice(5);
    if (e.shiftKey && e.altKey) return `Shift + Alt + ${code}`;
    if (e.ctrlKey && e.shiftKey) return `Ctrl + Shift + ${code}`;
    if (e.ctrlKey && e.altKey) return `Ctrl + Alt + ${code}`;
    if (e.altKey) return `Alt + ${code}`;
    if (e.ctrlKey) return `Ctrl + ${code}`;
    if (e.shiftKey) return `Shift + ${code}`;
    return code;
  };
  window.addEventListener('keydown', (e) => {
    const k = keyName(e);
    if (k === 'Escape' || k === 'Ctrl + W' || k === overlayKey) {
      e.preventDefault();
      e.stopPropagation();
      post('focus-game', { why: k });
    }
  }, true);

  // 4. Clicks inside widgets while "shown" (unlocked) make the overlay interactive (APT: WidgetAreaTracker).
  window.addEventListener('mousedown', () => post('page-mousedown'), true);
  //    Pointer reached a widget (only widgets take input while "shown"): with the hold key down
  //    (tracked by the host from X) that also makes the overlay interactive.
  let lastPointer = 0;
  window.addEventListener('mousemove', () => {
    const now = performance.now();
    if (now - lastPointer > 200) { lastPointer = now; post('page-pointer'); }
  }, true);

  // 5. APT's built-in trade browser is an Electron <webview> (PriceCheckWindow.vue), which QtWebEngine
  //    doesn't have: it's an HTMLUnknownElement whose .src APT sets. Hand that URL to the host (opens it
  //    in the default browser); adapter-css.js hides the element so it takes no space or input.
  //    window.open / target=_blank links are handled by the host's newWindowRequested.
  Object.defineProperty(HTMLUnknownElement.prototype, 'src', {
    configurable: true,
    get () { return this.__src ?? ''; },
    set (url) {
      this.__src = url;
      if (this.localName === 'webview' && url) post('open-url', { url: String(url), via: 'webview' });
    },
  });

  // 6. Host API.
  window.__aptov = {
    // APT's real overlay sends this on focus changes; drives active/hide-on-blur in the UI.
    setFocus (game, overlay) { inject('MAIN->OVERLAY::focus-change', { game, overlay, usingHotkey: false }); },
    hideExclusive () { inject('MAIN->OVERLAY::hide-exclusive-widget', undefined); },
    // Rects that should take pointer input while "shown": visible widgets; where a widget root is
    // pointer-events:none (e.g. the price check's full-size wrapper), its pointer-events:auto children.
    rects () {
      const out = [];
      const visit = (el, depth) => {
        const cs = getComputedStyle(el);
        if (cs.display === 'none' || cs.visibility === 'hidden') return;
        if (cs.pointerEvents !== 'none') {
          const r = el.getBoundingClientRect();
          if (r.width <= 0 || r.height <= 0) return;
          // Full-height columns (e.g. #price-window) are mostly empty: use their children instead,
          // so the transparent part below the content stays click-through.
          if (r.height >= window.innerHeight - 1 && el.children.length && depth < 5) {
            for (const c of el.children) visit(c, depth + 1);
            return;
          }
          out.push({ x: r.x, y: r.y, w: r.width, h: r.height });
          return;
        }
        if (depth < 5) for (const c of el.children) visit(c, depth + 1);
      };
      document.querySelectorAll('#overlay-window > [id^="widget-"]').forEach(el => visit(el, 0));
      return out;
    },
  };

  post('injected', { ua });
})();
