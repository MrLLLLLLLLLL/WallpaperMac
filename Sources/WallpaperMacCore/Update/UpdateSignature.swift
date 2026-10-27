import CryptoKit
import Foundation

/// Ed25519 detached signatures for update artifacts.
///
/// GitHub HTTPS plus published SHA-256 protects transport and corruption. A
/// signature bound to a key held outside the repository additionally protects
/// against a compromised GitHub account publishing a malicious zip: without
/// the private key the attacker cannot produce a signature the app accepts.
///
/// Wire format is deliberately minimal (not full minisign) so verification
/// needs no third-party binary:
/// - public key: raw 32-byte Ed25519 key, base64, one line
/// - signature:  raw 64-byte Ed25519 signature of `signedMessage`, base64
///
/// The signed message is `protocolDomain || SHA256(file)` (concatenation, not
/// a second hash). Signing the digest keeps large artifacts out of memory and
/// the domain prefix keeps a signature from being replayed at another
/// protocol that also signs bare SHA-256 digests.
public enum UpdateSignature {
    public static let publicKeyFileDefaultName = "WallpaperMac.update.pub"

    /// ASCII domain separator prefixed to every signed digest. Both the app
    /// and `scripts/update-signing-tool.swift` must use this exact value.
    public static let protocolDomain = Data("WallpaperMac-update-v1\n".utf8)

    /// Release-signing public key. The private half lives outside the
    /// repository; rotating it means shipping an app update first.
    public static let releasePublicKeyBase64 = "foCWVc0f2OqKht/95zzLJOfzcRj93Upvd3B5IDkAGbo="

    /// `protocolDomain || rawDigest` — the exact bytes Ed25519 signs.
    public static func signedMessage(digest: Data) -> Data {
        protocolDomain + digest
    }

    /// Signs the artifact digest and returns the base64 signature payload.
    public static func sign(
        fileAt url: URL,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws -> String {
        // Streaming digest: the artifact is never held in memory whole.
        let digest = try UpdateArtifactVerifier.sha256Digest(ofFileAt: url)
        return try sign(digest: digest, privateKey: privateKey)
    }

    public static func sign(
        data: Data,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws -> String {
        let digest = Data(SHA256.hash(data: data))
        return try sign(digest: digest, privateKey: privateKey)
    }

    public static func sign(
        digest: Data,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws -> String {
        let signature = try privateKey.signature(for: signedMessage(digest: digest))
        return Data(signature).base64EncodedString()
    }

    public static func verify(
        fileAt url: URL,
        signatureBase64: String,
        publicKeyBase64: String
    ) throws -> Bool {
        // Streaming digest so multi-hundred-MB zips never sit in memory.
        let digest = try UpdateArtifactVerifier.sha256Digest(ofFileAt: url)
        return verify(digest: digest, signatureBase64: signatureBase64, publicKeyBase64: publicKeyBase64)
    }

    public static func verify(
        data: Data,
        signatureBase64: String,
        publicKeyBase64: String
    ) throws -> Bool {
        let digest = Data(SHA256.hash(data: data))
        return verify(digest: digest, signatureBase64: signatureBase64, publicKeyBase64: publicKeyBase64)
    }

    public static func verify(
        digest: Data,
        signatureBase64: String,
        publicKeyBase64: String
    ) -> Bool {
        guard let keyData = Data(base64Encoded: publicKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
              let signatureData = Data(base64Encoded: signatureBase64.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        let publicKey: Curve25519.Signing.PublicKey
        do {
            publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        } catch {
            return false
        }
        return publicKey.isValidSignature(signatureData, for: signedMessage(digest: digest))
    }

    /// Parses `.sig` asset contents written by the release tooling.
    public static func parseSignatureFile(_ text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            return trimmed
        }
        return nil
    }
}
