# Plan de Tareas — Distribuidora El Rey

**Auditoría:** 2026-06-10
**Proyecto:** rqbpzmkcwxruzszbtsjv.supabase.co
**Schema:** `public` v14.5 (Postgres 15)
**Stack confirmado:** HTML + Vanilla JS + Supabase JS por CDN + Netlify, con capa PWA encima.

---

## 1. Estado real

### Lo que YA está hecho
- **Base de datos completa y bien diseñada:** 16 tablas, 5 vistas materializables como queries, 5 RPCs (`confirmar_ingreso`, `cerrar_hoja_ruta`, `empresa_actual`, `rol_actual`, `permiso`). Multi-empresa por `empresa_id`.
- **14 mockups HTML funcionales** en `front/` con datos hardcodeados, todos respetando la identidad visual definida.
- **11 specs de módulo** en `docs/specs/` con queries Supabase listas para copiar.
- **CLAUDE.md de back y front** con convenciones claras.

### Lo que falta
- Cablear los 14 mockups a Supabase (reemplazar arrays demo por queries reales).
- Auditar y completar RLS de las 16 tablas.
- Capa PWA + offline (Service Worker + IndexedDB + cola de sync).
- 1 RPC nueva: `confirmar_pedido` (atómica) — ver §3.
- Migrations versionadas (todo el schema vive solo en producción hoy).
- Rotar la `service_role` key compartida en chat.

### Riesgos confirmados
1. **RLS:** la `anon key` lee las 16 tablas sin filtros → RLS apagado o policies demasiado abiertas. Crítico antes de cargar datos reales.
2. **Confirmar pedido no es atómico:** la spec 02 propone 4 inserts separados (`pedidos` + `pedido_items` + `boletas` + `mov_stock`). Si falla en la mitad, queda data inconsistente. Sin RPC es imposible reintentar limpio desde la cola offline.
3. **Sin migrations versionadas:** un cambio mal aplicado en producción no se puede revertir sin esfuerzo manual.
4. **Inconsistencias menores en specs:**
   - Spec 01 lista 12 módulos de permisos, spec 09 lista 14 (`ventas_margenes`, `reportes_stock` adicionales). Resolver antes de pantalla de permisos.
   - Spec 03 usa `mov_cuenta.descripcion` que no figura en el schema OpenAPI → falta columna o falta uso.

---

## 2. Política de stock (decidida)

- Stock **puede quedar negativo**. El backend **NO bloquea** ventas.
- Frontend señaliza: chip rojo `⚠ Stock 0` en buscador de productos del pedido.
- Admin/Depósito ven panel permanente con vista `stock_negativo` para corregir.
- En reporte de ventas: marcar boletas que dejaron stock negativo (auditoría).

---

## 3. Política offline (decidida)

- **PWA encima del stack actual** (sin tocar Vanilla JS).
- **Storage local:** Dexie.js sobre IndexedDB.
- **Service Worker:** Workbox vía CDN.
- **Snapshot:** al loguear con señal se descarga lo necesario (clientes, productos, saldos, stock — solo de la empresa del usuario).
- **Cola de operaciones pendientes:** cada confirmación offline se guarda con id temporal y flag `pendiente_sync`.
- **Sincronización:**
  - `sync_pull(last_sync_at, empresa_id)` → devuelve solo deltas (cambios desde la última sync).
  - `sync_push(operations[])` → recibe el batch, lo aplica en transacción, devuelve ids reales y rechazos.
- **Requisito DB:** agregar `updated_at` (con trigger) en las 16 tablas para deltas.

---

## 4. Tareas en orden eficiente

### Fase 0 — Hardening urgente (hoy)

**T-01. Rotar service_role key.**
Panel Supabase → Settings → API → Reset. La que compartiste ya está quemada.

**T-02. `supabase init` + `db pull`.**
- `cd "G:\Claude proyecto distri el rey"`
- `supabase init`
- `supabase link --project-ref rqbpzmkcwxruzszbtsjv`
- `supabase db pull` → genera la migration inicial con todo el schema actual.
- Commit en git (si no hay repo, inicializarlo: `git init`).

