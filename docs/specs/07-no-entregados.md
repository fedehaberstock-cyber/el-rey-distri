# SPEC: No Entregados

## Objetivo
Admin decide qué hacer con cada pedido no entregado: postergar o cancelar con devolución de stock.

## Queries
```js
// pedidos no entregados del día
const { data } = await supabase
  .from('pedidos')
  .select('*, clientes(nombre, direccion), boletas(total, saldo_anterior), pedido_items(*, productos(nombre))')
  .eq('empresa_id', empresaId)
  .eq('estado', 'no_entregado')
  .order('fecha', { ascending: false })

// POSTERGAR: cambiar fecha y asignar a nueva hoja de ruta
await supabase
  .from('pedidos')
  .update({ estado: 'postergado', hoja_ruta_id: null })
  .eq('id', pedidoId)

// CANCELAR: anular pedido + devolver stock seleccionado
await supabase
  .from('pedidos')
  .update({ estado: 'anulado' })
  .eq('id', pedidoId)

// devolución por ítem seleccionado
await supabase.from('mov_stock').insert(itemsADevolver.map(it => ({
  empresa_id,
  producto_id: it.producto_id,
  tipo: 'devolucion',
  cantidad: it.cantidad,   // positivo — vuelve al stock
  referencia: pedidoId,
  referencia_tipo: 'pedido',
  usuario_id
})))
```

## Reglas
- Solo admin puede resolver no entregados
- Al postergar: el pedido aparece disponible para la próxima hoja de ruta
- Al cancelar: el cargo en `mov_cuenta` del pedido original se revierte con un `ajuste`
- Devolución de stock es por ítem — no necesariamente se devuelve todo
