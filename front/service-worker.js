// ── El Rey · Service Worker ───────────────────────────────────────────────
// Estrategia: shell precacheado + network-first para páginas +
//             cache-first para librerías CDN + network-only para Supabase API.

const CACHE_SHELL   = 'elrey-shell-v23';
const CACHE_CDN     = 'elrey-cdn-v23';
const OFFLINE_PAGE  = './offline.html';

const SHELL_FILES = [
  './offline.html',
  './login_home.html',
  './pedido_preventista.html',
  './hoja_ruta.html',
  './clientes.html',
  './boleta.html',
  './no_entregados.html',
  './src/supabase.js',
  './src/auth.js',
  './src/utils.js',
  './src/db.js',
  './src/sync.js',
  './src/register-sw.js',
  './manifest.webmanifest',
  './icons/icon.svg',
  './icons/icon-maskable.svg',
];

// ── INSTALL ───────────────────────────────────────────────────────────────
self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(CACHE_SHELL)
      .then(cache => cache.addAll(SHELL_FILES))
      .then(() => self.skipWaiting())
  );
});

// ── ACTIVATE ──────────────────────────────────────────────────────────────
self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(
        keys
          .filter(k => k !== CACHE_SHELL && k !== CACHE_CDN)
          .map(k => caches.delete(k))
      ))
      .then(() => self.clients.claim())
  );
});

// ── FETCH ─────────────────────────────────────────────────────────────────
self.addEventListener('fetch', event => {
  const { request } = event;
  const url = new URL(request.url);

  // 1. Supabase API / Auth → Network Only (nunca cachear datos sensibles)
  if (url.hostname.endsWith('supabase.co') || url.hostname.endsWith('supabase.io')) {
    return; // deja que el browser maneje normalmente
  }

  // 2. CDN de librerías (esm.sh, unpkg.com, cdn.jsdelivr.net) → Cache-First
  if (
    url.hostname === 'esm.sh' ||
    url.hostname === 'unpkg.com' ||
    url.hostname === 'cdn.jsdelivr.net' ||
    url.hostname === 'storage.googleapis.com'
  ) {
    event.respondWith(cacheFirst(request, CACHE_CDN));
    return;
  }

  // 3. Navegación HTML y archivos locales → Network-First con fallback
  if (request.method === 'GET') {
    event.respondWith(networkFirstWithFallback(request));
  }
});

// ── ESTRATEGIAS ───────────────────────────────────────────────────────────

async function cacheFirst(request, cacheName) {
  const cache  = await caches.open(cacheName);
  const cached = await cache.match(request);
  if (cached) return cached;
  try {
    const resp = await fetch(request);
    if (resp.ok) cache.put(request, resp.clone());
    return resp;
  } catch {
    return new Response('Sin conexión', { status: 503, statusText: 'Service Unavailable' });
  }
}

async function networkFirstWithFallback(request) {
  const cache = await caches.open(CACHE_SHELL);
  try {
    const resp = await fetch(request);
    if (resp.ok) {
      // actualizar cache silenciosamente
      cache.put(request, resp.clone());
    }
    return resp;
  } catch {
    const cached = await cache.match(request);
    if (cached) return cached;

    // fallback para navegación HTML
    const isNavigation =
      request.destination === 'document' ||
      request.headers.get('accept')?.includes('text/html');
    if (isNavigation) {
      const offline = await cache.match(OFFLINE_PAGE);
      if (offline) return offline;
    }

    return new Response('Sin conexión', {
      status: 503,
      headers: { 'Content-Type': 'text/plain; charset=utf-8' },
    });
  }
}

// ── BACKGROUND SYNC ───────────────────────────────────────────────────────
// Si el browser soporta Background Sync, intentamos flushear la cola
// automáticamente cuando se recupera la conexión.
self.addEventListener('sync', event => {
  if (event.tag === 'elrey-sync-queue') {
    event.waitUntil(notifyClientsToSync());
  }
});

async function notifyClientsToSync() {
  const clients = await self.clients.matchAll({ type: 'window' });
  clients.forEach(client => client.postMessage({ type: 'SW_SYNC_REQUESTED' }));
}

// ── PUSH NOTIFICATIONS (placeholder) ─────────────────────────────────────
self.addEventListener('push', event => {
  if (!event.data) return;
  const data = event.data.json();
  event.waitUntil(
    self.registration.showNotification(data.title || 'El Rey', {
      body: data.body || '',
      icon: './icons/icon.svg',
      badge: './icons/icon.svg',
      tag: data.tag || 'elrey',
    })
  );
});
