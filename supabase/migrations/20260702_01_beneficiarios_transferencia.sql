-- ═══ Beneficiarios de transferencia ══════════════════════════════════════
-- Al registrar un cobro por transferencia se elige el beneficiario (cuenta
-- destino). Después en la pantalla transferencias se puede filtrar / agrupar
-- por beneficiario y exportar detalle + comprobantes.

-- 1) Tabla de beneficiarios
create table if not exists public.beneficiarios_transferencia (
  id          uuid primary key default gen_random_uuid(),
  empresa_id  uuid not null references public.empresas(id) on delete cascade,
  nombre      text not null,
  alias_cbu   text,
  tipo        text not null default 'propio' check (tipo in ('propio','tercero')),
  activo      boolean not null default true,
  created_at  timestamptz not null default now()
);
create index if not exists idx_benef_empresa on public.beneficiarios_transferencia(empresa_id);

alter table public.beneficiarios_transferencia enable row level security;

drop policy if exists "benef_sel" on public.beneficiarios_transferencia;
create policy "benef_sel" on public.beneficiarios_transferencia
  for select using (empresa_id in (select empresa_id from public.usuarios where auth_id = auth.uid()));
drop policy if exists "benef_ins" on public.beneficiarios_transferencia;
create policy "benef_ins" on public.beneficiarios_transferencia
  for insert with check (empresa_id in (select empresa_id from public.usuarios where auth_id = auth.uid()));
drop policy if exists "benef_upd" on public.beneficiarios_transferencia;
create policy "benef_upd" on public.beneficiarios_transferencia
  for update using (empresa_id in (select empresa_id from public.usuarios where auth_id = auth.uid()));
drop policy if exists "benef_del" on public.beneficiarios_transferencia;
create policy "benef_del" on public.beneficiarios_transferencia
  for delete using (empresa_id in (select empresa_id from public.usuarios where auth_id = auth.uid()));

-- 2) Columnas nuevas en mov_cuenta
alter table public.mov_cuenta
  add column if not exists beneficiario_id           uuid references public.beneficiarios_transferencia(id),
  add column if not exists nro_operacion_interna     int,
  add column if not exists enviado_al_beneficiario   boolean not null default false,
  add column if not exists enviado_en                timestamptz;

create index if not exists idx_mov_beneficiario on public.mov_cuenta(beneficiario_id)
  where beneficiario_id is not null;
create index if not exists idx_mov_nro_op on public.mov_cuenta(empresa_id, nro_operacion_interna)
  where nro_operacion_interna is not null;

-- 3) Columna nueva en pedidos para propagar al cerrar hoja_ruta
alter table public.pedidos
  add column if not exists beneficiario_transf_id uuid references public.beneficiarios_transferencia(id);

-- 4) Trigger: asignar nro_operacion_interna al insertar una transferencia pago
create or replace function public.set_nro_op_interna()
returns trigger language plpgsql as $$
begin
  if new.tipo = 'pago' and new.forma_pago = 'transferencia' and new.nro_operacion_interna is null then
    select coalesce(max(nro_operacion_interna), 0) + 1
      into new.nro_operacion_interna
      from public.mov_cuenta
     where empresa_id = new.empresa_id;
  end if;
  return new;
end $$;

drop trigger if exists tg_nro_op_interna on public.mov_cuenta;
create trigger tg_nro_op_interna
  before insert on public.mov_cuenta
  for each row execute function public.set_nro_op_interna();

-- 5) Backfill: numerar las transferencias históricas por fecha per empresa
do $$
declare
  emp record;
  mov record;
  n   int;
begin
  for emp in select distinct empresa_id from public.mov_cuenta
             where tipo='pago' and forma_pago='transferencia' and nro_operacion_interna is null
  loop
    n := coalesce((select max(nro_operacion_interna) from public.mov_cuenta where empresa_id=emp.empresa_id),0);
    for mov in
      select id from public.mov_cuenta
       where empresa_id = emp.empresa_id
         and tipo='pago' and forma_pago='transferencia'
         and nro_operacion_interna is null
       order by fecha, id
    loop
      n := n + 1;
      update public.mov_cuenta set nro_operacion_interna = n where id = mov.id;
    end loop;
  end loop;
