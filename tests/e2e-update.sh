#!/bin/bash
# Prueba de punta a punta del instalador contra un servidor local. Nunca toca /Applications.
# Escenarios: (1) camino feliz, (2) zip alterado, (3) zip firmado pero con otra versión
# de la que declara el release, (4) carpeta sin permiso de escritura.
# En (2)-(4) la app instalada debe quedar EXACTAMENTE como estaba.
set -euo pipefail
cd "$(dirname "$0")/.."
W="$(mktemp -d)"
# Puerto libre en cada corrida: un servidor viejo en un puerto fijo contestaba 404 desde otra carpeta.
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
trap 'kill $SRV 2>/dev/null || true; chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"' EXIT
./build.sh >/dev/null
V=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" NotchDrop.app/Contents/Info.plist)
mkdir -p "$W/feed"
ditto -c -k --sequesterRsrc --keepParent NotchDrop.app "$W/feed/NotchDrop-$V.zip"
swift scripts/update-keys.swift sign "$W/feed/NotchDrop-$V.zip" >/dev/null
cp "$W/feed/NotchDrop-$V.zip" "$W/feed/NotchDrop-99.0.0.zip"; cp "$W/feed/NotchDrop-$V.zip.sig" "$W/feed/NotchDrop-99.0.0.zip.sig"
feed() { # $1 = archivo, $2 = versión que declara el release
  cat > "$W/feed/$1" <<JSON
{"tag_name":"v$2","html_url":"http://127.0.0.1:$PORT/","draft":false,"prerelease":false,"assets":[
 {"name":"NotchDrop-$2.zip","browser_download_url":"http://127.0.0.1:$PORT/NotchDrop-$2.zip"},
 {"name":"NotchDrop-$2.zip.sig","browser_download_url":"http://127.0.0.1:$PORT/NotchDrop-$2.zip.sig"}]}
JSON
}
feed good.json "$V"; feed wrongversion.json 99.0.0
(cd "$W/feed" && python3 -m http.server $PORT >/dev/null 2>&1) & SRV=$!
sleep 1

cat > "$W/main.swift" <<'SWIFT'
import Foundation
let app = URL(fileURLWithPath: CommandLine.arguments[1])
let feed = CommandLine.arguments[2]
let expect = CommandLine.arguments[3]   // ok | badSignature | invalidBundle | notWritable
// arguments[4] = port
UserDefaults.standard.set("http://127.0.0.1:\(CommandLine.arguments[4])/\(feed)", forKey: "NotchDropUpdateFeedURL")
// fetchLatest answers on the main queue, which a blocking script would starve,
// so read the feed with the synchronous fetch and the same parser it uses.
let feedData: Data
do { feedData = try UpdateInstaller.fetch(UpdateFeed.url, timeout: 15) }
catch { print("FAIL no pude descargar el feed \(UpdateFeed.url): \(error)"); exit(1) }
guard let rel = UpdateFeed.parse(feedData) else { print("FAIL el feed no se pudo interpretar: \(String(decoding: feedData, as: UTF8.self))"); exit(1) }
do {
    _ = try UpdateInstaller.installSync(rel, currentApp: app, expectedBundleID: "com.marcelo.notchdrop")
    print(expect == "ok" ? "PASS instalada" : "FAIL se instaló algo que debía rechazarse"); exit(expect == "ok" ? 0 : 1)
} catch let e as UpdateError {
    let name: String
    switch e { case .badSignature: name = "badSignature"; case .invalidBundle: name = "invalidBundle"; case .notWritable: name = "notWritable"; default: name = "otro: \(e.message)" }
    print(name == expect ? "PASS rechazada (\(name)): \(e.message)" : "FAIL error inesperado \(name)"); exit(name == expect ? 0 : 1)
} catch { print("FAIL \(error)"); exit(1) }
SWIFT
swiftc -D NOTCHDROP_TESTS -framework Cocoa -framework AVFoundation -framework CoreMedia -framework CoreAudio \
  -framework UserNotifications -framework ServiceManagement -framework Carbon -framework PDFKit \
  NotchDrop.swift "$W/main.swift" -o "$W/e2e"

fresh() { rm -rf "$W/Applications"; mkdir -p "$W/Applications"; cp -R NotchDrop.app "$W/Applications/NotchDrop.app"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 0.0.1" "$W/Applications/NotchDrop.app/Contents/Info.plist"
  codesign --force --deep -s - "$W/Applications/NotchDrop.app" >/dev/null 2>&1; }
ver() { /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$W/Applications/NotchDrop.app/Contents/Info.plist"; }
hash() { find "$W/Applications/NotchDrop.app" -type f -exec shasum {} \; | sort | shasum | cut -c1-12; }

echo "== 1. camino feliz =="; fresh; "$W/e2e" "$W/Applications/NotchDrop.app" good.json ok $PORT
[ "$(ver)" = "$V" ] || { echo "FAIL versión instalada $(ver), esperaba $V"; exit 1; }
codesign --verify --deep --strict "$W/Applications/NotchDrop.app" && echo "   app instalada válida, versión $V"

echo "== 2. zip alterado =="; fresh; H=$(hash)
cp "$W/feed/NotchDrop-$V.zip" "$W/feed/orig.zip"
printf 'X' | dd of="$W/feed/NotchDrop-$V.zip" bs=1 seek=100 conv=notrunc 2>/dev/null
"$W/e2e" "$W/Applications/NotchDrop.app" good.json badSignature $PORT
cp "$W/feed/orig.zip" "$W/feed/NotchDrop-$V.zip"
[ "$(hash)" = "$H" ] || { echo "FAIL la app instalada cambió"; exit 1; }; echo "   app intacta"

echo "== 3. firmado pero con otra versión que el release =="; fresh; H=$(hash)
"$W/e2e" "$W/Applications/NotchDrop.app" wrongversion.json invalidBundle $PORT
[ "$(hash)" = "$H" ] || { echo "FAIL la app instalada cambió"; exit 1; }; echo "   app intacta"

echo "== 4. carpeta sin permiso de escritura =="; fresh; H=$(hash); chmod a-w "$W/Applications"
"$W/e2e" "$W/Applications/NotchDrop.app" good.json notWritable $PORT
chmod u+w "$W/Applications"; [ "$(hash)" = "$H" ] || { echo "FAIL la app instalada cambió"; exit 1; }; echo "   app intacta"
echo "E2E OK"
