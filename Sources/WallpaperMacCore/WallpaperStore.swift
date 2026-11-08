import Foundation

public enum WallpaperStoreError: Error, LocalizedError, Equatable {
    case sourceMissing(URL)
    case unsupportedSource(URL)
    case itemNotFound(UUID)
    case permissionDenied(URL)
    case invalidHTMLEntry(URL)
    case invalidWebURL
    case queuePersistenceBlocked(String)

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
        case .invalidWebURL:
            return "请输入有效的 HTTP 或 HTTPS 网址，且不要包含账号密码。"
        case .queuePersistenceBlocked(let reason):
            return "播放队列文件读取失败，已暂停写入以避免覆盖原文件：\(reason)"
        }
    }
}

public enum PlaybackQueueFileState: Equatable, Sendable {
    case missing
    case loaded
    case failed(String)
}

public struct PlaybackQueueLoadResult: Equatable, Sendable {
    public let queues: [PlaybackQueue]
    public let bindings: [DisplayPlaybackBinding]
    public let queuesFile: PlaybackQueueFileState
    public let bindingsFile: PlaybackQueueFileState

    public var loadError: String? {
        if case .failed(let message) = queuesFile { return message }
        if case .failed(let message) = bindingsFile { return message }
        return nil
    }

    /// A read/decode failure means the in-memory fallback must never be
    /// written back over the user's original files.
    public var blocksPersistence: Bool { loadError != nil }
}

public final class WallpaperStore {
    public let libraryURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var queuePersistenceGate = LibraryPersistenceGate()

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

    private var displayProfilesURL: URL {
        libraryURL.appendingPathComponent("display-profiles.json")
    }

    private var hiddenWallpaperLockURL: URL {
        libraryURL.appendingPathComponent("hidden-wallpapers-lock.json")
    }

    private var migrationPlanURL: URL {
        libraryURL.appendingPathComponent("display-queue-migration-plan.json")
    }

    private var migrationMarkerURL: URL {
        libraryURL.appendingPathComponent("display-queues.migrated")
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
        try migrateLegacyDisplayQueuesIfNeeded()
        if fileManager.fileExists(atPath: playbackQueuesURL.path) {
            let data = try Data(contentsOf: playbackQueuesURL)
            var queues = try decoder.decode([PlaybackQueue].self, from: data)
            queues = normalizedQueues(queues)
            return queues.sorted { lhs, rhs in
                if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
                return lhs.createdAt < rhs.createdAt
            }
        }
        return [PlaybackQueue.defaultQueue]
    }

    public func save(playbackQueues: [PlaybackQueue]) throws {
        try ensureQueuePersistenceAllowed()
        try ensureLibraryDirectories()
        let normalized = normalizedQueues(playbackQueues)
        let data = try encoder.encode(normalized)
        try data.write(to: playbackQueuesURL, options: .atomic)
    }

