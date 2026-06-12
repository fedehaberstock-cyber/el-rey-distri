-- ─────────────────────────────────────────────────────────────────────────
-- Fecha de reparto: separar fecha de creación del pedido de cuándo se
-- entrega. Por defecto, los pedidos cargados un día se reparten al
-- siguiente, pero el preventista puede cambiarlo.
-- ─────────────────────────────────────────────────────────────────────────

-- 1. Columna nueva
alter table pedidos
  add column if not exists fecha_reparto date;

-- 2. Backfill: pedidos existentes se "reparten" el mismo día que se cargaron
update pedidos
   set fecha_reparto = (fecha at time zone 'America/Argentina/Cordoba')::date
 where fecha_reparto is null;

-- 3. NOT NULL + default = mañana (zona Córdoba)
alter table pedidos
  alter column fecha_reparto set not null,
  alter column fecha_reparto set default
    ((now() at time zone 'America/Argentina/Cordoba')::date + 1);

create index if not exists pedidos_fecha_reparto_idx on pedidos(empresa_id, fecha_reparto);

-- 4. Vista hoja_ruta_hoy ahora filtra por fecha_reparto = hoy (Córdoba)
create or replace view hoja_ruta_hoy as
select p.id as pedido_id,
       p.empresa_id, p.fecha, p.fecha_reparto, p.estado, p.hoja_ruta_id,
       p.forma_pago, p.monto_efectivo, p.monto_transf, p.monto_cuenta, p.entregado,
       c.id as cliente_id, c.nombre as cliente_nombre, c.direccion, c.telefono,
       z.nombre as zona_nombre, z.orden as zona_orden, c.posicion_zona,
       u.nombre as preventista_nombre,
       b.total as total_boleta
  from pedidos p
  join clientes c on c.id = p.cliente_id
  left join zonas z on z.id = c.zona_id
  join usuarios u on u.id = p.usuario_id
  left join boletas b on b.pedido_id = p.id
 where p.estado = any (array['confirmado'::estado_pedido,'entregado'::estado_pedido,'no_entregado'::estado_pedido])
   and p.fecha_reparto = (now() at time zone 'America/Argentina/Cordoba')::date
 order by z.orden, c.posicion_zona;

-- 5. confirmar_pedido acepta fecha_reparto opcional en el payload
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
  v_total        numeric := 0;
  v_saldo_ant    numeric;
  v_item         jsonb;
  v_item_total   numeric;
begin
  -- usuario y empresa desde auth
  select id, empresa_id into v_usuario_id, v_empresa_id
    from usuarios where auth_id = auth.uid();
  if v_usuario_id is null then
    raise exception 'Usuario no encontrado';
  end if;

  -- saldo previo (inmutable en la boleta)
  select coalesce(saldo, 0) into v_saldo_ant
    from saldo_actual where cliente_id = v_cliente_id;
  if v_saldo_ant is null or v_saldo_ant < 0 then v_saldo_ant := 0; end if;

  -- 1. pedido
  insert into pedidos
    (empresa_id, cliente_id, usuario_id, fecha, fecha_reparto, estado, descuento, observaciones,
     monto_efectivo, monto_transf, monto_cuenta)
  values
    (v_empresa_id, v_cliente_id, v_usuario_id, now(), v_fecha_rep, 'confirmado',
     v_descuento, v_obs, 0, 0, 0)
  returning id into v_pedido_id;

  -- 2. items + 3. movimientos de stock
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
       coalesce((v_item->>'u_por_bulto')::integer, 1));

    v_item_total :=
      (v_item->>'cantidad')::integer *
      (v_item->>'precio_unit')::numeric *
      (1 - coalesce((v_item->>'descuento')::numeric, 0)/100);
    v_total := v_total + v_item_total;

    insert into mov_stock
      (empresa_id, producto_id, tipo, cantidad, referencia_tipo, referencia_id, usuario_id)
    values
      (v_empresa_id, (v_item->>'producto_id')::uuid, 'venta',
       -1 * (v_item->>'cantidad')::integer *
         (case when coalesce((v_item->>'es_bulto')::boolean,false)
               then coalesce((v_item->>'u_por_bulto')::integer,1) else 1 end),
       'pedido', v_pedido_id, v_usuario_id);
  end loop;

  -- aplicar descuento general al total
  v_total := v_total * (1 - v_descuento/100);

  -- 4. boleta
  insert into boletas
    (empresa_id, pedido_id, fecha, total, estado, saldo_anterior, total_a_cobrar)
  values
    (v_empresa_id, v_pedido_id, now(), v_total, 'emitida',
     v_saldo_ant, v_total + v_saldo_ant)
  returning id into v_boleta_id;

  return jsonb_build_object(
    'pedido_id', v_pedido_id,
    'boleta_id', v_boleta_id,
    'total', v_total,
    'fecha_reparto', v_fecha_rep
  );
end;
$$;
