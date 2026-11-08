import CryptoKit
import Foundation
import Security

/// Password verifier for the hidden-wallpaper toggle. Only a salted PBKDF2
/// digest is persisted; the password itself is never stored.
public struct HiddenWallpaperLock: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let defaultIterations = 210_000
    public static let saltByteCount = 16
    public static let keyByteCount = 32
    public static let minimumPasswordLength = 4
    public static let maximumPasswordLength = 128

    public var version: Int
    public var saltBase64: String
    public var iterations: Int
    public var hashBase64: String

    public init(version: Int, saltBase64: String, iterations: Int, hashBase64: String) {
        self.version = version
        self.saltBase64 = saltBase64
        self.iterations = iterations
        self.hashBase64 = hashBase64
    }

    /// Creates a verifier for a non-empty password. Returns nil when the
    /// password is outside the supported length or randomness fails.
    public static func make(
        password: String,
        iterations: Int = defaultIterations
    ) -> HiddenWallpaperLock? {
        guard isValidPassword(password), iterations > 0 else { return nil }
        var salt = Data(count: saltByteCount)
        let status = salt.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, saltByteCount, base)
        }
        guard status == errSecSuccess else { return nil }
        let digest = derivedKey(
            password: password,
            salt: salt,
            iterations: iterations,
            keyLength: keyByteCount
        )
        return HiddenWallpaperLock(
            version: currentVersion,
            saltBase64: salt.base64EncodedString(),
            iterations: iterations,
            hashBase64: digest.base64EncodedString()
        )
    }

    public static func isValidPassword(_ password: String) -> Bool {
        let count = password.utf8.count
        return count >= minimumPasswordLength && count <= maximumPasswordLength
    }

    public func verify(password: String) -> Bool {
        guard version == Self.currentVersion,
              iterations > 0, iterations <= 1_000_000,
              let salt = Data(base64Encoded: saltBase64),
              (8...64).contains(salt.count),
              let expected = Data(base64Encoded: hashBase64),
              expected.count == Self.keyByteCount else {
            return false
        }
        let actual = Self.derivedKey(
            password: password,
            salt: salt,
            iterations: iterations,
            keyLength: expected.count
        )
        guard actual.count == expected.count else { return false }
        // Constant-time comparison: do not stop at the first differing byte.
        var difference: UInt8 = 0
        for index in actual.indices {
            difference |= actual[index] ^ expected[index]
        }
        return difference == 0
    }

    /// PBKDF2-HMAC-SHA256 implemented with CryptoKit so the verifier works
    /// without an extra system-library target.
    public static func derivedKey(
        password: String,
        salt: Data,
        iterations: Int,
        keyLength: Int
    ) -> Data {
        precondition(iterations > 0 && keyLength > 0)
        let passwordKey = SymmetricKey(data: Data(password.utf8))
        var derived = Data()
        var blockIndex: UInt32 = 1
        while derived.count < keyLength {
            var blockIndexData = Data()
            withUnsafeBytes(of: blockIndex.bigEndian) { blockIndexData.append(contentsOf: $0) }
            var mac = HMAC<SHA256>(key: passwordKey)
            mac.update(data: salt)
            mac.update(data: blockIndexData)
            var u = Data(mac.finalize())
            var t = u
            if iterations > 1 {
                for _ in 1..<iterations {
                    var nextMac = HMAC<SHA256>(key: passwordKey)
                    nextMac.update(data: u)
                    u = Data(nextMac.finalize())
                    for index in t.indices {
                        t[index] ^= u[index]
                    }
                }
            }
            derived.append(t)
            blockIndex += 1
        }
        return Data(derived.prefix(keyLength))
    }
}
