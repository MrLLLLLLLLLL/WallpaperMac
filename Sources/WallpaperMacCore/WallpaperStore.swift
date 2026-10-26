import Foundation

public enum WallpaperStoreError: Error, LocalizedError, Equatable {
    case sourceMissing(URL)
    case unsupportedSource(URL)
    case itemNotFound(UUID)
    case permissionDenied(URL)
    case invalidHTMLEntry(URL)

    public var errorDescription: String? {
        switch self {
        case .sourceMissing(let url):
            return "壁纸资源不存在：\(url.path)"
        case .unsupportedSource(let url):
            return "不支持的壁纸资源：\(url.lastPathComponent)"
        case .itemNotFound(let id):
            return "找不到壁纸记录：\(id.uuidString)"
        case .permissionDenied(let url):
            return "没有权限读取壁纸资源：\(url.path)"
        case .invalidHTMLEntry(let url):
            return "网页入口文件无效：\(url.path)"
        }
    }
}

public final class WallpaperStore {
    public let libraryURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private var metadataURL: URL {
        libraryURL.appendingPathComponent("wallpapers.json")
    }

    private var assignmentsURL: URL {
        libraryURL.appendingPathComponent("display-assignments.json")
    }

    private var groupsURL: URL {
        libraryURL.appendingPathComponent("wallpaper-groups.json")
    }

    private var displayQueuesURL: URL {
        libraryURL.appendingPathComponent("display-queues.json")
    }

    private var playbackQueuesURL: URL {
        libraryURL.appendingPathComponent("playback-queues.json")
    }

    private var displayPlaybackBindingsURL: URL {
        libraryURL.appendingPathComponent("display-playback-bindings.json")
    }

