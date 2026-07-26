-- ═══ Tracking real de cambios de PRECIO DE VENTA ══════════════════════════
-- Antes usábamos productos.updated_at como proxy, pero se disparaba con
-- cualquier UPDATE (incluidos los que solo modifican costo tras un ingreso).
-- Esto rompía:
--   - Lista de precios "solo aumentos recientes" en stock.html
--   - Bloque "novedades" en pedido_preventista (mostraba productos que
--     solo cambiaron costo).
--
-- Agregamos una columna dedicada + trigger que la actualiza SOLO cuando
-- el campo precio cambia realmente.

alter table public.productos
  add column if not exists ultimo_cambio_precio date;

-- created_at: no existía, la agregamos para poder detectar productos "nuevos"
-- (no basta con updated_at que se bumpea por ingresos).
alter table public.productos
  add column if not exists created_at timestamptz not null default now();

-- Backfill: para los existentes, ponemos una fecha muy vieja para que no
-- aparezcan como "nuevos" ahora.
update public.productos
   set created_at = '2020-01-01'::timestamptz
 where created_at > now() - interval '1 minute';

create or replace function public.set_ultimo_cambio_precio()
returns trigger language plpgsql as $$
begin
  if new.precio is distinct from old.precio then
    new.ultimo_cambio_precio := current_date;
  end if;
  return new;
end $$;

drop trigger if exists tg_ultimo_cambio_precio on public.productos;
create trigger tg_ultimo_cambio_precio
  before update on public.productos
  for each row execute function public.set_ultimo_cambio_precio();

-- Backfill: para arrancar con algo razonable, usamos updated_at como
-- aproximación (mejor que null). Al primer UPDATE real de precio queda
-- correcto.
update public.productos
   set ultimo_cambio_precio = coalesce(updated_at::date, current_date - 30)
 where ultimo_cambio_precio is null;

-- ═══ Novedades: nuevos + reingresos (últimos 7 días) ══════════════════════
-- Reemplaza el bloque v_novedades para devolver:
--   - Productos creados en los últimos 30 días (marca "nuevo")
--   - Productos con último ingreso en los últimos 7 días (marca "reingreso")
-- Filtra por stock > 0.
create or replace function public.rpc_sugerencias_cliente(p_cliente_id uuid)
returns jsonb
language plpgsql security definer
set search_path = 'public'
as $$
declare
  v_uid uuid := auth.uid();
  v_emp uuid;
  v_umbral_pen_sub numeric      := 0.25;
  v_umbral_pen_producto numeric := 0.15;
  v_ventana_pedidos int         := 10;
  v_umbral_recurrencia numeric  := 0.3;
  v_top_siempre int   := 30;
  v_top_gap int       := 10;
  v_top_novedades int := 15;
  v_top_ofertas int   := 15;
  v_lo_de_siempre jsonb;
  v_gap jsonb;
  v_novedades jsonb;
  v_ofertas jsonb;
  v_total_activos int;
