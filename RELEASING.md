# Publicar una versión

## La llave de firma (léelo una vez)

Cada versión que publicas lleva un **sello digital**. Las apps instaladas revisan ese sello antes de actualizarse; si no coincide, no instalan nada. Así, aunque alguien entrara a tu cuenta de GitHub, no podría mandarles una actualización falsa: para sellarla necesitaría además tu Mac.

- **Dónde vive el secreto:** en el Llavero de tu Mac (Acceso a Llaveros → "NotchDrop update signing key"). No está en el repo ni en GitHub.
- **Qué va dentro de la app:** solo la parte pública (`UpdateSignature.publicKeyBase64` en `NotchDrop.swift`). Es segura de publicar.

## Respalda la llave (una sola vez, 1 minuto)

Si tu Mac se pierde o se borra y no tienes copia, ya no podrás sellar versiones nuevas. Nada se rompe: las apps instaladas siguen funcionando igual. Pero cada persona tendría que reinstalar a mano.

1. En Terminal, copia el secreto al portapapeles (no se muestra en pantalla):

   ```bash
   security find-generic-password -a NotchDrop -s "NotchDrop update signing key" -w | pbcopy
   ```

2. Ábrelo en la app **Contraseñas** de tu Mac → **+** → nombre "NotchDrop llave de firma" → pega en el campo de contraseña → guarda.
3. Borra el portapapeles copiando cualquier otra cosa.

**Nunca** pegues ese valor en el repo, en un chat ni en un correo.

## Restaurarla en otra Mac

```bash
security add-generic-password -a NotchDrop -s "NotchDrop update signing key" -w "<el valor guardado>"
```

## Publicar

1. Haz tus cambios y commit.
2. Agrega la versión nueva al principio de `CHANGELOG.md` y escribe las notas del Release en un archivo, por ejemplo `notas.md`.
3. Ejecuta:

   ```bash
   scripts/release.sh 3.13.1 notas.md
   ```

Sube la versión en `Info.plist`, corre las pruebas, compila, crea el zip, lo firma y verifica la firma, hace commit y tag, y crea el Release con `NotchDrop-X.zip` y `NotchDrop-X.zip.sig`. Si algo falla, se detiene antes de publicar.
