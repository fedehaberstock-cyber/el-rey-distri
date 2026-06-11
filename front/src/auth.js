// =====================================================================
// Autenticación y sesión — login, logout, datos del usuario actual.
//
// Patrón de uso desde cada página:
//   import { requireSession } from './src/auth.js'
//   const { usuario, permisos } = await requireSession()
//   // si no hay sesión, redirige a login_home.html
// =====================================================================

import { supabase } from './supabase.js'

// Niveles ordenados — para comparar permisos
const NIVELES = ['ninguno', 'vista', 'crear', 'editar', 'admin']

// Cache en memoria (se hidrata desde sessionStorage al iniciar la página)
let _usuario = null
let _permisos = null
hydrateFromCache()

function hydrateFromCache() {
  try {
    const u = sessionStorage.getItem('elrey.usuario')
    const p = sessionStorage.getItem('elrey.permisos')
    if (u) _usuario = JSON.parse(u)
    if (p) _permisos = JSON.parse(p)
  } catch (_) {
    // ignore
  }
}

function saveCache() {
  if (_usuario) sessionStorage.setItem('elrey.usuario', JSON.stringify(_usuario))
  if (_permisos) sessionStorage.setItem('elrey.permisos', JSON.stringify(_permisos))
}

function clearCache() {
  sessionStorage.removeItem('elrey.usuario')
  sessionStorage.removeItem('elrey.permisos')
  _usuario = null
  _permisos = null
}

// ── login / logout ──────────────────────────────────────────────────────
export async function login(email, password) {
  const { data, error } = await supabase.auth.signInWithPassword({
    email: email.trim().toLowerCase(),
    password,
  })
  if (error) throw new Error(error.message)
  await cargarUsuarioYPermisos(data.user.id)
  return { usuario: _usuario, permisos: _permisos }
}

export async function logout() {
  await supabase.auth.signOut()
  clearCache()
}

// ── carga del usuario y sus permisos ───────────────────────────────────
async function cargarUsuarioYPermisos(authId) {
  const { data: usuario, error: e1 } = await supabase
    .from('usuarios')
    .select('id, nombre, email, rol, empresa_id, activo')
    .eq('auth_id', authId)
    .single()
  if (e1) throw new Error('No se pudo cargar usuario: ' + e1.message)
  if (!usuario.activo) throw new Error('Usuario inactivo')

  const { data: permisos, error: e2 } = await supabase
    .from('permisos')
    .select('modulo, nivel')
    .eq('usuario_id', usuario.id)
  if (e2) throw new Error('No se pudieron cargar permisos: ' + e2.message)

  _usuario = usuario
  _permisos = (permisos || []).reduce((acc, p) => {
    acc[p.modulo] = p.nivel
    return acc
  }, {})
  saveCache()
}

// ── helpers de sesión ───────────────────────────────────────────────────
export async function getSession() {
  const { data } = await supabase.auth.getSession()
  return data.session
}

// Para usar al cargar cualquier página protegida.
// Si no hay sesión → redirige a login_home.html.
export async function requireSession(redirectTo = './login_home.html') {
  const session = await getSession()
  if (!session) {
    location.replace(redirectTo)
    throw new Error('sin sesión')
  }
  if (!_usuario) await cargarUsuarioYPermisos(session.user.id)
  return { usuario: _usuario, permisos: _permisos }
}

export function getUsuario() { return _usuario }
export function getPermisos() { return _permisos || {} }

// ── verificación de permisos ────────────────────────────────────────────
// nivelRequerido: 'vista' | 'crear' | 'editar' | 'admin'
export function tienePermiso(modulo, nivelRequerido = 'vista') {
  if (!_usuario) return false
  if (_usuario.rol === 'admin') return true
  const actual = _permisos?.[modulo] || 'ninguno'
  return NIVELES.indexOf(actual) >= NIVELES.indexOf(nivelRequerido)
}
