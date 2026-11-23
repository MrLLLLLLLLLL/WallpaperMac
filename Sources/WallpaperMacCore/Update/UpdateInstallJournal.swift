import Foundation

/// Durable record of a failed detached install. The shell installer writes a
/// key=value file outside its staging directory; the next app launch consumes
/// it so a failed update is visible instead of silently ending with a quit.
public struct UpdateInstallFailure: Equatable, Sendable {
    public let version: String?
    public let message: String
    public let logPath: String?
    public let recordedAt: String?

    public init(version: String?, message: String, logPath: String?, recordedAt: String?) {
        self.version = version
        self.message = message
        self.logPath = logPath
        self.recordedAt = recordedAt
    }
}

public enum UpdateInstallJournal {
    public static let failureFileName = "last-install-failure.txt"

    public static var directoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("WallpaperMac", isDirectory: true)
            .appendingPathComponent("Update", isDirectory: true)
    }

    public static var failureFileURL: URL {
        directoryURL.appendingPathComponent(failureFileName, isDirectory: false)
    }

    /// Reads and removes the failure record. Invalid or empty files are
    /// removed as well so they cannot block future notifications forever.
    public static func takeFailure(
        directory: URL = directoryURL,
        fileManager: FileManager = .default
    ) -> UpdateInstallFailure? {
        let fileURL = directory.appendingPathComponent(failureFileName, isDirectory: false)
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        try? fileManager.removeItem(at: fileURL)
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator])
            let value = String(line[line.index(after: separator)...])
            fields[key] = value
        }
        guard fields["state"] == "failed",
              let message = fields["message"],
              !message.isEmpty else {
            return nil
        }
        let version = fields["version"].flatMap { $0.isEmpty ? nil : $0 }
        let logPath = fields["log"].flatMap { $0.isEmpty ? nil : $0 }
        let recordedAt = fields["date"].flatMap { $0.isEmpty ? nil : $0 }
        return UpdateInstallFailure(
            version: version,
            message: message,
            logPath: logPath,
            recordedAt: recordedAt
        )
    }

    /// Used by tests and diagnostics to create a failure record.
    public static func writeFailure(
        _ failure: UpdateInstallFailure,
        directory: URL = directoryURL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var lines = ["state=failed"]
        if let version = failure.version, !version.isEmpty {
            lines.append("version=\(version)")
        }
        lines.append("message=\(failure.message)")
        if let logPath = failure.logPath, !logPath.isEmpty {
            lines.append("log=\(logPath)")
        }
        if let recordedAt = failure.recordedAt, !recordedAt.isEmpty {
            lines.append("date=\(recordedAt)")
        }
        let url = directory.appendingPathComponent(failureFileName, isDirectory: false)
        try Data((lines.joined(separator: "\n") + "\n").utf8)
            .write(to: url, options: .atomic)
    }
}
