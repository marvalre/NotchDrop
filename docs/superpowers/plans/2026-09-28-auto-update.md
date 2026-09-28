# Actualizaciones automáticas — plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Un actualizador de un clic dentro de NotchDrop que descarga releases firmados de GitHub, los verifica y se reemplaza solo.

**Architecture:** Sección `// MARK: - Updates` en `NotchDrop.swift` con cuatro piezas: `UpdateVersion`, `UpdateSignature`, `UpdateFeed` e `UpdateInstaller`, más una tarjeta en Ajustes. Las pruebas compilan el `NotchDrop.swift` real junto a `tests/main.swift`, gracias a un `#if !NOTCHDROP_TESTS` alrededor del arranque de la app. La firma y la publicación se hacen con `scripts/update-keys.swift` y `scripts/release.sh`.

**Tech Stack:** Swift/AppKit con `swiftc` de un solo archivo, CryptoKit (Curve25519/Ed25519), URLSession, `ditto`, `codesign`, `security` (Llavero) y `gh`.

**Spec:** `docs/superpowers/specs/2026-09-28-auto-update-design.md`

## Global Constraints

- Costo cero: solo GitHub Releases, la API pública de GitHub y frameworks de macOS.
- Instalación con un clic, nunca silenciosa.
- Todo zip se verifica con Ed25519 contra la llave pública compilada en la app antes de extraerlo. Sin firma válida no se instala nada.
- La llave privada solo vive en el Llavero del autor (servicio `NotchDrop update signing key`) y nunca se imprime en logs ni entra al repo.
- Solo se aceptan URLs `https`, o `http` hacia `127.0.0.1`/`localhost` (servidor de pruebas).
- La versión anterior va a la Papelera, no se borra.
- Bundle ID esperado: `com.marcelo.notchdrop`.
- Textos visibles en español.
- Versión objetivo: 3.13.0.
- No hay que imponer cuarentena global (`LSFileQuarantineEnabled`), porque rompería la actualización sin aviso de Gatekeeper. La cuarentena de las descargas del usuario se aplica por archivo; eso es parte de las correcciones del escaneo, no de este plan.

---

### Task 1: Infraestructura de pruebas + `UpdateVersion`

**Files:**
- Modify: `NotchDrop.swift` (final del archivo: envolver el arranque; nueva sección `// MARK: - Updates` antes de él)
- Create: `tests/main.swift`, `tests/run.sh`

**Interfaces:**
- Produces: `enum UpdateVersion { static func components(_ s: String) -> [Int]?; static func isNewer(_ candidate: String, than current: String) -> Bool }` y el runner `tests/run.sh`, que compila `NotchDrop.swift` + `tests/main.swift` con `-D NOTCHDROP_TESTS`.

- [ ] **Step 1: Envolver el arranque para que el archivo compile como librería en pruebas**

Reemplazar las 5 líneas finales de `NotchDrop.swift`:

```swift
#if !NOTCHDROP_TESTS
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
#endif
```

- [ ] **Step 2: Crear el runner `tests/run.sh`**

```bash
#!/bin/bash
# Compila el NotchDrop.swift real junto a tests/main.swift y ejecuta las pruebas.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
swiftc -D NOTCHDROP_TESTS \
  -framework Cocoa -framework AVFoundation -framework CoreMedia -framework CoreAudio \
  -framework UserNotifications -framework ServiceManagement -framework Carbon -framework PDFKit \
  NotchDrop.swift tests/main.swift -o "$OUT/notchdrop-tests"
"$OUT/notchdrop-tests"
```

Después: `chmod +x tests/run.sh`.

- [ ] **Step 3: Escribir las pruebas que fallan en `tests/main.swift`**

```swift
import Foundation

var passed = 0, failed = 0
func check(_ ok: Bool, _ label: String) {
    if ok { passed += 1; print("  PASS  \(label)") } else { failed += 1; print("  FAIL  \(label)") }
}

print("UpdateVersion")
check(UpdateVersion.isNewer("3.13.0", than: "3.12.1"), "3.13.0 > 3.12.1")
check(UpdateVersion.isNewer("v3.13.0", than: "3.12.1"), "acepta 'v' inicial")
check(UpdateVersion.isNewer("3.12.10", than: "3.12.9"), "compara numéricamente, no como texto")
check(UpdateVersion.isNewer("4.0", than: "3.99.99"), "distinta longitud")
check(!UpdateVersion.isNewer("3.12.1", than: "3.12.1"), "igual no es más nueva")
check(!UpdateVersion.isNewer("3.12.0", than: "3.12.1"), "menor no es más nueva")
check(!UpdateVersion.isNewer("3.12", than: "3.12.0"), "3.12 == 3.12.0")
check(!UpdateVersion.isNewer("banana", than: "3.12.1"), "basura no es más nueva")
check(!UpdateVersion.isNewer("3..1", than: "3.0"), "componente vacío es inválido")
check(!UpdateVersion.isNewer("3.-1", than: "3.0"), "negativo es inválido")
check(UpdateVersion.components("v3.13.0") == [3, 13, 0], "components parsea")

print("\nRESULTADO: \(passed) pass / \(failed) fail")
exit(failed == 0 ? 0 : 1)
```

