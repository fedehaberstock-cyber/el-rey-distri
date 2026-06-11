# SPEC: Autenticación y Roles

## Objetivo
Login con email/contraseña. Cada usuario ve solo lo que le corresponde según su rol y permisos.

## Flujo
1. Usuario entra a cualquier página → verificar sesión → si no hay, redirigir a `login.html`
2. Login via `supabase.auth.signInWithPassword({ email, password })`
3. Al autenticar, leer `usuarios` por `auth_id = auth.uid()` → obtener `rol`, `nombre`, `empresa_id`
4. Leer tabla `permisos` para ese usuario → guardar en memoria de sesión
5. Redirigir a `home.html`

## Queries
```js
// leer usuario actual
const { data: usuario } = await supabase
  .from('usuarios')
  .select('*')
  .eq('auth_id', session.user.id)
  .single()

// leer permisos
const { data: permisos } = await supabase
  .from('permisos')
  .select('modulo, nivel')
  .eq('usuario_id', usuario.id)
```

## Reglas de acceso por módulo
| Módulo | Admin | Preventista | Depósito |
|---|---|---|---|
| pedidos | admin | crear | vista |
| clientes | admin | crear | vista |
| hoja_ruta | admin | vista | editar |
| stock | admin | vista | editar |
| ingresos | admin | ninguno | crear |
| boletas | admin | ninguno | editar |
| ventas_totales | admin | vista | vista |
| ventas_costos | admin | ninguno | ninguno |
| deudores | admin | ninguno | ninguno |
| recaudacion | admin | ninguno | ninguno |
| configuracion | admin | ninguno | ninguno |
| usuarios_permisos | admin | ninguno | ninguno |

## Comportamiento por nivel
- `ninguno` → redirigir, no mostrar en menú
- `vista` → mostrar sin botones de acción
- `crear` → mostrar con botón de nuevo, sin editar/eliminar
- `editar` → crear + editar
- `admin` → todo incluyendo eliminar y configurar

## Logout
```js
await supabase.auth.signOut()
// redirigir a login.html
```
