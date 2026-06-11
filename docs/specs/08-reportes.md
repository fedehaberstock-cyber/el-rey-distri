# SPEC: Reportes

## Reporte de Ventas
```js
// ventas por período con items
const { data } = await supabase
  .from('pedidos')
  .select('id, fecha, usuarios(nombre), clientes(nombre), pedido_items(cantidad, precio_unit, descuento, productos(nombre))')
  .eq('empresa_id', empresaId)
  .in('estado', ['confirmado', 'entregado'])
  .gte('fecha', desde)
  .lte('fecha', hasta)
```

## Reporte de Stock
```js
// stock con alertas
const { data } = await supabase
  .from('dias_sin_ingreso')
  .select('*, productos(nombre, categoria, costo, proveedores(nombre))')
  .eq('productos.empresa_id', empresaId)
  .order('dias_sin_ingreso', { ascending: false })
```

## Reporte de Deudores
```js
const { data } = await supabase
  .from('saldo_actual')
  .select('cliente_id, saldo, clientes(nombre, direccion, telefono)')
  .gt('saldo', 0)
  .order('saldo', { ascending: false })
```

## Reporte de Recaudación por Preventista
```js
const { data } = await supabase
  .from('recaudacion_por_usuario')
  .select('usuario_id, dia, forma_pago, recaudado, usuarios(nombre)')
  .eq('usuarios.empresa_id', empresaId)
  .gte('dia', desde)
  .lte('dia', hasta)
  .order('dia', { ascending: false })
```

## Reglas de acceso
| Reporte | Admin | Preventista | Depósito |
|---|---|---|---|
| Ventas totales | ✅ | ✅ (sin costos) | ✅ (sin costos) |
| Ventas costos/márgenes | ✅ | ❌ | ❌ |
| Stock | ✅ | ✅ | ✅ |
| Deudores | ✅ | ❌ | ❌ |
| Recaudación | ✅ | ❌ | ❌ |

Para preventistas: omitir `costo` en los queries de productos.