- [ ] **Step 4: Correr y verificar que falla**

Run: `tests/run.sh`
Expected: error de compilación `cannot find 'UpdateVersion' in scope`.

- [ ] **Step 5: Implementar `UpdateVersion`** (en la nueva sección, antes del bloque `#if`)

```swift
// MARK: - Updates

enum UpdateVersion {
    // "v3.13.0" / "3.13" → [3, 13, 0] / [3, 13]; nil for anything that isn't
    // purely non-negative integers separated by dots.
    static func components(_ s: String) -> [Int]? {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var out: [Int] = []
        for p in parts {
            guard p.allSatisfy(\.isNumber), let n = Int(p) else { return nil }
            out.append(n)
        }
        return out
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let a = components(candidate), let b = components(current) else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
```

- [ ] **Step 6: Correr y verificar que pasa**

Run: `tests/run.sh`
Expected: `RESULTADO: 11 pass / 0 fail`.

Además, verificar que la app sigue compilando: `./build.sh` debe terminar con `==> Done`.

- [ ] **Step 7: Commit**

```bash
git add NotchDrop.swift tests/main.swift tests/run.sh
git commit -m "Add test runner that compiles the real source, plus UpdateVersion"
```

---

### Task 2: `UpdateSignature` (Ed25519)

**Files:**
- Modify: `NotchDrop.swift` (sección Updates; `import CryptoKit` al inicio del archivo)
- Modify: `tests/main.swift`

**Interfaces:**
- Consumes: runner de la Task 1.
- Produces: `enum UpdateSignature { static var publicKeyBase64: String; static func verify(data: Data, signatureBase64: String, publicKeyBase64: String = UpdateSignature.publicKeyBase64) -> Bool }`.

- [ ] **Step 1: Pruebas que fallan** (agregar a `tests/main.swift` antes de la línea `RESULTADO`)

```swift
import CryptoKit

print("\nUpdateSignature")
let testKey = Curve25519.Signing.PrivateKey()
let testPub = testKey.publicKey.rawRepresentation.base64EncodedString()
let payload = Data("NotchDrop-3.13.1.zip contents".utf8)
let goodSig = try! testKey.signature(for: payload).base64EncodedString()
check(UpdateSignature.verify(data: payload, signatureBase64: goodSig, publicKeyBase64: testPub), "firma válida se acepta")
var tampered = payload; tampered[0] ^= 0xFF
check(!UpdateSignature.verify(data: tampered, signatureBase64: goodSig, publicKeyBase64: testPub), "un byte alterado se rechaza")
let otherPub = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
check(!UpdateSignature.verify(data: payload, signatureBase64: goodSig, publicKeyBase64: otherPub), "llave equivocada se rechaza")
check(!UpdateSignature.verify(data: payload, signatureBase64: "no-es-base64!!", publicKeyBase64: testPub), "firma corrupta se rechaza")
check(!UpdateSignature.verify(data: payload, signatureBase64: "", publicKeyBase64: testPub), "firma vacía se rechaza")
check(UpdateSignature.verify(data: payload, signatureBase64: goodSig + "\n", publicKeyBase64: testPub), "tolera salto de línea final del .sig")
```

(El `import CryptoKit` va al inicio de `tests/main.swift`.)

- [ ] **Step 2: Correr → falla** con `cannot find 'UpdateSignature' in scope`.

- [ ] **Step 3: Implementar**

Agregar `import CryptoKit` junto a los otros `import` del inicio de `NotchDrop.swift`. En la sección Updates:

```swift
enum UpdateSignature {
    // Public half of the release-signing key. The private half lives only in
    // the author's Keychain ("NotchDrop update signing key"); see RELEASING.md.
    static var publicKeyBase64 = ""

    static func verify(data: Data, signatureBase64: String, publicKeyBase64: String = UpdateSignature.publicKeyBase64) -> Bool {
        guard let keyData = Data(base64Encoded: publicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let sig = Data(base64Encoded: signatureBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
              !sig.isEmpty
        else { return false }
        return key.isValidSignature(sig, for: data)
    }
}
```

La llave pública real se escribe en la Task 3. Con `""`, `verify` rechaza todo, que es el comportamiento seguro por defecto.

- [ ] **Step 4: Correr → pasa.** Expected: `RESULTADO: 17 pass / 0 fail`.

