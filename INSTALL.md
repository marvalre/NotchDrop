# Instalar NotchDrop

Guía rápida para instalar la app en tu Mac. No necesitas saber programar.

## 1. Descarga el archivo

Descarga `NotchDrop-3.10.0.zip` (o el que te hayan compartido) y ábrelo haciendo doble clic para descomprimirlo. Vas a obtener `NotchDrop.app`.

## 2. Muévela a Aplicaciones

Arrastra `NotchDrop.app` a tu carpeta **Aplicaciones**.

## 3. Autorízala la primera vez

Como esta app no viene de la App Store ni de un desarrollador pagado de Apple, macOS la bloquea la primera vez con un aviso de "no se pudo verificar". Es normal en software de código abierto.

**En macOS 15 (Sequoia) y más nuevo**, el aviso solo ofrece **"Mover al basurero"** y **"Listo"** — no hay botón para abrirla. No la borres:

1. Pulsa **Listo**.
2. Abre **Configuración del Sistema → Privacidad y Seguridad**.
3. Baja hasta el final, a la sección **Seguridad**. Ahí aparece *"NotchDrop fue bloqueada para proteger tu Mac"* con un botón **Abrir de todos modos**.
4. Púlsalo y confirma con tu contraseña o Touch ID.
5. Abre `NotchDrop.app` otra vez. Ya funciona.

Después de esto, la app abre normal con doble clic siempre.

> **Nota sobre el truco del clic derecho:** en versiones anteriores de macOS bastaba con hacer clic derecho sobre la app y elegir "Abrir". **Apple eliminó ese atajo**; en macOS 15+ el menú sigue mostrando "Abrir" pero el bloqueo aparece igual. El único camino es el de Configuración del Sistema descrito arriba.
>
> En **macOS 13 y 14** el clic derecho → Abrir todavía funciona, y el aviso sí incluye un botón "Abrir".

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

## 7. Actualizaciones

Desde Ajustes → **🔄 Actualizaciones**, NotchDrop puede revisar sola si hay una versión nueva en GitHub (una vez al día, o cuando pulses "Buscar ahora") y, si la encuentra, descargarla e instalarla en el mismo lugar sin que tengas que repetir los pasos de arriba.

Antes de instalar nada, verifica que el archivo venga firmado con una clave que solo existe en la Mac de quien publica los releases — así, aunque alguien más entrara a la cuenta de GitHub del proyecto, no podría hacer que esta función instalara una versión suya: la firma no coincidiría y NotchDrop se niega a instalar. Los detalles de cómo se genera y usa esa clave están en `scripts/keygen.swift` y `scripts/sign_release.swift`.

Si prefieres no usarla, apaga "Buscar actualizaciones automáticamente" en Ajustes; el paso 3 de arriba sigue funcionando igual para instalar a mano.

## ¿Problemas?

- **"NotchDrop no se puede abrir porque no se puede verificar"** → repite el paso 3 (clic derecho → Abrir).
- **No aparece nada en pantalla** → revisa que esté corriendo en Monitor de Actividad buscando "NotchDrop"; si no, ábrela de nuevo desde Aplicaciones.
- **Los links no descargan** → probablemente falta `yt-dlp` (paso 5).
