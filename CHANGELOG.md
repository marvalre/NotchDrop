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

## v3.13.6 — Pendientes del escaneo

**Arreglado**
- **Iniciar al abrir sesión:** el interruptor se quedaba en "activado" aunque lo apagaras en Configuración del Sistema. Ahora se actualiza cada vez que abres Ajustes, y si macOS pide aprobación te lleva a esa pantalla.
- **Pastillas del island** (carátula y onda a los lados del notch): ahora un clic las abre; antes no hacían nada.
- **Teclado tras cerrar el panel:** si escribías en una nota y el panel se cerraba solo al alejar el mouse, las teclas seguían yendo al panel invisible hasta que hacías clic en tu app. Ahora se le devuelve el foco (macOS 14+).
- **Barras de scroll clásicas** (cuando hay mouse conectado) comían 15 pt del panel pequeño; ahora todas las áreas de scroll usan barras superpuestas.
- **Medidor de audio:** carrera de datos entre el hilo de audio y el principal, resuelta con un candado.
- **Arranque:** la limpieza de procesos huérfanos del reproductor ya no corre en el hilo principal.

**Verificación**
- 250 pruebas automáticas, la app compilada arranca y no genera reportes de fallo.

---

## v3.13.5 — Memoria: Netflix en Chrome, portapapeles y descargas

**Arreglado**
- **Netflix en Chrome llenaba la memoria.** Mientras la app detectaba Netflix, cada 3 segundos convertía el icono de Chrome a un TIFF de **74 MB** que no se liberaba: medido, el consumo subía a ~4.8 GB en pocos minutos. Ahora el icono es un PNG de 128 px que se genera una sola vez (unos KB).
- **Portadas distintas con el mismo tamaño** dejaban la anterior en pantalla (la comparación solo miraba el tamaño y los primeros bytes). Ahora se compara con una huella SHA-256.
- **Portapapeles:** un texto enorme (p. ej. un log de 20 MB) congelaba la app ~0.8 s en cada copia posterior y se guardaba completo. Ahora no se guarda texto de más de 1 MB en el historial (lo que copiaste sigue funcionando normal en el portapapeles del sistema) y cada fila dibuja solo los primeros 300 caracteres.
- **Descargas de herramientas/actualizaciones sin plazo total.** Un servidor lento que iba goteando bytes podía dejar los botones "Instalar"/"Actualizar" bloqueados por horas. Ahora hay un tope de 15 minutos por descarga.
- **Cámara espejo:** abrir y cerrar rápido podía dejar la cámara encendida (inicio y paro corrían en colas distintas).
- **Descarga de carátulas de Spotify:** al vencer el plazo ahora se cancela la descarga en vez de dejarla corriendo.
- **Restos de instalación:** si cerrabas la app a media instalación de herramientas quedaban archivos ocultos de decenas de MB; se limpian al abrir.

**Verificación**
- 250 comprobaciones automáticas. Cada arreglo tiene prueba (incluida una con un servidor local que gotea bytes).

---

## v3.13.4 — Correcciones del escaneo: imágenes, notas, alarmas y un crash

**Arreglado**
- **Descarga directa de imágenes.** Ya no guarda como "imagen" una página de error (404) ni un HTML de login: exige respuesta 2xx y tipo de imagen, y la extensión sale de la URL o del tipo MIME, nunca del nombre que decida el servidor (un `.png` que en realidad era un ejecutable ya se rechaza).
- **Notes interpretaba tu texto como HTML.** `<b>`, `a < b` o `R&D` se comían o se transformaban, y los saltos de línea se perdían. Ahora se escapa y se conservan las líneas (comprobado guardando una nota real en Apple Notes). El botón ahora confirma "✓ Guardada" o avisa si falló el permiso.
- **Alarmas que suenan horas tarde.** Si la Mac dormía durante la alarma, al despertar sonaba el tono en loop con horas de retraso. Ahora, pasados 2 minutos, se marca como **"Alarma perdida — era a las…"** y no suena. Igual al reabrir la app. Textos de la notificación en español.
- **Crash con duración infinita.** Una transmisión en vivo (o metadatos corruptos) que reporta duración infinita hacía que la app se cerrara al dibujar el tiempo. Ahora se muestra 0:00.
- **Hover y arrastre.** Arrastrar un archivo por otro monitor situado encima del notch abría el Shelf; ahora solo cuenta la pantalla del notch. La fila superior de píxeles (donde se pega el cursor) también se cuenta como zona válida.
- **Chrome/Netflix.** Con Chrome abierto y en silencio, la app ya no revisa todas sus pestañas con AppleScript cada 3 segundos; solo lo hace cuando hay audio.
- **Tutorial** mencionaba 4 de las 7 pestañas.

