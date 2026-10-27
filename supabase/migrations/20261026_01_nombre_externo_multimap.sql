-- ═══ Permitir mapeo 1:N entre nombre externo del proveedor y productos ═══
-- Hasta ahora un nombre externo (ej. "Huggies x8u") mapeaba a UN producto.
-- Pero muchos proveedores publican una lista con un ítem genérico mientras
-- vos tenés varios productos cargados (tamaño M, G, XG). Para cubrir ese caso
-- quitamos el unique(proveedor_id, nombre_norm) y permitimos múltiples filas
-- con el mismo nombre_norm: cada una asocia el nombre externo a un producto
-- distinto, con su propio factor_conversion.

alter table public.nombre_externo_proveedor
  drop constraint if exists nombre_externo_proveedor_proveedor_id_nombre_norm_key;
