// ── El Rey · Service Worker Registration ─────────────────────────────────
// Incluir con <script src="./src/register-sw.js"></script> en cada página.
// NO es un módulo ES — se ejecuta de forma clásica para registrar el SW.

if ('serviceWorker' in navigator) {
  let recargando = false;
  // Cuando un SW nuevo toma el control, recargamos una sola vez.
  navigator.serviceWorker.addEventListener('controllerchange', () => {
    if (recargando) return;
    recargando = true;
    window.location.reload();
  });

  window.addEventListener('load', () => {
    navigator.serviceWorker.register('./service-worker.js', { scope: './' })
      .then(reg => {
        // si ya hay uno esperando al registrar, activarlo
        if (reg.waiting) reg.waiting.postMessage({ type: 'SKIP_WAITING' });
        // si aparece uno nuevo durante la sesión, activarlo apenas instale
        reg.addEventListener('updatefound', () => {
          const newWorker = reg.installing;
          newWorker?.addEventListener('statechange', () => {
            if (newWorker.state === 'installed' && navigator.serviceWorker.controller) {
              console.info('[SW] Nueva versión instalada, activando…');
              newWorker.postMessage({ type: 'SKIP_WAITING' });
            }
          });
        });
        // chequear updates cada 30 min sin esperar a un reload manual
        setInterval(() => reg.update().catch(() => {}), 30 * 60 * 1000);
      })
      .catch(err => console.warn('[SW] Registro falló:', err));
  });
}
