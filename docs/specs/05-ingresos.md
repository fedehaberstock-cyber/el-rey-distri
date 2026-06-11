# SPEC: Ingresos de Proveedor

## Objetivo
Registrar una boleta de compra. Al confirmar: actualiza costos y sube stock via función SQL.

## Flujo
1. Elegir proveedor → precargar `cargos_default` del proveedor
2. Agregar productos con bultos, unidades/bulto y costo neto
3. Activar/desactivar cargos extra (IVA, IIBB, Ganancias, Flete) con % editables
4. Ingresar total de la boleta física → verificar checksum
5. Confirmar → insertar `ingresos` + `ingreso_items` → llamar `confirmar_ingreso()`

## Queries
```js
// proveedor con cargos default
const { data: prov } = await supabase
  .from('proveedores')
  .select('id, nombre, cargos_default')
  .eq('empresa_id', empresaId)
  .eq('activo', true)

// insertar ingreso
const { data: ingreso } = await supabase
  .from('ingresos')
  .insert({
    empresa_id, proveedor_id, usuario_id,
    numero_boleta, fecha,
    cargos_aplicados: cargosActivos,  // [{nombre, pct}]
    total_declarado, total_calculado
  }).select().single()

// insertar items
await supabase.from('ingreso_items').insert(items.map(it => ({
  empresa_id,
  ingreso_id: ingreso.id,
  producto_id: it.productoId,
  bultos: it.bultos,
  u_por_bulto: it.uPorBulto,
  cantidad: it.bultos * it.uPorBulto,
  costo_unit_neto: it.costo,
  costo_unit_final: it.costo * multiplicador
})))

// confirmar — actualiza costos y genera mov_stock
await supabase.rpc('confirmar_ingreso', { p_ingreso_id: ingreso.id })
```

## Cálculo de costos
```
multiplicador = 1 + sum(cargos_activos.pct) / 100
costo_unit_final = costo_unit_neto × multiplicador
```

## Checksum
```
diferencia = total_declarado - total_calculado
|diferencia| < 1 → OK (tolerancia $1)
```

## Reglas
- Solo depósito y admin pueden cargar ingresos
- `confirmar_ingreso` es idempotente solo una vez — no llamar dos veces
