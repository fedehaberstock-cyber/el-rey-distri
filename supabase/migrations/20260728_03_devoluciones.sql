-- ═══ Devoluciones de clientes ═════════════════════════════════════════════
-- Registra una devolución como una "venta negativa":
--   - pedido con estado='devolucion', total negativo
--   - pedido_items con cantidad negativa (para que reportes de venta resten)
--   - boleta con total negativo
--   - mov_stock 'devolucion' (positivo) solo para items con reingresa_stock=true
--   - mov_cuenta 'ajuste' con monto negativo (crédito a favor del cliente)
-- Requiere agregar 'devolucion' al enum estado_pedido.

alter type public.estado_pedido add value if not exists 'devolucion';

comment on type public.estado_pedido is
  'Estados: borrador, confirmado, entregado, no_entregado, postergado, anulado, devolucion (venta negativa).';

create or replace function public.crear_devolucion(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_empresa_id   uuid;
  v_usuario_id   uuid;
  v_cliente_id   uuid;
  v_obs          text;
  v_items        jsonb;
  v_item         jsonb;
  v_pedido_id    uuid;
  v_boleta_id    uuid;
  v_total        numeric := 0;
  v_subtotal     numeric;
  v_cant         integer;
  v_precio       numeric;
begin
  select id, empresa_id into v_usuario_id, v_empresa_id
  from usuarios where auth_id = auth.uid() limit 1;
  if v_usuario_id is null then raise exception 'usuario no autenticado'; end if;

  v_cliente_id := (p_payload->>'cliente_id')::uuid;
  v_obs        := p_payload->>'observaciones';
  v_items      := p_payload->'items';

  if v_cliente_id is null then raise exception 'cliente_id requerido'; end if;
  if jsonb_array_length(v_items) = 0 then raise exception 'al menos un item es requerido'; end if;

  -- total (negativo)
  for v_item in select * from jsonb_array_elements(v_items) loop
    v_cant   := abs((v_item->>'cantidad')::integer);
    v_precio := (v_item->>'precio_unit')::numeric;
    v_subtotal := v_cant * v_precio;
    v_total := v_total + v_subtotal;
  end loop;
  v_total := -abs(v_total);   -- garantizar negativo

  -- 1) pedido (estado=devolucion, total del pedido es implícito por los items)
  insert into pedidos
    (empresa_id, cliente_id, usuario_id, fecha, estado, observaciones,
     fecha_reparto, monto_efectivo, monto_transf, monto_cuenta)
  values
    (v_empresa_id, v_cliente_id, v_usuario_id, now(), 'devolucion', v_obs,
     current_date, 0, 0, 0)
  returning id into v_pedido_id;

  -- 2) items con cantidad NEGATIVA (para que reportes de venta resten)
  --    + reingreso opcional al stock
  for v_item in select * from jsonb_array_elements(v_items) loop
    v_cant   := abs((v_item->>'cantidad')::integer);
    v_precio := (v_item->>'precio_unit')::numeric;

    insert into pedido_items
      (empresa_id, pedido_id, producto_id, cantidad, precio_unit, descuento, es_bulto, u_por_bulto)
    values
      (v_empresa_id, v_pedido_id,
       (v_item->>'producto_id')::uuid,
       -v_cant,           -- cantidad negativa
       v_precio,
       0, false, 1);

    if coalesce((v_item->>'reingresa_stock')::boolean, true) then
      insert into mov_stock
        (empresa_id, producto_id, tipo, cantidad, referencia, referencia_tipo, usuario_id)
      values
        (v_empresa_id, (v_item->>'producto_id')::uuid, 'devolucion',
         v_cant, v_pedido_id, 'devolucion', v_usuario_id);
    end if;
  end loop;

  -- 3) boleta con total negativo
  insert into boletas
    (empresa_id, pedido_id, fecha, total, estado, saldo_anterior, total_a_cobrar)
  values
    (v_empresa_id, v_pedido_id, now(), v_total, 'emitida', 0, v_total)
  returning id into v_boleta_id;

  -- 4) mov_cuenta ajuste negativo (crédito a favor del cliente)
  insert into mov_cuenta
    (empresa_id, cliente_id, tipo, monto, forma_pago,
     referencia, referencia_tipo, usuario_id)
  values
    (v_empresa_id, v_cliente_id, 'ajuste', v_total, null,
     v_pedido_id, 'devolucion', v_usuario_id);

  return jsonb_build_object(
    'pedido_id', v_pedido_id,
    'boleta_id', v_boleta_id,
    'total',     v_total
  );
end;
$$;

grant execute on function public.crear_devolucion(jsonb) to authenticated;
