-- ═══ Historial de comisiones (para no recalcular el pasado) ═══════════════
-- Hasta ahora la comisión vivía como un único valor en usuarios
-- (comision_tipo / comision_valor). El reporte de ganancia leía ese valor
-- actual y lo aplicaba a cualquier período → cambiar la comisión hoy
-- recalculaba comisiones de meses pasados.
--
-- Creamos un historial versionado por vigencia. El reporte resuelve la tasa
-- vigente a la fecha de cada pedido. usuarios.comision_* se mantiene como
-- "valor actual" (puntero al vigente) para compatibilidad.

create table if not exists public.comisiones_historial (
  id             uuid primary key default gen_random_uuid(),
  empresa_id     uuid not null references public.empresas(id) on delete cascade,
  usuario_id     uuid not null references public.usuarios(id) on delete cascade,
  comision_tipo  text not null default 'ninguno'
                 check (comision_tipo in ('ninguno','porcentaje','fijo')),
  comision_valor numeric(12,2) not null default 0,
  vigente_desde  date not null default current_date,
  vigente_hasta  date,
  creado_en      timestamptz not null default now()
);

create index if not exists comisiones_hist_idx
  on public.comisiones_historial(empresa_id, usuario_id, vigente_desde);

alter table public.comisiones_historial enable row level security;
drop policy if exists tenant on public.comisiones_historial;
create policy tenant on public.comisiones_historial
  using (empresa_id = public.empresa_actual())
  with check (empresa_id = public.empresa_actual());

-- Semilla: una fila por usuario con su comisión ACTUAL, vigente desde una fecha
-- vieja. No podemos reconstruir tasas pasadas reales, así que el pasado queda
-- con el valor actual (igual que hoy). Los cambios futuros ya se versionan.
insert into public.comisiones_historial
  (empresa_id, usuario_id, comision_tipo, comision_valor, vigente_desde)
select u.empresa_id, u.id,
       coalesce(u.comision_tipo, 'ninguno'),
       coalesce(u.comision_valor, 0),
       '2020-01-01'::date
  from public.usuarios u
 where not exists (
   select 1 from public.comisiones_historial h where h.usuario_id = u.id
 );
