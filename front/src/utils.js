// =====================================================================
// Utilidades comunes — formato de moneda, fechas, helpers de DOM.
// =====================================================================

const ARS_FMT = new Intl.NumberFormat('es-AR', {
  style: 'currency',
  currency: 'ARS',
  maximumFractionDigits: 0,
})

export const ars = (n) => ARS_FMT.format(Number(n) || 0)

export const fechaCorta = (d) => {
  const x = d instanceof Date ? d : new Date(d)
  return x.toLocaleDateString('es-AR')
}

export const fechaLarga = (d) => {
  const x = d instanceof Date ? d : new Date(d)
  return x.toLocaleDateString('es-AR', {
    weekday: 'long',
    day: 'numeric',
    month: 'long',
  })
}

export const horaCorta = (d) => {
  const x = d instanceof Date ? d : new Date(d)
  return x.toLocaleTimeString('es-AR', { hour: '2-digit', minute: '2-digit' })
}

// Capitaliza primera letra (para fecha larga: "Lunes, 9 de junio")
export const cap = (s) =>
  typeof s === 'string' && s.length ? s[0].toUpperCase() + s.slice(1) : s

// Mostrar errores de Supabase al usuario — nunca silenciar
export const mostrarError = (msg, el) => {
  console.error('[elrey]', msg)
  if (el && typeof el === 'string') el = document.getElementById(el)
  if (el) {
    el.textContent = msg
    el.classList.add('show')
  } else {
    alert(msg)
  }
}

// Debounce simple para inputs de búsqueda
export const debounce = (fn, ms = 250) => {
  let t
  return (...args) => {
    clearTimeout(t)
    t = setTimeout(() => fn(...args), ms)
  }
}