- [ ] **Step 5: Commit**

```bash
git add NotchDrop.swift tests/main.swift
git commit -m "Add Ed25519 update signature verification"
```

---

### Task 3: Llave de firma, script de firma y script de release

**Files:**
- Create: `scripts/update-keys.swift`, `scripts/release.sh`, `RELEASING.md`
- Modify: `NotchDrop.swift` (valor de `publicKeyBase64`), `tests/main.swift`

**Interfaces:**
- Consumes: `UpdateSignature.verify`.
- Produces: `swift scripts/update-keys.swift generate|sign <zip>|verify <zip>`, `scripts/release.sh <versión> <notas.md>` y la llave pública real en `UpdateSignature.publicKeyBase64`.

- [ ] **Step 1: Crear `scripts/update-keys.swift`**

```swift
// Llave de firma de actualizaciones de NotchDrop.
//   swift scripts/update-keys.swift generate     crea la llave en el Llavero e imprime SOLO la pública
//   swift scripts/update-keys.swift sign X.zip   escribe X.zip.sig con la llave del Llavero
//   swift scripts/update-keys.swift verify X.zip verifica X.zip.sig contra la llave pública de NotchDrop.swift
import Foundation
import CryptoKit

let service = "NotchDrop update signing key"
let account = "NotchDrop"

func run(_ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/security"); p.arguments = args
    let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
    try! p.run(); let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (p.terminationStatus, String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}
func privateKey() -> Curve25519.Signing.PrivateKey {
    let (st, b64) = run(["find-generic-password", "-a", account, "-s", service, "-w"])
    guard st == 0, let d = Data(base64Encoded: b64), let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: d) else {
        FileHandle.standardError.write(Data("No encontré la llave en el Llavero (\(service)).\n".utf8)); exit(1)
    }
    return k
}
func publicKeyFromSource() -> String {
    let src = try! String(contentsOfFile: "NotchDrop.swift", encoding: .utf8)
    guard let r = src.range(of: #"static var publicKeyBase64 = "([^"]*)""#, options: .regularExpression) else { return "" }
    return String(src[r]).components(separatedBy: "\"")[1]
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "generate":
    if run(["find-generic-password", "-a", account, "-s", service]).0 == 0 {
        FileHandle.standardError.write(Data("Ya existe una llave; no la reemplazo.\n".utf8)); exit(1)
    }
    let k = Curve25519.Signing.PrivateKey()
    let st = run(["add-generic-password", "-a", account, "-s", service, "-w", k.rawRepresentation.base64EncodedString()]).0
    guard st == 0 else { FileHandle.standardError.write(Data("No pude guardar en el Llavero.\n".utf8)); exit(1) }
    print(k.publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard let path = args.dropFirst().first, let data = FileManager.default.contents(atPath: path) else { print("uso: sign <zip>"); exit(1) }
    let sig = try! privateKey().signature(for: data).base64EncodedString()
    try! (sig + "\n").write(toFile: path + ".sig", atomically: true, encoding: .utf8)
    print("firmado: \(path).sig")
case "verify":
    guard let path = args.dropFirst().first, let data = FileManager.default.contents(atPath: path),
          let sig = try? String(contentsOfFile: path + ".sig", encoding: .utf8),
          let key = Data(base64Encoded: publicKeyFromSource()).flatMap({ try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }),
          let s = Data(base64Encoded: sig.trimmingCharacters(in: .whitespacesAndNewlines)),
          key.isValidSignature(s, for: data)
    else { print("FIRMA INVÁLIDA para la llave pública de NotchDrop.swift"); exit(1) }
    print("firma OK contra la llave pública de NotchDrop.swift")
default:
    print("uso: generate | sign <zip> | verify <zip>"); exit(1)
}
```

- [ ] **Step 2: Generar la llave (una sola vez) y pegar la pública**

Run (desde la raíz del repo): `swift scripts/update-keys.swift generate`
Expected: imprime una sola línea base64 de 44 caracteres, que es la llave **pública**. Reemplazar `static var publicKeyBase64 = ""` por `static var publicKeyBase64 = "<esa línea>"`.

- [ ] **Step 3: Prueba que ata la llave pública con la del Llavero**

Agregar a `tests/main.swift`:

```swift
check(Data(base64Encoded: UpdateSignature.publicKeyBase64)?.count == 32, "la llave pública de producción está configurada (32 bytes)")
```

Run: `tests/run.sh` → `18 pass / 0 fail`.
Luego firmar y verificar un archivo cualquiera: `echo hola > /tmp/k.zip && swift scripts/update-keys.swift sign /tmp/k.zip && swift scripts/update-keys.swift verify /tmp/k.zip` → `firma OK`.

