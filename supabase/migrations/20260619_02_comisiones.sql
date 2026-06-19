-- ═══ Comisiones de preventistas ═══
-- Cada usuario puede tener:
--   - comision_tipo = 'porcentaje' → comision_valor = % sobre sus ventas
--   - comision_tipo = 'fijo'       → comision_valor = monto mensual (prorrateado)
--   - comision_tipo = 'ninguno'    → no se descuenta (default)

do $$
begin
  if not exists (select 1 from pg_type where typname = 'tipo_comision') then
    create type public.tipo_comision as enum ('ninguno','porcentaje','fijo');
  end if;
end$$;

alter table public.usuarios
  add column if not exists comision_tipo  public.tipo_comision not null default 'ninguno',
  add column if not exists comision_valor numeric(12,2) not null default 0;
