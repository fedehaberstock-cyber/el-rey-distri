-- ═══ confirmar_pedido: incrementar stock_vendido de las ofertas ═══════════
-- Cuando el front envía items con oferta_id (líneas creadas al aplicar una
-- oferta), sumamos la cantidad al contador de la oferta. Cuando llega a
-- stock_maximo, la RPC de sugerencias ya deja de mostrarla.

alter table public.pedido_items
  add column if not exists oferta_id uuid references public.ofertas(id);

create index if not exists pedido_items_oferta_idx
  on public.pedido_items(oferta_id) where oferta_id is not null;

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
  v_items        jsonb;
  v_item         jsonb;
  v_pedido_id    uuid;
  v_boleta_id    uuid;
  v_total        numeric := 0;
  v_subtotal     numeric;
  v_saldo_ant    numeric;
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

  -- total
  for v_item in select * from jsonb_array_elements(v_items) loop
    v_subtotal := (v_item->>'cantidad')::numeric
                * (v_item->>'precio_unit')::numeric
                * (1 - coalesce((v_item->>'descuento')::numeric, 0) / 100);
    v_total := v_total + v_subtotal;
  end loop;
  v_total := v_total * (1 - v_descuento / 100);

  -- saldo previo
  select coalesce(saldo, 0) into v_saldo_ant
  from saldo_actual where cliente_id = v_cliente_id;
  if v_saldo_ant < 0 then v_saldo_ant := 0; end if;

  -- 1) pedido
  insert into pedidos
    (empresa_id, cliente_id, usuario_id, fecha, estado, descuento, observaciones,
     fecha_reparto, monto_efectivo, monto_transf, monto_cuenta)
  values
    (v_empresa_id, v_cliente_id, v_usuario_id, now(), 'confirmado',
     v_descuento, v_obs, coalesce(v_fecha_rep, current_date), 0, 0, 0)
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

    -- Si viene con oferta_id y NO es la línea del regalo, sumar al contador.
    -- El regalo se marca con es_regalo=true en el payload.
    if v_oferta_id is not null and coalesce((v_item->>'es_regalo')::boolean, false) = false then
      update ofertas
         set stock_vendido = coalesce(stock_vendido, 0) + (v_item->>'cantidad')::integer
       where id = v_oferta_id;
      -- Si llegó al tope, desactivamos automáticamente (opcional):
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
