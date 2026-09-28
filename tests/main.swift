import Foundation
import CryptoKit

var passed = 0, failed = 0
func check(_ ok: Bool, _ label: String) {
    if ok { passed += 1 } else { failed += 1; print("  FAIL  \(label)") }
}

let app = AppDelegate()
func calc(_ input: String, _ want: Double?, _ label: String? = nil) {
    let got = app.evaluateArithmetic(input)
    let ok = (got == nil && want == nil) || (got != nil && want != nil && abs(got! - want!) < 1e-6)
    check(ok, "\(label ?? "calc") \"\(input)\" -> \(got.map { String($0) } ?? "nil"), want \(want.map { String($0) } ?? "nil")")
}

// ── Currency calculator ─────────────────────────────────────────────────────
print("Calculadora de Currency")
calc("1", 1); calc("25.5", 25.5); calc("25,5", 25.5); calc("  42  ", 42); calc("0", 0)
calc("25*4", 100); calc("1200/3", 400); calc("10+5", 15); calc("10-5", 5)
calc("2+3*4", 14); calc("(2+3)*4", 20); calc("100/4+1", 26); calc("1.5*2", 3); calc("1,5*2", 3)
calc("19.99*3", 59.97); calc("1500+250", 1750); calc("(1200+800)/2", 1000); calc("50*1.16", 58)
for bad in ["", "   ", "abc", "5++", "*5", "5*", "(5+3", "5+3)", "()", "5..3", "FUNCTION(1)", "$(whoami)", "5/0", "1e999"] {
    calc(bad, nil, "inválido")
}
calc("-5", -5); calc("-5+10", 5); calc("10*-2", -20)

print("Separadores de miles y decimales")
calc("1,000", 1000, "miles"); calc("12,345", 12345, "miles"); calc("1,000,000", 1_000_000, "miles")
calc("1,000.50", 1000.5, "miles+decimal"); calc("1.000,50", 1000.5, "miles+decimal es")
calc("1,5", 1.5, "decimal coma"); calc("0,25", 0.25, "decimal coma")
calc("1,000+2,5", 1002.5, "dos números distintos"); calc("2,5*1,000", 2500, "dos números distintos")
calc("1,5+1,5", 3, "regresión: cada número por separado"); calc("1,000+1,000", 2000)
calc("2,500*2", 5000, "miles en operación"); calc("(1,000+500)/3", 500, "miles con paréntesis")
calc("1,0000", 1, "cuatro decimales con coma"); calc("0,500", 0.5, "0,500 es decimal, no miles"); calc("1,00,000", nil, "agrupación irregular")

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
check(!UpdateVersion.isNewer("3.13.0-beta", than: "3.12.1"), "prerelease con sufijo se ignora")
check(UpdateVersion.components("v3.13.0") == [3, 13, 0], "components parsea")

print("UpdateSignature")
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
check(!UpdateSignature.verify(data: payload, signatureBase64: goodSig, publicKeyBase64: ""), "sin llave pública configurada rechaza todo")
check(UpdateSignature.verify(data: payload, signatureBase64: goodSig + "\n", publicKeyBase64: testPub), "tolera salto de línea final del .sig")

check(Data(base64Encoded: UpdateSignature.publicKeyBase64)?.count == 32, "la llave pública de producción está configurada (32 bytes)")

