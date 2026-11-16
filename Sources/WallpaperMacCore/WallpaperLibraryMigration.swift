import Foundation

public struct WallpaperLibraryMigrationResult: Equatable, Sendable {
    public let sourceURL: URL
    public let destinationURL: URL
    public let fileCount: Int
    public let byteCount: Int64

    public init(sourceURL: URL, destinationURL: URL, fileCount: Int, byteCount: Int64) {
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.fileCount = fileCount
        self.byteCount = byteCount
    }
}

public enum WallpaperLibraryMigrationError: LocalizedError, Equatable {
    case sourceMissing(URL)
    case sourceNotDirectory(URL)
    case destinationNotDirectory(URL)
    case destinationNotEmpty(URL)
    case destinationInsideSource(URL)
    case sourceInsideDestination(URL)
    case sameLocation(URL)
    case copyFailed(String)

    public var errorDescription: String? {
        switch self {
        case .sourceMissing(let url):
            return "当前壁纸库不存在：\(url.path)"
        case .sourceNotDirectory(let url):
            return "当前壁纸库不是文件夹：\(url.path)"
        case .destinationNotDirectory(let url):
            return "迁移目标不是文件夹：\(url.path)"
        case .destinationNotEmpty(let url):
            return "迁移目标文件夹必须为空：\(url.path)"
        case .destinationInsideSource(let url):
            return "不能把壁纸库迁移到它自己的子目录：\(url.path)"
        case .sourceInsideDestination(let url):
            return "迁移目标不能是当前壁纸库的父目录：\(url.path)"
        case .sameLocation(let url):
            return "迁移目标与当前壁纸库相同：\(url.path)"
        case .copyFailed(let message):
            return "迁移壁纸库失败：\(message)"
        }
    }
}

public enum WallpaperLibraryMigrator {
    /// Copies every library file to a new, empty directory. The source is
    /// never modified or deleted; the caller switches storage only after this
    /// returns successfully.
    public static func migrate(
        from source: URL,
        to destination: URL,
        fileManager: FileManager = .default
    ) throws -> WallpaperLibraryMigrationResult {
        let source = source.standardizedFileURL.resolvingSymlinksInPath()
        let destination = destination.standardizedFileURL.resolvingSymlinksInPath()
        guard source != destination else {
            throw WallpaperLibraryMigrationError.sameLocation(destination)
        }
        guard fileManager.fileExists(atPath: source.path) else {
            throw WallpaperLibraryMigrationError.sourceMissing(source)
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw WallpaperLibraryMigrationError.sourceNotDirectory(source)
        }
        let sourcePrefix = source.path.hasSuffix("/") ? source.path : source.path + "/"
        let destinationPrefix = destination.path.hasSuffix("/") ? destination.path : destination.path + "/"
        guard !destination.path.hasPrefix(sourcePrefix) else {
            throw WallpaperLibraryMigrationError.destinationInsideSource(destination)
        }
        guard !source.path.hasPrefix(destinationPrefix) else {
            throw WallpaperLibraryMigrationError.sourceInsideDestination(destination)
        }

        let destinationExisted = fileManager.fileExists(atPath: destination.path)
        if destinationExisted {
            var isDestinationDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: destination.path, isDirectory: &isDestinationDirectory),
                  isDestinationDirectory.boolValue else {
                throw WallpaperLibraryMigrationError.destinationNotDirectory(destination)
            }
            let existing = try fileManager.contentsOfDirectory(
                at: destination,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            guard existing.isEmpty else {
                throw WallpaperLibraryMigrationError.destinationNotEmpty(destination)
            }
        } else {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        }

        do {
            let contents = try fileManager.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: nil,
                options: []
            )
            for sourceItem in contents {
                let name = sourceItem.lastPathComponent
                guard name != ".DS_Store", !name.hasPrefix("._") else { continue }
                let destinationItem = destination.appendingPathComponent(name)
                try fileManager.copyItem(at: sourceItem, to: destinationItem)
            }
            let metrics = try libraryMetrics(at: source, fileManager: fileManager)
            return WallpaperLibraryMigrationResult(
                sourceURL: source,
                destinationURL: destination,
                fileCount: metrics.fileCount,
                byteCount: metrics.byteCount
            )
        } catch {
            if destinationExisted {
                for item in (try? fileManager.contentsOfDirectory(
                    at: destination,
                    includingPropertiesForKeys: nil,
                    options: []
                )) ?? [] {
                    try? fileManager.removeItem(at: item)
                }
            } else {
                try? fileManager.removeItem(at: destination)
            }
            if error is WallpaperLibraryMigrationError {
                throw error
            }
            throw WallpaperLibraryMigrationError.copyFailed(error.localizedDescription)
        }
    }

    private static func libraryMetrics(
        at url: URL,
        fileManager: FileManager
    ) throws -> (fileCount: Int, byteCount: Int64) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return (0, 0)
        }
        var count = 0
        var bytes: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            count += 1
            bytes += Int64(values.fileSize ?? 0)
        }
        return (count, bytes)
    }
}
