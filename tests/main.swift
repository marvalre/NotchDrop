import Foundation
import CryptoKit
import PDFKit
import ImageIO

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

print("AutoCollapsePolicy (⌥⌘N)")
let panelRect = NSRect(x: 500, y: 700, width: 440, height: 220)
let inside = NSPoint(x: 700, y: 800), outside = NSPoint(x: 100, y: 100)
var d = AutoCollapsePolicy.decide(pointer: outside, paddedRect: panelRect, keyboardOpened: false, hasEntered: false)
check(d.collapse, "abierto con el mouse: el mouse lejos SÍ cierra")
d = AutoCollapsePolicy.decide(pointer: outside, paddedRect: panelRect, keyboardOpened: true, hasEntered: false)
check(!d.collapse && !d.hasEntered, "abierto con ⌥⌘N: el mouse lejos NO cierra antes de entrar")
d = AutoCollapsePolicy.decide(pointer: inside, paddedRect: panelRect, keyboardOpened: true, hasEntered: false)
check(!d.collapse && d.hasEntered, "abierto con ⌥⌘N: entrar al panel lo marca como visitado")
d = AutoCollapsePolicy.decide(pointer: outside, paddedRect: panelRect, keyboardOpened: true, hasEntered: true)
check(d.collapse, "abierto con ⌥⌘N: después de haber entrado, salir SÍ cierra")
d = AutoCollapsePolicy.decide(pointer: inside, paddedRect: panelRect, keyboardOpened: false, hasEntered: false)
check(!d.collapse, "mouse dentro nunca cierra")

print("StopwatchClock")
let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
var sw = StopwatchClock()
check(sw.elapsed(at: t0) == 0 && !sw.isRunning, "arranca en cero y detenido")
sw.start(at: t0)
check(abs(sw.elapsed(at: t0.addingTimeInterval(4.51)) - 4.51) < 1e-9, "mide tiempo real aunque nadie lo consulte durante 4.5 s (el timer viejo mostraba 1.6)")
sw.start(at: t0.addingTimeInterval(2))
check(abs(sw.elapsed(at: t0.addingTimeInterval(3)) - 3) < 1e-9, "start repetido no reinicia")
sw.pause(at: t0.addingTimeInterval(5))
check(!sw.isRunning && abs(sw.elapsed(at: t0.addingTimeInterval(100)) - 5) < 1e-9, "en pausa el tiempo no avanza")
sw.pause(at: t0.addingTimeInterval(50))
check(abs(sw.elapsed(at: t0.addingTimeInterval(100)) - 5) < 1e-9, "pausar dos veces no suma")
sw.start(at: t0.addingTimeInterval(200))
check(abs(sw.elapsed(at: t0.addingTimeInterval(203)) - 8) < 1e-9, "al reanudar continúa desde lo acumulado")
sw.reset()
check(sw.elapsed(at: t0.addingTimeInterval(500)) == 0 && !sw.isRunning, "reset vuelve a cero")
check(sw.elapsed(at: t0.addingTimeInterval(-10)) == 0, "un reloj que retrocede nunca da negativo")
sw.start(at: t0); check(sw.elapsed(at: t0.addingTimeInterval(-10)) == 0, "start y reloj que retrocede → 0")
check(StopwatchClock.format(0) == "00:00.0", "formato 0")
check(StopwatchClock.format(61.5) == "01:01.5", "formato 61.5")
check(StopwatchClock.format(3599.99) == "59:59.9", "formato 59:59.9")
check(StopwatchClock.format(0.09) == "00:00.0", "décimas truncan, no redondean")

print("BridgeRestartPolicy")
check(BridgeRestartPolicy.delay(afterFailures: 1) == 2, "1er fallo: reintenta en 2 s")
check(BridgeRestartPolicy.delay(afterFailures: 2) == 10, "2do fallo: reintenta en 10 s")
check(BridgeRestartPolicy.delay(afterFailures: 3) == 60, "3er fallo: reintenta en 60 s")
check(BridgeRestartPolicy.delay(afterFailures: 4) == nil, "4to fallo seguido: se rinde")
check(BridgeRestartPolicy.delay(afterFailures: 0) == nil, "0 fallos no pide reintento")

