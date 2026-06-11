# SPEC: Boleta de Venta

## Objetivo
Ver e imprimir la boleta de un pedido. Muestra saldo anterior del cliente si existe.

## Queries
```js
// cargar boleta completa
const { data } = await supabase
  .from('boletas')
  .select(`
    id, total, saldo_anterior, total_a_cobrar, estado, fecha,
    pedidos (
      id, descuento, observaciones,
      usuarios(nombre),
      clientes(nombre, direccion, telefono),
      pedido_items(
        cantidad, precio_unit, descuento, es_bulto, u_por_bulto,
        productos(nombre)
      )
    )
  `)
  .eq('id', boletaId)
  .single()
```

## Display
- Si `saldo_anterior > 0`: mostrar línea roja "Saldo anterior + $X" y "Total a cobrar $Y"
- Si `saldo_anterior = 0`: mostrar solo "Total $X"
- `saldo_anterior` es inmutable — se guardó al confirmar el pedido, no recalcular

## Imprimir
```js
window.print()  // CSS @media print oculta UI, muestra solo boleta
```

## Reglas
- Todos pueden ver su boleta
- Solo depósito y admin pueden cambiar estado (`emitida` → `modificada` → `anulada`)
