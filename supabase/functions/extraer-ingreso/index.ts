// ─────────────────────────────────────────────────────────────────────────
// Edge Function: extraer-ingreso
// Recibe una o más URLs/base64 de fotos de una boleta de proveedor,
// llama a Claude Haiku 4.5 con visión y devuelve los items detectados.
//
// Body esperado:
//   { imagenes: ["https://...jpg", "data:image/jpeg;base64,..."] }
//
// Respuesta:
//   { items: [{ texto_original, cantidad, costo_unit, costo_total_linea }, ...] }
//
// El frontend hace el matching con alias_productos por su cuenta.
// ─────────────────────────────────────────────────────────────────────────

const ANTHROPIC_API_URL = "https://api.anthropic.com/v1/messages";
const MODEL = "claude-haiku-4-5-20251001";

const SYSTEM_PROMPT = `Sos un extractor de líneas de boletas de proveedores de distribuidoras.
Recibís una o más fotos de la MISMA boleta (distintas zonas o ángulos) y devolvés un JSON
con todos los productos que aparezcan.

REGLAS:
- Devolvés ÚNICAMENTE JSON válido, sin markdown ni texto adicional.
- Formato exacto:
  { "items": [
      { "texto_original": "<tal como figura en la boleta>",
        "cantidad": <número>,
        "costo_unit": <número o null>,
        "costo_total_linea": <número o null> }
  ] }
- texto_original debe ser literal del papel (no lo reformatees).
- Si solo aparece el total de línea sin precio unitario, dejá costo_unit en null.
- Si solo aparece el precio unitario sin total, calculalo (cantidad × costo_unit).
- IGNORÁ totales de la boleta, IVA, subtotales, fletes, descuentos generales.
  Solo los renglones de productos.
- Si una foto está rotada o borrosa y no podés leer algo, omitilo en silencio.
- Si NO hay ningún producto legible, devolvé { "items": [] }.`;

interface ItemDetectado {
  texto_original: string;
  cantidad: number;
  costo_unit: number | null;
  costo_total_linea: number | null;
}

Deno.serve(async (req: Request): Promise<Response> => {
  // CORS preflight
  if (req.method === "OPTIONS") {
    return new Response(null, {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
        "Access-Control-Allow-Headers": "authorization, content-type, x-client-info, apikey",
      },
    });
  }

  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }

  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) return json({ error: "ANTHROPIC_API_KEY no configurada" }, 500);

  let body: { imagenes?: string[] };
  try {
    body = await req.json();
  } catch {
    return json({ error: "Body inválido" }, 400);
  }

  const imagenes = body.imagenes || [];
  if (!Array.isArray(imagenes) || imagenes.length === 0) {
    return json({ error: "Falta el array 'imagenes'" }, 400);
  }
  if (imagenes.length > 8) {
    return json({ error: "Máximo 8 fotos por boleta" }, 400);
  }

  // Armar los content blocks para Anthropic
  const content: Array<Record<string, unknown>> = [];
  for (const img of imagenes) {
    if (img.startsWith("data:")) {
      // base64 inline: data:image/jpeg;base64,XXXX
      const m = img.match(/^data:(image\/[a-z]+);base64,(.+)$/);
      if (!m) return json({ error: "Imagen base64 mal formada" }, 400);
      content.push({
        type: "image",
        source: { type: "base64", media_type: m[1], data: m[2] },
      });
    } else if (img.startsWith("http")) {
      content.push({
        type: "image",
        source: { type: "url", url: img },
      });
    } else {
      return json({ error: "Imagen debe ser URL http(s) o data:base64" }, 400);
    }
  }
  content.push({
    type: "text",
    text: "Extraé los items de esta boleta. Devolvé SOLO el JSON pedido.",
  });

  // Llamada a Anthropic
  let resp: Response;
  try {
    resp = await fetch(ANTHROPIC_API_URL, {
      method: "POST",
      headers: {
        "x-api-key": apiKey,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: 4000,
        system: SYSTEM_PROMPT,
        messages: [{ role: "user", content }],
      }),
    });
  } catch (e) {
    return json({ error: "Error llamando a Anthropic: " + String(e) }, 502);
  }

  if (!resp.ok) {
    const txt = await resp.text();
    return json({ error: `Anthropic ${resp.status}: ${txt}` }, 502);
  }

  const data = await resp.json();
  const textBlock = data?.content?.find((c: { type: string }) => c.type === "text");
  if (!textBlock?.text) return json({ error: "Respuesta vacía del modelo" }, 502);

  // Parsear el JSON que devuelve Claude (puede venir con texto/markdown extra)
  let parsed: { items: ItemDetectado[] };
  try {
    parsed = extraerJSON(textBlock.text);
  } catch (e) {
    return json({ error: "JSON inválido del modelo: " + String(e), raw: textBlock.text }, 502);
  }

  return json({
    items: parsed.items || [],
    usage: data.usage,
  });
});

function extraerJSON(txt: string): { items: ItemDetectado[] } {
  // Sacar fences ```json ... ``` si vinieran
  const limpio = txt.replace(/^```(?:json)?\s*/i, "").replace(/```\s*$/i, "").trim();
  return JSON.parse(limpio);
}

function json(obj: unknown, status = 200): Response {
  return new Response(JSON.stringify(obj), {
    status,
    headers: {
      "content-type": "application/json",
      "Access-Control-Allow-Origin": "*",
    },
  });
}