- [ ] **Step 4: Crear `scripts/release.sh`**

```bash
#!/bin/bash
# Publica una versión: scripts/release.sh 3.13.0 notas.md
# Antes: actualizar CHANGELOG.md y tener la llave en el Llavero (RELEASING.md).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?uso: scripts/release.sh <versión> <notas.md>}"
NOTES="${2:?uso: scripts/release.sh <versión> <notas.md>}"
[ -z "$(git status --porcelain -- NotchDrop.swift)" ] || { echo "NotchDrop.swift tiene cambios sin commit"; exit 1; }
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
git add Info.plist CHANGELOG.md
git commit -m "Release $VERSION"
git tag -a "v$VERSION" -m "NotchDrop v$VERSION"
git push origin main "v$VERSION"
gh release create "v$VERSION" "$ZIP" "$ZIP.sig" --title "NotchDrop v$VERSION" --notes-file "$NOTES"
echo "Publicado v$VERSION"
```

Después: `chmod +x scripts/release.sh`, y agregar `*.zip.sig` a `.gitignore`.

- [ ] **Step 5: Crear `RELEASING.md`**

Explicar en lenguaje llano:
- Qué es la llave.
- Dónde vive: el Llavero, servicio `NotchDrop update signing key`.
- Cómo respaldarla: `security find-generic-password -a NotchDrop -s "NotchDrop update signing key" -w`, y pegar el resultado en la app Contraseñas. Nunca en el repo ni en chats.
- Cómo restaurarla en otra Mac: `security add-generic-password -a NotchDrop -s "NotchDrop update signing key" -w <valor>`.
- Qué pasa si se pierde.
- El comando `scripts/release.sh 3.13.1 notas.md`.

- [ ] **Step 6: Commit**

```bash
git add scripts/update-keys.swift scripts/release.sh RELEASING.md .gitignore NotchDrop.swift tests/main.swift
git commit -m "Add release signing key tooling and release script"
```

---

### Task 4: `UpdateFeed` (consulta a GitHub)

**Files:** Modify `NotchDrop.swift` (sección Updates) y `tests/main.swift`.

**Interfaces:**
- Consumes: `UpdateVersion.components`.
- Produces:
  - `struct UpdateRelease: Equatable { let version: String; let zipURL: URL; let signatureURL: URL; let pageURL: URL }`
  - `enum UpdateError: Error { case http(Int), network(String), noRelease, badSignature, invalidBundle(String), notWritable, extractFailed, replaceFailed(String) }` con `var message: String`
  - `enum UpdateFeed { static let defaultURL: URL; static var url: URL; static func isAllowed(_ url: URL) -> Bool; static func parse(_ data: Data) -> UpdateRelease?; static func fetchLatest(completion: @escaping (Result<UpdateRelease, UpdateError>) -> Void) }`

- [ ] **Step 1: Pruebas que fallan** (en `tests/main.swift`)

```swift
print("\nUpdateFeed")
let feedJSON = """
{"tag_name":"v3.13.1","html_url":"https://github.com/marvalre/NotchDrop/releases/tag/v3.13.1",
 "assets":[{"name":"NotchDrop-3.13.1.zip","browser_download_url":"https://github.com/marvalre/NotchDrop/releases/download/v3.13.1/NotchDrop-3.13.1.zip"},
           {"name":"NotchDrop-3.13.1.zip.sig","browser_download_url":"https://github.com/marvalre/NotchDrop/releases/download/v3.13.1/NotchDrop-3.13.1.zip.sig"}]}
""".data(using: .utf8)!
let rel = UpdateFeed.parse(feedJSON)
check(rel?.version == "3.13.1", "parsea versión sin la 'v'")
check(rel?.zipURL.lastPathComponent == "NotchDrop-3.13.1.zip", "encuentra el zip")
check(rel?.signatureURL.lastPathComponent == "NotchDrop-3.13.1.zip.sig", "encuentra la firma")
let noSig = """
{"tag_name":"v3.13.1","html_url":"https://x","assets":[{"name":"NotchDrop-3.13.1.zip","browser_download_url":"https://x/NotchDrop-3.13.1.zip"}]}
""".data(using: .utf8)!
check(UpdateFeed.parse(noSig) == nil, "release sin .sig se ignora (versiones viejas sin firmar)")
check(UpdateFeed.parse(Data("no json".utf8)) == nil, "JSON inválido → nil")
check(UpdateFeed.isAllowed(URL(string: "https://github.com/x")!), "https permitido")
check(UpdateFeed.isAllowed(URL(string: "http://127.0.0.1:8765/x")!), "http local permitido (pruebas)")
check(!UpdateFeed.isAllowed(URL(string: "http://evil.example/x")!), "http remoto rechazado")
check(!UpdateFeed.isAllowed(URL(string: "file:///etc/passwd")!), "file:// rechazado")
```

