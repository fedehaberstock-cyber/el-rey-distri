-- ═══ Zonas: modo de reparto ═══════════════════════════════════════════════
-- 3 modos por zona:
--   dia_siguiente → fecha_reparto = current_date + 1 (flujo actual, default)
--   a_definir     → fecha_reparto NULL; el pedido queda pendiente de programar
--   no_reparte    → fecha_reparto NULL; solo retiro / consumo interno
-- Si el cliente no tiene zona asignada → tratamos como 'no_reparte'.

alter table public.zonas
  add column if not exists modo_reparto text
    not null default 'dia_siguiente'
    check (modo_reparto in ('dia_siguiente','a_definir','no_reparte'));

comment on column public.zonas.modo_reparto is
  'dia_siguiente: reparte automáticamente el día siguiente al pedido. a_definir: pedido queda pendiente de programar fecha. no_reparte: solo retiro / consumo interno.';

-- ── confirmar_pedido: resolver fecha_reparto según modo de zona del cliente ──
create or replace function public.confirmar_pedido(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_empresa_id   uuid;
  v_usuario_id   uuid;
  v_cliente_id   uuid;
  v_descuento    numeric;
  v_obs          text;
  v_fecha_rep    date;
  v_zona_modo    text;
  v_items        jsonb;
  v_item         jsonb;
  v_pedido_id    uuid;
  v_boleta_id    uuid;
  v_total        numeric := 0;
  v_subtotal     numeric;
  v_saldo_ant    numeric := 0;
  v_oferta_id    uuid;
begin
  select id, empresa_id into v_usuario_id, v_empresa_id
  from usuarios where auth_id = auth.uid() limit 1;

  if v_usuario_id is null then
    raise exception 'usuario no autenticado';
  end if;

  v_cliente_id := (p_payload->>'cliente_id')::uuid;
  v_descuento  := coalesce((p_payload->>'descuento')::numeric, 0);
  v_obs        := p_payload->>'observaciones';
  v_fecha_rep  := nullif(p_payload->>'fecha_reparto','')::date;
  v_items      := p_payload->'items';

  if v_cliente_id is null then raise exception 'cliente_id requerido'; end if;
  if jsonb_array_length(v_items) = 0 then raise exception 'al menos un item es requerido'; end if;

  -- Si no vino fecha explícita, la resolvemos por modo de zona del cliente.
  -- Cliente sin zona ⇒ tratamos como 'no_reparte'.
  if v_fecha_rep is null then
    select coalesce(z.modo_reparto, 'no_reparte')
      into v_zona_modo
      from clientes c
      left join zonas z on z.id = c.zona_id
     where c.id = v_cliente_id;

    if v_zona_modo = 'dia_siguiente' then
      v_fecha_rep := current_date + 1;
    end if;
    -- a_definir / no_reparte / cliente sin zona → queda NULL
  end if;

  -- total
  for v_item in select * from jsonb_array_elements(v_items) loop
    v_subtotal := (v_item->>'cantidad')::numeric
                * (v_item->>'precio_unit')::numeric
                * (1 - coalesce((v_item->>'descuento')::numeric, 0) / 100);
    v_total := v_total + v_subtotal;
  end loop;
  v_total := v_total * (1 - v_descuento / 100);

  -- saldo previo
  v_saldo_ant := coalesce(
    (select saldo from saldo_actual where cliente_id = v_cliente_id),
    0
  );
  if v_saldo_ant < 0 then v_saldo_ant := 0; end if;

  -- 1) pedido
  insert into pedidos
    (empresa_id, cliente_id, usuario_id, fecha, estado, descuento, observaciones,
     fecha_reparto, monto_efectivo, monto_transf, monto_cuenta)
  values
    (v_empresa_id, v_cliente_id, v_usuario_id, now(), 'confirmado',
     v_descuento, v_obs, v_fecha_rep, 0, 0, 0)
  returning id into v_pedido_id;

  -- 2) items + mov_stock + acumular stock_vendido por oferta
  for v_item in select * from jsonb_array_elements(v_items) loop
    v_oferta_id := nullif(v_item->>'oferta_id','')::uuid;

    insert into pedido_items
      (empresa_id, pedido_id, producto_id, cantidad, precio_unit, descuento,
       es_bulto, u_por_bulto, oferta_id)
    values
      (v_empresa_id, v_pedido_id,
       (v_item->>'producto_id')::uuid,
       (v_item->>'cantidad')::integer,
       (v_item->>'precio_unit')::numeric,
       coalesce((v_item->>'descuento')::numeric, 0),
       coalesce((v_item->>'es_bulto')::boolean, false),
       (v_item->>'u_por_bulto')::integer,
       v_oferta_id);

    insert into mov_stock
      (empresa_id, producto_id, tipo, cantidad, referencia, referencia_tipo, usuario_id)
    values
      (v_empresa_id,
       (v_item->>'producto_id')::uuid,
       'venta',
       -(v_item->>'cantidad')::integer,
       v_pedido_id, 'pedido', v_usuario_id);

    if v_oferta_id is not null and coalesce((v_item->>'es_regalo')::boolean, false) = false then
      update ofertas
         set stock_vendido = coalesce(stock_vendido, 0) + (v_item->>'cantidad')::integer
       where id = v_oferta_id;
      update ofertas
         set activa = false
       where id = v_oferta_id
         and stock_maximo is not null
         and stock_vendido >= stock_maximo;
    end if;
  end loop;

  -- 3) boleta
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
