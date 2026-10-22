-- ═══ Precio de referencia por proveedor + ratio para sugerir precio de venta ═══
--
-- Flujo:
--   1) El proveedor publica una lista de precios (al público). Importás esa lista.
--   2) Cada línea se mapea a un producto tuyo o se marca "ignorado".
--      Mapeos y clasificaciones quedan guardados (nombre_externo_proveedor),
--      así las próximas listas se matchean solas.
--   3) En producto_proveedor se guardan:
--        - precio_referencia  → último precio publicado por ese proveedor
--        - ratio_venta        → precio_de_venta_tuyo / precio_referencia
--      El ratio se setea la primera vez (manual o auto) y de ahí en adelante
--      se mantiene constante: cuando el proveedor sube el precio, la app
--      sugiere nuevo_precio_venta = nuevo_precio_ref × ratio.
--   4) Si editás manualmente el precio de venta (fuera de una importación),
--      un trigger recalcula el ratio: la nueva relación pasa a ser la buena.

-- Columnas en producto_proveedor
alter table public.producto_proveedor
  add column if not exists precio_referencia numeric,
  add column if not exists ratio_venta       numeric;

comment on column public.producto_proveedor.precio_referencia is
  'Último precio publicado por el proveedor en su lista. Se actualiza al importar.';
comment on column public.producto_proveedor.ratio_venta is
  'precio_venta / precio_referencia. Capturado 1 vez; se recalcula si editás el precio de venta.';

-- Nombres externos: cómo nombra cada proveedor sus productos.
-- Estado: mapeado (asociado a un producto tuyo) o ignorado (no te interesa).
create table if not exists public.nombre_externo_proveedor (
  id                uuid primary key default gen_random_uuid(),
  empresa_id        uuid not null references public.empresas(id) on delete cascade,
  proveedor_id      uuid not null references public.proveedores(id) on delete cascade,
  nombre_externo    text not null,
  nombre_norm       text not null,
  producto_id       uuid references public.productos(id) on delete set null,
  estado            text not null check (estado in ('mapeado','ignorado')),
  -- Equivalencia entre la unidad de la lista y la unidad del stock.
  -- precio_ref_tu_unidad = precio_lista × factor_conversion.
  -- Ej: proveedor vende x10, vos tenés x20 → factor = 20/10 = 2.
  factor_conversion numeric not null default 1 check (factor_conversion > 0),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (proveedor_id, nombre_norm)
);

create index if not exists idx_nombre_ext_prov on public.nombre_externo_proveedor(proveedor_id);
create index if not exists idx_nombre_ext_prod on public.nombre_externo_proveedor(producto_id)
  where producto_id is not null;

-- Historial de importaciones (header con contadores).
create table if not exists public.importacion_lista_proveedor (
  id               uuid primary key default gen_random_uuid(),
  empresa_id       uuid not null references public.empresas(id) on delete cascade,
  proveedor_id     uuid not null references public.proveedores(id) on delete cascade,
  usuario_id       uuid references public.usuarios(id) on delete set null,
  fecha            timestamptz not null default now(),
  lineas_total     integer not null default 0,
  lineas_mapeadas  integer not null default 0,
  lineas_ignoradas integer not null default 0,
  lineas_nuevas    integer not null default 0,
  cambios_aplicados integer not null default 0,
  mapeados_sin_precio integer not null default 0
);
create index if not exists idx_imp_lista_prov on public.importacion_lista_proveedor(proveedor_id, fecha desc);

-- Trigger: cuando se edita productos.precio (fuera o dentro de una importación),
-- recalcula ratio_venta para todos los proveedores que tengan precio_referencia
-- cargado. Decisión A: el precio de venta manda sobre el ratio.
create or replace function public.sync_ratio_venta_from_producto()
returns trigger language plpgsql as $$
begin
  if NEW.precio is distinct from OLD.precio and NEW.precio > 0 then
    update public.producto_proveedor
       set ratio_venta = NEW.precio / nullif(precio_referencia, 0)
     where producto_id = NEW.id
       and precio_referencia is not null
       and precio_referencia > 0;
  end if;
  return NEW;
end $$;

drop trigger if exists trg_sync_ratio_venta on public.productos;
create trigger trg_sync_ratio_venta
  after update of precio on public.productos
  for each row execute function public.sync_ratio_venta_from_producto();
