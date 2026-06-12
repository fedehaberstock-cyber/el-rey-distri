-- ─────────────────────────────────────────────────────────────────────────
-- confirmar_pedido auto-genera (o reusa) la hoja_ruta del día de reparto y
-- linkea el pedido. Así la hoja del día de entrega se arma desde el día
-- anterior, al cargar los pedidos.
-- ─────────────────────────────────────────────────────────────────────────

create or replace function confirmar_pedido(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cliente_id   uuid := (p_payload->>'cliente_id')::uuid;
  v_descuento    numeric := coalesce((p_payload->>'descuento')::numeric, 0);
  v_obs          text := p_payload->>'observaciones';
  v_items        jsonb := p_payload->'items';
  v_fecha_rep    date  := coalesce(
                            (p_payload->>'fecha_reparto')::date,
                            (now() at time zone 'America/Argentina/Cordoba')::date + 1
                          );
  v_usuario_id   uuid;
  v_empresa_id   uuid;
  v_pedido_id    uuid;
  v_boleta_id    uuid;
  v_hoja_id      uuid;
  v_total        numeric := 0;
  v_subtotal     numeric;
  v_saldo_ant    numeric;
  v_item         jsonb;
begin
  select id, empresa_id into v_usuario_id, v_empresa_id
    from usuarios where auth_id = auth.uid();
  if v_usuario_id is null then raise exception 'Usuario no encontrado'; end if;

  for v_item in select * from jsonb_array_elements(v_items) loop
    v_subtotal := (v_item->>'cantidad')::numeric
                * (v_item->>'precio_unit')::numeric
                * (1 - coalesce((v_item->>'descuento')::numeric, 0)/100);
    v_total := v_total + v_subtotal;
  end loop;
  v_total := v_total * (1 - v_descuento/100);

  select coalesce(saldo, 0) into v_saldo_ant
    from saldo_actual where cliente_id = v_cliente_id;
  if v_saldo_ant is null or v_saldo_ant < 0 then v_saldo_ant := 0; end if;

  -- buscar (o crear) la hoja_ruta abierta del día de reparto
  select id into v_hoja_id
    from hojas_ruta
   where empresa_id = v_empresa_id
     and fecha = v_fecha_rep
     and estado <> 'cerrada'
   limit 1;

  if v_hoja_id is null then
    insert into hojas_ruta (empresa_id, usuario_id, fecha, estado)
    values (v_empresa_id, v_usuario_id, v_fecha_rep, 'pendiente')
    returning id into v_hoja_id;
  end if;

  -- pedido (ya linkeado a la hoja)
  insert into pedidos
    (empresa_id, cliente_id, usuario_id, fecha, fecha_reparto, hoja_ruta_id,
     estado, descuento, observaciones, monto_efectivo, monto_transf, monto_cuenta)
  values
    (v_empresa_id, v_cliente_id, v_usuario_id, now(), v_fecha_rep, v_hoja_id,
     'confirmado', v_descuento, v_obs, 0, 0, 0)
  returning id into v_pedido_id;

  for v_item in select * from jsonb_array_elements(v_items) loop
    insert into pedido_items
      (empresa_id, pedido_id, producto_id, cantidad, precio_unit, descuento,
       es_bulto, u_por_bulto)
    values
      (v_empresa_id, v_pedido_id,
       (v_item->>'producto_id')::uuid,
       (v_item->>'cantidad')::integer,
       (v_item->>'precio_unit')::numeric,
       coalesce((v_item->>'descuento')::numeric, 0),
       coalesce((v_item->>'es_bulto')::boolean, false),
       (v_item->>'u_por_bulto')::integer);

    insert into mov_stock
      (empresa_id, producto_id, tipo, cantidad, referencia, referencia_tipo, usuario_id)
    values
      (v_empresa_id, (v_item->>'producto_id')::uuid, 'venta',
       -(v_item->>'cantidad')::integer,
       v_pedido_id, 'pedido', v_usuario_id);
  end loop;

  insert into boletas
    (empresa_id, pedido_id, fecha, total, estado, saldo_anterior, total_a_cobrar)
  values
    (v_empresa_id, v_pedido_id, now(), v_total, 'emitida',
     v_saldo_ant, v_total + v_saldo_ant)
  returning id into v_boleta_id;

  return jsonb_build_object(
    'pedido_id', v_pedido_id,
    'boleta_id', v_boleta_id,
    'hoja_ruta_id', v_hoja_id,
    'total', v_total,
    'fecha_reparto', v_fecha_rep
  );
end;
$$;
