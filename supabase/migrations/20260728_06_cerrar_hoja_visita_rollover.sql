-- ═══ Fix: cerrar_hoja_ruta vuelve a registrar visita no_entregado al rollear ══
-- La versión 20260624_02 (comprobante_por_pedido) reescribió cerrar_hoja_ruta
-- y en el camino perdió el insert into visitas_clientes que hacía la versión
-- 20260615_04. Sin ese registro no queda trazabilidad del rollover y la
-- pantalla Pendientes no puede distinguir un pedido rolleado a mañana de
-- uno recién creado para mañana.

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

    -- NO ENTREGADO: registrar visita para trazabilidad + rollover al día siguiente
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
        referencia, referencia_tipo, usuario_id,
        comprobante_url, referencia_externa)
      values (emp_id, ped.cliente_id, 'pago', -ped.monto_transf,
        'transferencia', ped.id, 'hoja_ruta', cobrador,
        ped.comprobante_transf_url, ped.referencia_transf);
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
    cerrada_en          = now(),
    cerrada_por_usuario_id = coalesce(cobrador, asignado)
  where id = p_hoja_id;
end;
$$;

-- Backfill: para pedidos con fecha_reparto futura sin visita registrada,
-- si su fecha original (pedidos.fecha::date) es < fecha_reparto - 1, es rolleado.
-- Insertamos la visita para que la pantalla Pendientes los detecte.
insert into visitas_clientes (empresa_id, cliente_id, usuario_id, resultado, motivo, pedido_id, fecha)
select p.empresa_id, p.cliente_id, p.usuario_id, 'no_entregado', null, p.id, p.fecha::date
  from pedidos p
 where p.estado in ('confirmado','postergado')
   and p.fecha_reparto is not null
   and p.fecha::date < p.fecha_reparto - 1
   and not exists (
     select 1 from visitas_clientes v
      where v.pedido_id = p.id and v.resultado = 'no_entregado'
   );
