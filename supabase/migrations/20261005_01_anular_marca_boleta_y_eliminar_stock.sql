-- ═══ Pedidos anulados: boleta coherente + eliminar sin duplicar stock ═══
-- 1) anular_pedido ahora marca la boleta como 'anulada' (antes quedaba 'emitida'
--    y aparecía en el cliente como un pedido vigente).
-- 2) eliminar_boleta borra también la devolución de stock de la anulación.
--    Antes borraba solo la salida (venta) y dejaba la entrada (anulación):
--    eliminar una boleta ya anulada sumaba la mercadería dos veces.
-- 3) Backfill de boletas de pedidos ya anulados.

create or replace function public.anular_pedido(p_pedido_id uuid, p_motivo text default null)
returns void
language plpgsql security definer
set search_path = 'public'
as $$
declare
  v_emp uuid; v_cli uuid; v_usr uuid; it record;
  v_mot text := nullif(btrim(coalesce(p_motivo,'')), '');
begin
  select empresa_id, cliente_id, usuario_id into v_emp, v_cli, v_usr
    from pedidos where id = p_pedido_id;
  if v_emp is null then raise exception 'pedido no existe'; end if;

  for it in select producto_id, cantidad from pedido_items where pedido_id = p_pedido_id loop
    insert into mov_stock (empresa_id, producto_id, tipo, cantidad, referencia, referencia_tipo, usuario_id)
    values (v_emp, it.producto_id, 'devolucion', it.cantidad, p_pedido_id, 'anulacion', v_usr);
  end loop;

  delete from mov_cuenta where referencia = p_pedido_id;

  insert into visitas_clientes (empresa_id, cliente_id, usuario_id, resultado, motivo, pedido_id)
  values (v_emp, v_cli, v_usr, 'no_entregado', v_mot, p_pedido_id);

  update pedidos set
    estado = 'anulado', entregado = false, hoja_ruta_id = null,
    motivo_no_entrega = v_mot,
    monto_efectivo = 0, monto_transf = 0, monto_cuenta = 0
  where id = p_pedido_id;

  update boletas set estado = 'anulada' where pedido_id = p_pedido_id;
end $$;

create or replace function eliminar_boleta(p_boleta_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rol         text;
  v_empresa_id  uuid;
  v_pedido_id   uuid;
begin
  select rol, empresa_id into v_rol, v_empresa_id
    from usuarios where auth_id = auth.uid();
  if v_rol is null then raise exception 'Usuario no encontrado'; end if;
  if v_rol <> 'admin' then raise exception 'Solo admin puede eliminar boletas'; end if;

  select pedido_id into v_pedido_id
    from boletas where id = p_boleta_id and empresa_id = v_empresa_id;
  if v_pedido_id is null then raise exception 'Boleta no encontrada'; end if;

  delete from mov_cuenta
   where referencia = v_pedido_id
     and referencia_tipo in ('hoja_ruta','pedido');

  -- Venta (salida) y anulación (entrada) se borran juntas: el stock neto del
  -- pedido vuelve a 0 en ambos casos (anulado o no).
  delete from mov_stock
   where referencia = v_pedido_id
     and referencia_tipo in ('pedido','anulacion');

  delete from pedido_items where pedido_id = v_pedido_id;
  delete from boletas where id = p_boleta_id;
  delete from pedidos where id = v_pedido_id;
end;
$$;

update boletas b
   set estado = 'anulada'
  from pedidos p
 where p.id = b.pedido_id
   and p.estado = 'anulado'
   and b.estado <> 'anulada';

-- ── DIAGNÓSTICO (correr aparte, solo lectura) ─────────────────────────────
-- Mercadería que entró DOS veces: devoluciones por anulación cuyo pedido ya
-- fue eliminado (la salida original se borró, la entrada quedó).
--
-- select pr.nombre, sum(ms.cantidad) as unidades_de_mas, count(distinct ms.referencia) as pedidos,
--        min(ms.fecha) as desde, max(ms.fecha) as hasta
--   from mov_stock ms
--   join productos pr on pr.id = ms.producto_id
--  where ms.referencia_tipo = 'anulacion'
--    and not exists (select 1 from pedidos p where p.id = ms.referencia)
--  group by pr.nombre
--  order by unidades_de_mas desc;
