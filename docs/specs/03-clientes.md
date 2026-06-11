# SPEC: Clientes y Cuenta Corriente

## Objetivo
Ver, crear y gestionar clientes. Ver saldo y registrar cobros manuales.

## Queries
```js
// lista con saldo
const { data } = await supabase
  .from('clientes')
  .select('*, saldo_actual(saldo), zonas(nombre)')
  .eq('empresa_id', empresaId)
  .eq('activo', true)
  .order('nombre')

// historial de movimientos
const { data } = await supabase
  .from('mov_cuenta')
  .select('tipo, monto, forma_pago, descripcion, fecha, usuarios(nombre)')
  .eq('cliente_id', clienteId)
  .order('fecha', { ascending: false })

// registrar cobro manual
await supabase.from('mov_cuenta').insert({
  empresa_id, cliente_id,
  tipo: 'pago',
  monto: -monto,   // negativo = pago
  forma_pago,      // 'efectivo' | 'transferencia'
  referencia_tipo: 'ajuste_manual',
  usuario_id
})

// crear cliente
await supabase.from('clientes').insert({
  empresa_id, nombre, direccion, telefono,
  zona_id, posicion_zona
})
```

## Saldo
- Positivo = cliente debe
- Negativo = cliente tiene a favor
- Leer siempre desde vista `saldo_actual`

## Reglas
- Admin y preventistas pueden crear clientes
- Solo admin puede editar zona y posición
- Cobros manuales: admin y depósito
