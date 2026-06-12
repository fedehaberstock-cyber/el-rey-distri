-- ─────────────────────────────────────────────────────────────────────────
-- Bug fix: cerrar_hoja_ruta no insertaba el CARGO de la venta entregada.
-- Sin el cargo, la cuenta_corriente del cliente nunca acumulaba la deuda.
-- A partir de ahora, por cada pedido entregado se inserta un mov_cuenta
-- tipo 'cargo' con monto = total del pedido. Los pagos (efectivo/transf)
-- siguen insertándose como negativos. El neto define la deuda.
-- ─────────────────────────────────────────────────────────────────────────

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

    -- NO ENTREGADO: rollover al día siguiente y desvincular
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

    -- 1. CARGO de la venta (cliente debe ahora total_pedido)
    if coalesce(ped.total_pedido, 0) > 0 then
      insert into mov_cuenta (empresa_id, cliente_id, tipo, monto, forma_pago,
        referencia, referencia_tipo, usuario_id)
      values (emp_id, ped.cliente_id, 'cargo', coalesce(ped.total_pedido, 0),
        'cuenta_corriente', ped.id, 'hoja_ruta', cobrador);
    end if;

    -- 2. PAGOS recibidos en la entrega
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

    -- cuenta_corriente: ya quedó implícito como (cargo - pagos)
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

-- ─────────────────────────────────────────────────────────────────────────
-- Backfill: insertar cargos faltantes para hojas ya cerradas previamente
-- (pedidos entregados cuya venta no quedó registrada en mov_cuenta).
-- ─────────────────────────────────────────────────────────────────────────
insert into mov_cuenta (empresa_id, cliente_id, tipo, monto, forma_pago,
  referencia, referencia_tipo, usuario_id)
select p.empresa_id, p.cliente_id, 'cargo', b.total,
  'cuenta_corriente', p.id, 'hoja_ruta', p.usuario_id
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
