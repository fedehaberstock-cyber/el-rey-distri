--
-- PostgreSQL database dump
--

\restrict MpbhTfa0Hax4QX5bD7crCXg8msLkqWTjoU13ceUyHkNzGtuO1gKbalzUxAjDlLC

-- Dumped from database version 17.6
-- Dumped by pg_dump version 18.4

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA public;


--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA public IS 'standard public schema';


--
-- Name: estado_boleta; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.estado_boleta AS ENUM (
    'emitida',
    'modificada',
    'anulada'
);


--
-- Name: estado_hoja_ruta; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.estado_hoja_ruta AS ENUM (
    'pendiente',
    'en_reparto',
    'cerrada'
);


--
-- Name: estado_pedido; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.estado_pedido AS ENUM (
    'borrador',
    'confirmado',
    'entregado',
    'no_entregado',
    'postergado',
    'anulado'
);


--
-- Name: forma_pago; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.forma_pago AS ENUM (
    'efectivo',
    'transferencia',
    'cuenta_corriente',
    'mixto'
);


--
-- Name: nivel_permiso; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.nivel_permiso AS ENUM (
    'ninguno',
    'vista',
    'crear',
    'editar',
    'admin'
);


--
-- Name: rol_usuario; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.rol_usuario AS ENUM (
    'admin',
    'preventista',
    'deposito'
);


--
-- Name: tipo_mov_cuenta; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.tipo_mov_cuenta AS ENUM (
    'cargo',
    'pago',
    'ajuste'
);


--
-- Name: tipo_mov_stock; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.tipo_mov_stock AS ENUM (
    'ingreso',
    'venta',
    'ajuste',
    'devolucion'
);