- [ ] **Step 2: Correr → falla** por símbolos que no existen.

- [ ] **Step 3: Implementar**

```swift
struct UpdateRelease: Equatable {
    let version: String
    let zipURL: URL
    let signatureURL: URL
    let pageURL: URL
}

enum UpdateError: Error {
    case http(Int), network(String), noRelease, badSignature, invalidBundle(String), notWritable, extractFailed, replaceFailed(String)
    var message: String {
        switch self {
        case .http(let c): return "GitHub respondió con error \(c). Intenta más tarde."
        case .network(let m): return "Sin conexión: \(m)"
        case .noRelease: return "No encontré una versión publicada."
        case .badSignature: return "La actualización no pasó la verificación de seguridad y no se instaló."
        case .invalidBundle(let m): return "La actualización descargada no es válida (\(m)). No se instaló."
        case .notWritable: return "No tengo permiso para reemplazar la app en su carpeta. Descárgala a mano desde GitHub."
        case .extractFailed: return "No pude descomprimir la actualización."
        case .replaceFailed(let m): return "No pude reemplazar la app: \(m). Tu versión actual sigue intacta."
        }
    }
}

enum UpdateFeed {
    static let defaultURL = URL(string: "https://api.github.com/repos/marvalre/NotchDrop/releases/latest")!
    // Debug override for end-to-end tests against a local server. Signatures are
    // still required, so pointing it elsewhere can't install anything unsigned.
    static var url: URL {
        UserDefaults.standard.string(forKey: "NotchDropUpdateFeedURL").flatMap(URL.init(string:)) ?? defaultURL
    }

    static func isAllowed(_ url: URL) -> Bool {
        if url.scheme == "https" { return true }
        return url.scheme == "http" && ["127.0.0.1", "localhost"].contains(url.host ?? "")
    }

    static func parse(_ data: Data) -> UpdateRelease? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let assets = obj["assets"] as? [[String: Any]] else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard UpdateVersion.components(version) != nil else { return nil }
        func asset(_ name: String) -> URL? {
            assets.first { ($0["name"] as? String) == name }
                .flatMap { ($0["browser_download_url"] as? String).flatMap(URL.init(string:)) }
                .flatMap { isAllowed($0) ? $0 : nil }
        }
        guard let zip = asset("NotchDrop-\(version).zip"),
              let sig = asset("NotchDrop-\(version).zip.sig") else { return nil }
        let page = (obj["html_url"] as? String).flatMap(URL.init(string:)) ?? zip
        return UpdateRelease(version: version, zipURL: zip, signatureURL: sig, pageURL: page)
    }

    static func fetchLatest(completion: @escaping (Result<UpdateRelease, UpdateError>) -> Void) {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let result: Result<UpdateRelease, UpdateError>
            if let err { result = .failure(.network(err.localizedDescription)) }
            else if let h = resp as? HTTPURLResponse, h.statusCode != 200 { result = .failure(.http(h.statusCode)) }
            else if let rel = data.flatMap(parse) { result = .success(rel) }
            else { result = .failure(.noRelease) }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }
}
```

- [ ] **Step 4: Correr → pasa.** Expected: `27 pass / 0 fail`.
- [ ] **Step 5: Commit** — `git commit -am "Add GitHub release feed parsing for updates"`

---

### Task 5: `UpdateInstaller` + prueba de punta a punta contra un servidor local

**Files:** Modify `NotchDrop.swift` (sección Updates). Create `tests/e2e-update.sh`.

**Interfaces:**
- Consumes: `UpdateRelease`, `UpdateError`, `UpdateFeed.isAllowed`, `UpdateSignature.verify`, `runProcessBounded(_:timeout:)` (ya existe, línea ~447).
- Produces:
  - `enum UpdateInstaller { static func install(_ release: UpdateRelease, currentApp: URL, expectedBundleID: String, completion: @escaping (Result<URL, UpdateError>) -> Void) }`: todo el trabajo va en segundo plano y `completion` se llama en main con la URL de la app instalada.
  - `static func relaunch(_ app: URL)`

- [ ] **Step 1: Implementar**

