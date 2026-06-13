-- ─────────────────────────────────────────────────────────────────────────
-- Markup objetivo + margen mínimo para sugerencia/bloqueo de precios.
--
-- Modelo en cascada (mayor a menor prioridad):
--   1. productos.markup_objetivo_pct  (override por producto)
--   2. categorias_markup.markup_pct   (default por nombre de categoría)
--   3. empresas.markup_default_pct    (fallback global)
--
-- markup_minimo_pct (default 20%) define el piso para bloquear ingresos.
-- ─────────────────────────────────────────────────────────────────────────

-- 1) Settings globales en empresas
alter table public.empresas
  add column if not exists markup_default_pct numeric(5,2) not null default 33,
  add column if not exists markup_minimo_pct  numeric(5,2) not null default 20;

-- 2) Override por producto
alter table public.productos
  add column if not exists markup_objetivo_pct numeric(5,2);

-- 3) Markup por categoría (key text porque productos.categoria es text)
create table if not exists public.categorias_markup (
  id          uuid primary key default gen_random_uuid(),
  empresa_id  uuid not null references public.empresas(id) on delete cascade,
  categoria   text not null,
  markup_pct  numeric(5,2) not null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint categorias_markup_uq unique (empresa_id, categoria)
);

create index if not exists categorias_markup_emp_idx
  on public.categorias_markup (empresa_id);

alter table public.categorias_markup enable row level security;

drop policy if exists categorias_markup_tenant on public.categorias_markup;
create policy categorias_markup_tenant on public.categorias_markup
  using (empresa_id = public.empresa_actual())
  with check (empresa_id = public.empresa_actual());

-- 4) Helper: redondear precio al próximo múltiplo de 50/90/100 hacia arriba.
--    Grid: ..., 1200, 1250, 1290, 1300, 1350, 1390, 1400, ...
create or replace function public.redondear_precio_50_90(p numeric)
  returns int
  language plpgsql immutable
as $$
declare
  base int;
  ult2 int;
  cien int;
begin
  if p is null or p <= 0 then return 0; end if;
  base := ceil(p)::int;
  ult2 := base % 100;
  cien := base - ult2;
  if    ult2 = 0       then return base;
  elsif ult2 <= 50     then return cien + 50;
  elsif ult2 <= 90     then return cien + 90;
  else                       return cien + 100;
  end if;
end $$;

-- 5) SEED — markups categóricos surgidos del análisis del catálogo actual.
--    Solo se cargan en empresas activas; idempotente (on conflict do nothing).
do $$
declare
  emp record;
begin
  for emp in select id from public.empresas where activa loop
    insert into public.categorias_markup (empresa_id, categoria, markup_pct) values
      (emp.id, 'Tinturas',        27.5),
      (emp.id, 'Aromatizantes',   28.6),
      (emp.id, 'Pegamentos',      29.0),
      (emp.id, 'Tabaqueria',      29.0),
      (emp.id, 'Papel',           30.0),
      (emp.id, 'Reunata',         31.0),
      (emp.id, 'Make',            35.0),
      (emp.id, 'Pilas',           32.0),
      (emp.id, 'Kiosco',          30.0),
      (emp.id, 'Temporada',       33.0),
      (emp.id, 'Filos',           33.0),
      (emp.id, 'Descartables',    30.0),
      (emp.id, 'Varios',          31.0)
    on conflict (empresa_id, categoria) do nothing;
  end loop;
end $$;

-- 6) SEED — para categorías caóticas (alta dispersión interna), cada producto
--    queda con SU markup actual como objetivo. Así Novalgina 205%, Cif 170%,
--    etc., conservan su precio relativo y la sugerencia futura respeta lo
--    histórico del producto.
update public.productos
   set markup_objetivo_pct = round(((precio - costo) / costo * 100)::numeric, 2)
 where activo = true
   and costo > 0
   and precio > 0
   and categoria in ('Analgésicos', 'Perfumería', 'Limpieza')
   and markup_objetivo_pct is null;