**Verificación**
- 241 comprobaciones automáticas (antes 210). Cada arreglo tiene su prueba.

---

## v3.13.3 — Los MP4 descargados se abren en cualquier lado

**Arreglado**
- **Descargas en MP4 salían en AV1.** Para un video normal de YouTube, el selector anterior elegía **AV1 a 2160p**: archivos enormes que QuickTime (en varios Macs), CapCut y la mayoría de los editores no abren. Ahora prefiere **H.264**, que se abre en todos lados. Medido con el mismo video: antes `av01 2160p`, ahora `avc1 1080p`. El costo: en YouTube, H.264 llega hasta 1080p (el 4K solo existe en AV1/VP9).

**Verificación**
- Descarga real de YouTube con los argumentos exactos de la app y las herramientas que instala la app: sale `h264 + aac`, con video y audio unidos en `.mp4`. MP3 real también comprobado (`mp3`, 19 s).

---

## v3.13.2 — Descargas: las herramientas se instalan con un clic

**Agregado**
- **Botón "Instalar herramientas"** (Shelf y Ajustes → Descarga de links). Antes había que abrir la Terminal, instalar Homebrew y correr `brew install yt-dlp ffmpeg`, y ahí se atoraba la gente. Ahora la app descarga yt-dlp, ffmpeg y ffprobe sola (unos 75 MB, ~20 s en fibra), sin Homebrew ni contraseña, a `~/Library/Application Support/NotchDrop/bin`. Cada archivo se verifica con SHA-256 antes de ejecutarse y, si algo falla, lo que ya estuviera instalado queda intacto. Si el Mac ya tiene las herramientas de Homebrew, se usan esas.
- Al abrir **Shelf**, si faltan, el botón aparece de entrada con una explicación en vez de esperar a que la descarga falle.

**Arreglado**
- **"ERROR: Postprocessing: ffprobe and ffmpeg not found"** al bajar MP3 (o al unir video y audio): la app no le decía a yt-dlp dónde estaba ffmpeg. Ahora se lo indica siempre (`--ffmpeg-location`), y el error en inglés se sustituye por un mensaje claro con el botón para instalar.
- **Safari: "Contenido privado… prueba activar cookies" aunque ya estuvieran activadas.** El error real era que macOS bloquea las cookies de Safari sin *Acceso total al disco*, y la app lo confundía por contener la palabra "cookies". Ahora lo explica y ofrece abrir esa pantalla de Configuración del Sistema.

**Verificación**
- Prueba real con las URLs y hashes reales: instalación completa en 18 s; con las herramientas de la app, la extracción de MP3 funciona, y sin `--ffmpeg-location` reproduce exactamente el error de la captura.
- Prueba de punta a punta con un servidor local: hash alterado, binario que no corre y actualización mala se rechazan sin dejar archivos ni romper lo instalado.

---

## v3.13.1 — Convertir PDF a imagen ya no se come toda la memoria

