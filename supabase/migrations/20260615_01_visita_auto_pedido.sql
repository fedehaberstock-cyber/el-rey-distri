-- ═════════ Trigger: auto-registrar visita 'pedido' al confirmar pedido ═════════
-- Cuando se inserta un pedido, registramos automáticamente una visita
-- con resultado='pedido' para que el % conversión funcione sin pedir esfuerzo extra.

create or replace function public.trg_visita_auto_pedido()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if NEW.usuario_id is null then
    return NEW;
  end if;
  insert into public.visitas_clientes
    (empresa_id, cliente_id, usuario_id, fecha, resultado, pedido_id)
  values
    (NEW.empresa_id, NEW.cliente_id, NEW.usuario_id,
     (NEW.fecha at time zone 'America/Argentina/Cordoba')::date,
     'pedido', NEW.id);
  return NEW;
end $$;

drop trigger if exists pedidos_visita_auto on public.pedidos;
create trigger pedidos_visita_auto
  after insert on public.pedidos
  for each row execute function public.trg_visita_auto_pedido();