begin
  select empresa_id into v_emp from usuarios where auth_id = v_uid;
  if v_emp is null then
    select empresa_id into v_emp from clientes where id = p_cliente_id;
  end if;
  if v_emp is null then return jsonb_build_object('error', 'empresa no resuelta'); end if;

  select count(distinct cliente_id) into v_total_activos
    from pedidos where empresa_id = v_emp and fecha > current_date - 90;

  -- lo_de_siempre
  with u as (
    select p.id, p.fecha,
           row_number() over (partition by p.cliente_id order by p.fecha desc) as rn
      from pedidos p
     where p.cliente_id = p_cliente_id and p.empresa_id = v_emp
       and p.estado in ('confirmado','entregado')
  ),
  ult as (select id from u where rn <= v_ventana_pedidos),
  prods as (
    select pi.producto_id,
           count(distinct u.id) as apariciones
      from pedido_items pi
      join ult u on u.id = pi.pedido_id
     group by pi.producto_id
  ),
  total_ped as (select count(*) as n from ult)
  select coalesce(jsonb_agg(jsonb_build_object(
    'producto_id', p.producto_id,
    'nombre',      pr.nombre,
    'categoria',   pr.categoria,
    'subcategoria',pr.subcategoria,
    'precio',      pr.precio,
    'stock',       coalesce(s.stock, 0),
    'apariciones', p.apariciones,
    'de_pedidos',  (select n from total_ped),
    'recurrencia', round(p.apariciones::numeric / nullif((select n from total_ped),0), 2)
  ) order by p.apariciones desc), '[]'::jsonb)
    into v_lo_de_siempre
    from prods p
    join productos pr on pr.id = p.producto_id and pr.activo = true
    left join stock_actual s on s.producto_id = p.producto_id
   where p.apariciones::numeric / nullif((select n from total_ped),0) >= v_umbral_recurrencia
     and coalesce(s.stock, 0) > 0
   limit v_top_siempre;

  -- gap
  select coalesce(jsonb_agg(x order by x.clientes desc), '[]'::jsonb) into v_gap
    from (
      select coalesce(nullif(btrim(pr.subcategoria),''), pr.nombre) as clave,
             case when nullif(btrim(pr.subcategoria),'') is not null then 'subcategoria' else 'producto' end as tipo,
             count(distinct pi.pedido_id) as apariciones,
             count(distinct p.cliente_id) as clientes,
             round(count(distinct p.cliente_id)::numeric / nullif(v_total_activos,0), 2) as penetracion_pct,
             jsonb_agg(distinct jsonb_build_object(
               'producto_id', pr.id, 'nombre', pr.nombre,
               'precio', pr.precio, 'stock', coalesce(s.stock, 0)
             )) as productos
        from pedido_items pi
        join pedidos p on p.id = pi.pedido_id and p.empresa_id = v_emp
        join productos pr on pr.id = pi.producto_id
        left join stock_actual s on s.producto_id = pr.id
       where p.fecha > current_date - 90
         and p.cliente_id <> p_cliente_id
         and not exists (
           select 1 from pedido_items pi2
           join pedidos p2 on p2.id = pi2.pedido_id
           where p2.cliente_id = p_cliente_id and pi2.producto_id = pr.id
           and p2.fecha > current_date - 180)
       group by clave, tipo
       having count(distinct p.cliente_id)::numeric / nullif(v_total_activos,0) >= v_umbral_pen_sub
       order by clientes desc
       limit v_top_gap
    ) x;

  -- ═══ NOVEDADES ═════════════════════════════════════════════════════════
  -- Combina:
  --   - Productos creados en los últimos 30 días (marca "nuevo")
  --   - Productos con último ingreso en los últimos 7 días (marca "reingreso")
  -- Excluye productos sin stock. Ordena: nuevos primero, luego por
  -- fecha de novedad descendente.
  with ult_ingreso as (
    select producto_id, max(fecha)::date as fecha_ingreso
      from mov_stock
     where tipo = 'ingreso'
     group by producto_id
  ),
  novedades_raw as (
    select pr.id, pr.nombre, pr.categoria, pr.subcategoria, pr.precio,
           coalesce(s.stock, 0) as stock,
           case
             when pr.created_at >= current_date - 30 then 'nuevo'
             else 'reingreso'
           end as tipo_novedad,
           case
             when pr.created_at >= current_date - 30 then pr.created_at::date
             else ui.fecha_ingreso
           end as fecha_novedad
      from productos pr
      left join stock_actual s on s.producto_id = pr.id
      left join ult_ingreso ui on ui.producto_id = pr.id
     where pr.empresa_id = v_emp
       and pr.activo = true
       and coalesce(s.stock, 0) > 0
       and (
         pr.created_at >= current_date - 30
         or ui.fecha_ingreso >= current_date - 7
       )
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'producto_id',  id,
    'nombre',       nombre,
    'categoria',    categoria,
    'subcategoria', subcategoria,
    'precio',       precio,
    'stock',        stock,
    'tipo_novedad', tipo_novedad,
    'fecha_novedad',fecha_novedad
  ) order by (case when tipo_novedad = 'nuevo' then 0 else 1 end), fecha_novedad desc), '[]'::jsonb)
    into v_novedades
    from (select * from novedades_raw order by fecha_novedad desc limit v_top_novedades) t;

  -- OFERTAS
  select coalesce(jsonb_agg(jsonb_build_object(
    'oferta_id',          t.id,
    'producto_id',        t.producto_id,
    'nombre',             t.nombre,
    'categoria',          t.categoria,
    'subcategoria',       t.subcategoria,
    'descripcion',        t.descripcion,
    'precio_normal',      t.precio_normal,
    'precio_oferta',      t.precio_oferta,
    'vigente_hasta',      t.vigente_hasta,
    'stock',              t.stock,
    'prioridad',          t.prioridad,
    'cantidad_min',       t.cantidad_min,
    'aplica_desc_bulto',  t.aplica_desc_bulto,
    'u_bulto',            t.u_bulto,
    'desc_bulto',         t.desc_bulto,
    'regalo_producto_id', t.regalo_producto_id,
    'regalo_nombre',      t.regalo_nombre,
    'regalo_cantidad',    t.regalo_cantidad,
    'stock_maximo',       t.stock_maximo,
    'stock_vendido',      t.stock_vendido
  ) order by t.prioridad desc, t.vigente_hasta asc nulls last), '[]'::jsonb)
    into v_ofertas
    from (
      select o.id, o.producto_id, pr.nombre, pr.categoria, pr.subcategoria,
             o.descripcion, pr.precio as precio_normal, o.precio_oferta,
             o.vigente_hasta, coalesce(s.stock, 0) as stock, o.prioridad,
             o.cantidad_min, o.aplica_desc_bulto,
             pr.u_bulto, pr.desc_bulto,
             o.regalo_producto_id, prr.nombre as regalo_nombre, o.regalo_cantidad,
             o.stock_maximo, o.stock_vendido
        from ofertas o
        join productos pr on pr.id = o.producto_id and pr.activo = true
        left join stock_actual s on s.producto_id = o.producto_id
        left join productos prr on prr.id = o.regalo_producto_id
       where o.empresa_id = v_emp
         and o.activa = true
         and o.vigente_desde <= current_date
         and (o.vigente_hasta is null or o.vigente_hasta >= current_date)
         and coalesce(s.stock, 0) > 0
         and (o.stock_maximo is null or o.stock_vendido < o.stock_maximo)
       order by o.prioridad desc, o.vigente_hasta asc nulls last
       limit v_top_ofertas
    ) t;

  return jsonb_build_object(
    'cliente_id',                  p_cliente_id,
    'denominador_clientes_activos', v_total_activos,
    'umbral_pen_sub',              v_umbral_pen_sub,
    'umbral_pen_producto',         v_umbral_pen_producto,
    'ventana_pedidos',             v_ventana_pedidos,
    'umbral_recurrencia',          v_umbral_recurrencia,
    'lo_de_siempre',               v_lo_de_siempre,
    'gap_sugeridos',               v_gap,
    'novedades',                   v_novedades,
    'ofertas',                     v_ofertas
  );
end;
$$;
