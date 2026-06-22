-- ═══ RPC de sugerencias por cliente ═══
-- Motor de recomendacion nivel 1+2:
--   - lo_de_siempre: productos que el cliente compra recurrentemente
--   - gap_subcategorias: subcategorias que la mayoria compra y este no
--   - novedades: productos creados en los ultimos 30d que el cliente no compro
--   - ofertas: placeholder (pendiente tabla ofertas)
--
-- Pensada para ser reutilizable: la consume pedido_preventista, futuro
-- bot de WhatsApp, otros canales. Toda la logica vive aca.

create or replace function public.rpc_sugerencias_cliente(p_cliente_id uuid)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare
  v_emp uuid := public.empresa_actual();
  v_hace_90 date := (current_date - 90);
  v_hace_180 date := (current_date - 180);
  v_hace_30 date := (current_date - 30);
  v_umbral_penetracion numeric := 0.5;  -- 50% de los clientes activos
  v_min_compras int := 3;               -- min veces para ser "lo de siempre"
  v_total_activos int;
  v_lo_de_siempre jsonb;
  v_gap jsonb;
  v_novedades jsonb;
begin
  if v_emp is null then raise exception 'empresa no resuelta'; end if;

  -- Denominador para penetracion: clientes con >=1 pedido en ultimos 90d
  select count(distinct cliente_id) into v_total_activos
    from pedidos
   where empresa_id = v_emp
     and estado != 'anulado'
     and fecha::date >= v_hace_90
     and cliente_id is not null;
  if coalesce(v_total_activos, 0) = 0 then v_total_activos := 1; end if;

  -- ── 1. Lo de siempre ───────────────────────────────────────────────────
  with compras_cli as (
    select pi.producto_id,
           count(distinct p.id) as veces,
           percentile_cont(0.5) within group (order by pi.cantidad) as cant_mediana,
           max(p.fecha::date) as ultima_compra
      from pedidos p
      join pedido_items pi on pi.pedido_id = p.id
     where p.empresa_id = v_emp
       and p.cliente_id = p_cliente_id
       and p.estado != 'anulado'
       and p.fecha::date >= v_hace_180
     group by pi.producto_id
    having count(distinct p.id) >= v_min_compras
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'producto_id',     cc.producto_id,
    'nombre',          pr.nombre,
    'categoria',       pr.categoria,
    'subcategoria',    pr.subcategoria,
    'cantidad_tipica', greatest(round(cc.cant_mediana)::int, 1),
    'veces',           cc.veces,
    'dias_ultima',     (current_date - cc.ultima_compra)::int,
    'stock',           coalesce(s.stock, 0),
    'precio',          pr.precio
  ) order by cc.veces desc, cc.ultima_compra desc), '[]'::jsonb)
    into v_lo_de_siempre
    from compras_cli cc
    join productos pr on pr.id = cc.producto_id and pr.activo = true
    left join stock_actual s on s.producto_id = pr.id;

  -- ── 2. Gap de subcategorias ────────────────────────────────────────────
  with penetracion as (
    select pr.subcategoria,
           count(distinct p.cliente_id) as clientes_que_compran
      from pedidos p
      join pedido_items pi on pi.pedido_id = p.id
      join productos pr on pr.id = pi.producto_id
     where p.empresa_id = v_emp
       and p.estado != 'anulado'
       and p.fecha::date >= v_hace_90
       and pr.subcategoria is not null
       and pr.subcategoria <> ''
     group by pr.subcategoria
  ),
  compradas_por_cli as (
    select distinct pr.subcategoria
      from pedidos p
      join pedido_items pi on pi.pedido_id = p.id
      join productos pr on pr.id = pi.producto_id
     where p.empresa_id = v_emp
       and p.cliente_id = p_cliente_id
       and p.estado != 'anulado'
       and p.fecha::date >= v_hace_180
       and pr.subcategoria is not null
       and pr.subcategoria <> ''
  ),
  gaps as (
    select pen.subcategoria,
           pen.clientes_que_compran,
           round(pen.clientes_que_compran::numeric / v_total_activos * 100, 1) as penetracion_pct
      from penetracion pen
     where pen.clientes_que_compran::numeric / v_total_activos >= v_umbral_penetracion
       and not exists (
         select 1 from compradas_por_cli c where c.subcategoria = pen.subcategoria
       )
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'subcategoria',     g.subcategoria,
    'penetracion_pct',  g.penetracion_pct,
    'clientes',         g.clientes_que_compran,
    'productos', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'producto_id', pr.id,
        'nombre',      pr.nombre,
        'categoria',   pr.categoria,
        'precio',      pr.precio,
        'stock',       coalesce(s.stock, 0)
      ) order by coalesce(s.stock, 0) desc, pr.nombre), '[]'::jsonb)
      from productos pr
      left join stock_actual s on s.producto_id = pr.id
      where pr.empresa_id = v_emp
        and pr.activo = true
        and pr.subcategoria = g.subcategoria
        and coalesce(s.stock, 0) > 0
    )
  ) order by g.penetracion_pct desc), '[]'::jsonb)
    into v_gap
    from gaps g;

  -- ── 3. Novedades ───────────────────────────────────────────────────────
  with comprados_alguna_vez as (
    select distinct pi.producto_id
      from pedidos p
      join pedido_items pi on pi.pedido_id = p.id
     where p.empresa_id = v_emp
       and p.cliente_id = p_cliente_id
       and p.estado != 'anulado'
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'producto_id',  pr.id,
    'nombre',       pr.nombre,
    'categoria',    pr.categoria,
    'subcategoria', pr.subcategoria,
    'precio',       pr.precio,
    'stock',        coalesce(s.stock, 0),
    'creado_en',    pr.creado_en
  ) order by pr.creado_en desc), '[]'::jsonb)
    into v_novedades
    from productos pr
    left join stock_actual s on s.producto_id = pr.id
    where pr.empresa_id = v_emp
      and pr.activo = true
      and pr.creado_en::date >= v_hace_30
      and coalesce(s.stock, 0) > 0
      and not exists (select 1 from comprados_alguna_vez c where c.producto_id = pr.id);

  return jsonb_build_object(
    'cliente_id',                  p_cliente_id,
    'denominador_clientes_activos', v_total_activos,
    'umbral_penetracion',          v_umbral_penetracion,
    'lo_de_siempre',               v_lo_de_siempre,
    'gap_subcategorias',           v_gap,
    'novedades',                   v_novedades,
    'ofertas',                     '[]'::jsonb,
    'generado_en',                 now()
  );
end;
$$;

grant execute on function public.rpc_sugerencias_cliente(uuid) to authenticated;
