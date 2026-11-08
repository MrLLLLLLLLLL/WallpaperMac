import Foundation

/// One-time acknowledgement used by the detached update installer. The new
/// process writes this only after AppDelegate has completed its critical setup.
public enum UpdateHealthHandshake {
    public static let tokenArgument = "--update-health-token"
    public static let fileArgument = "--update-health-file"

    @discardableResult
    public static func acknowledge(
        arguments: [String],
        processID: Int32 = ProcessInfo.processInfo.processIdentifier,
        version: String = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "unknown",
        fileManager: FileManager = .default
    ) throws -> Bool {
        var token: String?
        var acknowledgementPath: String?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == tokenArgument, index + 1 < arguments.count {
                token = arguments[index + 1]
                index += 1
            } else if argument == fileArgument, index + 1 < arguments.count {
                acknowledgementPath = arguments[index + 1]
                index += 1
            }
            index += 1
        }
        guard let token, let acknowledgementPath else { return false }
        guard UUID(uuidString: token) != nil, !acknowledgementPath.isEmpty else {
            throw UpdateInstallError.scriptFailed("更新健康确认参数无效")
        }
        let destination = URL(fileURLWithPath: acknowledgementPath, isDirectory: false)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let payload = "token=\(token)\npid=\(processID)\nversion=\(version)\n"
        try Data(payload.utf8).write(to: destination, options: .atomic)
        return true
    }
}
