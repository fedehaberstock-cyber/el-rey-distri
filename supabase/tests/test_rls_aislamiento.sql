-- =====================================================================
-- TEST: aislamiento RLS multi-empresa
--
-- Crea 2 empresas, 2 usuarios fake, datos en cada una, y verifica que
-- al simular sesión de usuario A no se vea NADA de empresa B.
--
-- Diseñado para correr completo en una transacción y hacer rollback,
-- no deja basura en la base.
-- =====================================================================

begin;

-- ids fijos para poder simular auth.uid()
do $$
declare
  v_auth_a uuid := '11111111-1111-1111-1111-111111111111';
  v_auth_b uuid := '22222222-2222-2222-2222-222222222222';
  v_emp_a  uuid;
  v_emp_b  uuid;
  v_user_a uuid;
  v_user_b uuid;
  v_cli_a  uuid;
  v_cli_b  uuid;
  v_cnt    int;
begin
  -- usuarios fake en auth.users (necesarios para FK desde public.usuarios.auth_id)
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at)
  values
    (v_auth_a, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'test_a@rls.test', '', now(), now()),
    (v_auth_b, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'test_b@rls.test', '', now(), now());

  -- 2 empresas
  insert into empresas (nombre, activa) values ('Empresa A', true) returning id into v_emp_a;
  insert into empresas (nombre, activa) values ('Empresa B', true) returning id into v_emp_b;

  -- 1 usuario por empresa
  insert into usuarios (empresa_id, auth_id, nombre, email, rol, activo)
    values (v_emp_a, v_auth_a, 'Admin A', 'test_a@rls.test', 'admin', true)
    returning id into v_user_a;
  insert into usuarios (empresa_id, auth_id, nombre, email, rol, activo)
    values (v_emp_b, v_auth_b, 'Admin B', 'test_b@rls.test', 'admin', true)
    returning id into v_user_b;

  -- 1 cliente por empresa
  insert into clientes (empresa_id, nombre, posicion_zona, activo)
    values (v_emp_a, 'Cliente A1', 1, true) returning id into v_cli_a;
  insert into clientes (empresa_id, nombre, posicion_zona, activo)
    values (v_emp_b, 'Cliente B1', 1, true) returning id into v_cli_b;

  raise notice '--- SETUP OK: empresa A=%, empresa B=% ---', v_emp_a, v_emp_b;

  -- ============================================================
  -- TEST 1: usuario A solo ve datos de empresa A
  -- ============================================================
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_auth_a)::text, true);

  select count(*) into v_cnt from clientes;
  raise notice 'TEST 1: usuario A ve % clientes (esperado: 1)', v_cnt;
  if v_cnt <> 1 then raise exception 'FALLO: A ve % clientes', v_cnt; end if;

  select count(*) into v_cnt from clientes where empresa_id = v_emp_b;
  raise notice 'TEST 1: usuario A ve % clientes de empresa B (esperado: 0)', v_cnt;
  if v_cnt <> 0 then raise exception 'FALLO RLS: A ve datos de B'; end if;

  -- ============================================================
  -- TEST 2: usuario A no puede insertar con empresa_id de B
  -- ============================================================
  begin
    insert into clientes (empresa_id, nombre, posicion_zona, activo)
      values (v_emp_b, 'Cliente trucho', 99, true);
    raise exception 'FALLO RLS: A pudo insertar con empresa_id de B';
  exception when others then
    if SQLSTATE = 'P0001' and SQLERRM like 'FALLO RLS%' then
      raise;
    end if;
    raise notice 'TEST 2: insert cross-tenant bloqueado correctamente (%)', SQLSTATE;
  end;

  -- ============================================================
  -- TEST 3: cambio de sesión a usuario B → ve solo datos de B
  -- ============================================================
  perform set_config('request.jwt.claims', json_build_object('sub', v_auth_b)::text, true);

  select count(*) into v_cnt from clientes;
  raise notice 'TEST 3: usuario B ve % clientes (esperado: 1)', v_cnt;
  if v_cnt <> 1 then raise exception 'FALLO: B ve % clientes', v_cnt; end if;

  select count(*) into v_cnt from clientes where empresa_id = v_emp_a;
  raise notice 'TEST 3: usuario B ve % clientes de empresa A (esperado: 0)', v_cnt;
  if v_cnt <> 0 then raise exception 'FALLO RLS: B ve datos de A'; end if;

  -- ============================================================
  -- TEST 4: sin sesión (anon) no ve nada
  -- ============================================================
  reset role;
  set local role anon;
  perform set_config('request.jwt.claims', null, true);

  select count(*) into v_cnt from clientes;
  raise notice 'TEST 4: anon ve % clientes (esperado: 0)', v_cnt;
  if v_cnt <> 0 then raise exception 'FALLO RLS: anon ve datos'; end if;

  reset role;
  raise notice '--- TODOS LOS TESTS PASARON ---';
end;
$$;

-- siempre rollback: este test no deja basura
rollback;
