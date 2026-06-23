-- ═══ Ofertas vigentes + integracion en rpc_sugerencias_cliente ═══
-- Tabla simple para administrar ofertas con vigencia. La RPC las
-- expone en el bloque 'ofertas' cuando se llama por cliente.

create table if not exists public.ofertas (
  id              uuid primary key default gen_random_uuid(),
  empresa_id      uuid not null references public.empresas(id) on delete cascade,
  producto_id     uuid not null references public.productos(id) on delete cascade,
  descripcion     text not null,
  precio_oferta   numeric(12,2),                                -- opcional
  vigente_desde   date not null default current_date,
  vigente_hasta   date,                                         -- null = sin vencimiento
  prioridad       int  not null default 0,                      -- mayor = aparece primero
  activa          boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create index if not exists ofertas_emp_idx on public.ofertas(empresa_id, activa);
create index if not exists ofertas_prod_idx on public.ofertas(producto_id);

alter table public.ofertas enable row level security;
drop policy if exists tenant on public.ofertas;
create policy tenant on public.ofertas
  using (empresa_id = public.empresa_actual())
  with check (empresa_id = public.empresa_actual());

drop trigger if exists tg_updated_at_ofertas on public.ofertas;
create trigger tg_updated_at_ofertas
  before update on public.ofertas
  for each row execute function public.tg_set_updated_at();


-- ── Reemplazo de la RPC para incluir ofertas vigentes ─────────────────
create or replace function public.rpc_sugerencias_cliente(p_cliente_id uuid)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare
  v_emp uuid := public.empresa_actual();
  v_hace_90 date := (current_date - 90);
  v_hace_180 date := (current_date - 180);
  v_hace_30 date := (current_date - 30);
  v_hace_7  date := (current_date - 7);
  v_umbral_pen_sub      numeric := 0.25;
  v_umbral_pen_producto numeric := 0.15;
  v_ventana_pedidos int := 10;
  v_umbral_recurrencia numeric := 0.3;
  v_min_apariciones int := 2;
  v_top_siempre int := 30;
  v_top_gap int := 10;
  v_top_novedades int := 10;
  v_top_ofertas int := 15;
  v_total_activos int;
  v_lo_de_siempre jsonb;
  v_gap jsonb;
  v_novedades jsonb;
  v_ofertas jsonb;
begin
  if v_emp is null then
    select empresa_id into v_emp from clientes where id = p_cliente_id;
  end if;
  if v_emp is null then raise exception 'empresa no resuelta'; end if;

  select count(distinct cliente_id) into v_total_activos
    from pedidos
   where empresa_id = v_emp
     and estado != 'anulado'
     and fecha::date >= v_hace_90
     and cliente_id is not null;
  if coalesce(v_total_activos, 0) = 0 then v_total_activos := 1; end if;

  -- ── 1. Lo de siempre (relativo al cliente) ─────────────────────────────
  with ultimos_pedidos as (
    select p.id, p.fecha::date as fecha
      from pedidos p
     where p.empresa_id = v_emp
       and p.cliente_id = p_cliente_id
       and p.estado != 'anulado'
     order by p.fecha desc
     limit v_ventana_pedidos
  ),
  total_pedidos as (select count(*)::int as n from ultimos_pedidos),
  items_ventana as (
    select pi.producto_id, pi.cantidad, up.fecha
      from ultimos_pedidos up
      join pedido_items pi on pi.pedido_id = up.id
  ),
  freq_producto as (
    select producto_id,
           count(distinct fecha) as veces,
           max(fecha) as ultima_compra,
           min(fecha) as primera_compra,
           percentile_cont(0.5) within group (order by cantidad) as cant_mediana
      from items_ventana
     group by producto_id
  ),
  compras_cli as (
    select fp.producto_id, fp.veces, fp.ultima_compra, fp.cant_mediana,
           case when fp.veces >= 2
                then ((fp.ultima_compra - fp.primera_compra)::int / nullif(fp.veces - 1, 0))
                else null end as frec_dias
      from freq_producto fp, total_pedidos tp
     where fp.veces >= greatest(v_min_apariciones, ceil(tp.n * v_umbral_recurrencia)::int)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'producto_id', t.producto_id, 'nombre', t.nombre,
    'categoria', t.categoria, 'subcategoria', t.subcategoria,
    'cantidad_tipica', t.cantidad_tipica, 'veces', t.veces,
    'dias_ultima', t.dias_ultima, 'frec_dias', t.frec_dias,
    'urgente', t.urgente,
    'stock', t.stock, 'precio', t.precio
  ) order by t.urgente desc, t.veces desc, t.dias_ultima asc), '[]'::jsonb)
    into v_lo_de_siempre
    from (
      select cc.producto_id, pr.nombre, pr.categoria, pr.subcategoria,
             greatest(round(cc.cant_mediana)::int, 1) as cantidad_tipica,
             cc.veces,
             (current_date - cc.ultima_compra)::int as dias_ultima,
             cc.frec_dias,
             coalesce(cc.frec_dias is not null
                      and (current_date - cc.ultima_compra)::int > cc.frec_dias * 2, false) as urgente,
             coalesce(s.stock, 0) as stock,
             pr.precio
        from compras_cli cc
        join productos pr on pr.id = cc.producto_id and pr.activo = true
        left join stock_actual s on s.producto_id = pr.id
       order by cc.veces desc, cc.ultima_compra desc
       limit v_top_siempre
    ) t;

  -- ── 2. Gap (mixto sub/producto) ────────────────────────────────────────
  with penetracion as (
    select coalesce(nullif(btrim(pr.subcategoria),''), pr.nombre) as clave,
           max(case when pr.subcategoria is null or btrim(pr.subcategoria) = ''
                    then 'producto' else 'subcategoria' end) as tipo,
           count(distinct p.cliente_id) as clientes_que_compran
      from pedidos p
      join pedido_items pi on pi.pedido_id = p.id
      join productos pr on pr.id = pi.producto_id
     where p.empresa_id = v_emp
       and p.estado != 'anulado'
       and p.fecha::date >= v_hace_90
       and pr.activo = true
     group by coalesce(nullif(btrim(pr.subcategoria),''), pr.nombre)
  ),
  compradas_por_cli as (
    select distinct coalesce(nullif(btrim(pr.subcategoria),''), pr.nombre) as clave
      from pedidos p
      join pedido_items pi on pi.pedido_id = p.id
      join productos pr on pr.id = pi.producto_id
     where p.empresa_id = v_emp
       and p.cliente_id = p_cliente_id
       and p.estado != 'anulado'
       and p.fecha::date >= v_hace_30
  ),
  gaps as (
    select pen.clave, pen.tipo, pen.clientes_que_compran,
           round(pen.clientes_que_compran::numeric / v_total_activos * 100, 1) as penetracion_pct
      from penetracion pen
     where pen.clientes_que_compran::numeric / v_total_activos >= (
             case when pen.tipo = 'producto' then v_umbral_pen_producto
                  else v_umbral_pen_sub end
           )
       and not exists (select 1 from compradas_por_cli c where c.clave = pen.clave)
     order by clientes_que_compran desc
     limit v_top_gap
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'clave', g.clave, 'tipo', g.tipo,
    'penetracion_pct', g.penetracion_pct, 'clientes', g.clientes_que_compran,
    'productos', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'producto_id', t.id, 'nombre', t.nombre, 'categoria', t.categoria,
        'precio', t.precio, 'stock', t.stock
      ) order by t.stock desc, t.nombre), '[]'::jsonb)
      from (
        select pr.id, pr.nombre, pr.categoria, pr.precio, coalesce(s.stock, 0) as stock
          from productos pr
          left join stock_actual s on s.producto_id = pr.id
         where pr.empresa_id = v_emp and pr.activo = true
           and coalesce(nullif(btrim(pr.subcategoria),''), pr.nombre) = g.clave
           and coalesce(s.stock, 0) > 0
         order by coalesce(s.stock, 0) desc, pr.nombre
      ) t
    )
  ) order by g.penetracion_pct desc), '[]'::jsonb)
    into v_gap
    from gaps g;

  -- ── 3. Novedades ───────────────────────────────────────────────────────
  with comprados_alguna_vez as (
    select distinct pi.producto_id
      from pedidos p
      join pedido_items pi on pi.pedido_id = p.id
     where p.empresa_id = v_emp
       and p.cliente_id = p_cliente_id
       and p.estado != 'anulado'
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'producto_id', t.id, 'nombre', t.nombre, 'categoria', t.categoria,
    'subcategoria', t.subcategoria, 'precio', t.precio,
    'stock', t.stock, 'creado_en', t.creado_en
  ) order by t.creado_en desc), '[]'::jsonb)
    into v_novedades
    from (
      select pr.id, pr.nombre, pr.categoria, pr.subcategoria, pr.precio,
             coalesce(s.stock, 0) as stock, pr.creado_en
        from productos pr
        left join stock_actual s on s.producto_id = pr.id
       where pr.empresa_id = v_emp and pr.activo = true
         and pr.creado_en::date >= v_hace_7
         and coalesce(s.stock, 0) > 0
         and not exists (select 1 from comprados_alguna_vez c where c.producto_id = pr.id)
       order by pr.creado_en desc
       limit v_top_novedades
    ) t;

  -- ── 4. Ofertas vigentes ────────────────────────────────────────────────
  select coalesce(jsonb_agg(jsonb_build_object(
    'oferta_id',     t.id,
    'producto_id',   t.producto_id,
    'nombre',        t.nombre,
    'categoria',     t.categoria,
    'subcategoria',  t.subcategoria,
    'descripcion',   t.descripcion,
    'precio_normal', t.precio_normal,
    'precio_oferta', t.precio_oferta,
    'vigente_hasta', t.vigente_hasta,
    'stock',         t.stock,
    'prioridad',     t.prioridad
  ) order by t.prioridad desc, t.vigente_hasta asc nulls last), '[]'::jsonb)
    into v_ofertas
    from (
      select o.id, o.producto_id, pr.nombre, pr.categoria, pr.subcategoria,
             o.descripcion, pr.precio as precio_normal, o.precio_oferta,
             o.vigente_hasta, coalesce(s.stock, 0) as stock, o.prioridad
        from ofertas o
        join productos pr on pr.id = o.producto_id and pr.activo = true
        left join stock_actual s on s.producto_id = o.producto_id
       where o.empresa_id = v_emp
         and o.activa = true
         and o.vigente_desde <= current_date
         and (o.vigente_hasta is null or o.vigente_hasta >= current_date)
         and coalesce(s.stock, 0) > 0
       order by o.prioridad desc, o.vigente_hasta asc nulls last
       limit v_top_ofertas
    ) t;

  return jsonb_build_object(
    'cliente_id',                  p_cliente_id,
    'denominador_clientes_activos', v_total_activos,
    'umbral_pen_sub',              v_umbral_pen_sub,
    'umbral_pen_producto',         v_umbral_pen_producto,
    'ventana_pedidos',             v_ventana_pedidos,
    'umbral_recurrencia',          v_umbral_recurrencia,
    'lo_de_siempre',               v_lo_de_siempre,
    'gap_sugeridos',               v_gap,
    'novedades',                   v_novedades,
    'ofertas',                     v_ofertas,
    'generado_en',                 now()
  );
end;
$$;

grant execute on function public.rpc_sugerencias_cliente(uuid) to authenticated;
