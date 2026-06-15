-- ═══ Registro de dispositivos (auditoría, sin bloqueo) ═══
-- Cada navegador genera un device_id (uuid) en localStorage y lo registra
-- al loguearse. Permite ver cuántos dispositivos distintos usa cada cuenta.

create table if not exists public.dispositivos (
  id          uuid primary key default gen_random_uuid(),
  empresa_id  uuid not null references public.empresas(id) on delete cascade,
  usuario_id  uuid not null references public.usuarios(id) on delete cascade,
  device_id   text not null,                          -- uuid del navegador
  user_agent  text,                                   -- navegador/SO
  primer_uso  timestamptz not null default now(),
  ultimo_uso  timestamptz not null default now(),
  accesos     int not null default 1,
  unique (usuario_id, device_id)
);

create index if not exists dispositivos_usuario_idx
  on public.dispositivos (usuario_id, ultimo_uso desc);

alter table public.dispositivos enable row level security;

drop policy if exists dispositivos_tenant on public.dispositivos;
create policy dispositivos_tenant on public.dispositivos
  using  (empresa_id = public.empresa_actual())
  with check (empresa_id = public.empresa_actual());

-- RPC que el cliente llama en cada login: upsert por (usuario_id, device_id)
create or replace function public.registrar_dispositivo(p_device_id text, p_user_agent text)
returns void
language plpgsql security definer
set search_path = 'public'
as $$
declare
  v_emp uuid; v_usr uuid;
begin
  select id, empresa_id into v_usr, v_emp
    from usuarios where auth_id = auth.uid() limit 1;
  if v_usr is null then return; end if;
  if p_device_id is null or btrim(p_device_id) = '' then return; end if;

  insert into dispositivos (empresa_id, usuario_id, device_id, user_agent)
  values (v_emp, v_usr, p_device_id, left(coalesce(p_user_agent,''), 500))
  on conflict (usuario_id, device_id) do update
    set ultimo_uso = now(),
        accesos    = dispositivos.accesos + 1,
        user_agent = coalesce(excluded.user_agent, dispositivos.user_agent);
end $$;
