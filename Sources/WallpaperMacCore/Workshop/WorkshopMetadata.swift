import Foundation

/// Content kind of a Workshop item as advertised by Steam's tags.
/// Tags are a pre-download hint only; `project.json` remains authoritative
/// after the files land on disk.
public enum WorkshopKind: String, Equatable, Sendable, Codable {
    case video
    case web
    case scene
    case application
    case unknown
}

/// Normalized subset of `ISteamRemoteStorage/GetPublishedFileDetails` that the
/// import flow needs. The endpoint is anonymous and needs no API key.
public struct WorkshopMetadata: Equatable, Sendable {
    public let itemID: String
    public let title: String
    public let itemDescription: String
    public let tags: [String]
    public let fileSizeBytes: Int64?
    public let previewURL: URL?
    public let consumerAppID: Int?
    public let timeUpdated: Date?
    /// `result == 1` from Steam; false means removed/hidden/nonexistent.
    public let isAvailable: Bool

    public init(
        itemID: String,
        title: String,
        itemDescription: String,
        tags: [String],
        fileSizeBytes: Int64?,
        previewURL: URL?,
        consumerAppID: Int?,
        timeUpdated: Date?,
        isAvailable: Bool
    ) {
        self.itemID = itemID
        self.title = title
        self.itemDescription = itemDescription
        self.tags = tags
        self.fileSizeBytes = fileSizeBytes
        self.previewURL = previewURL
        self.consumerAppID = consumerAppID
        self.timeUpdated = timeUpdated
        self.isAvailable = isAvailable
    }

    /// Best-effort kind from the type tags Steam attaches (exact names from
    /// Wallpaper Engine's own filter list). Nil when no type tag matches.
    public var kindFromTags: WorkshopKind? {
        // Order matters only when multiple type tags appear; Application and
        // Scene are never downloadable as video/web so they win first.
        if tags.contains("Application") { return .application }
        if tags.contains("Scene") { return .scene }
        if tags.contains("Video") { return .video }
        if tags.contains("Web") { return .web }
        return nil
    }

    public var isWallpaperEngineItem: Bool {
        consumerAppID == 431960
    }

    /// True when the metadata alone already rules the item out of v1 import.
    public var unsupportedReason: WorkshopUnsupportedReason? {
        guard isAvailable else { return .unavailable }
        if let kind = kindFromTags {
            switch kind {
            case .scene: return .scene
            case .application: return .application
            case .video, .web, .unknown: break
            }
        }
        if let app = consumerAppID, app != 431960 {
            return .wrongApp(app)
        }
        return nil
    }
}

public enum WorkshopUnsupportedReason: Error, Equatable, Sendable, LocalizedError {
    case unavailable
    case scene
    case application
    case wrongApp(Int)
    case unknownType(String?)
    case missingEntryFile(String)
    case entryFileMissingOnDisk(String)

    public var userMessage: String {
        switch self {
        case .unavailable:
            return "该工坊条目不存在、已隐藏或已被作者移除。"
        case .scene:
            return "场景（Scene）壁纸依赖 Wallpaper Engine 的私有渲染器，当前版本仅支持视频和网页壁纸。"
        case .application:
            return "应用（Application）壁纸是 Windows 程序，无法在 macOS 上运行。"
        case .wrongApp(let app):
            return "该条目属于其他 Steam 应用（appid \(app)），不是 Wallpaper Engine 壁纸。"
        case .unknownType(let type):
            return "无法识别的壁纸类型（\(type ?? "缺失")），仅支持视频和网页壁纸。"
        case .missingEntryFile(let file):
            return "工坊项目缺少入口文件（\(file)）。"
        case .entryFileMissingOnDisk(let file):
            return "下载完成但找不到入口文件（\(file)），请重试下载。"
        }
    }

    public var errorDescription: String? { userMessage }
}

// MARK: - Steam API wire format

struct WorkshopDetailsResponse: Decodable {
    struct FileDetails: Decodable {
        let publishedfileid: String?
        let result: Int?
        let title: String?
        let description: String?
        let file_size: String?
        let preview_url: String?
        let consumer_app_id: Int?
        let time_updated: Double?
        let tags: [Tag]?

        struct Tag: Decodable {
            let tag: String?
        }
    }

    let response: Payload?

    struct Payload: Decodable {
        let result: Int?
        let resultcount: Int?
        let publishedfiledetails: [FileDetails]?
    }
}

public enum WorkshopMetadataParser {
    /// Parses a GetPublishedFileDetails body. `requestedID` fills in when the
    /// wire object omits the id (Steam sometimes does).
    public static func parse(data: Data, requestedID: String) throws -> WorkshopMetadata {
        let decoded = try JSONDecoder().decode(WorkshopDetailsResponse.self, from: data)
        guard let details = decoded.response?.publishedfiledetails?.first else {
            throw WorkshopMetadataError.emptyResponse
        }
        guard let row = row(details, fallbackID: requestedID) else {
            throw WorkshopMetadataError.emptyResponse
        }
        return row
    }

    /// Parses every row of a batched details answer. Rows Steam refused or
    /// that carry non-numeric ids are dropped; an entirely empty body throws.
    public static func parseAll(data: Data) throws -> [WorkshopMetadata] {
        let decoded = try JSONDecoder().decode(WorkshopDetailsResponse.self, from: data)
        guard let rows = decoded.response?.publishedfiledetails, !rows.isEmpty else {
            throw WorkshopMetadataError.emptyResponse
        }
        return rows.compactMap { row($0, fallbackID: nil) }
    }

    private static func row(
        _ details: WorkshopDetailsResponse.FileDetails,
        fallbackID: String?
    ) -> WorkshopMetadata? {
        let result = details.result ?? 0
        let id = details.publishedfileid ?? fallbackID ?? ""
        // Steam's id may later feed filesystem paths; refuse non-digits here.
        // Length/traversal policy for downloads is enforced again in
        // WorkshopDownloadCoordinator and WorkshopLink.parse.
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && $0.isNumber }), id.count <= 20 else {
            return nil
        }
        let preview = details.preview_url.flatMap { URL(string: $0) }
        let size = details.file_size.flatMap { Int64($0) }
        let updated = details.time_updated.map { Date(timeIntervalSince1970: $0) }
        return WorkshopMetadata(
            itemID: id,
            title: details.title ?? "",
            itemDescription: details.description ?? "",
            tags: (details.tags ?? []).compactMap(\.tag),
            fileSizeBytes: size,
            previewURL: preview,
            consumerAppID: details.consumer_app_id,
            timeUpdated: updated,
            isAvailable: result == 1
        )
    }
}

public enum WorkshopMetadataError: Error, Equatable, Sendable, LocalizedError {
    case emptyResponse
    case network(String)
    case httpStatus(Int)
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .emptyResponse:
            return "Steam 未返回条目信息，请检查链接后重试。"
        case .network(let message):
            return "无法连接 Steam：\(message)。大陆网络下 api.steampowered.com 可能需要代理或稍后重试。"
        case .httpStatus(let code):
            return "Steam 接口返回 HTTP \(code)，请稍后重试。"
        case .unavailable:
            return "该工坊条目不可用。"
        }
    }
}
