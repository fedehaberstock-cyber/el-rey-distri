# CLAUDE.md — Frontend · Distribuidora El Rey

## Stack
- HTML + Vanilla JS (sin framework, módulos ES vía CDN)
- Supabase JS v2 via ESM (`https://esm.sh/@supabase/supabase-js@2`)
- CSS custom properties por archivo (paleta común en `:root`)
- Service Worker (`service-worker.js`) con cache versionado — bumpear `CACHE_SHELL/CACHE_CDN` en cada release UI relevante
- Dexie como cache local de `clientes/productos/saldo_actual` para fallback offline (en `src/db.js`)
- Sin bundler — archivos estáticos servidos desde Cloudflare Pages

## Credenciales
En `src/supabase.js` (publishable key, no service role):
```js
export const SUPABASE_URL  = 'https://rqbpzmkcwxruzszbtsjv.supabase.co'
export const SUPABASE_ANON = 'sb_publishable_...'
```
**Nunca hardcodear en otros archivos. Nunca commitear la service role.**

URL de producción: `https://el-rey-distri.pages.dev` (Cloudflare Pages, deploy automático desde main).

## Estructura
```
front/
├── src/
│   ├── supabase.js        # cliente único, storageKey='elrey.auth'
│   ├── auth.js            # requireSession(), tienePermiso(modulo, nivel)
│   ├── utils.js           # ars(), formatos, mostrarError
│   ├── db.js              # Dexie (cache offline)
│   └── logger.js
├── login_home.html        # entrada — login o tiles según rol/permisos
├── service-worker.js      # cache v17 (al subir, bumpear)
├── offline.html
└── *.html                 # ver tabla de pantallas abajo
```

## Pantallas activas
| Pantalla | Rol/permiso | Notas |
|---|---|---|
| `login_home.html` | todos | render condicional según rol + permisos por módulo |
| `pedido_preventista.html` | pedidos:crear | búsqueda tolerante, stock validation, fecha_reparto |
| `pedidos_dia.html` | pedidos:vista | pedidos del día, filtra por usuario si no es admin |
| `hoja_ruta.html` | hoja_ruta:vista | acepta `?hoja_id=`; auto-resuelve la próxima pendiente o adopta huérfanos |
| `historial_hojas.html` | ventas_totales:vista | hojas pasadas + cerrar viejas con/sin cobros |
| `boleta.html` / `boletas_lote.html` | boletas:vista | impresión A5, edit/delete admin |
| `editar_boleta.html` | boletas:editar | RPC `editar_boleta` (ventana 14h para preventista) |
| `clientes.html` | clientes:vista | búsqueda + saldo + movs + boletas + zona/posición + cobro/cargo |
| `stock.html` | stock:vista | listado, ingreso, ajuste, editar producto |
| `ingreso_boleta.html` | stock:crear | IA (Haiku) + memoria alias + revisión de precios |
| `catalogo.html` | catalogo:vista | foto del producto: drag/paste + auto-trim + bulk flow |
| `productos.html` | catalogo:vista | catálogo simple (lista + alta/edit) |
| `proveedores.html` | proveedores:editar | CRUD |
| `zonas.html` | zonas:editar (o clientes:editar) | CRUD + reorden ▲▼ |
| `ordenar_ruta.html` | zonas:editar | DnD + asignación de "sin zona" |
| `markups.html` | catalogo:editar | global / categoría / producto |
| `reporte_ventas.html` | ventas_totales | dashboards |
| `reporte_deudores.html` | deudores | top deudores |
| `reporte_recaudacion.html` | recaudacion | recaudación por usuario/forma |
| `reporte_stock.html` | reportes_stock | críticos + precios desactualizados |
| `no_entregados.html` | hoja_ruta | gestionar no-entregas |
| `permisos.html` | usuarios_permisos:admin | matriz módulo × nivel por usuario |

## Identidad visual
```css
--paper:#FBF9F2  --ink:#1C2B27    --gold:#A9760E   --gold-dk:#8A5F09
--line:#E4DECF   --line-soft:#EEEADD  --ink-soft:#5B665F
--green-bg/#tx   --amber-bg/#tx   --red-bg/#tx     --card:#FFFFFF
```
- Border-radius: 12-14px en cards, 10-12px en buttons, 999px en chips.
- Font: system-ui.
- `max-width:480px;margin:0 auto` en mobile-first; algunas páginas usan 520-560px.

