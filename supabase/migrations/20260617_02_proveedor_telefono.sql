-- ═══ Teléfono del proveedor para WhatsApp directo desde Compras ═══
-- Formato esperado: internacional sin "+" ni espacios (ej: 5493511234567).

alter table public.proveedores
  add column if not exists telefono text;
