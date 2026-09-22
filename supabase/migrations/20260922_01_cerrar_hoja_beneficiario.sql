-- ═══ Fix: cerrar_hoja_ruta vuelve a propagar el beneficiario de la transferencia ══
-- La versión 20260728_06 reescribió la función partiendo de una copia previa a
-- 20260702_01 y perdió `beneficiario_id` en el insert de mov_cuenta. El chofer
-- elegía el beneficiario (queda en pedidos.beneficiario_transf_id) pero el pago
-- se registraba sin él → aparecía "Sin asignar" en Transferencias.

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

-- Backfill: recuperar el beneficiario que el chofer eligió en las hojas ya cerradas.
update mov_cuenta m
   set beneficiario_id = p.beneficiario_transf_id
  from pedidos p
 where m.referencia = p.id
   and m.referencia_tipo = 'hoja_ruta'
   and m.tipo = 'pago'
   and m.forma_pago = 'transferencia'
   and m.beneficiario_id is null
   and p.beneficiario_transf_id is not null;
