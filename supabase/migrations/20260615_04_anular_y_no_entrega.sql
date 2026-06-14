-- ═══════════════════════════════════════════════════════════════════════
-- Combo: trazabilidad de no-entrega + anular pedido (rechazado)
--   1) visitas_clientes admite resultado 'no_entregado'
--   2) anular_pedido(): devuelve stock, revierte cuenta, registra rechazo
--   3) cerrar_hoja_ruta(): guarda el motivo del no-entregado antes del rollover
-- ═══════════════════════════════════════════════════════════════════════

-- 1) permitir 'no_entregado'
alter table public.visitas_clientes drop constraint if exists visitas_clientes_resultado_check;
alter table public.visitas_clientes add constraint visitas_clientes_resultado_check
  check (resultado in ('pedido','sin_pedido','no_entregado'));

-- 2) anular_pedido: cliente rechazó el pedido (no lo quiere)
--    - devuelve el stock (mov_stock 'devolucion')
--    - revierte cualquier cargo/pago en cuenta del pedido
--    - registra el rechazo como visita 'no_entregado'
--    - marca el pedido 'anulado' y lo desvincula de la hoja
--    Resultado: no suma a ventas/comisión y el stock vuelve.
create or replace function public.anular_pedido(p_pedido_id uuid, p_motivo text default null)
returns void
language plpgsql security definer
set search_path = 'public'
as $$
declare
  v_emp uuid; v_cli uuid; v_usr uuid; it record;
  v_mot text := nullif(btrim(coalesce(p_motivo,'')), '');
begin
  select empresa_id, cliente_id, usuario_id into v_emp, v_cli, v_usr
    from pedidos where id = p_pedido_id;
  if v_emp is null then raise exception 'pedido no existe'; end if;

  -- 1. devolver stock por cada ítem
  for it in select producto_id, cantidad from pedido_items where pedido_id = p_pedido_id loop
    insert into mov_stock (empresa_id, producto_id, tipo, cantidad, referencia, referencia_tipo, usuario_id)
    values (v_emp, it.producto_id, 'devolucion', it.cantidad, p_pedido_id, 'anulacion', v_usr);
  end loop;

  -- 2. revertir cuenta corriente del pedido (si ya se había cargado/cobrado)
  delete from mov_cuenta where referencia = p_pedido_id;

  -- 3. registrar el rechazo como visita (trazabilidad del cliente que rebota)
  insert into visitas_clientes (empresa_id, cliente_id, usuario_id, resultado, motivo, pedido_id)
  values (v_emp, v_cli, v_usr, 'no_entregado', v_mot, p_pedido_id);

  -- 4. anular y desvincular
  update pedidos set
    estado = 'anulado', entregado = false, hoja_ruta_id = null,
    motivo_no_entrega = v_mot,
    monto_efectivo = 0, monto_transf = 0, monto_cuenta = 0
  where id = p_pedido_id;
end $$;

-- 3) cerrar_hoja_ruta: idéntica a la versión vigente, pero al hacer rollover
--    de un no-entregado guarda una visita 'no_entregado' con el motivo.
create or replace function cerrar_hoja_ruta(p_hoja_id uuid) returns void
language plpgsql security definer
set search_path = 'public'
as $$
declare
  ped           record;
  emp_id        uuid;
  cobrador      uuid;
  tot_ef        numeric := 0;
  tot_tr        numeric := 0;
  tot_cc        numeric := 0;
  tot_ne        numeric := 0;
begin
  select empresa_id, usuario_id into emp_id, cobrador
    from hojas_ruta where id = p_hoja_id;

  for ped in
    select p.*,
           b.total          as total_pedido,
           b.saldo_anterior as saldo_ant
      from pedidos p
      join boletas b on b.pedido_id = p.id
     where p.hoja_ruta_id = p_hoja_id
  loop

    -- NO ENTREGADO: registrar intento fallido, rollover al día siguiente
    if ped.entregado = false then
      tot_ne := tot_ne + coalesce(ped.total_pedido, 0) + coalesce(ped.saldo_ant, 0);

      insert into visitas_clientes (empresa_id, cliente_id, usuario_id, resultado, motivo, pedido_id)
      values (emp_id, ped.cliente_id, coalesce(cobrador, ped.usuario_id), 'no_entregado',
              nullif(btrim(coalesce(ped.motivo_no_entrega,'')), ''), ped.id);

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

    -- 1. CARGO de la venta
    if coalesce(ped.total_pedido, 0) > 0 then
      insert into mov_cuenta (empresa_id, cliente_id, tipo, monto, forma_pago,
        referencia, referencia_tipo, usuario_id)
      values (emp_id, ped.cliente_id, 'cargo', coalesce(ped.total_pedido, 0),
        'cuenta_corriente', ped.id, 'hoja_ruta', cobrador);
    end if;

    -- 2. PAGOS recibidos
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
        else 'cuenta_corriente'::forma_pago
      end,
      estado = 'entregado'
    where id = ped.id;

  end loop;

  update hojas_ruta set
    total_efectivo      = tot_ef,
    total_transf        = tot_tr,
    total_cuenta        = tot_cc,
    total_no_entregado  = tot_ne,
    estado              = 'cerrada',
    cerrada_en          = now()
  where id = p_hoja_id;
end;
$$;
