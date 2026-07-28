// ─────────────────────────────────────────────────────────────────────────
// Edge Function: crear-usuario
// Crea un usuario nuevo en auth.users + fila en public.usuarios.
// Solo admins de la misma empresa pueden invocarla.
//
// Body: { nombre, email, password, rol }  (rol: admin | preventista | deposito)
// ─────────────────────────────────────────────────────────────────────────

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY     = Deno.env.get("SUPABASE_ANON_KEY")!;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(status: number, body: unknown) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
  if (req.method !== "POST")    return json(405, { error: "method_not_allowed" });

  const authHeader = req.headers.get("Authorization") || "";
  if (!authHeader.startsWith("Bearer ")) return json(401, { error: "sin_token" });

  // 1) Validar quién invoca: debe ser admin
  const asUser = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: me, error: errMe } = await asUser.auth.getUser();
  if (errMe || !me?.user) return json(401, { error: "sesion_invalida" });

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE);
  const { data: caller } = await admin
    .from("usuarios")
    .select("id, empresa_id, rol")
    .eq("auth_id", me.user.id)
    .maybeSingle();
  if (!caller || caller.rol !== "admin") return json(403, { error: "solo_admin" });

  // 2) Payload
  let body: any;
  try { body = await req.json(); } catch { return json(400, { error: "json_invalido" }); }
  const nombre   = String(body?.nombre || "").trim();
  const email    = String(body?.email  || "").trim().toLowerCase();
  const password = String(body?.password || "");
  const rol      = String(body?.rol || "").trim();

  if (!nombre)                                 return json(400, { error: "falta_nombre" });
  if (!email || !email.includes("@"))          return json(400, { error: "email_invalido" });
  if (password.length < 6)                     return json(400, { error: "password_corto" });
  if (!["admin", "preventista", "deposito"].includes(rol))
    return json(400, { error: "rol_invalido" });

  // 3) Crear auth user (auto-confirmado)
  const { data: created, error: errCreate } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: { nombre },
  });
  if (errCreate || !created?.user) {
    return json(400, { error: "auth_create_falló", detalle: errCreate?.message });
  }
  const newAuthId = created.user.id;

  // 4) Insertar en public.usuarios
  const { data: newRow, error: errIns } = await admin
    .from("usuarios")
    .insert({
      auth_id: newAuthId,
      empresa_id: caller.empresa_id,
      nombre,
      email,
      rol,
      activo: true,
    })
    .select("id, nombre, email, rol")
    .single();

  if (errIns) {
    // rollback: borrar el auth user
    await admin.auth.admin.deleteUser(newAuthId);
    return json(400, { error: "insert_usuarios_falló", detalle: errIns.message });
  }

  return json(200, { ok: true, usuario: newRow });
});
