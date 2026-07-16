-- ═══ Confirmar_ingreso también actualiza producto_proveedor ═══
-- Antes: la RPC actualizaba productos.costo pero no producto_proveedor,
-- entonces el comparador de proveedores quedaba desactualizado hasta que
-- se editaba a mano. Ahora hace upsert por (producto_id, proveedor_id).

-- ── Vista: última venta por producto (server-side, sin límites) ───────────
-- Reemplaza el cálculo en JS que traía mov_stock con limit(50000) y en
-- empresas con mucho volumen se cortaba, dejando productos como "sin venta"
-- aunque hubieran vendido recientemente.
create or replace view public.ultima_venta_producto as
select producto_id,
       empresa_id,
       max(fecha) as ultima_venta
  from public.mov_stock
 where tipo = 'venta'
 group by producto_id, empresa_id;

grant select on public.ultima_venta_producto to authenticated, anon;

-- ── confirmar_ingreso — versión con upsert producto_proveedor ─────────────
create or replace function public.confirmar_ingreso(p_ingreso_id uuid) returns void
language plpgsql security definer
set search_path = 'public'
as $$
declare
  item      record;
  emp_id    uuid;
  usr_id    uuid;
  prov_id   uuid;
begin
  select empresa_id, usuario_id, proveedor_id
    into emp_id, usr_id, prov_id
    from ingresos where id = p_ingreso_id;

  for item in
    select * from ingreso_items where ingreso_id = p_ingreso_id
  loop
    -- 1) Actualiza costo del producto al costo final con cargos
    update productos
       set costo = item.costo_unit_final,
           ultimo_cambio_costo = current_date
     where id = item.producto_id;

    -- 2) Registra movimiento de stock tipo ingreso
    insert into mov_stock
      (empresa_id, producto_id, tipo, cantidad, referencia, referencia_tipo, usuario_id)
    values
      (emp_id, item.producto_id, 'ingreso', item.cantidad,
       p_ingreso_id, 'ingreso', usr_id);

    -- 3) Upsert en producto_proveedor: guarda el costo neto (sin cargos) de
    --    este proveedor, para el comparador. Usa costo_unit_neto — refleja
    --    lo que realmente cobra el proveedor por unidad, sin flete/impuestos
    --    que la app aplica como cargos.
    if prov_id is not null then
      insert into producto_proveedor
        (empresa_id, producto_id, proveedor_id, costo, actualizado_en)
      values
        (emp_id, item.producto_id, prov_id, item.costo_unit_neto, current_date)
      on conflict (producto_id, proveedor_id) do update
        set costo          = excluded.costo,
            actualizado_en = current_date;
    end if;
  end loop;
end;
$$;
