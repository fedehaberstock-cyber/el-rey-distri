-- ─────────────────────────────────────────────────────────────────────────
-- Fix del índice único de alias_productos.
-- El índice funcional sobre lower(alias_text) no matcheaba el ON CONFLICT
-- (Postgres requiere que la columna del conflicto coincida exactamente).
-- Lo reemplazamos por una unique constraint normal sobre alias_text;
-- el frontend ahora guarda el texto siempre en minúsculas.
-- ─────────────────────────────────────────────────────────────────────────

-- Normalizar las filas existentes (por si hay alguna mezclada en mayúsculas).
update public.alias_productos
   set alias_text = lower(alias_text)
 where alias_text <> lower(alias_text);

-- Borrar duplicados que pudieran haber quedado por el bug previo,
-- conservando la fila más reciente (mayor updated_at).
delete from public.alias_productos a
 using public.alias_productos b
 where a.empresa_id = b.empresa_id
   and a.proveedor_id = b.proveedor_id
   and a.alias_text = b.alias_text
   and a.updated_at < b.updated_at;

drop index if exists public.alias_productos_uq;

alter table public.alias_productos
  drop constraint if exists alias_productos_uq;

alter table public.alias_productos
  add constraint alias_productos_uq
  unique (empresa_id, proveedor_id, alias_text);
