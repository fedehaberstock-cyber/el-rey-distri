// =====================================================================
// Cliente Supabase — único punto de configuración para todo el frontend.
// Nunca hardcodear credenciales en otros archivos. Importar desde acá.
// =====================================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

export const SUPABASE_URL  = 'https://rqbpzmkcwxruzszbtsjv.supabase.co'
export const SUPABASE_ANON = 'sb_publishable_tdI7VSKRcEqhaTVY0ipprA_umkrtiQb'

export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON, {
  auth: {
    persistSession: true,
    autoRefreshToken: true,
    storageKey: 'elrey.auth',
    storage: window.localStorage,
  },
})
