-- ── DESCUENTOS AUTOMÁTICOS POR CLIENTE ─────────────────────────────────────
-- Reglas que se aplican al agregar productos a un pedido:
--   alcance: 'todo' | 'categoria' | 'subcategoria' | 'producto'
--   alcance_valor: nombre de categoria/subcategoria, o producto_id (texto)
--   porcentaje: positivo = descuento, negativo = recargo
--   excluye: true = "no aplicar descuento a este alcance" (sobrescribe reglas más amplias)
--
-- Resolución en front: para cada producto se elige la regla MÁS ESPECÍFICA aplicable
-- (producto > subcategoria > categoria > todo). Si esa regla tiene excluye=true,
-- el descuento es 0. Si no, se usa su porcentaje.
--
-- El preventista puede sobrescribir manualmente el % en la línea del pedido.

create table if not exists public.descuentos_cliente (
  id            uuid primary key default gen_random_uuid(),
  empresa_id    uuid not null references public.empresas(id) on delete cascade,
  cliente_id    uuid not null references public.clientes(id) on delete cascade,
  alcance       text not null check (alcance in ('todo','categoria','subcategoria','producto')),
  alcance_valor text,
  porcentaje    numeric not null default 0,
  excluye       boolean not null default false,
  created_at    timestamptz not null default now()
);

create index if not exists idx_descuentos_cliente_cliente on public.descuentos_cliente(cliente_id);
create index if not exists idx_descuentos_cliente_empresa on public.descuentos_cliente(empresa_id);

-- Constraint: si alcance != 'todo' entonces alcance_valor no puede ser null
alter table public.descuentos_cliente drop constraint if exists ck_alcance_valor;
alter table public.descuentos_cliente add constraint ck_alcance_valor
  check (alcance = 'todo' or (alcance_valor is not null and length(btrim(alcance_valor)) > 0));

-- RLS
alter table public.descuentos_cliente enable row level security;

drop policy if exists "descuentos_cliente_sel" on public.descuentos_cliente;
create policy "descuentos_cliente_sel" on public.descuentos_cliente
  for select using (empresa_id in (select empresa_id from public.usuarios where auth_uid = auth.uid()));

drop policy if exists "descuentos_cliente_ins" on public.descuentos_cliente;
create policy "descuentos_cliente_ins" on public.descuentos_cliente
  for insert with check (empresa_id in (select empresa_id from public.usuarios where auth_uid = auth.uid()));

drop policy if exists "descuentos_cliente_upd" on public.descuentos_cliente;
create policy "descuentos_cliente_upd" on public.descuentos_cliente
  for update using (empresa_id in (select empresa_id from public.usuarios where auth_uid = auth.uid()));

drop policy if exists "descuentos_cliente_del" on public.descuentos_cliente;
create policy "descuentos_cliente_del" on public.descuentos_cliente
  for delete using (empresa_id in (select empresa_id from public.usuarios where auth_uid = auth.uid()));
