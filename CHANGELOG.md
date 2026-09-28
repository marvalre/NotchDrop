# Historial de versiones

Cada versión está marcada con un tag de git. Para volver a una versión anterior:

```bash
git checkout v3.9.1      # ver esa versión
git checkout main        # volver a la actual
```

Para revertir **permanentemente** a una versión anterior (con cuidado — pierdes lo posterior):

```bash
git reset --hard v3.9.1
```

---

## v3.13.2 — ⌥⌘N ya no se cierra solo, comprimir audio ya no falla

**Arreglado**
- Abrir el panel con **⌥⌘N** mientras el mouse estaba lejos del notch (el caso normal de un atajo) a veces lo volvía a cerrar casi de inmediato. La animación de apertura reconstruye el área de detección de mouse en cada cuadro, y eso podía disparar un "mouse salió" espurio incluso con el cursor lejísimos — con hover esto nunca se notaba porque el cursor ya estaba encima. Ahora ese cierre automático se ignora mientras el panel todavía se está animando.
- **Comprimir** un archivo de audio (Herramientas → Convertir → Comprimir) fallaba para casi cualquier formato salvo `.m4a`: siempre recodificaba a AAC pero guardaba el resultado con la extensión original — un `.mp3` terminaba siendo audio AAC dentro de un contenedor `.mp3`, que ffmpeg rechaza. Ahora el códec coincide con el contenedor de salida (`libmp3lame` para mp3, `libopus` para ogg/opus, AAC para el resto); los formatos sin pérdida (wav/aiff/flac), que no tienen forma real de "pesar menos" sin cambiar de códec, se reempacan como `.m4a` en vez de fallar en silencio.
- Convertir un PDF de muchas páginas a imágenes podía acumular memoria: cada página generaba una imagen temporal en un mismo bloque de trabajo cuyo autorelease pool no se vaciaba hasta terminar el documento completo. Ahora cada página libera sus temporales antes de pasar a la siguiente.

---

## v3.13.1 — Currency ya no confunde "1,000" con 1

**Arreglado**
- En la pestaña Currency, escribir un monto con separador de miles como `1,000` se leía como `1` — el parser convertía cualquier coma en punto decimal sin distinguir "coma de miles" de "coma decimal". Ahora una coma seguida de exactamente 3 dígitos (o más de una coma) se trata como separador de miles y se descarta; una coma con 1-2 dígitos (o ninguno) sigue leyéndose como decimal, así que `1,5` sigue siendo 1.5.

---

## v3.13.0 — Actualizaciones automáticas firmadas

**Agregado**
- Nueva sección **🔄 Actualizaciones** en Ajustes: NotchDrop puede revisar sola (una vez al día, o al pulsar "Buscar ahora") si hay una versión nueva publicada en GitHub Releases, y ofrecer instalarla en el mismo lugar.
- Antes de instalar cualquier cosa, verifica una firma Ed25519 sobre el `.zip` de la versión. La clave privada que produce esa firma solo vive en la Mac de quien publica releases (ver `scripts/keygen.swift` y `scripts/sign_release.swift`) y nunca se sube a git ni a GitHub — así, aunque alguien más entrara a la cuenta de GitHub del proyecto, no podría hacer que esta función instalara una versión suya en las Macs que ya tienen NotchDrop: la firma no coincidiría y la instalación se cancela.
- El toggle "Buscar actualizaciones automáticamente" (activado por defecto) vive en Ajustes; apagarlo deja el chequeo manual disponible con el botón "Buscar ahora".

**Verificación**
- Revisado a mano contra el código real: el flujo falla cerrado (no instala nada) si la clave pública todavía es el placeholder, si la firma no verifica, o si el release no trae `.zip` + `.zip.sig`.

---

## v3.12.1 — La barra de pestañas ya no se sale del panel

**Arreglado**
- En algunas Macs la pestaña **Currency** quedaba cortada en el borde derecho del panel y el engrane de Ajustes se dibujaba encima de ella. La fila de pestañas no tenía límite derecho, y con los 6 nombres completos cabía en el tamaño de panel pequeño con un margen de exactamente 0 pt — cualquier Mac que renderice el texto un poco más ancho la desbordaba.
- Ahora la barra se adapta al espacio real: si los nombres no caben, las pestañas no seleccionadas se muestran solo con ícono (con su nombre al pasar el mouse) y la seleccionada conserva el suyo. Además tiene un límite derecho fijo, así que nunca vuelve a encimarse con el engrane.

**Verificación**
- 13 pruebas con AppKit real a distintos anchos disponibles (500, 375, 330 y 200 pt), comprobando que la fila siempre cabe, que la pestaña seleccionada conserva su nombre y que todas tienen tooltip.

---

## v3.12.0 — Impuesto en Currency + arreglo de layout

**Agregado**
- Checkbox de **Impuesto** en la pestaña Currency: apagado por defecto (no cambia nada si no lo activas). Al marcarlo aparece un campo de porcentaje prellenado con **16** (editable a cualquier valor 0–100), que suma ese impuesto al monto antes o después de convertir moneda — el resultado es el mismo matemáticamente. El desglose se muestra en el texto de estado, por ejemplo `59.97 USD +16% = 69.57 USD · 1 USD = 0.92 EUR`.

