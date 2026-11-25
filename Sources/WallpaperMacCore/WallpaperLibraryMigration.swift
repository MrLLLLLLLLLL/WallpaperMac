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
        // Keep the lexical roots used by the persisted index alongside the
        // resolved roots used for safety checks and copying. An index may use
        // either spelling when a library was selected through a symlink.
        let storedSource = source.standardizedFileURL
        let storedDestination = destination.standardizedFileURL
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
            // Metadata is rewritten inside the same do/catch as the copy. A
            // malformed index or backup therefore follows the same rollback
            // path as a failed file copy and cannot leave a nonempty target.
            try rewriteMetadata(
                at: destination,
                storedSource: storedSource,
                resolvedSource: source,
                storedDestination: storedDestination,
                fileManager: fileManager
            )
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

    private static func rewriteMetadata(
        at destination: URL,
        storedSource: URL,
        resolvedSource: URL,
        storedDestination: URL,
        fileManager: FileManager
    ) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for name in ["wallpapers.json", "wallpapers.json.bak"] {
            let url = destination.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            let data = try Data(contentsOf: url)
            let items = try decoder.decode([WallpaperItem].self, from: data)
            let rebased = items.map { item in
                rebase(
                    item,
                    storedSource: storedSource,
                    resolvedSource: resolvedSource,
                    storedDestination: storedDestination
                )
            }
            // Do not use WallpaperStore.save here: migration must preserve a
            // distinct backup and any .recover marker, and must not create an
            // index when the source only had a backup.
            let output = try encoder.encode(rebased)
            try output.write(to: url, options: .atomic)
        }
    }

    private static func rebase(
        _ item: WallpaperItem,
        storedSource: URL,
        resolvedSource: URL,
        storedDestination: URL
    ) -> WallpaperItem {
        var updated = item
        if item.storageMode == .managedCopy {
            updated.sourceURL = rebaseLibraryURL(
                item.sourceURL,
                storedSource: storedSource,
                resolvedSource: resolvedSource,
                storedDestination: storedDestination,
                thumbnailsOnly: false
            )
            updated.entryURL = item.entryURL.map {
                rebaseLibraryURL(
                    $0,
                    storedSource: storedSource,
                    resolvedSource: resolvedSource,
                    storedDestination: storedDestination,
                    thumbnailsOnly: false
                )
            }
            updated.playbackURL = item.playbackURL.map {
                rebaseLibraryURL(
                    $0,
                    storedSource: storedSource,
                    resolvedSource: resolvedSource,
                    storedDestination: storedDestination,
                    thumbnailsOnly: false
                )
            }
        }
        // Thumbnails are app-owned even for external-reference items. Only
        // files under the old library's Thumbnails directory move; an external
        // source or an arbitrary external thumbnail is never rewritten.
        updated.thumbnailURL = item.thumbnailURL.map {
            rebaseLibraryURL(
                $0,
                storedSource: storedSource,
                resolvedSource: resolvedSource,
                storedDestination: storedDestination,
                thumbnailsOnly: true
            )
        }
        return updated
    }

    private static func rebaseLibraryURL(
        _ url: URL,
        storedSource: URL,
        resolvedSource: URL,
        storedDestination: URL,
        thumbnailsOnly: Bool
    ) -> URL {
        guard url.isFileURL else { return url }
        let path = url.standardizedFileURL.path
        let roots = [storedSource, resolvedSource].map { root in
            thumbnailsOnly
                ? root.appendingPathComponent("Thumbnails", isDirectory: true).standardizedFileURL
                : root.standardizedFileURL
        }
        for root in roots {
            let rootPath = root.path
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            guard path.hasPrefix(prefix) else { continue }
            let relative = String(path.dropFirst(prefix.count))
            let destination = thumbnailsOnly
                ? storedDestination.appendingPathComponent("Thumbnails", isDirectory: true)
                : storedDestination
            guard !relative.isEmpty else { return destination }
            return destination.appendingPathComponent(relative, isDirectory: url.hasDirectoryPath).standardizedFileURL
        }
        return url
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
