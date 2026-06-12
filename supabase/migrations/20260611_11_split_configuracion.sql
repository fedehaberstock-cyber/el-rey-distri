-- Migrar permisos del módulo "configuracion" a los nuevos módulos
-- "catalogo" y "proveedores" (uno por uno).

insert into permisos (empresa_id, usuario_id, modulo, nivel)
select empresa_id, usuario_id, 'catalogo', nivel from permisos
 where modulo = 'configuracion'
on conflict (usuario_id, modulo) do update set nivel = excluded.nivel;

insert into permisos (empresa_id, usuario_id, modulo, nivel)
select empresa_id, usuario_id, 'proveedores', nivel from permisos
 where modulo = 'configuracion'
on conflict (usuario_id, modulo) do update set nivel = excluded.nivel;

delete from permisos where modulo = 'configuracion';
