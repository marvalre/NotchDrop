# Instalar NotchDrop

Guía rápida para instalar la app en tu Mac. No necesitas saber programar.

## 1. Descarga el archivo

Descarga `NotchDrop-3.10.0.zip` (o el que te hayan compartido) y ábrelo haciendo doble clic para descomprimirlo. Vas a obtener `NotchDrop.app`.

## 2. Muévela a Aplicaciones

Arrastra `NotchDrop.app` a tu carpeta **Aplicaciones**.

## 3. Ábrela (el primer clic derecho es obligatorio)

Como esta app no viene de la App Store ni de un desarrollador pagado de Apple, macOS te va a advertir "no se puede verificar" o "desarrollador no identificado" la primera vez. Es normal en apps de código abierto — así se evita:

1. En **Aplicaciones**, haz **clic derecho (o Control + clic)** sobre `NotchDrop.app`.
2. Elige **Abrir**.
3. Aparece una alerta — pulsa **Abrir** de nuevo.

Después de este primer paso, la app abre normal con doble clic siempre.

> **Si ves "No se abrió NotchDrop" con solo los botones "Mover al basurero" / "Listo"** (sin opción de abrir) — esto pasa en macOS Sonoma/Sequoia si se abrió con doble clic directo en vez de clic derecho. Solución:
> 1. Pulsa **Listo** (no borres el archivo).
> 2. Ve a **Configuración del Sistema → Privacidad y Seguridad**.
> 3. Baja hasta **Seguridad** — ahí aparece el aviso de NotchDrop con un botón **Abrir de todos modos**. Púlsalo y confirma con tu contraseña o Touch ID.
> 4. Abre `NotchDrop.app` de nuevo — ahora sí aparece un botón para abrirla, y de ahí en adelante abre normal.

## 4. Permisos que te va a pedir

La primera vez que uses cada función, macOS pedirá permiso por separado. Todos son normales y necesarios:

| Cuándo aparece | Para qué es |
|---|---|
| Al abrir la app | Notificaciones (para las alarmas) |
| Al reproducir música | Grabación de pantalla y audio del sistema — solo mide el volumen para dibujar la onda visual, **nunca graba ni guarda nada** |
| Si activas el espejo de cámara | Cámara |
| Al usar Now Playing / guardar notas | Automatización (Spotify, Chrome, Notes) |

Todo esto se procesa **en tu Mac**. NotchDrop no manda nada a internet, salvo:
- Cuando tú pegas un link para descargar un video (usa `yt-dlp`, que se conecta a ese sitio para bajarlo).
- La pestaña **Currency**, que consulta tasas de cambio públicas (sin API key, sin cuenta).

## 5. Herramientas opcionales

Algunas funciones necesitan una herramienta externa gratuita instalada. Si no la tienes, la app simplemente avisa que falta — nada se rompe.

Abre **Terminal** (Cmd+Espacio, escribe "Terminal") y pega:

```bash
brew install yt-dlp ffmpeg
```

- `yt-dlp` → para descargar videos de TikTok/Instagram/YouTube/X, etc.
- `ffmpeg` → para convertir/comprimir video y audio.

Si no tienes Homebrew instalado, primero corre esto y sigue las instrucciones en pantalla:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Convertir imágenes y PDF **no necesita nada de esto** — funciona directo.

## 6. Usarla

- El panel vive arriba, en el notch (o en la parte de arriba de la pantalla si tu Mac no tiene notch — dibuja uno simulado).
- Pásale el mouse por encima para abrirlo, o usa el atajo **⌥⌘N** (Option + Comando + N) desde cualquier app.
- Arrastra archivos ahí para guardarlos temporalmente (Shelf), pega links para descargar, convierte formatos, pon alarmas, revisa tu historial de portapapeles, o convierte monedas — todo desde las pestañas de arriba.

## ¿Problemas?

- **"NotchDrop no se puede abrir porque no se puede verificar"** → repite el paso 3 (clic derecho → Abrir).
- **No aparece nada en pantalla** → revisa que esté corriendo en Monitor de Actividad buscando "NotchDrop"; si no, ábrela de nuevo desde Aplicaciones.
- **Los links no descargan** → probablemente falta `yt-dlp` (paso 5).
