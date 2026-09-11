// A sandboxed record frame cannot read the host document. record-views.js copies
// an explicit html[data-theme] (light|dark) into the frame URL; with none, the
// frame follows the system scheme through tokens.css exactly like the host page.
(() => {
  'use strict';
  const theme = new URLSearchParams(location.search).get('theme');
  if (theme === 'light' || theme === 'dark') document.documentElement.dataset.theme = theme;
})();