## Auth y roles
- `requireSession()` al inicio de cada página (de `auth.js`). Si no hay sesión → redirige a `login_home.html`.
- `tienePermiso(modulo, nivelRequerido='vista')` — admin pasa todo; resto consulta tabla `permisos`.
- Roles: `admin` | `preventista` | `deposito`.
- Niveles: `ninguno` < `vista` < `crear` < `editar` < `admin`.
- Módulos: `pedidos, clientes, hoja_ruta, stock, ingresos, boletas, ventas_totales, ventas_costos, ventas_margenes, deudores, recaudacion, reportes_stock, catalogo, proveedores, zonas, usuarios_permisos`.

## Patrones de datos
- **Stock**: leer siempre de `stock_actual` (vista, suma de `mov_stock`). Nunca de `productos.stock`.
- **Saldo cliente**: leer de `saldo_actual` (vista, suma de `mov_cuenta`).
- **Fechas**: usar Argentina/Cordoba con
  ```js
  new Intl.DateTimeFormat('en-CA',{timeZone:'America/Argentina/Cordoba'}).format(new Date())
  ```
- **Validación de stock en venta** (pedido_preventista y editar_boleta):
  - Si `producto.stock != null`, capear cantidad por `stock - cantEnOrden(id)`.
  - En editar, considerar `cantidad_original_de_esa_línea` como crédito.

## IA — extracción de boletas (ingreso)
- **Edge Function**: `supabase/functions/extraer-ingreso/index.ts` — Claude Haiku 4.5 con visión.
- **Frontend**: `ingreso_boleta.html`
  1. Sube fotos a bucket `ingresos_fotos` (privado).
  2. Pasa signed URLs al function; el function baja y manda a Anthropic como base64.
  3. Recibe `{ items: [{ texto_original, cantidad, costo_unit, costo_total_linea }] }`.
  4. Hace match contra `alias_productos` (normalizado: lowercase + sin acentos + colapso de espacios).
  5. Sin match → fila ámbar editable; al "Aceptar y recordar" guarda alias con `factor_conversion` (relación cantidad_proveedor ↔ cantidad_interna).
- Cuando agregues nuevos buscadores, usá `normAlias()` para comparar.

## Revisión de precios (post-ingreso)
- Antes del confirmar final, si algún `producto.costo` cambia, se abre overlay con 3 niveles:
  - 🔴 Bloqueado (margen < `markup_minimo_pct`)
  - 🟡 Atención (margen 20-25%)
  - 🟢 Sugerencia
- Precio sugerido = `costo × (1 + markup)` redondeado al próximo 50/90/00 hacia arriba.
- Markup cascade: `productos.markup_objetivo_pct` → `categorias_markup.markup_pct` → `empresas.markup_default_pct`.
- Tras confirmar, se actualizan los precios aceptados (`UPDATE productos SET precio = ...`) y luego se llama al RPC `confirmar_ingreso`.

## Catálogo — foto del producto
- Bucket `productos` (public). Path `{producto_id}/{timestamp}.{ext}`.
- Carga: click, **drag & drop**, o **paste (Ctrl+V)** de imagen del clipboard. URL drag desde sitio externo: intenta fetch con CORS, fallback "copiá la imagen y pegala acá".
- Auto-procesado opcional (toggle persistente en localStorage `elrey.autoProcesar`):
  - Detecta color de fondo promediando las 4 esquinas.
  - Recorta bbox de pixeles no-fondo (tolerancia 35 por canal).
  - Centra en canvas 600x600 blanco con 5% padding.
  - Exporta JPG 92%.
- Bulk flow: botones "💾 Guardar y siguiente sin foto" / "Saltar sin guardar" con contador "X de Y sin foto".

## Convenciones
- Moneda: `ars(n)` de `utils.js` (`Intl.NumberFormat('es-AR',{style:'currency',currency:'ARS',maximumFractionDigits:0})`).
- Errores: `mostrarError(msg)` o `alert()` — nunca silenciar (excepción: error genérico de red en flujos con fallback offline).
- Exposición a `window.*` para handlers `onclick=` inline (módulos ES no son globales).
- **No usar `oninput` para inputs cuyo setter rerenderice el contenedor del input** — cierra el teclado en móvil. Pattern correcto: `oninput="setter()"` solo actualiza un sub-contenedor (`#x-results`), o `onchange` (commit al perder foco).

## Service Worker
- Bumpear `CACHE_SHELL` y `CACHE_CDN` (mismo número) en cada release que tenga cambios visibles para el usuario, así forzamos invalidación.
- Versión actual: ver constante en [service-worker.js](service-worker.js).
