-- ═══ Auto sin_pedido: extender a N días para atrás ═══
-- Antes procesaba solo ayer. Ahora procesa los últimos p_dias (default 3)
-- para cubrir casos en que el preventista no abre la app varios días.
-- Sigue siendo idempotente (NOT EXISTS).

create or replace function public.cerrar_dia_anterior_visitas(p_dias int default 3)
returns int
language plpgsql security definer
set search_path = 'public'
as $$
declare
  v_hoy        date := (now() at time zone 'America/Argentina/Cordoba')::date;
  v_usr        uuid;
  v_emp        uuid;
  v_dia        date;
  v_dow        int;
  v_insertados int := 0;
  v_ins        int;
begin
  select id, empresa_id into v_usr, v_emp
    from usuarios where auth_id = auth.uid() limit 1;
  if v_usr is null then return 0; end if;

  -- recorrer del día más cercano al más lejano: ayer, anteayer, ...
  for i in 1..greatest(p_dias, 1) loop
    v_dia := v_hoy - i;
    v_dow := extract(dow from v_dia)::int;

    with ins as (
      insert into visitas_clientes (empresa_id, usuario_id, cliente_id, fecha, resultado, motivo)
      select v_emp, v_usr, c.id, v_dia, 'sin_pedido', 'auto: cierre de día'
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
            and vc.fecha = v_dia
        )
      returning 1
    )
    select count(*) into v_ins from ins;
    v_insertados := v_insertados + v_ins;
  end loop;

  return v_insertados;
end;
$$;
