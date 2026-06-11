# SPEC: Pedidos

## Objetivo
Preventista carga un pedido para un cliente. El stock baja al confirmar. Se genera la boleta.

## Flujo
1. Elegir cliente → mostrar saldo actual de `saldo_actual`
2. Buscar y agregar productos → por unidad o por bulto (con descuento default)
3. Aplicar descuento general opcional
4. Confirmar → insertar `pedidos` + `pedido_items` + `boletas` + `mov_stock` (venta, negativo)

## Queries
```js
// clientes con saldo
const { data } = await supabase
  .from('clientes')
  .select('*, saldo_actual(saldo)')
  .eq('empresa_id', empresaId)
  .eq('activo', true)
  .order('nombre')

// productos activos
const { data } = await supabase
  .from('productos')
  .select('id, nombre, precio, u_bulto, desc_bulto, categoria')
  .eq('empresa_id', empresaId)
  .eq('activo', true)
  .ilike('nombre', `%${busqueda}%`)

// confirmar pedido
const { data: pedido } = await supabase
  .from('pedidos')
  .insert({ empresa_id, cliente_id, usuario_id, descuento, estado: 'confirmado' })
  .select().single()

await supabase.from('pedido_items').insert(items.map(it => ({
  empresa_id, pedido_id: pedido.id, producto_id: it.id,
  cantidad: it.cant, precio_unit: it.precio, descuento: it.disc,
  es_bulto: it.esBulto, u_por_bulto: it.uPorBulto
})))

// saldo anterior al momento del pedido
const { data: saldo } = await supabase
  .from('saldo_actual')
  .select('saldo')
  .eq('cliente_id', clienteId)
  .single()

await supabase.from('boletas').insert({
  empresa_id, pedido_id: pedido.id,
  total: totalPedido,
  saldo_anterior: saldo?.saldo > 0 ? saldo.saldo : 0,
  total_a_cobrar: totalPedido + (saldo?.saldo > 0 ? saldo.saldo : 0)
})

// mov_stock: bajar stock por cada ítem
await supabase.from('mov_stock').insert(items.map(it => ({
  empresa_id, producto_id: it.id,
  tipo: 'venta', cantidad: -it.cant,
  referencia: pedido.id, referencia_tipo: 'pedido',
  usuario_id
})))
```

## Venta por bulto
- `es_bulto = true`, `u_por_bulto = producto.u_bulto`
- `cantidad` siempre en unidades (bultos × u_por_bulto)
- `descuento` precargado con `producto.desc_bulto`, editable

## Reglas
- Solo preventistas y admin pueden crear pedidos
- Preventistas solo ven sus propios pedidos
- Stock puede quedar negativo — es válido
