-- ═══ Quien cierra la hoja ═══
-- Antes: los cobros se grababan con hojas_ruta.usuario_id (a quien estaba
-- ASIGNADA la hoja). Si Seba cerraba una hoja de Fede, recaudacion mostraba
-- Fede igual. Ahora: el cobrador en mov_cuenta es el usuario que realmente
-- ejecuta el cierre (auth.uid()), y se guarda en hojas_ruta.cerrada_por_usuario_id.

alter table public.hojas_ruta
  add column if not exists cerrada_por_usuario_id uuid references public.usuarios(id);

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
  cobrado_total numeric;
  contra_saldo  numeric;
  contra_pedido numeric;
begin
  select empresa_id, usuario_id into emp_id, asignado
    from hojas_ruta where id = p_hoja_id;

  -- Cobrador real = usuario actual que ejecuta el cierre.
  -- Si no hay sesion (ej. cierre llamado desde otro RPC sin auth), cae al asignado.
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

    cobrado_total := coalesce(ped.monto_efectivo,0)
                   + coalesce(ped.monto_transf,0)
                   + coalesce(ped.monto_cuenta,0);

    contra_saldo  := least(cobrado_total, coalesce(ped.saldo_ant, 0));
    contra_pedido := greatest(cobrado_total - contra_saldo, 0);

    if ped.monto_efectivo > 0 then
      insert into mov_cuenta (empresa_id, cliente_id, tipo, monto, forma_pago,
        referencia, referencia_tipo, usuario_id)
      values (emp_id, ped.cliente_id, 'pago', -ped.monto_efectivo,
        'efectivo', ped.id, 'hoja_ruta', cobrador);
      tot_ef := tot_ef + ped.monto_efectivo;
    end if;

    if ped.monto_transf > 0 then
      insert into mov_cuenta (empresa_id, cliente_id, tipo, monto, forma_pago,
        referencia, referencia_tipo, usuario_id)
      values (emp_id, ped.cliente_id, 'pago', -ped.monto_transf,
        'transferencia', ped.id, 'hoja_ruta', cobrador);
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
        when ped.monto_cuenta   > 0 then 'cuenta_corriente'::forma_pago
        else null end,
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
