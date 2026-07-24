import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import WallpaperMacCore

enum SidebarDestination: Hashable {
    case all
    case images
    case videos
    case web
    case favorites
    case recent
    case queueLibrary
    case group(UUID)
    case display(String)
}

enum WallpaperStatusFilter: String, CaseIterable, Identifiable {
    case all
    case applied
    case unapplied
    case unavailable

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "全部状态"
        case .applied: return "已应用"
        case .unapplied: return "未应用"
        case .unavailable: return "失效资源"
        }
    }
}

enum WallpaperSortOrder: String, CaseIterable, Identifiable {
    case recentlyAdded
    case recentlyUsed
    case name

    var id: String { rawValue }
    var title: String {
        switch self {
        case .recentlyAdded: return "最近添加"
        case .recentlyUsed: return "最近使用"
        case .name: return "名称"
        }
    }
}

enum LibraryLayout: String, CaseIterable, Identifiable {
    case grid
    case list

    var id: String { rawValue }
    var title: String { self == .grid ? "网格" : "列表" }
    var icon: String { self == .grid ? "square.grid.2x2" : "list.bullet" }
}

struct DisplayRow: Identifiable, Equatable {
    let id: String
    let name: String
    let isConnected: Bool
    let applicationState: ApplicationState
}

struct ImportSummary: Identifiable {
    let id = UUID()
    let importedCount: Int
    let failures: [String]

    var title: String {
        failures.isEmpty ? "导入完成" : (importedCount > 0 ? "部分导入完成" : "导入失败")
    }

