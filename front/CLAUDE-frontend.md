# CLAUDE.md — Frontend · Distribuidora El Rey

## Stack
- HTML + Vanilla JS (sin framework)
- Supabase JS v2 via ESM (`https://esm.sh/@supabase/supabase-js@2`)
- CSS custom properties (ver variables en `:root`)
- Sin bundler — archivos estáticos servidos desde Netlify

## Credenciales
Las credenciales de Supabase van en `src/supabase.js`:
```js
export const SUPABASE_URL  = 'https://xxxx.supabase.co'
export const SUPABASE_ANON = 'eyJ...'
```
**Nunca hardcodear en otros archivos. Nunca commitear credenciales reales.**

## Estructura de archivos
```
elrey-app/
├── src/
│   ├── supabase.js          # cliente supabase, exporta { supabase }
│   ├── auth.js              # login, logout, sesión activa
│   └── utils.js             # ars(), formatFecha(), etc.
├── pages/
│   ├── login.html
│   ├── home.html            # redirige según rol
│   ├── pedidos.html
│   ├── clientes.html
│   ├── stock.html
│   ├── ingreso_boleta.html
│   ├── boleta.html
│   ├── hoja_ruta.html
│   ├── no_entregados.html
│   ├── reportes_ventas.html
│   ├── reportes_stock.html
│   ├── deudores.html
│   ├── recaudacion.html
│   ├── permisos.html
│   └── catalogo.html
└── CLAUDE.md
```

## Identidad visual (nunca cambiar)
```css
--paper:#FBF9F2  --ink:#1C2B27    --gold:#A9760E
--line:#E4DECF   --ink-soft:#5B665F
--green-bg/#tx   --amber-bg/#tx   --red-bg/#tx
```
Border-radius: 12-14px en cards, 999px en chips. Font: system-ui.

## Auth y roles
- Login via `supabase.auth.signInWithPassword()`
- Al iniciar cada página verificar sesión: si no hay → redirigir a `login.html`
- Rol y permisos se leen de la tabla `usuarios` y `permisos` al cargar
- Roles: `admin` | `preventista` | `deposito`
- Ocultar/mostrar secciones según `nivel_permiso`: ninguno | vista | crear | editar | admin

## Patrones de datos
- Stock: siempre leer de la vista `stock_actual` (nunca de `productos.stock`)
- Saldo cliente: siempre leer de la vista `saldo_actual`
- Nunca calcular stock o saldo en el front — leer de las vistas

## Convenciones
- Fechas: `toLocaleDateString('es-AR')`
- Moneda: `Intl.NumberFormat('es-AR', { style:'currency', currency:'ARS', maximumFractionDigits:0 })`
- Errores de Supabase: siempre mostrar al usuario, nunca silenciar
- Imágenes de productos: subir a Supabase Storage bucket `productos`, guardar URL en `productos.foto_url`

## Pantallas ya prototipadas
Todos los archivos HTML del proyecto son prototipos funcionales con datos hardcodeados.
La tarea es reemplazar los arrays de demo por queries a Supabase manteniendo exactamente el mismo diseño y comportamiento.