**Arreglado**
- La pestaña Currency se compactó (fuentes y espaciados más chicos, monto e impuesto comparten fila) para que quepa completa sin necesitar scroll, incluso en el tamaño de panel más pequeño (0.85x) — donde antes el resultado quedaba invisible debajo del borde del panel al activar el impuesto.
- Como respaldo silencioso, el contenido de Currency ahora vive en un scroll view (mismo patrón que Notes), así que un desborde futuro nunca vuelve a ocultar contenido sin aviso.

**Verificación**
- 14 pruebas unitarias para el parseo del porcentaje de impuesto (válidos, negativos, con coma decimal, con símbolo %, vacío) antes de integrarlo.
- Verificado en la app real a escala 0.85 (el peor caso), confirmando que el resultado ya no se corta.

---

## v3.11.1 — Se acabó el "clic fantasma" del trackpad

**Arreglado**
- Pasar el mouse por el notch hacía que el trackpad se sintiera y sonara como si hubieras hecho clic, sin haberlo hecho. La app disparaba el motor háptico del trackpad (`NSHapticFeedbackManager`) cada vez que el panel se abría o cerraba — y como el hover usa esa misma ruta, bastaba con acercar el cursor. Lo mismo pasaba al alejarse, y al salir el mouse del panel abierto.
- Ahora el háptico solo responde a acciones deliberadas: clic en la píldora del notch o el atajo ⌥⌘N. Abrir por hover, cerrar por alejarse, soltar archivos, cambiar de pantalla o el cierre automático son silenciosos.

---

## v3.11.0 — La pestaña Currency ahora es calculadora

**Agregado**
- El campo de monto acepta **operaciones**: escribe `25*4`, `1200/3`, `(1200+800)/2` o `50*1.16` y convierte el resultado. El estado de abajo muestra la operación resuelta, p. ej. `19.99*3 = 59.97 USD`.
- El resultado se **actualiza mientras escribes**, sin tener que dar Enter.

**Arreglado**
- Escribir en el campo ya no dispara una consulta de red por cada tecla. El cálculo es local; la tasa solo se pide al cambiar de moneda o al dar Enter, y se reutiliza si ya se descargó ese mismo día.
- Si se pierde la conexión, se conserva en pantalla la última tasa conocida en vez de borrar el resultado.

**Nota técnica**
La calculadora usa un parser propio en vez de `NSExpression`. `NSExpression` lanza excepciones de Objective-C con entrada malformada, y Swift no las puede atrapar: escribir un `5*` a medias habría cerrado la app. El parser devuelve "sin resultado" en su lugar. Está cubierto por 35 pruebas, incluyendo división entre cero, paréntesis sin cerrar e intentos de inyección.

---

## v3.10.0 — Currency + portapapeles paginado

**Agregado**
- **Pestaña Currency**: conversor de divisas en vivo con 30 monedas (USD, EUR, GBP, CHF, JPY, MXN, etc.). Tasas reales del Banco Central Europeo vía Frankfurter.app, sin API key ni cuenta. Incluye botón para invertir el par y caché por par de monedas.
- **INSTALL.md**: guía de instalación en español para gente no técnica, incluyendo el caso de macOS Sequoia donde el diálogo de Gatekeeper solo ofrece "Mover al basurero".

**Arreglado**
- **Portapapeles amontonado**: antes se dibujaban todas las entradas de golpe y las filas se veían encimadas. Ahora se muestran 3 y hay un botón "Ver más (N)" abajo para revelar el resto.
- Las filas de texto se forzaron a una sola línea (`usesSingleLineMode`, `wraps = false`) para que no puedan romper a dos renglones bajo presión de layout.

**Cambiado**
- Historial de portapapeles guarda hasta 12 entradas (antes 5).
- Fuente y espaciado de la barra de pestañas reducidos ligeramente (12pt → 11pt) para que quepan 6 pestañas más el engranaje en el tamaño de panel más chico.

---

## v3.9.1 — Base pre-Currency

Versión con 5 pestañas: Player, Shelf, Tools, Notes, Convert. Incluye todo el trabajo previo:

- Now Playing universal (MediaRemote + puente Perl para macOS 15.4+), waveform en vivo por Core Audio, control de volumen del sistema, barra de progreso con búsqueda real.
- Shelf con persistencia, AirDrop, y descargador de links universal (yt-dlp) con reintentos automáticos para TikTok.
- Convertidor de formatos y compresión con objetivo de tamaño real (no CRF).
- Alarmas con tono sintetizado real, cronómetro, historial de portapapeles con imágenes.
- Notas rápidas a Apple Notes.
- Atajo global ⌥⌘N sin requerir permiso de Monitoreo de entrada.
- Notch dinámico que se adapta a cualquier Mac y a cualquier escalado de pantalla; notch simulado en Macs sin notch físico.
