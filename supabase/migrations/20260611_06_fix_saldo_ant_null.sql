-- ── Fix: confirmar_pedido falla cuando el cliente no tiene movimientos ───────
-- saldo_actual es una VIEW sobre mov_cuenta. Si no hay filas para ese cliente
-- la SELECT INTO no asigna nada y v_saldo_ant queda NULL.
-- Solución: usar subquery escalar con COALESCE para garantizar 0 cuando no hay filas.

create or replace function public.confirmar_pedido(p_payload jsonb)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare
  v_usuario_id   uuid;
  v_empresa_id   uuid;
  v_cliente_id   uuid;
  v_descuento    numeric;
  v_pedido_id    uuid;
  v_boleta_id    uuid;
  v_total        numeric := 0;
  v_subtotal     numeric;
  v_saldo_ant    numeric := 0;   -- ← inicializar en 0 por si no hay filas
  item           jsonb;
begin
  -- contexto del usuario actual
  select id, empresa_id into v_usuario_id, v_empresa_id
  from usuarios where auth_id = auth.uid() limit 1;

  if v_usuario_id is null then
    raise exception 'usuario no encontrado';
  end if;

  v_cliente_id := (p_payload->>'cliente_id')::uuid;
  v_descuento  := coalesce((p_payload->>'descuento')::numeric, 0);

  -- calcular total
  for item in select * from jsonb_array_elements(p_payload->'items') loop
    declare
      v_precio    numeric;
      v_cantidad  integer;
      v_desc_item numeric;
      v_es_bulto  boolean;
      v_u_bulto   integer;
    begin
      v_precio    := (item->>'precio_unit')::numeric;
      v_cantidad  := (item->>'cantidad')::integer;
      v_desc_item := coalesce((item->>'descuento')::numeric, 0);
      v_es_bulto  := coalesce((item->>'es_bulto')::boolean, false);
      v_u_bulto   := coalesce((item->>'u_por_bulto')::integer, 1);

      v_subtotal  := v_cantidad * v_precio * (1 - v_desc_item / 100);
      v_total     := v_total + v_subtotal;
    end;
  end loop;
  v_total := v_total * (1 - v_descuento / 100);

  -- saldo previo — usar subquery escalar para manejar cliente sin movimientos
  v_saldo_ant := coalesce(
    (select coalesce(saldo, 0) from saldo_actual where cliente_id = v_cliente_id),
    0
  );
  if v_saldo_ant < 0 then v_saldo_ant := 0; end if;

  -- 1. pedido
  insert into pedidos
    (empresa_id, cliente_id, usuario_id, fecha, estado, descuento, observaciones)
  values
    (v_empresa_id, v_cliente_id, v_usuario_id, now(), 'confirmado',
     v_descuento, p_payload->>'observaciones')
  returning id into v_pedido_id;

  -- 2. items + mov_stock
  for item in select * from jsonb_array_elements(p_payload->'items') loop
    declare
      v_prod_id   uuid;
      v_cantidad  integer;
      v_precio    numeric;
      v_desc_item numeric;
      v_es_bulto  boolean;
      v_u_bulto   integer;
    begin
      v_prod_id   := (item->>'producto_id')::uuid;
      v_cantidad  := (item->>'cantidad')::integer;
      v_precio    := (item->>'precio_unit')::numeric;
      v_desc_item := coalesce((item->>'descuento')::numeric, 0);
      v_es_bulto  := coalesce((item->>'es_bulto')::boolean, false);
      v_u_bulto   := coalesce((item->>'u_por_bulto')::integer, 1);

      insert into pedido_items
        (empresa_id, pedido_id, producto_id, cantidad, precio_unit, descuento, es_bulto, u_por_bulto)
      values
        (v_empresa_id, v_pedido_id, v_prod_id, v_cantidad, v_precio, v_desc_item, v_es_bulto, v_u_bulto);

      insert into mov_stock
        (empresa_id, producto_id, tipo, cantidad, referencia, referencia_tipo, usuario_id)
      values
        (v_empresa_id, v_prod_id, 'venta', -v_cantidad,
         v_pedido_id, 'pedido', v_usuario_id);
    end;
  end loop;

  -- 3. cargo en cuenta corriente
  insert into mov_cuenta
    (empresa_id, cliente_id, tipo, monto, referencia, referencia_tipo, usuario_id)
  values
    (v_empresa_id, v_cliente_id, 'cargo', v_total,
     v_pedido_id, 'pedido', v_usuario_id);

  -- 4. boleta
  insert into boletas
    (empresa_id, pedido_id, fecha, total, estado, saldo_anterior, total_a_cobrar)
  values
    (v_empresa_id, v_pedido_id, now(), v_total, 'emitida',
     v_saldo_ant, v_total + v_saldo_ant)
  returning id into v_boleta_id;

  return jsonb_build_object(
    'pedido_id',      v_pedido_id,
    'boleta_id',      v_boleta_id,
    'total',          v_total,
    'saldo_anterior', v_saldo_ant,
    'total_a_cobrar', v_total + v_saldo_ant
  );
end;
$$;
