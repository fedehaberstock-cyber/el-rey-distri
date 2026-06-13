-- ─────────────────────────────────────────────────────────────────────────
-- Alias de productos por proveedor — memoria del extractor IA de boletas.
-- Cuando una boleta llega con un nombre/empaque distinto al stock interno,
-- el usuario lo mapea manualmente la primera vez y queda guardado acá.
--
-- factor_conversion: relación unidad-proveedor → unidad-interna.
--   Ej: proveedor manda "10 packs x 20" pero internamente se cuenta x10.
--       factor = 2  →  mi_cantidad = cant_proveedor × 2
--                      mi_costo_unit = costo_unit_proveedor ÷ 2
--   Default 1 (sin conversión).
-- ─────────────────────────────────────────────────────────────────────────

create table if not exists public.alias_productos (
  id                uuid primary key default gen_random_uuid(),
  empresa_id        uuid not null references public.empresas(id) on delete cascade,
  proveedor_id     uuid not null references public.proveedores(id) on delete cascade,
  alias_text        text not null,
  producto_id       uuid not null references public.productos(id) on delete cascade,
  factor_conversion numeric(10,4) not null default 1,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

-- Un mismo texto solo puede mapear a un producto por proveedor
create unique index if not exists alias_productos_uq
  on public.alias_productos (empresa_id, proveedor_id, lower(alias_text));

create index if not exists alias_productos_prov_idx
  on public.alias_productos (empresa_id, proveedor_id);

alter table public.alias_productos enable row level security;

drop policy if exists alias_productos_tenant on public.alias_productos;
create policy alias_productos_tenant on public.alias_productos
  using (empresa_id = public.empresa_actual())
  with check (empresa_id = public.empresa_actual());

-- ─────────────────────────────────────────────────────────────────────────
-- Storage bucket "ingresos_fotos" — fotos de boletas para procesar con IA.
-- Privado: solo el usuario autenticado de la empresa accede.
-- ─────────────────────────────────────────────────────────────────────────

insert into storage.buckets (id, name, public)
values ('ingresos_fotos', 'ingresos_fotos', false)
on conflict (id) do nothing;

drop policy if exists "ingresos_fotos_read_auth" on storage.objects;
create policy "ingresos_fotos_read_auth" on storage.objects
  for select to authenticated
  using (bucket_id = 'ingresos_fotos');

drop policy if exists "ingresos_fotos_write_auth" on storage.objects;
create policy "ingresos_fotos_write_auth" on storage.objects
  for all to authenticated
  using (bucket_id = 'ingresos_fotos')
  with check (bucket_id = 'ingresos_fotos');
