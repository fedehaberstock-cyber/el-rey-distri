-- ═══ Multi-proveedor por producto (comparador de precios) ═══
-- Tabla auxiliar: cada producto puede tener N proveedores alternativos
-- con su costo. El "proveedor preferido" sigue siendo productos.proveedor_id.
-- Sirve para comparar precios y detectar oportunidades de cambio.

create table if not exists public.producto_proveedor (
  id              uuid primary key default gen_random_uuid(),
  empresa_id      uuid not null references public.empresas(id) on delete cascade,
  producto_id     uuid not null references public.productos(id) on delete cascade,
  proveedor_id    uuid not null references public.proveedores(id) on delete cascade,
  costo           numeric(12,2) not null check (costo >= 0),
  observaciones   text,
  actualizado_en  date not null default current_date,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (producto_id, proveedor_id)
);

create index if not exists producto_proveedor_emp_idx on public.producto_proveedor(empresa_id);
create index if not exists producto_proveedor_prod_idx on public.producto_proveedor(producto_id);

alter table public.producto_proveedor enable row level security;
drop policy if exists tenant on public.producto_proveedor;
create policy tenant on public.producto_proveedor
  using (empresa_id = public.empresa_actual())
  with check (empresa_id = public.empresa_actual());

drop trigger if exists tg_updated_at_producto_proveedor on public.producto_proveedor;
create trigger tg_updated_at_producto_proveedor
  before update on public.producto_proveedor
  for each row execute function public.tg_set_updated_at();

-- Sembrar con el proveedor actual de cada producto (para que la tabla
-- arranque con el dato que ya tenemos).
insert into public.producto_proveedor (empresa_id, producto_id, proveedor_id, costo)
  select p.empresa_id, p.id, p.proveedor_id, coalesce(p.costo, 0)
  from public.productos p
  where p.proveedor_id is not null
  on conflict (producto_id, proveedor_id) do nothing;
