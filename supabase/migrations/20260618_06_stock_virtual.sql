-- ═══ Stock virtual y sugerencia que lo respeta ═══
-- stock_virtual = stock_actual + ordenes_compra.estado=enviada (pendientes)
-- Asi sugerencia_compra no vuelve a sugerir lo que ya esta pedido al proveedor.

create or replace view public.stock_virtual as
  select
    p.id as producto_id,
    p.empresa_id,
    coalesce(s.stock, 0) as stock_actual,
    coalesce(p_p.pendiente, 0) as pendiente_compra,
    coalesce(s.stock, 0) + coalesce(p_p.pendiente, 0) as stock_virtual
  from public.productos p
  left join public.stock_actual s on s.producto_id = p.id
  left join (
    select oi.producto_id, sum(oi.cantidad - oi.cantidad_recibida)::int as pendiente
      from public.orden_compra_items oi
      join public.ordenes_compra o on o.id = oi.orden_id
     where o.estado in ('enviada','recibida_parcial')
     group by oi.producto_id
  ) p_p on p_p.producto_id = p.id
  where p.activo = true;

-- Reemplazar sugerencia_compra para que use stock_virtual (no stock_actual)
create or replace view public.sugerencia_compra as
  select
    p.id as producto_id,
    p.empresa_id,
    p.nombre,
    p.categoria,
    p.subcategoria,
    p.proveedor_id,
    p.unidad_compra,
    pr.nombre as proveedor_nombre,
    coalesce(pr.dias_objetivo, 14) as dias_objetivo,
    coalesce(pr.dias_reorden, 7)  as dias_reorden,
    coalesce(sv.stock_virtual, 0)   as stock_actual,
    coalesce(sv.pendiente_compra,0) as pendiente_compra,
    coalesce(v.unidades_por_dia, 0) as velocidad,
    case when coalesce(v.unidades_por_dia, 0) > 0
         then floor(coalesce(sv.stock_virtual, 0) / v.unidades_por_dia)::int
         else null
    end as dias_restantes,
    greatest(0, ceil(coalesce(pr.dias_objetivo, 14)::numeric
                     * coalesce(v.unidades_por_dia, 0) - coalesce(sv.stock_virtual, 0)))::int
      as cantidad_sugerida,
    p.costo as ultimo_costo
  from public.productos p
  left join public.stock_virtual sv  on sv.producto_id = p.id
  left join public.velocidad_venta v on v.producto_id = p.id
  left join public.proveedores pr    on pr.id = p.proveedor_id
  where p.activo = true
    and coalesce(v.unidades_por_dia, 0) > 0
    and coalesce(sv.stock_virtual, 0) <
        coalesce(pr.dias_reorden, 7)::numeric * coalesce(v.unidades_por_dia, 0);
