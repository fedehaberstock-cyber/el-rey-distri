-- ═══ Gastos del día + faltante al cerrar la hoja de ruta ═══
-- Permite cargar gastos (combustible, viáticos, etc.) al cerrar la hoja,
-- y registrar faltante/sobrante de caja contra el efectivo entregado.

-- Tabla de gastos (un registro por gasto)
create table if not exists public.hoja_gastos (
  id          uuid primary key default gen_random_uuid(),
  empresa_id  uuid not null references public.empresas(id) on delete cascade,
  hoja_id     uuid not null references public.hojas_ruta(id) on delete cascade,
  concepto    text not null,
  monto       numeric(12,2) not null check (monto > 0),
  usuario_id  uuid references public.usuarios(id),
  fecha       timestamptz not null default now()
);
create index if not exists hoja_gastos_hoja_idx on public.hoja_gastos(hoja_id);

alter table public.hoja_gastos enable row level security;
drop policy if exists tenant on public.hoja_gastos;
create policy tenant on public.hoja_gastos
  using (empresa_id = public.empresa_actual())
  with check (empresa_id = public.empresa_actual());

-- Columnas nuevas en hojas_ruta
alter table public.hojas_ruta
  add column if not exists total_gastos       numeric(12,2) not null default 0,
  add column if not exists efectivo_entregado numeric(12,2),
  add column if not exists faltante           numeric(12,2) not null default 0,
  add column if not exists observaciones      text;

-- Versión nueva del cierre con payload jsonb. Mantiene la firma uuid existente
-- (usada por sync RPC y por el cierre "sin cobros" del historial).
create or replace function public.cerrar_hoja_ruta(p_payload jsonb) returns void
language plpgsql security definer
set search_path = 'public'
as $$
declare
  v_hoja_id            uuid := (p_payload->>'hoja_id')::uuid;
  v_efectivo_entregado numeric := nullif(p_payload->>'efectivo_entregado','')::numeric;
  v_observaciones      text := nullif(p_payload->>'observaciones','');
  v_gastos             jsonb := coalesce(p_payload->'gastos', '[]'::jsonb);
  v_emp                uuid;
  v_usr                uuid;
  v_tot_gastos         numeric := 0;
  v_gasto              jsonb;
  v_faltante           numeric := 0;
  v_total_efectivo     numeric;
begin
  if v_hoja_id is null then raise exception 'hoja_id requerido'; end if;

  select empresa_id, usuario_id into v_emp, v_usr
    from hojas_ruta where id = v_hoja_id;
  if v_emp is null then raise exception 'hoja no encontrada'; end if;

  -- 1. Insertar gastos
  for v_gasto in select * from jsonb_array_elements(v_gastos) loop
    if (v_gasto->>'concepto') is null or btrim(v_gasto->>'concepto') = '' then continue; end if;
    if coalesce((v_gasto->>'monto')::numeric, 0) <= 0 then continue; end if;
    insert into hoja_gastos (empresa_id, hoja_id, concepto, monto, usuario_id)
    values (v_emp, v_hoja_id, btrim(v_gasto->>'concepto'),
            (v_gasto->>'monto')::numeric, v_usr);
    v_tot_gastos := v_tot_gastos + (v_gasto->>'monto')::numeric;
  end loop;

  -- 2. Ejecutar el cierre normal (rollover, mov_cuenta, totales por forma de pago)
  perform public.cerrar_hoja_ruta(v_hoja_id);

  -- 3. Faltante = total_efectivo (cobrado) − gastos − efectivo entregado
  --    Positivo  → falta plata
  --    Negativo  → sobra
  if v_efectivo_entregado is not null then
    select total_efectivo into v_total_efectivo
      from hojas_ruta where id = v_hoja_id;
    v_faltante := coalesce(v_total_efectivo, 0) - v_tot_gastos - v_efectivo_entregado;
  end if;

  update hojas_ruta set
    total_gastos       = v_tot_gastos,
    efectivo_entregado = v_efectivo_entregado,
    faltante           = coalesce(v_faltante, 0),
    observaciones      = v_observaciones
  where id = v_hoja_id;
end;
$$;
