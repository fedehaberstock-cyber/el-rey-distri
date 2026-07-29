-- ═══ Permitir fecha_reparto NULL en pedidos ══════════════════════════════
-- Requerido para clientes sin zona / zona a_definir / no_reparte, donde
-- el pedido queda pendiente de programar fecha desde Pendientes.

alter table public.pedidos alter column fecha_reparto drop not null;
