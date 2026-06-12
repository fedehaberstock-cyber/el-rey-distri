-- ─────────────────────────────────────────────────────────────────────────
-- Storage bucket "productos" para fotos del catálogo.
-- Público (URLs accesibles sin auth) — solo admin/deposito pueden subir.
-- ─────────────────────────────────────────────────────────────────────────

insert into storage.buckets (id, name, public)
values ('productos', 'productos', true)
on conflict (id) do update set public = true;

-- Lectura pública
drop policy if exists "productos_read_public" on storage.objects;
create policy "productos_read_public" on storage.objects
  for select using (bucket_id = 'productos');

-- Subida/actualización/borrado: cualquier usuario autenticado
drop policy if exists "productos_write_auth" on storage.objects;
create policy "productos_write_auth" on storage.objects
  for all to authenticated
  using (bucket_id = 'productos')
  with check (bucket_id = 'productos');
