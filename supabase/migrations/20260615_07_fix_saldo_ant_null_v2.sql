-- ── Fix (regresión): confirmar_pedido vuelve a fallar con clientes sin movimientos ──
-- La migración 20260615_05 reescribió confirmar_pedido para validar stock y, en el
-- camino, perdió el fix de 20260611_06: con SELECT INTO sobre la view saldo_actual,
-- si el cliente no tiene movimientos no se asigna nada y v_saldo_ant queda NULL,
-- rompiendo el NOT NULL de boletas.saldo_anterior.
-- Volvemos a aplicar el patrón: inicializar v_saldo_ant := 0 y usar subquery escalar
-- envuelta en coalesce, que sí cubre el caso "cero filas".

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
  v_saldo_ant    numeric := 0;   -- ← inicializar en 0
  v_prod_id      uuid;
  v_cant         integer;
  v_stock_actual numeric;
  v_prod_nombre  text;
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

  -- validación de stock por ítem (agrupando por producto)
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

  -- total
  for v_item in select * from jsonb_array_elements(v_items) loop
    v_subtotal := (v_item->>'cantidad')::numeric
                * (v_item->>'precio_unit')::numeric
                * (1 - coalesce((v_item->>'descuento')::numeric, 0) / 100);
    v_total := v_total + v_subtotal;
  end loop;
  v_total := v_total * (1 - v_descuento / 100);

  -- saldo previo — subquery escalar con coalesce externo cubre el caso "cero filas"
  v_saldo_ant := coalesce(
    (select coalesce(saldo, 0) from saldo_actual where cliente_id = v_cliente_id),
    0
  );
  if v_saldo_ant < 0 then v_saldo_ant := 0; end if;

  insert into pedidos
    (empresa_id, cliente_id, usuario_id, fecha, estado, descuento, observaciones,
     monto_efectivo, monto_transf, monto_cuenta)
  values
    (v_empresa_id, v_cliente_id, v_usuario_id, now(), 'confirmado',
     v_descuento, v_obs, 0, 0, 0)
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
    'total_a_cobrar', v_total + v_saldo_ant
  );
end;
$$;
