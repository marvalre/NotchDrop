#!/bin/bash
# Prueba de punta a punta del instalador de herramientas contra un servidor local, con
# herramientas falsas (scripts). Nunca toca ~/Library/Application Support.
# (1) camino feliz con .gz y sin .gz  (2) hash alterado → rechaza y no instala nada
# (3) binario que no corre → rechaza  (4) una herramienta ya instalada NO se pierde si la nueva falla
set -euo pipefail
cd "$(dirname "$0")/.."
W="$(mktemp -d)"
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
trap 'kill $SRV 2>/dev/null || true; rm -rf "$W"' EXIT
mkdir -p "$W/feed" "$W/bin"
printf '#!/bin/sh\necho "fake-tool 1.0"\n' > "$W/feed/good"
printf '#!/bin/sh\necho "fake-tool 2.0"\n' > "$W/feed/good2"
printf 'esto no es un ejecutable' > "$W/feed/broken"
gzip -c "$W/feed/good" > "$W/feed/good.gz"
(cd "$W/feed" && python3 -m http.server $PORT >/dev/null 2>&1) & SRV=$!
sleep 1
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
echo "$(sha "$W/feed/good")  fake_raw" > "$W/feed/SUMS"
cat > "$W/main.swift" <<SWIFT
import Foundation
let dir = URL(fileURLWithPath: "$W/bin")
let base = "http://127.0.0.1:$PORT"
func spec(_ name: String, _ file: String, sha: String?, gz: Bool = false, sums: Bool = false) -> ToolSpec {
    ToolSpec(name: name, url: URL(string: "\\(base)/\\(file)")!, sha256: sha,
             sumsURL: sums ? URL(string: "\\(base)/SUMS") : nil, sumsEntry: sums ? "fake_raw" : nil, gunzip: gz, versionArgs: ["--version"])
}
func run(_ label: String, _ specs: [ToolSpec], expectFail: Bool) {
    do { try ToolInstaller.installSync(specs, into: dir); print(expectFail ? "FAIL \\(label): debía rechazarse" : "PASS \\(label)"); if expectFail { exit(1) } }
    catch let e as ToolInstallError { print(expectFail ? "PASS \\(label) → \\(e.message)" : "FAIL \\(label): \\(e.message)"); if !expectFail { exit(1) } }
    catch { print("FAIL \\(label): \\(error)"); exit(1) }
}
func output(_ name: String) -> String {
    let p = Process(); p.executableURL = dir.appendingPathComponent(name); p.arguments = []
    let o = Pipe(); p.standardOutput = o; try? p.run(); p.waitUntilExit()
    return String(decoding: o.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}
let goodSha = CommandLine.arguments[1], goodGzSha = CommandLine.arguments[2], good2Sha = CommandLine.arguments[3], brokenSha = CommandLine.arguments[4]
run("1a. herramienta plana con hash fijo", [spec("plana", "good", sha: goodSha)], expectFail: false)
run("1b. herramienta .gz con hash fijo", [spec("comprimida", "good.gz", sha: goodGzSha, gz: true)], expectFail: false)
run("1c. hash tomado del archivo de sumas", [spec("consumas", "good", sha: nil, sums: true)], expectFail: false)
guard output("plana") == "fake-tool 1.0" else { print("FAIL la herramienta instalada no se ejecuta bien"); exit(1) }
run("2. hash incorrecto", [spec("alterada", "good", sha: String(repeating: "0", count: 64))], expectFail: true)
guard !FileManager.default.fileExists(atPath: dir.appendingPathComponent("alterada").path) else { print("FAIL se instaló algo con hash malo"); exit(1) }
run("3. binario que no corre (hash correcto)", [spec("rota", "broken", sha: brokenSha)], expectFail: true)
guard !FileManager.default.fileExists(atPath: dir.appendingPathComponent("rota").path) else { print("FAIL se instaló un binario roto"); exit(1) }
run("4a. actualizar con una versión buena", [spec("plana", "good2", sha: good2Sha)], expectFail: false)
guard output("plana") == "fake-tool 2.0" else { print("FAIL no actualizó"); exit(1) }
run("4b. una actualización mala NO rompe la instalada", [spec("plana", "good", sha: String(repeating: "f", count: 64))], expectFail: true)
guard output("plana") == "fake-tool 2.0" else { print("FAIL la versión buena se perdió"); exit(1) }
let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { \$0.hasPrefix(".") }
guard leftovers.isEmpty else { print("FAIL quedaron archivos temporales: \\(leftovers)"); exit(1) }
print("PASS sin archivos temporales")
SWIFT
swiftc -D NOTCHDROP_TESTS -framework Cocoa -framework AVFoundation -framework CoreMedia -framework CoreAudio \
  -framework UserNotifications -framework ServiceManagement -framework Carbon -framework PDFKit \
  NotchDrop.swift "$W/main.swift" -o "$W/e2e" 2>&1 | grep error || true
"$W/e2e" "$(sha "$W/feed/good")" "$(sha "$W/feed/good.gz")" "$(sha "$W/feed/good2")" "$(sha "$W/feed/broken")"
echo "E2E TOOLS OK"
