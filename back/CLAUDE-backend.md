# CLAUDE.md — Backend · Distribuidora El Rey

## Stack
- Supabase (Postgres 15 + Auth + Storage + RLS + Edge Functions Deno)
- Sin servidor propio — lógica de negocio en funciones SQL (plpgsql) y una edge function para IA
- Migrations versionadas en `supabase/migrations/`
- Edge functions en `supabase/functions/`

## Credenciales
- `SUPABASE_URL` + publishable key → frontend (en `src/supabase.js`).
- `SUPABASE_SERVICE_ROLE_KEY` → solo scripts de admin, nunca al browser.
- `ANTHROPIC_API_KEY` → secret de Supabase, usado solo por la edge function `extraer-ingreso`. Setear con `supabase secrets set ANTHROPIC_API_KEY=sk-ant-...`.

## Migrations aplicadas
| Archivo | Contenido |
|---|---|
| `00000000000000_schema_inicial.sql` | esquema base (empresas, usuarios, permisos, clientes, zonas, productos, proveedores, pedidos, boletas, hojas_ruta, ingresos, mov_stock, mov_cuenta) + RPCs principales + RLS |
| `20260611_01_confirmar_pedido.sql` | RPC `confirmar_pedido` con boleta + saldo_anterior |
| `20260611_02_updated_at.sql` | triggers de timestamps |
| `20260611_03_sync_rpcs.sql` | helpers sync offline |
| `20260611_05_errores_frontend.sql` | fixes varios |
| `20260611_06_fix_saldo_ant_null.sql` | fix saldo NULL |
| `20260611_07_fecha_reparto.sql` | `pedidos.fecha_reparto` + vista `hoja_ruta_hoy` con tz Argentina |
| `20260611_08_editar_boleta.sql` | RPC `editar_boleta` con ventana 14h para preventista |
| `20260611_09_hoja_ruta_fix.sql` | vista filtra confirmados + cerrar_hoja_ruta rollover de no-entregados |
| `20260611_10_cargo_cuenta.sql` | `cerrar_hoja_ruta` inserta cargo por boleta entregada + backfill |
| `20260611_11_split_configuracion.sql` | módulo 'configuracion' → 'catalogo' + 'proveedores' |
| `20260611_12_hoja_autogen.sql` | `confirmar_pedido` auto-crea/encuentra hoja por fecha_reparto |
| `20260611_13_eliminar_boleta.sql` | RPC `eliminar_boleta` (admin only) |
| `20260611_14_storage_productos.sql` | bucket `productos` + `productos.foto_url` |
| `20260613_01_alias_productos.sql` | tabla `alias_productos` + bucket `ingresos_fotos` |
| `20260613_02_alias_productos_uq.sql` | unique constraint plain (reemplaza índice funcional roto) |
| `20260613_03_markup_objetivo.sql` | `empresas.markup_default/minimo_pct` + `productos.markup_objetivo_pct` + tabla `categorias_markup` + `redondear_precio_50_90()` + seed según análisis de catálogo |
| `20260613_04_alias_normalize.sql` | re-normaliza `alias_productos.alias_text` + dedupe |

`20260611_04_seed_admin_inicial.sql` está en .gitignore (password admin).

## Tablas principales
```
empresas (markup_default_pct, markup_minimo_pct)
 ├─ usuarios → permisos(modulo, nivel)
 ├─ clientes (zona_id → zonas, posicion_zona)
 ├─ productos (proveedor_id → proveedores, categoria, costo, precio,
 │             markup_objetivo_pct, foto_url)
 ├─ proveedores (cargos_default)
 ├─ zonas (orden)
 ├─ categorias_markup (categoria text, markup_pct)
 ├─ pedidos (fecha_reparto, hoja_ruta_id, estado)
 │   └─ pedido_items (es_bulto, u_por_bulto, descuento)
 │   └─ boletas (saldo_anterior, total, total_a_cobrar)
 ├─ hojas_ruta (fecha, estado, qr_token)
 ├─ ingresos → ingreso_items
 ├─ alias_productos (proveedor_id, alias_text, producto_id, factor_conversion)
 ├─ mov_stock (tipo: ingreso/venta/ajuste, cantidad, referencia)
 └─ mov_cuenta (tipo: cargo/pago, monto, forma_pago, referencia)
```