--
-- Name: cerrar_hoja_ruta(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.cerrar_hoja_ruta(p_hoja_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  ped           record;
  emp_id        uuid;
  cobrador      uuid;
  tot_ef        numeric := 0;
  tot_tr        numeric := 0;
  tot_cc        numeric := 0;
  tot_ne        numeric := 0;
  cobrado_total numeric;
  contra_saldo  numeric;
  contra_pedido numeric;
begin
  select empresa_id, usuario_id into emp_id, cobrador
  from hojas_ruta where id = p_hoja_id;

  for ped in
    select p.*,
           b.total          as total_pedido,
           b.saldo_anterior as saldo_ant
    from pedidos p
    join boletas b on b.pedido_id = p.id
    where p.hoja_ruta_id = p_hoja_id
  loop

    -- NO ENTREGADO: acumular y saltar
    if ped.entregado = false then
      tot_ne := tot_ne + coalesce(ped.total_pedido, 0) + coalesce(ped.saldo_ant, 0);
      continue;
    end if;

    cobrado_total := coalesce(ped.monto_efectivo,0)
                   + coalesce(ped.monto_transf,0)
                   + coalesce(ped.monto_cuenta,0);

    -- Imputación: primero cancela saldo anterior, después el pedido nuevo
    contra_saldo  := least(cobrado_total, coalesce(ped.saldo_ant, 0));
    contra_pedido := greatest(cobrado_total - contra_saldo, 0);

    -- EFECTIVO
    if ped.monto_efectivo > 0 then
      insert into mov_cuenta
        (empresa_id, cliente_id, tipo, monto, forma_pago,
         referencia, referencia_tipo, usuario_id)
      values
        (emp_id, ped.cliente_id, 'pago', -ped.monto_efectivo,
         'efectivo', ped.id, 'hoja_ruta', cobrador);
      tot_ef := tot_ef + ped.monto_efectivo;
    end if;

    -- TRANSFERENCIA
    if ped.monto_transf > 0 then
      insert into mov_cuenta
        (empresa_id, cliente_id, tipo, monto, forma_pago,
         referencia, referencia_tipo, usuario_id)
      values
        (emp_id, ped.cliente_id, 'pago', -ped.monto_transf,
         'transferencia', ped.id, 'hoja_ruta', cobrador);
      tot_tr := tot_tr + ped.monto_transf;
    end if;

    -- CUENTA CORRIENTE: solo acumular, el cargo ya existe del pedido original
    if ped.monto_cuenta > 0 then
      tot_cc := tot_cc + ped.monto_cuenta;
    end if;

    -- Guardar imputación en el pedido para trazabilidad
    update pedidos set
      forma_pago = case
        when ped.monto_efectivo > 0 and ped.monto_transf > 0 then 'mixto'::forma_pago
        when ped.monto_efectivo > 0 then 'efectivo'::forma_pago
        when ped.monto_transf   > 0 then 'transferencia'::forma_pago
        else 'cuenta_corriente'::forma_pago
      end,
      estado = 'entregado'
    where id = ped.id;

  end loop;

  -- Actualizar totales de la hoja
  update hojas_ruta set
    total_efectivo      = tot_ef,
    total_transf        = tot_tr,
    total_cuenta        = tot_cc,
    total_no_entregado  = tot_ne,
    estado              = 'cerrada',
    cerrada_en          = now()
  where id = p_hoja_id;

end;
$$;


--
-- Name: confirmar_ingreso(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.confirmar_ingreso(p_ingreso_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  item record;
  emp_id uuid;
  usr_id uuid;
begin
  select empresa_id, usuario_id into emp_id, usr_id
  from ingresos where id = p_ingreso_id;

  for item in
    select * from ingreso_items where ingreso_id = p_ingreso_id
  loop
    -- actualizar costo del producto al costo final con cargos
    update productos
    set costo = item.costo_unit_final,
        ultimo_cambio_costo = current_date
    where id = item.producto_id;

    -- registrar movimiento de stock tipo ingreso
    insert into mov_stock
      (empresa_id, producto_id, tipo, cantidad, referencia, referencia_tipo, usuario_id)
    values
      (emp_id, item.producto_id, 'ingreso', item.cantidad,
       p_ingreso_id, 'ingreso', usr_id);
  end loop;
end;
$$;


--
-- Name: empresa_actual(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.empresa_actual() RETURNS uuid
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select empresa_id from usuarios where auth_id = auth.uid() limit 1;
$$;


--
-- Name: permiso(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.permiso(modulo_nombre text) RETURNS public.nivel_permiso
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select coalesce(
    (select nivel from permisos
     where usuario_id = (select id from usuarios where auth_id = auth.uid() limit 1)
       and modulo = modulo_nombre
     limit 1),
    'ninguno'
  );
$$;


--
-- Name: rol_actual(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rol_actual() RETURNS public.rol_usuario
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select rol from usuarios where auth_id = auth.uid() limit 1;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: boletas; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.boletas (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    empresa_id uuid NOT NULL,
    pedido_id uuid NOT NULL,
    fecha timestamp with time zone DEFAULT now() NOT NULL,
    total numeric(12,2) DEFAULT 0 NOT NULL,
    estado public.estado_boleta DEFAULT 'emitida'::public.estado_boleta NOT NULL,
    saldo_anterior numeric(12,2) DEFAULT 0 NOT NULL,
    total_a_cobrar numeric(12,2) DEFAULT 0 NOT NULL
);


--
-- Name: clientes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.clientes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    empresa_id uuid NOT NULL,
    nombre text NOT NULL,
    direccion text,
    telefono text,
    zona_id uuid,
    posicion_zona integer DEFAULT 0 NOT NULL,
    activo boolean DEFAULT true NOT NULL,
    creado_en timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: dias_sin_ingreso; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.dias_sin_ingreso AS
SELECT
    NULL::uuid AS producto_id,
    NULL::uuid AS empresa_id,
    NULL::text AS nombre,
    NULL::uuid AS proveedor_id,
    NULL::numeric(12,2) AS costo,
    NULL::date AS ultimo_cambio_costo,
    NULL::date AS ultimo_ingreso,
    NULL::integer AS dias_sin_ingreso;


--
-- Name: empresas; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.empresas (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    nombre text NOT NULL,
    activa boolean DEFAULT true NOT NULL,
    creada_en timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: pedidos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pedidos (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    empresa_id uuid NOT NULL,
    cliente_id uuid NOT NULL,
    usuario_id uuid NOT NULL,
    fecha timestamp with time zone DEFAULT now() NOT NULL,
    estado public.estado_pedido DEFAULT 'borrador'::public.estado_pedido NOT NULL,
    descuento numeric(5,2) DEFAULT 0 NOT NULL,
    observaciones text,
    hoja_ruta_id uuid,
    entregado boolean,
    motivo_no_entrega text,
    forma_pago public.forma_pago,
    monto_efectivo numeric(12,2) DEFAULT 0 NOT NULL,
    monto_transf numeric(12,2) DEFAULT 0 NOT NULL,
    monto_cuenta numeric(12,2) DEFAULT 0 NOT NULL,
    cobrador_id uuid
);


--
-- Name: usuarios; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.usuarios (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    empresa_id uuid NOT NULL,
    auth_id uuid,
    nombre text NOT NULL,
    email text,
    rol public.rol_usuario DEFAULT 'preventista'::public.rol_usuario NOT NULL,
    activo boolean DEFAULT true NOT NULL,
    creado_en timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: zonas; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.zonas (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    empresa_id uuid NOT NULL,
    nombre text NOT NULL,
    orden integer DEFAULT 0 NOT NULL,
    activa boolean DEFAULT true NOT NULL
);


--
-- Name: hoja_ruta_hoy; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.hoja_ruta_hoy AS
 SELECT p.id AS pedido_id,
    p.empresa_id,
    p.fecha,
    p.estado,
    p.hoja_ruta_id,
    p.forma_pago,
    p.monto_efectivo,
    p.monto_transf,
    p.monto_cuenta,
    p.entregado,
    c.id AS cliente_id,
    c.nombre AS cliente_nombre,
    c.direccion,
    c.telefono,
    z.nombre AS zona_nombre,
    z.orden AS zona_orden,
    c.posicion_zona,
    u.nombre AS preventista_nombre,
    b.total AS total_boleta
   FROM ((((public.pedidos p
     JOIN public.clientes c ON ((c.id = p.cliente_id)))
     LEFT JOIN public.zonas z ON ((z.id = c.zona_id)))
     JOIN public.usuarios u ON ((u.id = p.usuario_id)))
     LEFT JOIN public.boletas b ON ((b.pedido_id = p.id)))
  WHERE ((p.estado = ANY (ARRAY['confirmado'::public.estado_pedido, 'entregado'::public.estado_pedido, 'no_entregado'::public.estado_pedido])) AND (date_trunc('day'::text, p.fecha) = CURRENT_DATE))
  ORDER BY z.orden, c.posicion_zona;


--
-- Name: hojas_ruta; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.hojas_ruta (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    empresa_id uuid NOT NULL,
    fecha date DEFAULT CURRENT_DATE NOT NULL,
    usuario_id uuid,
    estado public.estado_hoja_ruta DEFAULT 'pendiente'::public.estado_hoja_ruta NOT NULL,
    qr_token text DEFAULT (gen_random_uuid())::text NOT NULL,
    total_efectivo numeric(12,2) DEFAULT 0 NOT NULL,
    total_transf numeric(12,2) DEFAULT 0 NOT NULL,
    total_cuenta numeric(12,2) DEFAULT 0 NOT NULL,
    total_no_entregado numeric(12,2) DEFAULT 0 NOT NULL,
    cerrada_en timestamp with time zone,
    creada_en timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: ingreso_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ingreso_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    empresa_id uuid NOT NULL,
    ingreso_id uuid NOT NULL,
    producto_id uuid NOT NULL,
    bultos integer DEFAULT 1 NOT NULL,
    u_por_bulto integer DEFAULT 1 NOT NULL,
    cantidad integer NOT NULL,
    costo_unit_neto numeric(12,2) NOT NULL,
    costo_unit_final numeric(12,2) NOT NULL
);


--
-- Name: ingresos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ingresos (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    empresa_id uuid NOT NULL,
    proveedor_id uuid NOT NULL,
    usuario_id uuid,
    numero_boleta text,
    fecha date DEFAULT CURRENT_DATE NOT NULL,
    cargos_aplicados jsonb DEFAULT '[]'::jsonb NOT NULL,
    total_declarado numeric(12,2),
    total_calculado numeric(12,2) DEFAULT 0 NOT NULL,
    creado_en timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: mov_cuenta; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.mov_cuenta (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    empresa_id uuid NOT NULL,
    cliente_id uuid NOT NULL,
    tipo public.tipo_mov_cuenta NOT NULL,
    monto numeric(12,2) NOT NULL,
    forma_pago public.forma_pago,
    referencia uuid,
    referencia_tipo text,
    usuario_id uuid,
    fecha timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: mov_stock; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.mov_stock (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    empresa_id uuid NOT NULL,
    producto_id uuid NOT NULL,
    tipo public.tipo_mov_stock NOT NULL,
    cantidad integer NOT NULL,
    referencia uuid,
    referencia_tipo text,
    usuario_id uuid,
    fecha timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: pedido_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pedido_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    empresa_id uuid NOT NULL,
    pedido_id uuid NOT NULL,
    producto_id uuid NOT NULL,
    cantidad integer NOT NULL,
    precio_unit numeric(12,2) NOT NULL,
    descuento numeric(5,2) DEFAULT 0 NOT NULL,
    es_bulto boolean DEFAULT false NOT NULL,
    u_por_bulto integer DEFAULT 1 NOT NULL
);


--
-- Name: permisos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.permisos (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    empresa_id uuid NOT NULL,
    usuario_id uuid NOT NULL,
    modulo text NOT NULL,
    nivel public.nivel_permiso DEFAULT 'ninguno'::public.nivel_permiso NOT NULL
);


--
-- Name: productos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.productos (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    empresa_id uuid NOT NULL,
    proveedor_id uuid,
    nombre text NOT NULL,
    categoria text,
    costo numeric(12,2) DEFAULT 0 NOT NULL,
    precio numeric(12,2) DEFAULT 0 NOT NULL,
    u_bulto integer DEFAULT 1 NOT NULL,
    desc_bulto numeric(5,2) DEFAULT 0 NOT NULL,
    ultimo_cambio_costo date,
    activo boolean DEFAULT true NOT NULL,
    creado_en timestamp with time zone DEFAULT now() NOT NULL,
    foto_url text
);


--
-- Name: proveedores; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.proveedores (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    empresa_id uuid NOT NULL,
    nombre text NOT NULL,
    dias_objetivo integer DEFAULT 30 NOT NULL,
    dias_reorden integer,
    cargos_default jsonb DEFAULT '[]'::jsonb NOT NULL,
    activo boolean DEFAULT true NOT NULL
);


--
-- Name: recaudacion_por_usuario; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.recaudacion_por_usuario AS
 SELECT usuario_id,
    date_trunc('day'::text, fecha) AS dia,
    forma_pago,
    sum((- monto)) AS recaudado
   FROM public.mov_cuenta
  WHERE ((tipo = 'pago'::public.tipo_mov_cuenta) AND (usuario_id IS NOT NULL))
  GROUP BY usuario_id, (date_trunc('day'::text, fecha)), forma_pago;


--
-- Name: saldo_actual; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.saldo_actual AS
 SELECT cliente_id,
    sum(monto) AS saldo
   FROM public.mov_cuenta
  GROUP BY cliente_id;


--
-- Name: stock_actual; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.stock_actual AS
 SELECT producto_id,
    sum(cantidad) AS stock
   FROM public.mov_stock
  GROUP BY producto_id;


--
-- Name: stock_negativo; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.stock_negativo AS
 SELECT producto_id,
    sum(cantidad) AS stock
   FROM public.mov_stock
  GROUP BY producto_id
 HAVING (sum(cantidad) < 0);


--
-- Name: boletas boletas_pedido_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.boletas
    ADD CONSTRAINT boletas_pedido_id_key UNIQUE (pedido_id);


--
-- Name: boletas boletas_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.boletas
    ADD CONSTRAINT boletas_pkey PRIMARY KEY (id);


--
-- Name: clientes clientes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.clientes
    ADD CONSTRAINT clientes_pkey PRIMARY KEY (id);


--
-- Name: empresas empresas_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresas
    ADD CONSTRAINT empresas_pkey PRIMARY KEY (id);


--
-- Name: hojas_ruta hojas_ruta_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hojas_ruta
    ADD CONSTRAINT hojas_ruta_pkey PRIMARY KEY (id);


--
-- Name: hojas_ruta hojas_ruta_qr_token_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hojas_ruta
    ADD CONSTRAINT hojas_ruta_qr_token_key UNIQUE (qr_token);


--
-- Name: ingreso_items ingreso_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingreso_items
    ADD CONSTRAINT ingreso_items_pkey PRIMARY KEY (id);


--
-- Name: ingresos ingresos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingresos
    ADD CONSTRAINT ingresos_pkey PRIMARY KEY (id);


--
-- Name: mov_cuenta mov_cuenta_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mov_cuenta
    ADD CONSTRAINT mov_cuenta_pkey PRIMARY KEY (id);


--
-- Name: mov_stock mov_stock_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mov_stock
    ADD CONSTRAINT mov_stock_pkey PRIMARY KEY (id);


--
-- Name: pedido_items pedido_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pedido_items
    ADD CONSTRAINT pedido_items_pkey PRIMARY KEY (id);


--
-- Name: pedidos pedidos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pedidos
    ADD CONSTRAINT pedidos_pkey PRIMARY KEY (id);


--
-- Name: permisos permisos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.permisos
    ADD CONSTRAINT permisos_pkey PRIMARY KEY (id);


--
-- Name: productos productos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.productos
    ADD CONSTRAINT productos_pkey PRIMARY KEY (id);


--
-- Name: proveedores proveedores_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proveedores
    ADD CONSTRAINT proveedores_pkey PRIMARY KEY (id);


--
-- Name: permisos uq_permiso; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.permisos
    ADD CONSTRAINT uq_permiso UNIQUE (usuario_id, modulo);


--
-- Name: usuarios usuarios_auth_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usuarios
    ADD CONSTRAINT usuarios_auth_id_key UNIQUE (auth_id);


--
-- Name: usuarios usuarios_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usuarios
    ADD CONSTRAINT usuarios_pkey PRIMARY KEY (id);


--
-- Name: zonas zonas_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.zonas
    ADD CONSTRAINT zonas_pkey PRIMARY KEY (id);


--
-- Name: idx_boletas_pedido; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_boletas_pedido ON public.boletas USING btree (pedido_id);


--
-- Name: idx_clientes_empresa; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_clientes_empresa ON public.clientes USING btree (empresa_id);


--
-- Name: idx_clientes_zona; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_clientes_zona ON public.clientes USING btree (zona_id, posicion_zona);


--
-- Name: idx_hojas_ruta_fecha; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_hojas_ruta_fecha ON public.hojas_ruta USING btree (empresa_id, fecha);


--
-- Name: idx_hojas_ruta_token; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_hojas_ruta_token ON public.hojas_ruta USING btree (qr_token);


--
-- Name: idx_ingreso_items_ingreso; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ingreso_items_ingreso ON public.ingreso_items USING btree (ingreso_id);


--
-- Name: idx_ingresos_proveedor; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ingresos_proveedor ON public.ingresos USING btree (proveedor_id);


--
-- Name: idx_mov_cuenta_cliente; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mov_cuenta_cliente ON public.mov_cuenta USING btree (cliente_id);


--
-- Name: idx_mov_cuenta_fecha; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mov_cuenta_fecha ON public.mov_cuenta USING btree (empresa_id, fecha);


--
-- Name: idx_mov_cuenta_usuario; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mov_cuenta_usuario ON public.mov_cuenta USING btree (usuario_id);


--
-- Name: idx_mov_stock_fecha; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mov_stock_fecha ON public.mov_stock USING btree (empresa_id, fecha);


--
-- Name: idx_mov_stock_producto; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mov_stock_producto ON public.mov_stock USING btree (producto_id);


--
-- Name: idx_pedido_items_pedido; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pedido_items_pedido ON public.pedido_items USING btree (pedido_id);


--
-- Name: idx_pedidos_cliente; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pedidos_cliente ON public.pedidos USING btree (cliente_id);


--
-- Name: idx_pedidos_empresa_fecha; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pedidos_empresa_fecha ON public.pedidos USING btree (empresa_id, fecha);


--
-- Name: idx_pedidos_hoja_ruta; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pedidos_hoja_ruta ON public.pedidos USING btree (hoja_ruta_id);


--
-- Name: idx_permisos_usuario; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_permisos_usuario ON public.permisos USING btree (usuario_id);


--
-- Name: idx_productos_empresa; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_productos_empresa ON public.productos USING btree (empresa_id);


--
-- Name: idx_productos_proveedor; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_productos_proveedor ON public.productos USING btree (proveedor_id);


--
-- Name: idx_proveedores_empresa; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_proveedores_empresa ON public.proveedores USING btree (empresa_id);


--
-- Name: idx_usuarios_empresa; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_usuarios_empresa ON public.usuarios USING btree (empresa_id);


--
-- Name: idx_zonas_empresa; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_zonas_empresa ON public.zonas USING btree (empresa_id);


--
-- Name: dias_sin_ingreso _RETURN; Type: RULE; Schema: public; Owner: -
--

CREATE OR REPLACE VIEW public.dias_sin_ingreso AS
 SELECT p.id AS producto_id,
    p.empresa_id,
    p.nombre,
    p.proveedor_id,
    p.costo,
    p.ultimo_cambio_costo,
    max(i.fecha) AS ultimo_ingreso,
    (CURRENT_DATE - max(i.fecha)) AS dias_sin_ingreso
   FROM ((public.productos p
     LEFT JOIN public.ingreso_items ii ON ((ii.producto_id = p.id)))
     LEFT JOIN public.ingresos i ON ((i.id = ii.ingreso_id)))
  GROUP BY p.id;


--
-- Name: boletas boletas_empresa_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.boletas
    ADD CONSTRAINT boletas_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES public.empresas(id);


--
-- Name: boletas boletas_pedido_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.boletas
    ADD CONSTRAINT boletas_pedido_id_fkey FOREIGN KEY (pedido_id) REFERENCES public.pedidos(id);


--
-- Name: clientes clientes_empresa_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.clientes
    ADD CONSTRAINT clientes_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES public.empresas(id);


--
-- Name: clientes clientes_zona_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.clientes
    ADD CONSTRAINT clientes_zona_id_fkey FOREIGN KEY (zona_id) REFERENCES public.zonas(id);


--
-- Name: pedidos fk_pedidos_hoja_ruta; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pedidos
    ADD CONSTRAINT fk_pedidos_hoja_ruta FOREIGN KEY (hoja_ruta_id) REFERENCES public.hojas_ruta(id);


--
-- Name: hojas_ruta hojas_ruta_empresa_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hojas_ruta
    ADD CONSTRAINT hojas_ruta_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES public.empresas(id);


--
-- Name: hojas_ruta hojas_ruta_usuario_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hojas_ruta
    ADD CONSTRAINT hojas_ruta_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES public.usuarios(id);


--
-- Name: ingreso_items ingreso_items_empresa_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingreso_items
    ADD CONSTRAINT ingreso_items_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES public.empresas(id);


--
-- Name: ingreso_items ingreso_items_ingreso_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingreso_items
    ADD CONSTRAINT ingreso_items_ingreso_id_fkey FOREIGN KEY (ingreso_id) REFERENCES public.ingresos(id) ON DELETE CASCADE;


--
-- Name: ingreso_items ingreso_items_producto_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingreso_items
    ADD CONSTRAINT ingreso_items_producto_id_fkey FOREIGN KEY (producto_id) REFERENCES public.productos(id);


--
-- Name: ingresos ingresos_empresa_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingresos
    ADD CONSTRAINT ingresos_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES public.empresas(id);


--
-- Name: ingresos ingresos_proveedor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingresos
    ADD CONSTRAINT ingresos_proveedor_id_fkey FOREIGN KEY (proveedor_id) REFERENCES public.proveedores(id);


--
-- Name: ingresos ingresos_usuario_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingresos
    ADD CONSTRAINT ingresos_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES public.usuarios(id);


--
-- Name: mov_cuenta mov_cuenta_cliente_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mov_cuenta
    ADD CONSTRAINT mov_cuenta_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES public.clientes(id);


--
-- Name: mov_cuenta mov_cuenta_empresa_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mov_cuenta
    ADD CONSTRAINT mov_cuenta_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES public.empresas(id);


--
-- Name: mov_cuenta mov_cuenta_usuario_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mov_cuenta
    ADD CONSTRAINT mov_cuenta_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES public.usuarios(id);


--
-- Name: mov_stock mov_stock_empresa_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mov_stock
    ADD CONSTRAINT mov_stock_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES public.empresas(id);


--
-- Name: mov_stock mov_stock_producto_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mov_stock
    ADD CONSTRAINT mov_stock_producto_id_fkey FOREIGN KEY (producto_id) REFERENCES public.productos(id);


--
-- Name: mov_stock mov_stock_usuario_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mov_stock
    ADD CONSTRAINT mov_stock_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES public.usuarios(id);


--
-- Name: pedido_items pedido_items_empresa_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pedido_items
    ADD CONSTRAINT pedido_items_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES public.empresas(id);


--
-- Name: pedido_items pedido_items_pedido_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pedido_items
    ADD CONSTRAINT pedido_items_pedido_id_fkey FOREIGN KEY (pedido_id) REFERENCES public.pedidos(id) ON DELETE CASCADE;


--
-- Name: pedido_items pedido_items_producto_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pedido_items
    ADD CONSTRAINT pedido_items_producto_id_fkey FOREIGN KEY (producto_id) REFERENCES public.productos(id);


--
-- Name: pedidos pedidos_cliente_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pedidos
    ADD CONSTRAINT pedidos_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES public.clientes(id);


--
-- Name: pedidos pedidos_cobrador_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pedidos
    ADD CONSTRAINT pedidos_cobrador_id_fkey FOREIGN KEY (cobrador_id) REFERENCES public.usuarios(id);


--
-- Name: pedidos pedidos_empresa_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pedidos
    ADD CONSTRAINT pedidos_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES public.empresas(id);


--
-- Name: pedidos pedidos_usuario_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pedidos
    ADD CONSTRAINT pedidos_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES public.usuarios(id);


--
-- Name: permisos permisos_empresa_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.permisos
    ADD CONSTRAINT permisos_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES public.empresas(id);


--
-- Name: permisos permisos_usuario_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.permisos
    ADD CONSTRAINT permisos_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES public.usuarios(id) ON DELETE CASCADE;


--
-- Name: productos productos_empresa_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.productos
    ADD CONSTRAINT productos_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES public.empresas(id);


--
-- Name: productos productos_proveedor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.productos
    ADD CONSTRAINT productos_proveedor_id_fkey FOREIGN KEY (proveedor_id) REFERENCES public.proveedores(id);


--
-- Name: proveedores proveedores_empresa_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proveedores
    ADD CONSTRAINT proveedores_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES public.empresas(id);


--
-- Name: usuarios usuarios_auth_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usuarios
    ADD CONSTRAINT usuarios_auth_id_fkey FOREIGN KEY (auth_id) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: usuarios usuarios_empresa_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usuarios
    ADD CONSTRAINT usuarios_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES public.empresas(id);


--
-- Name: zonas zonas_empresa_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.zonas
    ADD CONSTRAINT zonas_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES public.empresas(id);


--
-- Name: boletas; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.boletas ENABLE ROW LEVEL SECURITY;

--
-- Name: clientes; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.clientes ENABLE ROW LEVEL SECURITY;

--
-- Name: empresas; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.empresas ENABLE ROW LEVEL SECURITY;

--
-- Name: hojas_ruta; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.hojas_ruta ENABLE ROW LEVEL SECURITY;

--
-- Name: ingreso_items; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.ingreso_items ENABLE ROW LEVEL SECURITY;

--
-- Name: ingresos; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.ingresos ENABLE ROW LEVEL SECURITY;

--
-- Name: mov_cuenta; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.mov_cuenta ENABLE ROW LEVEL SECURITY;

--
-- Name: mov_stock; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.mov_stock ENABLE ROW LEVEL SECURITY;

--
-- Name: pedido_items; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.pedido_items ENABLE ROW LEVEL SECURITY;

--
-- Name: pedidos; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.pedidos ENABLE ROW LEVEL SECURITY;

--
-- Name: pedidos pedidos_acceso; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pedidos_acceso ON public.pedidos USING (((empresa_id = public.empresa_actual()) AND ((public.rol_actual() = ANY (ARRAY['admin'::public.rol_usuario, 'deposito'::public.rol_usuario])) OR (usuario_id = ( SELECT usuarios.id
   FROM public.usuarios
  WHERE (usuarios.auth_id = auth.uid())
 LIMIT 1))))) WITH CHECK ((empresa_id = public.empresa_actual()));


--
-- Name: permisos; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.permisos ENABLE ROW LEVEL SECURITY;

--
-- Name: productos; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.productos ENABLE ROW LEVEL SECURITY;

--
-- Name: proveedores; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.proveedores ENABLE ROW LEVEL SECURITY;

--
-- Name: boletas tenant; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant ON public.boletas USING ((empresa_id = public.empresa_actual())) WITH CHECK ((empresa_id = public.empresa_actual()));


--
-- Name: clientes tenant; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant ON public.clientes USING ((empresa_id = public.empresa_actual())) WITH CHECK ((empresa_id = public.empresa_actual()));


--
-- Name: empresas tenant; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant ON public.empresas USING ((id = public.empresa_actual()));


--
-- Name: hojas_ruta tenant; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant ON public.hojas_ruta USING ((empresa_id = public.empresa_actual())) WITH CHECK ((empresa_id = public.empresa_actual()));


--
-- Name: ingreso_items tenant; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant ON public.ingreso_items USING ((empresa_id = public.empresa_actual())) WITH CHECK ((empresa_id = public.empresa_actual()));


--
-- Name: ingresos tenant; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant ON public.ingresos USING ((empresa_id = public.empresa_actual())) WITH CHECK ((empresa_id = public.empresa_actual()));


--
-- Name: mov_cuenta tenant; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant ON public.mov_cuenta USING ((empresa_id = public.empresa_actual())) WITH CHECK ((empresa_id = public.empresa_actual()));


--
-- Name: mov_stock tenant; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant ON public.mov_stock USING ((empresa_id = public.empresa_actual())) WITH CHECK ((empresa_id = public.empresa_actual()));


--
-- Name: pedido_items tenant; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant ON public.pedido_items USING ((empresa_id = public.empresa_actual())) WITH CHECK ((empresa_id = public.empresa_actual()));


--
-- Name: permisos tenant; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant ON public.permisos USING ((empresa_id = public.empresa_actual())) WITH CHECK ((empresa_id = public.empresa_actual()));


--
-- Name: productos tenant; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant ON public.productos USING ((empresa_id = public.empresa_actual())) WITH CHECK ((empresa_id = public.empresa_actual()));


--
-- Name: proveedores tenant; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant ON public.proveedores USING ((empresa_id = public.empresa_actual())) WITH CHECK ((empresa_id = public.empresa_actual()));


--
-- Name: usuarios tenant; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant ON public.usuarios USING ((empresa_id = public.empresa_actual())) WITH CHECK ((empresa_id = public.empresa_actual()));


--
-- Name: zonas tenant; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant ON public.zonas USING ((empresa_id = public.empresa_actual())) WITH CHECK ((empresa_id = public.empresa_actual()));


--
-- Name: usuarios; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.usuarios ENABLE ROW LEVEL SECURITY;

--
-- Name: zonas; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.zonas ENABLE ROW LEVEL SECURITY;

--
-- PostgreSQL database dump complete
--

\unrestrict MpbhTfa0Hax4QX5bD7crCXg8msLkqWTjoU13ceUyHkNzGtuO1gKbalzUxAjDlLC

