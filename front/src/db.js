// ── El Rey · Local Database (Dexie / IndexedDB) ───────────────────────────
// Espejo local de los datos necesarios para operar offline.
// sync_pull popula estas tablas; sync_push drena op_queue.

import Dexie from 'https://unpkg.com/dexie@3/dist/dexie.mjs';

export const db = new Dexie('ElRey');

db.version(1).stores({
  // ── Metadata ──────────────────────────────────────────────────────────
  meta: '&key',
  // key examples: 'last_sync', 'empresa_id', 'usuario_id'

  // ── Master data (from sync_pull) ──────────────────────────────────────
  clientes:     '&id, nombre, activo, updated_at',
  productos:    '&id, nombre, activo, categoria, updated_at',
  saldo_actual: '&cliente_id',
  stock_actual: '&producto_id',
  zonas:        '&id, nombre',
  proveedores:  '&id, nombre',

  // ── Cola de operaciones pendientes ────────────────────────────────────
  // Cada entrada es una operación que no se pudo enviar al servidor
  // { seq, op, payload, status, intentos, error, created_at }
  op_queue: '++seq, status, created_at',
});

// ── HELPERS ───────────────────────────────────────────────────────────────

/** Upsert masivo: borra todo y recarga con los rows del server */
export async function bulkUpsert(tabla, rows) {
  if (!rows?.length) return;
  await db[tabla].bulkPut(rows);
}

/** Poblar las tablas con el resultado de sync_pull */
export async function applyPull(data) {
  const tablas = [
    'clientes', 'productos', 'saldo_actual', 'stock_actual',
    'zonas', 'proveedores',
  ];

  // saldo_actual / stock_actual: el server devuelve snapshot completo →
  // borramos y recargamos para evitar filas huérfanas
  if (data.saldo_actual?.length) {
    await db.saldo_actual.clear();
    await db.saldo_actual.bulkPut(data.saldo_actual);
  }
  if (data.stock_actual?.length) {
    await db.stock_actual.clear();
    await db.stock_actual.bulkPut(data.stock_actual);
  }

  for (const tabla of ['clientes', 'productos', 'zonas', 'proveedores']) {
    if (data[tabla]?.length) {
      await db[tabla].bulkPut(data[tabla]);
    }
  }

  // guardar server_time como last_sync
  if (data.server_time) {
    await db.meta.put({ key: 'last_sync', value: data.server_time });
  }
}

/** Agregar una operación a la cola pendiente */
export async function enqueue(op, payload) {
  await db.op_queue.add({
    op,
    payload,
    status: 'pending',   // pending | syncing | done | error
    intentos: 0,
    error: null,
    created_at: new Date().toISOString(),
  });
}

/** Obtener operaciones pendientes ordenadas por seq */
export async function getPendingOps() {
  return db.op_queue
    .where('status').anyOf(['pending', 'error'])
    .sortBy('seq');
}

/** Marcar operaciones como done después de sync exitoso */
export async function markDone(seqs) {
  await db.op_queue.where('seq').anyOf(seqs).modify({ status: 'done' });
}

/** Marcar operaciones con error */
export async function markError(seq, errorMsg) {
  await db.op_queue.update(seq, {
    status: 'error',
    error: errorMsg,
    intentos: (await db.op_queue.get(seq))?.intentos + 1 ?? 1,
  });
}

/** Contar pendientes (para badge en UI) */
export async function countPending() {
  return db.op_queue.where('status').anyOf(['pending', 'error']).count();
}

/** Último timestamp de sync */
export async function getLastSync() {
  const row = await db.meta.get('last_sync');
  return row?.value ?? null;
}
