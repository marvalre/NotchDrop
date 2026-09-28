#!/bin/bash
# Builds NotchDrop.app from source.
#
# Requires: Xcode command line tools (swiftc).
# Optional at runtime:
#   yt-dlp  — link downloads      (brew install yt-dlp)
#   ffmpeg  — video/audio convert (brew install ffmpeg)
set -euo pipefail

APP="NotchDrop.app"
CONTENTS="$APP/Contents"

echo "==> Preparing bundle"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

# Info.plist carries LSUIElement (no Dock icon) and every usage-description
# string macOS requires before it will even ask for a permission. Without it the
# app shows up in the Dock and silently fails to request camera/notifications.
cp Info.plist "$CONTENTS/Info.plist"

# Bundled third-party adapter. macOS 15.4+ blocks direct MediaRemote calls from
# third-party apps, so Now Playing goes through this. BSD-3-Clause: its LICENSE
# must travel with it.
cp -R third-party/MediaRemoteAdapter "$CONTENTS/Resources/"

echo "==> Compiling"
swiftc \
  -framework Cocoa \
  -framework AVFoundation \
  -framework CoreMedia \
  -framework CoreAudio \
  -framework UserNotifications \
  -framework ServiceManagement \
  -framework Carbon \
  -framework PDFKit \
  -parse-as-library -O NotchDrop.swift -o "$CONTENTS/MacOS/NotchDrop"
chmod +x "$CONTENTS/MacOS/NotchDrop"

echo "==> Signing (ad-hoc)"
# Enough to run locally. Not notarized, so on someone else's Mac the first
# launch needs right-click -> Open. See README.
codesign --force --deep -s - "$APP"
codesign --verify --verbose "$APP"

echo "==> Verifying bundle contents"
for required in \
  "$CONTENTS/Info.plist" \
  "$CONTENTS/MacOS/NotchDrop" \
  "$CONTENTS/Resources/MediaRemoteAdapter/run.pl" \
  "$CONTENTS/Resources/MediaRemoteAdapter/libMediaRemoteAdapter.dylib"
do
  [ -e "$required" ] || { echo "FALTA: $required"; exit 1; }
done

echo "==> Done: $APP"
echo "    Install: cp -R $APP /Applications/"
