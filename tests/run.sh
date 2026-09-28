#!/bin/bash
# Compiles the real NotchDrop.swift next to tests/main.swift and runs the tests.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
swiftc -D NOTCHDROP_TESTS \
  -framework Cocoa -framework AVFoundation -framework CoreMedia -framework CoreAudio \
  -framework UserNotifications -framework ServiceManagement -framework Carbon -framework PDFKit \
  NotchDrop.swift tests/main.swift -o "$OUT/notchdrop-tests"
"$OUT/notchdrop-tests"
