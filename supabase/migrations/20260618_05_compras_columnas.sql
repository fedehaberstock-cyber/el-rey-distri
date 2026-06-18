-- ═══ Columnas extra para flujo de compras ═══

alter table public.proveedores
  add column if not exists dias_credito integer not null default 0;

alter table public.productos
  add column if not exists unidad_compra integer not null default 1
    check (unidad_compra >= 1),
  add column if not exists notas_compra text;
