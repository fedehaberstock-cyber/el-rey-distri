-- ═══ RPCs de reporte agregados server-side ═══
-- Para reducir payload (hoy se traen pedidos+items+productos del rango y se
-- agrega en cliente). Estas RPCs devuelven jsonb agregado.

create or replace function public.rpc_reporte_ventas(
  p_desde date,
  p_hasta date,
  p_usuario_id uuid default null
) returns jsonb
language plpgsql security definer
set search_path = 'public'
as $$
declare
  v_emp        uuid := public.empresa_actual();
  v_kpis       jsonb;
  v_por_dia    jsonb;
  v_productos  jsonb;
  v_preventistas jsonb;
  v_proveedores jsonb;
  v_ganancia   jsonb;
begin
  if v_emp is null then raise exception 'empresa no resuelta'; end if;

  -- KPIs base
  with items as (
    select p.id as pedido_id, p.fecha::date as f, p.usuario_id, p.descuento as desc_gen,
           it.cantidad, it.precio_unit, it.descuento as desc_it, it.costo_unit_snapshot,
           pr.id as prod_id, pr.nombre as prod_nombre, pr.costo as prod_costo,
           pv.nombre as prov_nombre, us.nombre as usu_nombre
      from pedidos p
      join pedido_items it on it.pedido_id = p.id
      join productos pr    on pr.id = it.producto_id
 left join proveedores pv  on pv.id = pr.proveedor_id
 left join usuarios us     on us.id = p.usuario_id
     where p.empresa_id = v_emp
       and p.estado in ('confirmado','entregado')
       and p.fecha::date between p_desde and p_hasta
       and (p_usuario_id is null or p.usuario_id = p_usuario_id)
  ),
  pedido_tot as (
    select pedido_id, f, usuario_id,
           sum(cantidad * precio_unit * (1 - coalesce(desc_it,0)/100)) * (1 - coalesce(max(desc_gen),0)/100) as total
      from items
     group by pedido_id, f, usuario_id
  )
  select jsonb_build_object(
    'total',   coalesce(sum(total), 0),
    'pedidos', count(*),
    'ticket',  case when count(*) > 0 then coalesce(sum(total),0) / count(*) else 0 end
  )
  into v_kpis
  from pedido_tot;

  -- Por dia
  with pedido_tot as (
    select p.fecha::date as f,
           sum(it.cantidad * it.precio_unit * (1 - coalesce(it.descuento,0)/100)) * (1 - coalesce(max(p.descuento),0)/100) as total
      from pedidos p
      join pedido_items it on it.pedido_id = p.id
     where p.empresa_id = v_emp
       and p.estado in ('confirmado','entregado')
       and p.fecha::date between p_desde and p_hasta
       and (p_usuario_id is null or p.usuario_id = p_usuario_id)
     group by p.id, p.fecha::date
  )
  select coalesce(jsonb_agg(jsonb_build_object('fecha', f, 'total', sum_total) order by f), '[]'::jsonb)
    into v_por_dia
  from (
    select f, sum(total) as sum_total
      from pedido_tot
     group by f
  ) s;

  -- Top productos
  with items as (
    select p.descuento as desc_gen, it.cantidad, it.precio_unit, it.descuento as desc_it,
           it.costo_unit_snapshot, pr.id as prod_id, pr.nombre, pr.costo as prod_costo
      from pedidos p
      join pedido_items it on it.pedido_id = p.id
      join productos pr    on pr.id = it.producto_id
     where p.empresa_id = v_emp
       and p.estado in ('confirmado','entregado')
       and p.fecha::date between p_desde and p_hasta
       and (p_usuario_id is null or p.usuario_id = p_usuario_id)
  ),
  agg as (
    select nombre,
           sum(cantidad) as u,
           sum(cantidad * precio_unit * (1 - coalesce(desc_it,0)/100) * (1 - coalesce(desc_gen,0)/100)) as monto,
           sum(cantidad * coalesce(costo_unit_snapshot, prod_costo)) as costo
      from items
     group by nombre
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'nombre', nombre, 'u', u, 'monto', monto, 'costo', costo,
           'ganancia', monto - costo
         ) order by monto desc), '[]'::jsonb)
    into v_productos
  from agg;

  -- Por preventista
  with pedido_tot as (
    select coalesce(us.nombre,'(sin)') as nombre,
           sum(it.cantidad * it.precio_unit * (1 - coalesce(it.descuento,0)/100)) * (1 - coalesce(max(p.descuento),0)/100) as total,
           p.id as pid
      from pedidos p
      join pedido_items it on it.pedido_id = p.id
 left join usuarios us     on us.id = p.usuario_id
     where p.empresa_id = v_emp
       and p.estado in ('confirmado','entregado')
       and p.fecha::date between p_desde and p_hasta
     group by p.id, us.nombre
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'nombre', nombre, 'pedidos', cant, 'monto', monto
         ) order by monto desc), '[]'::jsonb)
    into v_preventistas
  from (
    select nombre, count(*) as cant, sum(total) as monto
      from pedido_tot group by nombre
  ) s;

  -- Por proveedor
  with items as (
    select p.descuento as desc_gen, it.cantidad, it.precio_unit, it.descuento as desc_it,
           it.costo_unit_snapshot, pr.costo as prod_costo,
           coalesce(pv.nombre,'Sin proveedor') as prov, p.id as pid
      from pedidos p
      join pedido_items it on it.pedido_id = p.id
      join productos pr    on pr.id = it.producto_id
 left join proveedores pv  on pv.id = pr.proveedor_id
     where p.empresa_id = v_emp
       and p.estado in ('confirmado','entregado')
       and p.fecha::date between p_desde and p_hasta
       and (p_usuario_id is null or p.usuario_id = p_usuario_id)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'nombre', prov, 'u', u, 'pedidos', cant_ped, 'ingreso', ingreso,
           'costo', costo, 'ganancia', ingreso - costo
         ) order by ingreso desc), '[]'::jsonb)
    into v_proveedores
  from (
    select prov,
           sum(cantidad) as u,
           count(distinct pid) as cant_ped,
           sum(cantidad * precio_unit * (1 - coalesce(desc_it,0)/100) * (1 - coalesce(desc_gen,0)/100)) as ingreso,
           sum(cantidad * coalesce(costo_unit_snapshot, prod_costo)) as costo
      from items
     group by prov
  ) s;

  -- Ganancia
  with items as (
    select p.descuento as desc_gen, it.cantidad, it.precio_unit, it.descuento as desc_it,
           it.costo_unit_snapshot, pr.costo as prod_costo
      from pedidos p
      join pedido_items it on it.pedido_id = p.id
      join productos pr    on pr.id = it.producto_id
     where p.empresa_id = v_emp
       and p.estado in ('confirmado','entregado')
       and p.fecha::date between p_desde and p_hasta
       and (p_usuario_id is null or p.usuario_id = p_usuario_id)
  )
  select jsonb_build_object(
    'costo', coalesce(sum(cantidad * coalesce(costo_unit_snapshot, prod_costo)),0),
    'sin_snapshot', coalesce(sum(case when costo_unit_snapshot is null then 1 else 0 end),0)
  )
  into v_ganancia
  from items;

  return jsonb_build_object(
    'kpis',         v_kpis,
    'por_dia',      v_por_dia,
    'productos',    v_productos,
    'preventistas', v_preventistas,
    'proveedores',  v_proveedores,
    'ganancia',     v_ganancia,
    'rango', jsonb_build_object('desde', p_desde, 'hasta', p_hasta)
  );
