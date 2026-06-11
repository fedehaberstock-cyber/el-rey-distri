// ── El Rey · Service Worker Registration ─────────────────────────────────
// Incluir con <script src="./src/register-sw.js"></script> en cada página.
// NO es un módulo ES — se ejecuta de forma clásica para registrar el SW.

if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('./service-worker.js', { scope: './' })
      .then(reg => {
        // activar nueva versión inmediatamente si hay una esperando
        if (reg.waiting) reg.waiting.postMessage({ type: 'SKIP_WAITING' });
        reg.addEventListener('updatefound', () => {
          const newWorker = reg.installing;
          newWorker?.addEventListener('statechange', () => {
            if (newWorker.state === 'installed' && navigator.serviceWorker.controller) {
              // hay nueva versión disponible — notificar opcionalmente
              console.info('[SW] Nueva versión disponible. Recargá para actualizar.');
            }
          });
        });
      })
      .catch(err => console.warn('[SW] Registro falló:', err));
  });
}
