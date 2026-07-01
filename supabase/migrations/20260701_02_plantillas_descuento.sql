-- ── PLANTILLAS DE DESCUENTO ────────────────────────────────────────────────
-- Reglas reutilizables agrupadas en plantillas. Un cliente puede tener varias
-- plantillas asignadas; las reglas se resuelven eligiendo la MÁS ESPECÍFICA
-- (producto > subcategoria > categoria > todo). Si dos reglas de igual
-- especificidad aplican, gana la de mayor porcentaje.

-- 1) Plantilla (nombre)
create table if not exists public.plantillas_descuento (
  id          uuid primary key default gen_random_uuid(),
  empresa_id  uuid not null references public.empresas(id) on delete cascade,
  nombre      text not null,
  descripcion text,
  activo      boolean not null default true,
  created_at  timestamptz not null default now()
);
create index if not exists idx_plantillas_desc_empresa on public.plantillas_descuento(empresa_id);

-- 2) Reglas de una plantilla
create table if not exists public.plantillas_descuento_reglas (
  id            uuid primary key default gen_random_uuid(),
  plantilla_id  uuid not null references public.plantillas_descuento(id) on delete cascade,
  alcance       text not null check (alcance in ('todo','categoria','subcategoria','producto')),
  alcance_valor text,
  porcentaje    numeric not null default 0,
  excluye       boolean not null default false,
  created_at    timestamptz not null default now()
);
create index if not exists idx_plantilla_reglas on public.plantillas_descuento_reglas(plantilla_id);

alter table public.plantillas_descuento_reglas drop constraint if exists ck_reglas_alcance_valor;
alter table public.plantillas_descuento_reglas add constraint ck_reglas_alcance_valor
  check (alcance = 'todo' or (alcance_valor is not null and length(btrim(alcance_valor)) > 0));

-- 3) N:M cliente ↔ plantilla
create table if not exists public.clientes_plantillas (
  cliente_id   uuid not null references public.clientes(id) on delete cascade,
  plantilla_id uuid not null references public.plantillas_descuento(id) on delete cascade,
  created_at   timestamptz not null default now(),
  primary key (cliente_id, plantilla_id)
);
create index if not exists idx_cli_plant_plantilla on public.clientes_plantillas(plantilla_id);

-- ── RLS ────────────────────────────────────────────────────────────────────
alter table public.plantillas_descuento         enable row level security;
alter table public.plantillas_descuento_reglas  enable row level security;
alter table public.clientes_plantillas          enable row level security;

drop policy if exists "plant_sel" on public.plantillas_descuento;
create policy "plant_sel" on public.plantillas_descuento
  for select using (empresa_id in (select empresa_id from public.usuarios where auth_id = auth.uid()));
drop policy if exists "plant_ins" on public.plantillas_descuento;
create policy "plant_ins" on public.plantillas_descuento
  for insert with check (empresa_id in (select empresa_id from public.usuarios where auth_id = auth.uid()));
drop policy if exists "plant_upd" on public.plantillas_descuento;
create policy "plant_upd" on public.plantillas_descuento
  for update using (empresa_id in (select empresa_id from public.usuarios where auth_id = auth.uid()));
drop policy if exists "plant_del" on public.plantillas_descuento;
create policy "plant_del" on public.plantillas_descuento
  for delete using (empresa_id in (select empresa_id from public.usuarios where auth_id = auth.uid()));

drop policy if exists "plant_reglas_sel" on public.plantillas_descuento_reglas;
create policy "plant_reglas_sel" on public.plantillas_descuento_reglas
  for select using (plantilla_id in (select id from public.plantillas_descuento
    where empresa_id in (select empresa_id from public.usuarios where auth_id = auth.uid())));
drop policy if exists "plant_reglas_ins" on public.plantillas_descuento_reglas;
create policy "plant_reglas_ins" on public.plantillas_descuento_reglas
  for insert with check (plantilla_id in (select id from public.plantillas_descuento
    where empresa_id in (select empresa_id from public.usuarios where auth_id = auth.uid())));
drop policy if exists "plant_reglas_upd" on public.plantillas_descuento_reglas;
create policy "plant_reglas_upd" on public.plantillas_descuento_reglas
  for update using (plantilla_id in (select id from public.plantillas_descuento
    where empresa_id in (select empresa_id from public.usuarios where auth_id = auth.uid())));
drop policy if exists "plant_reglas_del" on public.plantillas_descuento_reglas;
create policy "plant_reglas_del" on public.plantillas_descuento_reglas
  for delete using (plantilla_id in (select id from public.plantillas_descuento
    where empresa_id in (select empresa_id from public.usuarios where auth_id = auth.uid())));

drop policy if exists "cli_plant_sel" on public.clientes_plantillas;
create policy "cli_plant_sel" on public.clientes_plantillas
  for select using (cliente_id in (select id from public.clientes
    where empresa_id in (select empresa_id from public.usuarios where auth_id = auth.uid())));
drop policy if exists "cli_plant_ins" on public.clientes_plantillas;
create policy "cli_plant_ins" on public.clientes_plantillas
  for insert with check (cliente_id in (select id from public.clientes
    where empresa_id in (select empresa_id from public.usuarios where auth_id = auth.uid())));
drop policy if exists "cli_plant_del" on public.clientes_plantillas;
create policy "cli_plant_del" on public.clientes_plantillas
  for delete using (cliente_id in (select id from public.clientes
    where empresa_id in (select empresa_id from public.usuarios where auth_id = auth.uid())));

-- ── BACKFILL desde descuentos_cliente (si existe) ──────────────────────────
-- Para cada cliente con reglas en descuentos_cliente, crea una plantilla
-- "Reglas legado — <nombre_cliente>" y migra las reglas + asigna al cliente.
do $$
declare
  r record;
  new_pl uuid;
begin
  if to_regclass('public.descuentos_cliente') is null then return; end if;

  for r in
    select c.id as cliente_id, c.empresa_id, c.nombre
    from public.clientes c
    where exists (select 1 from public.descuentos_cliente d where d.cliente_id = c.id)
  loop
    insert into public.plantillas_descuento (empresa_id, nombre, descripcion)
    values (r.empresa_id, 'Reglas legado — ' || r.nombre, 'Migrado desde descuentos_cliente')
    returning id into new_pl;

    insert into public.plantillas_descuento_reglas (plantilla_id, alcance, alcance_valor, porcentaje, excluye)
    select new_pl, alcance, alcance_valor, porcentaje, excluye
    from public.descuentos_cliente
    where cliente_id = r.cliente_id;

    insert into public.clientes_plantillas (cliente_id, plantilla_id)
    values (r.cliente_id, new_pl)
    on conflict do nothing;
  end loop;
end $$;

-- (No borramos descuentos_cliente automáticamente — quedan por si necesitás revisar.)
