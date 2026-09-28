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
func fail(_ msg: String) -> Never { FileHandle.standardError.write(Data((msg + "\n").utf8)); exit(1) }
func privateKey() -> Curve25519.Signing.PrivateKey {
    let (st, b64) = run(["find-generic-password", "-a", account, "-s", service, "-w"])
    guard st == 0, let d = Data(base64Encoded: b64), let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: d)
    else { fail("No encontré la llave en el Llavero (\(service)). Ver RELEASING.md.") }
    return k
}
func publicKeyFromSource() -> String {
    let src = (try? String(contentsOfFile: "NotchDrop.swift", encoding: .utf8)) ?? ""
    guard let r = src.range(of: #"static var publicKeyBase64 = "[^"]*""#, options: .regularExpression) else { return "" }
    return String(src[r]).components(separatedBy: "\"")[1]
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "generate":
    if run(["find-generic-password", "-a", account, "-s", service]).0 == 0 { fail("Ya existe una llave; no la reemplazo.") }
    let k = Curve25519.Signing.PrivateKey()
    guard run(["add-generic-password", "-a", account, "-s", service, "-w", k.rawRepresentation.base64EncodedString()]).0 == 0
    else { fail("No pude guardar en el Llavero.") }
    print(k.publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard args.count > 1, let data = FileManager.default.contents(atPath: args[1]) else { fail("uso: sign <zip>") }
    let sig = try! privateKey().signature(for: data).base64EncodedString()
    try! (sig + "\n").write(toFile: args[1] + ".sig", atomically: true, encoding: .utf8)
    print("firmado: \(args[1]).sig")
case "verify":
    guard args.count > 1, let data = FileManager.default.contents(atPath: args[1]),
          let sig = try? String(contentsOfFile: args[1] + ".sig", encoding: .utf8),
          let keyData = Data(base64Encoded: publicKeyFromSource()),
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
          let s = Data(base64Encoded: sig.trimmingCharacters(in: .whitespacesAndNewlines)),
          key.isValidSignature(s, for: data)
    else { fail("FIRMA INVÁLIDA para la llave pública de NotchDrop.swift") }
    print("firma OK contra la llave pública de NotchDrop.swift")
default:
    fail("uso: generate | sign <zip> | verify <zip>")
}
