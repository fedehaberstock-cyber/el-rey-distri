-- ═══ Marca de "revisión de precio" ═══════════════════════════════════════
-- La pestaña Precios (stock.html) marca productos como "posible desactualización"
-- según hace cuánto no se toca su precio/costo. Hasta ahora usaba solo
-- ultimo_cambio_costo, que únicamente se actualiza al confirmar un ingreso de
-- stock — no al ajustar precios desde la pantalla Ajustar precios.
--
-- Agregamos una fecha de "última revisión de precio" que se estampa cuando el
-- usuario aplica cambios en Ajustar precios sobre un producto (aunque el valor
-- no cambie: revisó la lista del proveedor y confirmó que sigue vigente).
--
-- La pestaña Precios usará la fecha más reciente entre:
--   ultima_revision_precio, ultimo_cambio_costo, ultimo_cambio_precio.

alter table public.productos
  add column if not exists ultima_revision_precio date;

comment on column public.productos.ultima_revision_precio is
  'Última vez que se revisó el precio del producto en Ajustar precios (se estampa al aplicar, cambie o no el valor).';
