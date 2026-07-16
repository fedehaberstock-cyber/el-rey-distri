-- ═══ Ofertas: cantidad mínima, producto de regalo, stock máximo ═══
-- Agrega los campos necesarios para modelar ofertas del tipo
-- "compra N de X (opcionalmente aplicando desc de bulto) + M gratis de Y",
-- con un límite de stock disponible para la promo además del límite temporal.

alter table public.ofertas
  add column if not exists cantidad_min       integer not null default 1,
  add column if not exists aplica_desc_bulto  boolean not null default false,
  add column if not exists regalo_producto_id uuid references public.productos(id),
  add column if not exists regalo_cantidad    integer,
  add column if not exists stock_maximo       integer,
  add column if not exists stock_vendido      integer not null default 0;

-- Constraint: si hay regalo, la cantidad debe ser > 0
alter table public.ofertas drop constraint if exists ck_ofertas_regalo;
alter table public.ofertas add constraint ck_ofertas_regalo
  check (regalo_producto_id is null or (regalo_cantidad is not null and regalo_cantidad > 0));

comment on column public.ofertas.cantidad_min       is 'Unidades mínimas del producto principal para activar la oferta.';
comment on column public.ofertas.aplica_desc_bulto  is 'Si al alcanzar bultos completos también se aplica el desc_bulto del producto.';
comment on column public.ofertas.regalo_producto_id is 'Producto que se agrega sin cargo cuando se cumple la oferta.';
comment on column public.ofertas.regalo_cantidad    is 'Cantidad del producto de regalo.';
comment on column public.ofertas.stock_maximo       is 'Stock destinado a la promo (unidades del principal). NULL = sin límite.';
comment on column public.ofertas.stock_vendido      is 'Contador de unidades ya vendidas con esta oferta (para agotamiento).';
