# SPEC: Permisos Granulares

## Objetivo
Admin configura qué puede hacer cada usuario en cada módulo.

## Queries
```js
// leer permisos de un usuario
const { data } = await supabase
  .from('permisos')
  .select('modulo, nivel')
  .eq('usuario_id', usuarioId)

// guardar cambios (upsert)
await supabase
  .from('permisos')
  .upsert(
    modulos.map(m => ({
      empresa_id, usuario_id: usuarioId,
      modulo: m.id, nivel: m.nivel
    })),
    { onConflict: 'usuario_id,modulo' }
  )

// verificar permiso desde el front antes de mostrar una acción
const tienePermiso = (modulo, nivelRequerido) => {
  const niveles = ['ninguno','vista','crear','editar','admin']
  const actual = permisosCache[modulo] || 'ninguno'
  return niveles.indexOf(actual) >= niveles.indexOf(nivelRequerido)
}
```

## Módulos
`pedidos` | `clientes` | `hoja_ruta` | `stock` | `ingresos` | `boletas` | `ventas_totales` | `ventas_costos` | `ventas_margenes` | `deudores` | `recaudacion` | `reportes_stock` | `configuracion` | `usuarios_permisos`

## Reglas
- Admin siempre tiene nivel `admin` en todo — no se puede modificar
- Si no existe registro en `permisos` para un módulo → nivel `ninguno`
- Cambios se aplican en la próxima sesión del usuario afectado
