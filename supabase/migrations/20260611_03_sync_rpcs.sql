-- =====================================================================
-- T-05b: RPCs `sync_pull` y `sync_push`
--
-- sync_pull(last_sync): devuelve deltas de las tablas que el cliente
--   necesita cachear localmente. SECURITY INVOKER → respeta RLS del
--   usuario (multi-empresa + visibilidad por rol).
--
-- sync_push(ops[]): procesa operaciones offline en savepoints. Cada op
--   tiene { idx, op, payload }. Devuelve { ok: [...], rechazos: [...] }.
--   Si una op falla, las demás siguen.
-- =====================================================================

-- ---------- sync_pull ----------
create or replace function public.sync_pull(p_last_sync timestamptz default null)
returns jsonb
language plpgsql
security invoker
set search_path to 'public'
as $$
declare
  v_emp uuid := public.empresa_actual();
  v_since timestamptz := coalesce(p_last_sync, 'epoch'::timestamptz);
  v_result jsonb;
begin
  if v_emp is null then
    raise exception 'sin contexto de empresa';
  end if;

  select jsonb_build_object(
    'server_time', now(),
    'empresas',         (select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from empresas t       where t.id = v_emp and t.updated_at > v_since),
    'usuarios',         (select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from usuarios t       where t.updated_at > v_since),
    'permisos',         (select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from permisos t       where t.updated_at > v_since),
    'zonas',            (select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from zonas t          where t.updated_at > v_since),
    'proveedores',      (select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from proveedores t    where t.updated_at > v_since),
    'productos',        (select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from productos t      where t.updated_at > v_since),
    'clientes',         (select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from clientes t       where t.updated_at > v_since),
    'pedidos',          (select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from pedidos t        where t.updated_at > v_since),
    'pedido_items',     (select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from pedido_items t   where t.updated_at > v_since),
    'boletas',          (select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from boletas t        where t.updated_at > v_since),
    'hojas_ruta',       (select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from hojas_ruta t     where t.updated_at > v_since),
    'mov_stock',        (select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from mov_stock t      where t.updated_at > v_since),
    'mov_cuenta',       (select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from mov_cuenta t     where t.updated_at > v_since),
    -- vistas materializables — siempre snapshot completo (son livianas)
    'stock_actual',     (select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from stock_actual t),
    'saldo_actual',     (select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from saldo_actual t)
  )
  into v_result;

  return v_result;
end;
$$;

comment on function public.sync_pull(timestamptz) is
'Devuelve registros modificados desde p_last_sync filtrados por RLS. Cliente lo usa para mantener cache local actualizado.';

-- ---------- sync_push ----------
create or replace function public.sync_push(p_ops jsonb)
returns jsonb
language plpgsql
security invoker
set search_path to 'public'
as $$
declare
  v_op       jsonb;
  v_idx      int;
  v_kind     text;
  v_payload  jsonb;
  v_result   jsonb;
  v_ok       jsonb := '[]'::jsonb;
  v_rejects  jsonb := '[]'::jsonb;
  v_errmsg   text;
begin
  if jsonb_typeof(p_ops) <> 'array' then
    raise exception 'p_ops debe ser un array';
  end if;

  for v_op in select * from jsonb_array_elements(p_ops) loop
    v_idx     := (v_op->>'idx')::int;
    v_kind    := v_op->>'op';
    v_payload := v_op->'payload';

    begin
      case v_kind
        when 'confirmar_pedido' then
          v_result := public.confirmar_pedido(v_payload);

        when 'confirmar_ingreso' then
          perform public.confirmar_ingreso((v_payload->>'ingreso_id')::uuid);
          v_result := jsonb_build_object('ok', true);

        when 'cerrar_hoja_ruta' then
          perform public.cerrar_hoja_ruta((v_payload->>'hoja_id')::uuid);
          v_result := jsonb_build_object('ok', true);

        when 'cobro_manual' then
          insert into mov_cuenta
            (empresa_id, cliente_id, tipo, monto, forma_pago,
             referencia_tipo, usuario_id, fecha)
          values
            (public.empresa_actual(),
             (v_payload->>'cliente_id')::uuid,
             'pago',
             -(v_payload->>'monto')::numeric,
             (v_payload->>'forma_pago')::forma_pago,
             'ajuste_manual',
             (select id from usuarios where auth_id = auth.uid() limit 1),
             coalesce((v_payload->>'fecha')::timestamptz, now()))
          returning id into v_result;
          v_result := jsonb_build_object('mov_cuenta_id', v_result);

        when 'ajuste_stock' then
          insert into mov_stock
            (empresa_id, producto_id, tipo, cantidad,
             referencia_tipo, usuario_id, fecha)
          values
            (public.empresa_actual(),
             (v_payload->>'producto_id')::uuid,
             'ajuste',
             (v_payload->>'cantidad')::integer,
             'ajuste_manual',
             (select id from usuarios where auth_id = auth.uid() limit 1),
             coalesce((v_payload->>'fecha')::timestamptz, now()))
          returning id into v_result;
          v_result := jsonb_build_object('mov_stock_id', v_result);

        else
          raise exception 'operación no soportada: %', v_kind;
      end case;

      v_ok := v_ok || jsonb_build_object('idx', v_idx, 'result', v_result);

    exception when others then
      v_errmsg := SQLERRM;
      v_rejects := v_rejects || jsonb_build_object(
        'idx', v_idx, 'op', v_kind, 'error', v_errmsg
      );
    end;
  end loop;

  return jsonb_build_object('ok', v_ok, 'rechazos', v_rejects);
end;
$$;

comment on function public.sync_push(jsonb) is
'Procesa lote de operaciones offline. Cada op: {idx, op, payload}. Falla parcialmente: las exitosas se aplican, las rechazadas vuelven con error.';
