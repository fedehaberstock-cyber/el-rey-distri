# Fuente: "claude code desde 0 para negocios" (parte 2)
Archivo: `claude code desde 0 para negocios.txt` (~52.000 caracteres). En español (Argentina); la dueña de una agencia de performance (Clica) y una colega muestran Claude conectado a Meta y análisis de retención. Estado: leído completo.

## Ideas centrales
1. **Novedades de la app de Claude:** chat, Cowork y Code en una sola aplicación (ya no hace falta terminal); carpetas por proyecto o cliente; nivel de esfuerzo; modo planificación/automático; dictado por voz; **rutinas** (tareas recurrentes automáticas); **Dispatch** (operar la computadora desde el celular).
2. **Conectar Claude con Meta Ads** mediante el conector oficial de Meta (MCP): hay que agregar un conector personalizado con la dirección `mcp.facebook.com/ads`. Requisito: **Business Manager bien configurado y verificado**, con la "información del negocio" completa (dirección, datos fiscales, todo lo que se pueda subir) para que Meta lo considere usuario verificado.
3. Seguridad: el conector pide **aprobación para cada acción** (opciones: requerir aprobación / permitir siempre / bloqueado). Las campañas que crea quedan como **borrador**, no se publican solas. "IA primero, pero con una persona en el medio": hay que verificar lo que devuelve. Con varias cuentas, indicarle el ID de la cuenta publicitaria (o pegar la URL).
4. **Criterio humano:** la IA devuelve respuestas genéricas; el valor es aplicar tus propias reglas. Ejemplo de la autora: anuncio de parte alta saturado con frecuencia sobre 2,5; de parte baja sobre 3; y "si el CTR no cae, no está saturado, solo funciona". También conviene pedirle a Claude "¿qué más podrías analizar?" y "¿qué preguntas necesitás hacerme?".
5. **Retención antes que adquisición:** con un archivo de ventas se hacen análisis de canasta de productos, segmentación **RFM** (qué tan reciente, frecuente y valioso es cada cliente; 9 segmentos), tasa de recompra (referencia que citan: 30–40% buena, 10–20% promedio de tiendas) y **ventana de recompra** (mediana de 59 días entre compras → mandar el mensaje de segunda compra entre los días 40 y 60). Los mejores clientes se cuidan, no se llenan de descuentos. Un solo intento de reactivación a los muy fríos.
6. Cita un estudio según el cual la hipersegmentación logra hasta 160% más de incremento en ventas. No se verificó la fuente. Menciona que una audiencia personalizada de Meta necesita un mínimo de contactos (dudan si 100 o 1.000; no confirmado).
7. Mayor tasa de recompra permite pagar más por conseguir un cliente nuevo.

## Qué aplica a Trébol
**Etapa 1 (estrategia):**
- Marco de **retención**: el comercio que repone es el que vale. Definir desde ya cada cuántos días repone un kiosco o almacén (ventana de reposición) para planificar el seguimiento por WhatsApp.
- Segmentar a los comercios en: nuevos, activos, a punto de dejar de reponer. Los que más compran se cuidan (atención, visita del distribuidor), no se les baja el precio.
**Etapa 2 (implementación):**
- **Verificar el Business Manager** con los datos de la empresa (FH&EH SAS) antes de pautar.
- En esta sesión ya hay un conector de Meta Ads disponible: se puede usar para leer la cuenta, preparar campañas como borrador y revisar métricas, **siempre con tu aprobación**.
- Reglas propias de saturación (frecuencia) adaptadas a una zona chica; pedirle a Claude el análisis del tablero 4PI.
- Registro de ventas por distribuidor para un RFM simple cuando haya datos.
**Etapa 3:** nada directo.
**No aplica:** análisis de canasta y recompra de tienda online, conector de pago Detrix, Google Ads (token de desarrollador), Dispatch/Cowork como herramientas de este proyecto.
**Cuidado:** cifras (160%, tasas de recompra, tamaño mínimo de audiencia) sin fuente verificable; no tomarlas como dato.