```swift
enum UpdateInstaller {
    static func fetch(_ url: URL, timeout: TimeInterval = 120) throws -> Data {
        guard UpdateFeed.isAllowed(url) else { throw UpdateError.network("URL no permitida") }
        var req = URLRequest(url: url); req.timeoutInterval = timeout
        let sem = DispatchSemaphore(value: 0)
        var result: Result<Data, UpdateError> = .failure(.network("sin respuesta"))
        URLSession.shared.dataTask(with: req) { d, r, e in
            if let e { result = .failure(.network(e.localizedDescription)) }
            else if let h = r as? HTTPURLResponse, !(200..<300).contains(h.statusCode) { result = .failure(.http(h.statusCode)) }
            else { result = .success(d ?? Data()) }
            sem.signal()
        }.resume()
        sem.wait()
        return try result.get()
    }

    static func install(_ release: UpdateRelease, currentApp: URL, expectedBundleID: String,
                        completion: @escaping (Result<URL, UpdateError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try installSync(release, currentApp: currentApp, expectedBundleID: expectedBundleID) }
                .mapError { $0 as? UpdateError ?? .replaceFailed($0.localizedDescription) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    static func installSync(_ release: UpdateRelease, currentApp: URL, expectedBundleID: String) throws -> URL {
        let fm = FileManager.default
        let parent = currentApp.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: parent.path) else { throw UpdateError.notWritable }

        let zipData = try fetch(release.zipURL)
        let sig = String(decoding: try fetch(release.signatureURL, timeout: 30), as: UTF8.self)
        // Verify before anything touches the disk as an app.
        guard UpdateSignature.verify(data: zipData, signatureBase64: sig) else { throw UpdateError.badSignature }

        let work = fm.temporaryDirectory.appendingPathComponent("NotchDropUpdate-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let zipFile = work.appendingPathComponent("update.zip")
        try zipData.write(to: zipFile)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zipFile.path, work.appendingPathComponent("x").path]
        guard runProcessBounded(unzip, timeout: 60).status == 0 else { throw UpdateError.extractFailed }
        let newApp = work.appendingPathComponent("x/NotchDrop.app")

        let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == expectedBundleID else { throw UpdateError.invalidBundle("identificador distinto") }
        guard info?["CFBundleShortVersionString"] as? String == release.version else { throw UpdateError.invalidBundle("versión distinta a la publicada") }
        let cs = Process()
        cs.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        cs.arguments = ["--verify", "--deep", "--strict", newApp.path]
        guard runProcessBounded(cs, timeout: 60).status == 0 else { throw UpdateError.invalidBundle("firma de código inválida") }

        let backupName = "NotchDrop (anterior).app"
        let backup = parent.appendingPathComponent(backupName)
        if fm.fileExists(atPath: backup.path) { try? fm.trashItem(at: backup, resultingItemURL: nil) }
        let installed: URL
        do {
            installed = try fm.replaceItemAt(currentApp, withItemAt: newApp, backupItemName: backupName,
                                             options: [.withoutDeletingBackupItem]) ?? currentApp
        } catch { throw UpdateError.replaceFailed(error.localizedDescription) }
        if fm.fileExists(atPath: backup.path) { try? fm.trashItem(at: backup, resultingItemURL: nil) }
        return installed
    }

    // Waits for this process to exit, then opens the new copy. The app path is
    // passed as $0, never spliced into the script text.
    static func relaunch(_ app: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", app.path]
        try? p.run()
        NSApp.terminate(nil)
    }
}
```

- [ ] **Step 2: Escribir `tests/e2e-update.sh`**

Construye dos versiones, sirve una como release firmado desde un servidor local y ejecuta el instalador real contra una copia en una carpeta temporal. Nunca toca `/Applications`.

