# NotchDrop

Convierte el notch de tu MacBook en un Dynamic Island funcional: reproductor, bandeja de archivos, descargador de links, convertidor de formatos, herramientas rápidas y notas — todo desde un panel que vive en la parte superior de la pantalla.

En Macs **sin** notch físico dibuja uno simulado, así que funciona en cualquier Mac.

---

## Funciones

### 🎵 Player
- **Now Playing universal** — Apple Music, Spotify, Safari, Chrome y cualquier app que publique una sesión del sistema. Con respaldo por AppleScript para Spotify y detección de Netflix en Chrome.
- **Waveform en vivo** — niveles reales del audio de salida mediante un *process tap* de Core Audio. No usa ScreenCaptureKit, así que nunca aparece el ícono de "compartiendo pantalla".
- **Control de volumen del sistema** — con silenciar, sincronizado con cambios hechos desde el teclado o Control Center.
- **Barra de progreso con búsqueda** — arrastra para adelantar la canción.
- **Espejo de cámara** — vista rápida de la cámara frontal.

### 📁 Shelf
- Arrastra archivos al notch para guardarlos temporalmente y volver a arrastrarlos a donde los necesites.
- **AirDrop** directo de lo que tengas en la bandeja.
- **Descarga de links** — pega un link de TikTok, Instagram, X, YouTube, Reddit (~1800 sitios) y baja el video o la imagen. Elige **MP4** o **MP3**. Los archivos van a `Descargas` y aparecen en la bandeja.
- El Shelf **persiste** entre reinicios.

### 🔄 Convert
- **Cambiar formato** según lo que subas:
  - Video → MP4, MOV, M4V, WebM, GIF, MP3, M4A, WAV
  - Audio → MP3, M4A, WAV, AIFF, FLAC
  - Imagen → PNG, JPG, HEIC, TIFF, PDF
  - PDF → PNG, JPG (una imagen por página)
- **Comprimir** con calidad ajustable (90 / 75 / 50 / 30 %).
- Nunca sobrescribe el original: escribe al lado con nombre distinto.

### ⚡ Tools
- **Alarmas** por preset o por hora específica, con un tono de alarma real en loop (no un bip de notificación). Se detiene desde el panel o desde la notificación.
- **Cronómetro.**
- **Historial de portapapeles** con texto e imágenes. Respeta los marcadores de "contenido confidencial" que usan los gestores de contraseñas, así que las contraseñas copiadas nunca se guardan.

### 📝 Notes
Captura rápida directo a Apple Notes.

