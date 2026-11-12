// Injected at DocumentReady: transparent page background (APT's index.html declares color-scheme: dark).
(() => {
  const style = document.createElement('style');
  style.id = 'apt-layer-css';
  style.textContent = `
    html, body, #app { background: transparent !important; }
    webview { display: none !important; } /* Electron-only built-in browser; adapter.js opens its URL externally */
  `;
  document.head.appendChild(style);
})();
