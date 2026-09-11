// Only public application files are cached. OAuth callbacks, API responses,
// user profiles, tokens, downloads and records never enter this cache.
const CACHE = 'ppomi-public-home-20260911-11';
const PUBLIC_PATHS = new Set([
  '/', '/web/vendor/tokens.css', '/web/workbench/app.css', '/web/workbench/app.js', '/web/home.css', '/web/home.js', '/web/auth.js', '/web/auth-client.js', '/web/auth-error.js', '/web/config.js', '/web/device-store.js',
  '/web/records.js', '/web/record-rpc.js', '/web/record-protocol.js', '/web/record-session.js', '/web/record-crypto.js', '/web/record-views.js', '/web/timeline-projection.js', '/web/lzfse.js', '/web/vendor/ledger-display.js',
  '/web/transcript-protocol.js', '/web/transcript-client.js', '/web/transcript-realtime.js', '/web/transcript-session.js',
  '/install-guide.js', '/install-guide.css', '/manifest.webmanifest',
  '/icon.png', '/paw.svg', '/web/app-icon.svg',
]);

self.addEventListener('install', (event) => {
  event.waitUntil((async () => {
    const cache = await caches.open(CACHE);
    await cache.addAll([...PUBLIC_PATHS].map((path) => new Request(path, {cache: 'reload', credentials: 'omit'})));
    // The new worker takes over when the existing app windows are closed.
    // Do not replace running authentication code in the middle of a login.
  })());
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    const names = await caches.keys();
    await Promise.all(names.filter((name) => name.startsWith('ppomi-public-home-') && name !== CACHE).map((name) => caches.delete(name)));
    await self.clients.claim();
  })());
});

self.addEventListener('fetch', (event) => {
  const request = event.request;
  const url = new URL(request.url);
  if (request.method !== 'GET' || request.headers.has('Authorization')
    || url.origin !== self.location.origin || url.search || !PUBLIC_PATHS.has(url.pathname)) return;
  event.respondWith((async () => {
    const cache = await caches.open(CACHE);
    try {
      const response = await fetch(request, {cache: 'no-cache', credentials: 'omit'});
      if (response.ok && response.type === 'basic' && !response.redirected) {
        await cache.put(url.pathname, response.clone());
      }
      return response;
    } catch {
      const cached = await cache.match(url.pathname);
      if (cached) return cached;
      return new Response('인터넷에 연결한 뒤 다시 열어 주세요.', {
        status: 503, headers: {'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store'},
      });
    }
  })());
});
