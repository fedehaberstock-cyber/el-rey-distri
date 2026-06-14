-- ─────────────────────────────────────────────────────────────────────────
-- Mejoras grandes — escenarios A (precios masivos), B (métricas
-- preventistas) y C (sugerencia de compra).
-- ─────────────────────────────────────────────────────────────────────────

-- ═════════ 1) UNIFICAR REDONDEO A 50/00 ═════════
-- Reemplaza la grilla 50/90/00 por 50/00 (más simple, más limpio).
create or replace function public.redondear_precio_50_90(p numeric)
  returns int
  language plpgsql immutable
as $$
declare
  base int;
  ult2 int;
  cien int;
begin
  if p is null or p <= 0 then return 0; end if;
  base := ceil(p)::int;
  ult2 := base % 100;
  cien := base - ult2;
  if ult2 = 0       then return base;
  elsif ult2 <= 50  then return cien + 50;
  else                   return cien + 100;
  end if;
end $$;

-- ═════════ 2) SUBCATEGORÍA EN PRODUCTOS (escenario A) ═════════
alter table public.productos
  add column if not exists subcategoria text;

create index if not exists productos_subcategoria_idx
  on public.productos (empresa_id, categoria, subcategoria);

-- ═════════ 3) AUDITORÍA DE AJUSTES MASIVOS (escenario A) ═════════
create table if not exists public.ajustes_precios_log (
  id                 uuid primary key default gen_random_uuid(),
  empresa_id         uuid not null references public.empresas(id) on delete cascade,
  usuario_id         uuid references public.usuarios(id),
  filtros            jsonb not null,            -- {categoria, subcategoria, proveedor_id, excluidos[]}
  porcentaje         numeric(6,2) not null,
  productos_afectados int not null,
  created_at         timestamptz not null default now()
);

create index if not exists ajustes_precios_log_emp_idx
  on public.ajustes_precios_log (empresa_id, created_at desc);

alter table public.ajustes_precios_log enable row level security;
drop policy if exists ajustes_precios_log_tenant on public.ajustes_precios_log;
create policy ajustes_precios_log_tenant on public.ajustes_precios_log
  using (empresa_id = public.empresa_actual())
  with check (empresa_id = public.empresa_actual());

-- ═════════ 4) VISITAS DE PREVENTISTA (escenario B) ═════════
create table if not exists public.visitas_clientes (
  id          uuid primary key default gen_random_uuid(),
  empresa_id  uuid not null references public.empresas(id) on delete cascade,
  cliente_id  uuid not null references public.clientes(id) on delete cascade,
  usuario_id  uuid not null references public.usuarios(id) on delete cascade,
  fecha       date not null default ((now() at time zone 'America/Argentina/Cordoba')::date),
  resultado   text not null check (resultado in ('pedido','sin_pedido')),
  motivo      text,
  pedido_id   uuid references public.pedidos(id) on delete set null,
  created_at  timestamptz not null default now()
);

create index if not exists visitas_usuario_fecha_idx
  on public.visitas_clientes (usuario_id, fecha);
create index if not exists visitas_cliente_idx
  on public.visitas_clientes (cliente_id, fecha desc);

alter table public.visitas_clientes enable row level security;

drop policy if exists visitas_clientes_acceso on public.visitas_clientes;
create policy visitas_clientes_acceso on public.visitas_clientes
  using (
    empresa_id = public.empresa_actual()
    and (
      public.rol_actual() = 'admin'
      or usuario_id = (
        select u.id from public.usuarios u where u.auth_id = auth.uid() limit 1
      )
    )
  )
  with check (empresa_id = public.empresa_actual());

-- ═════════ 5) DÍA DE LA SEMANA EN ZONAS (opcional, escenario B) ═════════
-- Para asociar zona a día (Lunes=1 ... Domingo=7) y saber qué clientes
-- "tocan visitar hoy" al medir conversión.
alter table public.zonas
  add column if not exists dia_semana int check (dia_semana between 1 and 7);

-- ═════════ 6) VISTA: VELOCIDAD DE VENTA Y SUGERENCIA DE COMPRA (escenario C) ═════════
-- Velocidad = unidades vendidas por día, últimas 28 días.
-- Calculada como sum(cantidad) de mov_stock tipo 'venta' / 28.
create or replace view public.velocidad_venta as
  select
    p.id as producto_id,
    p.empresa_id,
    coalesce(abs(sum(ms.cantidad)), 0)::numeric / 28.0 as unidades_por_dia
  from public.productos p
  left join public.mov_stock ms
    on ms.producto_id = p.id
   and ms.tipo = 'venta'
   and ms.fecha >= (now() - interval '28 days')
  where p.activo = true
  group by p.id, p.empresa_id;

-- Sugerencia de compra: por producto, calcula cuánto reponer para cubrir
-- los próximos `dias_objetivo` (del proveedor), descontando stock actual.
-- Solo sugiere productos cuyo stock proyectado se quede por debajo de
-- `dias_reorden` (umbral de alerta).
create or replace view public.sugerencia_compra as
  select
    p.id as producto_id,
    p.empresa_id,
    p.nombre,
    p.categoria,
    p.subcategoria,
    p.proveedor_id,
    pr.nombre as proveedor_nombre,
    coalesce(pr.dias_objetivo, 14) as dias_objetivo,
    coalesce(pr.dias_reorden, 7)  as dias_reorden,
    coalesce(s.stock, 0)           as stock_actual,
    coalesce(v.unidades_por_dia, 0) as velocidad,
    case when coalesce(v.unidades_por_dia, 0) > 0
         then floor(coalesce(s.stock, 0) / v.unidades_por_dia)::int
         else null
    end as dias_restantes,
    -- cantidad a comprar: (dias_objetivo × velocidad) − stock_actual, ceil
    greatest(0, ceil(coalesce(pr.dias_objetivo, 14)::numeric
                     * coalesce(v.unidades_por_dia, 0) - coalesce(s.stock, 0)))::int
      as cantidad_sugerida,
    p.costo as ultimo_costo
  from public.productos p
  left join public.stock_actual s   on s.producto_id = p.id
  left join public.velocidad_venta v on v.producto_id = p.id
  left join public.proveedores pr   on pr.id = p.proveedor_id
  where p.activo = true
    and coalesce(v.unidades_por_dia, 0) > 0
    and coalesce(s.stock, 0) <
        coalesce(pr.dias_reorden, 7)::numeric * coalesce(v.unidades_por_dia, 0);

-- ═════════ 7) PERMISOS ═════════
-- Los nuevos módulos reutilizan permisos existentes:
--   - "compras" / "ajustes de precio" → permiso 'catalogo' nivel editar (admin/deposito)
--   - "mis números" → cualquier preventista con permiso 'pedidos' nivel vista
-- No hace falta agregar nuevos módulos en `permisos`.
