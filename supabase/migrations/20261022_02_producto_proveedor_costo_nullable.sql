-- ═══ costo nullable en producto_proveedor ═══
-- "Solo referencia": al importar la lista de un proveedor, si ese proveedor
-- no te vende el producto (todavía), igual queremos guardar su precio de lista
-- para que la app pueda sugerir precios de venta. En esos casos costo = NULL
-- y la UI de stock no lo lista como proveedor alternativo real.
-- Si en algún momento empezás a comprarle a ese proveedor, se edita el costo
-- y pasa a ser proveedor real.

alter table public.producto_proveedor
  alter column costo drop not null;
