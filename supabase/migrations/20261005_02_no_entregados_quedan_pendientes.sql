-- ═══ No entregados: quedan en Pendientes + registro en la hoja cerrada ═══
-- Antes: al cerrar la hoja, un pedido no entregado se pasaba solo al día
-- siguiente (fecha_reparto + 1) y desaparecía de la hoja (hoja_ruta_id = null),
-- igual que los cancelados por el repartidor. La hoja cerrada no dejaba rastro.
-- Ahora:
--   * no entregado → fecha_reparto = null: queda en Pendientes hasta que
--     alguien le asigne fecha. Se conserva el motivo.
--   * no entregado y cancelado → la visita 'no_entregado' guarda hoja_ruta_id,
--     así la hoja cerrada puede listarlos con su motivo.

alter table public.visitas_clientes
  add column if not exists hoja_ruta_id uuid references public.hojas_ruta(id) on delete set null;

create index if not exists idx_visitas_hoja on public.visitas_clientes(hoja_ruta_id)
  where hoja_ruta_id is not null;

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

    -- NO ENTREGADO: registro en la hoja + queda en Pendientes sin fecha
    if ped.entregado = false then
      tot_ne := tot_ne + coalesce(ped.total_pedido, 0) + coalesce(ped.saldo_ant, 0);

      insert into visitas_clientes (empresa_id, cliente_id, usuario_id, resultado, motivo, pedido_id, hoja_ruta_id)
      values (emp_id, ped.cliente_id, coalesce(cobrador, ped.usuario_id), 'no_entregado',
              nullif(btrim(coalesce(ped.motivo_no_entrega,'')), ''), ped.id, p_hoja_id);

      update pedidos set
        hoja_ruta_id  = null,
        fecha_reparto = null,
        estado        = 'confirmado',
        entregado     = null,
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

-- anular_pedido: igual a 20261005_01, pero la visita guarda la hoja de la
-- que se canceló (se lee antes de desvincular el pedido).
create or replace function public.anular_pedido(p_pedido_id uuid, p_motivo text default null)
returns void
language plpgsql security definer
set search_path = 'public'
as $$
declare
  v_emp uuid; v_cli uuid; v_usr uuid; v_hoja uuid; it record;
  v_mot text := nullif(btrim(coalesce(p_motivo,'')), '');
begin
  select empresa_id, cliente_id, usuario_id, hoja_ruta_id into v_emp, v_cli, v_usr, v_hoja
    from pedidos where id = p_pedido_id;
  if v_emp is null then raise exception 'pedido no existe'; end if;

  for it in select producto_id, cantidad from pedido_items where pedido_id = p_pedido_id loop
    insert into mov_stock (empresa_id, producto_id, tipo, cantidad, referencia, referencia_tipo, usuario_id)
    values (v_emp, it.producto_id, 'devolucion', it.cantidad, p_pedido_id, 'anulacion', v_usr);
  end loop;

  delete from mov_cuenta where referencia = p_pedido_id;

  insert into visitas_clientes (empresa_id, cliente_id, usuario_id, resultado, motivo, pedido_id, hoja_ruta_id)
  values (v_emp, v_cli, v_usr, 'no_entregado', v_mot, p_pedido_id, v_hoja);

  update pedidos set
    estado = 'anulado', entregado = false, hoja_ruta_id = null,
    motivo_no_entrega = v_mot,
    monto_efectivo = 0, monto_transf = 0, monto_cuenta = 0
  where id = p_pedido_id;

  update boletas set estado = 'anulada' where pedido_id = p_pedido_id;
end $$;
