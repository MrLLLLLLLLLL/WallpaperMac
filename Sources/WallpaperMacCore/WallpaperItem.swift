import Foundation

public enum WallpaperType: String, Codable, CaseIterable, Equatable, Sendable {
    case image
    case video
    case web

    public static func detect(from url: URL, fileManager: FileManager = .default) -> WallpaperType? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return fromExtension(url.pathExtension)
        }

        if isDirectory.boolValue {
            guard let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                return nil
            }
            let containsHTML = enumerator.contains { candidate in
                guard let candidate = candidate as? URL,
                      ["html", "htm"].contains(candidate.pathExtension.lowercased()) else {
                    return false
                }
                return (try? candidate.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
            }
            return containsHTML ? .web : nil
        }

        return fromExtension(url.pathExtension)
    }

    private static func fromExtension(_ extensionName: String) -> WallpaperType? {
        switch extensionName.lowercased() {
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "tif", "tiff":
            return .image
        case "mp4", "mov", "m4v", "webm", "avi", "mkv":
            return .video
        case "html", "htm":
            return .web
        default:
            return nil
        }
    }
}

public enum StorageMode: String, Codable, CaseIterable, Equatable, Sendable {
    case managedCopy
    case externalReference
}

public enum WallpaperAvailability: String, Codable, CaseIterable, Equatable, Sendable {
    case available
    case importing
    case missing
    case unsupported
    case permissionDenied
}

public struct WallpaperMetadata: Codable, Equatable, Sendable {
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var durationSeconds: Double?
    public var fileSizeBytes: Int64?
    public var fileExtension: String?

    public init(
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        durationSeconds: Double? = nil,
        fileSizeBytes: Int64? = nil,
        fileExtension: String? = nil
    ) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.durationSeconds = durationSeconds
        self.fileSizeBytes = fileSizeBytes
        self.fileExtension = fileExtension
    }
}

public struct WallpaperItem: Identifiable, Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id, name, type, sourceURL, playbackURL, entryURL, storageMode, thumbnailURL, metadata, availability
        case createdAt, lastUsedAt, isFavorite, groupID
    }

    public let id: UUID
    public var name: String
    public var type: WallpaperType
    public var sourceURL: URL
    /// Optional app-managed copy used when the source container needs a playback-only compatibility fix.
    public var playbackURL: URL?
    public var entryURL: URL?
    public var storageMode: StorageMode
    public var thumbnailURL: URL?
    public var metadata: WallpaperMetadata?
    public var availability: WallpaperAvailability
    public var createdAt: Date
    public var lastUsedAt: Date?
    public var isFavorite: Bool
    public var groupID: UUID?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(WallpaperType.self, forKey: .type)
        sourceURL = try container.decode(URL.self, forKey: .sourceURL)
        playbackURL = try container.decodeIfPresent(URL.self, forKey: .playbackURL)
        entryURL = try container.decodeIfPresent(URL.self, forKey: .entryURL)
        storageMode = try container.decode(StorageMode.self, forKey: .storageMode)
        thumbnailURL = try container.decodeIfPresent(URL.self, forKey: .thumbnailURL)
        metadata = try container.decodeIfPresent(WallpaperMetadata.self, forKey: .metadata)
        // Legacy archives omitted several fields. Fall back conservatively:
        // missing availability must not look healthy, and missing createdAt
        // must not sort the item as brand new.
        availability = try container.decodeIfPresent(WallpaperAvailability.self, forKey: .availability) ?? .missing
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        groupID = try container.decodeIfPresent(UUID.self, forKey: .groupID)
    }

    public init(
        id: UUID = UUID(),
        name: String,
        type: WallpaperType,
        sourceURL: URL,
        playbackURL: URL? = nil,
        entryURL: URL? = nil,
        storageMode: StorageMode,
        thumbnailURL: URL? = nil,
        metadata: WallpaperMetadata? = nil,
        availability: WallpaperAvailability = .available,
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil,
        isFavorite: Bool = false,
        groupID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.sourceURL = sourceURL
        self.playbackURL = playbackURL
        self.entryURL = entryURL
        self.storageMode = storageMode
        self.thumbnailURL = thumbnailURL
        self.metadata = metadata
        self.availability = availability
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.isFavorite = isFavorite
        self.groupID = groupID
    }
}
