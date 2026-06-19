// =====================================================================
// Utilidades comunes — formato de moneda, fechas, helpers de DOM.
// =====================================================================

const ARS_FMT = new Intl.NumberFormat('es-AR', {
  style: 'currency',
  currency: 'ARS',
  maximumFractionDigits: 0,
})

export const ars = (n) => ARS_FMT.format(Number(n) || 0)

// Fecha de hoy en Argentina (Córdoba, UTC-3) como YYYY-MM-DD.
// Importante: NO usar new Date().toISOString().slice(0,10) porque
// a las 21hs UTC ya es el día siguiente y se rompen los filtros de "hoy".
export const hoyArg = () => new Intl.DateTimeFormat('en-CA', {
  timeZone: 'America/Argentina/Cordoba'
}).format(new Date())

export const isoArg = (d) => new Intl.DateTimeFormat('en-CA', {
  timeZone: 'America/Argentina/Cordoba'
}).format(d instanceof Date ? d : new Date(d))

// YYYY-MM-DD en Argentina con offset de días (positivo o negativo)
export const isoArgOffset = (dias) => {
  const d = new Date(Date.now() + dias * 86400000)
  return isoArg(d)
}

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

// Exporta filas a CSV con BOM UTF-8 para que Excel lo abra bien.
// columnas: [{key, label, format?}]  filas: [{key:value, ...}]
export const exportCSV = (nombre, columnas, filas) => {
  const esc = v => {
    if (v == null) return ''
    const s = String(v)
    return /[",;\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s
  }
  const sep = ';' // Excel-AR usa ; por default
  const head = columnas.map(c => esc(c.label)).join(sep)
  const cuerpo = filas.map(r =>
    columnas.map(c => esc(c.format ? c.format(r[c.key], r) : r[c.key])).join(sep)
  ).join('\n')
  const bom = '﻿'
  const blob = new Blob([bom + head + '\n' + cuerpo], { type: 'text/csv;charset=utf-8' })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = nombre.endsWith('.csv') ? nombre : `${nombre}.csv`
  document.body.appendChild(a); a.click(); a.remove()
  setTimeout(() => URL.revokeObjectURL(url), 1000)
}

// Print-friendly: agrega @media print mínimo y dispara window.print()
export const imprimirPagina = () => {
  if (!document.getElementById('print-css-base')) {
    const s = document.createElement('style')
    s.id = 'print-css-base'
    s.textContent = `@media print { .no-print, button, input, select { display:none !important } body { max-width:none !important; padding:0 !important } }`
    document.head.appendChild(s)
  }
  window.print()
}

// Debounce simple para inputs de búsqueda
export const debounce = (fn, ms = 250) => {
  let t
  return (...args) => {
    clearTimeout(t)
    t = setTimeout(() => fn(...args), ms)
  }
}
