-- ═══ Registro de comprobantes de transferencia ═══
-- Permite adjuntar foto del comprobante a cada cobro de transferencia
-- y marcarlo como conciliado contra el extracto bancario.

alter table public.mov_cuenta
  add column if not exists comprobante_url    text,
  add column if not exists referencia_externa text,
  add column if not exists conciliado         boolean not null default false,
  add column if not exists conciliado_en      timestamptz,
  add column if not exists conciliado_por     uuid references public.usuarios(id);

create index if not exists mov_cuenta_transf_no_concil_idx
  on public.mov_cuenta(empresa_id, conciliado)
  where forma_pago = 'transferencia' and tipo = 'pago' and conciliado = false;


-- ── Storage bucket "comprobantes" (publico para simplificar acceso) ─────
insert into storage.buckets (id, name, public)
values ('comprobantes', 'comprobantes', true)
on conflict (id) do update set public = true;

drop policy if exists "comprobantes_read_public" on storage.objects;
create policy "comprobantes_read_public" on storage.objects
  for select using (bucket_id = 'comprobantes');

drop policy if exists "comprobantes_write_auth" on storage.objects;
create policy "comprobantes_write_auth" on storage.objects
  for all to authenticated
  using (bucket_id = 'comprobantes')
  with check (bucket_id = 'comprobantes');
