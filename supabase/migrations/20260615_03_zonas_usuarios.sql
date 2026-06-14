-- ═══════ Zonas: acceso por usuario ═══════
-- Cada zona puede asignarse a uno o varios usuarios (preventistas).
-- Se guarda como array de uuid (sin FK por ser array; se valida en la app).
-- Si está vacío, la zona no se filtra por usuario (la ven todos / solo admin).

alter table public.zonas
  add column if not exists usuarios_ids uuid[] not null default '{}'::uuid[];
