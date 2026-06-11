# CLAUDE.md — Backend · Distribuidora El Rey

## Stack
- Supabase (Postgres 15 + Auth + Storage + RLS)
- Sin servidor propio — toda la lógica de negocio en funciones SQL (plpgsql)
- Migrations versionadas en `/migrations/`

## Credenciales
Nunca hardcodear. Usar variables de entorno o el dashboard de Supabase.
- `SUPABASE_URL` / `SUPABASE_ANON_KEY` → frontend
- `SUPABASE_SERVICE_ROLE_KEY` → solo scripts de migración o admin, nunca en el browser

## Esquema — estado actual
| Versión | Archivo | Estado |
|---|---|---|
| v2 | `esquema_distribuidora_v2.sql` | ✅ aplicado en prod |
| v3 | `esquema_distribuidora_v3.sql` | ✅ aplicado en prod |
| datos | `datos_iniciales.sql` | ✅ aplicado en prod |

## Tablas principales
```
empresas → usuarios → permisos
                   → pedidos → pedido_items
                             → boletas
                   → clientes (zona_id → zonas)
                   → productos (proveedor_id → proveedores)
                   → hojas_ruta ← pedidos.hoja_ruta_id
                   → ingresos → ingreso_items
                   → mov_stock
                   → mov_cuenta
```

## Vistas (leer siempre desde acá, nunca calcular en el front)
- `stock_actual` — stock por producto
- `saldo_actual` — saldo por cliente
- `stock_negativo` — productos con stock < 0
- `hoja_ruta_hoy` — pedidos del día ordenados por zona y posición
- `recaudacion_por_usuario` — cobros por preventista, día y forma de pago
- `dias_sin_ingreso` — días desde el último ingreso por producto

## Funciones SQL (llamar via `supabase.rpc()`)
| Función | Cuándo llamarla |
|---|---|
| `confirmar_ingreso(ingreso_id)` | Al confirmar una boleta de proveedor |
| `cerrar_hoja_ruta(hoja_id)` | Al cerrar el reparto del día |
| `empresa_actual()` | Interna — usada por RLS |
| `rol_actual()` | Interna — usada por RLS |
| `permiso(modulo)` | Para verificar acceso desde el front |

## RLS — reglas clave
- Toda tabla tiene `empresa_id` y política `tenant` — aislamiento multi-empresa automático
- `pedidos`: preventistas solo ven sus propios pedidos; admin y depósito ven todos
- Costos (`productos.costo`) visibles solo para admin — ocultar en queries del front para otros roles

## Storage
- Bucket: `productos` (public)
- Path: `{empresa_id}/{producto_id}.jpg`
- Leer: URL pública directa desde `productos.foto_url`
- Escribir: desde el front con `supabase.storage.from('productos').upload()`

## Convenciones SQL
- UUIDs con `gen_random_uuid()` por defecto
- Timestamps con timezone (`timestamptz`)
- Montos: `numeric(12,2)` — nunca `float`
- Stock y saldos: siempre por suma de movimientos, nunca valor fijo
- Nuevas migraciones: crear archivo `vN.sql` en `/migrations/`, nunca editar los anteriores

## Casos de uso críticos y cómo se resuelven
| Caso | Solución |
|---|---|
| Stock negativo por venta offline simultánea | Permitido, Seba ajusta manualmente |
| Saldo anterior en boleta | Se guarda en `boletas.saldo_anterior` al confirmar el pedido (inmutable) |
| Imputación de cobro | `cerrar_hoja_ruta` imputa primero contra saldo anterior, después contra pedido |
| Doble cobro | Imposible: `cerrar_hoja_ruta` es la única función que genera `mov_cuenta` de tipo pago con `referencia_tipo = 'hoja_ruta'` |
| Precio desactualizado | Vista `dias_sin_ingreso` expone días desde el último ingreso por producto |
| Pedido no entregado | Estado `no_entregado` → admin decide postergar (nuevo `hoja_ruta_id`) o anular (devolucion en `mov_stock`) |
