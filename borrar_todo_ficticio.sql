-- ═══ RESET COMPLETO DE OPERACIONES + PRODUCTOS (datos ficticios) ═══
-- BORRA:  productos, stock, pedidos, boletas, hojas de ruta, ingresos, mov_cuenta,
--         visitas, ajustes de precios, alias de productos.
-- CONSERVA: empresas, usuarios, permisos, zonas, clientes, proveedores, categorias_markup.
--
-- Ejecutar en Supabase SQL Editor con "Run without RLS".

begin;

truncate table
  public.mov_stock,
  public.mov_cuenta,
  public.pedido_items,
  public.boletas,
  public.pedidos,
  public.hojas_ruta,
  public.visitas_clientes,
  public.ingreso_items,
  public.ingresos,
  public.ajustes_precios_log,
  public.alias_productos,
  public.productos
cascade;

-- conteos finales para verificar
do $$
declare
  c_prod int; c_ped int; c_bol int; c_mov_stock int; c_mov_cta int;
  c_cli int; c_prv int; c_zon int;
begin
  select count(*) into c_prod from public.productos;
  select count(*) into c_ped from public.pedidos;
  select count(*) into c_bol from public.boletas;
  select count(*) into c_mov_stock from public.mov_stock;
  select count(*) into c_mov_cta from public.mov_cuenta;
  select count(*) into c_cli from public.clientes;
  select count(*) into c_prv from public.proveedores;
  select count(*) into c_zon from public.zonas;
  raise notice 'Productos: %  Pedidos: %  Boletas: %  Mov_stock: %  Mov_cuenta: %', c_prod, c_ped, c_bol, c_mov_stock, c_mov_cta;
  raise notice 'Conservados → Clientes: %  Proveedores: %  Zonas: %', c_cli, c_prv, c_zon;
end $$;

commit;