print("\nBridge: stderr sin leer")
// A child that writes far more than a pipe buffer to stderr must not be able to
// stall the bridge: with stderr on an unread Pipe it blocks at ~64KB, alive but mute.
do {
    let perl = Process(); perl.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    perl.arguments = ["-e", "$|=1; for my $i (1..400) { print STDERR ('e' x 1024) . qq(\\n); print qq(line $i\\n); }"]
    let out = Pipe(); perl.standardOutput = out
    MediaRemoteBridge.silenceDiagnostics(perl)
    try! perl.run()
    let data = out.fileHandleForReading.readDataToEndOfFile(); perl.waitUntilExit()
    check(String(decoding: data, as: UTF8.self).split(separator: "\n").count == 400, "el hijo emite 400 líneas aunque escriba 400 KB a stderr")
}

print("MediaRemoteBridge: procesos huérfanos")
let psSample = """
  100     1 /usr/bin/perl /Applications/NotchDrop.app/Contents/Resources/MediaRemoteAdapter/run.pl /Applications/NotchDrop.app/Contents/Resources/MediaRemoteAdapter/libMediaRemoteAdapter.dylib loop
  101   555 /usr/bin/perl /Applications/NotchDrop.app/Contents/Resources/MediaRemoteAdapter/run.pl /Applications/NotchDrop.app/Contents/Resources/MediaRemoteAdapter/libMediaRemoteAdapter.dylib loop
  102     1 /usr/bin/perl /Users/x/NotchDrop.app/Contents/Resources/MediaRemoteAdapter/run.pl /Users/x/NotchDrop.app/Contents/Resources/MediaRemoteAdapter/libMediaRemoteAdapter.dylib loop
  103     1 /usr/bin/perl /tmp/otro-script.pl loop
  104     1 /usr/bin/perl /Applications/NotchDrop.app/Contents/Resources/MediaRemoteAdapter/run.pl /Applications/NotchDrop.app/Contents/Resources/MediaRemoteAdapter/libMediaRemoteAdapter.dylib get
  105     1 /Applications/Other.app/Contents/MacOS/Other
"""
let orphans = MediaRemoteBridge.orphanPIDs(inPSOutput: psSample)
check(orphans == [100, 102], "solo los perl del adaptador con padre 1 y 'loop' son huérfanos (fue \(orphans))")
check(!orphans.contains(101), "el que tiene un padre vivo NO se toca")
check(!orphans.contains(103), "otro script perl no se toca")
check(!orphans.contains(104), "una consulta puntual (get) no se toca")
check(MediaRemoteBridge.orphanPIDs(inPSOutput: "").isEmpty, "salida vacía → nada")
check(MediaRemoteBridge.orphanPIDs(inPSOutput: "basura sin números\n  x y z").isEmpty, "líneas malformadas se ignoran")

print("PDF → imágenes")
do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nd-pdf-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    func makePDF(_ name: String, pages: [(r: CGFloat, g: CGFloat, b: CGFloat)]) -> URL {
        let url = dir.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        for c in pages {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor(red: c.r, green: c.g, blue: c.b, alpha: 1)); ctx.fill(box)
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            ctx.endPDFPage()
        }
        ctx.closePDF(); return url
    }
    func convertSync(_ url: URL, _ ext: String) -> FileConverter.Outcome {
        var r: FileConverter.Outcome?
        FileConverter.convert(url, to: ext) { r = $0 }
        let end = Date().addingTimeInterval(60)
        while r == nil && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        return r ?? .failure("timeout")
    }
    // (ancho, alto, píxel RGB) de una imagen escrita a disco; (x, y) desde arriba-izquierda.
    func probe(_ url: URL, x: Int, y: Int) -> (Int, Int, [Int])? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height))
        return (img.width, img.height, [Int(px[0]), Int(px[1]), Int(px[2])])
    }
    let three = makePDF("tres.pdf", pages: [(1, 0, 0), (0, 1, 0), (0, 0, 1)])
    if case .success(let first) = convertSync(three, "png") {
        check(first.lastPathComponent == "tres-p1.png", "primera página: tres-p1.png (fue \(first.lastPathComponent))")
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".png") }.sorted()
        check(files == ["tres-p1.png", "tres-p2.png", "tres-p3.png"], "una imagen por página: \(files)")
        // El color exacto lo decide la gestión de color de macOS (el código anterior también
        // daba [255, 38, 0] para rojo puro), así que se comprueba el color DOMINANTE.
        let expected: [(String, Int)] = [("tres-p1.png", 0), ("tres-p2.png", 1), ("tres-p3.png", 2)]
        for (name, channel) in expected {
            let u = dir.appendingPathComponent(name)
            if let (w, h, rgb) = probe(u, x: 900, y: 300) {
                check(w == 2448 && h == 3168, "\(name): 4× de 612×792 = 2448×3168 (fue \(w)×\(h))")
                check(rgb[channel] >= 245 && rgb.enumerated().allSatisfy { $0.offset == channel || $0.element <= 60 },
                      "\(name): el color dominante es el del canal \(channel) (fue \(rgb))")
                // esquina inferior izquierda del PDF = negro (comprueba que no quedó de cabeza)
                if let (_, _, corner) = probe(u, x: 40, y: h - 40) { check(corner == [0, 0, 0], "\(name): el cuadro negro está abajo a la izquierda (fue \(corner))") }
                if let (_, _, top) = probe(u, x: 40, y: 40) { check(top != [0, 0, 0], "\(name): arriba a la izquierda NO es negro (fue \(top))") }
            } else { check(false, "\(name): no se pudo leer") }
        }
    } else { check(false, "PDF de 3 páginas → png falló") }
    let one = makePDF("una.pdf", pages: [(0.5, 0.5, 0.5)])
    if case .success(let f) = convertSync(one, "jpg") {
        check(f.lastPathComponent == "una.jpg", "una sola página: sin sufijo (fue \(f.lastPathComponent))")
        if let (w, h, rgb) = probe(f, x: 900, y: 300) {
            check(w == 2448 && h == 3168, "jpg: 2448×3168")
            check(rgb.allSatisfy { abs($0 - 138) <= 20 }, "jpg: gris medio (fue \(rgb))")
        } else { check(false, "jpg ilegible") }
    } else { check(false, "PDF de 1 página → jpg falló") }
    let empty = dir.appendingPathComponent("roto.pdf"); try! Data("no soy un pdf".utf8).write(to: empty)
    if case .failure = convertSync(empty, "png") { check(true, "PDF inválido falla con mensaje") } else { check(false, "PDF inválido debía fallar") }
}

