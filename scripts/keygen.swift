#!/usr/bin/swift
// Generates the Ed25519 keypair the auto-updater uses to verify releases.
//
// Run this ONCE, on your own Mac, then:
//   1. Paste the printed public key into NotchDrop.swift, replacing
//      AppUpdater.publicKeyBase64.
//   2. Keep update_signing_key.private somewhere safe (Keychain, a password
//      manager, an encrypted volume) and NEVER commit it or upload it
//      anywhere, including GitHub. Anyone who gets that file can sign a
//      release your users would install as if it came from you.
//
// Usage: swift scripts/keygen.swift

import CryptoKit
import Foundation

let key = Curve25519.Signing.PrivateKey()
let privB64 = key.rawRepresentation.base64EncodedString()
let pubB64 = key.publicKey.rawRepresentation.base64EncodedString()

let outPath = "update_signing_key.private"
do {
    try privB64.write(toFile: outPath, atomically: true, encoding: .utf8)
} catch {
    print("No se pudo escribir \(outPath): \(error.localizedDescription)")
    exit(1)
}

print("Clave privada guardada en ./\(outPath) — no la subas a git ni la compartas.")
print("")
print("Clave pública (pega esto en NotchDrop.swift, en AppUpdater.publicKeyBase64):")
print(pubB64)
