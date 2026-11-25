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
    case group(UUID)
    case displaysOverview
    case display(String)
    case queue(UUID)

    var isLibraryWorkspace: Bool {
        switch self {
        case .all, .images, .videos, .web, .favorites, .recent, .group:
            return true
        case .displaysOverview, .display, .queue:
            return false
        }
    }
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
    struct LibraryMigrationCompletion: Identifiable {
        let id = UUID()
        let oldURL: URL
        let newURL: URL
        let fileCount: Int
        let byteCount: Int64
    }

    @Published private(set) var wallpapers: [WallpaperItem] = []
    @Published private(set) var visibleWallpapers: [WallpaperItem] = []
    @Published private(set) var currentPage = 1
    @Published private(set) var pageSize = WallpaperLibraryPagination.defaultPageSize
    @Published private(set) var groups: [WallpaperGroup] = []
    @Published var selectedWallpaperID: UUID?
    @Published var selectedWallpaperIDs: Set<UUID> = []
    @Published var isSelectionMode = false
    @Published var isNewGroupSheetPresented = false
    @Published var isQueueEditorPresented = false
    @Published var queueEditorDisplayID: String?
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
    /// Mirrors WallpaperManager.queueLoadError/queueSaveError so the UI can
    /// surface that queue persistence is disabled instead of failing silently.
    @Published private(set) var queuePersistenceWarning: String?
    @Published private(set) var libraryURL: URL
    @Published var storageMode: StorageMode
    @Published var playbackPolicy: PlaybackPolicy
    @Published var isDropTargeted = false
    @Published var isImporting = false
    @Published var isWebURLImportPresented = false
    @Published var pendingImportURLs: [URL] = []
    @Published private(set) var pendingImportCandidates: [WallpaperImportCandidate] = []
    @Published private(set) var pendingWebEntryCandidates: [URL] = []
    @Published private(set) var isImportInspectionInProgress = false
    @Published var importSummary: ImportSummary?
    @Published var showsHiddenWallpapers = false
    @Published private(set) var hiddenPasswordIsSet = false
    @Published var hiddenAuthRequest: HiddenWallpaperAuthRequest?
    @Published var hiddenAuthError: String?
    @Published var isMigratingLibrary = false
    @Published var libraryMigrationCompletion: LibraryMigrationCompletion?

    private(set) var store: WallpaperStore
    private var storeWorker: WallpaperStoreWorker
    let displayService = DisplayService()
    let wallpaperManager = WallpaperManager()
    private var settingsObserver: NSObjectProtocol?
    private var migrationRequestObserver: NSObjectProtocol?
    private var statusBarObservers: [NSObjectProtocol] = []
    private var observationCancellables = Set<AnyCancellable>()
    private let libraryAccess: WallpaperLibraryAccess
    private var shouldCreateMissingLibraryDirectory: Bool
    private var pendingGroupAssignmentIDs: Set<UUID> = []
    private var groupCreationSucceeded = false
    private var pendingQueueAssignmentIDs: Set<UUID> = []
    private var undoOperation: (() -> Void)?
    /// True only while the visible toast carries a real undo action.
    var canUndoToast: Bool { undoOperation != nil }
    private var activeToastID: UUID?
    private var metadataEnrichmentTask: Task<Void, Never>?
    private var metadataEnrichmentGeneration = 0
    private var libraryLoadTask: Task<Void, Never>?
    private var libraryLoadGeneration = 0
    /// Rotated whenever the library root changes. Async mutations capture the
    /// session they started in and must not publish results into a newer one.
    private var librarySessionID = UUID()

    private func isCurrentLibrarySession(_ session: UUID) -> Bool {
        session == librarySessionID
    }

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
        hiddenPasswordIsSet = (try? store.hiddenWallpaperLock()) != nil
        storageMode = StorageMode(rawValue: defaults.string(forKey: SettingsKey.storageMode) ?? "") ?? .managedCopy
        playbackPolicy = PlaybackPolicy(
            isMuted: defaults.object(forKey: SettingsKey.muted) as? Bool ?? true,
            loops: defaults.object(forKey: SettingsKey.loops) as? Bool ?? true,
            pauseOnBattery: defaults.object(forKey: SettingsKey.pauseOnBattery) as? Bool ?? false,
            pauseInFullScreenApps: defaults.object(forKey: SettingsKey.pauseInFullScreen) as? Bool ?? false,
            fitMode: WallpaperFitMode(rawValue: defaults.string(forKey: SettingsKey.fitMode) ?? "") ?? .fill,
            webWallpaperInteractionEnabled: defaults.object(forKey: SettingsKey.webWallpaperInteractionEnabled) as? Bool ?? false
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
        migrationRequestObserver = NotificationCenter.default.addObserver(
            forName: .wallpaperMacRequestLibraryMigration,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.chooseLibraryForMigration()
            }
        }
        let center = NotificationCenter.default
        statusBarObservers = [
            center.addObserver(forName: .wallpaperMacStatusTogglePlayback, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.toggleAllPlayback() }
            },
            center.addObserver(forName: .wallpaperMacStatusToggleMute, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.toggleAllMute() }
            },
            center.addObserver(forName: .wallpaperMacStatusHideHiddenWallpapers, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.hideHiddenWallpapersFromShortcut() }
            }
        ]
        reload(afterLoad: restoreWallpaperAssignments)
        wallpaperManager.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &observationCancellables)
        wallpaperManager.$queueLoadError
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshQueuePersistenceWarning() }
            .store(in: &observationCancellables)
        wallpaperManager.$queueSaveError
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshQueuePersistenceWarning() }
            .store(in: &observationCancellables)
        refreshQueuePersistenceWarning()
        NotificationCenter.default.addObserver(
            forName: .wallpaperMacFlushPersistence,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                // AppDelegate spins its run loop until this flag clears (or a
                // 3s cap), so termination waits for the durable flush.
                UserDefaults.standard.set(true, forKey: "WallpaperMacPersistenceFlushPending")
                await self?.wallpaperManager.flushPersistence()
                UserDefaults.standard.set(false, forKey: "WallpaperMacPersistenceFlushPending")
            }
        }
        displayService.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.normalizeDestinationForConnectedDisplays()
                self?.objectWillChange.send()
            }
            .store(in: &observationCancellables)
    }

    private func refreshQueuePersistenceWarning() {
        if let saveError = wallpaperManager.queueSaveError {
            queuePersistenceWarning = saveError
        } else if wallpaperManager.isQueuePersistenceBlocked {
            queuePersistenceWarning = wallpaperManager.queueLoadError
                ?? "队列文件损坏，已暂停保存以保护原数据。"
        } else {
            queuePersistenceWarning = nil
        }
    }

    /// Re-reads queue files after the user repaired them and reports whether
    /// persistence is available again. Only meaningful when writes are blocked
    /// (load failure) — a save failure must NOT reload, or it would replace the
    /// unsaved in-memory edits with the stale on-disk state.
    func retryQueuePersistence() {
        guard wallpaperManager.isQueuePersistenceBlocked else { return }
        let recovered = wallpaperManager.retryLoadingQueues()
        refreshQueuePersistenceWarning()
        if recovered {
            showToast("队列已恢复保存。")
        } else {
            lastError = "队列文件仍然无法读取，请检查 playback-queues.json 与 display-playback-bindings.json 后再重试。"
        }
    }

    private func queueOperationBlockedError() -> String? {
        guard wallpaperManager.isQueuePersistenceBlocked else { return nil }
        return wallpaperManager.queueLoadError
            ?? "队列文件损坏，已暂停保存以保护原数据；请先修复或重试加载。"
    }

    private func normalizeDestinationForConnectedDisplays() {        switch destination {
        case .display(let displayID):
            if !displayService.displays.contains(where: { $0.id == displayID }) {
                destination = .displaysOverview
            }
        case .queue(let queueID):
            if !queueLibrary.contains(where: { $0.id == queueID }) {
                destination = .all
            }
        default:
            break
        }
    }

    deinit {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
        if let migrationRequestObserver {
            NotificationCenter.default.removeObserver(migrationRequestObserver)
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
        guard let selectedWallpaperID,
              let item = wallpapers.first(where: { $0.id == selectedWallpaperID }) else { return nil }
        if item.isHidden && !showsHiddenWallpapers { return nil }
        return item
    }

    func isWallpaperVisible(_ item: WallpaperItem) -> Bool {
        showsHiddenWallpapers || !item.isHidden
    }

    var displayRows: [DisplayRow] {
        let assignments = UniquedDictionary.build(wallpaperManager.displayAssignments.map { ($0.id, $0) }, label: "display assignments")
        // Disconnected displays keep their assignments and queue state in the
        // background. They are not actionable in the UI until they reconnect.
        return displayService.displays.map { display in
            DisplayRow(
                id: display.id,
                name: display.name,
                isConnected: true,
                applicationState: assignments[display.id]?.applicationState ?? .idle
            )
        }
    }

    var filteredWallpapers: [WallpaperItem] {
        let filtered = wallpapers.filter { item in
            let matchesHidden = showsHiddenWallpapers || !item.isHidden
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
            case .displaysOverview, .queue:
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
            return matchesHidden && matchesSearch && matchesType && matchesStatus && matchesDestination
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
        let session = librarySessionID
        let worker = storeWorker
        libraryLoadTask?.cancel()
        libraryLoadTask = Task { [weak self] in
            do {
                let snapshot = try await worker.loadLibrary()
                guard !Task.isCancelled,
                      let self,
                      self.libraryLoadGeneration == loadGeneration,
                      self.isCurrentLibrarySession(session) else { return }
                self.applyLibrarySnapshot(snapshot)
                self.startMetadataEnrichment(for: snapshot.items, generation: metadataGeneration)
                afterLoad?()
            } catch {
                guard !Task.isCancelled,
                      let self,
                      self.libraryLoadGeneration == loadGeneration,
                      self.isCurrentLibrarySession(session) else { return }
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
        pruneHiddenSelection()
    }

    private func pruneHiddenSelection() {
        guard !showsHiddenWallpapers else { return }
        let hiddenIDs = Set(wallpapers.filter(\.isHidden).map(\.id))
        selectedWallpaperIDs.subtract(hiddenIDs)
        if let selectedWallpaperID, hiddenIDs.contains(selectedWallpaperID) {
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

    var totalPageCount: Int {
        WallpaperLibraryPagination.pageCount(
            totalCount: filteredWallpapers.count,
            pageSize: pageSize
        )
    }

    var pageNumbers: [Int] {
        let total = totalPageCount
        guard total > 0 else { return [] }
        let windowSize = min(5, total)
        let halfWindow = windowSize / 2
        var start = max(1, currentPage - halfWindow)
        let end = min(total, start + windowSize - 1)
        start = max(1, end - windowSize + 1)
        return Array(start...end)
    }

    func goToPage(_ pageNumber: Int) {
        currentPage = WallpaperLibraryPagination.normalizedPage(
            pageNumber,
            totalCount: filteredWallpapers.count,
            pageSize: pageSize
        )
        refreshVisibleWallpapers()
        selectedWallpaperID = nil
    }

    /// Updates the page capacity from the visible content area. The first
    /// visible wallpaper stays on screen when a resize changes the capacity.
    func updatePaginationPageSize(_ newSize: Int) {
        let clamped = max(1, newSize)
        guard clamped != pageSize else { return }
        let anchorID = visibleWallpapers.first?.id
        pageSize = clamped
        if let anchorID,
           let index = filteredWallpapers.firstIndex(where: { $0.id == anchorID }) {
            currentPage = index / clamped + 1
        }
        refreshVisibleWallpapers()
    }

    private func resetPagination() {
        currentPage = 1
        refreshVisibleWallpapers()
    }

    private func refreshVisibleWallpapers() {
        currentPage = WallpaperLibraryPagination.normalizedPage(
            currentPage,
            totalCount: filteredWallpapers.count,
            pageSize: pageSize
        )
        visibleWallpapers = WallpaperLibraryPagination.page(
            from: filteredWallpapers,
            pageNumber: currentPage,
            pageSize: pageSize
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

        let session = librarySessionID
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

            guard !Task.isCancelled,
                  let self,
                  self.metadataEnrichmentGeneration == generation,
                  self.isCurrentLibrarySession(session) else { return }
            guard !enriched.isEmpty else { return }

            // Field-level patches only: a full merged array would overwrite
            // renames/favorites that landed while enrichment was running.
            var patches: [UUID: WallpaperStore.MetadataPatch] = [:]
            for enrichedItem in enriched {
                guard let current = self.wallpapers.first(where: { candidate in
                    candidate.id == enrichedItem.id && candidate.sourceURL == enrichedItem.sourceURL && candidate.entryURL == enrichedItem.entryURL
                }) else { continue }
                if current.metadata != enrichedItem.metadata || current.thumbnailURL != enrichedItem.thumbnailURL {
                    patches[enrichedItem.id] = WallpaperStore.MetadataPatch(
                        metadata: enrichedItem.metadata,
                        thumbnailURL: enrichedItem.thumbnailURL
                    )
                }
            }
            guard !patches.isEmpty else { return }
            do {
                let updated = try await self.storeWorker.updateMetadata(patches)
                guard !Task.isCancelled,
                      self.metadataEnrichmentGeneration == generation,
                      self.isCurrentLibrarySession(session) else { return }
                for item in updated where item.type == .video {
                    self.wallpaperManager.updateDuration(for: item.id, duration: item.metadata?.durationSeconds)
                }
                var merged = self.wallpapers
                for item in updated {
                    guard let index = merged.firstIndex(where: { $0.id == item.id }) else { continue }
                    merged[index] = item
                }
                self.wallpapers = merged
                self.refreshVisibleWallpapers()
            } catch {
                guard self.isCurrentLibrarySession(session) else { return }
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
        let session = librarySessionID
        Task { [weak self] in
            do {
                let snapshot = try await worker.createGroup(group, assigning: assignmentIDs)
                guard let self, self.isCurrentLibrarySession(session) else { return }
                self.groupCreationSucceeded = true
                self.pendingGroupAssignmentIDs.removeAll()
                self.applyMutationSnapshot(snapshot, enrichMetadata: false)
            } catch {
                guard let self, self.isCurrentLibrarySession(session) else { return }
                self.lastError = error.localizedDescription
            }
        }
    }

    func beginCreateGroup(for ids: Set<UUID>) {
        pendingGroupAssignmentIDs = ids
        groupCreationSucceeded = false
        isNewGroupSheetPresented = true
    }

    /// Drops a cancelled selection so the next group created from the sidebar
    /// does not silently absorb wallpapers from an earlier dismissed sheet.
    /// A successful create flips the flag before dismissing, so its in-flight
    /// assignment IDs are preserved until the worker snapshot lands.
    func discardPendingGroupAssignment() {
        if groupCreationSucceeded {
            groupCreationSucceeded = false
        } else {
            pendingGroupAssignmentIDs = []
        }
    }

    func assignSelected(to groupID: UUID?) {
        assignWallpapers(selectedWallpaperIDs, to: groupID)
    }

    func assignWallpapers(_ ids: Set<UUID>, to groupID: UUID?) {
        let selectedIDs = Set(wallpapers.lazy.map(\.id)).intersection(ids)
        guard !selectedIDs.isEmpty else { return }
        let worker = storeWorker
        let session = librarySessionID
        Task { [weak self] in
            do {
                let snapshot = try await worker.assign(itemsWithIDs: selectedIDs, to: groupID)
                guard let self, self.isCurrentLibrarySession(session) else { return }
                self.applyMutationSnapshot(snapshot, enrichMetadata: false)
            } catch {
                guard let self, self.isCurrentLibrarySession(session) else { return }
                self.lastError = error.localizedDescription
            }
        }
    }

    func removeSelectedWallpapers() {
        let selectedItems = wallpapers.filter { selectedWallpaperIDs.contains($0.id) }
        guard !selectedItems.isEmpty else { return }
        let removedIDs = Set(selectedItems.map(\.id))
        let worker = storeWorker
        let session = librarySessionID
        Task { [weak self] in
            do {
                let snapshot = try await worker.remove(items: selectedItems)
                guard let self, self.isCurrentLibrarySession(session) else { return }
                // Commit the index first. Only after it succeeds do we ask the
                // player to drop references, so a failed delete cannot leave a
                // half-removed queue/assignment state behind.
                self.wallpaperManager.removeWallpaperIDs(removedIDs)
                self.selectedWallpaperIDs.subtract(removedIDs)
                if let selectedWallpaperID, removedIDs.contains(selectedWallpaperID) {
                    self.selectedWallpaperID = nil
                }
                self.applyMutationSnapshot(snapshot, enrichMetadata: false)
            } catch {
                guard let self, self.isCurrentLibrarySession(session) else { return }
                self.lastError = error.localizedDescription
            }
        }
    }

    func openQueueEditor(for displayID: String) {
        queueEditorDisplayID = displayID
        isQueueEditorPresented = true
    }

    /// Opens the library queue bound to the display's current mode. Falls back
    /// to the legacy per-display editor when no library queue is bound.
    func openQueue(for displayID: String) {
        if let queueID = wallpaperManager.effectiveQueueID(for: displayID) {
            destination = .queue(queueID)
        } else {
            openQueueEditor(for: displayID)
        }
    }

    func saveQueue(
        for display: DisplayService.Display,
        wallpaperIDs: [UUID],
        intervalSeconds: Double,
        transition: WallpaperTransitionEffect,
        isEnabled: Bool
    ) {
        let queueID = wallpaperManager.boundQueue(for: display.id)?.id ?? PlaybackQueue.defaultQueue.id
        var queue = wallpaperManager.queue(with: queueID) ?? .defaultQueue
        // Editor saves are a full replace: the list on screen is the source of
        // truth for both membership and order.
        queue.replaceWallpaperIDs(wallpaperIDs, markingSortMode: .custom)
        queue.defaultIntervalSeconds = intervalSeconds
        queue.transition = transition
        if !wallpaperManager.updateQueue(queue) {
            lastError = queueOperationBlockedError() ?? "保存队列失败，请重试。"
            return
        }
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
        let session = librarySessionID
        Task { [weak self] in
            let inspection = await worker.inspectImportURLs(urls)
            guard let self,
                  self.isCurrentLibrarySession(session),
                  self.pendingImportURLs == urls else { return }
            self.pendingImportCandidates = inspection.candidates
            self.pendingWebEntryCandidates = inspection.webEntryCandidates
            self.isImportInspectionInProgress = false
        }
    }

    func importURLs(_ urls: [URL], entryURL: URL? = nil, storageMode: StorageMode? = nil) {
        let selectedStorageMode = storageMode ?? self.storageMode
        let worker = storeWorker
        let session = librarySessionID
        Task { [weak self] in
            do {
                let result = try await worker.importItems(at: urls, entryURL: entryURL, storageMode: selectedStorageMode)
                guard let self, self.isCurrentLibrarySession(session) else { return }
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
                guard let self, self.isCurrentLibrarySession(session) else { return }
                self.isImporting = false
                self.isImportInspectionInProgress = false
                self.lastError = error.localizedDescription
            }
        }
    }

    func importWebWallpaper(_ url: URL) {
        let worker = storeWorker
        let session = librarySessionID
        Task { [weak self] in
            do {
                let result = try await worker.importWebURL(url)
                guard let self, self.isCurrentLibrarySession(session) else { return }
                self.applyMutationSnapshot(result.snapshot, enrichMetadata: false)
                self.selectedWallpaperID = result.importedIDs.first
                self.importSummary = ImportSummary(importedCount: 1, failures: [])
            } catch {
                guard let self, self.isCurrentLibrarySession(session) else { return }
                self.lastError = error.localizedDescription
            }
        }
    }

    func importDroppedFiles(from providers: [NSItemProvider]) {
        let collector = DropURLCollector(providerCount: providers.count)
        let session = librarySessionID
        for (index, provider) in providers.enumerated() {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] data, error in
                guard error == nil else {
                    collector.submit(nil, at: index)
                    Task { @MainActor [weak self] in
                        guard let self, self.isCurrentLibrarySession(session) else { return }
                        if let urls = collector.drain() {
                            self.beginImport(urls)
                        }
                    }
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
                collector.submit(url, at: index)
                Task { @MainActor [weak self] in
                    guard let self, self.isCurrentLibrarySession(session) else { return }
                    if let urls = collector.drain() {
                        self.beginImport(urls)
                    }
                }
            }
        }
        // Watchdog: an NSItemProvider that never calls back would otherwise
        // leave the whole drop silently hanging. After the grace period, force
        // only the *missing* slots to finish so the collected URLs still
        // import and the user gets a partial-failure notice instead of
        // nothing. isComplete() guards the normal case: a drop that already
        // finished must not be re-drained or misreported as a timeout, and a
        // complete-but-not-yet-drained drop must not be stolen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.isCurrentLibrarySession(session) else { return }
            if collector.isComplete() {
                if let urls = collector.drain() {
                    self.beginImport(urls)
                }
                return
            }
            collector.forceFinishMissing()
            if let urls = collector.drain() {
                self.beginImport(urls)
                self.lastError = "部分拖拽文件读取失败或超时，仅导入了已读取的文件。"
            } else {
                self.lastError = "部分拖拽文件读取失败或超时，未能导入。"
            }
        }
    }

    @discardableResult
    func setLibraryURL(_ url: URL) -> Bool {
        let normalizedURL = url.standardizedFileURL
        guard !Self.isTemporaryLibraryURL(normalizedURL) else {
            lastError = "不能使用临时目录作为壁纸库：\(normalizedURL.path)。临时目录可能在关机或重启后被系统清理，请选择文稿、图片或其他长期保存的位置。"
            return false
        }
        do {
            try FileManager.default.createDirectory(at: normalizedURL, withIntermediateDirectories: true)
            try libraryAccess.persist(url: normalizedURL)
        } catch {
            lastError = "无法保存壁纸库位置：\(error.localizedDescription)"
            return false
        }
        libraryURL = normalizedURL
        shouldCreateMissingLibraryDirectory = false
        // Invalidate every in-flight mutation from the previous library before
        // swapping workers, and clear the old library's UI state so it cannot
        // be used to delete/apply items in the new one.
        librarySessionID = UUID()
        metadataEnrichmentTask?.cancel()
        libraryLoadTask?.cancel()
        wallpapers = []
        groups = []
        visibleWallpapers = []
        selectedWallpaperIDs.removeAll()
        selectedWallpaperID = nil
        pendingImportURLs = []
        pendingImportCandidates = []
        pendingWebEntryCandidates = []
        isImporting = false
        isImportInspectionInProgress = false
        pendingDeleteIDs = []
        pendingGroupAssignmentIDs = []
        pendingQueueAssignmentIDs = []
        isNewGroupSheetPresented = false
        isQueueEditorPresented = false
        queueEditorDisplayID = nil
        isDeleteConfirmationPresented = false
        undoOperation = nil
        toastMessage = nil
        activeToastID = nil
        lastError = nil
        showsHiddenWallpapers = false
        hiddenPasswordIsSet = false
        hiddenAuthRequest = nil
        hiddenAuthError = nil
        store = WallpaperStore(libraryURL: libraryURL)
        storeWorker = WallpaperStoreWorker(libraryURL: libraryURL)
        hiddenPasswordIsSet = (try? store.hiddenWallpaperLock()) != nil
        UserDefaults.standard.set(libraryURL.path, forKey: SettingsKey.libraryPath)
        wallpaperManager.configure(store: store, policy: playbackPolicy)
        reload(afterLoad: restoreWallpaperAssignments)
        return true
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

    func chooseNewLibraryURL() {
        let panel = NSOpenPanel()
        panel.title = "选择壁纸库位置"
        panel.message = "壁纸库索引和副本将保存到这个文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = libraryURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setLibraryURL(url)
    }

    func chooseLibraryForMigration() {
        guard !isMigratingLibrary else { return }
        guard !isImporting, !isImportInspectionInProgress else {
            lastError = "请先完成当前导入，再迁移壁纸库。"
            return
        }
        let panel = NSOpenPanel()
        panel.title = "迁移壁纸库"
        panel.message = "选择一个空文件夹或新建文件夹。当前壁纸库会完整复制到新位置，完成后可决定是否删除旧库。"
        panel.prompt = "迁移到这里"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = libraryURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        migrateLibrary(to: url)
    }

    func migrateLibrary(to destination: URL) {
        guard !isMigratingLibrary else { return }
        let source = libraryURL.standardizedFileURL
        let destination = destination.standardizedFileURL
        guard !Self.isTemporaryLibraryURL(destination) else {
            lastError = "不能迁移到临时目录：\(destination.path)。请选择文稿、图片或其他长期保存的位置。"
            return
        }
        guard destination != source else {
            lastError = "迁移目标与当前壁纸库相同。"
            return
        }

        let worker = storeWorker
        let session = librarySessionID
        metadataEnrichmentTask?.cancel()
        libraryLoadTask?.cancel()
        isMigratingLibrary = true
        Task { [weak self] in
            do {
                let result = try await worker.migrateLibrary(to: destination)
                guard let self, self.isCurrentLibrarySession(session) else { return }
                guard self.setLibraryURL(destination) else {
                    self.isMigratingLibrary = false
                    return
                }
                self.isMigratingLibrary = false
                self.libraryMigrationCompletion = LibraryMigrationCompletion(
                    oldURL: source,
                    newURL: destination,
                    fileCount: result.fileCount,
                    byteCount: result.byteCount
                )
                self.showToast("壁纸库已迁移")
            } catch {
                guard let self, self.isCurrentLibrarySession(session) else { return }
                self.isMigratingLibrary = false
                self.lastError = error.localizedDescription
            }
        }
    }

    func deleteOldLibrary(at oldURL: URL) {
        let oldURL = oldURL.standardizedFileURL.resolvingSymlinksInPath()
        let current = libraryURL.standardizedFileURL.resolvingSymlinksInPath()
        guard oldURL != current,
              !current.path.hasPrefix(oldURL.path + "/") else {
            lastError = "拒绝删除当前壁纸库或其父目录：\(oldURL.path)"
            return
        }
        let worker = storeWorker
        Task { [weak self] in
            do {
                try await worker.removeLibrary(at: oldURL)
                guard let self else { return }
                self.showToast("已删除旧壁纸库")
            } catch {
                guard let self else { return }
                self.lastError = "旧壁纸库删除失败：\(error.localizedDescription)"
            }
        }
    }

    func setFitModeOverride(_ mode: WallpaperFitMode?, for item: WallpaperItem) {
        guard item.fitModeOverride != mode else { return }
        let worker = storeWorker
        let session = librarySessionID
        Task { [weak self] in
            do {
                let persisted = try await worker.updateFitModeOverride(id: item.id, mode: mode)
                guard let self, self.isCurrentLibrarySession(session) else { return }
                if let index = self.wallpapers.firstIndex(where: { $0.id == item.id }) {
                    self.wallpapers[index] = persisted
                    self.refreshVisibleWallpapers()
                }
                self.wallpaperManager.updateFitMode(for: persisted)
            } catch {
                guard let self, self.isCurrentLibrarySession(session) else { return }
                self.lastError = error.localizedDescription
            }
        }
    }

    // MARK: - Hidden wallpapers

    func requestSetShowsHiddenWallpapers(_ enabled: Bool) {
        guard enabled != showsHiddenWallpapers else { return }
        if !enabled {
            lockHiddenWallpapers()
            return
        }
        hiddenPasswordIsSet = (try? store.hiddenWallpaperLock()) != nil
        presentHiddenAuth(
            mode: hiddenPasswordIsSet ? .unlock : .setPassword,
            purpose: .enableVisibility
        )
    }

    func setHidden(_ isHidden: Bool, for ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        if isHidden {
            guard showsHiddenWallpapers else {
                hiddenPasswordIsSet = (try? store.hiddenWallpaperLock()) != nil
                presentHiddenAuth(
                    mode: hiddenPasswordIsSet ? .unlock : .setPassword,
                    purpose: .hide(ids)
                )
                return
            }
        } else {
            // Hidden items are not reachable unless hidden mode is unlocked.
            guard showsHiddenWallpapers else { return }
        }
        persistHidden(isHidden, for: ids)
    }

    func cancelHiddenAuth() {
        hiddenAuthRequest = nil
        hiddenAuthError = nil
    }

    func submitHiddenPassword(_ password: String, confirmation: String?) {
        guard let request = hiddenAuthRequest else { return }
        hiddenAuthError = nil
        switch request.mode {
        case .setPassword:
            guard confirmation == password else {
                hiddenAuthError = "两次输入的密码不一致。"
                return
            }
            guard HiddenWallpaperLock.isValidPassword(password) else {
                hiddenAuthError = "密码至少需要 \(HiddenWallpaperLock.minimumPasswordLength) 个字符。"
                return
            }
            let worker = storeWorker
            Task { [weak self] in
                let lock = await Task.detached(priority: .userInitiated) {
                    HiddenWallpaperLock.make(password: password)
                }.value
                guard let self else { return }
                guard let lock else {
                    self.hiddenAuthError = "无法生成密码校验信息。"
                    return
                }
                do {
                    try await worker.save(hiddenWallpaperLock: lock)
                } catch {
                    self.hiddenAuthError = "无法保存密码：\(error.localizedDescription)"
                    return
                }
                guard self.hiddenAuthRequest?.id == request.id else { return }
                self.hiddenPasswordIsSet = true
                self.finishHiddenAuth(request)
            }
        case .unlock:
            guard let lock = (try? store.hiddenWallpaperLock()) ?? nil else {
                hiddenAuthError = "未找到密码配置。"
                return
            }
            Task { [weak self] in
                let verified = await Task.detached(priority: .userInitiated) {
                    lock.verify(password: password)
                }.value
                guard let self, self.hiddenAuthRequest?.id == request.id else { return }
                guard verified else {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    if self.hiddenAuthRequest?.id == request.id {
                        self.hiddenAuthError = "密码不正确。"
                    }
                    return
                }
                self.finishHiddenAuth(request)
            }
        }
    }

    private func presentHiddenAuth(
        mode: HiddenWallpaperAuthRequest.Mode,
        purpose: HiddenWallpaperAuthRequest.Purpose
    ) {
        hiddenAuthError = nil
        hiddenAuthRequest = HiddenWallpaperAuthRequest(mode: mode, purpose: purpose)
    }

    private func finishHiddenAuth(_ request: HiddenWallpaperAuthRequest) {
        hiddenAuthRequest = nil
        hiddenAuthError = nil
        switch request.purpose {
        case .enableVisibility:
            showsHiddenWallpapers = true
            wallpaperManager.setShowsHiddenWallpapers(true, policy: playbackPolicy, items: wallpapers)
            refreshVisibleWallpapers()
        case .hide(let ids):
            persistHidden(true, for: ids)
        }
    }

    /// Re-hides hidden wallpapers from the global shortcut. Enabling hidden
    /// visibility still requires the password; closing it never does.
    private func hideHiddenWallpapersFromShortcut() {
        guard showsHiddenWallpapers else { return }
        lockHiddenWallpapers()
    }

    private func lockHiddenWallpapers() {
        showsHiddenWallpapers = false
        hiddenAuthRequest = nil
        hiddenAuthError = nil
        wallpaperManager.setShowsHiddenWallpapers(false, policy: playbackPolicy, items: wallpapers)
        pruneHiddenSelection()
        refreshVisibleWallpapers()
    }

    private func persistHidden(_ isHidden: Bool, for ids: Set<UUID>) {
        let worker = storeWorker
        let session = librarySessionID
        Task { [weak self] in
            var updated: [WallpaperItem] = []
            do {
                for id in ids {
                    updated.append(try await worker.updateHidden(id: id, isHidden: isHidden))
                }
            } catch {
                guard let self, self.isCurrentLibrarySession(session) else { return }
                self.lastError = error.localizedDescription
                return
            }
            guard let self, self.isCurrentLibrarySession(session) else { return }
            for item in updated {
                if let index = self.wallpapers.firstIndex(where: { $0.id == item.id }) {
                    self.wallpapers[index] = item
                }
            }
            self.wallpaperManager.updateHiddenState(for: updated)
            if isHidden {
                self.wallpaperManager.removeHiddenItemsFromDefaultQueues(ids)
            }
            self.refreshVisibleWallpapers()
            if !self.showsHiddenWallpapers {
                self.wallpaperManager.setShowsHiddenWallpapers(
                    false,
                    policy: self.playbackPolicy,
                    items: self.wallpapers
                )
                self.pruneHiddenSelection()
            }
            self.showToast(isHidden ? "已隐藏 \(updated.count) 项" : "已取消隐藏 \(updated.count) 项")
        }
    }

    func apply(item: WallpaperItem, to display: DisplayService.Display) {
        guard item.availability == .available else {
            lastError = "资源不可用，请先恢复文件后重试。"
            return
        }
        do {
            try wallpaperManager.apply(item: item, to: display, policy: playbackPolicy)
            if let index = wallpapers.firstIndex(where: { $0.id == item.id }) {
                wallpapers[index].lastUsedAt = Date()
                let worker = storeWorker
                let session = librarySessionID
                Task { [weak self] in
                    do {
                        // Field-level write: a stale whole-item snapshot could
                        // erase a concurrent fit-mode or metadata change.
                        let persisted = try await worker.touchLastUsed(id: item.id)
                        guard let self,
                              self.isCurrentLibrarySession(session),
                              let currentIndex = self.wallpapers.firstIndex(where: { $0.id == persisted.id }) else { return }
                        self.wallpapers[currentIndex] = persisted
                    } catch {
                        guard let self, self.isCurrentLibrarySession(session) else { return }
                        self.lastError = error.localizedDescription
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
        let shouldPlay = !wallpaperManager.isAnyDynamicWallpaperPlaying
        wallpaperManager.setPlaybackEnabledForAll(shouldPlay)
        NotificationCenter.default.post(
            name: .wallpaperMacPlaybackStateChanged,
            object: nil,
            userInfo: ["isPlaying": shouldPlay]
        )
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
        let session = librarySessionID
        Task { [weak self] in
            do {
                let refreshed = try await worker.refreshAvailability(for: item)
                guard let self,
                      self.isCurrentLibrarySession(session),
                      let index = self.wallpapers.firstIndex(where: { $0.id == item.id }) else { return }
                self.wallpapers[index] = refreshed
                self.refreshVisibleWallpapers()
            } catch {
                guard let self, self.isCurrentLibrarySession(session) else { return }
                self.lastError = error.localizedDescription
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
        let session = librarySessionID
        Task { [weak self] in
            do {
                let snapshot = try await worker.relocate(item: item, to: url)
                guard let self, self.isCurrentLibrarySession(session) else { return }
                self.applyMutationSnapshot(snapshot)
            } catch {
                guard let self, self.isCurrentLibrarySession(session) else { return }
                self.lastError = error.localizedDescription
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
        let worker = storeWorker
        let session = librarySessionID
        Task { [weak self] in
            do {
                let snapshot = try await worker.remove(items: items)
                guard let self, self.isCurrentLibrarySession(session) else { return }
                // Index first; keep queue/display references intact on failure.
                self.wallpaperManager.removeWallpaperIDs(removedIDs)
                self.selectedWallpaperIDs.subtract(removedIDs)
                if let selectedWallpaperID, removedIDs.contains(selectedWallpaperID) {
                    self.selectedWallpaperID = nil
                }
                self.applyMutationSnapshot(snapshot, enrichMetadata: false)
            } catch {
                guard let self, self.isCurrentLibrarySession(session) else { return }
                self.lastError = error.localizedDescription
            }
        }
    }

    func showInFinder(_ item: WallpaperItem) {
        let url = item.entryURL ?? item.sourceURL
        if url.isFileURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    var queueLibrary: [PlaybackQueue] { wallpaperManager.playbackQueues }

    func queueKind(_ queue: PlaybackQueue) -> PlaybackQueueKind {
        let byID = UniquedDictionary.build(wallpapers.map { ($0.id, $0) }, label: "queue items")
        return queue.kind(items: byID)
    }

    func queues(for kind: PlaybackQueueKind) -> [PlaybackQueue] {
        queueLibrary
            .filter { queueKind($0) == kind }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func queueSlotID(for displayID: String, kind: PlaybackQueueKind) -> UUID? {
        wallpaperManager.queueSlotID(for: displayID, kind: kind)
    }

    func queueSlotIsValid(for displayID: String, kind: PlaybackQueueKind) -> Bool {
        guard let queueID = queueSlotID(for: displayID, kind: kind),
              let queue = wallpaperManager.queue(with: queueID) else {
            return kind == .hidden
        }
        return queueKind(queue) == kind
    }

    @discardableResult
    func setQueueSlot(_ kind: PlaybackQueueKind, queue: PlaybackQueue?, for displayID: String) -> Bool {
        guard let display = displayService.displays.first(where: { $0.id == displayID }) else {
            lastError = "该显示器当前不可用。"
            return false
        }
        let accepted = wallpaperManager.setQueueSlot(
            kind,
            queueID: queue?.id,
            for: display.id,
            policy: playbackPolicy,
            items: wallpapers
        )
        if !accepted {
            lastError = kind == .normal
                ? "默认模式只能选择不含隐藏壁纸的队列。"
                : "隐藏模式只能选择包含隐藏壁纸的队列。"
        }
        return accepted
    }

    func beginCreateQueue(for ids: Set<UUID> = []) {        pendingQueueAssignmentIDs = ids
        isNewQueueSheetPresented = true
    }

    @discardableResult
    func createQueue(named name: String) -> PlaybackQueue? {
        guard let queue = wallpaperManager.createQueue(named: name) else {
            lastError = queueOperationBlockedError() ?? "已经存在同名播放队列，或名称为空。"
            return nil
        }
        if !pendingQueueAssignmentIDs.isEmpty {
            wallpaperManager.addWallpaperIDs(Array(pendingQueueAssignmentIDs), to: queue.id, items: wallpapers)
            pendingQueueAssignmentIDs.removeAll()
        }
        return wallpaperManager.queue(with: queue.id)
    }

    @discardableResult
    func duplicateQueue(_ queue: PlaybackQueue) -> PlaybackQueue? {
        guard let copy = wallpaperManager.createQueue(
            named: "\(queue.name) 副本",
            playbackMode: queue.playbackMode,
            completionBehavior: queue.completionBehavior,
            advanceMode: queue.advanceMode,
            defaultIntervalSeconds: queue.defaultIntervalSeconds,
            transition: queue.transition
        ) else {
            lastError = "无法创建队列副本，请检查名称是否重复。"
            return nil
        }
        var duplicate = copy
        duplicate.sortMode = queue.sortMode
        duplicate.itemIntervalOverrides = queue.itemIntervalOverrides
        duplicate.addWallpaperIDs(queue.wallpaperIDs)
        _ = wallpaperManager.updateQueue(duplicate)
        return wallpaperManager.queue(with: copy.id)
    }

    func deleteQueue(_ queue: PlaybackQueue) {
        guard !queue.isDefault else {
            lastError = "默认队列不可删除。"
            return
        }
        if !wallpaperManager.deleteQueue(id: queue.id, policy: playbackPolicy, items: wallpapers) {
            lastError = queueOperationBlockedError() ?? "删除队列失败，请重试。"
        }
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
        if !wallpaperManager.updateQueue(updated) {
            lastError = queueOperationBlockedError() ?? "调整队列顺序失败，请重试。"
        }
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
        let session = librarySessionID
        Task { [weak self] in
            do {
                let snapshot = try await worker.setFavorite(itemIDs: ids, isFavorite: shouldFavorite)
                guard let self, self.isCurrentLibrarySession(session) else { return }
                self.applyMutationSnapshot(snapshot, enrichMetadata: false)
            } catch {
                guard let self, self.isCurrentLibrarySession(session) else { return }
                self.lastError = error.localizedDescription
            }
        }
    }

    func showToast(_ message: String, undo: (() -> Void)? = nil) {
        // Tag each toast so a stale timer cannot clear a newer one that reused
        // the same message text (including undo prompts).
        let toastID = UUID()
        activeToastID = toastID
        toastMessage = message
        undoOperation = undo
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.activeToastID == toastID else { return }
            self.toastMessage = nil
            self.undoOperation = nil
            self.activeToastID = nil
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
            fitMode: WallpaperFitMode(rawValue: defaults.string(forKey: SettingsKey.fitMode) ?? "") ?? .fill,
            webWallpaperInteractionEnabled: defaults.object(forKey: SettingsKey.webWallpaperInteractionEnabled) as? Bool ?? false
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
    @ObservedObject private var themeStore = ThemeStore.shared
    @AppStorage(SettingsKey.onboardingCompleted) private var onboardingCompleted = false

    var body: some View {
        Group {
            if onboardingCompleted {
                mainWorkspace
                    .id(themeStore.activeTheme.id)
            } else {
                OnboardingView(model: model) {
                    onboardingCompleted = true
                }
                .id(themeStore.activeTheme.id)
            }
        }
        .preferredColorScheme(themeStore.activeTheme.colorScheme)
        .tint(AppTheme.Palette.accent)
        .background(AppTheme.Palette.canvas)
        .sheet(isPresented: $model.isImporting) {
            ImportSheet(model: model)
        }
        .sheet(isPresented: $model.isWebURLImportPresented) {
            WebWallpaperURLImportSheet { model.importWebWallpaper($0) }
        }
        .sheet(isPresented: $model.isNewGroupSheetPresented, onDismiss: {
            model.discardPendingGroupAssignment()
        }) {
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
        .sheet(isPresented: $model.isNewQueueSheetPresented) {
            NewQueueSheet { name in
                if let queue = model.createQueue(named: name) {
                    model.destination = .queue(queue.id)
                }
            }
        }
        .sheet(item: $model.hiddenAuthRequest) { request in
            HiddenWallpaperAuthSheet(model: model, request: request)
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
            VStack(spacing: 10) {
                if let warning = model.queuePersistenceWarning {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(AppTheme.Palette.warning)
                        Text(warning)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("重试加载") { model.retryQueuePersistence() }
                            .buttonStyle(.borderless)
                            .foregroundStyle(AppTheme.Palette.accent)
                    }
                    .font(.callout)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.horizontal, 24)
                }
                if let toast = model.toastMessage {
                    HStack(spacing: 12) {
                        Text(toast)
                        if model.canUndoToast {
                            Button("撤销") { model.undoLastAction() }
                                .buttonStyle(.borderless)
                                .foregroundStyle(AppTheme.Palette.accent)
                        }
                    }
                    .font(.callout)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 18)
                }
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
        .onReceive(NotificationCenter.default.publisher(for: .wallpaperMacShowDisplaysOverview)) { _ in
            model.destination = .displaysOverview
        }
    }

    private var mainWorkspace: some View {
        HStack(spacing: 0) {
            SidebarView(model: model)
                .frame(width: MainWindowMetrics.sidebarWidth)
            ThemeVerticalHairline()
            WorkspaceContentView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.destination.isLibraryWorkspace {
                ThemeVerticalHairline()
                InspectorView(model: model)
                    .frame(width: MainWindowMetrics.inspectorWidth)
            }
        }
        .background(AppTheme.Palette.canvas)
        .disabled(model.isMigratingLibrary)
        .overlay {
            if model.isMigratingLibrary {
                ZStack {
                    Color.black.opacity(0.28).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text("正在迁移壁纸库…")
                            .font(.headline)
                        Text("正在复制索引、素材和缩略图，请勿退出应用。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(28)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
        .confirmationDialog(
            "壁纸库迁移完成",
            isPresented: Binding(
                get: { model.libraryMigrationCompletion != nil },
                set: { if !$0 { model.libraryMigrationCompletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("保留旧库", role: .cancel) {
                model.libraryMigrationCompletion = nil
            }
            Button("删除旧库", role: .destructive) {
                if let completion = model.libraryMigrationCompletion {
                    model.deleteOldLibrary(at: completion.oldURL)
                }
                model.libraryMigrationCompletion = nil
            }
        } message: {
            if let completion = model.libraryMigrationCompletion {
                Text("新位置：\(completion.newURL.path)\n旧库仍保存在：\(completion.oldURL.path)。是否删除旧库？")
            }
        }
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
        HStack(spacing: 0) {
            onboardingSidebar
                .frame(width: 220)
            ThemeVerticalHairline()
            VStack(spacing: 0) {
                header
                ThemeHairline()
                GeometryReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            Spacer(minLength: 24)
                            HStack(alignment: .top, spacing: 18) {
                                Image(systemName: icon)
                                    .font(.system(size: 44, weight: .light))
                                    .foregroundStyle(AppTheme.Palette.accent)
                                    .frame(width: 54, alignment: .leading)
                                VStack(alignment: .leading, spacing: 16) {
                                    Text(message)
                                        .font(AppTheme.Typography.body)
                                        .foregroundStyle(AppTheme.Palette.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    content
                                        .frame(maxWidth: 760, alignment: .leading)
                                }
                            }
                            .frame(maxWidth: 820, alignment: .leading)
                            .padding(.horizontal, 28)
                            Spacer(minLength: 24)
                        }
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .center)
                    }
                }
                ThemeHairline()
                footer
            }
        }
        .background(AppTheme.Palette.canvas)
        .onAppear { model.prepareLibrary() }
        .onChange(of: launchAtLogin) { enabled in
            do {
                try LoginItemService.setEnabled(enabled)
            } catch {
                model.lastError = "登录项设置失败：\(error.localizedDescription)"
            }
        }
    }

    private var onboardingSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("WallpaperMac")
                    .font(AppTheme.Typography.display(19))
                    .foregroundStyle(AppTheme.Palette.text)
                Text("首次设置")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Palette.textTertiary)
            }
            .padding(.horizontal, 16)
            .frame(height: MainWindowMetrics.libraryHeaderHeight, alignment: .center)

            ThemeHairline()

            VStack(spacing: 2) {
                ForEach(Array(stepTitles.enumerated()), id: \.offset) { index, item in
                    OnboardingStepRow(
                        index: index,
                        title: item,
                        isSelected: step == index
                    ) {
                        step = index
                    }
                }
            }
            .padding(8)

            Spacer()
            Text("第 \(step + 1) / 4 步")
                .font(AppTheme.Typography.mono(9.5))
                .foregroundStyle(AppTheme.Palette.textTertiary)
                .padding(16)
        }
        .background(AppTheme.Palette.sidebar)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(AppTheme.Typography.pageTitle)
                .foregroundStyle(AppTheme.Palette.text)
            Spacer()
            Text(stepTitles[step])
                .font(AppTheme.Typography.mono(9.5))
                .foregroundStyle(AppTheme.Palette.textTertiary)
        }
        .padding(.horizontal, 24)
        .frame(height: MainWindowMetrics.libraryHeaderHeight)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if step > 0 {
                Button("上一步") { step -= 1 }
                    .buttonStyle(QuietButtonStyle())
            }
            Spacer()
            Button(step == 3 ? "完成并进入壁纸库" : "继续") {
                if step == 3 {
                    NotificationCenter.default.post(name: .wallpaperMacSettingsChanged, object: nil)
                    model.prepareLibrary()
                    finish()
                } else {
                    step += 1
                }
            }
            .buttonStyle(AccentActionButtonStyle())
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var stepTitles: [String] {
        ["欢迎", "壁纸库", "后台行为", "权限检查"]
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
        case 0: return "用图片、视频、本地 HTML 项目或在线网址打造 macOS 壁纸。本地素材保存在壁纸库，在线网页需要网络连接。"
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
                OnboardingFeature(title: "网页 / 网址", icon: "safari")
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
                    Button("选择文件夹") { model.chooseNewLibraryURL() }
                }
                Text("当前目录会自动创建 Assets 和索引文件，不会添加演示壁纸。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .themeInsetSurface()
        case 2:
            VStack(spacing: 0) {
                OnboardingToggleRow(
                    title: "登录时启动",
                    detail: "登录 macOS 后自动打开 WallpaperMac。",
                    isOn: $launchAtLogin
                )
                ThemeHairline()
                OnboardingToggleRow(
                    title: "使用电池时暂停动态壁纸",
                    detail: "节省电量，接入电源后恢复。",
                    isOn: $pauseOnBattery
                )
                ThemeHairline()
                OnboardingToggleRow(
                    title: "全屏应用时暂停动态壁纸",
                    detail: "只暂停全屏窗口所在的显示器。",
                    isOn: $pauseInFullScreen
                )
            }
            .padding(14)
            .themeInsetSurface()
        default:
            let permission = model.libraryPermissionState
            VStack(alignment: .leading, spacing: 10) {
                PermissionRow(title: "读取壁纸库", granted: permission.readable)
                PermissionRow(title: "写入壁纸库", granted: permission.writable)
                if !permission.writable {
                    Text("请在 Finder 中为所选文件夹授予当前用户读写权限，或在进入主界面后重新选择其他位置。")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Palette.warning)
                }
            }
            .padding(16)
            .themeInsetSurface()
        }
    }
}

private struct OnboardingStepRow: View {
    let index: Int
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(isSelected ? AppTheme.Palette.accent : Color.clear)
                    .frame(width: 2, height: 15)
                Text(String(format: "%02d", index + 1))
                    .font(AppTheme.Typography.mono(9, weight: .medium))
                    .foregroundStyle(isSelected ? AppTheme.Palette.accent : AppTheme.Palette.textTertiary)
                    .frame(width: 18, alignment: .leading)
                Text(title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? AppTheme.Palette.text : AppTheme.Palette.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.leading, 4)
            .padding(.trailing, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(
                        isSelected
                            ? AppTheme.Palette.accentWash
                            : (isHovering ? AppTheme.Palette.raised.opacity(0.55) : Color.clear)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct OnboardingToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(AppTheme.Typography.body)
                    .foregroundStyle(AppTheme.Palette.text)
                Text(detail)
                    .font(AppTheme.Typography.micro)
                    .foregroundStyle(AppTheme.Palette.textTertiary)
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(AppTheme.Palette.accent)
        }
        .padding(.vertical, 9)
    }
}

private struct OnboardingFeature: View {
    let title: String
    let icon: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(AppTheme.Palette.accent)
            Text(title)
                .font(AppTheme.Typography.body)
                .foregroundStyle(AppTheme.Palette.text)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .themeInsetSurface()
    }
}

private struct PermissionRow: View {
    let title: String
    let granted: Bool
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? AppTheme.Palette.applied : AppTheme.Palette.warning)
            Text(title)
                .font(AppTheme.Typography.body)
                .foregroundStyle(AppTheme.Palette.text)
            Spacer()
            Text(granted ? "可用" : "待处理")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Palette.textTertiary)
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

    private var hasHiddenMembers: Bool {
        guard !model.showsHiddenWallpapers else { return false }
        return queueItems.contains(where: \.isHidden)
    }

    private var displayedQueueItems: [WallpaperItem] {
        queueItems.filter { model.isWallpaperVisible($0) }
    }

    private var availableItems: [WallpaperItem] {
        model.wallpapers.filter { item in
            model.isWallpaperVisible(item)
                && item.availability == .available
                && !wallpaperIDs.contains(item.id)
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

                    if hasHiddenMembers {
                        Label("队列包含隐藏壁纸，解锁后可编辑成员；播放时会自动跳过。", systemImage: "eye.slash")
                            .font(.caption)
                            .foregroundStyle(AppTheme.Palette.warning)
                    }

                    if displayedQueueItems.isEmpty {
                        Text(hasHiddenMembers ? "当前没有可显示的队列成员。" : "队列为空，请添加至少一项可用壁纸。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    } else {
                        List {
                            ForEach(Array(displayedQueueItems.enumerated()), id: \.element.id) { index, item in
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
                                    .disabled(hasHiddenMembers || index == 0)
                                    .help("上移")
                                    Button {
                                        swapQueueItems(at: index, with: index + 1)
                                    } label: {
                                        Image(systemName: "chevron.down")
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(hasHiddenMembers || index == displayedQueueItems.count - 1)
                                    .help("下移")
                                    Button {
                                        wallpaperIDs.removeAll { $0 == item.id }
                                    } label: {
                                        Image(systemName: "minus.circle")
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(hasHiddenMembers)
                                    .help("移出队列")
                                }
                            }
                            .onMove { offsets, destination in
                                guard !hasHiddenMembers else { return }
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
                    .disabled(hasHiddenMembers)
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
        .groupBoxStyle(ThemeGroupBoxStyle())
    }

    private func moveQueueItems(from offsets: IndexSet, to destination: Int) {
        // The list shows only resolved items; wallpaperIDs may still contain
        // placeholders for deleted wallpapers. Translate visible offsets onto
        // wallpaperIDs so a reorder cannot silently drop those rows.
        let visibleIDs = queueItems.map(\.id)
        let wallpaperIndices = visibleIDs.compactMap { id in wallpaperIDs.firstIndex(of: id) }
        guard wallpaperIndices.count == visibleIDs.count else { return }
        let source = IndexSet(offsets.compactMap { offset -> Int? in
            guard wallpaperIndices.indices.contains(offset) else { return nil }
            return wallpaperIndices[offset]
        })
        let dest: Int = {
            if wallpaperIndices.indices.contains(destination) {
                return wallpaperIndices[destination]
            }
            return wallpaperIDs.count
        }()
        var ids = wallpaperIDs
        ids.move(fromOffsets: source, toOffset: dest)
        wallpaperIDs = ids
    }

    private func swapQueueItems(at index: Int, with otherIndex: Int) {
        let visibleIDs = queueItems.map(\.id)
        guard visibleIDs.indices.contains(index), visibleIDs.indices.contains(otherIndex) else { return }
        guard let first = wallpaperIDs.firstIndex(of: visibleIDs[index]),
              let second = wallpaperIDs.firstIndex(of: visibleIDs[otherIndex]) else { return }
        wallpaperIDs.swapAt(first, second)
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
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("壁纸库")
                    .font(AppTheme.Typography.display(19))
                    .foregroundStyle(AppTheme.Palette.text)
                Spacer()
                Text(verbatim: "\(visibleItems.count)")
                    .font(AppTheme.Typography.mono(10))
                    .foregroundStyle(AppTheme.Palette.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 14)

            ThemeHairline()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    SidebarRow(title: "全部壁纸", icon: "square.grid.2x2", isSelected: model.destination == .all, trailing: "\(visibleItems.count)") { model.destination = .all }
                    SidebarRow(title: "图片", icon: "photo", isSelected: model.destination == .images, trailing: "\(count(of: .image))") { model.destination = .images }
                    SidebarRow(title: "视频", icon: "film", isSelected: model.destination == .videos, trailing: "\(count(of: .video))") { model.destination = .videos }
                    SidebarRow(title: "网页", icon: "safari", isSelected: model.destination == .web, trailing: "\(count(of: .web))") { model.destination = .web }
                    SidebarRow(title: "收藏", icon: "star", isSelected: model.destination == .favorites, trailing: "\(visibleItems.filter(\.isFavorite).count)") { model.destination = .favorites }
                    SidebarRow(title: "最近使用", icon: "clock", isSelected: model.destination == .recent) { model.destination = .recent }

                    if !model.displayRows.isEmpty {
                        sectionHeader("显示器")
                        SidebarRow(
                            title: "总览",
                            icon: "rectangle.grid.2x2",
                            isSelected: model.destination == .displaysOverview,
                            trailing: "\(model.displayRows.count)"
                        ) {
                            model.destination = .displaysOverview
                        }
                        ForEach(model.displayRows) { display in
                            SidebarRow(
                                title: display.name,
                                icon: display.isConnected ? "display" : "display.trianglebadge.exclamationmark",
                                isSelected: model.destination == .display(display.id),
                                trailing: display.isConnected ? nil : "断开",
                                trailingColor: AppTheme.Palette.warning,
                                statusDot: display.isConnected ? AppTheme.Palette.applied : AppTheme.Palette.warning
                            ) {
                                model.destination = .display(display.id)
                            }
                        }
                    }

                    sectionHeader("播放队列") {
                        Button { model.beginCreateQueue() } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                        .help("新建播放队列")
                    }

                    ForEach(model.queueLibrary) { queue in
                        SidebarRow(
                            title: queue.name,
                            icon: queueIcon(queue),
                            isSelected: model.destination == .queue(queue.id),
                            trailing: "\(visibleWallpaperCount(queue))"
                        ) {
                            model.destination = .queue(queue.id)
                        }
                    }

                    sectionHeader("分组") {
                        Button { model.beginCreateGroup(for: []) } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                        .help("新建分组")
                    }

                    ForEach(model.groups) { group in
                        SidebarRow(
                            title: group.name,
                            icon: "folder",
                            isSelected: model.destination == .group(group.id),
                            trailing: "\(groupCount(group.id))"
                        ) {
                            model.destination = .group(group.id)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
            }

            Spacer(minLength: 8)
            ThemeHairline()
            HStack(spacing: 6) {
                Image(systemName: model.showsHiddenWallpapers ? "eye" : "eye.slash")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(model.showsHiddenWallpapers ? AppTheme.Palette.accent : AppTheme.Palette.textTertiary)
                    .frame(width: 14)
                Text("显示隐藏壁纸")
                    .font(AppTheme.Typography.micro)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                Spacer(minLength: 4)
                Toggle("显示隐藏壁纸", isOn: Binding(
                    get: { model.showsHiddenWallpapers },
                    set: { model.requestSetShowsHiddenWallpapers($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(AppTheme.Palette.accent)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .help("隐藏壁纸默认不显示；打开需要密码")
            .accessibilityLabel("显示隐藏壁纸")

            ThemeHairline()
                .padding(.horizontal, 10)

            HStack(spacing: 6) {
                ThemeIconButton(systemName: "folder", help: "迁移壁纸库") {
                    model.chooseLibraryForMigration()
                }
                Text(model.libraryURL.lastPathComponent)
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.libraryURL.path)
                Spacer(minLength: 4)
                ThemeIconButton(systemName: "gearshape", help: "设置") {
                    (NSApp.delegate as? AppDelegate)?.showSettingsWindow()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(AppTheme.Palette.sidebar)
    }

    private var visibleItems: [WallpaperItem] {
        model.wallpapers.filter { model.isWallpaperVisible($0) }
    }

    private func count(of type: WallpaperType) -> Int {
        visibleItems.filter { $0.type == type }.count
    }

    private func groupCount(_ groupID: UUID) -> Int {
        visibleItems.filter { $0.groupID == groupID }.count
    }

    private func visibleWallpaperCount(_ queue: PlaybackQueue) -> Int {
        queue.wallpaperIDs.filter { id in
            model.wallpapers.first(where: { $0.id == id }).map(model.isWallpaperVisible) ?? false
        }.count
    }

    private func queueIcon(_ queue: PlaybackQueue) -> String {
        if queue.isDefault { return "star" }
        return model.queueKind(queue) == .hidden ? "eye.slash" : "list.bullet.rectangle"
    }

    private func sectionHeader<Accessory: View>(
        _ title: String,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ThemeHairline()
                .padding(.horizontal, 4)
                .padding(.top, 14)
            HStack(spacing: 8) {
                Text(title)
                    .font(AppTheme.Typography.section)
                    .tracking(0.6)
                    .foregroundStyle(AppTheme.Palette.textTertiary)
                Spacer(minLength: 0)
                accessory()
            }
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 4)
        }
    }
}

private struct SidebarRow: View {
    let title: String
    let icon: String
    let isSelected: Bool
    var trailing: String? = nil
    var trailingColor: Color = AppTheme.Palette.textTertiary
    var statusDot: Color? = nil
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(isSelected ? AppTheme.Palette.accent : Color.clear)
                    .frame(width: 2, height: 15)
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? AppTheme.Palette.accent : AppTheme.Palette.textSecondary)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? AppTheme.Palette.text : AppTheme.Palette.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let statusDot {
                    Circle()
                        .fill(statusDot)
                        .frame(width: 4, height: 4)
                }
                if let trailing {
                    Text(trailing)
                        .font(AppTheme.Typography.mono(9.5))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? AppTheme.Palette.accent : trailingColor)
                }
            }
            .padding(.leading, 4)
            .padding(.trailing, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(
                        isSelected
                            ? AppTheme.Palette.accentWash
                            : (isHovering ? AppTheme.Palette.raised.opacity(0.55) : Color.clear)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct WorkspaceContentView: View {
    @ObservedObject var model: LibraryViewModel

    var body: some View {
        switch model.destination {
        case .displaysOverview:
            DisplaysOverviewView(model: model)
        case .display(let displayID):
            DisplayWorkspaceView(model: model, displayID: displayID)
        case .queue(let queueID):
            QueueWorkspaceView(model: model, queueID: queueID)
        default:
            LibraryContentView(model: model)
        }
    }
}

private struct LibraryContentView: View {
    @ObservedObject var model: LibraryViewModel
    @State private var isDropTargeted = false
    @State private var showingBatchRemoveConfirmation = false

    private func gridColumns(_ layout: WallpaperLibraryGridLayout) -> [GridItem] {
        Array(
            repeating: GridItem(
                .fixed(CGFloat(layout.tileWidth)),
                spacing: CGFloat(layout.horizontalSpacing)
            ),
            count: layout.columns
        )
    }

    var body: some View {
        libraryBody
    }

    @ViewBuilder
    private var libraryBody: some View {
        VStack(spacing: 0) {
            libraryHeader

            ThemeHairline()

            if model.filteredWallpapers.isEmpty {
                EmptyLibraryView(
                    hasItems: !model.wallpapers.isEmpty,
                    importAction: { model.importWallpapers() },
                    importURLAction: { model.isWebURLImportPresented = true },
                    clearFiltersAction: {
                        model.searchText = ""
                        model.selectedType = nil
                        model.statusFilter = .all
                    }
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { proxy in
                    Group {
                        if model.layout == .grid {
                            let layout = WallpaperLibraryPageLayout.grid(
                                availableWidth: Double(proxy.size.width),
                                availableHeight: Double(proxy.size.height)
                            )
                            ScrollView {
                                LazyVGrid(
                                    columns: gridColumns(layout),
                                    spacing: CGFloat(layout.verticalSpacing)
                                ) {
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
                                        .contextMenu {
                                            WallpaperContextMenu(model: model, item: item)
                                        }
                                    }
                                }
                                .padding(CGFloat(WallpaperLibraryPageLayout.contentPadding))
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
                                .contextMenu {
                                    WallpaperContextMenu(model: model, item: item)
                                }
                            }
                            .listStyle(.inset)
                            .scrollContentBackground(.hidden)
                            .background(AppTheme.Palette.canvas)
                        }
                    }
                    .onAppear { updatePagination(for: proxy.size) }
                    .onChange(of: proxy.size) { size in
                        updatePagination(for: size)
                    }
                    .onChange(of: model.layout) { _ in
                        updatePagination(for: proxy.size)
                    }
                }
            }

            if !model.filteredWallpapers.isEmpty {
                ThemeHairline()
                paginationBar
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
            model.importDroppedFiles(from: providers)
            return true
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(AppTheme.Palette.accent, style: StrokeStyle(lineWidth: 2, dash: [8]))
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

    private var libraryHeader: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < 870
            HStack(spacing: compact ? 8 : 10) {
                headerTitle(compact: compact)
                Spacer(minLength: 8)
                if model.isSelectionMode {
                    selectionModeControls
                } else if compact {
                    compactBrowseControls
                } else {
                    fullBrowseControls
                }
            }
            .padding(.horizontal, compact ? 16 : 20)
            .frame(width: proxy.size.width, height: MainWindowMetrics.libraryHeaderHeight)
        }
        .frame(height: MainWindowMetrics.libraryHeaderHeight)
    }

    private func headerTitle(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(AppTheme.Typography.pageTitle)
                .foregroundStyle(AppTheme.Palette.text)
                .lineLimit(1)
            Text(headerSubtitle(compact: compact))
                .font(AppTheme.Typography.caption)
                .monospacedDigit()
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .lineLimit(1)
        }
        .frame(width: compact ? 120 : 130, alignment: .leading)
    }

    private func headerSubtitle(compact: Bool) -> String {
        if model.isSelectionMode {
            return "已选 \(model.selectedWallpaperIDs.count) / \(model.filteredWallpapers.count) 项"
        }
        let page = max(model.totalPageCount, 1)
        if compact {
            return "\(model.filteredWallpapers.count) 项　\(model.currentPage)/\(page) 页"
        }
        return "\(model.filteredWallpapers.count) 个资源　第 \(model.currentPage) / \(page) 页"
    }

    @ViewBuilder
    private var selectionModeControls: some View {
        Button("全选") { model.selectAllFiltered() }
            .buttonStyle(.borderless)
            .font(AppTheme.Typography.caption)
            .foregroundStyle(AppTheme.Palette.textSecondary)
        Button("清空") { model.clearSelection() }
            .buttonStyle(.borderless)
            .font(AppTheme.Typography.caption)
            .foregroundStyle(AppTheme.Palette.textSecondary)
        Menu {
            Button("移出分组") { model.assignSelected(to: nil) }
            if !model.groups.isEmpty {
                Divider()
                ForEach(model.groups) { group in
                    Button(group.name) { model.assignSelected(to: group.id) }
                }
            }
            Divider()
            Button("新建分组…") { model.beginCreateGroup(for: []) }
        } label: {
            Label("分组", systemImage: "folder")
                .font(AppTheme.Typography.caption)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        Button("删除", role: .destructive) {
            showingBatchRemoveConfirmation = true
        }
        .buttonStyle(QuietButtonStyle(compact: true))
        .tint(AppTheme.Palette.danger)
        .disabled(model.selectedWallpaperIDs.isEmpty)
        .fixedSize()
        Button("完成") {
            model.clearSelection()
            model.isSelectionMode = false
        }
        .buttonStyle(AccentActionButtonStyle(compact: true))
        .fixedSize()
    }

    @ViewBuilder
    private var fullBrowseControls: some View {
        ThemeSearchField(placeholder: "搜索壁纸", text: $model.searchText, width: 150)
        filterMenu {
            ThemeMenuLabel(title: "筛选", systemImage: "line.3.horizontal.decrease.circle")
        }
        sortMenu {
            ThemeMenuLabel(title: model.sortOrder.title, systemImage: "arrow.up.arrow.down")
        }
        ThemeViewModeSwitch(layout: $model.layout)
        Button { model.isSelectionMode = true } label: {
            Label("批量管理", systemImage: "checklist")
                .font(AppTheme.Typography.caption)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(AppTheme.Palette.textSecondary)
        .fixedSize()
        addWallpaperMenu(compact: false)
    }

    @ViewBuilder
    private var compactBrowseControls: some View {
        ThemeSearchField(placeholder: "搜索", text: $model.searchText, width: 130)
        filterMenu {
            ThemeMenuLabel(title: nil, systemImage: "line.3.horizontal.decrease.circle")
        }
        sortMenu {
            ThemeMenuLabel(title: nil, systemImage: "arrow.up.arrow.down")
        }
        ThemeViewModeSwitch(layout: $model.layout)
        ThemeIconButton(systemName: "checklist", help: "批量管理") {
            model.isSelectionMode = true
        }
        addWallpaperMenu(compact: true)
    }

    private func addWallpaperMenu(compact: Bool) -> some View {
        Menu {
            Button("导入文件或文件夹") { model.importWallpapers() }
            Button("导入网址") { model.isWebURLImportPresented = true }
        } label: {
            if compact {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.Palette.canvas)
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(AppTheme.Palette.accent)
                    )
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                    Text("添加壁纸")
                        .font(.system(size: 12, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                        .opacity(0.7)
                }
                .foregroundStyle(AppTheme.Palette.canvas)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Metrics.controlCorner, style: .continuous)
                        .fill(AppTheme.Palette.accent)
                )
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("添加壁纸")
    }

    private func filterMenu<MenuLabel: View>(@ViewBuilder label: () -> MenuLabel) -> some View {
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
            label()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("筛选类型和状态")
    }

    private func sortMenu<MenuLabel: View>(@ViewBuilder label: () -> MenuLabel) -> some View {
        Menu {
            Picker("排序", selection: $model.sortOrder) {
                ForEach(WallpaperSortOrder.allCases) { order in
                    Text(order.title).tag(order)
                }
            }
        } label: {
            label()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("排序：\(model.sortOrder.title)")
    }

    private func updatePagination(for size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        switch model.layout {
        case .grid:
            let layout = WallpaperLibraryPageLayout.grid(
                availableWidth: Double(size.width),
                availableHeight: Double(size.height)
            )
            model.updatePaginationPageSize(layout.pageSize)
        case .list:
            model.updatePaginationPageSize(
                WallpaperLibraryPageLayout.listPageSize(availableHeight: Double(size.height))
            )
        }
    }

    private var paginationBar: some View {
        HStack(spacing: 10) {
            Text("本页 \(model.visibleWallpapers.count) 项")
                .font(AppTheme.Typography.mono(9.5))
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .frame(minWidth: 72, alignment: .leading)

            Spacer()

            Button {
                model.goToPage(1)
            } label: {
                Image(systemName: "backward.end")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(AppTheme.Palette.textSecondary)
            .disabled(model.currentPage <= 1)
            .help("第一页")

            Button {
                model.goToPage(model.currentPage - 1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(AppTheme.Palette.textSecondary)
            .disabled(model.currentPage <= 1)
            .help("上一页")

            ForEach(model.pageNumbers, id: \.self) { page in
                PageNumberButton(
                    page: page,
                    isCurrent: page == model.currentPage,
                    action: { model.goToPage(page) }
                )
            }

            Button {
                model.goToPage(model.currentPage + 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(AppTheme.Palette.textSecondary)
            .disabled(model.currentPage >= model.totalPageCount)
            .help("下一页")

            Button {
                model.goToPage(model.totalPageCount)
            } label: {
                Image(systemName: "forward.end")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(AppTheme.Palette.textSecondary)
            .disabled(model.currentPage >= model.totalPageCount)
            .help("最后一页")

            Spacer()

            Text("第 \(model.currentPage) / \(model.totalPageCount) 页")
                .font(AppTheme.Typography.mono(9.5))
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .frame(minWidth: 72, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(AppTheme.Palette.panel.opacity(0.7))
    }

    private var title: String {
        switch model.destination {
        case .all: return "全部壁纸"
        case .images: return "图片"
        case .videos: return "视频"
        case .web: return "网页"
        case .favorites: return "收藏"
        case .recent: return "最近使用"
        case .group(let id): return model.groups.first(where: { $0.id == id })?.name ?? "分组"
        case .displaysOverview: return "显示器"
        case .display(let id): return model.displayRows.first(where: { $0.id == id })?.name ?? "显示器"
        case .queue(let id): return model.queueLibrary.first(where: { $0.id == id })?.name ?? "播放队列"
        }
    }
}

private struct PageNumberButton: View {
    let page: Int
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("\(page)")
                .font(AppTheme.Typography.mono(10, weight: isCurrent ? .semibold : .regular))
                .frame(width: 26, height: 24)
                .foregroundStyle(isCurrent ? AppTheme.Palette.accent : AppTheme.Palette.textSecondary)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isCurrent ? AppTheme.Palette.accentWash : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(
                            isCurrent ? AppTheme.Palette.accent.opacity(0.45) : Color.clear,
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("第 \(page) 页")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
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
            if isSelected {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(AppTheme.Palette.accent)
                    .frame(width: 2, height: 32)
            }
            if selectionMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(
                        isSelected
                            ? AppTheme.Palette.accent
                            : AppTheme.Palette.textSecondary
                    )
            }
            ThumbnailView(item: item)
                .frame(width: 110, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(AppTheme.Palette.hairline, lineWidth: 1)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(AppTheme.Typography.bodyMedium)
                    .foregroundStyle(AppTheme.Palette.text)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: iconName)
                        .font(.system(size: 9, weight: .medium))
                    Text(typeName)
                        .font(AppTheme.Typography.micro)
                    if let detailText {
                        Text(detailText)
                            .font(AppTheme.Typography.mono(9))
                            .foregroundStyle(AppTheme.Palette.textTertiary)
                    }
                }
                .foregroundStyle(AppTheme.Palette.textSecondary)
                statusLine
            }
            Spacer(minLength: 8)
            Button(action: favoriteAction) {
                Image(systemName: item.isFavorite ? "star.fill" : "star")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(
                        item.isFavorite
                            ? AppTheme.Palette.accent
                            : AppTheme.Palette.textSecondary
                    )
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(item.isFavorite ? "取消收藏" : "收藏壁纸")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isSelected ? AppTheme.Palette.accentWash : Color.clear)
        )
        .onTapGesture(perform: selectAction)
    }

    @ViewBuilder
    private var statusLine: some View {
        if item.availability != .available {
            Label(availabilityLabel(item.availability), systemImage: "exclamationmark.triangle.fill")
                .font(AppTheme.Typography.micro)
                .foregroundStyle(AppTheme.Palette.danger)
        } else if item.isHidden {
            Label("已隐藏", systemImage: "eye.slash")
                .font(AppTheme.Typography.micro)
                .foregroundStyle(AppTheme.Palette.warning)
        } else if !appliedDisplays.isEmpty {
            HStack(spacing: 4) {
                ThemeStatusDot(color: AppTheme.Palette.applied, size: 4)
                Text(appliedDisplays.joined(separator: "、"))
                    .font(AppTheme.Typography.micro)
                    .foregroundStyle(AppTheme.Palette.applied)
                    .lineLimit(1)
            }
        } else {
            Text(sourceLabel)
                .font(AppTheme.Typography.micro)
                .foregroundStyle(AppTheme.Palette.textTertiary)
        }
    }

    private var detailText: String? {
        if let width = item.metadata?.pixelWidth,
           let height = item.metadata?.pixelHeight,
           width > 0, height > 0 {
            return "\(width)×\(height)"
        }
        if let fileExtension = item.metadata?.fileExtension, !fileExtension.isEmpty {
            return fileExtension.uppercased()
        }
        return nil
    }

    private var sourceLabel: String {
        if !item.sourceURL.isFileURL { return "远程网址" }
        if item.entryURL != nil { return "HTML 项目" }
        return item.storageMode == .managedCopy ? "应用库副本" : "外部引用"
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
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                WallpaperPreviewFrame {
                    ThumbnailView(item: item)
                }
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Metrics.cardCorner, style: .continuous))
                .themeCardBorder(isSelected: isSelected, isHovering: isHovering)
                .overlay(alignment: .topLeading) {
                    if selectionMode {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(
                                isSelected
                                    ? AppTheme.Palette.accent
                                    : AppTheme.Palette.text.opacity(0.85)
                            )
                            .background(
                                Circle()
                                    .fill(AppTheme.Palette.canvas.opacity(0.7))
                                    .frame(width: 20, height: 20)
                            )
                            .padding(8)
                    }
                }
                Button(action: favoriteAction) {
                    Image(systemName: item.isFavorite ? "star.fill" : "star")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(
                            item.isFavorite
                                ? AppTheme.Palette.accent
                                : AppTheme.Palette.textSecondary
                        )
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(AppTheme.Palette.canvas.opacity(0.72)))
                        .overlay(Circle().stroke(AppTheme.Palette.hairline, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .padding(8)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(AppTheme.Typography.bodyMedium)
                    .foregroundStyle(AppTheme.Palette.text)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: iconName)
                        .font(.system(size: 9, weight: .medium))
                    Text(typeName)
                        .font(AppTheme.Typography.micro)
                    Spacer(minLength: 4)
                    if let detailText {
                        Text(detailText)
                            .font(AppTheme.Typography.mono(9))
                            .foregroundStyle(AppTheme.Palette.textTertiary)
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(AppTheme.Palette.textSecondary)
                statusLine
            }
            // Reserve a stable text block so every card has the same height
            // and the dynamic page capacity matches what is actually visible.
            .frame(
                height: CGFloat(WallpaperLibraryPageLayout.cardTextHeight),
                alignment: .topLeading
            )
            .padding(.top, CGFloat(WallpaperLibraryPageLayout.cardTextSpacing))
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: selectAction)
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var statusLine: some View {
        if item.availability != .available {
            Label(availabilityLabel(item.availability), systemImage: "exclamationmark.triangle.fill")
                .font(AppTheme.Typography.micro)
                .foregroundStyle(AppTheme.Palette.danger)
                .lineLimit(1)
        } else if item.isHidden {
            Label("已隐藏", systemImage: "eye.slash")
                .font(AppTheme.Typography.micro)
                .foregroundStyle(AppTheme.Palette.warning)
        } else if !appliedDisplays.isEmpty {
            HStack(spacing: 4) {
                ThemeStatusDot(color: AppTheme.Palette.applied, size: 4)
                Text(appliedDisplays.joined(separator: "、"))
                    .font(AppTheme.Typography.micro)
                    .foregroundStyle(AppTheme.Palette.applied)
                    .lineLimit(1)
            }
        } else {
            EmptyView()
        }
    }

    private var detailText: String? {
        if let width = item.metadata?.pixelWidth,
           let height = item.metadata?.pixelHeight,
           width > 0, height > 0 {
            return "\(width)×\(height)"
        }
        if let fileExtension = item.metadata?.fileExtension, !fileExtension.isEmpty {
            return fileExtension.uppercased()
        }
        switch item.type {
        case .web: return item.sourceURL.isFileURL ? "HTML" : "URL"
        default: return nil
        }
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

struct WallpaperPreviewFrame<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        // Use a geometry-bearing color as the sizing source. Applying
        // aspectRatio directly to ThumbnailView lets a portrait thumbnail
        // contribute its intrinsic height and can make the preview vertical.
        Color.black
            .frame(maxWidth: .infinity)
            .aspectRatio(CGFloat(WallpaperPreviewLayout.aspectRatio), contentMode: .fit)
            .overlay {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .clipped()
    }
}

struct ThumbnailView: View {
    let item: WallpaperItem

    var body: some View {
        ZStack {
            if let image = previewImage {
                if isPortrait(image) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                }
            } else {
                LinearGradient(
                    colors: [AppTheme.Palette.raised, AppTheme.Palette.panel],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: iconName)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(AppTheme.Palette.textTertiary)
                if item.type != .image {
                    Text(item.type == .video ? "视频" : (item.sourceURL.isFileURL ? "HTML" : "URL"))
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.Palette.textTertiary)
                        .padding(.top, 58)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .clipped()
    }

    private func isPortrait(_ image: NSImage) -> Bool {
        image.size.height > image.size.width
    }

    private var previewImage: NSImage? {
        guard item.availability == .available else { return nil }
        if let thumbnailURL = item.thumbnailURL {
            return ThumbnailCache.shared.image(at: thumbnailURL)
        }
        guard item.type == .image else { return nil }
        return ThumbnailCache.shared.image(at: item.sourceURL)
    }

    private var iconName: String {
        switch item.type { case .image: return "photo"; case .video: return "film"; case .web: return "safari" }
    }
}

private struct WebWallpaperURLImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    let onImport: (URL) -> Void

    private var candidateURL: URL? {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              WebWallpaperURL.isValid(url) else { return nil }
        return url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("添加网页壁纸")
                .font(.title2.weight(.semibold))
            TextField("https://example.com", text: $address)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("网页地址")
            Text("支持 HTTP 和 HTTPS。网址以明文保存在壁纸库中，网页会运行网站脚本；请勿使用含敏感令牌的网址，只添加可信网站。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("添加") {
                    guard let candidateURL else { return }
                    onImport(candidateURL)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(candidateURL == nil)
            }
        }
        .padding(24)
        .frame(width: 460)
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
            guard candidate.type == .web, candidate.url.isExistingDirectory else { return nil }
            return candidate.url
        }
        guard webProjects.count == 1 else { return nil }
        return webProjects.first
    }

    private func importType(for url: URL) -> WallpaperType? {
        model.pendingImportCandidates.first(where: { $0.url == url })?.type
    }

    private func importCandidate(for url: URL) -> WallpaperImportCandidate? {
        model.pendingImportCandidates.first(where: { $0.url == url })
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
                                if let candidate = importCandidate(for: url) {
                                    Text("范围：\(candidate.scopeURL.path)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                    if let count = candidate.fileCount, let bytes = candidate.estimatedBytes {
                                        Text("\(count) 个文件 · \(ByteCountFormatter().string(fromByteCount: bytes))")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            Spacer()
                            if model.isImportInspectionInProgress {
                                ProgressView()
                                    .controlSize(.small)
                            } else if type == nil {
                                Text("不支持")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.Palette.danger)
                            } else {
                                Text("待导入")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.Palette.applied)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Text("单个 HTML 只处理所选文件；需要相对 CSS、JS 或其他资源时，请显式导入整个项目目录。")
                .font(.caption)
                .foregroundStyle(.secondary)

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
        .groupBoxStyle(ThemeGroupBoxStyle())
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
    let importURLAction: () -> Void
    var clearFiltersAction: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        AppTheme.Palette.hairline,
                        style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                    )
                    .frame(width: 250, height: 140)
                Image(systemName: hasItems ? "magnifyingglass" : "plus")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(
                        hasItems
                            ? AppTheme.Palette.textTertiary
                            : AppTheme.Palette.accent
                    )
            }
            VStack(spacing: 6) {
                Text(hasItems ? "没有匹配的壁纸" : "壁纸库还是空的")
                    .font(AppTheme.Typography.display(21))
                    .foregroundStyle(AppTheme.Palette.text)
                Text(hasItems
                     ? "尝试修改搜索条件或筛选器"
                     : "拖入图片、视频或本地 HTML 项目，开始创建你的壁纸库")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            if !hasItems {
                Menu {
                    Button("导入文件或文件夹", action: importAction)
                    Button("导入网址", action: importURLAction)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                        Text("添加第一张壁纸")
                            .font(.system(size: 12, weight: .semibold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .semibold))
                            .opacity(0.7)
                    }
                    .foregroundStyle(AppTheme.Palette.canvas)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: AppTheme.Metrics.controlCorner, style: .continuous)
                            .fill(AppTheme.Palette.accent)
                    )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            } else if let clearFiltersAction {
                Button("清除筛选", action: clearFiltersAction)
                    .buttonStyle(QuietButtonStyle())
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
            HStack(alignment: .center, spacing: 8) {
                Text("壁纸详情")
                    .font(AppTheme.Typography.display(18))
                    .foregroundStyle(AppTheme.Palette.text)
                Spacer(minLength: 8)
                if let item = model.selectedWallpaper {
                    Button {
                        model.toggleFavorite(item)
                    } label: {
                        Image(systemName: item.isFavorite ? "star.fill" : "star")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(
                                item.isFavorite
                                    ? AppTheme.Palette.accent
                                    : AppTheme.Palette.textSecondary
                            )
                            .frame(width: 24, height: 24)
                            .background(
                                Circle()
                                    .fill(item.isFavorite ? AppTheme.Palette.accentWash : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(item.isFavorite ? "取消收藏" : "收藏壁纸")
                }
            }
            .padding(.horizontal, 16)
            .frame(height: MainWindowMetrics.libraryHeaderHeight)
            ThemeHairline()

            if let item = model.selectedWallpaper {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        preview(for: item)
                        titleBlock(for: item)
                        displaySection(for: item)
                        if item.type != .image {
                            playbackSection(for: item)
                        }
                        fitSection(for: item)
                        resourceSection(for: item)
                        actionSection(for: item)
                    }
                    .padding(16)
                }
            } else {
                emptyState
            }
        }
        .background(AppTheme.Palette.panel)
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

    private func preview(for item: WallpaperItem) -> some View {
        WallpaperPreviewFrame {
            ThumbnailView(item: item)
        }
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Metrics.cardCorner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Metrics.cardCorner, style: .continuous)
                .stroke(AppTheme.Palette.hairline, lineWidth: 1)
        )
    }

    private func titleBlock(for item: WallpaperItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(item.name)
                .font(AppTheme.Typography.inspectorTitle)
                .foregroundStyle(AppTheme.Palette.text)
                .lineLimit(2)
            HStack(spacing: 6) {
                Image(systemName: iconName(for: item))
                    .font(.system(size: 9, weight: .medium))
                Text(typeName(for: item))
                    .font(AppTheme.Typography.caption)
                Spacer(minLength: 8)
                if let badge = resolutionBadge(for: item) {
                    Text(badge)
                        .font(AppTheme.Typography.mono(9.5))
                        .foregroundStyle(AppTheme.Palette.textTertiary)
                }
            }
            .foregroundStyle(AppTheme.Palette.textSecondary)
        }
    }

    private func displaySection(for item: WallpaperItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ThemeSectionHeader(title: "显示器")
            VStack(spacing: 0) {
                ForEach(model.displayRows) { row in
                    displayRow(row, item: item)
                    if row.id != model.displayRows.last?.id {
                        ThemeHairline()
                            .padding(.leading, 10)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(AppTheme.Palette.raised.opacity(0.45))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(AppTheme.Palette.hairline, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private func displayRow(_ row: DisplayRow, item: WallpaperItem) -> some View {
        let applied = model.wallpaperManager.appliedWallpaperIDs[row.id] == item.id
        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: row.isConnected ? "display" : "display.trianglebadge.exclamationmark")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(row.isConnected ? AppTheme.Palette.textSecondary : AppTheme.Palette.warning)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.name)
                        .font(AppTheme.Typography.bodyMedium)
                        .foregroundStyle(AppTheme.Palette.text)
                        .lineLimit(1)
                    if row.isConnected && applied {
                        ThemeStatusDot(color: AppTheme.Palette.applied, size: 4)
                        Text("当前壁纸")
                            .font(AppTheme.Typography.micro)
                            .foregroundStyle(AppTheme.Palette.applied)
                    }
                }
                Text(row.isConnected ? (applied ? "已应用" : "未应用") : "已断开，保留原分配")
                    .font(AppTheme.Typography.micro)
                    .foregroundStyle(row.isConnected ? AppTheme.Palette.textTertiary : AppTheme.Palette.warning)
                if let queue = model.wallpaperManager.queue(for: row.id), !queue.wallpaperIDs.isEmpty {
                    HStack(spacing: 8) {
                        Text(queue.isEnabled ? "队列播放中" : "队列已配置")
                            .font(AppTheme.Typography.micro)
                            .foregroundStyle(queue.isEnabled ? AppTheme.Palette.applied : AppTheme.Palette.textTertiary)
                        Text("\(queue.wallpaperIDs.count) 项")
                            .font(AppTheme.Typography.mono(8.5))
                            .foregroundStyle(AppTheme.Palette.textTertiary)
                        Text("\(Int(queue.normalizedIntervalSeconds)) 秒")
                            .font(AppTheme.Typography.mono(8.5))
                            .foregroundStyle(AppTheme.Palette.textTertiary)
                        Text(queue.transition.title)
                            .font(AppTheme.Typography.micro)
                            .foregroundStyle(AppTheme.Palette.textTertiary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 4)
            if row.isConnected,
               let display = model.displayService.displays.first(where: { $0.id == row.id }) {
                VStack(alignment: .trailing, spacing: 5) {
                    Button(applied ? "已应用" : "应用") {
                        model.apply(item: item, to: display)
                    }
                    .buttonStyle(AccentActionButtonStyle(compact: true))
                    .disabled(item.availability != .available || applied)
                    Button("队列") {
                        model.openQueue(for: display.id)
                    }
                    .buttonStyle(QuietButtonStyle(compact: true))
                }
            } else {
                Text("已断开")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Palette.warning)
            }
        }
        .padding(10)
    }

    private func playbackSection(for item: WallpaperItem) -> some View {
        let hasDisplay = !model.playbackDisplayIDs(for: item).isEmpty
        return VStack(alignment: .leading, spacing: 8) {
            ThemeSectionHeader(title: "播放")
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        model.togglePlayback(for: item)
                    } label: {
                        Label(model.isPlaying(item) ? "暂停" : "播放", systemImage: model.isPlaying(item) ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(AccentActionButtonStyle(compact: true))
                    .disabled(!hasDisplay)

                    Button {
                        model.setMuted(!model.isMuted(item), for: item)
                    } label: {
                        Label(model.isMuted(item) ? "取消静音" : "静音", systemImage: model.isMuted(item) ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    .buttonStyle(QuietButtonStyle(compact: true))
                    .disabled(!hasDisplay)

                    Button {
                        model.reloadPlayback(for: item)
                    } label: {
                        Label("重新加载", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(QuietButtonStyle(compact: true))
                    .disabled(!hasDisplay)
                    Spacer(minLength: 0)
                }
                Text(hasDisplay ? (model.isMuted(item) ? "当前静音" : "当前有声") : "尚未应用到显示器")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Palette.textTertiary)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(AppTheme.Palette.raised.opacity(0.45))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(AppTheme.Palette.hairline, lineWidth: 1)
            )
        }
    }

    private func fitSection(for item: WallpaperItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ThemeSectionHeader(title: "适配方式")
            HStack(spacing: 8) {
                Picker("适配方式", selection: Binding<WallpaperFitMode?>(
                    get: { item.fitModeOverride },
                    set: { model.setFitModeOverride($0, for: item) }
                )) {
                    Text("跟随全局（\(model.playbackPolicy.fitMode.title)）").tag(nil as WallpaperFitMode?)
                    ForEach(WallpaperFitMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(Optional(mode))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(AppTheme.Palette.accent)
                .fixedSize()
                Spacer(minLength: 0)
                Text(item.fitModeOverride == nil ? "跟随全局" : "仅此壁纸")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Palette.textTertiary)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(AppTheme.Palette.raised.opacity(0.45))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(AppTheme.Palette.hairline, lineWidth: 1)
            )
        }
    }

    private func resourceSection(for item: WallpaperItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ThemeSectionHeader(title: "资源")
            VStack(spacing: 0) {
                ledgerRow("存储模式", value: storageModeText(for: item))
                ThemeHairline()
                ledgerRow("状态", value: availabilityText(for: item))
                ThemeHairline()
                ledgerRow("格式", value: formatText(for: item))
                ThemeHairline()
                ledgerRow("大小", value: sizeText(for: item))
                if item.type == .image || item.type == .video {
                    ThemeHairline()
                    ledgerRow("分辨率", value: resolutionText(item.metadata))
                }
                if item.type == .video {
                    ThemeHairline()
                    ledgerRow("时长", value: durationText(item.metadata?.durationSeconds))
                }
                ThemeHairline()
                ledgerRow("可见性", value: item.isHidden ? "已隐藏" : "正常")
                ThemeHairline()
                ledgerRow(item.sourceURL.isFileURL ? "路径" : "网址", value: item.sourceURL.isFileURL ? item.sourceURL.path : item.sourceURL.absoluteString, stacked: true)
                if let entryURL = item.entryURL {
                    ThemeHairline()
                    ledgerRow(entryURL.isFileURL ? "入口文件" : "网页地址", value: entryURL.isFileURL ? entryURL.path : entryURL.absoluteString, stacked: true)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(AppTheme.Palette.raised.opacity(0.45))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(AppTheme.Palette.hairline, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            if item.availability != .available {
                VStack(alignment: .leading, spacing: 6) {
                    Label(availabilityLabel(item.availability), systemImage: "exclamationmark.triangle.fill")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.Palette.danger)
                    Text(availabilityExplanation(item.availability))
                        .font(AppTheme.Typography.micro)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(AppTheme.Palette.danger.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(AppTheme.Palette.danger.opacity(0.35), lineWidth: 1)
                )
            }
        }
    }

    @ViewBuilder
    private func ledgerRow(_ label: String, value: String, stacked: Bool = false) -> some View {
        if stacked {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(AppTheme.Typography.micro)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                Text(value)
                    .font(AppTheme.Typography.mono(9))
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label)
                    .font(AppTheme.Typography.micro)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                Spacer(minLength: 8)
                Text(value)
                    .font(AppTheme.Typography.mono(9.5))
                    .foregroundStyle(AppTheme.Palette.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
    }

    private func actionSection(for item: WallpaperItem) -> some View {
        HStack(spacing: 8) {
            Button(item.isHidden ? "取消隐藏" : "隐藏壁纸") {
                model.setHidden(!item.isHidden, for: [item.id])
            }
            .buttonStyle(QuietButtonStyle(compact: true))

            if item.availability != .available {
                Button("重新定位") {
                    model.relocate(item: item)
                }
                .buttonStyle(AccentActionButtonStyle(compact: true))
                Button("重新扫描") {
                    model.refreshAvailability(for: item)
                }
                .buttonStyle(QuietButtonStyle(compact: true))
            }

            Spacer(minLength: 4)
            Button("移除记录") {
                showingRemoveConfirmation = true
            }
            .buttonStyle(QuietButtonStyle(compact: true, tone: AppTheme.Palette.danger))
        }
        .padding(.top, 2)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: AppTheme.Metrics.cardCorner, style: .continuous)
                    .stroke(AppTheme.Palette.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .frame(width: 132, height: 74)
                Image(systemName: "cursorarrow.click")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(AppTheme.Palette.textTertiary)
            }
            Text("选择一个壁纸")
                .font(AppTheme.Typography.display(17))
                .foregroundStyle(AppTheme.Palette.text)
            Text("预览、分配显示器并查看资源信息")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
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

    private func availabilityText(for item: WallpaperItem) -> String {
        if !item.sourceURL.isFileURL && item.availability == .available {
            return "网址已保存，联网时加载"
        }
        return availabilityLabel(item.availability)
    }

    private func typeName(for item: WallpaperItem) -> String {
        switch item.type {
        case .image: return "图片壁纸"
        case .video: return "视频壁纸"
        case .web: return "网页壁纸"
        }
    }

    private func iconName(for item: WallpaperItem) -> String {
        switch item.type {
        case .image: return "photo"
        case .video: return "film"
        case .web: return "safari"
        }
    }

    private func resolutionBadge(for item: WallpaperItem) -> String? {
        if let width = item.metadata?.pixelWidth,
           let height = item.metadata?.pixelHeight,
           width > 0, height > 0 {
            return "\(width)×\(height)"
        }
        if item.type == .web {
            return item.sourceURL.isFileURL ? "HTML" : "URL"
        }
        return nil
    }

    private func storageModeText(for item: WallpaperItem) -> String {
        if !item.sourceURL.isFileURL {
            return "远程网址"
        }
        if item.entryURL != nil {
            return "HTML 项目"
        }
        return item.storageMode == .managedCopy ? "应用库副本" : "外部文件引用"
    }

    private func formatText(for item: WallpaperItem) -> String {
        if !item.sourceURL.isFileURL {
            return "远程网页"
        }
        if let entryURL = item.entryURL {
            return entryURL.pathExtension.isEmpty ? "HTML" : entryURL.pathExtension.uppercased()
        }
        return metadataValue(item.metadata?.fileExtension?.uppercased(), fallback: "正在读取…")
    }

    private func sizeText(for item: WallpaperItem) -> String {
        guard item.sourceURL.isFileURL else { return "不适用" }
        return fileSizeText(item.metadata?.fileSizeBytes)
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
}