end $$;

-- 6) cerrar_hoja_ruta actualizada: propaga beneficiario_transf_id del pedido a mov_cuenta
create or replace function public.cerrar_hoja_ruta(p_hoja_id uuid) returns void
language plpgsql security definer
set search_path = 'public'
as $$
declare
  ped           record;
  emp_id        uuid;
  asignado      uuid;
  cobrador      uuid;
  tot_ef        numeric := 0;
  tot_tr        numeric := 0;
  tot_cc        numeric := 0;
  tot_ne        numeric := 0;
begin
  select empresa_id, usuario_id into emp_id, asignado
    from hojas_ruta where id = p_hoja_id;

  select id into cobrador from usuarios where auth_id = auth.uid();
  if cobrador is null then cobrador := asignado; end if;

  for ped in
    select p.*,
           b.total          as total_pedido,
           b.saldo_anterior as saldo_ant
      from pedidos p
      join boletas b on b.pedido_id = p.id
     where p.hoja_ruta_id = p_hoja_id
  loop

    if ped.entregado = false then
      tot_ne := tot_ne + coalesce(ped.total_pedido, 0) + coalesce(ped.saldo_ant, 0);
      update pedidos set
        hoja_ruta_id  = null,
        fecha_reparto = fecha_reparto + 1,
        estado        = 'confirmado',
        entregado     = null,
        motivo_no_entrega = null,
        monto_efectivo = 0, monto_transf = 0, monto_cuenta = 0
      where id = ped.id;
      continue;
    end if;

    if coalesce(ped.total_pedido, 0) > 0 then
      insert into mov_cuenta (empresa_id, cliente_id, tipo, monto, forma_pago,
        referencia, referencia_tipo, usuario_id)
      values (emp_id, ped.cliente_id, 'cargo', coalesce(ped.total_pedido, 0),
        'cuenta_corriente', ped.id, 'hoja_ruta', cobrador);
    end if;

    if ped.monto_efectivo > 0 then
      insert into mov_cuenta (empresa_id, cliente_id, tipo, monto, forma_pago,
        referencia, referencia_tipo, usuario_id)
      values (emp_id, ped.cliente_id, 'pago', -ped.monto_efectivo,
        'efectivo', ped.id, 'hoja_ruta', cobrador);
      tot_ef := tot_ef + ped.monto_efectivo;
    end if;

    if ped.monto_transf > 0 then
      insert into mov_cuenta (empresa_id, cliente_id, tipo, monto, forma_pago,
        referencia, referencia_tipo, usuario_id,
        comprobante_url, referencia_externa, beneficiario_id)
      values (emp_id, ped.cliente_id, 'pago', -ped.monto_transf,
        'transferencia', ped.id, 'hoja_ruta', cobrador,
        ped.comprobante_transf_url, ped.referencia_transf, ped.beneficiario_transf_id);
      tot_tr := tot_tr + ped.monto_transf;
    end if;

    if ped.monto_cuenta > 0 then
      tot_cc := tot_cc + ped.monto_cuenta;
    end if;

    update pedidos set
      forma_pago = case
        when ped.monto_efectivo > 0 and ped.monto_transf > 0 then 'mixto'::forma_pago
        when ped.monto_efectivo > 0 then 'efectivo'::forma_pago
        when ped.monto_transf   > 0 then 'transferencia'::forma_pago
        else 'cuenta_corriente'::forma_pago
      end,
      estado = 'entregado'
    where id = ped.id;
  end loop;

  update hojas_ruta
     set total_efectivo = tot_ef,
         total_transf   = tot_tr,
         total_cuenta   = tot_cc,
         total_no_entregado = tot_ne,
         estado = 'cerrada',
         cerrada_en = now(),
         cerrada_por_usuario_id = coalesce(cobrador, asignado)
   where id = p_hoja_id;
end;
$$;
