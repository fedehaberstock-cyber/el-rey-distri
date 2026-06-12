-- ─────────────────────────────────────────────────────────────────────────
-- Hoja de ruta: separar cierre de día.
--   - Vista solo muestra pedidos pendientes (confirmados) en hojas abiertas
--     o sin asignar.
--   - Cierre: no entregados pasan al día siguiente con fecha_reparto+1 y
--     hoja_ruta_id=null (rollover automático).
-- ─────────────────────────────────────────────────────────────────────────

drop view if exists hoja_ruta_hoy;

create view hoja_ruta_hoy as
select p.id as pedido_id,
       p.empresa_id, p.fecha, p.fecha_reparto, p.estado, p.hoja_ruta_id,
       p.forma_pago, p.monto_efectivo, p.monto_transf, p.monto_cuenta, p.entregado,
       c.id as cliente_id, c.nombre as cliente_nombre, c.direccion, c.telefono,
       z.nombre as zona_nombre, z.orden as zona_orden, c.posicion_zona,
       u.nombre as preventista_nombre,
       b.total as total_boleta
  from pedidos p
  join clientes c on c.id = p.cliente_id
  left join zonas z on z.id = c.zona_id
  join usuarios u on u.id = p.usuario_id
  left join boletas b on b.pedido_id = p.id
 where p.estado = 'confirmado'::estado_pedido
   and p.fecha_reparto = (now() at time zone 'America/Argentina/Cordoba')::date
   and (
     p.hoja_ruta_id is null
     or exists (
       select 1 from hojas_ruta h
        where h.id = p.hoja_ruta_id and h.estado <> 'cerrada'
     )
   )
 order by z.orden, c.posicion_zona;

-- cerrar_hoja_ruta con rollover de no-entregados
create or replace function cerrar_hoja_ruta(p_hoja_id uuid) returns void
language plpgsql security definer
set search_path = 'public'
as $$
declare
  ped           record;
  emp_id        uuid;
  cobrador      uuid;
  tot_ef        numeric := 0;
  tot_tr        numeric := 0;
  tot_cc        numeric := 0;
  tot_ne        numeric := 0;
  cobrado_total numeric;
  contra_saldo  numeric;
  contra_pedido numeric;
begin
  select empresa_id, usuario_id into emp_id, cobrador
    from hojas_ruta where id = p_hoja_id;

  for ped in
    select p.*,
           b.total          as total_pedido,
           b.saldo_anterior as saldo_ant
      from pedidos p
      join boletas b on b.pedido_id = p.id
     where p.hoja_ruta_id = p_hoja_id
  loop

    -- NO ENTREGADO: rollover al día siguiente y desvincular de esta hoja
    if ped.entregado = false then
      tot_ne := tot_ne + coalesce(ped.total_pedido, 0) + coalesce(ped.saldo_ant, 0);
      update pedidos set
        hoja_ruta_id  = null,
        fecha_reparto = fecha_reparto + 1,
        estado        = 'confirmado',
        entregado     = null,
        motivo_no_entrega = null,
        monto_efectivo = 0, monto_transf = 0, monto_cuenta = 0
      where id = ped.id;
      continue;
    end if;

    cobrado_total := coalesce(ped.monto_efectivo,0)
                   + coalesce(ped.monto_transf,0)
                   + coalesce(ped.monto_cuenta,0);

    contra_saldo  := least(cobrado_total, coalesce(ped.saldo_ant, 0));
    contra_pedido := greatest(cobrado_total - contra_saldo, 0);

    if ped.monto_efectivo > 0 then
      insert into mov_cuenta (empresa_id, cliente_id, tipo, monto, forma_pago,
        referencia, referencia_tipo, usuario_id)
      values (emp_id, ped.cliente_id, 'pago', -ped.monto_efectivo,
        'efectivo', ped.id, 'hoja_ruta', cobrador);
      tot_ef := tot_ef + ped.monto_efectivo;
    end if;

    if ped.monto_transf > 0 then
      insert into mov_cuenta (empresa_id, cliente_id, tipo, monto, forma_pago,
        referencia, referencia_tipo, usuario_id)
      values (emp_id, ped.cliente_id, 'pago', -ped.monto_transf,
        'transferencia', ped.id, 'hoja_ruta', cobrador);
      tot_tr := tot_tr + ped.monto_transf;
    end if;

    if ped.monto_cuenta > 0 then
      tot_cc := tot_cc + ped.monto_cuenta;
    end if;

    update pedidos set
      forma_pago = case
        when ped.monto_efectivo > 0 and ped.monto_transf > 0 then 'mixto'::forma_pago
        when ped.monto_efectivo > 0 then 'efectivo'::forma_pago
        when ped.monto_transf   > 0 then 'transferencia'::forma_pago
        else 'cuenta_corriente'::forma_pago
      end,
      estado = 'entregado'
    where id = ped.id;

  end loop;

  update hojas_ruta set
    total_efectivo      = tot_ef,
    total_transf        = tot_tr,
    total_cuenta        = tot_cc,
    total_no_entregado  = tot_ne,
    estado              = 'cerrada',
    cerrada_en          = now()
  where id = p_hoja_id;
end;
$$;