print("UpdateFeed")
let feedJSON = """
{"tag_name":"v3.13.1","html_url":"https://github.com/marvalre/NotchDrop/releases/tag/v3.13.1","draft":false,"prerelease":false,
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
let prerelease = String(decoding: feedJSON, as: UTF8.self).replacingOccurrences(of: "\"prerelease\":false", with: "\"prerelease\":true")
check(UpdateFeed.parse(Data(prerelease.utf8)) == nil, "prerelease se ignora")
let draft = String(decoding: feedJSON, as: UTF8.self).replacingOccurrences(of: "\"draft\":false", with: "\"draft\":true")
check(UpdateFeed.parse(Data(draft.utf8)) == nil, "borrador se ignora")
check(UpdateFeed.parse(Data("no json".utf8)) == nil, "JSON inválido → nil")
check(UpdateFeed.isAllowed(URL(string: "https://github.com/x")!), "https permitido")
check(UpdateFeed.isAllowed(URL(string: "http://127.0.0.1:8765/x")!), "http local permitido (pruebas)")
check(!UpdateFeed.isAllowed(URL(string: "http://evil.example/x")!), "http remoto rechazado")
check(!UpdateFeed.isAllowed(URL(string: "file:///etc/passwd")!), "file:// rechazado")

// ── Compresión con ffmpeg real ────────────────────────────────────────────
print("Compresión: contenedor y códec")
check(FileConverter.compressionOutputExtension(forSource: "mp3", isVideo: false) == "mp3", "mp3 → mp3")
check(FileConverter.compressionOutputExtension(forSource: "m4a", isVideo: false) == "m4a", "m4a → m4a")
check(FileConverter.compressionOutputExtension(forSource: "opus", isVideo: false) == "opus", "opus → opus")
for lossless in ["wav", "flac", "aiff", "aif", "ogg", "wma"] {
    check(FileConverter.compressionOutputExtension(forSource: lossless, isVideo: false) == "m4a", "\(lossless) → m4a")
}
for keep in ["mp4", "mov", "m4v", "mkv"] { check(FileConverter.compressionOutputExtension(forSource: keep, isVideo: true) == keep, "video \(keep) se conserva") }
for change in ["webm", "avi", "flv", "wmv", "mpg", "mpeg"] { check(FileConverter.compressionOutputExtension(forSource: change, isVideo: true) == "mp4", "video \(change) → mp4") }

if let ffmpeg = FileConverter.ffmpegPath() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nd-compress-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    func sh(_ exe: URL, _ args: [String]) -> String {
        let p = Process(); p.executableURL = exe; p.arguments = args
        let o = Pipe(); p.standardOutput = o; p.standardError = FileHandle.nullDevice
        try! p.run(); let d = o.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let ffprobe = URL(fileURLWithPath: ffmpeg.path.replacingOccurrences(of: "ffmpeg", with: "ffprobe"))
    func codec(_ url: URL, _ stream: String) -> String {
        sh(ffprobe, ["-v", "error", "-select_streams", stream, "-show_entries", "stream=codec_name", "-of", "csv=p=0", url.path])
    }
    func make(_ name: String, _ inputs: [String], _ codecArgs: [String]) -> URL {
        let out = dir.appendingPathComponent(name)
        _ = sh(ffmpeg, ["-y", "-v", "error"] + inputs + codecArgs + [out.path])
        return out
    }
    func compressSync(_ url: URL, _ percent: Int) -> FileConverter.Outcome {
        var result: FileConverter.Outcome?
        FileConverter.compress(url, targetPercent: percent) { result = $0 }
        let deadline = Date().addingTimeInterval(180)
        while result == nil && Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        return result ?? .failure("timeout")
    }
    let noise = ["-f", "lavfi", "-i", "anoisesrc=d=8:c=pink:r=44100"]
    // (archivo, códec de audio esperado en la salida, extensión esperada)
    let audioCases: [(String, [String], String, String)] = [
        ("a.mp3", ["-c:a", "libmp3lame", "-b:a", "192k"], "mp3", "mp3"),
        ("a.m4a", ["-c:a", "aac", "-b:a", "192k"], "aac", "m4a"),
        ("a.wav", ["-c:a", "pcm_s16le"], "aac", "m4a"),
        ("a.flac", ["-c:a", "flac"], "aac", "m4a"),
        ("a.aiff", ["-c:a", "pcm_s16be"], "aac", "m4a"),
        ("a.opus", ["-c:a", "libopus", "-b:a", "128k"], "opus", "opus"),
    ]
    for (name, enc, wantCodec, wantExt) in audioCases {
        let src = make(name, noise, enc)
        guard FileManager.default.fileExists(atPath: src.path) else { print("  (omitido \(name): este ffmpeg no puede generarlo)"); continue }
        switch compressSync(src, 50) {
        case .success(let out):
            check(out.pathExtension == wantExt, "\(name): salida .\(wantExt) (fue .\(out.pathExtension))")
            check(codec(out, "a:0") == wantCodec, "\(name): códec \(wantCodec) (fue \(codec(out, "a:0")))")
            check(FileConverter.fileSize(of: out) < FileConverter.fileSize(of: src), "\(name): pesa menos que el original")
        case .failure(let m): check(false, "\(name): debía comprimir pero falló: \(m)")
        case .missingFFmpeg: check(false, "\(name): ffmpeg no encontrado")
        }
    }
    let videoSrc = ["-f", "lavfi", "-i", "testsrc2=size=320x240:rate=25:duration=5", "-f", "lavfi", "-i", "anoisesrc=d=5:c=pink:r=44100"]
    let videoCases: [(String, [String], String)] = [
        ("v.mp4", ["-c:v", "libx264", "-b:v", "1500k", "-c:a", "aac"], "mp4"),
        ("v.mkv", ["-c:v", "libx264", "-b:v", "1500k", "-c:a", "aac"], "mkv"),
        ("v.webm", ["-c:v", "libvpx-vp9", "-b:v", "1500k", "-c:a", "libopus"], "mp4"),
    ]
    for (name, enc, wantExt) in videoCases {
        let src = make(name, videoSrc, enc)
        guard FileManager.default.fileExists(atPath: src.path) else { print("  (omitido \(name))"); continue }
        switch compressSync(src, 50) {
        case .success(let out):
            check(out.pathExtension == wantExt, "\(name): salida .\(wantExt) (fue .\(out.pathExtension))")
            check(codec(out, "v:0") == "h264", "\(name): video h264 (fue \(codec(out, "v:0")))")
        case .failure(let m): check(false, "\(name): debía comprimir pero falló: \(m)")
        case .missingFFmpeg: check(false, "\(name): ffmpeg no encontrado")
        }
    }
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    let leftovers = names.filter { FileConverter.fileSize(of: dir.appendingPathComponent($0)) == 0 }
    check(leftovers.isEmpty, "no quedan archivos vacíos tras comprimir (\(leftovers))")
} else { print("  (ffmpeg no instalado: se omiten las pruebas de compresión real)") }

print("\nRESULTADO: \(passed) pass / \(failed) fail")
exit(failed == 0 ? 0 : 1)
