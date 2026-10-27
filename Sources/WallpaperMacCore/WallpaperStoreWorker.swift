import Foundation

/// A point-in-time view of the library metadata. File-system work is isolated
/// inside `WallpaperStoreWorker` so the SwiftUI main actor only receives the
/// already-decoded result.
public struct WallpaperLibrarySnapshot: Sendable {
    public let items: [WallpaperItem]
    public let groups: [WallpaperGroup]

    public init(items: [WallpaperItem], groups: [WallpaperGroup]) {
        self.items = items
        self.groups = groups
    }
}

/// Precomputed import information used by the import sheet. Keeping this data
/// out of SwiftUI's `body` prevents recursive directory enumeration whenever
/// the sheet redraws.
public struct WallpaperImportCandidate: Identifiable, Sendable {
    public let url: URL
    public let type: WallpaperType?

    public var id: URL { url }

    public init(url: URL, type: WallpaperType?) {
        self.url = url
        self.type = type
    }
}

public struct WallpaperImportInspection: Sendable {
    public let candidates: [WallpaperImportCandidate]
    public let webEntryCandidates: [URL]

    public init(candidates: [WallpaperImportCandidate], webEntryCandidates: [URL]) {
        self.candidates = candidates
        self.webEntryCandidates = webEntryCandidates
    }
}

public struct WallpaperImportResult: Sendable {
    public let snapshot: WallpaperLibrarySnapshot
    public let importedIDs: [UUID]
    public let failures: [String]

    public init(snapshot: WallpaperLibrarySnapshot, importedIDs: [UUID], failures: [String]) {
        self.snapshot = snapshot
        self.importedIDs = importedIDs
        self.failures = failures
    }
}

/// Serializes library file-system operations away from the main actor.
/// `WallpaperStore` intentionally remains synchronous for command-line tests
/// and services, while the macOS UI uses this actor for potentially expensive
/// directory scans, copies, deletes, and JSON writes.
public actor WallpaperStoreWorker {
    private var store: WallpaperStore

    public init(libraryURL: URL) {
        store = WallpaperStore(libraryURL: libraryURL)
    }

    public func changeLibrary(to libraryURL: URL) {
        store = WallpaperStore(libraryURL: libraryURL)
    }

    public func loadLibrary() throws -> WallpaperLibrarySnapshot {
        let items = try store.refreshAllAvailability()
        return WallpaperLibrarySnapshot(items: items, groups: try store.groups())
    }

    public func snapshot() throws -> WallpaperLibrarySnapshot {
        WallpaperLibrarySnapshot(items: try store.items(), groups: try store.groups())
    }

    public func inspectImportURLs(_ urls: [URL]) -> WallpaperImportInspection {
        let candidates = urls.map { url in
            WallpaperImportCandidate(url: url, type: WallpaperType.detect(from: url))
        }
        let webDirectories = candidates.compactMap { candidate -> URL? in
            guard candidate.type == .web, candidate.url.isExistingDirectory else { return nil }
            return candidate.url
        }
        let entries = webDirectories.count == 1
            ? store.webEntryCandidates(at: webDirectories[0])
            : []
        return WallpaperImportInspection(candidates: candidates, webEntryCandidates: entries)
    }

    public func importItems(
        at urls: [URL],
        entryURL: URL?,
        storageMode: StorageMode
    ) throws -> WallpaperImportResult {
        var importedIDs: [UUID] = []
        var failures: [String] = []
        importedIDs.reserveCapacity(urls.count)

        for url in urls {
            do {
                let selectedEntry = entryURL ?? preferredEntryURL(for: url)
                let item = try store.importItem(at: url, storageMode: storageMode, entryURL: selectedEntry)
                importedIDs.append(item.id)
            } catch {
                failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        return WallpaperImportResult(snapshot: try snapshot(), importedIDs: importedIDs, failures: failures)
    }

    public func createGroup(
        _ group: WallpaperGroup,
        assigning itemIDs: Set<UUID>
    ) throws -> WallpaperLibrarySnapshot {
        var groups = try store.groups()
        groups.append(group)
        try store.save(groups: groups)
        _ = try store.assign(itemsWithIDs: itemIDs, to: group.id)
        return try snapshot()
    }

    public func assign(itemsWithIDs itemIDs: Set<UUID>, to groupID: UUID?) throws -> WallpaperLibrarySnapshot {
        _ = try store.assign(itemsWithIDs: itemIDs, to: groupID)
        return try snapshot()
    }

    public func remove(items: [WallpaperItem]) throws -> WallpaperLibrarySnapshot {
        _ = try store.remove(items: items)
        return try snapshot()
    }

    public func relocate(item: WallpaperItem, to replacementURL: URL) throws -> WallpaperLibrarySnapshot {
        _ = try store.relocate(item: item, to: replacementURL)
        return try snapshot()
    }

    public func refreshAvailability(for item: WallpaperItem) throws -> WallpaperItem {
        try store.refreshAvailability(for: item)
    }

    public func save(items: [WallpaperItem]) throws {
        try store.save(items: items)
    }

    public func update(item: WallpaperItem) throws -> WallpaperItem {
        try store.update(item: item)
    }

    /// Field-level enrichment update: never accepts a full item array.
    public func updateMetadata(
        _ patches: [UUID: WallpaperStore.MetadataPatch]
    ) throws -> [WallpaperItem] {
        try store.updateMetadata(patches)
    }

    public func setFavorite(itemIDs: Set<UUID>, isFavorite: Bool) throws -> WallpaperLibrarySnapshot {
        guard !itemIDs.isEmpty else { return try snapshot() }
        var items = try store.items()
        var didChange = false
        for index in items.indices where itemIDs.contains(items[index].id) {
            guard items[index].isFavorite != isFavorite else { continue }
            items[index].isFavorite = isFavorite
            didChange = true
        }
        if didChange {
            try store.save(items: items)
        }
        return WallpaperLibrarySnapshot(items: items, groups: try store.groups())
    }

    private func preferredEntryURL(for url: URL) -> URL? {
        guard WallpaperType.detect(from: url) == .web else { return nil }
        let candidates = store.webEntryCandidates(at: url)
        return candidates.first(where: { $0.lastPathComponent.lowercased() == "index.html" }) ?? candidates.first
    }
}
