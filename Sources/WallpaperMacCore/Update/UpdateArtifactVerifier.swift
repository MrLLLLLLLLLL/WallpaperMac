import CryptoKit
import Foundation

/// Pure artifact-integrity helpers: SHA-256 hashing and `SHA256SUMS.txt` parsing.
///
/// Kept separate from the downloader so the verification rules can be tested
/// against known bytes without touching the network or the file system beyond
/// a temporary file.
public enum UpdateArtifactVerifier {
    /// Parses GNU `shasum`/`sha256sum` output: `<hex>  <path>` or `<hex> *<path>`.
    /// Keys are basenames so entries written as `dist/WallpaperMac-…zip` still
    /// match the bare asset name used by GitHub Releases.
    public static func checksums(from data: Data) -> [String: String] {
        guard let text = String(data: data, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let entry = parseChecksumLine(String(line)) else { continue }
            result[entry.name] = entry.hash
        }
        return result
    }

    static func parseChecksumLine(_ line: String) -> (hash: String, name: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 64 else { return nil }

        let hashPart = trimmed.prefix(64)
        guard hashPart.allSatisfy(\.isHexDigit) else { return nil }
        let afterHash = trimmed.dropFirst(64)
        guard let first = afterHash.first, first.isWhitespace else { return nil }

        var path = afterHash.drop(while: \.isWhitespace)
        if path.hasPrefix("*") {
            path = path.dropFirst()
        }
        let cleaned = path.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }

        let name = URL(fileURLWithPath: cleaned).lastPathComponent
        guard !name.isEmpty, name != "/" else { return nil }
        return (hashPart.lowercased(), name)
    }

    public static func expectedChecksum(
        forAssetNamed name: String,
        inChecksumsFile data: Data
    ) -> String? {
        checksums(from: data)[name]
    }

    public static func sha256Hex(ofData data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Streaming hash so multi-hundred-megabyte artifacts never sit in memory.
    public static func sha256Hex(ofFileAt url: URL) throws -> String {
        try sha256Digest(ofFileAt: url)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Raw 32-byte SHA-256 digest, computed by streaming the file in chunks.
    public static func sha256Digest(ofFileAt url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }

    public static func verify(fileAt url: URL, expectedHash: String) throws -> Bool {
        let actual = try sha256Hex(ofFileAt: url)
        return actual == expectedHash.lowercased()
    }
}