    var message: String {
        var lines: [String] = []
        if importedCount > 0 {
            lines.append("已成功导入 \(importedCount) 项壁纸。")
        }
        if !failures.isEmpty {
            lines.append("失败项目：")
            lines.append(contentsOf: failures)
        }
        return lines.joined(separator: "\n")
    }
}

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published private(set) var wallpapers: [WallpaperItem] = []
    @Published private(set) var visibleWallpapers: [WallpaperItem] = []
    @Published private(set) var groups: [WallpaperGroup] = []
    @Published var selectedWallpaperID: UUID?
    @Published var selectedWallpaperIDs: Set<UUID> = []
    @Published var isSelectionMode = false
    @Published var isNewGroupSheetPresented = false
    @Published var isQueueEditorPresented = false
    @Published var queueEditorDisplayID: String?
    @Published var isQueueManagementPresented = false
    @Published var isNewQueueSheetPresented = false
    @Published var pendingDeleteIDs: Set<UUID> = []
    @Published var isDeleteConfirmationPresented = false
    @Published var toastMessage: String?
    @Published var destination: SidebarDestination = .all { didSet { resetPagination() } }
    @Published var searchText = "" { didSet { resetPagination() } }
    @Published var selectedType: WallpaperType? { didSet { resetPagination() } }
    @Published var statusFilter: WallpaperStatusFilter = .all { didSet { resetPagination() } }
    @Published var sortOrder: WallpaperSortOrder = .recentlyAdded { didSet { resetPagination() } }
    @Published var layout: LibraryLayout = .grid
    @Published var lastError: String?
    @Published private(set) var libraryURL: URL
    @Published var storageMode: StorageMode
    @Published var playbackPolicy: PlaybackPolicy
    @Published var isDropTargeted = false
    @Published var isImporting = false
    @Published var pendingImportURLs: [URL] = []
    @Published private(set) var pendingImportCandidates: [WallpaperImportCandidate] = []
    @Published private(set) var pendingWebEntryCandidates: [URL] = []
    @Published private(set) var isImportInspectionInProgress = false
    @Published var importSummary: ImportSummary?

    private(set) var store: WallpaperStore
    private var storeWorker: WallpaperStoreWorker
    let displayService = DisplayService()
    let wallpaperManager = WallpaperManager()
    private var settingsObserver: NSObjectProtocol?
    private var statusBarObservers: [NSObjectProtocol] = []
    private var observationCancellables = Set<AnyCancellable>()
    private let libraryAccess: WallpaperLibraryAccess
    private var shouldCreateMissingLibraryDirectory: Bool
    private var pendingGroupAssignmentIDs: Set<UUID> = []
    private var pendingQueueAssignmentIDs: Set<UUID> = []
    private var undoOperation: (() -> Void)?
    private var metadataEnrichmentTask: Task<Void, Never>?
    private var metadataEnrichmentGeneration = 0
    private var libraryLoadTask: Task<Void, Never>?
    private var libraryLoadGeneration = 0
    private static let pageSize = WallpaperLibraryPagination.defaultPageSize

    init() {
        let defaults = UserDefaults.standard
        let defaultLibraryURL = Self.defaultLibraryURL
        let configuredPath = defaults.string(forKey: SettingsKey.libraryPath)
        let access = WallpaperLibraryAccess(configurationDirectory: Self.configurationDirectory)
        libraryAccess = access
        let resolvedURL = access.restore(defaultURL: defaultLibraryURL, persistedPath: configuredPath)
        shouldCreateMissingLibraryDirectory = configuredPath == nil
            || resolvedURL.standardizedFileURL == defaultLibraryURL.standardizedFileURL
        libraryURL = resolvedURL
        if configuredPath == nil {
            defaults.set(resolvedURL.path, forKey: SettingsKey.libraryPath)
        }
        store = WallpaperStore(libraryURL: resolvedURL)
        storeWorker = WallpaperStoreWorker(libraryURL: resolvedURL)
        storageMode = StorageMode(rawValue: defaults.string(forKey: SettingsKey.storageMode) ?? "") ?? .managedCopy
        playbackPolicy = PlaybackPolicy(
            isMuted: defaults.object(forKey: SettingsKey.muted) as? Bool ?? true,
            loops: defaults.object(forKey: SettingsKey.loops) as? Bool ?? true,
            pauseOnBattery: defaults.object(forKey: SettingsKey.pauseOnBattery) as? Bool ?? false,
            pauseInFullScreenApps: defaults.object(forKey: SettingsKey.pauseInFullScreen) as? Bool ?? false,
            fitMode: WallpaperFitMode(rawValue: defaults.string(forKey: SettingsKey.fitMode) ?? "") ?? .fill
        )
        wallpaperManager.configure(store: store, policy: playbackPolicy)
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .wallpaperMacSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applySettingsFromDefaults()
            }
        }
        let center = NotificationCenter.default
        statusBarObservers = [
            center.addObserver(forName: .wallpaperMacStatusTogglePlayback, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.toggleAllPlayback() }
            },
            center.addObserver(forName: .wallpaperMacStatusToggleMute, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.toggleAllMute() }
            }
        ]
        reload(afterLoad: restoreWallpaperAssignments)
        wallpaperManager.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &observationCancellables)
        displayService.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &observationCancellables)
    }

    deinit {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
        statusBarObservers.forEach(NotificationCenter.default.removeObserver)
        metadataEnrichmentTask?.cancel()
        libraryLoadTask?.cancel()
    }

    static var configurationDirectory: URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return applicationSupport
            .appendingPathComponent("WallpaperMac", isDirectory: true)
            .appendingPathComponent("Configuration", isDirectory: true)
    }

    static var defaultLibraryURL: URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return applicationSupport
            .appendingPathComponent("WallpaperMac", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
    }

    var libraryPermissionState: (readable: Bool, writable: Bool) {
        let fm = FileManager.default
        let path = libraryURL.path
        let parent = libraryURL.deletingLastPathComponent()
        let readable = fm.fileExists(atPath: path) ? fm.isReadableFile(atPath: path) : fm.isReadableFile(atPath: parent.path)
        let writable = fm.fileExists(atPath: path) ? fm.isWritableFile(atPath: path) : fm.isWritableFile(atPath: parent.path)
        return (readable, writable)
    }

    func prepareLibrary() {
        do {
            if !FileManager.default.fileExists(atPath: libraryURL.path), !shouldCreateMissingLibraryDirectory {
                lastError = "壁纸库目录不可用：\(libraryURL.path)。请重新选择壁纸库位置，原有壁纸记录不会被删除。"
                return
            }
            try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
            try libraryAccess.persist(url: libraryURL)
            UserDefaults.standard.set(libraryURL.path, forKey: SettingsKey.libraryPath)
            reload(afterLoad: restoreWallpaperAssignments)
        } catch {
            lastError = error.localizedDescription
        }
    }

    var selectedWallpaper: WallpaperItem? {
        guard let selectedWallpaperID else { return nil }
        return wallpapers.first { $0.id == selectedWallpaperID }
    }

    var displayRows: [DisplayRow] {
        let assignments = Dictionary(uniqueKeysWithValues: wallpaperManager.displayAssignments.map { ($0.id, $0) })
        let connectedRows = displayService.displays.map { display in
            DisplayRow(
                id: display.id,
                name: display.name,
                isConnected: true,
                applicationState: assignments[display.id]?.applicationState ?? .idle
            )
        }
        let connectedIDs = Set(connectedRows.map(\.id))
        let disconnectedRows = wallpaperManager.displayAssignments
            .filter { !connectedIDs.contains($0.id) }
            .map { assignment in
                DisplayRow(
                    id: assignment.id,
                    name: assignment.displayName,
                    isConnected: false,
                    applicationState: assignment.applicationState
                )
            }
        return connectedRows + disconnectedRows
    }

    var filteredWallpapers: [WallpaperItem] {
        let filtered = wallpapers.filter { item in
            let matchesSearch = searchText.isEmpty || item.name.localizedCaseInsensitiveContains(searchText)
            let matchesType = selectedType == nil || item.type == selectedType
            let isApplied = wallpaperManager.appliedWallpaperIDs.values.contains(item.id)
            let matchesStatus: Bool
            switch statusFilter {
            case .all: matchesStatus = true
            case .applied: matchesStatus = isApplied
            case .unapplied: matchesStatus = !isApplied
            case .unavailable: matchesStatus = item.availability != .available
            }
            let matchesDestination: Bool
            switch destination {
            case .all:
                matchesDestination = true
            case .display(let displayID):
                matchesDestination = wallpaperManager.displayAssignments.first(where: { $0.id == displayID })?.wallpaperID == item.id
            case .recent:
                matchesDestination = item.lastUsedAt != nil
            case .queueLibrary:
                matchesDestination = true
            case .group(let groupID):
                matchesDestination = item.groupID == groupID
            case .images:
                matchesDestination = item.type == .image
            case .videos:
                matchesDestination = item.type == .video
            case .web:
                matchesDestination = item.type == .web
            case .favorites:
                matchesDestination = item.isFavorite
            }
            return matchesSearch && matchesType && matchesStatus && matchesDestination
        }
        return filtered.sorted { lhs, rhs in
            switch sortOrder {
            case .recentlyAdded:
                return lhs.createdAt > rhs.createdAt
            case .recentlyUsed:
                return (lhs.lastUsedAt ?? .distantPast) > (rhs.lastUsedAt ?? .distantPast)
            case .name:
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }

    /// Reconciles persisted display assignments after each completed library load.
    ///
    /// A launch normally triggers more than one `prepareLibrary()` call while SwiftUI
    /// builds the root view. Keeping restoration inside the successful reload callback
    /// prevents a later reload from cancelling the only task responsible for starting
    /// persisted display queues.
    private func restoreWallpaperAssignments() {
        wallpaperManager.restoreAssignments(
            to: displayService.displays,
            policy: playbackPolicy,
            items: wallpapers
        )
    }

    func reload(afterLoad: (() -> Void)? = nil) {
        metadataEnrichmentTask?.cancel()
        metadataEnrichmentGeneration += 1
        libraryLoadGeneration += 1
        let metadataGeneration = metadataEnrichmentGeneration
        let loadGeneration = libraryLoadGeneration
        let worker = storeWorker
        libraryLoadTask?.cancel()
        libraryLoadTask = Task { [weak self] in
            do {
                let snapshot = try await worker.loadLibrary()
                guard !Task.isCancelled,
                      let self,
                      self.libraryLoadGeneration == loadGeneration else { return }
                self.applyLibrarySnapshot(snapshot)
                self.startMetadataEnrichment(for: snapshot.items, generation: metadataGeneration)
                afterLoad?()
            } catch {
                guard !Task.isCancelled, let self, self.libraryLoadGeneration == loadGeneration else { return }
                self.lastError = error.localizedDescription
                self.visibleWallpapers = []
            }
        }
    }

    private func applyLibrarySnapshot(_ snapshot: WallpaperLibrarySnapshot) {
        wallpapers = snapshot.items
        groups = snapshot.groups
        resetPagination()
        let validIDs = Set(wallpapers.map(\.id))
        selectedWallpaperIDs = selectedWallpaperIDs.intersection(validIDs)
        if let selectedWallpaperID, !validIDs.contains(selectedWallpaperID) {
            self.selectedWallpaperID = nil
        }
    }

    private func applyMutationSnapshot(_ snapshot: WallpaperLibrarySnapshot, enrichMetadata: Bool = true) {
        metadataEnrichmentTask?.cancel()
        metadataEnrichmentGeneration += 1
        let generation = metadataEnrichmentGeneration
        applyLibrarySnapshot(snapshot)
        guard enrichMetadata else { return }
        startMetadataEnrichment(for: snapshot.items, generation: generation)
    }

    func loadNextPageIfNeeded(currentItem item: WallpaperItem) {
        guard let lastVisibleID = visibleWallpapers.last?.id, lastVisibleID == item.id else { return }
        let nextCount = WallpaperLibraryPagination.nextLoadedCount(
            currentCount: visibleWallpapers.count,
            totalCount: filteredWallpapers.count,
            pageSize: Self.pageSize
        )
        guard nextCount > visibleWallpapers.count else { return }
        visibleWallpapers = WallpaperLibraryPagination.page(
            from: filteredWallpapers,
            loadedCount: nextCount,
            pageSize: Self.pageSize
        )
    }

    private func resetPagination() {
        visibleWallpapers = WallpaperLibraryPagination.page(
            from: filteredWallpapers,
            loadedCount: Self.pageSize,
            pageSize: Self.pageSize
        )
    }

    private func refreshVisibleWallpapersPreservingLoadedCount(_ loadedCount: Int) {
        visibleWallpapers = WallpaperLibraryPagination.page(
            from: filteredWallpapers,
            loadedCount: loadedCount,
            pageSize: Self.pageSize
        )
    }

    private func startMetadataEnrichment(for items: [WallpaperItem], generation: Int) {
        let libraryURL = self.libraryURL
        let candidates = items.filter { item in
            guard item.availability == .available else { return false }
            guard let metadata = item.metadata else { return true }
            guard metadata.fileSizeBytes != nil, metadata.fileExtension != nil else { return true }
            switch item.type {
            case .image:
                return metadata.pixelWidth == nil || metadata.pixelHeight == nil
            case .video:
                return metadata.pixelWidth == nil
                    || metadata.pixelHeight == nil
                    || metadata.durationSeconds == nil
                    || item.thumbnailURL == nil
                    || !FileManager.default.fileExists(atPath: item.thumbnailURL!.path)
            case .web:
                return false
            }
        }
        guard !candidates.isEmpty else { return }

        metadataEnrichmentTask = Task { [weak self] in
            let enriched = await Task.detached(priority: .utility) {
                var results: [WallpaperItem] = []
                results.reserveCapacity(candidates.count)
                for item in candidates {
                    if Task.isCancelled { return results }
                    if let updated = await WallpaperResourceMetadataService.enrich(item: item, libraryURL: libraryURL) {
                        results.append(updated)
                    }
                }
                return results
            }.value

            guard !Task.isCancelled, let self, self.metadataEnrichmentGeneration == generation else { return }
            guard !enriched.isEmpty else { return }

            let loadedCount = self.visibleWallpapers.count
            var mergedItems = self.wallpapers
            var changed = false
            for enrichedItem in enriched {
                guard let index = mergedItems.firstIndex(where: { current in
                    current.id == enrichedItem.id && current.sourceURL == enrichedItem.sourceURL && current.entryURL == enrichedItem.entryURL
                }) else { continue }
                var current = mergedItems[index]
                if current.metadata != enrichedItem.metadata || current.thumbnailURL != enrichedItem.thumbnailURL {
                    current.metadata = enrichedItem.metadata
                    current.thumbnailURL = enrichedItem.thumbnailURL
                    mergedItems[index] = current
                    changed = true
                }
            }
            guard changed else { return }
            do {
                try await self.storeWorker.save(items: mergedItems)
                guard !Task.isCancelled, self.metadataEnrichmentGeneration == generation else { return }
                self.wallpapers = mergedItems
                self.refreshVisibleWallpapersPreservingLoadedCount(loadedCount)
            } catch {
                self.lastError = "保存资源信息失败：\(error.localizedDescription)"
            }
        }
    }

    func toggleSelection(for item: WallpaperItem) {
        if selectedWallpaperIDs.contains(item.id) {
            selectedWallpaperIDs.remove(item.id)
        } else {
            selectedWallpaperIDs.insert(item.id)
        }
    }

    func selectAllFiltered() {
        selectedWallpaperIDs.formUnion(filteredWallpapers.map(\.id))
    }

    func clearSelection() {
        selectedWallpaperIDs.removeAll()
    }

    func createGroup(named name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        guard !groups.contains(where: { $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame }) else {
            lastError = "已经存在同名分组。"
            return
        }
        let group = WallpaperGroup(name: trimmedName)
        let assignmentIDs = pendingGroupAssignmentIDs
        let worker = storeWorker
        Task { [weak self] in
            do {
                let snapshot = try await worker.createGroup(group, assigning: assignmentIDs)
                guard let self else { return }
                self.pendingGroupAssignmentIDs.removeAll()
                self.applyMutationSnapshot(snapshot, enrichMetadata: false)
            } catch {
                self?.lastError = error.localizedDescription
            }
        }
    }

    func beginCreateGroup(for ids: Set<UUID>) {
        pendingGroupAssignmentIDs = ids
        isNewGroupSheetPresented = true
    }

    func assignSelected(to groupID: UUID?) {
        assignWallpapers(selectedWallpaperIDs, to: groupID)
    }

    func assignWallpapers(_ ids: Set<UUID>, to groupID: UUID?) {
        let selectedIDs = Set(wallpapers.lazy.map(\.id)).intersection(ids)
        guard !selectedIDs.isEmpty else { return }
        let worker = storeWorker
        Task { [weak self] in
            do {
                let snapshot = try await worker.assign(itemsWithIDs: selectedIDs, to: groupID)
                self?.applyMutationSnapshot(snapshot, enrichMetadata: false)
            } catch {
                self?.lastError = error.localizedDescription
            }
        }
    }

    func removeSelectedWallpapers() {
        let selectedItems = wallpapers.filter { selectedWallpaperIDs.contains($0.id) }
        guard !selectedItems.isEmpty else { return }
        let selectedIDs = Set(selectedItems.map(\.id))
        wallpaperManager.removeWallpaperIDs(selectedIDs)
        let worker = storeWorker
        Task { [weak self] in
            do {
                let snapshot = try await worker.remove(items: selectedItems)
                guard let self else { return }
                self.selectedWallpaperIDs.subtract(selectedIDs)
                if let selectedWallpaperID, selectedIDs.contains(selectedWallpaperID) {
                    self.selectedWallpaperID = nil
                }
                self.applyMutationSnapshot(snapshot, enrichMetadata: false)
            } catch {
                self?.lastError = error.localizedDescription
            }
        }
    }

    func openQueueEditor(for displayID: String) {
        queueEditorDisplayID = displayID
        isQueueEditorPresented = true
    }

    func saveQueue(
        for display: DisplayService.Display,
        wallpaperIDs: [UUID],
        intervalSeconds: Double,
        transition: WallpaperTransitionEffect,
        isEnabled: Bool
    ) {
        let queueID = wallpaperManager.activeQueue(for: display.id)?.id ?? PlaybackQueue.defaultQueue.id
        var queue = wallpaperManager.queue(with: queueID) ?? .defaultQueue
        queue.addWallpaperIDs(wallpaperIDs)
        queue.defaultIntervalSeconds = intervalSeconds
        queue.transition = transition
        _ = wallpaperManager.updateQueue(queue)
        if isEnabled && !wallpaperIDs.isEmpty {
            wallpaperManager.setActiveQueue(queueID, for: display, policy: playbackPolicy, items: wallpapers)
        } else {
            wallpaperManager.stopQueue(displayID: display.id)
        }
    }

    func importWallpapers() {
        let panel = NSOpenPanel()
        panel.title = "添加壁纸"
        panel.message = "选择图片、视频或本地网页项目"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .movie, .html]
        guard panel.runModal() == .OK else { return }
        beginImport(panel.urls)
    }

    func cancelImport() {
        isImporting = false
        isImportInspectionInProgress = false
        pendingImportURLs = []
        pendingImportCandidates = []
        pendingWebEntryCandidates = []
    }

    func beginImport(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        pendingImportURLs = urls
        pendingImportCandidates = []
        pendingWebEntryCandidates = []
        isImportInspectionInProgress = true
        isImporting = true
        let worker = storeWorker
        Task { [weak self] in
            let inspection = await worker.inspectImportURLs(urls)
            guard let self, self.pendingImportURLs == urls else { return }
            self.pendingImportCandidates = inspection.candidates
            self.pendingWebEntryCandidates = inspection.webEntryCandidates
            self.isImportInspectionInProgress = false
        }
    }

    func importURLs(_ urls: [URL], entryURL: URL? = nil, storageMode: StorageMode? = nil) {
        let selectedStorageMode = storageMode ?? self.storageMode
        let worker = storeWorker
        Task { [weak self] in
            do {
                let result = try await worker.importItems(at: urls, entryURL: entryURL, storageMode: selectedStorageMode)
                guard let self else { return }
                self.isImporting = false
                self.isImportInspectionInProgress = false
                self.pendingImportURLs = []
                self.pendingImportCandidates = []
                self.pendingWebEntryCandidates = []
                self.applyMutationSnapshot(result.snapshot)
                self.selectedWallpaperID = result.importedIDs.last
                self.lastError = nil
                if !result.importedIDs.isEmpty || !result.failures.isEmpty {
                    self.importSummary = ImportSummary(importedCount: result.importedIDs.count, failures: result.failures)
                }
            } catch {
                guard let self else { return }
                self.isImporting = false
                self.isImportInspectionInProgress = false
                self.lastError = error.localizedDescription
            }
        }
    }

    func importDroppedFiles(from providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] data, error in
                guard error == nil else {
                    Task { @MainActor [weak self] in self?.lastError = error?.localizedDescription }
                    return
                }
                let url: URL?
                if let data = data as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let nsURL = data as? NSURL {
                    url = nsURL as URL
                } else if let string = data as? String {
                    url = URL(fileURLWithPath: string)
                } else {
                    url = nil
                }
                guard let url else { return }
                Task { @MainActor [weak self] in
                    self?.beginImport([url])
                }
            }
        }
    }

    func setLibraryURL(_ url: URL) {
        let normalizedURL = url.standardizedFileURL
        guard !Self.isTemporaryLibraryURL(normalizedURL) else {
            lastError = "不能使用临时目录作为壁纸库：\(normalizedURL.path)。临时目录可能在关机或重启后被系统清理，请选择文稿、图片或其他长期保存的位置。"
            return
        }
        do {
            try FileManager.default.createDirectory(at: normalizedURL, withIntermediateDirectories: true)
            try libraryAccess.persist(url: normalizedURL)
        } catch {
            lastError = "无法保存壁纸库位置：\(error.localizedDescription)"
            return
        }
        libraryURL = normalizedURL
        shouldCreateMissingLibraryDirectory = false
        store = WallpaperStore(libraryURL: libraryURL)
        storeWorker = WallpaperStoreWorker(libraryURL: libraryURL)
        UserDefaults.standard.set(libraryURL.path, forKey: SettingsKey.libraryPath)
        wallpaperManager.configure(store: store, policy: playbackPolicy)
        reload(afterLoad: restoreWallpaperAssignments)
    }

    private static func isTemporaryLibraryURL(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let temporaryPath = FileManager.default.temporaryDirectory.standardizedFileURL.path
        return path == "/tmp"
            || path.hasPrefix("/tmp/")
            || path == "/private/tmp"
            || path.hasPrefix("/private/tmp/")
            || path == "/var/tmp"
            || path.hasPrefix("/var/tmp/")
            || path == "/private/var/tmp"
            || path.hasPrefix("/private/var/tmp/")
            || path == temporaryPath
            || path.hasPrefix(temporaryPath + "/")
    }

    func chooseLibraryURL() {
        let panel = NSOpenPanel()
        panel.title = "选择壁纸库位置"
        panel.message = "壁纸库副本将保存到这个文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = libraryURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setLibraryURL(url)
    }

    func apply(item: WallpaperItem, to display: DisplayService.Display) {
        guard item.availability == .available else {
            lastError = "资源不可用，请先恢复文件后重试。"
            return
        }
        do {
            try wallpaperManager.apply(item: item, to: display, policy: playbackPolicy)
            if let index = wallpapers.firstIndex(where: { $0.id == item.id }) {
                var updated = wallpapers[index]
                updated.lastUsedAt = Date()
                wallpapers[index] = updated
                let worker = storeWorker
                Task { [weak self] in
                    do {
                        let persisted = try await worker.update(item: updated)
                        guard let self, let currentIndex = self.wallpapers.firstIndex(where: { $0.id == persisted.id }) else { return }
                        self.wallpapers[currentIndex] = persisted
                    } catch {
                        self?.lastError = error.localizedDescription
                    }
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func playbackDisplayIDs(for item: WallpaperItem) -> [String] {
        displayService.displays.compactMap { display in
            wallpaperManager.appliedWallpaperIDs[display.id] == item.id ? display.id : nil
        }
    }

    func togglePlayback(for item: WallpaperItem) {
        for displayID in playbackDisplayIDs(for: item) {
            wallpaperManager.togglePlayback(for: displayID)
        }
    }

    func setMuted(_ muted: Bool, for item: WallpaperItem) {
        for displayID in playbackDisplayIDs(for: item) {
            wallpaperManager.setMuted(muted, for: displayID)
        }
    }

    func reloadPlayback(for item: WallpaperItem) {
        for displayID in playbackDisplayIDs(for: item) {
            wallpaperManager.reload(displayID: displayID, policy: playbackPolicy)
        }
    }

    func isPlaying(_ item: WallpaperItem) -> Bool {
        playbackDisplayIDs(for: item).contains { wallpaperManager.playbackStates[$0]?.isPlaying == true }
    }

    func toggleAllPlayback() {
        wallpaperManager.setPlaybackEnabledForAll(!wallpaperManager.isAnyDynamicWallpaperPlaying)
    }

    func toggleAllMute() {
        wallpaperManager.setMutedForAll(!wallpaperManager.areAllDynamicWallpapersMuted)
    }

    func isMuted(_ item: WallpaperItem) -> Bool {
        let IDs = playbackDisplayIDs(for: item)
        guard let firstID = IDs.first else { return playbackPolicy.isMuted }
        return wallpaperManager.playbackStates[firstID]?.isMuted ?? playbackPolicy.isMuted
    }

    func refreshAvailability(for item: WallpaperItem) {
        let worker = storeWorker
        Task { [weak self] in
            do {
                let refreshed = try await worker.refreshAvailability(for: item)
                guard let self, let index = self.wallpapers.firstIndex(where: { $0.id == item.id }) else { return }
                self.wallpapers[index] = refreshed
                self.refreshVisibleWallpapersPreservingLoadedCount(self.visibleWallpapers.count)
            } catch {
                self?.lastError = error.localizedDescription
            }
        }
    }

    func relocate(item: WallpaperItem) {
        let panel = NSOpenPanel()
        panel.title = "重新定位壁纸资源"
        panel.message = "选择原壁纸文件或网页项目文件夹"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let worker = storeWorker
        Task { [weak self] in
            do {
                let snapshot = try await worker.relocate(item: item, to: url)
                self?.applyMutationSnapshot(snapshot)
            } catch {
                self?.lastError = error.localizedDescription
            }
        }
    }

    func remove(item: WallpaperItem) {
        removeWallpapers(ids: [item.id])
        selectedWallpaperID = nil
    }

    func requestDelete(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        pendingDeleteIDs = ids
        isDeleteConfirmationPresented = true
    }

    func removeWallpapers(ids: Set<UUID>) {
        let items = wallpapers.filter { ids.contains($0.id) }
        guard !items.isEmpty else { return }
        let removedIDs = Set(items.map(\.id))
        wallpaperManager.removeWallpaperIDs(removedIDs)
        let worker = storeWorker
        Task { [weak self] in
            do {
                let snapshot = try await worker.remove(items: items)
                guard let self else { return }
                self.selectedWallpaperIDs.subtract(removedIDs)
                if let selectedWallpaperID, removedIDs.contains(selectedWallpaperID) {
                    self.selectedWallpaperID = nil
                }
                self.applyMutationSnapshot(snapshot, enrichMetadata: false)
            } catch {
                self?.lastError = error.localizedDescription
            }
        }
    }

    func showInFinder(_ item: WallpaperItem) {
        let url = item.entryURL ?? item.sourceURL
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    var queueLibrary: [PlaybackQueue] { wallpaperManager.playbackQueues }

    func beginCreateQueue(for ids: Set<UUID> = []) {
        pendingQueueAssignmentIDs = ids
        isQueueManagementPresented = true
        isNewQueueSheetPresented = true
    }

    @discardableResult
    func createQueue(named name: String) -> PlaybackQueue? {
        guard let queue = wallpaperManager.createQueue(named: name) else {
            lastError = "已经存在同名播放队列，或名称为空。"
            return nil
        }
        if !pendingQueueAssignmentIDs.isEmpty {
            wallpaperManager.addWallpaperIDs(Array(pendingQueueAssignmentIDs), to: queue.id, items: wallpapers)
            pendingQueueAssignmentIDs.removeAll()
        }
        return wallpaperManager.queue(with: queue.id)
    }

    func duplicateQueue(_ queue: PlaybackQueue) {
        guard let copy = wallpaperManager.createQueue(
            named: "\(queue.name) 副本",
            playbackMode: queue.playbackMode,
            completionBehavior: queue.completionBehavior,
            advanceAfterVideoCompletion: queue.advanceAfterVideoCompletion,
            defaultIntervalSeconds: queue.defaultIntervalSeconds,
            transition: queue.transition
        ) else {
            lastError = "无法创建队列副本，请检查名称是否重复。"
            return
        }
        var duplicate = copy
        duplicate.sortMode = queue.sortMode
        duplicate.itemIntervalOverrides = queue.itemIntervalOverrides
        duplicate.addWallpaperIDs(queue.wallpaperIDs)
        _ = wallpaperManager.updateQueue(duplicate)
    }

    func deleteQueue(_ queue: PlaybackQueue) {
        guard !queue.isDefault else {
            lastError = "默认队列不可删除。"
            return
        }
        _ = wallpaperManager.deleteQueue(id: queue.id, policy: playbackPolicy, items: wallpapers)
    }

    func addWallpapers(_ ids: Set<UUID>, to queueID: UUID) {
        let ordered = wallpapers.filter { ids.contains($0.id) }.map(\.id)
        wallpaperManager.addWallpaperIDs(ordered, to: queueID, items: wallpapers)
    }

    func removeWallpapers(_ ids: Set<UUID>, from queueID: UUID) {
        guard !ids.isEmpty else { return }
        wallpaperManager.removeWallpaperIDs(ids, from: queueID)
        showToast("已从队列移除 \(ids.count) 项", undo: { [weak self] in
            guard let self else { return }
            self.wallpaperManager.addWallpaperIDs(Array(ids), to: queueID, items: self.wallpapers)
        })
    }

    func moveWallpaper(in queue: PlaybackQueue, from source: Int, to destination: Int) {
        var updated = queue
        updated.moveWallpaper(from: source, to: destination)
        _ = wallpaperManager.updateQueue(updated)
    }

    func setActiveQueue(_ queue: PlaybackQueue, for displayID: String) {
        guard let display = displayService.displays.first(where: { $0.id == displayID }) else {
            lastError = "该显示器当前不可用。"
            return
        }
        wallpaperManager.setActiveQueue(queue.id, for: display, policy: playbackPolicy, items: wallpapers)
    }

    func toggleFavorites(for ids: Set<UUID>) {
        let items = wallpapers.filter { ids.contains($0.id) }
        guard !items.isEmpty else { return }
        let shouldFavorite = !items.allSatisfy(\.isFavorite)
        let worker = storeWorker
        Task { [weak self] in
            do {
                let snapshot = try await worker.setFavorite(itemIDs: ids, isFavorite: shouldFavorite)
                self?.applyMutationSnapshot(snapshot, enrichMetadata: false)
            } catch {
                self?.lastError = error.localizedDescription
            }
        }
    }

    func showToast(_ message: String, undo: (() -> Void)? = nil) {
        toastMessage = message
        undoOperation = undo
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.toastMessage == message else { return }
            self.toastMessage = nil
            self.undoOperation = nil
        }
    }

    func undoLastAction() {
        undoOperation?()
        undoOperation = nil
        toastMessage = nil
    }

    func appliedDisplayNames(for item: WallpaperItem) -> [String] {
        displayService.displays.compactMap { display in
            wallpaperManager.appliedWallpaperIDs[display.id] == item.id ? display.name : nil
        }
    }

    func toggleFavorite(_ item: WallpaperItem) {
        toggleFavorites(for: [item.id])
    }

    private func applySettingsFromDefaults() {
        let defaults = UserDefaults.standard
        storageMode = StorageMode(rawValue: defaults.string(forKey: SettingsKey.storageMode) ?? "") ?? .managedCopy
        playbackPolicy = PlaybackPolicy(
            isMuted: defaults.object(forKey: SettingsKey.muted) as? Bool ?? true,
            loops: defaults.object(forKey: SettingsKey.loops) as? Bool ?? true,
            pauseOnBattery: defaults.object(forKey: SettingsKey.pauseOnBattery) as? Bool ?? false,
            pauseInFullScreenApps: defaults.object(forKey: SettingsKey.pauseInFullScreen) as? Bool ?? false,
            fitMode: WallpaperFitMode(rawValue: defaults.string(forKey: SettingsKey.fitMode) ?? "") ?? .fill
        )
        wallpaperManager.update(policy: playbackPolicy)
        if let path = defaults.string(forKey: SettingsKey.libraryPath) {
            let configuredURL = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            if configuredURL != libraryURL.standardizedFileURL {
                setLibraryURL(configuredURL)
            }
        }
    }
}

struct MainView: View {
    @StateObject private var model = LibraryViewModel()
    @AppStorage(SettingsKey.onboardingCompleted) private var onboardingCompleted = false

    var body: some View {
        Group {
            if onboardingCompleted {
                mainWorkspace
            } else {
                OnboardingView(model: model) {
                    onboardingCompleted = true
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $model.isImporting) {
            ImportSheet(model: model)
        }
        .sheet(isPresented: $model.isNewGroupSheetPresented) {
            NewGroupSheet { name in
                model.createGroup(named: name)
            }
        }
        .sheet(isPresented: $model.isQueueEditorPresented) {
            if let displayID = model.queueEditorDisplayID,
               let display = model.displayService.displays.first(where: { $0.id == displayID }) {
                QueueEditorView(model: model, display: display)
            } else {
                Text("显示器当前不可用")
                    .padding(32)
            }
        }
        .sheet(isPresented: $model.isQueueManagementPresented) {
            QueueManagementView(model: model)
                .frame(minWidth: 760, minHeight: 560)
        }
        .confirmationDialog("删除壁纸记录？", isPresented: $model.isDeleteConfirmationPresented, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                model.removeWallpapers(ids: model.pendingDeleteIDs)
                model.pendingDeleteIDs.removeAll()
            }
            Button("取消", role: .cancel) {
                model.pendingDeleteIDs.removeAll()
            }
        } message: {
            Text("应用库副本会被删除；外部文件引用只删除 WallpaperMac 中的记录，不会删除原文件。")
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toastMessage {
                HStack(spacing: 12) {
                    Text(toast)
                    if model.toastMessage != nil {
                        Button("撤销") { model.undoLastAction() }
                            .buttonStyle(.borderless)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 18)
            }
        }
        .alert("操作失败", isPresented: Binding(
            get: { model.lastError != nil },
            set: { if !$0 { model.lastError = nil } }
        )) {
            Button("好") { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "未知错误")
        }
        .alert(item: $model.importSummary) { summary in
            Alert(
                title: Text(summary.title),
                message: Text(summary.message),
                dismissButton: .default(Text("好"))
            )
        }
        // Existing installations skip onboarding, so the onboarding view's
        // onAppear hook is not reached. Prepare and persist the library on every
        // launch instead of only on first-run.
        .onAppear { model.prepareLibrary() }
    }

    private var mainWorkspace: some View {
        HStack(spacing: 0) {
            SidebarView(model: model)
                .frame(width: 220)
            Divider()
            LibraryContentView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            InspectorView(model: model)
                .frame(width: 340)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct OnboardingView: View {
    @ObservedObject var model: LibraryViewModel
    let finish: () -> Void
    @State private var step = 0
    @AppStorage(SettingsKey.launchAtLogin) private var launchAtLogin = false
    @AppStorage(SettingsKey.pauseOnBattery) private var pauseOnBattery = false
    @AppStorage(SettingsKey.pauseInFullScreen) private var pauseInFullScreen = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 18) {
                Image(systemName: icon)
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .font(.system(size: 28, weight: .semibold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
                content
                    .frame(maxWidth: 560)
            }
            Spacer()
            HStack {
                if step > 0 {
                    Button("上一步") { step -= 1 }
                }
                Spacer()
                Text("第 \(step + 1) / 4 步")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(step == 3 ? "完成并进入壁纸库" : "继续") {
                    if step == 3 {
                        NotificationCenter.default.post(name: .wallpaperMacSettingsChanged, object: nil)
                        model.prepareLibrary()
                        finish()
                    } else {
                        step += 1
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: 700)
            .padding(.horizontal, 36)
            .padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.prepareLibrary() }
        .onChange(of: launchAtLogin) { enabled in
            do {
                try LoginItemService.setEnabled(enabled)
            } catch {
                model.lastError = "登录项设置失败：\(error.localizedDescription)"
            }
        }
    }

    private var icon: String {
        switch step {
        case 0: return "rectangle.stack.badge.play"
        case 1: return "folder.badge.plus"
        case 2: return "gearshape.2"
        default: return model.libraryPermissionState.writable ? "checkmark.shield" : "exclamationmark.shield"
        }
    }

    private var title: String {
        switch step {
        case 0: return "欢迎使用 WallpaperMac"
        case 1: return "选择壁纸库存储位置"
        case 2: return "设置后台行为"
        default: return "检查应用权限"
        }
    }

    private var message: String {
        switch step {
        case 0: return "用图片、视频和本地 HTML 项目打造属于你的 macOS 壁纸。所有素材默认保存在本机，不需要账号或云同步。"
        case 1: return "选择一个长期稳定、拥有读写权限的文件夹。托管副本会复制到这里，外部引用则只保存原文件位置。"
        case 2: return "这些选项可以随时在设置中修改。动态壁纸默认静音，避免意外播放声音。"
        default: return "WallpaperMac 会检查壁纸库的读写权限。无法自动获得权限时仍可继续，但受影响的导入或维护操作会提示处理。"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0:
            HStack(spacing: 12) {
                OnboardingFeature(title: "图片", icon: "photo")
                OnboardingFeature(title: "视频", icon: "film")
                OnboardingFeature(title: "本地网页", icon: "safari")
            }
        case 1:
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "folder")
                    Text(model.libraryURL.path)
                        .font(.caption)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Spacer()
                    Button("选择文件夹") { model.chooseLibraryURL() }
                }
                Text("当前目录会自动创建 Assets 和索引文件，不会添加演示壁纸。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        case 2:
            VStack(alignment: .leading, spacing: 10) {
                Toggle("登录时启动", isOn: $launchAtLogin)
                Toggle("使用电池时暂停动态壁纸", isOn: $pauseOnBattery)
                Toggle("全屏应用时暂停动态壁纸", isOn: $pauseInFullScreen)
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        default:
            let permission = model.libraryPermissionState
            VStack(alignment: .leading, spacing: 10) {
                PermissionRow(title: "读取壁纸库", granted: permission.readable)
                PermissionRow(title: "写入壁纸库", granted: permission.writable)
                if !permission.writable {
                    Text("请在 Finder 中为所选文件夹授予当前用户读写权限，或在进入主界面后重新选择其他位置。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

private struct OnboardingFeature: View {
    let title: String
    let icon: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.title2).foregroundStyle(Color.accentColor)
            Text(title).font(.callout)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct PermissionRow: View {
    let title: String
    let granted: Bool
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
            Text(title)
            Spacer()
            Text(granted ? "可用" : "待处理")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct NewGroupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    let createAction: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("新建分组")
                .font(.title2.weight(.semibold))
            Text("用分组整理壁纸，分组不会复制或移动原始资源。")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("分组名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("创建", action: create)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        createAction(trimmed)
        dismiss()
    }
}

private struct QueueEditorView: View {
    @ObservedObject var model: LibraryViewModel
    let display: DisplayService.Display
    @Environment(\.dismiss) private var dismiss
    @State private var wallpaperIDs: [UUID]
    @State private var intervalSeconds: Double
    @State private var transition: WallpaperTransitionEffect
    @State private var isEnabled: Bool

    init(model: LibraryViewModel, display: DisplayService.Display) {
        self.model = model
        self.display = display
        let queue = model.wallpaperManager.queue(for: display.id)
            ?? DisplayPlaybackQueue(displayID: display.id, displayName: display.name)
        _wallpaperIDs = State(initialValue: queue.wallpaperIDs)
        _intervalSeconds = State(initialValue: queue.normalizedIntervalSeconds)
        _transition = State(initialValue: queue.transition)
        _isEnabled = State(initialValue: queue.isEnabled)
    }

    private var queueItems: [WallpaperItem] {
        wallpaperIDs.compactMap { id in model.wallpapers.first(where: { $0.id == id }) }
    }

    private var availableItems: [WallpaperItem] {
        model.wallpapers.filter { item in
            item.availability == .available && !wallpaperIDs.contains(item.id)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("播放队列")
                        .font(.title2.weight(.semibold))
                    Text(display.name)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("启用", isOn: $isEnabled)
                    .toggleStyle(.switch)
            }

            GroupBox("队列壁纸") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("拖动项目可调整播放顺序")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }

                    if queueItems.isEmpty {
                        Text("队列为空，请添加至少一项可用壁纸。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    } else {
                        List {
                            ForEach(Array(queueItems.enumerated()), id: \.element.id) { index, item in
                                HStack(spacing: 8) {
                                    Image(systemName: iconName(for: item))
                                        .foregroundStyle(.secondary)
                                    Text(item.name)
                                        .lineLimit(1)
                                    Spacer()
                                    Button {
                                        swapQueueItems(at: index, with: index - 1)
                                    } label: {
                                        Image(systemName: "chevron.up")
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(index == 0)
                                    .help("上移")
                                    Button {
                                        swapQueueItems(at: index, with: index + 1)
                                    } label: {
                                        Image(systemName: "chevron.down")
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(index == queueItems.count - 1)
                                    .help("下移")
                                    Button {
                                        wallpaperIDs.removeAll { $0 == item.id }
                                    } label: {
                                        Image(systemName: "minus.circle")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("移出队列")
                                }
                            }
                            .onMove { offsets, destination in
                                moveQueueItems(from: offsets, to: destination)
                            }
                        }
                        .listStyle(.inset)
                        .frame(minHeight: 120, maxHeight: 220)
                    }

                    Menu {
                        if availableItems.isEmpty {
                            Text("没有可添加的壁纸")
                        } else {
                            ForEach(availableItems) { item in
                                Button {
                                    wallpaperIDs.append(item.id)
                                } label: {
                                    Label(item.name, systemImage: iconName(for: item))
                                }
                            }
                        }
                    } label: {
                        Label("添加壁纸", systemImage: "plus")
                    }
                }
                .padding(.vertical, 4)
            }

            GroupBox("切换策略") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("每项停留")
                        Spacer()
                        Stepper(value: $intervalSeconds, in: 1...86_400, step: 1) {
                            Text("\(Int(intervalSeconds)) 秒")
                                .monospacedDigit()
                                .frame(minWidth: 76, alignment: .trailing)
                        }
                    }
                    Picker("切换效果", selection: $transition) {
                        ForEach(WallpaperTransitionEffect.allCases, id: \.self) { effect in
                            Text(effect.title).tag(effect)
                        }
                    }
                    .pickerStyle(.menu)
                    Text("切换间隔支持 1 秒至 86400 秒；队列中的失效资源会自动跳过。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isEnabled && wallpaperIDs.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520, height: 560)
    }

    private func moveQueueItems(from offsets: IndexSet, to destination: Int) {
        var ids = queueItems.map(\.id)
        ids.move(fromOffsets: offsets, toOffset: destination)
        wallpaperIDs = ids
    }

    private func swapQueueItems(at index: Int, with otherIndex: Int) {
        guard index >= 0, index < queueItems.count,
              otherIndex >= 0, otherIndex < queueItems.count else { return }
        var ids = queueItems.map(\.id)
        ids.swapAt(index, otherIndex)
        wallpaperIDs = ids
    }

    private func save() {
        model.saveQueue(
            for: display,
            wallpaperIDs: wallpaperIDs,
            intervalSeconds: intervalSeconds,
            transition: transition,
            isEnabled: isEnabled
        )
        dismiss()
    }

    private func iconName(for item: WallpaperItem) -> String {
        switch item.type {
        case .image: return "photo"
        case .video: return "film"
        case .web: return "safari"
        }
    }
}

private struct SidebarView: View {
    @ObservedObject var model: LibraryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("壁纸库")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    SidebarRow(title: "全部壁纸", icon: "square.grid.2x2", isSelected: model.destination == .all) { model.destination = .all }
                    SidebarRow(title: "图片", icon: "photo", isSelected: model.destination == .images) { model.destination = .images }
                    SidebarRow(title: "视频", icon: "film", isSelected: model.destination == .videos) { model.destination = .videos }
                    SidebarRow(title: "网页", icon: "safari", isSelected: model.destination == .web) { model.destination = .web }
                    SidebarRow(title: "收藏", icon: "star", isSelected: model.destination == .favorites) { model.destination = .favorites }
                    SidebarRow(title: "最近使用", icon: "clock", isSelected: model.destination == .recent) { model.destination = .recent }
                    SidebarRow(title: "播放队列", icon: "list.bullet.rectangle", isSelected: model.destination == .queueLibrary, subtitle: "\(model.queueLibrary.count) 个队列") { model.destination = .queueLibrary }

                    HStack {
                        Text("分组")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button { model.isNewGroupSheetPresented = true } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderless)
                        .help("新建分组")
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 22)
                    .padding(.bottom, 5)

                    ForEach(model.groups) { group in
                        SidebarRow(
                            title: group.name,
                            icon: "folder",
                            isSelected: model.destination == .group(group.id),
                            subtitle: "\(model.wallpapers.filter { $0.groupID == group.id }.count) 项"
                        ) {
                            model.destination = .group(group.id)
                        }
                    }

                    if !model.displayRows.isEmpty {
                        Text("显示器")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.top, 22)
                            .padding(.bottom, 5)
                        ForEach(model.displayRows) { display in
                            SidebarRow(
                                title: display.name,
                                icon: display.isConnected ? "display" : "display.trianglebadge.exclamationmark",
                                isSelected: model.destination == .display(display.id),
                                subtitle: display.isConnected ? nil : "已断开"
                            ) {
                                model.destination = .display(display.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
            }
            Spacer(minLength: 12)
            Divider()
            HStack {
                Button(action: { model.chooseLibraryURL() }) {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("选择壁纸库位置")
                Text(model.libraryURL.path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(12)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.42))
    }
}

private struct SidebarRow: View {
    let title: String
    let icon: String
    let isSelected: Bool
    var subtitle: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .background(isSelected ? Color.accentColor.opacity(0.82) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct LibraryContentView: View {
    @ObservedObject var model: LibraryViewModel
    @State private var isDropTargeted = false
    @State private var showingBatchRemoveConfirmation = false

    private let columns = [GridItem(.adaptive(minimum: 190), spacing: 16)]

    var body: some View {
        Group {
            if model.destination == .queueLibrary {
                QueueManagementView(model: model)
            } else {
                libraryBody
            }
        }
    }

    @ViewBuilder
    private var libraryBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                    Text(model.isSelectionMode
                         ? "已选 \(model.selectedWallpaperIDs.count) / \(model.filteredWallpapers.count) 项"
                         : "\(model.filteredWallpapers.count) 个资源 · 已加载 \(model.visibleWallpapers.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isSelectionMode {
                    Button("全选") { model.selectAllFiltered() }
                        .buttonStyle(.borderless)
                    Button("清空") { model.clearSelection() }
                        .buttonStyle(.borderless)
                    Menu {
                        Button("移出分组") { model.assignSelected(to: nil) }
                        if !model.groups.isEmpty {
                            Divider()
                            ForEach(model.groups) { group in
                                Button(group.name) { model.assignSelected(to: group.id) }
                            }
                        }
                        Divider()
                        Button("新建分组…") { model.isNewGroupSheetPresented = true }
                    } label: {
                        Label("分组", systemImage: "folder")
                    }
                    .menuStyle(.borderlessButton)
                    Button("删除", role: .destructive) {
                        showingBatchRemoveConfirmation = true
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.selectedWallpaperIDs.isEmpty)
                    Button("完成") {
                        model.clearSelection()
                        model.isSelectionMode = false
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    TextField("搜索壁纸", text: $model.searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 190)
                    Menu {
                        Picker("类型", selection: $model.selectedType) {
                            Text("全部类型").tag(nil as WallpaperType?)
                            Text("图片").tag(WallpaperType?.some(.image))
                            Text("视频").tag(WallpaperType?.some(.video))
                            Text("网页").tag(WallpaperType?.some(.web))
                        }
                        Divider()
                        Picker("状态", selection: $model.statusFilter) {
                            ForEach(WallpaperStatusFilter.allCases) { filter in
                                Text(filter.title).tag(filter)
                            }
                        }
                    } label: {
                        Label("筛选", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .help("筛选类型和状态")
                    Menu {
                        Picker("排序", selection: $model.sortOrder) {
                            ForEach(WallpaperSortOrder.allCases) { order in
                                Text(order.title).tag(order)
                            }
                        }
                    } label: {
                        Label(model.sortOrder.title, systemImage: "arrow.up.arrow.down")
                    }
                    .menuStyle(.borderlessButton)
                    .help("排序")
                    Picker("视图", selection: $model.layout) {
                        ForEach(LibraryLayout.allCases) { layout in
                            Image(systemName: layout.icon).tag(layout)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 76)
                    .help("切换网格或列表")
                    Button { model.isSelectionMode = true } label: {
                        Label("批量管理", systemImage: "checklist")
                    }
                    .buttonStyle(.borderless)
                    Button(action: { model.importWallpapers() }) {
                        Label("添加壁纸", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    Button(action: { (NSApp.delegate as? AppDelegate)?.showSettingsWindow() }) {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.borderless)
                    .help("设置")
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)

            Divider()

            if model.filteredWallpapers.isEmpty {
                EmptyLibraryView(hasItems: !model.wallpapers.isEmpty, importAction: { model.importWallpapers() })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.layout == .grid {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(model.visibleWallpapers) { item in
                            WallpaperCard(
                                item: item,
                                isSelected: model.isSelectionMode
                                    ? model.selectedWallpaperIDs.contains(item.id)
                                    : item.id == model.selectedWallpaperID,
                                selectionMode: model.isSelectionMode,
                                appliedDisplays: model.appliedDisplayNames(for: item)
                            ) {
                                if model.isSelectionMode {
                                    model.toggleSelection(for: item)
                                } else {
                                    model.selectedWallpaperID = item.id
                                }
                            } favoriteAction: {
                                model.toggleFavorite(item)
                            }
                            .onAppear { model.loadNextPageIfNeeded(currentItem: item) }
                            .contextMenu {
                                WallpaperContextMenu(model: model, item: item)
                            }
                        }
                    }
                    .padding(24)
                }
            } else {
                List(model.visibleWallpapers) { item in
                    WallpaperListRow(
                        item: item,
                        isSelected: model.isSelectionMode
                            ? model.selectedWallpaperIDs.contains(item.id)
                            : item.id == model.selectedWallpaperID,
                        selectionMode: model.isSelectionMode,
                        appliedDisplays: model.appliedDisplayNames(for: item)
                    ) {
                        if model.isSelectionMode {
                            model.toggleSelection(for: item)
                        } else {
                            model.selectedWallpaperID = item.id
                        }
                    } favoriteAction: {
                        model.toggleFavorite(item)
                    }
                    .onAppear { model.loadNextPageIfNeeded(currentItem: item) }
                    .contextMenu {
                        WallpaperContextMenu(model: model, item: item)
                    }
                }
                .listStyle(.inset)
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
            model.importDroppedFiles(from: providers)
            return true
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .padding(10)
                    .overlay {
                        Text("松开以导入壁纸")
                            .font(.headline)
                            .padding(14)
                            .background(.regularMaterial, in: Capsule())
                    }
            }
        }
        .confirmationDialog("删除选中的壁纸？", isPresented: $showingBatchRemoveConfirmation, titleVisibility: .visible) {
            Button("删除", role: .destructive) { model.removeSelectedWallpapers() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("应用库副本会被删除；外部文件引用只删除 WallpaperMac 中的记录，不会删除原文件。")
        }
    }

    private var title: String {
        switch model.destination {
        case .all: return "全部壁纸"
        case .images: return "图片"
        case .videos: return "视频"
        case .web: return "网页"
        case .favorites: return "收藏"
        case .recent: return "最近使用"
        case .queueLibrary: return "播放队列"
        case .group(let id): return model.groups.first(where: { $0.id == id })?.name ?? "分组"
        case .display(let id): return model.displayRows.first(where: { $0.id == id })?.name ?? "显示器"
        }
    }
}

private struct WallpaperListRow: View {
    let item: WallpaperItem
    let isSelected: Bool
    let selectionMode: Bool
    let appliedDisplays: [String]
    let selectAction: () -> Void
    let favoriteAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if selectionMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
            ThumbnailView(item: item)
                .frame(width: 110, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(.callout.weight(.medium)).lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: iconName)
                    Text(typeName)
                    if item.availability != .available {
                        Text(availabilityLabel(item.availability)).foregroundStyle(.red)
                    }
                    if !appliedDisplays.isEmpty {
                        Text(appliedDisplays.joined(separator: "、")).foregroundStyle(.green).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: favoriteAction) {
                Image(systemName: item.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(item.isFavorite ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(isSelected ? Color.accentColor.opacity(0.16) : .clear)
        .onTapGesture(perform: selectAction)
    }

    private var iconName: String {
        switch item.type { case .image: return "photo"; case .video: return "film"; case .web: return "safari" }
    }

    private var typeName: String {
        switch item.type { case .image: return "图片"; case .video: return "视频"; case .web: return "网页" }
    }

    private func availabilityLabel(_ availability: WallpaperAvailability) -> String {
        switch availability {
        case .available: return "可用"
        case .importing: return "导入中"
        case .missing: return "已失效"
        case .unsupported: return "不支持"
        case .permissionDenied: return "无权限"
        }
    }
}

private struct WallpaperCard: View {
    let item: WallpaperItem
    let isSelected: Bool
    let selectionMode: Bool
    let appliedDisplays: [String]
    let selectAction: () -> Void
    let favoriteAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .topTrailing) {
                WallpaperPreviewFrame {
                    ThumbnailView(item: item)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2)
                }
                    .overlay(alignment: .topLeading) {
                        if selectionMode {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.title2)
                                .foregroundStyle(isSelected ? Color.accentColor : .white)
                                .padding(10)
                                .shadow(radius: 2)
                        }
                    }
                Button(action: favoriteAction) {
                    Image(systemName: item.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(item.isFavorite ? .yellow : .white)
                        .padding(8)
                        .background(.black.opacity(0.42), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(8)
            }
            Text(item.name)
                .font(.callout.weight(.medium))
                .lineLimit(2)
            HStack(spacing: 5) {
                Image(systemName: iconName)
                Text(typeName)
                Spacer()
                if item.availability != .available {
                    Text(availabilityLabel(item.availability)).foregroundStyle(.red)
                } else if !appliedDisplays.isEmpty {
                    Text(appliedDisplays.joined(separator: "、"))
                        .lineLimit(1)
                        .foregroundStyle(.green)
                }
            }
            .font(.caption)
            .foregroundStyle(item.availability == .missing ? .red : .secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: selectAction)
    }

    private func availabilityLabel(_ availability: WallpaperAvailability) -> String {
        switch availability {
        case .available: return "可用"
        case .importing: return "导入中"
        case .missing: return "已失效"
        case .unsupported: return "不支持"
        case .permissionDenied: return "无权限"
        }
    }

    private var iconName: String {
        switch item.type { case .image: return "photo"; case .video: return "film"; case .web: return "safari" }
    }

    private var typeName: String {
        switch item.type { case .image: return "图片"; case .video: return "视频"; case .web: return "网页" }
    }
}

private struct WallpaperPreviewFrame<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        // Use a geometry-bearing color as the sizing source. Applying
        // aspectRatio directly to ThumbnailView lets a portrait thumbnail
        // contribute its intrinsic height and can make the preview vertical.
        Color.clear
            .frame(maxWidth: .infinity)
            .aspectRatio(CGFloat(WallpaperPreviewLayout.aspectRatio), contentMode: .fit)
            .overlay {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .clipped()
    }
}

private struct ThumbnailView: View {
    let item: WallpaperItem

    var body: some View {
        ZStack {
            if let image = previewImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [Color(nsColor: .controlBackgroundColor), Color(nsColor: .underPageBackgroundColor)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: iconName)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.secondary)
                if item.type != .image {
                    Text(item.type == .video ? "视频" : "HTML")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 58)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipped()
    }

    private var previewImage: NSImage? {
        guard item.availability == .available else { return nil }
        if let thumbnailURL = item.thumbnailURL, let image = NSImage(contentsOf: thumbnailURL) {
            return image
        }
        guard item.type == .image else { return nil }
        return NSImage(contentsOf: item.sourceURL)
    }

    private var iconName: String {
        switch item.type { case .image: return "photo"; case .video: return "film"; case .web: return "safari" }
    }
}

private struct ImportSheet: View {
    @ObservedObject var model: LibraryViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedEntry: URL?
    @State private var selectedStorageMode: StorageMode = .managedCopy

    private var candidates: [URL] { model.pendingWebEntryCandidates }

    private var webProject: URL? {
        let webProjects = model.pendingImportCandidates.compactMap { candidate -> URL? in
            guard candidate.type == .web, candidate.url.hasDirectoryPath else { return nil }
            return candidate.url
        }
        guard webProjects.count == 1 else { return nil }
        return webProjects.first
    }

    private func importType(for url: URL) -> WallpaperType? {
        model.pendingImportCandidates.first(where: { $0.url == url })?.type
    }

    private var requiresEntrySelection: Bool {
        webProject != nil && candidates.count > 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("导入壁纸")
                .font(.title2.weight(.semibold))
            Text("确认素材、存储策略和网页入口后再开始导入。")
                .font(.callout)
                .foregroundStyle(.secondary)

            GroupBox("扫描结果") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.pendingImportURLs, id: \.self) { url in
                        HStack(spacing: 8) {
                            let type = importType(for: url)
                            Image(systemName: icon(for: type))
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(url.lastPathComponent)
                                    .font(.callout)
                                    .lineLimit(1)
                                Text(typeDescription(for: type))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.isImportInspectionInProgress {
                                ProgressView()
                                    .controlSize(.small)
                            } else if type == nil {
                                Text("不支持")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            } else {
                                Text("待导入")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Picker("存储策略", selection: $selectedStorageMode) {
                Text("复制到应用库").tag(StorageMode.managedCopy)
                Text("引用原文件").tag(StorageMode.externalReference)
            }
            .pickerStyle(.radioGroup)
            Text(selectedStorageMode == .managedCopy
                 ? "应用会将素材复制到当前壁纸库，原文件移动后仍可正常使用。"
                 : "应用直接引用原文件，文件移动或删除后需要重新定位。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if requiresEntrySelection {
                GroupBox("网页入口") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("这个项目包含多个 HTML 文件，请选择启动时加载的入口页面。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("入口文件", selection: $selectedEntry) {
                            ForEach(candidates, id: \.self) { candidate in
                                Text(relativePath(candidate)).tag(Optional(candidate))
                            }
                        }
                        .labelsHidden()
                    }
                    .padding(.vertical, 4)
                }
            }

            HStack {
                Spacer()
                Button("取消") {
                    model.cancelImport()
                    dismiss()
                }
                Button("开始导入") {
                    model.importURLs(model.pendingImportURLs, entryURL: selectedEntry, storageMode: selectedStorageMode)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.pendingImportURLs.isEmpty || model.isImportInspectionInProgress || (requiresEntrySelection && selectedEntry == nil))
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear {
            selectedStorageMode = model.storageMode
            selectedEntry = candidates.first(where: { $0.lastPathComponent.lowercased() == "index.html" }) ?? candidates.first
        }
        .onChange(of: candidates) { values in
            guard selectedEntry == nil else { return }
            selectedEntry = values.first(where: { $0.lastPathComponent.lowercased() == "index.html" }) ?? values.first
        }
    }

    private func icon(for type: WallpaperType?) -> String {
        switch type {
        case .image: return "photo"
        case .video: return "film"
        case .web: return "safari"
        case .none: return "questionmark.folder"
        }
    }

    private func typeDescription(for type: WallpaperType?) -> String {
        switch type {
        case .image: return "图片壁纸"
        case .video: return "视频壁纸"
        case .web: return "本地网页壁纸"
        case .none: return "正在扫描…"
        }
    }

    private func relativePath(_ url: URL) -> String {
        guard let projectURL = webProject else { return url.lastPathComponent }
        let base = projectURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(base.count + 1))
    }
}

private struct EmptyLibraryView: View {
    let hasItems: Bool
    let importAction: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: hasItems ? "magnifyingglass" : "photo.on.rectangle.angled")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
            Text(hasItems ? "没有匹配的壁纸" : "壁纸库还是空的")
                .font(.title3.weight(.semibold))
            Text(hasItems ? "尝试修改搜索条件或筛选器" : "拖入图片、视频或本地 HTML 项目，开始创建你的壁纸库")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !hasItems {
                Button("添加第一张壁纸", action: importAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .padding(40)
    }
}

private struct InspectorView: View {
    @ObservedObject var model: LibraryViewModel
    @State private var showingRemoveConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("检查器")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 16)
            Divider()
            if let item = model.selectedWallpaper {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        WallpaperPreviewFrame {
                            ThumbnailView(item: item)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name).font(.title3.weight(.semibold))
                            Text(typeName(for: item)).font(.caption).foregroundStyle(.secondary)
                        }
                        GroupBox("显示器") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(model.displayRows) { row in
                                    HStack(spacing: 8) {
                                        Image(systemName: row.isConnected ? "display" : "display.trianglebadge.exclamationmark")
                                            .foregroundStyle(row.isConnected ? Color.primary : Color.orange)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(row.name).font(.callout)
                                            Text(status(for: row, item: item))
                                                .font(.caption)
                                                .foregroundStyle(statusColor(for: row, item: item))
                                            if let queue = model.wallpaperManager.queue(for: row.id), !queue.wallpaperIDs.isEmpty {
                                                Text(queue.isEnabled
                                                     ? "队列播放中 · \(queue.wallpaperIDs.count) 项"
                                                     : "队列已配置 · \(queue.wallpaperIDs.count) 项")
                                                    .font(.caption2)
                                                    .foregroundStyle(queue.isEnabled ? .green : .secondary)
                                                Text("每 \(Int(queue.normalizedIntervalSeconds)) 秒 · \(queue.transition.title)")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer(minLength: 4)
                                        if row.isConnected,
                                           let display = model.displayService.displays.first(where: { $0.id == row.id }) {
                                            VStack(alignment: .trailing, spacing: 5) {
                                                HStack(spacing: 5) {
                                                    Button(model.wallpaperManager.appliedWallpaperIDs[display.id] == item.id ? "已应用" : "应用") {
                                                        model.apply(item: item, to: display)
                                                    }
                                                    .buttonStyle(.borderedProminent)
                                                    .controlSize(.small)
                                                    .disabled(item.availability != .available || model.wallpaperManager.appliedWallpaperIDs[display.id] == item.id)
                                                    Button("配置队列") {
                                                        model.openQueueEditor(for: display.id)
                                                    }
                                                    .buttonStyle(.bordered)
                                                    .controlSize(.small)
                                                }
                                            }
                                        } else {
                                            Text("已断开")
                                                .font(.caption)
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 3)
                        }
                        if item.type != .image {
                            GroupBox("播放") {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack(spacing: 8) {
                                        Button {
                                            model.togglePlayback(for: item)
                                        } label: {
                                            Label(model.isPlaying(item) ? "暂停" : "播放", systemImage: model.isPlaying(item) ? "pause.fill" : "play.fill")
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
                                        .disabled(model.playbackDisplayIDs(for: item).isEmpty)

                                        Button {
                                            model.setMuted(!model.isMuted(item), for: item)
                                        } label: {
                                            Label(model.isMuted(item) ? "取消静音" : "静音", systemImage: model.isMuted(item) ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .disabled(model.playbackDisplayIDs(for: item).isEmpty)

                                        Button {
                                            model.reloadPlayback(for: item)
                                        } label: {
                                            Label("重新加载", systemImage: "arrow.clockwise")
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .disabled(model.playbackDisplayIDs(for: item).isEmpty)
                                    }
                                    Text(model.playbackDisplayIDs(for: item).isEmpty ? "尚未应用到显示器" : (model.isMuted(item) ? "当前静音" : "当前有声"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        GroupBox("资源信息") {
                            VStack(alignment: .leading, spacing: 9) {
                                InspectorRow(title: "存储模式", value: item.storageMode == .managedCopy ? "应用库副本" : "外部文件引用")
                                InspectorRow(title: "状态", value: availabilityLabel(item.availability))
                                InspectorRow(title: "文件格式", value: metadataValue(item.metadata?.fileExtension?.uppercased(), fallback: "正在读取…"))
                                InspectorRow(title: "文件大小", value: fileSizeText(item.metadata?.fileSizeBytes))
                                if item.type == .image || item.type == .video {
                                    InspectorRow(title: "分辨率", value: resolutionText(item.metadata))
                                }
                                if item.type == .video {
                                    InspectorRow(title: "时长", value: durationText(item.metadata?.durationSeconds))
                                }
                                InspectorRow(title: "路径", value: item.sourceURL.path)
                                if let entryURL = item.entryURL { InspectorRow(title: "入口文件", value: entryURL.path) }
                                if item.availability != .available {
                                    Text(availabilityExplanation(item.availability))
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                    HStack {
                                        Button("重新定位") { model.relocate(item: item) }
                                            .buttonStyle(.borderedProminent)
                                        Button("重新扫描") { model.refreshAvailability(for: item) }
                                            .buttonStyle(.bordered)
                                    }
                                }
                                HStack {
                                    Spacer()
                                    Button("移除记录", role: .destructive) {
                                        showingRemoveConfirmation = true
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    }
                    .padding(20)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "cursorarrow.click")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("选择一个壁纸").font(.callout.weight(.medium))
                    Text("预览、分配显示器并查看资源信息")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.28))
        .confirmationDialog("移除壁纸记录？", isPresented: $showingRemoveConfirmation, titleVisibility: .visible) {
            if let item = model.selectedWallpaper {
                Button("移除记录", role: .destructive) {
                    model.remove(item: item)
                }
                Button("取消", role: .cancel) {}
            }
        } message: {
            if let item = model.selectedWallpaper {
                Text(item.storageMode == .managedCopy
                     ? "这会删除应用库中的副本和记录，原始导入文件不会受到影响。"
                     : "这只会删除壁纸记录，不会删除原文件。")
            }
        }
    }

    private func availabilityLabel(_ availability: WallpaperAvailability) -> String {
        switch availability {
        case .available: return "可用"
        case .importing: return "导入中"
        case .missing: return "资源已失效"
        case .unsupported: return "格式不支持"
        case .permissionDenied: return "没有读取权限"
        }
    }

    private func availabilityExplanation(_ availability: WallpaperAvailability) -> String {
        switch availability {
        case .missing: return "文件或网页入口已移动、删除，重新定位后可恢复应用。"
        case .permissionDenied: return "应用无法读取当前路径，请检查文件权限后重新扫描。"
        case .unsupported: return "当前资源类型无法由 WallpaperMac 承载。"
        case .importing: return "资源正在导入，请稍候。"
        case .available: return ""
        }
    }

    private func typeName(for item: WallpaperItem) -> String {
        switch item.type { case .image: return "图片壁纸"; case .video: return "视频壁纸"; case .web: return "网页壁纸" }
    }

    private func metadataValue(_ value: String?, fallback: String) -> String {
        guard let value, !value.isEmpty else { return fallback }
        return value
    }

    private func resolutionText(_ metadata: WallpaperMetadata?) -> String {
        guard let width = metadata?.pixelWidth, let height = metadata?.pixelHeight, width > 0, height > 0 else {
            return metadata == nil ? "正在读取…" : "暂无信息"
        }
        return "\(width) × \(height)"
    }

    private func durationText(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "正在读取…" }
        let totalSeconds = Int(seconds.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let remaining = totalSeconds % 60
        return hours > 0
            ? String(format: "%02d:%02d:%02d", hours, minutes, remaining)
            : String(format: "%02d:%02d", minutes, remaining)
    }

    private func fileSizeText(_ bytes: Int64?) -> String {
        guard let bytes, bytes >= 0 else { return "正在读取…" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        return formatter.string(fromByteCount: bytes)
    }

    private func status(for row: DisplayRow, item: WallpaperItem) -> String {
        guard row.isConnected else { return "已断开，保留原分配" }
        return model.wallpaperManager.appliedWallpaperIDs[row.id] == item.id ? "当前壁纸" : "未应用"
    }

    private func statusColor(for row: DisplayRow, item: WallpaperItem) -> Color {
        guard row.isConnected else { return .orange }
        return model.wallpaperManager.appliedWallpaperIDs[row.id] == item.id ? .green : .secondary
    }
}

private struct InspectorRow: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.caption).lineLimit(3).textSelection(.enabled)
        }
    }
}