    public func displayPlaybackBindings() throws -> [DisplayPlaybackBinding] {
        try migrateLegacyDisplayQueuesIfNeeded()
        guard fileManager.fileExists(atPath: displayPlaybackBindingsURL.path) else { return [] }
        let data = try Data(contentsOf: displayPlaybackBindingsURL)
        return try decoder.decode([DisplayPlaybackBinding].self, from: data)
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    public func save(displayPlaybackBindings: [DisplayPlaybackBinding]) throws {
        try ensureQueuePersistenceAllowed()
        try ensureLibraryDirectories()
        let data = try encoder.encode(displayPlaybackBindings)
        try data.write(to: displayPlaybackBindingsURL, options: .atomic)
    }

    public var isPlaybackQueuePersistenceBlocked: Bool {
        queuePersistenceGate.blocksPersistence
    }

    public var playbackQueuePersistenceError: String? {
        queuePersistenceGate.loadError
    }

    /// Loads both queue files as one recovery point and records whether a
    /// failed read must block all future writes. A missing file is a normal
    /// first-run state and stays writable; only a present-but-unreadable file
    /// blocks persistence.
    public func loadPlaybackQueueConfiguration() -> PlaybackQueueLoadResult {
        let queuesExisted = fileManager.fileExists(atPath: playbackQueuesURL.path)
        var queues: [PlaybackQueue] = [.defaultQueue]
        var queuesFile: PlaybackQueueFileState = .missing
        do {
            queues = try playbackQueues()
            queuesFile = queuesExisted ? .loaded : .missing
        } catch {
            queuesFile = .failed("无法读取播放队列：\(error.localizedDescription)")
        }

        let bindingsExisted = fileManager.fileExists(atPath: displayPlaybackBindingsURL.path)
        var bindings: [DisplayPlaybackBinding] = []
        var bindingsFile: PlaybackQueueFileState = .missing
        do {
            bindings = try displayPlaybackBindings()
            bindingsFile = bindingsExisted ? .loaded : .missing
        } catch {
            bindingsFile = .failed("无法读取显示器队列绑定：\(error.localizedDescription)")
        }

        let result = PlaybackQueueLoadResult(
            queues: queues,
            bindings: bindings,
            queuesFile: queuesFile,
            bindingsFile: bindingsFile
        )
        if let error = result.loadError {
            queuePersistenceGate.recordLoadFailure(error)
        } else {
            queuePersistenceGate.recordSuccessfulLoad()
        }
        return result
    }

    public func save(
        playbackQueues: [PlaybackQueue],
        displayPlaybackBindings: [DisplayPlaybackBinding]
    ) throws {
        try ensureQueuePersistenceAllowed()
        try save(playbackQueues: playbackQueues)
        try save(displayPlaybackBindings: displayPlaybackBindings)
    }

    private func ensureQueuePersistenceAllowed() throws {
        if let error = queuePersistenceGate.loadError {
            throw WallpaperStoreError.queuePersistenceBlocked(error)
        }
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

    /// Legacy `display-queues.json` migration with crash-safe commit protocol.
    ///
    /// Layout:
    /// - `display-queue-migration-plan.json` — full generated queues/bindings
    ///   (the mapping from legacy display IDs to queue UUIDs lives here).
    /// - `display-playback-bindings.json` then `playback-queues.json` — the
    ///   modern pair. Either may be missing after a crash; the plan restores it.
    /// - `display-queues.migrated` — commit marker. Modern files without a
    ///   marker are treated as an untrusted partial migration and can be
    ///   regenerated from the still-present legacy file.
    private func migrateLegacyDisplayQueuesIfNeeded() throws {
        if fileManager.fileExists(atPath: migrationMarkerURL.path) {
            return
        }

        // Resume an interrupted migration first: the plan already holds the
        // canonical queue UUIDs, so regenerating cannot orphan bindings.
        if fileManager.fileExists(atPath: migrationPlanURL.path) {
            try resumeMigrationFromPlan()
            return
        }

        guard fileManager.fileExists(atPath: displayQueuesURL.path) else {
            // No legacy source. If a complete modern pair already decodes,
            // record the marker so future loads skip this path.
            if validatesModernQueueFiles() {
                try commitMigration(removingLegacy: false)
            }
            return
        }

        let legacyQueues: [DisplayPlaybackQueue]?
        do {
            let data = try Data(contentsOf: displayQueuesURL)
            legacyQueues = try decoder.decode([DisplayPlaybackQueue].self, from: data)
        } catch {
            // Corrupt or unreadable legacy must not fail queue loading. Skip
            // migration and leave whatever modern files exist in place.
            NSLog("WallpaperMac: skipping legacy queue migration: \(error.localizedDescription)")
            legacyQueues = nil
        }

        // Users who migrated with an older build kept display-queues.json and
        // never wrote a marker — and may have edited queues/bindings since.
        // The validated modern pair is authoritative; only regenerate when it
        // is missing or fails cross-checks (an interrupted newer migration).
        // A non-empty legacy file paired with empty modern bindings is an
        // incomplete migration, not an authoritative modern state: retiring it
        // would silently drop every display's active queue and progress.
        if validatesModernQueueFiles(requiringBindingsFor: legacyQueues) {
            try commitMigration(removingLegacy: true)
            return
        }

        guard let legacyQueues else { return }

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
        let plan = MigrationPlan(queues: queues, bindings: bindings)
        try encoder.encode(plan).write(to: migrationPlanURL, options: .atomic)
        try writeMigrationOutputs(queues: queues, bindings: bindings)
        try commitMigration(removingLegacy: true)
    }

    private struct MigrationPlan: Codable {
        let queues: [PlaybackQueue]
        let bindings: [DisplayPlaybackBinding]
    }

    private func resumeMigrationFromPlan() throws {
        let data = try Data(contentsOf: migrationPlanURL)
        let plan = try decoder.decode(MigrationPlan.self, from: data)
        try writeMigrationOutputs(queues: plan.queues, bindings: plan.bindings)
        try commitMigration(removingLegacy: true)
    }

    private func writeMigrationOutputs(queues: [PlaybackQueue], bindings: [DisplayPlaybackBinding]) throws {
        try ensureLibraryDirectories()
        // Bindings first: a crash here leaves only the plan + legacy (or plan
        // alone), never a queues file that cannot be reconciled without it.
        try encoder.encode(bindings).write(to: displayPlaybackBindingsURL, options: .atomic)
        try encoder.encode(queues).write(to: playbackQueuesURL, options: .atomic)
    }

    private func commitMigration(removingLegacy: Bool) throws {
        try ensureLibraryDirectories()
        let stamp = ISO8601DateFormatter().string(from: Date())
        try Data("migrated \(stamp)\n".utf8).write(to: migrationMarkerURL, options: .atomic)
        try? fileManager.removeItem(at: migrationPlanURL)
        if removingLegacy {
            let retired = libraryURL.appendingPathComponent("display-queues.json.migrated")
            if fileManager.fileExists(atPath: displayQueuesURL.path) {
                try? fileManager.removeItem(at: retired)
                try? fileManager.moveItem(at: displayQueuesURL, to: retired)
            }
        }
    }

    /// True when both modern files decode and cross-reference cleanly.
    ///
    /// When a non-empty legacy queue file is still present, an empty modern
    /// bindings file cannot represent a completed migration: the legacy file
    /// is the only remaining source of per-display queue state. Treat that
    /// combination as incomplete so it is regenerated instead of retired.
    private func validatesModernQueueFiles(
        requiringBindingsFor legacyQueues: [DisplayPlaybackQueue]? = nil
    ) -> Bool {
        guard fileManager.fileExists(atPath: playbackQueuesURL.path),
              fileManager.fileExists(atPath: displayPlaybackBindingsURL.path) else {
            return false
        }
        guard let queueData = try? Data(contentsOf: playbackQueuesURL),
              let queues = try? decoder.decode([PlaybackQueue].self, from: queueData),
              let bindingData = try? Data(contentsOf: displayPlaybackBindingsURL),
              let bindings = try? decoder.decode([DisplayPlaybackBinding].self, from: bindingData) else {
            return false
        }
        if let legacyQueues, !legacyQueues.isEmpty, bindings.isEmpty {
            return false
        }
        let queueIDs = Set(queues.map(\.id))
        guard queues.contains(where: \.isDefault) else { return false }
        for binding in bindings {
            guard queueIDs.contains(binding.activeQueueID) else { return false }
            for state in binding.queueStates.values where !queueIDs.contains(state.queueID) {
                return false
            }
        }
        return true
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
    public func importWebURL(_ url: URL) throws -> WallpaperItem {
        guard WebWallpaperURL.isValid(url) else {
            throw WallpaperStoreError.invalidWebURL
        }
        try ensureLibraryDirectories()
        let item = WallpaperItem(
            name: url.host ?? url.absoluteString,
            type: .web,
            sourceURL: url,
            storageMode: .externalReference
        )
        var currentItems = try items()
        currentItems.append(item)
        try save(currentItems)
        return item
    }

    @discardableResult
    public func importItem(at sourceURL: URL, storageMode: StorageMode, entryURL: URL? = nil) throws -> WallpaperItem {
        guard sourceURL.isFileURL else {
            throw WallpaperStoreError.unsupportedSource(sourceURL)
        }
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw WallpaperStoreError.sourceMissing(sourceURL)
        }
        guard let type = WallpaperType.detect(from: sourceURL, fileManager: fileManager) else {
            throw WallpaperStoreError.unsupportedSource(sourceURL)
        }

        try ensureLibraryDirectories()
        let id = UUID()
        let sourceIsDirectory = (try? sourceURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        // A single HTML file is not a project directory. Never copy or grant
        // its parent implicitly; relative resources require an explicit folder.
        let managedCopySourceURL = sourceURL
        let storedURL: URL

        switch storageMode {
        case .managedCopy:
            let assetsURL = libraryURL.appendingPathComponent("Assets", isDirectory: true)
            let destinationName = "\(id.uuidString)-\(managedCopySourceURL.lastPathComponent)"
            storedURL = assetsURL.appendingPathComponent(destinationName, isDirectory: managedCopySourceURL.isExistingDirectory)
            try fileManager.copyItem(at: managedCopySourceURL, to: storedURL)
        case .externalReference:
            storedURL = sourceURL
        }

        var playbackURL: URL?
        var relativeEntryPath: String?
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
                let isProjectDirectory = storageMode == .managedCopy
                    ? managedCopySourceURL.isExistingDirectory
                    : sourceIsDirectory
                relativeEntryPath = isProjectDirectory && !relativePath.isEmpty ? relativePath : nil
                let candidateURL: URL
                if storageMode == .managedCopy {
                    candidateURL = managedCopySourceURL.isExistingDirectory
                        ? storedURL.appendingPathComponent(relativePath)
                        : storedURL
                } else {
                    candidateURL = selectedEntry
                }
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
                relativeEntryPath: relativeEntryPath,
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

    /// Changes only the fit override so a concurrent metadata enrichment or
    /// last-used update cannot be clobbered by a stale whole-item snapshot.
    @discardableResult
    public func updateFitModeOverride(
        id: UUID,
        mode: WallpaperFitMode?
    ) throws -> WallpaperItem {
        var currentItems = try items()
        guard let index = currentItems.firstIndex(where: { $0.id == id }) else {
            throw WallpaperStoreError.itemNotFound(id)
        }
        guard currentItems[index].fitModeOverride != mode else {
            return currentItems[index]
        }
        currentItems[index].fitModeOverride = mode
        try save(currentItems)
        return currentItems[index]
    }

    /// Field-level last-used update; never writes a stale whole-item snapshot.
    @discardableResult
    public func touchLastUsed(id: UUID, date: Date = Date()) throws -> WallpaperItem {
        var currentItems = try items()
        guard let index = currentItems.firstIndex(where: { $0.id == id }) else {
            throw WallpaperStoreError.itemNotFound(id)
        }
        currentItems[index].lastUsedAt = date
        try save(currentItems)
        return currentItems[index]
    }

    /// Field-level hidden flag update. Keeping this separate from a full item
    /// snapshot prevents concurrent metadata/favorite edits from being lost.
    @discardableResult
    public func updateHidden(id: UUID, isHidden: Bool) throws -> WallpaperItem {
        var currentItems = try items()
        guard let index = currentItems.firstIndex(where: { $0.id == id }) else {
            throw WallpaperStoreError.itemNotFound(id)
        }
        guard currentItems[index].isHidden != isHidden else {
            return currentItems[index]
        }
        currentItems[index].isHidden = isHidden
        try save(currentItems)
        return currentItems[index]
    }

    public func hiddenWallpaperLock() throws -> HiddenWallpaperLock? {
        guard fileManager.fileExists(atPath: hiddenWallpaperLockURL.path) else { return nil }
        let data = try Data(contentsOf: hiddenWallpaperLockURL)
        return try decoder.decode(HiddenWallpaperLock.self, from: data)
    }

    public func save(hiddenWallpaperLock: HiddenWallpaperLock) throws {
        try ensureLibraryDirectories()
        let data = try encoder.encode(hiddenWallpaperLock)
        try data.write(to: hiddenWallpaperLockURL, options: .atomic)
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: hiddenWallpaperLockURL.path
        )
    }

    /// Patches only enrichment fields for several items in one read-modify-write.
    ///
    /// Callers must not hand over a full item array: the array is often a stale
    /// UI snapshot that would clobber renames, favorites and imports written
    /// after it was taken.
    @discardableResult
    public func updateMetadata(
        _ patches: [UUID: MetadataPatch]
    ) throws -> [WallpaperItem] {
        guard !patches.isEmpty else { return [] }
        var currentItems = try items()
        var updated: [WallpaperItem] = []
        for index in currentItems.indices {
            guard let patch = patches[currentItems[index].id] else { continue }
            if let metadata = patch.metadata {
                currentItems[index].metadata = metadata
            }
            if let thumbnailURL = patch.thumbnailURL {
                currentItems[index].thumbnailURL = thumbnailURL
            }
            updated.append(currentItems[index])
        }
        guard !updated.isEmpty else { return [] }
        try save(currentItems)
        return updated
    }

    public struct MetadataPatch: Equatable, Sendable {
        public var metadata: WallpaperMetadata?
        public var thumbnailURL: URL?

        public init(metadata: WallpaperMetadata? = nil, thumbnailURL: URL? = nil) {
            self.metadata = metadata
            self.thumbnailURL = thumbnailURL
        }
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

        let relativeEntryPath: String? = {
            guard item.type == .web else { return nil }
            if let stored = item.relativeEntryPath?.trimmingCharacters(in: .whitespacesAndNewlines),
               !stored.isEmpty {
                return stored
            }
            // Legacy records predate `relativeEntryPath`: derive it from the
            // old URLs by string comparison. The original directory may
            // already be gone, so do not consult the file system here.
            return storedRelativeEntryPath(for: item)
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
                    let candidateURL = baseURL.appendingPathComponent(relativeEntryPath)
                    // Never silently switch to index.html: if the replacement
                    // lacks the user's original entry, report it and let the
                    // caller re-select instead of persisting a different page.
                    guard isValidWebEntry(candidateURL, for: baseURL) else {
                        throw WallpaperStoreError.invalidHTMLEntry(candidateURL)
                    }
                    updated.entryURL = candidateURL
                } else if baseURL.isExistingDirectory {
                    updated.entryURL = webEntryURL(for: baseURL)
                } else {
                    updated.entryURL = baseURL
                }
                updated.relativeEntryPath = relativeEntryPath
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
        // Index first: if a later file delete fails the entry is still gone,
        // leaving only reclaimable orphan files rather than phantom rows.
        currentItems.removeAll { selectedIDs.contains($0.id) }
        try save(currentItems)
        for item in removedItems {
            removeManagedResources(for: item)
        }
        return removedItems
    }

    @discardableResult
    public func remove(item: WallpaperItem) throws -> WallpaperItem {
        var currentItems = try items()
        guard let index = currentItems.firstIndex(where: { $0.id == item.id }) else {
            throw WallpaperStoreError.itemNotFound(item.id)
        }
        currentItems.remove(at: index)
        try save(currentItems)
        removeManagedResources(for: item)
        return item
    }

    /// Best-effort resource cleanup after the index no longer references the item.
    /// Failures are logged as orphans; they must not roll back the index write.
    private func removeManagedResources(for item: WallpaperItem) {
        if item.sourceURL.isFileURL,
           item.storageMode == .managedCopy,
           fileManager.fileExists(atPath: item.sourceURL.path) {
            do {
                try fileManager.removeItem(at: item.sourceURL)
            } catch {
                NSLog("WallpaperMac: orphaned managed asset \(item.sourceURL.path): \(error.localizedDescription)")
            }
        }
        removeThumbnailIfOwned(by: item)
        removePlaybackProxyIfOwned(at: item.playbackURL)
    }

    @discardableResult
    public func refreshAllAvailability() throws -> [WallpaperItem] {
        removeLegacyVideoProxies()
        cleanupOrphanedManagedAssets()
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

    /// Stable display profiles. A missing file means the library has not been
    /// migrated yet; the caller should run the legacy migrator.
    public func displayProfilesDocument() throws -> DisplayProfileDocument? {
        guard fileManager.fileExists(atPath: displayProfilesURL.path) else { return nil }
        let data = try Data(contentsOf: displayProfilesURL)
        return try decoder.decode(DisplayProfileDocument.self, from: data)
    }

    public func save(displayProfilesDocument: DisplayProfileDocument) throws {
        try ensureLibraryDirectories()
        let data = try encoder.encode(displayProfilesDocument)
        try data.write(to: displayProfilesURL, options: .atomic)
    }

    private func availability(for item: WallpaperItem) -> WallpaperAvailability {
        if !item.sourceURL.isFileURL {
            return item.type == .web && WebWallpaperURL.isValid(item.sourceURL) ? .available : .unsupported
        }
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

    /// Removes managed assets under `Assets/` whose `{UUID}-` prefix matches no
    /// indexed item. Scope is strictly that ownership namespace — user files
    /// and external references are never touched.
    private func cleanupOrphanedManagedAssets() {
        let assetsURL = libraryURL.appendingPathComponent("Assets", isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: assetsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        let knownIDs: Set<String>
        do {
            knownIDs = Set(try items().map { $0.id.uuidString })
        } catch {
            return
        }

        for entry in entries {
            let name = entry.lastPathComponent
            // Ownership marker: `{UUID}-originalName` (see import destinationName).
            // UUID strings contain hyphens themselves (8-4-4-4-12 = 36 chars),
            // so the prefix is the first 36 characters, not up to the first '-'.
            guard name.count > 36 else { continue }
            let uuidPrefix = String(name.prefix(36))
            guard name.hasPrefix(uuidPrefix), name.dropFirst(36).hasPrefix("-") else { continue }
            guard UUID(uuidString: uuidPrefix) != nil, !knownIDs.contains(uuidPrefix) else { continue }
            do {
                try fileManager.removeItem(at: entry)
                NSLog("WallpaperMac: removed orphaned managed asset \(name)")
            } catch {
                NSLog("WallpaperMac: failed to remove orphaned asset \(name): \(error.localizedDescription)")
            }
        }
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
        if url.isExistingDirectory {
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
        guard sourceURL.isExistingDirectory else {
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

    /// Derives a project-relative entry path from already-persisted URLs.
    /// Uses string paths only so it works after the original directory is gone.
    private func storedRelativeEntryPath(for item: WallpaperItem) -> String? {
        guard item.type == .web, let entryURL = item.entryURL else { return nil }
        let base = item.sourceURL.standardizedFileURL.path
        let entry = entryURL.standardizedFileURL.path
        guard entry != base else { return nil }
        let basePrefix = base.hasSuffix("/") ? base : base + "/"
        guard entry.hasPrefix(basePrefix) else { return nil }
        let relative = String(entry.dropFirst(basePrefix.count))
        return relative.isEmpty ? nil : relative
    }
}
