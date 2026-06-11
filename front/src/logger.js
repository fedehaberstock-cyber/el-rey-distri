// ── El Rey · Logger de errores frontend ──────────────────────────────────
// Script clásico (no módulo) — incluir con:
//   <script src="./src/logger.js"></script>
// en TODAS las páginas, antes del módulo principal.
//
// Captura automáticamente:
//   - window.onerror   (errores JS no capturados)
//   - unhandledrejection (promesas rechazadas sin catch)
// Exporta window.logError(msg, error) para uso manual.

(function () {
  const SUPABASE_URL  = 'https://rqbpzmkcwxruzszbtsjv.supabase.co';
  const SUPABASE_ANON = 'sb_publishable_tdI7VSKRcEqhaTVY0ipprA_umkrtiQb';

  // ── Leer sesión desde Supabase auth storage ──────────────────────────
  function getAuthToken() {
    try {
      // Supabase almacena la sesión en localStorage con clave auto-generada
      for (let i = 0; i < localStorage.length; i++) {
        const key = localStorage.key(i);
        if (key && key.startsWith('sb-') && key.endsWith('-auth-token')) {
          const raw = localStorage.getItem(key);
          if (raw) return JSON.parse(raw)?.access_token ?? null;
        }
      }
    } catch {}
    return null;
  }

  function getUsuarioLocal() {
    try {
      const raw = sessionStorage.getItem('elrey.usuario');
      return raw ? JSON.parse(raw) : null;
    } catch { return null; }
  }

  // ── Enviar a Supabase via REST (no depende de supabase-js) ────────────
  function enviar(mensaje, stack, extra) {
    // No bloquear nada — fire-and-forget sin await
    try {
      const token   = getAuthToken() ?? SUPABASE_ANON;
      const usuario = getUsuarioLocal();

      const body = JSON.stringify({
        empresa_id: usuario?.empresa_id ?? null,
        usuario_id: usuario?.id         ?? null,
        pagina:     location.pathname,
        mensaje:    String(mensaje).slice(0, 2000),
        stack:      String(stack ?? '').slice(0, 5000),
        contexto: Object.assign({
          url:        location.href,
          user_agent: navigator.userAgent,
        }, extra),
      });

      fetch(SUPABASE_URL + '/rest/v1/errores_frontend', {
        method:  'POST',
        headers: {
          'Content-Type':  'application/json',
          'apikey':        SUPABASE_ANON,
          'Authorization': 'Bearer ' + token,
          'Prefer':        'return=minimal',
        },
        body,
        // keepalive: permite que el request sobreviva si la página se descarga
        keepalive: true,
      }).catch(function () {});   // silencioso
    } catch {}
  }

  // ── API pública ───────────────────────────────────────────────────────
  window.logError = function (msg, error) {
    console.error('[El Rey]', msg, error);
    enviar(msg, error?.stack, { tipo: 'manual' });
  };

  // ── Captura global ────────────────────────────────────────────────────
  window.addEventListener('error', function (e) {
    enviar(
      e.message,
      e.error?.stack,
      { tipo: 'uncaught', archivo: e.filename, linea: e.lineno, col: e.colno }
    );
  });

  window.addEventListener('unhandledrejection', function (e) {
    const msg = e.reason?.message ?? String(e.reason ?? 'Unhandled rejection');
    enviar(msg, e.reason?.stack, { tipo: 'unhandledrejection' });
  });
})();
