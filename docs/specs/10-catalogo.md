# SPEC: Catálogo de Productos

## Objetivo
Subir fotos a productos. Generar catálogo PDF personalizable para compartir por WhatsApp o tablet.

## Subir foto
```js
// subir imagen a Storage
const path = `${empresaId}/${productoId}.jpg`
const { error } = await supabase.storage
  .from('productos')
  .upload(path, file, { upsert: true, contentType: file.type })

// obtener URL pública
const { data } = supabase.storage
  .from('productos')
  .getPublicUrl(path)

// guardar URL en el producto
await supabase
  .from('productos')
  .update({ foto_url: data.publicUrl })
  .eq('id', productoId)
```

## Leer productos con foto
```js
const { data } = await supabase
  .from('productos')
  .select('id, nombre, categoria, precio, foto_url')
  .eq('empresa_id', empresaId)
  .eq('activo', true)
  .not('foto_url', 'is', null)
  .order('categoria, nombre')
```

## Config del catálogo
Guardar en `localStorage` por empresa:
```js
{
  empresa:       'Distribuidora El Rey',
  subtitulo:     'Alta Gracia · Tel: ...',
  piePagina:     '...',
  logo:          null,       // base64 o URL
  porPagina:     4,          // 2 | 4 | 6 | 8 | 12
  mostrarPrecio: true,
  filtroCat:     'todas'
}
```

## Exportar PDF
```js
window.print()  // CSS @media print genera layout A4
```

## Reglas
- Bucket `productos` debe ser public
- Solo admin puede subir/cambiar fotos
- Preventistas pueden ver el catálogo pero no editarlo
- Máx 5MB por imagen — validar en el front antes de subir
