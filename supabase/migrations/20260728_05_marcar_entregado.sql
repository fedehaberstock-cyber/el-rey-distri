-- ═══ Marcar pedido como entregado manualmente (desde pendientes) ══════════
-- Cuando el vendedor entrega un pedido fuera de una hoja de ruta (o quiere
-- cerrarlo sin cerrar la hoja), permite marcarlo entregado directamente.
-- Crea el cargo en cuenta_corriente por el total; el cobro se registra
-- después a través del flujo normal de pagos.
--
-- Params: pedido_id + forma_pago (cuenta_corriente | efectivo | transferencia)

create or replace function public.marcar_pedido_entregado(
  p_pedido_id uuid,
  p_forma_pago text default 'cuenta_corriente'
)
returns void
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_emp uuid; v_cli uuid; v_usr uuid; v_total numeric;
begin
  if p_forma_pago not in ('cuenta_corriente','efectivo','transferencia') then
    raise exception 'forma_pago inválida';
  end if;

  select empresa_id, cliente_id into v_emp, v_cli
    from pedidos where id = p_pedido_id;
  if v_emp is null then raise exception 'pedido no existe'; end if;

  select id into v_usr from usuarios where auth_id = auth.uid();
  if v_usr is null then raise exception 'usuario no autenticado'; end if;

  select total into v_total from boletas where pedido_id = p_pedido_id;
  v_total := coalesce(v_total, 0);

  -- 1) CARGO
  if v_total > 0 then
    insert into mov_cuenta (empresa_id, cliente_id, tipo, monto, forma_pago,
      referencia, referencia_tipo, usuario_id)
    values (v_emp, v_cli, 'cargo', v_total, 'cuenta_corriente',
      p_pedido_id, 'pedido', v_usr);
  end if;

  -- 2) PAGO inmediato si no es cuenta_corriente
  if p_forma_pago in ('efectivo','transferencia') and v_total > 0 then
    insert into mov_cuenta (empresa_id, cliente_id, tipo, monto, forma_pago,
      referencia, referencia_tipo, usuario_id)
    values (v_emp, v_cli, 'pago', -v_total, p_forma_pago::forma_pago,
      p_pedido_id, 'pedido', v_usr);
  end if;

  -- 3) actualizar pedido
  update pedidos set
    estado = 'entregado',
    entregado = true,
    hoja_ruta_id = null,
    monto_efectivo = case when p_forma_pago = 'efectivo'      then v_total else 0 end,
    monto_transf   = case when p_forma_pago = 'transferencia' then v_total else 0 end,
    monto_cuenta   = case when p_forma_pago = 'cuenta_corriente' then v_total else 0 end,
    forma_pago     = p_forma_pago::forma_pago
  where id = p_pedido_id;
end;
$$;

grant execute on function public.marcar_pedido_entregado(uuid, text) to authenticated;