## Vistas (leer siempre desde acá, nunca calcular en el front)
- `stock_actual` — stock por producto (suma de `mov_stock`).
- `saldo_actual` — saldo por cliente (suma de `mov_cuenta`).
- `stock_negativo` — productos con stock < 0.
- `hoja_ruta_hoy` — pedidos del día ordenados por zona/posición (timezone Argentina).
- `recaudacion_por_usuario` — cobros por preventista/día/forma.
- `dias_sin_ingreso` — días desde último ingreso por producto.

## RPCs (llamar via `supabase.rpc()`)
| Función | Cuándo |
|---|---|
| `confirmar_pedido(payload)` | Al confirmar un pedido (crea boleta + auto-crea/encuentra hoja_ruta por fecha_reparto) |
| `confirmar_ingreso(ingreso_id)` | Al confirmar ingreso de proveedor (genera mov_stock + actualiza `productos.costo` con costo_unit_final) |
| `cerrar_hoja_ruta(hoja_id)` | Cerrar reparto (inserta cargo por boleta entregada + pago por cobros + rollover de no_entregados) |
| `editar_boleta(payload)` | Editar items/precios/descuento de un pedido confirmado (admin sin restricción, preventista solo dentro de 14h) |
| `eliminar_boleta(boleta_id)` | Anular boleta (admin only) |
| `redondear_precio_50_90(p)` | Helper: lleva al próximo precio terminado en 00/50/90 ↑ |
| `normalizar_alias(s)` | Helper SQL paralelo a la `normAlias()` del front |
| `empresa_actual()` / `rol_actual()` | Interno (RLS) |

## RLS — reglas clave
- Toda tabla con `empresa_id` tiene política `tenant` con `empresa_id = empresa_actual()`.
- `pedidos`: preventistas ven solo los suyos; admin y depósito ven todos.
- `alias_productos`, `categorias_markup`: tenant simple.
- `productos.costo` visible solo para admin/deposito desde queries del front (no es RLS, es responsabilidad del front pedir solo las columnas correspondientes según el rol).

## Storage
- `productos` (public): `{producto_id}/{ts}.{ext}` — foto del catálogo.
- `ingresos_fotos` (private, auth): fotos de boletas para la IA. Solo el usuario autenticado las accede vía signed URL.

## Edge Functions
### `extraer-ingreso` (`supabase/functions/extraer-ingreso/index.ts`)
- Recibe `{ imagenes: ["https://...signed-url" | "data:image/...base64"] }` (máx 8).
- Baja cada URL HTTP y convierte a base64 (más confiable que pasar URLs a Anthropic).
- Llama a Claude Haiku 4.5 (`claude-haiku-4-5-20251001`) con visión, `temperature: 0` (determinístico).
- Devuelve `{ items: [{ texto_original, cantidad, costo_unit, costo_total_linea }], usage }`.
- CORS habilitado (incluye `x-client-info, apikey` en allowed headers).
- Deploy: `supabase functions deploy extraer-ingreso --no-verify-jwt`.

## Convenciones SQL
- UUIDs con `gen_random_uuid()`.
- Timestamps con timezone (`timestamptz`).
- Montos: `numeric(12,2)` — nunca `float`.
- Stock/saldos: suma de movimientos, nunca valor fijo.
- Nuevas migrations: `YYYYMMDD_NN_nombre.sql`, nunca editar previas.

## Casos críticos y solución
| Caso | Solución |
|---|---|
| Stock negativo por ventas offline | Permitido (ajuste manual) |
| Saldo anterior en boleta | `boletas.saldo_anterior` guardado al confirmar pedido (inmutable) |
| Imputación de cobro | `cerrar_hoja_ruta` imputa primero contra saldo anterior, luego contra pedido |
| Doble cobro | Solo `cerrar_hoja_ruta` genera mov_cuenta con `referencia_tipo='hoja_ruta'` |
| Pedido no entregado | Estado `no_entregado` + `cerrar_hoja_ruta` lo rollover (nueva hoja o queda huérfano) |
| Costo de producto post-ingreso | RPC pisa `productos.costo` con `costo_unit_final` (incluye cargos) |
| Precio post-ingreso | El RPC NO toca el precio; el front muestra pantalla de revisión y aplica updates manuales tras aceptar |
| Margen mínimo | `empresas.markup_minimo_pct` (default 20%); pantalla de revisión bloquea confirmar si algún producto queda debajo |
| Sugerencia de precio | Cascade: producto.markup_objetivo_pct > categorias_markup.markup_pct > empresas.markup_default_pct; redondeado con `redondear_precio_50_90` |
| Memoria de IA boletas | `alias_productos(proveedor_id, alias_text NORMALIZADO, producto_id, factor_conversion)` — `factor` relaciona unidad del proveedor con unidad interna |
