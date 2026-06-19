-- ═══ Auditoría de ediciones de boletas ═══
-- Tabla que guarda quien edito una boleta, cuando, por que (justificativo
-- requerido) y un snapshot del estado antes y despues de la edicion.

create table if not exists public.boletas_audit (
  id                  uuid primary key default gen_random_uuid(),
  empresa_id          uuid not null references public.empresas(id) on delete cascade,
  boleta_id           uuid not null references public.boletas(id) on delete cascade,
  editor_usuario_id   uuid references public.usuarios(id),
  editado_en          timestamptz not null default now(),
  justificativo       text not null check (length(btrim(justificativo)) > 0),
  snapshot_antes      jsonb not null,
  snapshot_despues    jsonb not null
);

create index if not exists boletas_audit_emp_idx on public.boletas_audit(empresa_id, editado_en desc);
create index if not exists boletas_audit_boleta_idx on public.boletas_audit(boleta_id);
create index if not exists boletas_audit_editor_idx on public.boletas_audit(editor_usuario_id);

alter table public.boletas_audit enable row level security;
drop policy if exists tenant on public.boletas_audit;
create policy tenant on public.boletas_audit
  using (empresa_id = public.empresa_actual())
  with check (empresa_id = public.empresa_actual());


-- Reemplazo de editar_boleta: pide justificativo y graba audit
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
  v_total        numeric := 0;
  v_subtotal     numeric;
  v_saldo_ant    numeric;
  v_item         jsonb;
  v_ahora_arg    timestamp;
  v_limite       timestamp;
  v_snap_antes   jsonb;
  v_snap_desp    jsonb;
begin
  if v_justif = '' or length(v_justif) < 3 then
    raise exception 'El justificativo es obligatorio (mínimo 3 caracteres)';
  end if;

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

  -- Snapshot ANTES (estado actual de la boleta + pedido + items)
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
        'u_por_bulto', pi.u_por_bulto
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

  -- Aplicar cambios
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
        'u_por_bulto', pi.u_por_bulto
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
