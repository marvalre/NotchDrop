# Historial de versiones

Cada versión está marcada con un tag de git. Para volver a una versión anterior:

```bash
cd "/Users/marcelo/M Visuals/Proyectos/NotchDrop"
git checkout v3.9.1      # ver esa versión
git checkout main        # volver a la actual
```

Para revertir **permanentemente** a una versión anterior (con cuidado — pierdes lo posterior):

```bash
git reset --hard v3.9.1
```

También hay copias completas del código fuente en `snapshots/` (fuera de git) y del `.app` compilado en `backups/`, por si quieres recuperar algo sin tocar git.

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
