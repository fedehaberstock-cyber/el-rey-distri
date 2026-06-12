-- ─────────────────────────────────────────────────────────────────────────
-- Editar boleta ya emitida: reescribe items, descuento, cliente y fecha de
-- reparto del pedido subyacente, recalcula totales y marca la boleta como
-- 'modificada'. Atómica.
--
-- Reglas de permiso:
--   - admin / deposito  → siempre (mientras la hoja_ruta no esté cerrada)
--   - preventista       → solo si es el creador del pedido, hoja abierta,
--                         y antes de las 14:00 hora Córdoba del día en que
--                         se cargó el pedido.
-- ─────────────────────────────────────────────────────────────────────────

create or replace function editar_boleta(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_boleta_id    uuid := (p_payload->>'boleta_id')::uuid;
  v_cliente_id   uuid := (p_payload->>'cliente_id')::uuid;
  v_descuento    numeric := coalesce((p_payload->>'descuento')::numeric, 0);
  v_obs          text := p_payload->>'observaciones';
  v_items        jsonb := p_payload->'items';
  v_fecha_rep    date  := (p_payload->>'fecha_reparto')::date;
  v_usuario_id   uuid;
  v_empresa_id   uuid;
  v_rol          text;
  v_pedido_id    uuid;
  v_pedido_user  uuid;
  v_pedido_fecha timestamptz;
  v_hoja_estado  text;
  v_total        numeric := 0;
  v_subtotal     numeric;
  v_saldo_ant    numeric;
  v_item         jsonb;
  v_ahora_arg    timestamp;
  v_limite       timestamp;
begin
  select id, empresa_id, rol into v_usuario_id, v_empresa_id, v_rol
    from usuarios where auth_id = auth.uid();
  if v_usuario_id is null then raise exception 'Usuario no encontrado'; end if;

  select pedido_id, saldo_anterior into v_pedido_id, v_saldo_ant
    from boletas where id = v_boleta_id and empresa_id = v_empresa_id;
  if v_pedido_id is null then raise exception 'Boleta no encontrada'; end if;

  select usuario_id, fecha, (select estado::text from hojas_ruta where id = p.hoja_ruta_id)
    into v_pedido_user, v_pedido_fecha, v_hoja_estado
    from pedidos p where p.id = v_pedido_id;

  if v_hoja_estado = 'cerrada' then
    raise exception 'La hoja de ruta ya está cerrada — no se puede editar';
  end if;

  if v_rol = 'preventista' then
    if v_pedido_user <> v_usuario_id then
      raise exception 'Solo podés editar boletas propias';
    end if;
    v_ahora_arg := (now() at time zone 'America/Argentina/Cordoba');
    v_limite := ((v_pedido_fecha at time zone 'America/Argentina/Cordoba')::date + interval '14 hours');
    if v_ahora_arg > v_limite then
      raise exception 'No se puede editar después de las 14:00 del día de carga';
    end if;
  elsif v_rol not in ('admin','deposito') then
    raise exception 'Rol sin permiso para editar boletas';
  end if;

  -- limpiar items y movimientos de stock previos
  delete from mov_stock
   where referencia_tipo = 'pedido' and referencia = v_pedido_id;
  delete from pedido_items where pedido_id = v_pedido_id;

  -- reinsertar items + mov_stock + acumular total
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

    v_subtotal := (v_item->>'cantidad')::numeric
                * (v_item->>'precio_unit')::numeric
                * (1 - coalesce((v_item->>'descuento')::numeric, 0)/100);
    v_total := v_total + v_subtotal;

    insert into mov_stock
      (empresa_id, producto_id, tipo, cantidad, referencia, referencia_tipo, usuario_id)
    values
      (v_empresa_id, (v_item->>'producto_id')::uuid, 'venta',
       -(v_item->>'cantidad')::integer,
       v_pedido_id, 'pedido', v_usuario_id);
  end loop;

  v_total := v_total * (1 - v_descuento/100);

  update pedidos
     set cliente_id = v_cliente_id,
         descuento = v_descuento,
         observaciones = v_obs,
         fecha_reparto = coalesce(v_fecha_rep, fecha_reparto)
   where id = v_pedido_id;

  if v_saldo_ant is null or v_saldo_ant < 0 then v_saldo_ant := 0; end if;
  update boletas
     set total = v_total,
         total_a_cobrar = v_total + v_saldo_ant,
         estado = 'modificada'
   where id = v_boleta_id;

  return jsonb_build_object(
    'boleta_id', v_boleta_id,
    'pedido_id', v_pedido_id,
    'total', v_total
  );
end;
$$;
