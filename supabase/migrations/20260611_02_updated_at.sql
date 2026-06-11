-- =====================================================================
-- T-05a: Columna `updated_at` + trigger universal
--
-- Necesaria para sync delta: `sync_pull(last_sync)` filtra registros
-- modificados desde la última sincronización del cliente.
--
-- Se agrega a las 15 tablas (las vistas no la necesitan).
-- =====================================================================

create or replace function public.tg_set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- Itera sobre las 15 tablas y agrega columna + trigger
do $$
declare
  t text;
  tablas text[] := array[
    'empresas', 'usuarios', 'permisos',
    'clientes', 'zonas', 'proveedores', 'productos',
    'pedidos', 'pedido_items',
    'ingresos', 'ingreso_items',
    'boletas', 'hojas_ruta',
    'mov_stock', 'mov_cuenta'
  ];
begin
  foreach t in array tablas loop
    execute format(
      'alter table public.%I add column if not exists updated_at timestamptz not null default now()',
      t
    );
    execute format(
      'drop trigger if exists tg_%I_updated_at on public.%I',
      t, t
    );
    execute format(
      'create trigger tg_%I_updated_at before update on public.%I
       for each row execute function public.tg_set_updated_at()',
      t, t
    );
    -- índice para queries de sync (filtran por empresa + updated_at)
    if t in ('empresas') then
      execute format(
        'create index if not exists idx_%I_updated_at on public.%I (updated_at)',
        t, t
      );
    else
      execute format(
        'create index if not exists idx_%I_emp_updated on public.%I (empresa_id, updated_at)',
        t, t
      );
    end if;
  end loop;
end;
$$;
