-- ── T-27 Observabilidad · Tabla errores_frontend ─────────────────────────
-- Recibe logs de errores JS desde el cliente.
-- Admins leen, usuarios autenticados insertan.

create table if not exists errores_frontend (
  id          uuid        primary key default gen_random_uuid(),
  empresa_id  uuid        references empresas(id)  on delete set null,
  usuario_id  uuid        references usuarios(id)  on delete set null,
  pagina      text,
  mensaje     text        not null,
  stack       text,
  contexto    jsonb,
  created_at  timestamptz not null default now()
);

alter table errores_frontend enable row level security;

-- Administradores pueden leer todos los errores de su empresa
create policy "admins leen errores de su empresa"
  on errores_frontend for select
  using (
    exists (
      select 1 from usuarios u
      where u.id = auth.uid() and u.rol = 'admin'
        and (u.empresa_id = errores_frontend.empresa_id
             or errores_frontend.empresa_id is null)
    )
  );

-- Cualquier usuario autenticado puede insertar
create policy "usuarios autenticados insertan errores"
  on errores_frontend for insert
  with check (auth.uid() is not null);

-- Índices para consultar por empresa/fecha
create index if not exists errores_frontend_empresa_created
  on errores_frontend (empresa_id, created_at desc);

create index if not exists errores_frontend_usuario
  on errores_frontend (usuario_id);