**Arreglado**
- **PDF → PNG/JPG usaba una cantidad absurda de memoria.** Un PDF de 40 páginas grandes llegaba a **5.4–7.2 GB** de pico; ahora usa **195 MB**, igual en cada corrida. El código hacía tres copias completas de cada página (imagen → TIFF → bitmap → archivo) y no soltaba ninguna hasta terminar el PDF. Ahora dibuja cada página en un solo bitmap y lo guarda con ImageIO, liberándolo antes de la siguiente.
- La resolución de salida se conserva: 4× (288 dpi). El código anterior decía 2× pero en pantallas Retina generaba 4× sin querer; ahora es 4× en cualquier Mac, con un tope de 9000 px para páginas tamaño póster.

**Verificación**
- Pruebas con un PDF real de 3 páginas de colores: cantidad de imágenes y nombres, dimensiones exactas, color de cada página, orientación (el cuadro negro queda abajo a la izquierda), JPG de una sola página y un PDF inválido. Medición de memoria antes/después con el mismo PDF.

---

## v3.13.0 — La app se actualiza sola (con un clic) y una tanda de arreglos

**Agregado**
- **Actualizaciones dentro de la app.** Ajustes → *Actualizaciones*. Una vez al día busca en GitHub; si hay versión nueva llega una notificación y aparece el botón **Actualizar**. Nunca instala nada sin que lo pulses. La descarga la hace la app misma, así que macOS no vuelve a pedir "Abrir de todos modos".
- **Firmadas.** Cada versión lleva un sello digital (Ed25519) y la app rechaza cualquier descarga que no coincida con la llave pública que trae dentro, aunque viniera de GitHub. Además comprueba que el paquete sea de NotchDrop, que su versión sea la publicada y que pase `codesign`.
- **Instalación segura.** El reemplazo es atómico: si algo falla, tu app queda exactamente como estaba. La versión anterior va a la Papelera, no se borra.
- Quien tenga una versión anterior a esta necesita instalarla **a mano una última vez**; de ahí en adelante se actualiza sola.

**Arreglado**
- **Currency: "1,000" se leía como 1.** Ahora la coma se interpreta número por número: decimal en `1,5`, miles en `1,000` / `12,345` / `1,000,000`, y con ambos separadores el último es el decimal (`1,000.50`, `1.000,50`). Sumas como `1,5+1,5` siguen dando 3 y `1,000+2,5` da 1002.5.
- **⌥⌘N: el panel abierto con el atajo se cerraba solo** al cabo de ~1 segundo. Medido en esta Mac: abierto 0.8 s y luego cerrado. Ahora se queda abierto hasta que el mouse haya entrado al panel una vez (o lo cierres con el atajo o un clic fuera).
- **Comprimir audio y video fallaba** para MP3, FLAC, AIFF, Opus y WebM, y para WAV "terminaba bien" con un archivo que nada puede reproducir. Ahora el códec se elige según el contenedor (MP3 → MP3, Opus → Opus) y los formatos que no pueden comprimirse bajando bitrate salen como `.m4a` / `.mp4`. Un intento fallido ya no deja un archivo vacío junto al original.
- **Cronómetro perdía tiempo**: contaba disparos de un timer y se atrasaba al hacer scroll o abrir un menú (4.5 s reales mostraban 1.6 s). Ahora usa el reloj real.
- **Now Playing se podía congelar tras horas de uso** (el puente escribía a un canal que nadie leía) y **dejaba procesos huérfanos** al cerrar o reiniciar la app: en esta Mac había 8, uno de más de 9 horas. Ahora se detiene al salir (también con `kill`), limpia los que hayan quedado de antes y se reinicia solo si se cae.
- Las pestañas conservan su nombre completo: primero se aprieta el espacio entre ellas y solo se dejan como ícono cuando de verdad no caben (3.12.2).

**Verificación**
- Las pruebas ahora compilan el `NotchDrop.swift` real (antes copiaban fragmentos): 156 comprobaciones, incluidas conversiones con ffmpeg real de MP3, M4A, WAV, FLAC, AIFF, Opus, MP4, MKV y WebM.
- Prueba de punta a punta del instalador contra un servidor local: instala una app válida; con un zip alterado, con un zip firmado de otra versión o sin permiso de escritura, rechaza y deja la app instalada byte por byte igual.

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
