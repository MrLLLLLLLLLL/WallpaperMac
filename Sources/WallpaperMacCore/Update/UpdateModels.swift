import Foundation

/// A GitHub release that is newer than the running application.
public struct AvailableUpdate: Equatable, Sendable {
    public let version: String
    public let releaseNotes: String
    public let releasePageURL: URL
    public let zipURL: URL
    public let checksumsURL: URL?
    public let signatureURL: URL?
    public let publishedAt: Date?

    public init(
        version: String,
        releaseNotes: String,
        releasePageURL: URL,
        zipURL: URL,
        checksumsURL: URL?,
        signatureURL: URL? = nil,
        publishedAt: Date?
    ) {
        self.version = version
        self.releaseNotes = releaseNotes
        self.releasePageURL = releasePageURL
        self.zipURL = zipURL
        self.checksumsURL = checksumsURL
        self.signatureURL = signatureURL
        self.publishedAt = publishedAt
    }
}

public enum UpdateCheckResult: Equatable, Sendable {
    case upToDate(currentVersion: String)
    case updateAvailable(AvailableUpdate)
}

public enum UpdateCheckError: Error, Equatable, Sendable, LocalizedError {
    case invalidCurrentVersion(String)
    case network(String)
    case rateLimited
    case notFound
    case invalidResponse
    case missingAsset(String)
    case invalidReleaseVersion(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCurrentVersion(let version):
            return "无法解析当前版本号：\(version)"
        case .network(let message):
            return "网络请求失败：\(message)"
        case .rateLimited:
            return "检查更新过于频繁，请稍后再试"
        case .notFound:
            return "未找到任何发布版本"
        case .invalidResponse:
            return "更新服务返回了无法解析的数据"
        case .missingAsset(let name):
            return "发布资源缺少必要文件：\(name)"
        case .invalidReleaseVersion(let tag):
            return "无法解析发布版本号：\(tag)"
        }
    }
}

public enum UpdateSignaturePolicy: Equatable, Sendable {
    /// Reject any release that does not carry a valid signature asset.
    case required
    /// Verify signatures when the release publishes one; allow unsigned
    /// artifacts otherwise. Useful while rolling the first signed build.
    case ifPresent
}