**T-03. Auditoría completa de RLS.**
- Listar policies actuales.
- Para cada tabla: `enable row level security` + policy `tenant` (`empresa_id = empresa_actual()`).
- Reglas adicionales:
  - `pedidos`: preventistas ven solo los suyos (`usuario_id = (SELECT id FROM usuarios WHERE auth_id = auth.uid())`).
  - `productos.costo`: ocultar a no-admin con view o columna RLS.
- Test: crear 2 empresas + 2 usuarios, verificar aislamiento real.

---

### Fase 1 — Cerrar la capa de datos (días 2-3)

**T-04. Crear RPC `confirmar_pedido(p_pedido jsonb)`.**
Recibe `{ cliente_id, descuento, items[], observaciones }` y en una transacción:
1. Inserta `pedidos`.
2. Inserta `pedido_items`.
3. Lee `saldo_actual` del cliente.
4. Inserta `boletas` con `saldo_anterior` y `total_a_cobrar` calculados.
5. Inserta `mov_stock` (uno por item, tipo `venta`, cantidad negativa).
6. Devuelve `{ pedido_id, boleta_id }`.

**T-05. Agregar `updated_at` + trigger universal.**
- Migration con `ALTER TABLE ... ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now()` para las 16 tablas.
- Función `tg_updated_at()` y trigger `BEFORE UPDATE` por tabla.

**T-06. Crear RPCs de sincronización.**
- `sync_pull(p_last_sync timestamptz)` → devuelve jsonb con `{tabla: [registros]}` filtrado por empresa y permisos.
- `sync_push(p_ops jsonb)` → procesa cada operación (insert/update/rpc) en savepoints, devuelve `{ok: [...], rechazos: [...]}`.

**T-07. Resolver inconsistencias detectadas.**
- Decidir lista canónica de 14 módulos de permisos (alinear specs 01 y 09).
- Agregar columna `mov_cuenta.descripcion` si se usa (o eliminar uso en spec 03).

**T-08. Seed de prueba.**
1 empresa, 3 usuarios (admin/preventista/depósito), 5 zonas, 30 clientes, 80 productos, 1 ingreso confirmado, 10 pedidos en distintos estados, 1 hoja de ruta abierta. Script `supabase/seed.sql`.

---

### Fase 2 — Cablear mockups a Supabase (días 4-9)

Orden por dependencias FK (los maestros primero).

**T-09. `src/supabase.js` + `src/auth.js` + `src/utils.js`.**
Cliente Supabase, helpers de sesión, formato ARS, fechas es-AR. Estructura `elrey-app/` según `CLAUDE-frontend.md`.

**T-10. `login_home.html`.**
Login + redirect según rol. Cache de `usuario` y `permisos` en `sessionStorage`.

**T-11. `permisos.html`.**
ABM de usuarios + permisos granulares por módulo. Requiere T-07.

**T-12. `clientes.html`.**
Listado con saldo (vista `saldo_actual`), alta, edición, historial `mov_cuenta`, cobro manual.

**T-13. `stock.html`.**
Vista `stock_actual` + filtros + ajustes manuales + alertas (`stock_negativo`, `dias_sin_ingreso`).

**T-14. `catalogo.html`.**
Subida de fotos a Storage `productos`, generación de PDF imprimible con config en `localStorage`.

**T-15. `ingreso_boleta.html`.**
Alta de ingreso, cargos jsonb, checksum, llamada a `confirmar_ingreso`.

**T-16. `pedido_preventista.html`.**
Buscador de productos, venta por unidad/bulto, llamada a `confirmar_pedido` (T-04).

**T-17. `boleta.html`.**
Vista e impresión de boleta. Mostrar saldo anterior si > 0.

**T-18. `hoja_ruta.html`.**
- Modo admin: generar hoja con pedidos del día (vista `hoja_ruta_hoy`), QR.
- Modo entrega: cargar por `?token=`, marcar entregado / no entregado, cobros divididos, llamar `cerrar_hoja_ruta`.

