# SPEC: Hoja de Ruta

## Objetivo
Generar la hoja de reparto del día ordenada por zona. Imprimir con QR. Cerrar con cobros.

## Flujo generación
1. Leer pedidos confirmados del día desde vista `hoja_ruta_hoy`
2. Crear registro en `hojas_ruta` con `qr_token` único
3. Asociar pedidos a la hoja: `pedidos.hoja_ruta_id = hoja.id`
4. Imprimir — el QR apunta a `https://dominio/hoja_ruta.html?token={qr_token}`

## Flujo cierre
1. Por cada pedido: marcar entregado/no entregado + forma de pago + montos
2. Al confirmar: llamar `cerrar_hoja_ruta(hoja_id)`
3. La función genera `mov_cuenta` por cada cobro e imputa primero contra saldo anterior

## Queries
```js
// pedidos del día ordenados por zona y posición
const { data } = await supabase
  .from('hoja_ruta_hoy')
  .select('*')
  .eq('empresa_id', empresaId)

// crear hoja
const { data: hoja } = await supabase
  .from('hojas_ruta')
  .insert({ empresa_id, usuario_id, fecha: hoy, estado: 'pendiente' })
  .select().single()

// asociar pedidos a la hoja
await supabase
  .from('pedidos')
  .update({ hoja_ruta_id: hoja.id })
  .in('id', pedidosIds)

// cargar forma de pago por pedido
await supabase
  .from('pedidos')
  .update({
    entregado,
    motivo_no_entrega,
    monto_efectivo, monto_transf, monto_cuenta
  })
  .eq('id', pedidoId)

// cerrar hoja — genera todos los mov_cuenta
await supabase.rpc('cerrar_hoja_ruta', { p_hoja_id: hoja.id })
```

## Saldo anterior en hoja impresa
- Mostrar por pedido: `boletas.saldo_anterior` + `boletas.total_a_cobrar`
- El total general de la hoja = suma de `total_a_cobrar` de todas las boletas

## QR
- Token generado automáticamente por Supabase (`gen_random_uuid()::text`)
- URL: `https://dominio/pages/hoja_ruta.html?token={qr_token}`
- Al cargar la página con `?token=`: buscar hoja por token y cargar pedidos

## Reglas
- Solo depósito y admin pueden cerrar la hoja
- Una hoja solo se puede cerrar una vez (`estado = 'cerrada'`)
