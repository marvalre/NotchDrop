#!/bin/bash
# Publica una versión:  scripts/release.sh 3.13.1 notas.md
# Antes: actualizar CHANGELOG.md y tener la llave en el Llavero (ver RELEASING.md).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?uso: scripts/release.sh <versión> <notas.md>}"
NOTES="${2:?uso: scripts/release.sh <versión> <notas.md>}"
[ -f "$NOTES" ] || { echo "No existe $NOTES"; exit 1; }
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "Hay cambios sin commit: haz commit primero."; git status --short; exit 1; }
BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist) + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" Info.plist
tests/run.sh
./build.sh
ZIP="NotchDrop-$VERSION.zip"
rm -f NotchDrop-*.zip NotchDrop-*.zip.sig
ditto -c -k --sequesterRsrc --keepParent NotchDrop.app "$ZIP"
swift scripts/update-keys.swift sign "$ZIP"
swift scripts/update-keys.swift verify "$ZIP"
git add Info.plist
git commit -m "Release $VERSION"
git tag -a "v$VERSION" -m "NotchDrop v$VERSION"
git push origin main "v$VERSION"
gh release create "v$VERSION" "$ZIP" "$ZIP.sig" --title "NotchDrop v$VERSION" --notes-file "$NOTES"
echo "Publicado v$VERSION"