### 💵 Currency
Conversor de divisas **y calculadora** — 30 monedas (USD, EUR, GBP, CHF, JPY, MXN, etc.), tasas reales vía [Frankfurter.app](https://www.frankfurter.app) (fuente BCE, sin API key).

El campo de monto acepta operaciones: escribe `19.99*3` o `(1200+800)/2` y convierte el resultado, mostrando la operación resuelta. Se actualiza mientras escribes, sin dar Enter. Hay un botón para invertir el par, y las tasas se reutilizan durante el día para no repetir consultas.

### ⚙️ Ajustes
Auto-inicio, apertura por hover, tamaño del panel, diagnóstico del notch, persistencia del portapapeles, configuración del descargador y tutorial.

### ⌨️ Atajo global
**⌥⌘N** abre y cierra el notch desde cualquier app. Usa la API de Carbon, que **no requiere el permiso de "Monitoreo de entrada"** — solo registra esa combinación, sin ver el resto de lo que escribes.

---

## Instalación

> ¿Solo quieres instalarlo, sin tecnicismos? Usa [INSTALL.md](INSTALL.md).

### Desde el código

```bash
git clone <url-del-repo>
cd NotchDrop
./build.sh
cp -R NotchDrop.app /Applications/
```

### Desde una release

Descarga el `.app` y muévelo a `/Applications`. La primera vez macOS lo bloqueará: ve a **Configuración del Sistema → Privacidad y Seguridad**, baja hasta **Seguridad** y pulsa **Abrir de todos modos**.

> Ese paso extra es porque la app no está *notarizada* con una cuenta Apple Developer de pago. Es normal en herramientas open source; solo pasa la primera vez.
>
> En macOS 15 (Sequoia) y más nuevo, el aviso solo ofrece "Mover al basurero" y "Listo" — **el viejo truco de clic derecho → Abrir ya no evita el bloqueo**, Apple lo eliminó. Guía paso a paso con capturas: [INSTALL.md](INSTALL.md).

---

## Actualizaciones

Desde la 3.13.0 NotchDrop busca versiones nuevas una vez al día en GitHub (se puede apagar en Ajustes). Si encuentra una, avisa y espera a que pulses **Actualizar**; nunca instala solo.

Cada versión se publica con una firma Ed25519 (`NotchDrop-X.zip.sig`) y la app la verifica contra la llave pública incluida en su código antes de tocar nada. Además valida que el paquete sea el de NotchDrop y la versión publicada, reemplaza la app de forma atómica y manda la anterior a la Papelera. Detalles de diseño en `docs/superpowers/specs/2026-09-28-auto-update-design.md`; cómo publicar una versión en `RELEASING.md`.

## Requisitos

- **macOS 13.0+** (Ventura). El waveform en vivo requiere 14.2+.
- Cualquier Mac. Con notch se ve mejor; sin notch se dibuja uno simulado.

### Opcionales

| Herramienta | Para qué | Instalar |
|---|---|---|
| `yt-dlp` | descargar links | `brew install yt-dlp` |
| `ffmpeg` | convertir video/audio | `brew install ffmpeg` |

Las conversiones de **imagen y PDF no necesitan nada** — usan frameworks nativos de macOS.

---

## Permisos

macOS los pedirá por separado la primera vez:

| Permiso | Para qué |
|---|---|
| Notificaciones | Alarmas |
| Grabación de pantalla y audio del sistema | El waveform en vivo. Solo se procesan niveles en memoria; nunca se graba ni se guarda audio. |
| Cámara | Solo al activar el espejo manualmente |
| Automatización (Spotify, Chrome, Notes, System Events) | Respaldos de Now Playing, guardar notas, menú de AirPlay |

**Todo el procesamiento ocurre localmente.** NotchDrop no envía nada a ningún servidor.

---

## Notas técnicas

### Posición del notch
La posición y el tamaño se leen del sistema en tiempo real (`NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea` / `safeAreaInsets`), nunca de valores fijos. Esto importa porque **el tamaño del notch en puntos cambia con el escalado de pantalla**, no solo con el modelo de Mac. También se recalcula al conectar/desconectar monitores o al despertar la Mac.

### Dependencia de MediaRemote
Now Playing universal usa `MediaRemote.framework`, un framework privado no documentado de Apple. En macOS 15.4+ ya no es accesible directamente desde apps de terceros, así que se incluye un puente ([MediaRemoteAdapter](third-party/MediaRemoteAdapter), de Jonas van den Berg, BSD-3-Clause) que hace esas llamadas vía Perl. Si Apple lo cambia, NotchDrop cae automáticamente a los respaldos de AppleScript.

Por esa API privada **esta app no puede publicarse en la Mac App Store**, que además exige sandbox — incompatible con ejecutar `yt-dlp`/`ffmpeg` y con capturar audio del sistema. La distribución directa es la ruta correcta para esta categoría de herramienta.

### TikTok
El reto anti-bot de TikTok es no determinista: en pruebas repetidas del mismo link, alrededor de 1 de cada 5 intentos funciona. La app usa la API de la app móvil (`app_info`) y **reintenta automáticamente hasta 6 veces**, lo que sube la tasa de éxito a ~74 %. Si activas las cookies del navegador en Ajustes, TikTok deja de funcionar — déjalas apagadas salvo que las necesites para contenido privado de otro sitio.

---

## Licencia

MIT — ver [LICENSE](LICENSE). Incluye [MediaRemoteAdapter](third-party/MediaRemoteAdapter) bajo BSD-3-Clause.
