-- ═══ Ordenes de compra a proveedores ═══
-- Persiste lo que se envia al proveedor (WhatsApp / copia / email) para tener
-- historial, calcular cuanto se le compra a cada uno y descontar del stock
-- virtual lo que ya esta pedido pero aun no llego.

do $$
begin
  if not exists (select 1 from pg_type where typname = 'estado_orden_compra') then
    create type public.estado_orden_compra as enum
      ('borrador','enviada','recibida_parcial','recibida','cancelada');
  end if;
end$$;

do $$
begin
  if not exists (select 1 from pg_type where typname = 'canal_orden_compra') then
    create type public.canal_orden_compra as enum
      ('whatsapp','copia','email','manual');
  end if;
end$$;

create table if not exists public.ordenes_compra (
  id                       uuid primary key default gen_random_uuid(),
  empresa_id               uuid not null references public.empresas(id) on delete cascade,
  proveedor_id             uuid references public.proveedores(id) on delete set null,
  estado                   public.estado_orden_compra not null default 'borrador',
  canal                    public.canal_orden_compra,
  fecha_enviada            timestamptz,
  fecha_estimada_llegada   date,
  fecha_recibida           timestamptz,
  total_estimado           numeric(12,2) not null default 0,
  observaciones            text,
  enviada_por_usuario_id   uuid references public.usuarios(id),
  ingreso_id               uuid references public.ingresos(id) on delete set null,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now()
);

create index if not exists ordenes_compra_emp_idx on public.ordenes_compra(empresa_id);
create index if not exists ordenes_compra_prov_idx on public.ordenes_compra(proveedor_id);
create index if not exists ordenes_compra_estado_idx on public.ordenes_compra(empresa_id, estado);

alter table public.ordenes_compra enable row level security;
drop policy if exists tenant on public.ordenes_compra;
create policy tenant on public.ordenes_compra
  using (empresa_id = public.empresa_actual())
  with check (empresa_id = public.empresa_actual());

drop trigger if exists tg_updated_at_ordenes_compra on public.ordenes_compra;
create trigger tg_updated_at_ordenes_compra
  before update on public.ordenes_compra
  for each row execute function public.tg_set_updated_at();


create table if not exists public.orden_compra_items (
  id                    uuid primary key default gen_random_uuid(),
  empresa_id            uuid not null references public.empresas(id) on delete cascade,
  orden_id              uuid not null references public.ordenes_compra(id) on delete cascade,
  producto_id           uuid not null references public.productos(id),
  cantidad              integer not null check (cantidad > 0),
  costo_unit_estimado   numeric(12,2) not null default 0,
  cantidad_recibida     integer not null default 0,
  costo_unit_recibido   numeric(12,2),
  created_at            timestamptz not null default now()
);

create index if not exists orden_items_orden_idx on public.orden_compra_items(orden_id);
create index if not exists orden_items_prod_idx  on public.orden_compra_items(producto_id);

alter table public.orden_compra_items enable row level security;
drop policy if exists tenant on public.orden_compra_items;
create policy tenant on public.orden_compra_items
  using (empresa_id = public.empresa_actual())
  with check (empresa_id = public.empresa_actual());
