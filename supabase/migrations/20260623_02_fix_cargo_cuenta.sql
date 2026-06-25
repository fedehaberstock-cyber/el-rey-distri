-- ═══ Fix: cerrar_hoja_ruta perdio el insert del CARGO ═══
-- En 20260619_03_cerrador_hoja yo (Claude) me base en una version
-- vieja de cerrar_hoja_ruta y borre la linea que insertaba el cargo
-- en mov_cuenta. Resultado: desde que se corrio esa migration, las
-- hojas cerradas no acumulaban deuda en el cliente — solo los pagos.
--
-- Este archivo:
-- 1. Reescribe cerrar_hoja_ruta correctamente (cargo + pagos + cerrador real).
-- 2. Hace backfill de cargos faltantes en hojas ya cerradas sin cargo.

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

  -- Cobrador real = usuario actual; si no hay sesion, cae al asignado.
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

    -- 1. CARGO de la venta entregada (genera la deuda en el cliente).
    if coalesce(ped.total_pedido, 0) > 0 then
      insert into mov_cuenta (empresa_id, cliente_id, tipo, monto, forma_pago,
        referencia, referencia_tipo, usuario_id)
      values (emp_id, ped.cliente_id, 'cargo', coalesce(ped.total_pedido, 0),
        'cuenta_corriente', ped.id, 'hoja_ruta', cobrador);
    end if;

    -- 2. Pagos recibidos en la entrega.
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

    -- cuenta_corriente: ya queda implicito como (cargo - pagos).
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


-- ── Backfill de cargos faltantes ────────────────────────────────────────
-- Para cada pedido entregado en una hoja cerrada cuyo cargo no se haya
-- insertado, lo crea ahora con la fecha original de cierre de la hoja.
insert into mov_cuenta (empresa_id, cliente_id, tipo, monto, forma_pago,
  referencia, referencia_tipo, usuario_id, fecha)
select p.empresa_id, p.cliente_id, 'cargo', b.total,
       'cuenta_corriente', p.id, 'hoja_ruta',
       coalesce(h.cerrada_por_usuario_id, p.usuario_id),
       coalesce(h.cerrada_en, now())
  from pedidos p
  join boletas b on b.pedido_id = p.id
  join hojas_ruta h on h.id = p.hoja_ruta_id
 where p.estado = 'entregado'
   and h.estado = 'cerrada'
   and b.total > 0
   and not exists (
     select 1 from mov_cuenta mc
      where mc.referencia = p.id
        and mc.referencia_tipo = 'hoja_ruta'
        and mc.tipo = 'cargo'
   );
