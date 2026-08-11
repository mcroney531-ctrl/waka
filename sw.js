// Minimal service worker for the Documentary Acquisitions Ledger PWA.
// Goal: installability + a home-screen app shell that still loads offline.
// Deliberately conservative: app pages are network-first (so a deploy is never
// stuck behind a stale cache), and Supabase traffic is never cached.
const CACHE = 'dal-v3';
const SHELL = [
  './',
  './index.html',
  './brainstorm.html',
  './manifest.webmanifest',
  './icons/icon-192.png',
  './icons/icon-512.png',
  './icons/maskable-192.png',
  './icons/maskable-512.png',
  './icons/apple-touch-icon.png'
];

self.addEventListener('install', (e) => {
  e.waitUntil(
    caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;

  let url;
  try { url = new URL(req.url); } catch (_) { return; }

  // Never intercept Supabase (REST, auth, edge functions) — always live.
  if (url.hostname.endsWith('supabase.co')) return;

  // Page loads: network-first, fall back to the cached shell when offline.
  if (req.mode === 'navigate') {
    e.respondWith(fetch(req).catch(() => caches.match('./index.html')));
    return;
  }

  // Everything else (local assets + CDN libs/fonts): cache-first, then network,
  // populating the cache as we go so a second visit works offline.
  e.respondWith(
    caches.match(req).then((hit) => {
      if (hit) return hit;
      return fetch(req).then((res) => {
        if (res && (res.ok || res.type === 'opaque')) {
          const copy = res.clone();
          caches.open(CACHE).then((c) => c.put(req, copy)).catch(() => {});
        }
        return res;
      });
    })
  );
});