end;
$$;

grant execute on function public.rpc_reporte_ventas(date, date, uuid) to authenticated;


-- ═══ rpc_reporte_recaudacion ═══
create or replace function public.rpc_reporte_recaudacion(
  p_desde date,
  p_hasta date
) returns jsonb
language plpgsql security definer
set search_path = 'public'
as $$
declare
  v_emp      uuid := public.empresa_actual();
  v_total    numeric;
  v_por_dia  jsonb;
  v_por_forma jsonb;
  v_por_usuario jsonb;
begin
  if v_emp is null then raise exception 'empresa no resuelta'; end if;

  select coalesce(sum(-monto), 0)
    into v_total
    from mov_cuenta
   where empresa_id = v_emp
     and tipo = 'pago'
     and fecha::date between p_desde and p_hasta;

  select coalesce(jsonb_agg(jsonb_build_object('fecha', d, 'total', t) order by d), '[]'::jsonb)
    into v_por_dia
    from (
      select fecha::date as d, sum(-monto) as t
        from mov_cuenta
       where empresa_id = v_emp
         and tipo = 'pago'
         and fecha::date between p_desde and p_hasta
       group by fecha::date
    ) s;

  select coalesce(jsonb_agg(jsonb_build_object('forma_pago', coalesce(forma_pago,'(sin)'), 'total', t)
                            order by t desc), '[]'::jsonb)
    into v_por_forma
    from (
      select forma_pago, sum(-monto) as t
        from mov_cuenta
       where empresa_id = v_emp
         and tipo = 'pago'
         and fecha::date between p_desde and p_hasta
       group by forma_pago
    ) s;

  select coalesce(jsonb_agg(jsonb_build_object('usuario', coalesce(us.nombre,'(sin)'),
                                               'total', t) order by t desc), '[]'::jsonb)
    into v_por_usuario
    from (
      select usuario_id, sum(-monto) as t
        from mov_cuenta
       where empresa_id = v_emp
         and tipo = 'pago'
         and fecha::date between p_desde and p_hasta
       group by usuario_id
    ) s
    left join usuarios us on us.id = s.usuario_id;

  return jsonb_build_object(
    'total',        v_total,
    'por_dia',      v_por_dia,
    'por_forma',    v_por_forma,
    'por_usuario',  v_por_usuario,
    'rango', jsonb_build_object('desde', p_desde, 'hasta', p_hasta)
  );
end;
$$;

grant execute on function public.rpc_reporte_recaudacion(date, date) to authenticated;
