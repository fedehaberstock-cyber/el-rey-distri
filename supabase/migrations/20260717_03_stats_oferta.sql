-- ═══ RPC de estadísticas por oferta ═══════════════════════════════════════
-- Devuelve para una oferta:
--   - Ventas del producto principal durante la ventana de la oferta
--     (unidades, $, promos aplicadas)
--   - Baseline: ventas del mismo producto en los 30 días previos a
--     vigente_desde, excluyendo los días donde el stock estuvo en 0
--   - Multiplicador de venta (velocidad oferta vs velocidad baseline)
--   - Regalados: unidades del producto de regalo entregadas
--   - Clientes "nuevos": los que compraron el principal durante la oferta
--     y NO lo compraron en los 45 días previos

create or replace function public.rpc_stats_oferta(p_oferta_id uuid)
returns jsonb
language plpgsql security definer
set search_path = 'public'
as $$
declare
  v_uid uuid := auth.uid();
  v_emp uuid;
  v_of  record;
  v_desde       date;
  v_hasta       date;
  v_dias_oferta int;
  v_baseline_desde date;
  v_baseline_hasta date;
  v_dias_base_efectivos int := 0;
  v_ventas_of numeric := 0;
  v_units_of  int := 0;
  v_promos    int := 0;
  v_units_base int := 0;
  v_regalos_units int := 0;
  v_clientes_ventana jsonb;
  v_clientes_nuevos jsonb;
  v_multiplicador numeric := 0;
begin
  select empresa_id into v_emp from usuarios where auth_id = v_uid;
  select * into v_of from ofertas where id = p_oferta_id;
  if v_of.id is null then raise exception 'oferta no encontrada'; end if;
  if v_emp is null then v_emp := v_of.empresa_id; end if;

  v_desde := v_of.vigente_desde;
  v_hasta := coalesce(v_of.vigente_hasta, current_date);
  v_dias_oferta := greatest(1, (v_hasta - v_desde) + 1);
  v_baseline_desde := v_desde - 30;
  v_baseline_hasta := v_desde - 1;

  -- Días efectivos del baseline con stock > 0 (aproximación por días con
  -- algún ingreso registrado que dejó stock positivo). Si no podemos
  -- determinar bien, asumimos los 30 días completos.
  -- Simplificación: excluir solo los días en que hubo venta imposible
  -- (stock global del producto llegó a 0). Estimamos con mov_stock.
  with dias_base as (
    select generate_series(v_baseline_desde, v_baseline_hasta, '1 day')::date as d
  ),
  stock_diario as (
    select d,
           coalesce((
             select sum(cantidad) from mov_stock
              where producto_id = v_of.producto_id
                and fecha::date <= dias_base.d
           ), 0) as stock_al_dia
      from dias_base
  )
  select count(*) into v_dias_base_efectivos
    from stock_diario where stock_al_dia > 0;

  if v_dias_base_efectivos = 0 then v_dias_base_efectivos := 30; end if;

  -- Ventas durante la oferta (líneas con oferta_id = esta oferta, no regalo)
  select coalesce(sum(pi.cantidad), 0),
         coalesce(sum(pi.cantidad * pi.precio_unit * (1 - coalesce(pi.descuento,0)/100)), 0),
         count(distinct pi.pedido_id)
    into v_units_of, v_ventas_of, v_promos
    from pedido_items pi
    join pedidos p on p.id = pi.pedido_id
   where pi.oferta_id = p_oferta_id
     and pi.producto_id = v_of.producto_id
     and coalesce(pi.descuento, 0) < 100
     and p.estado in ('confirmado','entregado');

  -- Regalos entregados
  if v_of.regalo_producto_id is not null then
    select coalesce(sum(pi.cantidad), 0)
      into v_regalos_units
      from pedido_items pi
      join pedidos p on p.id = pi.pedido_id
     where pi.oferta_id = p_oferta_id
       and pi.producto_id = v_of.regalo_producto_id
       and p.estado in ('confirmado','entregado');
  end if;

  -- Baseline: ventas del principal en los 30 días previos
  select coalesce(sum(pi.cantidad), 0)
    into v_units_base
    from pedido_items pi
    join pedidos p on p.id = pi.pedido_id
   where pi.producto_id = v_of.producto_id
     and p.estado in ('confirmado','entregado')
     and p.fecha::date between v_baseline_desde and v_baseline_hasta;

  -- Multiplicador: (units_of / dias_oferta) / (units_base / dias_base_efectivos)
  if v_units_base > 0 and v_dias_base_efectivos > 0 then
    v_multiplicador := round(
      (v_units_of::numeric / v_dias_oferta) /
      (v_units_base::numeric / v_dias_base_efectivos),
      2
    );
  end if;

  -- Clientes que compraron durante la ventana con esta oferta
  with cli_ventana as (
    select distinct p.cliente_id
      from pedido_items pi
      join pedidos p on p.id = pi.pedido_id
     where pi.oferta_id = p_oferta_id
       and pi.producto_id = v_of.producto_id
       and coalesce(pi.descuento, 0) < 100
       and p.estado in ('confirmado','entregado')
  ),
  -- De esos, los que YA habían comprado el producto en los 45 días previos
  cli_previos as (
    select distinct p.cliente_id
      from pedido_items pi
      join pedidos p on p.id = pi.pedido_id
     where pi.producto_id = v_of.producto_id
       and p.estado in ('confirmado','entregado')
       and p.fecha::date between (v_desde - 45) and (v_desde - 1)
  )
  select coalesce(jsonb_agg(
           jsonb_build_object('cliente_id', c.id, 'nombre', c.nombre)
           order by c.nombre
         ), '[]'::jsonb)
    into v_clientes_nuevos
    from cli_ventana cv
    join clientes c on c.id = cv.cliente_id
   where cv.cliente_id not in (select cliente_id from cli_previos);

  -- Lista total de clientes que compraron la oferta (para exportar)
  select coalesce(jsonb_agg(
           jsonb_build_object('cliente_id', c.id, 'nombre', c.nombre)
           order by c.nombre
         ), '[]'::jsonb)
    into v_clientes_ventana
    from (
      select distinct p.cliente_id
        from pedido_items pi
        join pedidos p on p.id = pi.pedido_id
       where pi.oferta_id = p_oferta_id
         and pi.producto_id = v_of.producto_id
         and coalesce(pi.descuento, 0) < 100
         and p.estado in ('confirmado','entregado')
    ) cv
    join clientes c on c.id = cv.cliente_id;

  return jsonb_build_object(
    'oferta_id',         p_oferta_id,
    'vigente_desde',     v_desde,
    'vigente_hasta',     v_hasta,
    'dias_oferta',       v_dias_oferta,
    'dias_baseline',     v_dias_base_efectivos,
    'baseline_desde',    v_baseline_desde,
    'baseline_hasta',    v_baseline_hasta,
    'units_oferta',      v_units_of,
    'ventas_oferta',     v_ventas_of,
    'promos_aplicadas',  v_promos,
    'units_baseline',    v_units_base,
    'multiplicador',     v_multiplicador,
    'regalos_units',     v_regalos_units,
    'clientes_total',    v_clientes_ventana,
    'clientes_nuevos',   v_clientes_nuevos
  );
end;
$$;
