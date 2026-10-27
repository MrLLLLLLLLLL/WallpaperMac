#!/usr/bin/env swift
import CryptoKit
import Foundation

// Standalone signing tool for update artifacts. Uses the same Ed25519 wire
// format as UpdateSignature so release output verifies in-app without any
// third-party binary.
//
//   swift scripts/update-signing-tool.swift generate [privateKeyPath]
//   swift scripts/update-signing-tool.swift sign <artifact> <privateKeyPath>
//   swift scripts/update-signing-tool.swift verify <artifact> <sigPath> <publicKeyPath>

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("ERROR: \(message)\n".utf8))
    exit(1)
}

func readLines(_ path: String) -> String {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("cannot read \(path)")
    }
    return text
}


func sha256Digest(at path: String) throws -> Data {
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
        let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
        if chunk.isEmpty { break }
        hasher.update(data: chunk)
    }
    return Data(hasher.finalize())
}

func firstDataLine(_ text: String) -> Data {
    for line in text.split(whereSeparator: \.isNewline) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
        guard let data = Data(base64Encoded: trimmed) else {
            fail("invalid base64 in \(text.prefix(40))…")
        }
        return data
    }
    fail("no base64 payload found")
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    fail("usage: generate|sign|verify …")
}

switch command {
case "generate":
    let privateKeyPath = arguments.count > 1 ? arguments[1] : "secrets/WallpaperMac.update.key"
    let publicKeyPath = privateKeyPath + ".pub"
    let privateKey = Curve25519.Signing.PrivateKey()
    let publicBase64 = privateKey.publicKey.rawRepresentation.base64EncodedString()
    let privateBase64 = privateKey.rawRepresentation.base64EncodedString()

    let directory = (privateKeyPath as NSString).deletingLastPathComponent
    if !directory.isEmpty {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }
    do {
        try privateBase64.write(toFile: privateKeyPath, atomically: true, encoding: .utf8)
        try publicBase64.write(toFile: publicKeyPath, atomically: true, encoding: .utf8)
    } catch {
        fail("cannot write keys: \(error)")
    }
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateKeyPath)
    print("privateKey: \(privateKeyPath)")
    print("publicKey:  \(publicKeyPath)")
    print("publicBase64: \(publicBase64)")
    print("KEEP THE PRIVATE KEY OFFLINE. Commit only the public key.")

case "sign":
    guard arguments.count >= 3 else { fail("usage: sign <artifact> <privateKeyPath>") }
    let artifactPath = arguments[1]
    let privateKeyPath = arguments[2]

    let privateBase64 = firstDataLine(readLines(privateKeyPath))
    guard let _ = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateBase64) else {
        fail("private key is not a valid Ed25519 key")
    }
    // Must match UpdateSignature.signedMessage: domain || raw SHA-256 digest.
    // Streaming hash so large artifacts never sit in memory.
    let digest = try sha256Digest(at: artifactPath)
    let message = Data("WallpaperMac-update-v1\n".utf8) + digest
    let signature = try (try Curve25519.Signing.PrivateKey(rawRepresentation: privateBase64)).signature(for: message)
    let signatureBase64 = Data(signature).base64EncodedString()
    let signaturePath = artifactPath + ".sig"
    do {
        try signatureBase64.write(toFile: signaturePath, atomically: true, encoding: .utf8)
    } catch {
        fail("cannot write signature: \(error)")
    }
    print("signature: \(signaturePath)")
    print(signatureBase64)

case "verify":
    guard arguments.count >= 4 else { fail("usage: verify <artifact> <sigPath> <publicKeyPath>") }
    let artifactPath = arguments[1]
    let signaturePath = arguments[2]
    let publicKeyPath = arguments[3]

    let signatureData = firstDataLine(readLines(signaturePath))
    let publicKeyData = firstDataLine(readLines(publicKeyPath))
    guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData) else {
        fail("public key is not a valid Ed25519 key")
    }
    let digest = try sha256Digest(at: artifactPath)
    let message = Data("WallpaperMac-update-v1\n".utf8) + digest
    if publicKey.isValidSignature(signatureData, for: message) {
        print("SIGNATURE_OK")
        exit(0)
    }
    print("SIGNATURE_INVALID")
    exit(1)

default:
    fail("unknown command \(command)")
}
