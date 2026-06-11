# SPEC: Stock

## Objetivo
Ver stock actual por producto. Registrar ajustes manuales. Ver historial de movimientos.

## Queries
```js
// stock actual con datos del producto
const { data } = await supabase
  .from('stock_actual')
  .select('producto_id, stock, productos(nombre, categoria, costo, proveedor_id, proveedores(nombre))')
  .eq('productos.empresa_id', empresaId)
  .order('stock', { ascending: true })

// productos en negativo
const { data } = await supabase
  .from('stock_negativo')
  .select('producto_id, stock, productos(nombre)')

// historial de movimientos de un producto
const { data } = await supabase
  .from('mov_stock')
  .select('tipo, cantidad, referencia_tipo, fecha, usuarios(nombre)')
  .eq('producto_id', productoId)
  .order('fecha', { ascending: false })
  .limit(50)

// ajuste manual
await supabase.from('mov_stock').insert({
  empresa_id, producto_id,
  tipo: 'ajuste',
  cantidad,   // positivo o negativo
  referencia_tipo: 'ajuste_manual',
  usuario_id
})
```

## Filtros disponibles
- Todos / Stock bajo (≤5) / Negativos
- Por categoría / Por proveedor

## Alertas
- Stock < 0 → badge rojo
- Stock 1-5 → badge amarillo
- Sin ingreso > 45 días → alerta naranja (leer de vista `dias_sin_ingreso`)
- Sin cambio de costo > 45 días → alerta naranja

## Reglas
- Todos pueden ver stock
- Solo depósito y admin pueden registrar ajustes