```bash
#!/bin/bash
# Prueba de punta a punta del instalador contra un servidor local.
set -euo pipefail
cd "$(dirname "$0")/.."
W="$(mktemp -d)"; PORT=8765
trap 'kill $SRV 2>/dev/null || true; rm -rf "$W"' EXIT
./build.sh >/dev/null
mkdir -p "$W/Applications" "$W/feed"
cp -R NotchDrop.app "$W/Applications/NotchDrop.app"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 0.0.1" "$W/Applications/NotchDrop.app/Contents/Info.plist"
codesign --force --deep -s - "$W/Applications/NotchDrop.app" >/dev/null 2>&1
V=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" NotchDrop.app/Contents/Info.plist)
ditto -c -k --sequesterRsrc --keepParent NotchDrop.app "$W/feed/NotchDrop-$V.zip"
swift scripts/update-keys.swift sign "$W/feed/NotchDrop-$V.zip" >/dev/null
cat > "$W/feed/latest.json" <<EOF
{"tag_name":"v$V","html_url":"http://127.0.0.1:$PORT/","assets":[
 {"name":"NotchDrop-$V.zip","browser_download_url":"http://127.0.0.1:$PORT/NotchDrop-$V.zip"},
 {"name":"NotchDrop-$V.zip.sig","browser_download_url":"http://127.0.0.1:$PORT/NotchDrop-$V.zip.sig"}]}
EOF
(cd "$W/feed" && python3 -m http.server $PORT >/dev/null 2>&1) & SRV=$!
sleep 1
cat > "$W/e2e.swift" <<'EOF'
let sem = DispatchSemaphore(value: 0)
let app = URL(fileURLWithPath: CommandLine.arguments[1])
let mode = CommandLine.arguments[2]
UserDefaults.standard.set("http://127.0.0.1:8765/latest.json", forKey: "NotchDropUpdateFeedURL")
UpdateFeed.fetchLatest { r in
    guard case .success(let rel) = r else { print("FAIL feed \(r)"); exit(1) }
    DispatchQueue.global().async {
        do {
            let url = try UpdateInstaller.installSync(rel, currentApp: app, expectedBundleID: "com.marcelo.notchdrop")
            let v = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
            print(mode == "good" ? "PASS instalada \(v ?? "?")" : "FAIL se instaló algo que debía rechazarse")
            exit(mode == "good" ? 0 : 1)
        } catch let e as UpdateError {
            if mode == "tampered", case .badSignature = e { print("PASS rechazada: \(e.message)"); exit(0) }
            print("FAIL \(e.message)"); exit(1)
        } catch { print("FAIL \(error)"); exit(1) }
    }
}
RunLoop.main.run()
EOF
{ echo "import Foundation"; cat "$W/e2e.swift"; } > "$W/main.swift"
swiftc -D NOTCHDROP_TESTS -framework Cocoa -framework AVFoundation -framework CoreMedia -framework CoreAudio \
  -framework UserNotifications -framework ServiceManagement -framework Carbon -framework PDFKit \
  NotchDrop.swift "$W/main.swift" -o "$W/e2e"
echo "== camino feliz =="; "$W/e2e" "$W/Applications/NotchDrop.app" good
echo "== zip alterado =="
printf 'X' | dd of="$W/feed/NotchDrop-$V.zip" bs=1 seek=100 conv=notrunc 2>/dev/null
"$W/e2e" "$W/Applications/NotchDrop.app" tampered
echo "E2E OK"
```

- [ ] **Step 3: Correr** `chmod +x tests/e2e-update.sh && tests/e2e-update.sh`
Expected: `PASS instalada <V>`, `PASS rechazada: La actualización no pasó la verificación…` y `E2E OK`.

- [ ] **Step 4: Commit** — `git add NotchDrop.swift tests/e2e-update.sh && git commit -m "Add signed update installer with local end-to-end test"`

---

### Task 6: Tarjeta en Ajustes, revisión automática, notificación y publicación de 3.13.0

**Files:** Modify `NotchDrop.swift` (propiedades del AppDelegate, `buildSettingsTab` entre la tarjeta de Ayuda y la de Acerca de, `applicationDidFinishLaunching`, delegado de notificaciones), `README.md`, `INSTALL.md`, `CHANGELOG.md`.

**Interfaces:**
- Consumes: `UpdateFeed.fetchLatest`, `UpdateVersion.isNewer`, `UpdateInstaller.install/relaunch`, `UpdateRelease`, `UpdateError.message`.
- Produces: comportamiento visible para el usuario; nada de lo que dependan otras tareas.

- [ ] **Step 1: Propiedades del AppDelegate**

```swift
var updateStatusLabel: NSTextField!
var updateActionBtn: NSButton!
var autoUpdateSwitch: NSSwitch!
var availableUpdate: UpdateRelease?
var isInstallingUpdate = false
var updateCheckTimer: Timer?
let autoUpdateDefaultsKey = "NotchDropAutoCheckUpdates"
let lastUpdateCheckDefaultsKey = "NotchDropLastUpdateCheck"
let notifiedUpdateVersionDefaultsKey = "NotchDropNotifiedUpdateVersion"
var autoUpdateEnabled: Bool {
    get { UserDefaults.standard.object(forKey: autoUpdateDefaultsKey) == nil ? true : UserDefaults.standard.bool(forKey: autoUpdateDefaultsKey) }
    set { UserDefaults.standard.set(newValue, forKey: autoUpdateDefaultsKey) }
}
var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
```

- [ ] **Step 2: Tarjeta "🔄 ACTUALIZACIONES"** en `buildSettingsTab`, antes de `// 4. About / Quit`, con el mismo patrón de `makeCardView()`:
- Título.
- `updateStatusLabel` (10 pt, `C.textMuted`, 2 líneas), con el texto inicial `"Versión \(currentVersion)"`.
- `updateActionBtn` con título "Buscar ahora" y acción `#selector(updateButtonPressed)`.
- Fila "Buscar automáticamente" con un `NSSwitch` → `#selector(toggleAutoUpdate(_:))`, con estado inicial `autoUpdateEnabled`.

- [ ] **Step 3: Lógica**