**T-19. `no_entregados.html`.**
Listado de pedidos no entregados, acciones postergar / anular con devolución de stock seleccionable.

**T-20. Reportes (`reporte_ventas`, `reporte_stock`, `reporte_deudores`, `reporte_recaudacion`).**
Queries de spec 08. Ocultar costos para preventista y depósito.

---

### Fase 3 — Capa PWA + offline (días 10-13)

**T-21. PWA básica.**
- `manifest.webmanifest` con íconos (192, 512), `display: standalone`, `theme_color: #1C2B27`.
- `service-worker.js` con Workbox vía CDN: precache de shell HTML/CSS/JS, runtime cache para imágenes de productos.
- Banner "Agregar a inicio" para iOS (Apple no auto-prompt).

**T-22. Capa offline con Dexie.**
- DB local con tablas espejo: `clientes`, `productos`, `saldos`, `stock`, `pedidos_pendientes`, `cobros_pendientes`, `ajustes_pendientes`, `meta` (last_sync).
- Wrapper `db.query(tabla)` que devuelve local si offline, online si hay señal.

**T-23. Cola de sincronización.**
- Hook al `online`/`offline` del navegador.
- Al recuperar señal: procesar cola en orden, llamar `sync_push`, manejar rechazos (mostrarlos en bandeja "Pendientes con error").
- Background Sync API donde se soporte; fallback: sync al abrir la app.

**T-24. Snapshot inicial post-login.**
- Llamar `sync_pull(null)` la primera vez, guardar `last_sync`.
- En cada login posterior: `sync_pull(last_sync)` para deltas.
- Indicador en UI: 🟢 online / 🟡 sincronizando / 🔴 offline + badge "N pendientes".

**T-25. Adaptar las pantallas críticas al modo offline.**
- `pedido_preventista`: 100% offline (confirma local, cola).
- `hoja_ruta` (cierre): 100% offline.
- `clientes` (ver saldo): solo lectura local.
- `stock` y reportes: requieren señal (mostrar mensaje si offline).

---

### Fase 4 — Calidad y despliegue (días 14-16)

**T-26. Testing manual guiado.**
- Checklist por módulo (entrada esperada, salida esperada).
- Test específico: cargar 5 pedidos en avión → aterrizar → verificar que sync no duplica ni pierde.

**T-27. Observabilidad.**
- Logs de errores con `console.error` interceptado y enviado a tabla `errores_frontend` (insert anónimo permitido por RLS específico).
- Panel admin para ver últimos errores.

**T-28. Despliegue Netlify.**
- Sitio estático apuntando al directorio `elrey-app/`.
- Variables de entorno (URL + anon key) inyectadas en build.
- Dominio + SSL automático.
- HTTPS obligatorio para que el Service Worker funcione.

**T-29. Documentación final.**
- README con setup local.
- Manual por rol (admin / preventista / depósito).
- Runbook: cómo hacer backup, alta de usuario, restaurar, ver logs.

---

## 5. Resumen y plazos

| Fase | Tareas | Días estimados |
|---|---|---|
| 0 — Hardening | T-01 → T-03 | 1 |
| 1 — Datos | T-04 → T-08 | 2 |
| 2 — Cablear mockups | T-09 → T-20 | 6 |
| 3 — PWA + offline | T-21 → T-25 | 4 |
| 4 — QA y deploy | T-26 → T-29 | 3 |
| **Total** | | **~16 días** de dev senior full-time |

---

## 6. Próximo paso accionable

Yo puedo arrancar ahora con **T-02 (`supabase init` + `db pull`)** que es no-destructivo y deja el schema versionado. Necesito que vos en paralelo hagas **T-01 (rotar la service_role key)** desde el panel de Supabase.

Una vez hecho eso, sigo con T-03 (auditar RLS) y T-04 (crear `confirmar_pedido`). ¿Avanzo?
