import CryptoKit
import Foundation

/// Installs Valve's official SteamCMD for macOS from the `steam_cmd_osx`
/// package manifest. The legacy `steamcmd_osx.tar.gz` bootstrap is Intel-only;
/// the manifest's packages carry the arm64 slice Apple silicon needs.
public actor SteamCMDInstaller {
    public static let manifestURL = URL(string: "https://steamcdn-a.akamaihd.net/client/steam_cmd_osx")!
    public static let packageBaseURL = URL(string: "https://steamcdn-a.akamaihd.net/client/")!
    /// Required for a runnable install; the rest (breakpad, public text) is
    /// installed when listed but a manifest without these cannot be SteamCMD.
    public static let requiredPackages = ["steamcmd_osx", "steamcmd_bins_osx"]

    public struct Package: Equatable, Sendable {
        public let name: String
        public let file: String
        public let size: Int64
        public let sha256: String
        /// Valve names every package after the SHA-1 of its bytes.
        public let sha1: String

        public var url: URL {
            SteamCMDInstaller.packageBaseURL.appendingPathComponent(file)
        }
    }

    public struct Manifest: Equatable, Sendable {
        public let version: String
        public let packages: [Package]
        public var totalSize: Int64 { packages.reduce(0) { $0 + $1.size } }
    }

    public enum InstallError: Error, Equatable, Sendable, LocalizedError {
        case network(String)
        case httpStatus(Int)
        case malformedManifest
        case checksumMismatch(package: String, expected: String, actual: String)
        case extractionFailed(String)
        case missingExecutable
        case notInstallable

        public var errorDescription: String? {
            switch self {
            case .network(let message):
                return "下载 SteamCMD 清单失败：\(message)"
            case .httpStatus(let code):
                return "SteamCMD 清单返回 HTTP \(code)"
            case .malformedManifest:
                return "Valve 的 SteamCMD 清单格式无法解析，未安装任何文件。"
            case .checksumMismatch(let package, let expected, let actual):
                return "SteamCMD 组件 \(package) 校验失败（期望 \(expected.prefix(12))…，实际 \(actual.prefix(12))…），已中止安装。"
            case .extractionFailed(let detail):
                return "解压 SteamCMD 失败：\(detail)"
            case .missingExecutable:
                return "安装后未找到可执行的 steamcmd。"
            case .notInstallable:
                return "当前系统无法安装 SteamCMD。"
            }
        }
    }

    public enum State: Equatable, Sendable {
        case idle
        case checking
        case downloading(package: String, received: Int64, expected: Int64?)
        case extracting(package: String)
        case committing
        case ready(URL)
        case failed(String)
    }

    private let session: URLSession
    private let fileManager: FileManager

    public init(session: URLSession = .shared, fileManager: FileManager = .default) {
        self.session = session
        self.fileManager = fileManager
    }

    /// Returns the steamcmd executable inside `directory` when present and executable.
    public static func executable(in directory: URL) -> URL? {
        let candidate = directory.appendingPathComponent("steamcmd")
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: candidate.path) else { return nil }
        // Must be executable; chmod +x after extract handles the common case.
        return fileManager.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    // MARK: - Manifest parsing (Valve KeyValues subset)

    /// Parses the quoted-string / brace / `//`-comment grammar Valve writes.
    /// Anything outside that subset is refused rather than guessed.
    public static func parseManifest(_ text: String) throws -> Manifest {
        let tokens = try tokenize(text)
        var index = 0
        let document = try parseEntries(tokens, index: &index, depth: 0)

        let roots = document.filter { $0.key == "osx" }
        guard roots.count == 1, case .block(let osx) = roots[0].value else {
            throw InstallError.malformedManifest
        }

        var version: String?
        var packages: [Package] = []
        for entry in osx {
            switch entry.value {
            case .text(let value) where entry.key == "version":
                version = value
            case .block(let fields):
                if let package = try parsePackage(name: entry.key, fields: fields) {
                    packages.append(package)
                }
            default:
                continue
            }
        }

        guard let version, !version.isEmpty,
              packages.contains(where: { requiredPackages.contains($0.name) }) else {
            throw InstallError.malformedManifest
        }
        // Every required package must be present.
        for required in requiredPackages where !packages.contains(where: { $0.name == required }) {
            throw InstallError.malformedManifest
        }
        let total = packages.reduce(Int64(0)) { sum, package in
            let (value, overflow) = sum.addingReportingOverflow(package.size)
            return overflow ? Int64.max : value
        }
        guard total <= 256 * 1024 * 1024 else { throw InstallError.malformedManifest }
        return Manifest(version: version, packages: packages)
    }

    private indirect enum Value { case text(String), block([Entry]) }
    private struct Entry { let key: String; let value: Value }
    private enum Token: Equatable { case string(String), open, close }

    private static func tokenize(_ text: String) throws -> [Token] {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, bytes.count <= 64 * 1024 else { throw InstallError.malformedManifest }
        var tokens: [Token] = []
        var index = 0
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0a, 0x0d:
                index += 1
            case UInt8(ascii: "{"):
                tokens.append(.open)
                index += 1
            case UInt8(ascii: "}"):
                tokens.append(.close)
                index += 1
            case UInt8(ascii: "/") where index + 1 < bytes.count && bytes[index + 1] == UInt8(ascii: "/"):
                while index < bytes.count, bytes[index] != 0x0a { index += 1 }
            case UInt8(ascii: "\""):
                index += 1
                let start = index
                while index < bytes.count, bytes[index] != UInt8(ascii: "\"") {
                    guard (0x20..<0x7f).contains(bytes[index]), bytes[index] != UInt8(ascii: "\\") else {
                        throw InstallError.malformedManifest
                    }
                    index += 1
                }
                guard index < bytes.count else { throw InstallError.malformedManifest }
                tokens.append(.string(String(decoding: bytes[start..<index], as: UTF8.self)))
                index += 1
            default:
                throw InstallError.malformedManifest
            }
            guard tokens.count <= 4096 else { throw InstallError.malformedManifest }
        }
        return tokens
    }

    private static func parseEntries(_ tokens: [Token], index: inout Int, depth: Int) throws -> [Entry] {
        var entries: [Entry] = []
        while index < tokens.count {
            if tokens[index] == .close, depth > 0 { return entries }
            guard case .string(let key) = tokens[index], index + 1 < tokens.count else {
                throw InstallError.malformedManifest
            }
            index += 1
            switch tokens[index] {
            case .string(let value):
                entries.append(Entry(key: key, value: .text(value)))
                index += 1
            case .open:
                guard depth < 4 else { throw InstallError.malformedManifest }
                index += 1
                let children = try parseEntries(tokens, index: &index, depth: depth + 1)
                guard index < tokens.count, tokens[index] == .close else {
                    throw InstallError.malformedManifest
                }
                index += 1
                entries.append(Entry(key: key, value: .block(children)))
            case .close:
                throw InstallError.malformedManifest
            }
        }
        guard depth == 0 else { throw InstallError.malformedManifest }
        return entries
    }

    private static func parsePackage(name: String, fields: [Entry]) throws -> Package? {
        guard name.count >= 1, name.count <= 64,
              name.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "_") }) else {
            return nil
        }
        var text: [String: String] = [:]
        var seen = Set<String>()
        for field in fields {
            guard !seen.contains(field.key) else { throw InstallError.malformedManifest }
            seen.insert(field.key)
            if case .text(let value) = field.value {
                text[field.key] = value
            }
        }
        let prefix = name + ".zip."
        guard let file = text["file"], file.hasPrefix(prefix),
              let sizeText = text["size"], let size = Int64(sizeText), size > 0,
              let sha256 = text["sha2"]?.lowercased(), sha256.count == 64,
              sha256.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }
        let sha1 = String(file.dropFirst(prefix.count)).lowercased()
        guard sha1.count == 40, sha1.allSatisfy({ $0.isHexDigit }) else {
            throw InstallError.malformedManifest
        }
        return Package(name: name, file: file, size: size, sha256: sha256, sha1: sha1)
    }

    // MARK: - Fetch + verify + extract

    public func fetchManifest() async throws -> Manifest {
        let request = URLRequest(
            url: Self.manifestURL,
            cachePolicy: .reloadRevalidatingCacheData,
            timeoutInterval: 30
        )
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw InstallError.network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw InstallError.httpStatus(http.statusCode)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw InstallError.malformedManifest
        }
        return try Self.parseManifest(text)
    }

    /// Downloads, verifies, and extracts every package into `destination`.
    /// Existing complete installs are replaced only after the new set passes
    /// every checksum.
    public func install(
        to destination: URL,
        onState: (@Sendable (State) -> Void)? = nil
    ) async throws -> URL {
        onState?(.checking)
        let manifest = try await fetchManifest()

        let staging = destination.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        for package in manifest.packages {
            onState?(.downloading(package: package.name, received: 0, expected: package.size))
            let zipURL = staging.appendingPathComponent(package.file)
            try await downloadPackage(package, to: zipURL, onState: onState)

            let actual = try sha256(of: zipURL)
            guard actual == package.sha256 else {
                throw InstallError.checksumMismatch(
                    package: package.name,
                    expected: package.sha256,
                    actual: actual
                )
            }

            onState?(.extracting(package: package.name))
            try await extract(zip: zipURL, into: staging)
        }

        onState?(.committing)
        // Promote: move staging content over destination atomically-ish per file.
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let contents = try fileManager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
        for item in contents {
            let name = item.lastPathComponent
            if name.hasPrefix(".") && name.contains("staging-") { continue }
            let target = destination.appendingPathComponent(name)
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
            try fileManager.moveItem(at: item, to: target)
        }

        let executable = destination.appendingPathComponent("steamcmd")
        guard fileManager.fileExists(atPath: executable.path) else {
            throw InstallError.missingExecutable
        }
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let shell = destination.appendingPathComponent("steamcmd.sh")
        if fileManager.fileExists(atPath: shell.path) {
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
        }

        guard Self.executable(in: destination) != nil else {
            throw InstallError.missingExecutable
        }
        onState?(.ready(executable))
        return executable
    }

    private func downloadPackage(
        _ package: Package,
        to destination: URL,
        onState: (@Sendable (State) -> Void)?
    ) async throws {
        let request = URLRequest(url: package.url, timeoutInterval: 120)
        do {
            let (bytes, response) = try await session.bytes(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw InstallError.httpStatus(http.statusCode)
            }
            fileManager.createFile(atPath: destination.path, contents: nil)
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            var received: Int64 = 0
            var buffer = Data()
            buffer.reserveCapacity(64 * 1024)
            for try await byte in bytes {
                buffer.append(byte)
                received += 1
                if buffer.count >= 64 * 1024 {
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                    if received % (1024 * 1024) < 64 * 1024 {
                        onState?(.downloading(
                            package: package.name,
                            received: received,
                            expected: package.size
                        ))
                    }
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
            }
            guard received == package.size else {
                throw InstallError.checksumMismatch(
                    package: package.name,
                    expected: "size \(package.size)",
                    actual: "size \(received)"
                )
            }
        } catch let error as InstallError {
            throw error
        } catch {
            throw InstallError.network(error.localizedDescription)
        }
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Extracts a zip with `/usr/bin/tar` (bsdtar handles zip). Valve's
    /// breakpad package stores Windows backslash paths — normalize after.
    /// stderr goes to a temp file (never a pipe) so a verbose archive cannot
    /// deadlock `waitUntilExit`, matching `ProcessRunner`'s rule.
    private func extract(zip: URL, into directory: URL) async throws {
        let stderrURL = fileManager.temporaryDirectory
            .appendingPathComponent("wm-steamcmd-extract-\(UUID().uuidString).log")
        fileManager.createFile(atPath: stderrURL.path, contents: nil)
        defer { try? fileManager.removeItem(at: stderrURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xf", zip.path, "-C", directory.path]
        process.standardOutput = FileHandle.nullDevice
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        process.standardError = stderrHandle
        defer { try? stderrHandle.close() }

        do {
            try process.run()
        } catch {
            throw InstallError.extractionFailed(error.localizedDescription)
        }

        // Wait off the cooperative pool: extract can take seconds and a
        // Thread.sleep loop here would stutter every other async task.
        let waited = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let deadline = Date().addingTimeInterval(120)
                while process.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if process.isRunning {
                    process.terminate()
                    let killDeadline = Date().addingTimeInterval(2)
                    while process.isRunning && Date() < killDeadline {
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                        while process.isRunning {
                            Thread.sleep(forTimeInterval: 0.05)
                        }
                    }
                    cont.resume(returning: false)
                    return
                }
                cont.resume(returning: true)
            }
        }
        guard waited else {
            throw InstallError.extractionFailed("解压超时")
        }
        guard process.terminationStatus == 0 else {
            let data = (try? Data(contentsOf: stderrURL)) ?? Data()
            let text = String(data: data, encoding: .utf8) ?? ""
            throw InstallError.extractionFailed(String(text.prefix(500)))
        }
        // Normalize `Frameworks\Breakpad.framework/...` backslash names.
        normalizeBackslashPaths(in: directory)
    }

    private func normalizeBackslashPaths(in root: URL) {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return }
        var renames: [(URL, URL)] = []
        for case let url as URL in enumerator {
            if url.lastPathComponent.contains("\\") {
                let fixedName = url.lastPathComponent.replacingOccurrences(of: "\\", with: "/")
                // Only the final component can be renamed in place; nested
                // backslash directories appear as a single flat name.
                let fixed = url.deletingLastPathComponent().appendingPathComponent(
                    fixedName.replacingOccurrences(of: "/", with: "-")
                )
                renames.append((url, fixed))
            }
        }
        for (from, to) in renames {
            try? fileManager.moveItem(at: from, to: to)
        }
    }
}
