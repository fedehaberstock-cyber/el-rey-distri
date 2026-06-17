-- ═══ Snapshot del costo al momento de la venta ═══
-- Agrega costo_unit_snapshot a pedido_items y lo populea en confirmar_pedido
-- y editar_boleta. Permite calcular ganancia historica precisa aunque los
-- costos cambien con el tiempo. Pedidos viejos quedan con el costo actual
-- (lo mejor que se puede sin haber tenido el campo antes).

-- 1. Columna nueva
alter table public.pedido_items
  add column if not exists costo_unit_snapshot numeric(12,2);

-- 2. Backfill: los items viejos toman el costo actual del producto
update public.pedido_items pi
   set costo_unit_snapshot = p.costo
  from public.productos p
 where pi.producto_id = p.id
   and pi.costo_unit_snapshot is null;

-- 3. confirmar_pedido con snapshot
create or replace function public.confirmar_pedido(p_payload jsonb)
returns jsonb
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_empresa_id   uuid;
  v_usuario_id   uuid;
  v_cliente_id   uuid;
  v_descuento    numeric;
  v_obs          text;
  v_items        jsonb;
  v_item         jsonb;
  v_pedido_id    uuid;
  v_boleta_id    uuid;
  v_total        numeric := 0;
  v_subtotal     numeric;
  v_saldo_ant    numeric := 0;
  v_prod_id      uuid;
  v_cant         integer;
  v_stock_actual numeric;
  v_prod_nombre  text;
  v_fecha_rep    date := coalesce(
                          (p_payload->>'fecha_reparto')::date,
                          (now() at time zone 'America/Argentina/Cordoba')::date + 1
                        );
begin
  select id, empresa_id into v_usuario_id, v_empresa_id
  from usuarios where auth_id = auth.uid() limit 1;

  if v_usuario_id is null then raise exception 'usuario no autenticado'; end if;

  v_cliente_id := (p_payload->>'cliente_id')::uuid;
  v_descuento  := coalesce((p_payload->>'descuento')::numeric, 0);
  v_obs        := p_payload->>'observaciones';
  v_items      := p_payload->'items';

  if v_cliente_id is null then raise exception 'cliente_id requerido'; end if;
  if jsonb_array_length(v_items) = 0 then raise exception 'al menos un item es requerido'; end if;

  -- validacion de stock por item agrupado por producto
  for v_prod_id, v_cant in
    select (v->>'producto_id')::uuid, sum((v->>'cantidad')::integer)
      from jsonb_array_elements(v_items) v
     group by (v->>'producto_id')::uuid
  loop
    select coalesce(stock, 0) into v_stock_actual
      from stock_actual where producto_id = v_prod_id;
    if v_stock_actual is null then v_stock_actual := 0; end if;

    if v_stock_actual < v_cant then
      select nombre into v_prod_nombre from productos where id = v_prod_id;
      raise exception 'Sin stock suficiente para %. Disponible: %, pedido: %.',
        coalesce(v_prod_nombre, 'producto'),
        v_stock_actual::int, v_cant
        using errcode = 'P0001';
    end if;
  end loop;

  for v_item in select * from jsonb_array_elements(v_items) loop
    v_subtotal := (v_item->>'cantidad')::numeric
                * (v_item->>'precio_unit')::numeric
                * (1 - coalesce((v_item->>'descuento')::numeric, 0) / 100);
    v_total := v_total + v_subtotal;
  end loop;
  v_total := v_total * (1 - v_descuento / 100);

  v_saldo_ant := coalesce(
    (select coalesce(saldo, 0) from saldo_actual where cliente_id = v_cliente_id),
    0
  );
  if v_saldo_ant < 0 then v_saldo_ant := 0; end if;

  insert into pedidos
    (empresa_id, cliente_id, usuario_id, fecha, fecha_reparto, estado, descuento, observaciones,
     monto_efectivo, monto_transf, monto_cuenta)
  values
    (v_empresa_id, v_cliente_id, v_usuario_id, now(), v_fecha_rep, 'confirmado',
     v_descuento, v_obs, 0, 0, 0)
  returning id into v_pedido_id;

  for v_item in select * from jsonb_array_elements(v_items) loop
    insert into pedido_items
      (empresa_id, pedido_id, producto_id, cantidad, precio_unit, descuento,
       es_bulto, u_por_bulto, costo_unit_snapshot)
    values
      (v_empresa_id, v_pedido_id,
       (v_item->>'producto_id')::uuid,
       (v_item->>'cantidad')::integer,
       (v_item->>'precio_unit')::numeric,
       coalesce((v_item->>'descuento')::numeric, 0),
       coalesce((v_item->>'es_bulto')::boolean, false),
       (v_item->>'u_por_bulto')::integer,
       (select costo from productos where id = (v_item->>'producto_id')::uuid));

    insert into mov_stock
      (empresa_id, producto_id, tipo, cantidad, referencia, referencia_tipo, usuario_id)
    values
      (v_empresa_id,
       (v_item->>'producto_id')::uuid,
       'venta',
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
    'total',     v_total,
    'saldo_anterior', v_saldo_ant,
    'total_a_cobrar', v_total + v_saldo_ant,
    'fecha_reparto',  v_fecha_rep
  );
end;
$$;

-- 4. editar_boleta con snapshot
create or replace function public.editar_boleta(p_payload jsonb)
returns jsonb
language plpgsql security definer
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

  delete from mov_stock
   where referencia_tipo = 'pedido' and referencia = v_pedido_id;
  delete from pedido_items where pedido_id = v_pedido_id;

  for v_item in select * from jsonb_array_elements(v_items) loop
    insert into pedido_items
      (empresa_id, pedido_id, producto_id, cantidad, precio_unit, descuento,
       es_bulto, u_por_bulto, costo_unit_snapshot)
    values
      (v_empresa_id, v_pedido_id,
       (v_item->>'producto_id')::uuid,
       (v_item->>'cantidad')::integer,
       (v_item->>'precio_unit')::numeric,
       coalesce((v_item->>'descuento')::numeric, 0),
       coalesce((v_item->>'es_bulto')::boolean, false),
       (v_item->>'u_por_bulto')::integer,
       (select costo from productos where id = (v_item->>'producto_id')::uuid));

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