print("ToolInstaller: hash y sumas")
check(ToolInstaller.sha256Hex(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "sha256 de 'abc' (vector estándar)")
let sums = """
0f192b7ec147ab6288885d6351d9ab67367640029b4377576ef46dd79cf7b202  yt-dlp_macos
aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  yt-dlp_macos.zip
bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb *yt-dlp
"""
check(ToolInstaller.parseSums(sums, file: "yt-dlp_macos") == "0f192b7ec147ab6288885d6351d9ab67367640029b4377576ef46dd79cf7b202", "SHA2-256SUMS: encuentra la línea exacta (no yt-dlp_macos.zip)")
check(ToolInstaller.parseSums(sums, file: "yt-dlp") == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "acepta el marcador binario '*' de sha256sum")
check(ToolInstaller.parseSums(sums, file: "no-existe") == nil, "archivo ausente → nil")
check(ToolInstaller.parseSums("", file: "x") == nil, "texto vacío → nil")

print("ToolInstaller: qué se descarga")
for arm in [true, false] {
    let specs = ToolInstaller.specs(arm64: arm)
    check(specs.map(\.name) == ["yt-dlp", "ffmpeg", "ffprobe"], "\(arm ? "arm64" : "x64"): yt-dlp, ffmpeg, ffprobe")
    check(specs.allSatisfy { $0.url.scheme == "https" }, "\(arm ? "arm64" : "x64"): todo por https")
    for sp in specs where sp.name != "yt-dlp" {
        check(sp.sha256?.count == 64 && sp.sha256!.allSatisfy { $0.isHexDigit }, "\(arm ? "arm64" : "x64") \(sp.name): hash fijo de 64 hex")
        check(sp.url.absoluteString.contains(arm ? "darwin-arm64" : "darwin-x64"), "\(arm ? "arm64" : "x64") \(sp.name): arquitectura correcta en la URL")
    }
    check(specs[0].sha256 == nil && specs[0].sumsURL != nil && specs[0].sumsEntry == "yt-dlp_macos", "yt-dlp: hash tomado del SHA2-256SUMS del release")
}
check(ToolInstaller.specs(arm64: true)[1].sha256 != ToolInstaller.specs(arm64: false)[1].sha256, "hashes distintos por arquitectura")

print("ToolLocator")
do {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("nd-loc-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: d) }
    let exe = d.appendingPathComponent("herramienta-de-prueba")
    check(ToolLocator.find("herramienta-de-prueba", extraDirectories: [d]) == nil, "no existe → nil")
    try! "#!/bin/sh\necho hola\n".write(to: exe, atomically: true, encoding: .utf8)
    check(ToolLocator.find("herramienta-de-prueba", extraDirectories: [d]) == nil, "existe pero sin permiso de ejecución → nil")
    try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
    check(ToolLocator.find("herramienta-de-prueba", extraDirectories: [d])?.path == exe.path, "ejecutable en la carpeta propia → lo encuentra")
    check(ToolLocator.find("herramienta-de-prueba", extraDirectories: []) == nil, "sin esa carpeta → nil")
}

print("MediaDownloader: clasificación de errores reales")
let safariErr = "ERROR: [Errno 1] Operation not permitted: '/Users/juank/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies'"
check(MediaDownloader.classify(safariErr) == .safariCookiesBlocked, "Safari sin Acceso total al disco (error real reproducido) → safariCookiesBlocked")
check(MediaDownloader.classify("ERROR: Postprocessing: ffprobe and ffmpeg not found. Please install or provide the path using --ffmpeg-location") == .missingConversionTools, "ffmpeg ausente (el de la captura de tu amigo)")
check(MediaDownloader.classify("ERROR: [youtube] x: Sign in to confirm you're not a bot. Use --cookies-from-browser or --cookies for the authentication.") == .loginRequired, "YouTube pide sesión → loginRequired")
check(MediaDownloader.classify("ERROR: [Instagram] x: Requested content is not available, rate-limit reached or login required") == .loginRequired, "Instagram login")
check(MediaDownloader.classify("ERROR: Unable to extract universal data for rehydration") == .tiktokBlocked, "TikTok anti-bot")
check(MediaDownloader.classify("ERROR: Unsupported URL: https://x.com") == .unsupported, "sitio no soportado")
check(MediaDownloader.classify("ERROR: Operation not permitted: '/Users/x/Downloads/a.mp4'") == .other, "'Operation not permitted' en otra ruta NO es de cookies de Safari")
let imgURL = URL(string: "https://cdn.example.com/a/foto.jpg")!
check(MediaDownloader.directDownloadVerdict(url: imgURL, status: 200, mimeType: "image/jpeg") == .accept(filename: "foto.jpg"), "imagen directa 200 image/jpeg → acepta")
check({ if case .reject = MediaDownloader.directDownloadVerdict(url: imgURL, status: 404, mimeType: "image/jpeg") { return true }; return false }(), "imagen directa 404 → rechaza (antes guardaba la página de error)")
check({ if case .reject = MediaDownloader.directDownloadVerdict(url: imgURL, status: 200, mimeType: "text/html; charset=utf-8") { return true }; return false }(), "imagen directa que devuelve HTML → rechaza")
check(MediaDownloader.directDownloadVerdict(url: imgURL, status: 200, mimeType: "application/octet-stream") == .accept(filename: "foto.jpg"), "CDN con octet-stream y extensión de imagen en la URL → acepta")
check({ if case .reject = MediaDownloader.directDownloadVerdict(url: URL(string: "https://x.com/run.png")!, status: 200, mimeType: "application/x-msdownload") { return true }; return false }(), "ejecutable disfrazado de .png → rechaza")
check(MediaDownloader.directDownloadVerdict(url: URL(string: "https://x.com/img")!, status: 200, mimeType: "image/webp") == .accept(filename: "img.webp"), "sin extensión en la URL → extensión sale del MIME")
check(MediaDownloader.directDownloadVerdict(url: URL(string: "https://x.com/.hidden.png")!, status: 200, mimeType: "image/png") == .accept(filename: "hidden.png"), "nombre sin punto inicial (no crea archivos ocultos)")
check(!MediaDownloader.friendlyError(from: safariErr).contains("prueba activar cookies"), "el mensaje de Safari ya NO dice 'activa cookies' (ya estaban activadas)")
check(MediaDownloader.friendlyError(from: safariErr).contains("Acceso total al disco"), "el mensaje de Safari explica el permiso real")

print("Descarga MP4: compatibilidad")
let mp4Args = MediaDownloader.Format.videoMP4.arguments
check(mp4Args.starts(with: ["-S", "vcodec:h264,res,acodec:m4a"]), "MP4 prefiere H.264 (el selector anterior elegía AV1 a 4K)")
check(mp4Args.contains("--merge-output-format") && mp4Args.contains("mp4"), "sigue uniendo en .mp4")
check(MediaDownloader.Format.audioMP3.arguments.contains("mp3"), "MP3 sin cambios")

print("NotesFormatter")
check(NotesFormatter.html(from: "hola") == "<div>hola</div>", "una línea → un <div>")
check(NotesFormatter.html(from: "a\nb") == "<div>a</div><div>b</div>", "salto de línea se conserva")
check(NotesFormatter.html(from: "a\n\nb") == "<div>a</div><div><br></div><div>b</div>", "línea vacía se conserva")
check(NotesFormatter.html(from: "<b>x</b> & R&D a < b") == "<div>&lt;b&gt;x&lt;/b&gt; &amp; R&amp;D a &lt; b</div>", "HTML y & se escapan (antes se interpretaban)")
check(NotesFormatter.html(from: "a\r\nb") == "<div>a</div><div>b</div>", "CRLF normalizado")

print("AlarmPolicy")
let alarmNow = Date(timeIntervalSince1970: 1_000_000)
check(AlarmPolicy.decide(end: alarmNow.addingTimeInterval(30), now: alarmNow) == .pending(remaining: 30), "alarma futura → pendiente")
check(AlarmPolicy.decide(end: alarmNow.addingTimeInterval(-5), now: alarmNow) == .ring, "5 s de retraso → suena")
check(AlarmPolicy.decide(end: alarmNow.addingTimeInterval(-120), now: alarmNow) == .ring, "justo en el límite de gracia → suena")
check(AlarmPolicy.decide(end: alarmNow.addingTimeInterval(-121), now: alarmNow) == .missed(lateBy: 121), "121 s tarde → perdida")
check(AlarmPolicy.decide(end: alarmNow.addingTimeInterval(-8 * 3600), now: alarmNow) == .missed(lateBy: 8 * 3600), "Mac dormida 8 h → perdida, no suena")

print("FallbackPollPolicy")
check(!FallbackPollPolicy.shouldPollNetflix(chromeRunning: true, audible: false, usingFallback: false), "Chrome abierto y en silencio → no lanza osascript")
check(FallbackPollPolicy.shouldPollNetflix(chromeRunning: true, audible: true, usingFallback: false), "hay audio → sí busca Netflix")
check(FallbackPollPolicy.shouldPollNetflix(chromeRunning: true, audible: false, usingFallback: true), "Netflix mostrándose y se silencia → consulta para limpiarlo")
check(!FallbackPollPolicy.shouldPollNetflix(chromeRunning: false, audible: true, usingFallback: false), "Chrome cerrado → no")

print("NotchGeometry")
let scr = NSRect(x: 0, y: 0, width: 1512, height: 982)
let coll = NSRect(x: 656, y: 950, width: 200, height: 32)
check(NotchGeometry.hoverTriggers(pointer: NSPoint(x: 756, y: 982), screenFrame: scr, collapsedRect: coll, notchWidth: 180), "fila superior de píxeles (y == maxY) abre el panel")
check(!NotchGeometry.hoverTriggers(pointer: NSPoint(x: 756, y: 1100), screenFrame: scr, collapsedRect: coll, notchWidth: 180), "monitor apilado arriba no abre el panel")
check(!NotchGeometry.hoverTriggers(pointer: NSPoint(x: 300, y: 970), screenFrame: scr, collapsedRect: coll, notchWidth: 180), "fuera del ancho del notch no abre")
check(NotchGeometry.dragTriggers(pointer: NSPoint(x: 700, y: 940), screenFrame: scr, collapsedRect: coll, notchWidth: 180), "arrastre cerca del notch despierta el Shelf")
check(!NotchGeometry.dragTriggers(pointer: NSPoint(x: 700, y: 1400), screenFrame: scr, collapsedRect: coll, notchWidth: 180), "arrastre en otro monitor encima → no")
check(!NotchGeometry.dragTriggers(pointer: NSPoint(x: 700, y: 500), screenFrame: scr, collapsedRect: coll, notchWidth: 180), "arrastre lejos, abajo → no")

print("PlaybackTime")
check(PlaybackTime.clock(65) == "1:05", "65 s → 1:05")
check(PlaybackTime.clock(.infinity) == "0:00", "duración infinita (stream en vivo) no revienta")
check(PlaybackTime.clock(-.infinity) == "0:00" && PlaybackTime.clock(.nan) == "0:00" && PlaybackTime.clock(-3) == "0:00", "NaN y negativos → 0:00")
check(PlaybackTime.clock(1e300) == "5999:59", "valor gigante se limita en vez de crashear")

print("\nRESULTADO: \(passed) pass / \(failed) fail")
exit(failed == 0 ? 0 : 1)