    public init(libraryURL: URL, fileManager: FileManager = .default) {
        self.libraryURL = libraryURL
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func items() throws -> [WallpaperItem] {
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            return []
        }
        let data = try Data(contentsOf: metadataURL)
        return try decoder.decode([WallpaperItem].self, from: data)
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func save(items: [WallpaperItem]) throws {
        try save(items)
    }

    public func groups() throws -> [WallpaperGroup] {
        guard fileManager.fileExists(atPath: groupsURL.path) else {
            return []
        }
        let data = try Data(contentsOf: groupsURL)
        return try decoder.decode([WallpaperGroup].self, from: data)
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func save(groups: [WallpaperGroup]) throws {
        try ensureLibraryDirectories()
        let data = try encoder.encode(groups)
        try data.write(to: groupsURL, options: .atomic)
    }

    public func playbackQueues() throws -> [PlaybackQueue] {
        if fileManager.fileExists(atPath: playbackQueuesURL.path) {
            let data = try Data(contentsOf: playbackQueuesURL)
            var queues = try decoder.decode([PlaybackQueue].self, from: data)
            queues = normalizedQueues(queues)
            return queues.sorted { lhs, rhs in
                if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
                return lhs.createdAt < rhs.createdAt
            }
        }

        try migrateLegacyDisplayQueuesIfNeeded()
        if fileManager.fileExists(atPath: playbackQueuesURL.path) {
            let data = try Data(contentsOf: playbackQueuesURL)
            return normalizedQueues(try decoder.decode([PlaybackQueue].self, from: data))
                .sorted { lhs, rhs in
                    if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
                    return lhs.createdAt < rhs.createdAt
                }
        }
        return [PlaybackQueue.defaultQueue]
    }

    public func save(playbackQueues: [PlaybackQueue]) throws {
        try ensureLibraryDirectories()
        let normalized = normalizedQueues(playbackQueues)
        let data = try encoder.encode(normalized)
        try data.write(to: playbackQueuesURL, options: .atomic)
    }

    public func displayPlaybackBindings() throws -> [DisplayPlaybackBinding] {
        if fileManager.fileExists(atPath: displayPlaybackBindingsURL.path) {
            let data = try Data(contentsOf: displayPlaybackBindingsURL)
            return try decoder.decode([DisplayPlaybackBinding].self, from: data)
                .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        }

        try migrateLegacyDisplayQueuesIfNeeded()
        guard fileManager.fileExists(atPath: displayPlaybackBindingsURL.path) else { return [] }
        let data = try Data(contentsOf: displayPlaybackBindingsURL)
        return try decoder.decode([DisplayPlaybackBinding].self, from: data)
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    public func save(displayPlaybackBindings: [DisplayPlaybackBinding]) throws {
        try ensureLibraryDirectories()
        let data = try encoder.encode(displayPlaybackBindings)
        try data.write(to: displayPlaybackBindingsURL, options: .atomic)
    }

    private func normalizedQueues(_ queues: [PlaybackQueue]) -> [PlaybackQueue] {
        var result: [PlaybackQueue] = []
        var seenIDs = Set<UUID>()
        var hasDefault = false
        for value in queues {
            var queue = value
            queue.normalize()
            guard seenIDs.insert(queue.id).inserted else { continue }
            if queue.isDefault {
                if hasDefault { continue }
                hasDefault = true
            }
            result.append(queue)
        }
        if !hasDefault {
            result.insert(.defaultQueue, at: 0)
        }
        return result
    }

    private func migrateLegacyDisplayQueuesIfNeeded() throws {
        guard !fileManager.fileExists(atPath: playbackQueuesURL.path),
              !fileManager.fileExists(atPath: displayPlaybackBindingsURL.path),
              fileManager.fileExists(atPath: displayQueuesURL.path) else { return }

        let data = try Data(contentsOf: displayQueuesURL)
        let legacyQueues = try decoder.decode([DisplayPlaybackQueue].self, from: data)
        var queues: [PlaybackQueue] = [.defaultQueue]
        var bindings: [DisplayPlaybackBinding] = []
        var usedNames = Set<String>()

        for legacy in legacyQueues {
            var name = legacy.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { name = "显示器队列" }
            let baseName = name
            var suffix = 2
            while usedNames.contains(name) || name == PlaybackQueue.defaultName {
                name = "\(baseName) \(suffix)"
                suffix += 1
            }
            usedNames.insert(name)
            let queue = PlaybackQueue(
                name: name,
                wallpaperIDs: legacy.wallpaperIDs,
                defaultIntervalSeconds: legacy.normalizedIntervalSeconds,
                transition: legacy.transition
            )
            queues.append(queue)
            let state = DisplayQueueState(
                queueID: queue.id,
                currentIndex: legacy.currentIndex,
                isPlaying: legacy.isEnabled,
                isEnabled: legacy.isEnabled
            )
            bindings.append(DisplayPlaybackBinding(
                displayID: legacy.displayID,
                displayName: legacy.displayName,
                activeQueueID: queue.id,
                queueStates: [queue.id: state]
            ))
        }

        try ensureLibraryDirectories()
        try encoder.encode(queues).write(to: playbackQueuesURL, options: .atomic)
        try encoder.encode(bindings).write(to: displayPlaybackBindingsURL, options: .atomic)
    }

    public func displayQueues() throws -> [DisplayPlaybackQueue] {
        guard fileManager.fileExists(atPath: displayQueuesURL.path) else {
            return []
        }
        let data = try Data(contentsOf: displayQueuesURL)
        return try decoder.decode([DisplayPlaybackQueue].self, from: data).map { queue in
            var normalized = queue
            normalized.normalize()
            return normalized
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    public func save(displayQueues: [DisplayPlaybackQueue]) throws {
        try ensureLibraryDirectories()
        let normalized = displayQueues.map { queue -> DisplayPlaybackQueue in
            var queue = queue
            queue.normalize()
            return queue
        }
        let data = try encoder.encode(normalized)
        try data.write(to: displayQueuesURL, options: .atomic)
    }

    public func webEntryCandidates(at sourceURL: URL) -> [URL] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
            return []
        }
        if !isDirectory.boolValue {
            return [sourceURL].filter { ["html", "htm"].contains($0.pathExtension.lowercased()) }
        }
        guard let enumerator = fileManager.enumerator(
            at: sourceURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return enumerator.compactMap { candidate in
            guard let url = candidate as? URL,
                  ["html", "htm"].contains(url.pathExtension.lowercased()),
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true else {
                return nil
            }
            return url
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    @discardableResult
    public func importItem(at sourceURL: URL, storageMode: StorageMode, entryURL: URL? = nil) throws -> WallpaperItem {
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw WallpaperStoreError.sourceMissing(sourceURL)
        }
        guard let type = WallpaperType.detect(from: sourceURL, fileManager: fileManager) else {
            throw WallpaperStoreError.unsupportedSource(sourceURL)
        }

        try ensureLibraryDirectories()
        let id = UUID()
        let sourceIsDirectory = (try? sourceURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let managedCopySourceURL = type == .web && !sourceIsDirectory
            ? sourceURL.deletingLastPathComponent()
            : sourceURL
        let storedURL: URL

        switch storageMode {
        case .managedCopy:
            let assetsURL = libraryURL.appendingPathComponent("Assets", isDirectory: true)
            let destinationName = "\(id.uuidString)-\(managedCopySourceURL.lastPathComponent)"
            storedURL = assetsURL.appendingPathComponent(destinationName, isDirectory: managedCopySourceURL.hasDirectoryPath)
            try fileManager.copyItem(at: managedCopySourceURL, to: storedURL)
        case .externalReference:
            storedURL = sourceURL
        }

        var playbackURL: URL?
        do {
            let resolvedEntryURL: URL?
            if type == .web {
                let selectedEntry = entryURL ?? webEntryURL(for: sourceURL)
                let entryValidationRoot = storageMode == .managedCopy ? managedCopySourceURL : sourceURL
                guard let selectedEntry,
                      isValidWebEntry(selectedEntry, for: entryValidationRoot) else {
                    throw WallpaperStoreError.invalidHTMLEntry(sourceURL)
                }
                let relativePath = relativePath(of: selectedEntry, to: entryValidationRoot)
                let candidateURL = storageMode == .managedCopy
                    ? storedURL.appendingPathComponent(relativePath)
                    : selectedEntry
                guard fileManager.fileExists(atPath: candidateURL.path),
                      fileManager.isReadableFile(atPath: candidateURL.path) else {
                    throw WallpaperStoreError.invalidHTMLEntry(selectedEntry)
                }
                resolvedEntryURL = candidateURL
            } else {
                resolvedEntryURL = nil
            }

            if type == .video {
                playbackURL = try prepareVideoPlaybackURL(
                    sourceURL: storedURL,
                    storageMode: storageMode
                )
            }

            let item = WallpaperItem(
                id: id,
                name: displayName(for: sourceURL),
                type: type,
                sourceURL: storedURL,
                playbackURL: playbackURL,
                entryURL: resolvedEntryURL,
                storageMode: storageMode
            )
            var currentItems = try items()
            currentItems.append(item)
            try save(currentItems)
            return item
        } catch {
            if storageMode == .managedCopy, fileManager.fileExists(atPath: storedURL.path) {
                try? fileManager.removeItem(at: storedURL)
            }
            removePlaybackProxyIfOwned(at: playbackURL)
            throw error
        }
    }

    @discardableResult
    public func update(item: WallpaperItem) throws -> WallpaperItem {
        var currentItems = try items()
        guard let index = currentItems.firstIndex(where: { $0.id == item.id }) else {
            throw WallpaperStoreError.itemNotFound(item.id)
        }
        currentItems[index] = item
        try save(currentItems)
        return item
    }

    @discardableResult
    public func update(item: WallpaperItem, isFavorite: Bool) throws -> WallpaperItem {
        var updated = item
        updated.isFavorite = isFavorite
        return try update(item: updated)
    }

    /// Assigns several wallpapers to the same group while decoding and writing the
    /// wallpaper metadata only once. This keeps bulk context-menu actions from
    /// issuing a complete JSON read/write cycle for every selected item.
    @discardableResult
    public func assign(itemsWithIDs itemIDs: Set<UUID>, to groupID: UUID?) throws -> [WallpaperItem] {
        guard !itemIDs.isEmpty else { return [] }

        var currentItems = try items()
        let matchedIDs = Set(currentItems.lazy.map(\.id)).intersection(itemIDs)
        guard matchedIDs.count == itemIDs.count else {
            throw WallpaperStoreError.itemNotFound(itemIDs.subtracting(matchedIDs).first ?? UUID())
        }

        var updatedItems: [WallpaperItem] = []
        updatedItems.reserveCapacity(itemIDs.count)
        var didChange = false
        for index in currentItems.indices where itemIDs.contains(currentItems[index].id) {
            if currentItems[index].groupID != groupID {
                currentItems[index].groupID = groupID
                didChange = true
            }
            updatedItems.append(currentItems[index])
        }
        if didChange {
            try save(currentItems)
        }
        return updatedItems
    }

    @discardableResult
    public func relocate(item: WallpaperItem, to replacementURL: URL) throws -> WallpaperItem {
        guard fileManager.fileExists(atPath: replacementURL.path) else {
            throw WallpaperStoreError.sourceMissing(replacementURL)
        }
        guard let detectedType = WallpaperType.detect(from: replacementURL, fileManager: fileManager), detectedType == item.type else {
            throw WallpaperStoreError.unsupportedSource(replacementURL)
        }
        guard !fileManager.fileExists(atPath: item.sourceURL.path) else {
            throw WallpaperStoreError.permissionDenied(item.sourceURL)
        }

        let originalSourceURL = item.sourceURL
        let isOriginalDirectory = (try? originalSourceURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let relativeEntryPath: String? = {
            guard item.type == .web, let entryURL = item.entryURL, isOriginalDirectory else { return nil }
            return relativePath(of: entryURL, to: originalSourceURL)
        }()

        var updated = item
        var copiedReplacement = false
        var generatedPlaybackURL: URL?
        do {
            switch item.storageMode {
            case .managedCopy:
                try fileManager.createDirectory(at: item.sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: replacementURL, to: item.sourceURL)
                copiedReplacement = true
            case .externalReference:
                updated.sourceURL = replacementURL
            }

            if item.type == .video {
                let preparedPlaybackURL = try prepareVideoPlaybackURL(
                    sourceURL: updated.sourceURL,
                    storageMode: item.storageMode
                )
                updated.playbackURL = preparedPlaybackURL
                if preparedPlaybackURL != item.playbackURL {
                    generatedPlaybackURL = preparedPlaybackURL
                }
            }

            // The replacement may have different dimensions, duration, or artwork.
            // Force a fresh enrichment pass after relocation instead of showing stale metadata.
            removeThumbnailIfOwned(by: item)
            updated.metadata = nil
            updated.thumbnailURL = nil

            if item.type == .web {
                let baseURL = item.storageMode == .managedCopy ? item.sourceURL : replacementURL
                if let relativeEntryPath, !relativeEntryPath.isEmpty {
                    updated.entryURL = baseURL.appendingPathComponent(relativeEntryPath)
                } else if baseURL.hasDirectoryPath {
                    updated.entryURL = webEntryURL(for: baseURL)
                } else {
                    updated.entryURL = baseURL
                }
                guard let entryURL = updated.entryURL,
                      isValidWebEntry(entryURL, for: baseURL) else {
                    throw WallpaperStoreError.invalidHTMLEntry(baseURL)
                }
            }

            updated.availability = availability(for: updated)
            let persisted = try update(item: updated)
            if item.playbackURL != persisted.playbackURL {
                removePlaybackProxyIfOwned(at: item.playbackURL)
            }
            return persisted
        } catch {
            if copiedReplacement, fileManager.fileExists(atPath: item.sourceURL.path) {
                try? fileManager.removeItem(at: item.sourceURL)
            }
            if generatedPlaybackURL != item.playbackURL {
                removePlaybackProxyIfOwned(at: generatedPlaybackURL)
            }
            throw error
        }
    }

    @discardableResult
    public func remove(items selectedItems: [WallpaperItem]) throws -> [WallpaperItem] {
        guard !selectedItems.isEmpty else { return [] }
        var currentItems = try items()
        let selectedIDs = Set(selectedItems.map(\.id))
        let removedItems = currentItems.filter { selectedIDs.contains($0.id) }
        guard removedItems.count == selectedIDs.count else {
            let missingID = selectedIDs.subtracting(removedItems.map(\.id)).first ?? UUID()
            throw WallpaperStoreError.itemNotFound(missingID)
        }
        for item in removedItems {
            if item.storageMode == .managedCopy, fileManager.fileExists(atPath: item.sourceURL.path) {
                try fileManager.removeItem(at: item.sourceURL)
            }
            removeThumbnailIfOwned(by: item)
            removePlaybackProxyIfOwned(at: item.playbackURL)
        }
        currentItems.removeAll { selectedIDs.contains($0.id) }
        try save(currentItems)
        return removedItems
    }

    @discardableResult
    public func remove(item: WallpaperItem) throws -> WallpaperItem {
        var currentItems = try items()
        guard let index = currentItems.firstIndex(where: { $0.id == item.id }) else {
            throw WallpaperStoreError.itemNotFound(item.id)
        }
        currentItems.remove(at: index)
        if item.storageMode == .managedCopy, fileManager.fileExists(atPath: item.sourceURL.path) {
            try fileManager.removeItem(at: item.sourceURL)
        }
        removeThumbnailIfOwned(by: item)
        removePlaybackProxyIfOwned(at: item.playbackURL)
        try save(currentItems)
        return item
    }

    @discardableResult
    public func refreshAllAvailability() throws -> [WallpaperItem] {
        removeLegacyVideoProxies()
        let currentItems = try items()
        var refreshed: [WallpaperItem] = []
        refreshed.reserveCapacity(currentItems.count)
        var didChange = false
        for item in currentItems {
            var updated = item
            try refreshVideoPlaybackURL(for: &updated)
            updated.availability = availability(for: updated)
            didChange = didChange || updated != item
            refreshed.append(updated)
        }
        // Availability checks run during every library load. Avoiding an
        // atomic JSON rewrite when nothing changed substantially reduces disk
        // pressure for large libraries and external volumes.
        if didChange {
            try save(refreshed)
        }
        return refreshed.sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    public func refreshAvailability(for item: WallpaperItem) throws -> WallpaperItem {
        var currentItems = try items()
        guard let index = currentItems.firstIndex(where: { $0.id == item.id }) else {
            throw WallpaperStoreError.itemNotFound(item.id)
        }

        var refreshed = currentItems[index]
        try refreshVideoPlaybackURL(for: &refreshed)
        refreshed.availability = availability(for: refreshed)
        currentItems[index] = refreshed
        try save(currentItems)
        return refreshed
    }

    public func displayAssignments() throws -> [DisplayAssignment] {
        guard fileManager.fileExists(atPath: assignmentsURL.path) else {
            return []
        }
        let data = try Data(contentsOf: assignmentsURL)
        return try decoder.decode([DisplayAssignment].self, from: data)
    }

    public func save(displayAssignments: [DisplayAssignment]) throws {
        try ensureLibraryDirectories()
        let data = try encoder.encode(displayAssignments)
        try data.write(to: assignmentsURL, options: .atomic)
    }

    private func availability(for item: WallpaperItem) -> WallpaperAvailability {
        guard fileManager.fileExists(atPath: item.sourceURL.path) else {
            return .missing
        }
        guard fileManager.isReadableFile(atPath: item.sourceURL.path) else {
            return .permissionDenied
        }
        guard item.type == .web, let entryURL = item.entryURL else {
            return .available
        }
        guard fileManager.fileExists(atPath: entryURL.path) else {
            return .missing
        }
        return fileManager.isReadableFile(atPath: entryURL.path) ? .available : .permissionDenied
    }

    private func removeThumbnailIfOwned(by item: WallpaperItem) {
        guard let thumbnailURL = item.thumbnailURL else { return }
        let thumbnailDirectory = libraryURL.appendingPathComponent("Thumbnails", isDirectory: true).standardizedFileURL
        let candidate = thumbnailURL.standardizedFileURL
        let directoryPath = thumbnailDirectory.path.hasSuffix("/")
            ? thumbnailDirectory.path
            : thumbnailDirectory.path + "/"
        guard candidate.path.hasPrefix(directoryPath), fileManager.fileExists(atPath: candidate.path) else { return }
        try? fileManager.removeItem(at: candidate)
    }

    private func ensureLibraryDirectories() throws {
        let assetsURL = libraryURL.appendingPathComponent("Assets", isDirectory: true)
        try fileManager.createDirectory(at: assetsURL, withIntermediateDirectories: true)
    }

    /// Prepares the URL AVFoundation should open for a video wallpaper.
    /// Managed imports can be normalized in their library copy. External
    /// references always open the original file and never create persistent
    /// playback copies inside the wallpaper library.
    private func prepareVideoPlaybackURL(
        sourceURL: URL,
        storageMode: StorageMode
    ) throws -> URL? {
        switch storageMode {
        case .managedCopy:
            _ = try VideoContainerCompatibility.normalizeHVC1InPlace(at: sourceURL, fileManager: fileManager)
            return nil
        case .externalReference:
            return nil
        }
    }

    private func refreshVideoPlaybackURL(for item: inout WallpaperItem) throws {
        guard item.type == .video else { return }
        if item.storageMode == .externalReference {
            removePlaybackProxyIfOwned(at: item.playbackURL)
            item.playbackURL = nil
            return
        }

        removePlaybackProxyIfOwned(at: item.playbackURL)
        item.playbackURL = nil
        guard fileManager.fileExists(atPath: item.sourceURL.path),
              fileManager.isReadableFile(atPath: item.sourceURL.path) else { return }
        item.playbackURL = try prepareVideoPlaybackURL(
            sourceURL: item.sourceURL,
            storageMode: item.storageMode
        )
    }

    private func removeLegacyVideoProxies() {
        let proxiesURL = libraryURL.appendingPathComponent("VideoProxies", isDirectory: true)
        guard fileManager.fileExists(atPath: proxiesURL.path) else { return }
        try? fileManager.removeItem(at: proxiesURL)
    }

    private func removePlaybackProxyIfOwned(at url: URL?) {
        guard let url else { return }
        let proxiesURL = libraryURL.appendingPathComponent("VideoProxies", isDirectory: true).standardizedFileURL
        let candidate = url.standardizedFileURL
        let directoryPath = proxiesURL.path.hasSuffix("/") ? proxiesURL.path : proxiesURL.path + "/"
        guard candidate.path.hasPrefix(directoryPath), fileManager.fileExists(atPath: candidate.path) else { return }
        try? fileManager.removeItem(at: candidate)
    }

    private func save(_ items: [WallpaperItem]) throws {
        try ensureLibraryDirectories()
        let data = try encoder.encode(items)
        try data.write(to: metadataURL, options: .atomic)
    }

    private func displayName(for url: URL) -> String {
        if url.hasDirectoryPath {
            return url.lastPathComponent
        }
        return url.deletingPathExtension().lastPathComponent
    }

    private func webEntryURL(for url: URL) -> URL? {
        let candidates = webEntryCandidates(at: url)
        return candidates.first(where: { $0.lastPathComponent.lowercased() == "index.html" }) ?? candidates.first
    }

    private func isValidWebEntry(_ entryURL: URL, for sourceURL: URL) -> Bool {
        guard fileManager.fileExists(atPath: entryURL.path),
              fileManager.isReadableFile(atPath: entryURL.path),
              (try? entryURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true else {
            return false
        }
        guard sourceURL.hasDirectoryPath else {
            return entryURL.standardizedFileURL == sourceURL.standardizedFileURL
        }
        let basePath = sourceURL.standardizedFileURL.path
        let entryPath = entryURL.standardizedFileURL.path
        return entryPath.hasPrefix(basePath + "/")
            && ["html", "htm"].contains(entryURL.pathExtension.lowercased())
    }

    private func relativePath(of entryURL: URL, to sourceURL: URL) -> String {
        let base = sourceURL.standardizedFileURL.path
        let entry = entryURL.standardizedFileURL.path
        guard entry == base || entry.hasPrefix(base + "/") else {
            return entryURL.lastPathComponent
        }
        return String(entry.dropFirst(base.count + (entry == base ? 0 : 1)))
    }
}
