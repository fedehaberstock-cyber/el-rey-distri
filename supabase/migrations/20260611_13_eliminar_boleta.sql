-- ─────────────────────────────────────────────────────────────────────────
-- Eliminar boleta (admin only). Borra pedido + items + mov_stock + mov_cuenta
-- asociados. Atómica.
-- ─────────────────────────────────────────────────────────────────────────

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

  delete from mov_stock
   where referencia = v_pedido_id
     and referencia_tipo = 'pedido';

  delete from pedido_items where pedido_id = v_pedido_id;
  delete from boletas where id = p_boleta_id;
  delete from pedidos where id = v_pedido_id;
end;
$$;
