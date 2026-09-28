# Actualizaciones automáticas — diseño

**Estado:** propuesta · **Versión objetivo:** 3.13.0 · **Fecha:** 2026-09-28

## Objetivo

Que NotchDrop avise cuando hay una versión nueva y se actualice con un clic, en cualquier Mac donde esté instalada, sin costo para el autor ni para los usuarios y sin volver a pasar por el aviso de seguridad de macOS.

## Lo que ya se comprobó antes de diseñar

Dos supuestos condicionaban todo el diseño. Se probaron en macOS 26.6 con apps reales firmadas ad-hoc, lanzadas con `open`:

1. **Una descarga hecha por la propia app no recibe cuarentena.** Un zip descargado con `URLSession` y extraído con `ditto` no tiene el atributo `com.apple.quarantine`. `Info.plist` no declara `LSFileQuarantineEnabled`. Por eso Gatekeeper no vuelve a pedir "Abrir de todos modos" en las actualizaciones.
2. **Una app firmada ad-hoc puede reemplazar un bundle en `/Applications`.** `FileManager.replaceItemAt` reemplazó una app de prueba sin mostrar el aviso de "Gestión de apps" de macOS.

## Costo

Cero. Usa GitHub Releases, que ya se usa hoy, y la API pública de GitHub (60 consultas por hora por IP; la app consulta una vez al día). La firma usa CryptoKit, que viene con macOS. No requiere cuenta de Apple Developer ni ningún servidor.

## Flujo para el usuario

1. Al abrir la app (10 s después) y luego cada 24 h, NotchDrop consulta el último release en GitHub.
2. Si hay una versión más nueva, manda una notificación del sistema y en Ajustes aparece: *"Versión X disponible — Actualizar"*.
3. El usuario pulsa **Actualizar**. La app descarga, verifica, se reemplaza y se vuelve a abrir sola.
4. En Ajustes también hay **Buscar ahora** y un interruptor **Buscar actualizaciones automáticamente** (activado por defecto).

La instalación nunca es silenciosa: siempre la dispara un clic del usuario. Así una actualización no interrumpe algo que esté usando, como una alarma o una descarga en curso.

## Seguridad

Actualizar sola significa que la app descarga y ejecuta código de internet. Por eso cada release va **firmado con una llave Ed25519**:

- La **llave pública** va compilada dentro de la app.
- La **llave privada** solo existe en la Mac del autor, en el Llavero de macOS (ítem `NotchDrop update signing key`). Nunca entra al repo.
- Cada release publica dos archivos: `NotchDrop-X.zip` y `NotchDrop-X.zip.sig`, que es la firma del zip.
- La app **rechaza** cualquier zip cuya firma no coincida, aunque venga de GitHub. Si alguien tomara la cuenta de GitHub, no podría mandar una actualización a los usuarios sin la llave privada.

Después de verificar la firma, la app también comprueba que el bundle extraído tenga el mismo `CFBundleIdentifier`, que su versión coincida con la del release y que pase `codesign --verify`.

**Riesgo operativo:** si se pierde la llave privada, ya no se pueden publicar actualizaciones que las copias instaladas acepten. Habría que generar una llave nueva y pedir a los usuarios una instalación manual. Conviene respaldarla, por ejemplo en un gestor de contraseñas.

## Componentes

Todo vive en `NotchDrop.swift`, en una sección `// MARK: - Updates`. El archivo tiene código de arranque al final, así que un segundo archivo complicaría el build.

| Componente | Qué hace | Cómo se prueba |
|---|---|---|
| `UpdateVersion.isNewer(_:than:)` | Compara versiones tipo `3.13.0` vs `v3.12.1` numéricamente | Pruebas unitarias |
| `UpdateSignature.verify(data:signature:publicKey:)` | Verifica la firma Ed25519 | Pruebas con una llave de prueba |
| `UpdateChecker` | Consulta la API de GitHub, extrae versión y URLs del zip y `.sig` | Prueba de punta a punta contra un servidor local |
| `UpdateInstaller` | Descarga, verifica, extrae, valida, reemplaza y relanza | Prueba de punta a punta contra un servidor local |

### Reemplazo y reinicio

1. Extrae el zip en una carpeta temporal.
2. `replaceItemAt(appActual, withItemAt: nueva, backupItemName: "NotchDrop (anterior).app", options: .withoutDeletingBackupItem)` es atómico y conserva la versión anterior.
3. Manda la versión anterior a la **Papelera**, no la borra, para poder recuperarla.
4. Lanza un proceso pequeño que espera a que termine la app actual y abre la nueva. Después la app se cierra sola.

## Qué pasa cuando algo falla

| Situación | Comportamiento |
|---|---|
| Sin internet o GitHub no responde | Revisión automática: silencio, reintenta al día siguiente. "Buscar ahora": muestra el error. |
| Límite de la API de GitHub | Igual que sin internet. |
| La firma no coincide | No instala nada. Mensaje: *"La actualización no pasó la verificación de seguridad y no se instaló."* |
| El bundle no pasa las validaciones | No instala nada. Muestra el motivo. |
| `/Applications` no tiene permiso de escritura | Muestra el mensaje con el enlace de descarga manual. |
| Falla a mitad del reemplazo | `replaceItemAt` es atómico: queda la versión anterior intacta. |

## Cómo se publica una versión (autor)

Un script nuevo, `scripts/release.sh 3.13.0`:

1. Sube la versión en `Info.plist`.
2. Compila con `build.sh` y crea el zip.
3. Firma el zip con la llave del Llavero y genera el `.sig`.
4. Hace commit, crea el tag y el Release de GitHub con los dos archivos.

Todo queda documentado en `RELEASING.md`, junto con cómo respaldar la llave.

## Transición

Quien tenga la versión 3.12.1 o anterior necesita instalar **a mano una última vez** la 3.13.0, que es la que trae el actualizador. De ahí en adelante se actualiza sola.

## Pruebas

- **Unitarias**, con el patrón de harness que ya usa el proyecto: comparación de versiones (incluye `v` inicial, distintas longitudes, iguales, menores) y verificación de firma (válida, un byte alterado, llave equivocada, firma corrupta o vacía).
- **De punta a punta, sin tocar el repo público**: una clave de depuración en `UserDefaults` (`NotchDropUpdateFeedURL`) apunta la app a un servidor HTTP local que sirve un release falso. Se prueban el camino feliz (3.13.0 → 3.13.1) y el rechazo de un zip con la firma alterada. La firma sigue siendo obligatoria con esa clave, así que no abre ningún hueco de seguridad.

## Fuera de alcance

- Instalación silenciosa sin clic.
- Canales beta o bajar de versión.
- Actualizaciones delta; el zip completo pesa unos 300 KB.
