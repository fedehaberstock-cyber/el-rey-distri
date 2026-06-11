// ── El Rey · Sync Manager ─────────────────────────────────────────────────
// Coordina la sincronización entre la DB local (Dexie) y Supabase.
//
// Ciclo de vida:
//   1. initSync(supabase, usuario)  →  llama pullDelta() + registra listeners
//   2. Al volver online             →  llama flushQueue()
//   3. Background Sync (SW)         →  postMessage SW_SYNC_REQUESTED → flushQueue()
//   4. pushOp(op, payload)          →  enqueue() + intenta flush inmediato si online

import { db, applyPull, enqueue, getPendingOps, markDone, markError, countPending, getLastSync } from './db.js';

// ── Estado interno ────────────────────────────────────────────────────────
const state = {
  online:   navigator.onLine,
  syncing:  false,
  pending:  0,
  lastSync: null,
  error:    null,
};

const listeners = new Set();

function notify() {
  listeners.forEach(cb => {
    try { cb({ ...state }); } catch {}
  });
}

// ── API pública ───────────────────────────────────────────────────────────

let _supabase = null;

/**
 * Inicializar el sync manager. Llamar una vez al cargar la app.
 * @param {object} supabase  - instancia de supabase-js
 */
export async function initSync(supabase) {
  _supabase = supabase;

  // escuchar eventos de conectividad
  window.addEventListener('online',  handleOnline);
  window.addEventListener('offline', handleOffline);

  // escuchar mensajes del Service Worker
  navigator.serviceWorker?.addEventListener('message', e => {
    if (e.data?.type === 'SW_SYNC_REQUESTED') flushQueue();
  });

  // actualizar pending count inicial
  state.pending  = await countPending();
  state.lastSync = await getLastSync();
  notify();

  // pull inicial si hay conexión
  if (navigator.onLine) {
    await pullDelta();
    await flushQueue();
  }
}

/** Suscribirse a cambios de estado */
export function subscribe(cb) {
  listeners.add(cb);
  cb({ ...state }); // emitir estado actual inmediatamente
  return () => listeners.delete(cb);
}

/** Agregar una operación a la cola y disparar flush si hay señal */
export async function pushOp(op, payload) {
  await enqueue(op, payload);
  state.pending = await countPending();
  notify();

  if (navigator.onLine && !state.syncing) {
    await flushQueue();
  } else {
    // registrar Background Sync si disponible
    try {
      const reg = await navigator.serviceWorker?.ready;
      await reg?.sync?.register('elrey-sync-queue');
    } catch {}
  }
}

/** Descargar deltas del servidor y aplicarlos a IndexedDB */
export async function pullDelta() {
  if (!_supabase || state.syncing) return;
  state.syncing = true; state.error = null; notify();

  try {
    const lastSync = await getLastSync();
    const { data, error } = await _supabase.rpc('sync_pull', {
      p_last_sync: lastSync,
    });

    if (error) throw error;
    await applyPull(data);
    state.lastSync = data.server_time ?? new Date().toISOString();
  } catch (err) {
    state.error = err.message ?? 'Error al sincronizar';
    console.warn('[sync] pullDelta falló:', err);
  } finally {
    state.syncing = false;
    state.pending = await countPending();
    notify();
  }
}

/** Enviar operaciones pendientes al servidor */
export async function flushQueue() {
  if (!_supabase || state.syncing) return;
  const ops = await getPendingOps();
  if (!ops.length) return;

  state.syncing = true; notify();

  try {
    // construir batch con idx = seq del registro
    const batch = ops.map((op, i) => ({
      idx:     op.seq,
      op:      op.op,
      payload: op.payload,
    }));

    const { data, error } = await _supabase.rpc('sync_push', { p_ops: batch });
    if (error) throw error;

    const okSeqs = (data?.ok ?? []).map(r => r.idx);
    if (okSeqs.length) await markDone(okSeqs);

    for (const rechazo of (data?.rechazos ?? [])) {
      await markError(rechazo.idx, rechazo.error);
      console.warn('[sync] rechazo:', rechazo);
    }

    // pull para reflejar cambios que el server aplicó
    if (okSeqs.length) await pullDelta();

  } catch (err) {
    state.error = err.message ?? 'Error al enviar operaciones';
    console.warn('[sync] flushQueue falló:', err);
    // marcar todos como error para reintentar
    for (const op of ops) await markError(op.seq, state.error);
  } finally {
    state.syncing  = false;
    state.pending  = await countPending();
    notify();
  }
}

// ── Handlers de conectividad ──────────────────────────────────────────────

async function handleOnline() {
  state.online = true; notify();
  await flushQueue();
  await pullDelta();
}

function handleOffline() {
  state.online = false; notify();
}

// ── Badge de estado para la UI ────────────────────────────────────────────

/**
 * Monta un indicador de conectividad en el elemento dado.
 * Lo actualiza automáticamente con cada cambio de estado.
 *
 * @param {HTMLElement} container
 * @returns {Function} unsubscribe
 */
export function mountStatusBadge(container) {
  function render(s) {
    let icon, text, color;
    if (s.syncing) {
      icon = '🔄'; text = 'Sincronizando…'; color = '#8A5F09';
    } else if (!s.online) {
      const p = s.pending;
      icon = '🔴'; color = '#A8392B';
      text = p > 0 ? `Sin señal · ${p} pendiente${p > 1 ? 's' : ''}` : 'Sin señal';
    } else if (s.pending > 0) {
      icon = '🟡'; text = `${s.pending} pendiente${s.pending > 1 ? 's' : ''}`;
      color = '#8A5F09';
    } else {
      icon = '🟢'; text = 'Sincronizado'; color = '#2C6B3F';
    }

    container.innerHTML = `
      <span style="font-size:11px;font-weight:600;color:${color};
        display:flex;align-items:center;gap:4px;cursor:default"
        title="${s.lastSync ? 'Última sync: ' + new Date(s.lastSync).toLocaleTimeString('es-AR') : 'Sin sync aún'}">
        ${icon} ${text}
      </span>`;
  }

  return subscribe(render);
}
