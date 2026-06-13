-- ─────────────────────────────────────────────────────────────────────────
-- Re-normalizar alias_text con el mismo criterio que ahora usa el front:
--   - lower
--   - sin acentos (unaccent o regex)
--   - puntuación → espacio
--   - espacios colapsados
--   - trim
-- Después dedupea por la nueva clave normalizada conservando el más reciente.
-- ─────────────────────────────────────────────────────────────────────────

-- 1) Función helper igual a la del front
create or replace function public.normalizar_alias(s text)
  returns text
  language sql immutable
as $$
  select trim(regexp_replace(
    regexp_replace(
      lower(translate(coalesce(s,''),
        'áéíóúÁÉÍÓÚñÑäëïöüÄËÏÖÜ',
        'aeiouAEIOUnNaeiouAEIOU')),
      '[.,;:()\[\]{}''"`´]', ' ', 'g'),
    '\s+', ' ', 'g'))
$$;

-- 2) Re-escribir todos los alias_text usando la función
update public.alias_productos
   set alias_text = public.normalizar_alias(alias_text)
 where alias_text is distinct from public.normalizar_alias(alias_text);

-- 3) Dedupe — si después de normalizar quedaron filas duplicadas,
--    nos quedamos con la más reciente (mayor updated_at).
delete from public.alias_productos a
 using public.alias_productos b
 where a.empresa_id   = b.empresa_id
   and a.proveedor_id = b.proveedor_id
   and a.alias_text   = b.alias_text
   and a.updated_at   < b.updated_at;
