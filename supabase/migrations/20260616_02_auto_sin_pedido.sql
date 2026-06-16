-- ═══ Auto "sin pedido" al cierre del día ═══
-- Cuando el preventista abre la app un día nuevo, todos los clientes de su
-- zona del día anterior que quedaron sin acción se marcan como sin_pedido.
-- Idempotente: usa NOT EXISTS, se puede llamar N veces sin duplicar.

create or replace function public.cerrar_dia_anterior_visitas()
returns int
language plpgsql security definer
set search_path = 'public'
as $$
declare
  v_ayer       date;
  v_usr        uuid;
  v_emp        uuid;
  v_dow        int;
  v_insertados int := 0;
begin
  v_ayer := (now() at time zone 'America/Argentina/Cordoba')::date - 1;

  select id, empresa_id into v_usr, v_emp
    from usuarios where auth_id = auth.uid() limit 1;
  if v_usr is null then return 0; end if;

  -- dow: 0=domingo, 6=sábado (igual que extract(dow) y JS)
  v_dow := extract(dow from v_ayer)::int;

  -- clientes de las zonas que reparten ayer Y están asignadas al preventista,
  -- que no tienen registro de visita para ese día
  with ins as (
    insert into visitas_clientes (empresa_id, usuario_id, cliente_id, fecha, resultado, motivo)
    select v_emp, v_usr, c.id, v_ayer, 'sin_pedido', 'auto: cierre de día'
    from clientes c
    join zonas z on z.id = c.zona_id
    where z.activa = true
      and z.dias_semana @> array[v_dow]
      and (
        z.usuarios_ids is null
        or array_length(z.usuarios_ids, 1) is null
        or v_usr = any(z.usuarios_ids)
      )
      and c.activo = true
      and not exists (
        select 1 from visitas_clientes vc
        where vc.usuario_id = v_usr
          and vc.cliente_id = c.id
          and vc.fecha = v_ayer
      )
    returning 1
  )
  select count(*) into v_insertados from ins;

  return v_insertados;
end;
$$;
