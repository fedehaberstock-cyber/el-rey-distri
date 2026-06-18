-- ═══ Gastos fijos mensuales ═══
-- Sirve para incluir en la ganancia neta del reporte de ventas
-- gastos recurrentes (alquiler, sueldos, servicios) prorrateados
-- por dias corridos al rango del reporte.

create table if not exists public.gastos_fijos (
  id             uuid primary key default gen_random_uuid(),
  empresa_id     uuid not null references public.empresas(id) on delete cascade,
  concepto       text not null,
  monto_mensual  numeric(12,2) not null check (monto_mensual >= 0),
  vigente_desde  date not null default current_date,
  vigente_hasta  date,
  activo         boolean not null default true,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create index if not exists gastos_fijos_emp_idx on public.gastos_fijos(empresa_id);

alter table public.gastos_fijos enable row level security;
drop policy if exists tenant on public.gastos_fijos;
create policy tenant on public.gastos_fijos
  using (empresa_id = public.empresa_actual())
  with check (empresa_id = public.empresa_actual());

drop trigger if exists tg_updated_at_gastos_fijos on public.gastos_fijos;
create trigger tg_updated_at_gastos_fijos
  before update on public.gastos_fijos
  for each row execute function public.tg_set_updated_at();
