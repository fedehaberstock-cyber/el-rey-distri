-- ═══ Boletas: campo "impresa_en" + edición hasta que se imprime ═══
-- Antes el preventista podía editar su boleta hasta las 14:00 del día de
-- carga. Pero la impresión real a veces ocurre más tarde (17-18hs). Pasamos
-- a una regla más natural: el preventista puede editar mientras la boleta
-- NO esté marcada como impresa. Admin/depósito siguen pudiendo editar en
-- cualquier momento (y pueden "deshacer impresa" si hace falta reabrir).

alter table public.boletas
  add column if not exists impresa_en timestamptz;

-- Rewrite base = 20260717_02_editar_boleta_ofertas.sql, cambiando solo el
-- chequeo de permiso del preventista.
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
  v_justif       text := btrim(coalesce(p_payload->>'justificativo', ''));
  v_usuario_id   uuid;
  v_empresa_id   uuid;
  v_rol          text;
  v_pedido_id    uuid;
  v_pedido_user  uuid;
  v_pedido_fecha timestamptz;
  v_hoja_estado  text;
  v_impresa_en   timestamptz;
  v_total        numeric := 0;
  v_subtotal     numeric;
  v_saldo_ant    numeric;
  v_item         jsonb;
  v_snap_antes   jsonb;
  v_snap_desp    jsonb;
  v_of_id        uuid;
begin
  if v_justif = '' or length(v_justif) < 3 then
    raise exception 'El justificativo es obligatorio (mínimo 3 caracteres)';
  end if;

  select id, empresa_id, rol into v_usuario_id, v_empresa_id, v_rol
    from usuarios where auth_id = auth.uid();
  if v_usuario_id is null then raise exception 'Usuario no encontrado'; end if;

  select pedido_id, saldo_anterior, impresa_en
    into v_pedido_id, v_saldo_ant, v_impresa_en
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
    if v_impresa_en is not null then
      raise exception 'La boleta ya fue impresa — pedile al admin que la reabra para editarla';
    end if;
  elsif v_rol not in ('admin','deposito') then
    raise exception 'Rol sin permiso para editar boletas';
  end if;

  -- Snapshot ANTES
  select jsonb_build_object(
    'boleta_id', b.id,
    'cliente_id', p.cliente_id,
    'cliente_nombre', c.nombre,
    'descuento', p.descuento,
    'observaciones', p.observaciones,
    'fecha_reparto', p.fecha_reparto,
    'total', b.total,
    'total_a_cobrar', b.total_a_cobrar,
    'saldo_anterior', b.saldo_anterior,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'producto_id', pi.producto_id,
        'producto_nombre', pr.nombre,
        'cantidad', pi.cantidad,
        'precio_unit', pi.precio_unit,
        'descuento', pi.descuento,
        'es_bulto', pi.es_bulto,
        'u_por_bulto', pi.u_por_bulto,
        'oferta_id', pi.oferta_id
      ) order by pr.nombre)
      from pedido_items pi
      join productos pr on pr.id = pi.producto_id
      where pi.pedido_id = v_pedido_id
    ), '[]'::jsonb)
  )
  into v_snap_antes
  from boletas b
  join pedidos p on p.id = b.pedido_id
  left join clientes c on c.id = p.cliente_id
  where b.id = v_boleta_id;

  -- Restar stock_vendido de las ofertas antiguas (compensar antes de reinsertar)
  update ofertas o
     set stock_vendido = greatest(0, coalesce(stock_vendido, 0) - subq.total_qty)
    from (
      select pi.oferta_id, sum(pi.cantidad) as total_qty
        from pedido_items pi
       where pi.pedido_id = v_pedido_id
         and pi.oferta_id is not null
       group by pi.oferta_id
    ) subq
   where o.id = subq.oferta_id;

  -- Aplicar cambios
  delete from mov_stock
   where referencia_tipo = 'pedido' and referencia = v_pedido_id;
  delete from pedido_items where pedido_id = v_pedido_id;

  for v_item in select * from jsonb_array_elements(v_items) loop
    v_of_id := nullif(v_item->>'oferta_id','')::uuid;

    insert into pedido_items
      (empresa_id, pedido_id, producto_id, cantidad, precio_unit, descuento,
       es_bulto, u_por_bulto, costo_unit_snapshot, oferta_id)
    values
      (v_empresa_id, v_pedido_id,
       (v_item->>'producto_id')::uuid,
       (v_item->>'cantidad')::integer,
       (v_item->>'precio_unit')::numeric,
       coalesce((v_item->>'descuento')::numeric, 0),
       coalesce((v_item->>'es_bulto')::boolean, false),
       (v_item->>'u_por_bulto')::integer,
       (select costo from productos where id = (v_item->>'producto_id')::uuid),
       v_of_id);

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

    if v_of_id is not null
       and coalesce((v_item->>'es_regalo')::boolean, false) = false then
      update ofertas
         set stock_vendido = coalesce(stock_vendido, 0) + (v_item->>'cantidad')::integer
       where id = v_of_id;
      update ofertas
         set activa = false
       where id = v_of_id
         and stock_maximo is not null
         and stock_vendido >= stock_maximo;
    end if;
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

  -- Snapshot DESPUES
  select jsonb_build_object(
    'boleta_id', b.id,
    'cliente_id', p.cliente_id,
    'cliente_nombre', c.nombre,
    'descuento', p.descuento,
    'observaciones', p.observaciones,
    'fecha_reparto', p.fecha_reparto,
    'total', b.total,
    'total_a_cobrar', b.total_a_cobrar,
    'saldo_anterior', b.saldo_anterior,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'producto_id', pi.producto_id,
        'producto_nombre', pr.nombre,
        'cantidad', pi.cantidad,
        'precio_unit', pi.precio_unit,
        'descuento', pi.descuento,
        'es_bulto', pi.es_bulto,
        'u_por_bulto', pi.u_por_bulto,
        'oferta_id', pi.oferta_id
      ) order by pr.nombre)
      from pedido_items pi
      join productos pr on pr.id = pi.producto_id
      where pi.pedido_id = v_pedido_id
    ), '[]'::jsonb)
  )
  into v_snap_desp
  from boletas b
  join pedidos p on p.id = b.pedido_id
  left join clientes c on c.id = p.cliente_id
  where b.id = v_boleta_id;

  insert into boletas_audit
    (empresa_id, boleta_id, editor_usuario_id, justificativo, snapshot_antes, snapshot_despues)
  values
    (v_empresa_id, v_boleta_id, v_usuario_id, v_justif, v_snap_antes, v_snap_desp);

  return jsonb_build_object(
    'boleta_id', v_boleta_id,
    'pedido_id', v_pedido_id,
    'total', v_total
  );
end;
$$;
