#!/usr/bin/swift
// Signs a release .zip for the auto-updater with the Ed25519 private key
// from scripts/keygen.swift, producing a <file>.sig containing the
// base64-encoded signature. Upload both the .zip and the .sig as assets on
// the same GitHub Release (the app looks for "<name>.zip" + "<name>.zip.sig").
//
// Usage: swift scripts/sign_release.swift NotchDrop-3.13.0.zip update_signing_key.private

import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else {
    print("Uso: swift scripts/sign_release.swift <archivo.zip> <update_signing_key.private>")
    exit(1)
}

let fileURL = URL(fileURLWithPath: args[1])
let keyPath = args[2]

guard let privB64 = try? String(contentsOfFile: keyPath, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
      let privData = Data(base64Encoded: privB64),
      let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: privData) else {
    print("No se pudo leer la clave privada en \(keyPath).")
    exit(1)
}

guard let fileData = try? Data(contentsOf: fileURL) else {
    print("No se pudo leer \(fileURL.path).")
    exit(1)
}

guard let signature = try? privateKey.signature(for: fileData) else {
    print("Falló la firma.")
    exit(1)
}

let sigPath = fileURL.path + ".sig"
do {
    try signature.base64EncodedString().write(toFile: sigPath, atomically: true, encoding: .utf8)
    print("Firmado: \(sigPath)")
} catch {
    print("No se pudo escribir \(sigPath): \(error.localizedDescription)")
    exit(1)
}