```swift
func scheduleUpdateChecks() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.maybeAutoCheckForUpdates() }
    // Hourly tick that only acts once a day — survives sleep better than a single 24 h timer.
    updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.maybeAutoCheckForUpdates() }
}

func maybeAutoCheckForUpdates() {
    guard autoUpdateEnabled, !isInstallingUpdate else { return }
    let last = UserDefaults.standard.double(forKey: lastUpdateCheckDefaultsKey)
    guard Date().timeIntervalSince1970 - last > 20 * 3600 else { return }
    checkForUpdates(userInitiated: false)
}

func checkForUpdates(userInitiated: Bool) {
    if userInitiated { updateStatusLabel?.stringValue = "Buscando…" }
    UpdateFeed.fetchLatest { [weak self] result in
        guard let self else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: self.lastUpdateCheckDefaultsKey)
        switch result {
        case .success(let rel) where UpdateVersion.isNewer(rel.version, than: self.currentVersion):
            self.availableUpdate = rel
            self.updateStatusLabel?.stringValue = "Versión \(rel.version) disponible (tienes \(self.currentVersion))"
            self.updateActionBtn?.title = "Actualizar"
            if !userInitiated, UserDefaults.standard.string(forKey: self.notifiedUpdateVersionDefaultsKey) != rel.version {
                UserDefaults.standard.set(rel.version, forKey: self.notifiedUpdateVersionDefaultsKey)
                self.postUpdateNotification(rel.version)
            }
        case .success:
            self.availableUpdate = nil
            if userInitiated { self.updateStatusLabel?.stringValue = "Tienes la última versión (\(self.currentVersion))" }
        case .failure(let e):
            if userInitiated { self.updateStatusLabel?.stringValue = e.message }
        }
    }
}

@objc func updateButtonPressed() {
    guard let rel = availableUpdate else { checkForUpdates(userInitiated: true); return }
    guard !isInstallingUpdate else { return }
    isInstallingUpdate = true
    updateActionBtn.isEnabled = false
    updateStatusLabel.stringValue = "Descargando y verificando \(rel.version)…"
    UpdateInstaller.install(rel, currentApp: Bundle.main.bundleURL, expectedBundleID: Bundle.main.bundleIdentifier ?? "com.marcelo.notchdrop") { [weak self] result in
        guard let self else { return }
        switch result {
        case .success(let app):
            self.updateStatusLabel.stringValue = "Listo. Reiniciando…"
            UpdateInstaller.relaunch(app)
        case .failure(let e):
            self.isInstallingUpdate = false
            self.updateActionBtn.isEnabled = true
            self.updateStatusLabel.stringValue = e.message
        }
    }
}

@objc func toggleAutoUpdate(_ sender: NSSwitch) { autoUpdateEnabled = sender.state == .on }

func postUpdateNotification(_ version: String) {
    let content = UNMutableNotificationContent()
    content.title = "NotchDrop \(version) disponible"
    content.body = "Abre Ajustes en el notch y pulsa Actualizar."
    let req = UNNotificationRequest(identifier: "com.marcelo.notchdrop.update", content: content, trigger: nil)
    UNUserNotificationCenter.current().add(req)
}
```

Llamar `scheduleUpdateChecks()` al final de `applicationDidFinishLaunching`. En `userNotificationCenter(_:didReceive:withCompletionHandler:)`, al inicio: si `response.notification.request.identifier == "com.marcelo.notchdrop.update"`, abrir el panel en Ajustes con `expandPanel(withHaptic: true); openSettings()`, llamar `completionHandler()` y `return`.

- [ ] **Step 4: Compilar y pruebas**

`tests/run.sh` (todo en verde), `tests/e2e-update.sh` (`E2E OK`) y `./build.sh`.

- [ ] **Step 5: Verificación en la app real, con el usuario**

1. Instalar el build en `/Applications`.
2. Servir un release local más nuevo y firmado, y hacer `defaults write com.marcelo.notchdrop NotchDropUpdateFeedURL http://127.0.0.1:8765/latest.json`.
3. Abrir la app. A los 10 s debe llegar la notificación y Ajustes debe mostrar "Versión X disponible".
4. **El usuario** pulsa Actualizar (sin clics sintéticos).
5. Verificar que queda corriendo la versión nueva y que la anterior está en la Papelera.
6. Después: `defaults delete com.marcelo.notchdrop NotchDropUpdateFeedURL` y reinstalar el build real.

- [ ] **Step 6: Documentación**

- README: nueva sección "Actualizaciones".
- INSTALL.md: nota de que a partir de 3.13.0 se actualiza sola.
- CHANGELOG 3.13.0.

- [ ] **Step 7: Publicar**

`scripts/release.sh 3.13.0 notas-3.13.0.md` y después verificar la descarga pública (versión, firma `.sig` válida con `update-keys.swift verify`).
