import AVFoundation
import AppKit
import CoreMedia
import WebKit
import WallpaperMacCore

@MainActor
final class WallpaperManager: ObservableObject {
    @Published private(set) var appliedWallpaperIDs: [String: UUID] = [:]
    @Published private(set) var playbackStates: [String: PlaybackState] = [:]
    @Published private(set) var displayAssignments: [DisplayAssignment] = []
    @Published private(set) var displayQueues: [String: DisplayPlaybackQueue] = [:]
    @Published private(set) var playbackQueues: [PlaybackQueue] = []
    @Published private(set) var displayQueueBindings: [String: DisplayPlaybackBinding] = [:]

    enum PlaybackState: Equatable {
        case staticImage
        case playing(isMuted: Bool)
        case paused(isMuted: Bool)

        var isPlaying: Bool {
            if case .playing = self { return true }
            return false
        }

        var isMuted: Bool {
            switch self {
            case .staticImage: return true
            case .playing(let muted), .paused(let muted): return muted
            }
        }
    }

    private var controllers: [String: WallpaperWindowController] = [:]
    private var assignments: [String: DisplayAssignment] = [:]
    private var queueTimers: [String: Timer] = [:]
    private var connectedDisplays: [String: DisplayService.Display] = [:]
    private var queueItems: [UUID: WallpaperItem] = [:]
    private var queueLibrary: [UUID: PlaybackQueue] = [:]
    private var bindings: [String: DisplayPlaybackBinding] = [:]
    private weak var store: WallpaperStore?
    private var playbackPolicy = PlaybackPolicy()
    private var isSystemSuspended = false
    private var activityMonitor: SystemActivityMonitor?
    private var screenChangeObserver: NSObjectProtocol?

    init() {
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleScreenChange()
            }
        }
        activityMonitor = SystemActivityMonitor { [weak self] suspended in
            Task { @MainActor [weak self] in
                self?.setSystemSuspended(suspended)
            }
        }
    }

    deinit {
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
        }
        queueTimers.values.forEach { $0.invalidate() }
        // WallpaperManager is main-actor isolated, but Swift does not allow
        // calling the main-actor controller teardown from deinit. All runtime
        // shutdown paths explicitly tear down controllers before removing
        // them; the app-owned manager normally lives for the process lifetime.
    }

    func configure(store: WallpaperStore, policy: PlaybackPolicy = PlaybackPolicy()) {
        queueTimers.values.forEach { $0.invalidate() }
        queueTimers.removeAll()
        controllers.values.forEach { $0.teardownAndClose() }
        controllers.removeAll()
        self.store = store
        self.playbackPolicy = policy
        activityMonitor?.update(policy: policy)
        loadAssignments()
        loadQueues()
    }

    func update(policy: PlaybackPolicy) {
        playbackPolicy = policy
        activityMonitor?.update(policy: policy)
        for (displayID, controller) in controllers {
            controller.setMuted(policy.isMuted)
            controller.setFitMode(policy.fitMode)
            controller.setWebInteractionEnabled(policy.webWallpaperInteractionEnabled)
            controller.setSystemSuspended(isSystemSuspended, reloadWebContentOnResume: false)
            playbackStates[displayID] = controller.playbackState
        }
    }

    private func setSystemSuspended(_ suspended: Bool) {
        guard suspended != isSystemSuspended else { return }
        isSystemSuspended = suspended
        for (displayID, controller) in controllers {
            controller.setSystemSuspended(
                suspended,
                reloadWebContentOnResume: !suspended && playbackPolicy.reloadWebContentOnResume
            )
            playbackStates[displayID] = controller.playbackState
        }
    }

    func apply(
        item: WallpaperItem,
        to display: DisplayService.Display,
        policy: PlaybackPolicy = PlaybackPolicy(),
        transition: WallpaperTransitionEffect = .cut,
        preserveQueue: Bool = false,
        advanceAfterVideoCompletion: Bool = false
    ) throws {
        playbackPolicy = policy
        connectedDisplays[display.id] = display
        if !preserveQueue {
            stopQueue(displayID: display.id, persist: true)
        }
        let replacement = try WallpaperWindowController(
            item: item,
            screen: display.screen,
            policy: policy,
            advanceAfterVideoCompletion: advanceAfterVideoCompletion,
            onVideoPlaybackCompleted: { [weak self] in
                self?.videoPlaybackDidFinish(for: display.id)
            }
        )
        replacement.setSystemSuspended(isSystemSuspended, reloadWebContentOnResume: false)
        let previous = controllers[display.id]
        controllers[display.id] = replacement
        let assignment = DisplayAssignment(
            id: display.id,
            displayName: display.name,
            isConnected: true,
            wallpaperID: item.id,
            applicationState: .applied
        )
        assignments[display.id] = assignment
        publishDisplayAssignments()
        appliedWallpaperIDs[display.id] = item.id
        playbackStates[display.id] = replacement.playbackState
        persistAssignments()
        present(replacement, replacing: previous, effect: transition, on: display.screen)
    }

    func clear(displayID: String) {
        stopQueue(displayID: displayID, persist: true)
        controllers.removeValue(forKey: displayID)?.teardownAndClose()
        assignments[displayID] = DisplayAssignment(
            id: displayID,
            displayName: assignments[displayID]?.displayName ?? displayID,
            isConnected: connectedDisplays[displayID] != nil,
            wallpaperID: nil,
            applicationState: .idle
        )
        publishDisplayAssignments()
        appliedWallpaperIDs.removeValue(forKey: displayID)
        playbackStates.removeValue(forKey: displayID)
        persistAssignments()
    }

    func clear(itemID: UUID) {
        let displayIDs = assignments.values.filter { $0.wallpaperID == itemID }.map(\.id)
        displayIDs.forEach { clear(displayID: $0) }
        removeWallpaperIDsFromQueues([itemID])
    }

    func removeWallpaperIDs(_ itemIDs: Set<UUID>) {
        guard !itemIDs.isEmpty else { return }
        let displayIDs = assignments.values.filter { assignment in
            guard let wallpaperID = assignment.wallpaperID else { return false }
            return itemIDs.contains(wallpaperID)
        }.map(\.id)
        displayIDs.forEach { clear(displayID: $0) }
        removeWallpaperIDsFromQueues(itemIDs)
    }

    func clearAll() {
        queueTimers.values.forEach { $0.invalidate() }
        queueTimers.removeAll()
        controllers.values.forEach { $0.teardownAndClose() }
        controllers.removeAll()
        bindings = bindings.mapValues { binding in
            var binding = binding
            for queueID in binding.queueStates.keys {
                guard var state = binding.queueStates[queueID] else { continue }
                state.isEnabled = false
                state.isPlaying = false
                binding.queueStates[queueID] = state
            }
            return binding
        }
        publishBindings()
        publishLegacyQueues()
        assignments = assignments.mapValues { assignment in
            DisplayAssignment(
                id: assignment.id,
                displayName: assignment.displayName,
                isConnected: assignment.isConnected,
                wallpaperID: nil,
                applicationState: .idle
            )
        }
        appliedWallpaperIDs.removeAll()
        playbackStates.removeAll()
        publishDisplayAssignments()
        persistAssignments()
        persistQueues()
    }

    func reapply(to displays: [DisplayService.Display], policy: PlaybackPolicy, items: [WallpaperItem]) {
        playbackPolicy = policy
        connectedDisplays = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })
        queueItems = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let connectedIDs = Set(displays.map(\.id))
        for key in assignments.keys where !connectedIDs.contains(key) {
            queueTimers[key]?.invalidate()
            queueTimers.removeValue(forKey: key)
            controllers.removeValue(forKey: key)?.teardownAndClose()
            assignments[key]?.isConnected = false
            assignments[key]?.applicationState = .disconnected
            appliedWallpaperIDs.removeValue(forKey: key)
            playbackStates.removeValue(forKey: key)
        }
        publishDisplayAssignments()

        for display in displays {
            if bindings[display.id] == nil {
                var binding = DisplayPlaybackBinding(
                    displayID: display.id,
                    displayName: display.name,
                    activeQueueID: defaultQueueID
                )
                let defaultQueue = queueLibrary[defaultQueueID] ?? .defaultQueue
                binding.queueStates[defaultQueueID] = DisplayQueueState(
                    queueID: defaultQueueID,
                    isPlaying: !defaultQueue.wallpaperIDs.isEmpty,
                    isEnabled: !defaultQueue.wallpaperIDs.isEmpty
                )
                bindings[display.id] = binding
            }
            guard let binding = bindings[display.id],
                  let queue = queueLibrary[binding.activeQueueID] else { continue }
            let state = binding.state(for: queue.id)
            if state.isEnabled && !queue.wallpaperIDs.isEmpty {
                startQueue(queueID: queue.id, on: display, policy: policy, items: items, resetIndex: false)
                continue
            }
            guard let assignment = assignments[display.id],
                  let wallpaperID = assignment.wallpaperID,
                  let item = queueItems[wallpaperID],
                  item.availability == .available else {
                continue
            }
            if controllers[display.id] == nil || appliedWallpaperIDs[display.id] != item.id {
                try? apply(item: item, to: display, policy: policy, preserveQueue: true)
            }
        }
        publishBindings()
        publishLegacyQueues()
        publishDisplayAssignments()
        persistAssignments()
    }

    func restoreAssignments(to displays: [DisplayService.Display], policy: PlaybackPolicy, items: [WallpaperItem]) {
        reapply(to: displays, policy: policy, items: items)
    }

    func queue(for displayID: String) -> DisplayPlaybackQueue? {
        displayQueues[displayID]
    }

    func queue(with id: UUID) -> PlaybackQueue? {
        queueLibrary[id]
    }

    func activeQueue(for displayID: String) -> PlaybackQueue? {
        guard let binding = bindings[displayID],
              binding.state(for: binding.activeQueueID).isEnabled else { return nil }
        return queueLibrary[binding.activeQueueID]
    }

    func boundQueue(for displayID: String) -> PlaybackQueue? {
        guard let binding = bindings[displayID] else { return nil }
        return queueLibrary[binding.activeQueueID]
    }

    func state(for displayID: String, queueID: UUID) -> DisplayQueueState? {
        bindings[displayID]?.queueStates[queueID]
    }

    @discardableResult
    func createQueue(
        named name: String,
        playbackMode: QueuePlaybackMode = .sequential,
        completionBehavior: QueueCompletionBehavior = .loop,
        advanceAfterVideoCompletion: Bool = false,
        defaultIntervalSeconds: Double = 30,
        transition: WallpaperTransitionEffect = .crossfade
    ) -> PlaybackQueue? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !playbackQueues.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return nil }
        let queue = PlaybackQueue(
            name: trimmed,
            playbackMode: playbackMode,
            completionBehavior: completionBehavior,
            advanceAfterVideoCompletion: advanceAfterVideoCompletion,
            defaultIntervalSeconds: defaultIntervalSeconds,
            transition: transition
        )
        queueLibrary[queue.id] = queue
        publishQueueLibrary()
        persistQueues()
        return queue
    }

    @discardableResult
    func updateQueue(_ queue: PlaybackQueue) -> Bool {
        guard queueLibrary[queue.id] != nil else { return false }
        var normalized = queue
        normalized.normalize()
        if normalized.isDefault {
            normalized = PlaybackQueue(
                id: normalized.id,
                name: PlaybackQueue.defaultName,
                isDefault: true,
                wallpaperIDs: normalized.wallpaperIDs,
                sortMode: normalized.sortMode,
                playbackMode: normalized.playbackMode,
                completionBehavior: normalized.completionBehavior,
                advanceAfterVideoCompletion: normalized.advanceAfterVideoCompletion,
                defaultIntervalSeconds: normalized.defaultIntervalSeconds,
                transition: normalized.transition,
                itemIntervalOverrides: normalized.itemIntervalOverrides,
                createdAt: normalized.createdAt,
                updatedAt: normalized.updatedAt
            )
        }
        queueLibrary[normalized.id] = normalized
        invalidateBoundDisplays(for: normalized.id)
        publishQueueLibrary()
        persistQueues()
        return true
    }

    @discardableResult
    func deleteQueue(id: UUID, policy: PlaybackPolicy? = nil, items: [WallpaperItem]? = nil) -> Bool {
        guard let queue = queueLibrary[id], !queue.isDefault else { return false }
        let fallbackID = defaultQueueID
        queueLibrary.removeValue(forKey: id)
        for displayID in bindings.keys {
            guard var binding = bindings[displayID], binding.activeQueueID == id else { continue }
            binding.activeQueueID = fallbackID
            binding.queueStates.removeValue(forKey: id)
            if binding.queueStates[fallbackID] == nil {
                binding.queueStates[fallbackID] = DisplayQueueState(queueID: fallbackID)
            }
            bindings[displayID] = binding
            if let display = connectedDisplays[displayID], let policy, let items {
                startQueue(queueID: fallbackID, on: display, policy: policy, items: items, resetIndex: false)
            }
        }
        publishQueueLibrary()
        persistQueues()
        return true
    }

    func addWallpaperIDs(_ itemIDs: [UUID], to queueID: UUID, items: [WallpaperItem]) {
        guard var queue = queueLibrary[queueID] else { return }
        let orderedIDs: [UUID]
        switch queue.sortMode {
        case .custom:
            orderedIDs = itemIDs
        case .name:
            orderedIDs = itemIDs.sorted { lhs, rhs in
                (items.first(where: { $0.id == lhs })?.name ?? "").localizedStandardCompare(items.first(where: { $0.id == rhs })?.name ?? "") == .orderedAscending
            }
        case .type:
            orderedIDs = itemIDs.sorted { lhs, rhs in
                let left = items.first(where: { $0.id == lhs })
                let right = items.first(where: { $0.id == rhs })
                if left?.type != right?.type { return String(describing: left?.type) < String(describing: right?.type) }
                return (left?.name ?? "").localizedStandardCompare(right?.name ?? "") == .orderedAscending
            }
        case .addedAt:
            orderedIDs = itemIDs.sorted { lhs, rhs in
                (items.first(where: { $0.id == lhs })?.createdAt ?? .distantPast) < (items.first(where: { $0.id == rhs })?.createdAt ?? .distantPast)
            }
        }
        queue.addWallpaperIDs(orderedIDs)
        queueLibrary[queueID] = queue
        invalidateBoundDisplays(for: queueID)
        publishQueueLibrary()
        persistQueues()
    }

    func removeWallpaperIDs(_ itemIDs: Set<UUID>, from queueID: UUID) {
        guard var queue = queueLibrary[queueID] else { return }
        queue.removeWallpaperIDs(itemIDs)
        queueLibrary[queueID] = queue
        for displayID in bindings.keys {
            guard var binding = bindings[displayID], var state = binding.queueStates[queueID] else { continue }
            state.normalize(for: queue)
            binding.queueStates[queueID] = state
            bindings[displayID] = binding
        }
        invalidateBoundDisplays(for: queueID)
        publishQueueLibrary()
        persistQueues()
    }

    func setActiveQueue(
        _ queueID: UUID,
        for display: DisplayService.Display,
        policy: PlaybackPolicy,
        items: [WallpaperItem]
    ) {
        guard queueLibrary[queueID] != nil else { return }
        var binding = bindings[display.id] ?? DisplayPlaybackBinding(displayID: display.id, displayName: display.name)
        binding.displayName = display.name
        binding.activeQueueID = queueID
        if binding.queueStates[queueID] == nil {
            binding.queueStates[queueID] = DisplayQueueState(queueID: queueID)
        }
        bindings[display.id] = binding
        startQueue(queueID: queueID, on: display, policy: policy, items: items, resetIndex: false)
        publishBindings()
        persistQueues()
    }

    func saveQueue(_ queue: DisplayPlaybackQueue) {
        let queueID = bindings[queue.displayID]?.activeQueueID ?? UUID()
        let isNew = queueLibrary[queueID] == nil
        let namedQueue = PlaybackQueue(
            id: queueID,
            name: isNew ? (queue.displayName.isEmpty ? "显示器队列" : queue.displayName) : (queueLibrary[queueID]?.name ?? queue.displayName),
            wallpaperIDs: queue.wallpaperIDs,
            advanceAfterVideoCompletion: queueLibrary[queueID]?.advanceAfterVideoCompletion ?? false,
            defaultIntervalSeconds: queue.normalizedIntervalSeconds,
            transition: queue.transition,
            createdAt: queueLibrary[queueID]?.createdAt ?? Date(),
            updatedAt: Date()
        )
        queueLibrary[queueID] = namedQueue
        var binding = bindings[queue.displayID] ?? DisplayPlaybackBinding(displayID: queue.displayID, displayName: queue.displayName)
        binding.displayName = queue.displayName
        binding.activeQueueID = queueID
        binding.queueStates[queueID] = DisplayQueueState(
            queueID: queueID,
            currentIndex: queue.currentIndex,
            isPlaying: queue.isEnabled,
            isEnabled: queue.isEnabled
        )
        bindings[queue.displayID] = binding
        publishQueueLibrary()
        persistQueues()
    }

    func startQueue(
        _ queue: DisplayPlaybackQueue,
        on display: DisplayService.Display,
        policy: PlaybackPolicy,
        items: [WallpaperItem],
        resetIndex: Bool
    ) {
        saveQueue(queue)
        guard let queueID = bindings[display.id]?.activeQueueID else { return }
        startQueue(queueID: queueID, on: display, policy: policy, items: items, resetIndex: resetIndex)
    }

    func startQueue(
        queueID: UUID,
        on display: DisplayService.Display,
        policy: PlaybackPolicy,
        items: [WallpaperItem],
        resetIndex: Bool
    ) {
        guard let queue = queueLibrary[queueID] else { return }
        connectedDisplays[display.id] = display
        queueItems = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        var binding = bindings[display.id] ?? DisplayPlaybackBinding(displayID: display.id, displayName: display.name)
        binding.displayName = display.name
        binding.activeQueueID = queueID
        var state = binding.state(for: queueID)
        if resetIndex { state.currentIndex = 0 }
        let availableIDs = queue.wallpaperIDs.filter { queueItems[$0]?.availability == .available }
        guard !availableIDs.isEmpty else {
            state.isEnabled = false
            state.isPlaying = false
            state.currentIndex = 0
            binding.queueStates[queueID] = state
            bindings[display.id] = binding
            publishBindings()
            publishLegacyQueues()
            persistQueues()
            return
        }
        let index = nextAvailableIndex(in: queue, state: state, preferCurrent: true)
        guard let index, let item = queueItems[queue.wallpaperIDs[index]] else { return }
        state.currentIndex = index
        state.isEnabled = true
        state.isPlaying = true
        binding.queueStates[queueID] = state
        bindings[display.id] = binding
        publishBindings()
        publishLegacyQueues()
        persistQueues()
        queueTimers[display.id]?.invalidate()
        do {
            try apply(
                item: item,
                to: display,
                policy: policy,
                transition: effectiveTransition(queue: queue, state: state),
                preserveQueue: true,
                advanceAfterVideoCompletion: shouldAdvanceAfterVideoCompletion(queue: queue, item: item)
            )
        } catch {
            return
        }
        scheduleQueueTimerIfNeeded(for: display.id, queue: queue, state: state, item: item)
    }

    func stopQueue(displayID: String, persist: Bool = true) {
        queueTimers.removeValue(forKey: displayID)?.invalidate()
        guard var binding = bindings[displayID] else { return }
        let queueID = binding.activeQueueID
        var state = binding.state(for: queueID)
        state.isEnabled = false
        state.isPlaying = false
        binding.queueStates[queueID] = state
        bindings[displayID] = binding
        publishBindings()
        publishLegacyQueues()
        if persist { persistQueues() }
    }

    var isAnyDynamicWallpaperPlaying: Bool {
        playbackStates.values.contains { $0.isPlaying }
    }

    var areAllDynamicWallpapersMuted: Bool {
        let dynamicStates = playbackStates.values.filter {
            if case .staticImage = $0 { return false }
            return true
        }
        return !dynamicStates.isEmpty && dynamicStates.allSatisfy(\.isMuted)
    }

    func setPlaybackEnabledForAll(_ isPlaying: Bool) {
        for (displayID, controller) in controllers {
            controller.setPlaybackEnabled(isPlaying)
            playbackStates[displayID] = controller.playbackState
            guard var binding = bindings[displayID] else { continue }
            let queueID = binding.activeQueueID
            var state = binding.state(for: queueID)
            state.isPlaying = isPlaying
            state.isEnabled = isPlaying
            binding.queueStates[queueID] = state
            bindings[displayID] = binding
        }
        publishBindings()
        publishLegacyQueues()
        persistQueues()
    }

    func setMutedForAll(_ isMuted: Bool) {
        for (displayID, controller) in controllers {
            controller.setMuted(isMuted)
            playbackStates[displayID] = controller.playbackState
        }
    }

    func togglePlayback(for displayID: String) {
        guard let controller = controllers[displayID] else { return }
        controller.togglePlayback()
        playbackStates[displayID] = controller.playbackState
        guard var binding = bindings[displayID] else { return }
        let queueID = binding.activeQueueID
        var state = binding.state(for: queueID)
        state.isPlaying = controller.playbackState.isPlaying
        state.isEnabled = controller.playbackState.isPlaying
        binding.queueStates[queueID] = state
        bindings[displayID] = binding
        publishBindings()
        publishLegacyQueues()
        persistQueues()
    }

    func setMuted(_ muted: Bool, for displayID: String) {
        guard let controller = controllers[displayID] else { return }
        controller.setMuted(muted)
        playbackStates[displayID] = controller.playbackState
    }

    func reload(displayID: String, policy: PlaybackPolicy) {
        guard controllers[displayID] != nil, let itemID = assignments[displayID]?.wallpaperID else { return }
        guard let display = NSScreen.screens.first(where: { self.displayID(for: $0) == displayID }) else { return }
        guard let store, let allItems = try? store.items(), let wallpaper = allItems.first(where: { $0.id == itemID }) else { return }
        playbackPolicy = policy
        let activeQueue = bindings[displayID].flatMap { queueLibrary[$0.activeQueueID] }
        let advanceAfterVideoCompletion = activeQueue?.advanceAfterVideoCompletion == true && wallpaper.type == .video
        do {
            let replacement = try WallpaperWindowController(
                item: wallpaper,
                screen: display,
                policy: policy,
                advanceAfterVideoCompletion: advanceAfterVideoCompletion,
                onVideoPlaybackCompleted: { [weak self] in
                    self?.videoPlaybackDidFinish(for: displayID)
                }
            )
            replacement.setSystemSuspended(isSystemSuspended, reloadWebContentOnResume: false)
            controllers[displayID]?.teardownAndClose()
            controllers[displayID] = replacement
            playbackStates[displayID] = replacement.playbackState
            replacement.showWindow(nil)
            replacement.window?.orderFrontRegardless()
        } catch {
            return
        }
    }

    private func loadAssignments() {
        guard let store, let saved = try? store.displayAssignments() else {
            assignments = [:]
            publishDisplayAssignments()
            appliedWallpaperIDs.removeAll()
            playbackStates.removeAll()
            return
        }
        assignments = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0) })
        publishDisplayAssignments()
        appliedWallpaperIDs.removeAll()
        playbackStates.removeAll()
    }

    private var defaultQueueID: UUID {
        playbackQueues.first(where: { $0.isDefault })?.id ?? PlaybackQueue.defaultQueue.id
    }

    private func loadQueues() {
        guard let store else {
            playbackQueues = [.defaultQueue]
            queueLibrary = [PlaybackQueue.defaultQueue.id: .defaultQueue]
            bindings = [:]
            displayQueueBindings = [:]
            displayQueues = [:]
            return
        }
        let loadedQueues = (try? store.playbackQueues()) ?? [.defaultQueue]
        playbackQueues = loadedQueues
        queueLibrary = Dictionary(uniqueKeysWithValues: loadedQueues.map { ($0.id, $0) })
        let loadedBindings = (try? store.displayPlaybackBindings()) ?? []
        bindings = Dictionary(uniqueKeysWithValues: loadedBindings.map { ($0.displayID, $0) })
        for displayID in bindings.keys {
            guard var binding = bindings[displayID], queueLibrary[binding.activeQueueID] == nil else { continue }
            binding.activeQueueID = defaultQueueID
            if binding.queueStates[defaultQueueID] == nil {
                binding.queueStates[defaultQueueID] = DisplayQueueState(queueID: defaultQueueID)
            }
            bindings[displayID] = binding
        }
        publishBindings()
        publishQueueLibrary()
        publishLegacyQueues()
    }

    private func publishQueueLibrary() {
        playbackQueues = queueLibrary.values.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.createdAt < rhs.createdAt
        }
    }

    private func publishBindings() {
        displayQueueBindings = bindings
    }

    private func publishDisplayAssignments() {
        displayAssignments = assignments.values.sorted { lhs, rhs in
            lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    private func persistAssignments() {
        publishDisplayAssignments()
        guard let store else { return }
        try? store.save(displayAssignments: displayAssignments)
    }

    private func removeWallpaperIDsFromQueues(_ itemIDs: Set<UUID>) {
        guard !itemIDs.isEmpty else { return }
        var restart: [(String, UUID)] = []
        for (queueID, value) in queueLibrary {
            var queue = value
            let wasChanged = queue.wallpaperIDs.contains(where: itemIDs.contains)
            guard wasChanged else { continue }
            queue.removeWallpaperIDs(itemIDs)
            queueLibrary[queueID] = queue
            for displayID in bindings.keys {
                guard var binding = bindings[displayID], binding.activeQueueID == queueID else { continue }
                var state = binding.state(for: queueID)
                let wasEnabled = state.isEnabled
                state.normalize(for: queue)
                binding.queueStates[queueID] = state
                bindings[displayID] = binding
                if wasEnabled {
                    restart.append((displayID, queueID))
                }
            }
        }
        publishQueueLibrary()
        publishBindings()
        publishLegacyQueues()
        persistQueues()
        for (displayID, queueID) in restart {
            guard let display = connectedDisplays[displayID], let items = queueItems.isEmpty ? nil : Array(queueItems.values) else { continue }
            if queueLibrary[queueID]?.wallpaperIDs.isEmpty == true {
                setActiveQueue(defaultQueueID, for: display, policy: playbackPolicy, items: items)
            } else {
                startQueue(queueID: queueID, on: display, policy: playbackPolicy, items: items, resetIndex: false)
            }
        }
    }

    private func publishLegacyQueues() {
        displayQueues = Dictionary(uniqueKeysWithValues: bindings.values.compactMap { binding in
            guard let queue = queueLibrary[binding.activeQueueID] else { return nil }
            let state = binding.state(for: queue.id)
            return (
                binding.displayID,
                DisplayPlaybackQueue(
                    displayID: binding.displayID,
                    displayName: binding.displayName,
                    wallpaperIDs: queue.wallpaperIDs,
                    intervalSeconds: state.overrides.intervalSeconds ?? queue.defaultIntervalSeconds,
                    transition: state.overrides.transition ?? queue.transition,
                    isEnabled: state.isEnabled,
                    currentIndex: state.currentIndex
                )
            )
        })
    }

    private func persistQueues() {
        guard let store else { return }
        try? store.save(playbackQueues: playbackQueues)
        try? store.save(displayPlaybackBindings: Array(bindings.values))
    }

    private func effectiveInterval(queue: PlaybackQueue, state: DisplayQueueState, itemID: UUID) -> Double {
        state.overrides.intervalSeconds ?? queue.interval(for: itemID)
    }

    private func effectivePlaybackMode(queue: PlaybackQueue, state: DisplayQueueState) -> QueuePlaybackMode {
        state.overrides.playbackMode ?? queue.playbackMode
    }

    private func effectiveCompletionBehavior(queue: PlaybackQueue, state: DisplayQueueState) -> QueueCompletionBehavior {
        state.overrides.completionBehavior ?? queue.completionBehavior
    }

    private func effectiveTransition(queue: PlaybackQueue, state: DisplayQueueState) -> WallpaperTransitionEffect {
        state.overrides.transition ?? queue.transition
    }

    private func invalidateBoundDisplays(for queueID: UUID) {
        var changed = false
        for displayID in Array(bindings.keys) {
            guard var binding = bindings[displayID],
                  binding.invalidateActiveQueue(ifMatching: queueID) else { continue }
            queueTimers.removeValue(forKey: displayID)?.invalidate()
            bindings[displayID] = binding
            changed = true
        }
        guard changed else { return }
        publishBindings()
        publishLegacyQueues()
    }

    private func shouldAdvanceAfterVideoCompletion(queue: PlaybackQueue, item: WallpaperItem) -> Bool {
        queue.advanceAfterVideoCompletion && item.type == .video
    }

    private func scheduleQueueTimerIfNeeded(
        for displayID: String,
        queue: PlaybackQueue,
        state: DisplayQueueState,
        item: WallpaperItem
    ) {
        if shouldAdvanceAfterVideoCompletion(queue: queue, item: item) {
            queueTimers.removeValue(forKey: displayID)?.invalidate()
        } else {
            scheduleQueueTimer(for: displayID, interval: effectiveInterval(queue: queue, state: state, itemID: item.id))
        }
    }

    private func videoPlaybackDidFinish(for displayID: String) {
        guard let binding = bindings[displayID],
              let queue = queueLibrary[binding.activeQueueID],
              let state = binding.queueStates[queue.id],
              state.isEnabled,
              queue.advanceAfterVideoCompletion,
              let itemID = queue.wallpaperIDs[safe: state.currentIndex],
              queueItems[itemID]?.type == .video else { return }
        queueTimers.removeValue(forKey: displayID)?.invalidate()
        advanceQueue(for: displayID)
    }

    private func scheduleQueueTimer(for displayID: String, interval: Double) {
        queueTimers[displayID]?.invalidate()
        queueTimers[displayID] = Timer.scheduledTimer(withTimeInterval: max(1, interval), repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.advanceQueue(for: displayID)
            }
        }
    }

    private func advanceQueue(for displayID: String) {
        guard let binding = bindings[displayID],
              let queue = queueLibrary[binding.activeQueueID],
              let display = connectedDisplays[displayID] else {
            stopQueue(displayID: displayID)
            return
        }
        let state = binding.state(for: queue.id)
        guard state.isEnabled, let next = nextQueueIndex(queue: queue, state: state) else {
            stopQueue(displayID: displayID)
            return
        }
        guard let item = queueItems[queue.wallpaperIDs[next]] else {
            stopQueue(displayID: displayID)
            return
        }
        var updatedBinding = binding
        var nextState = state
        nextState.currentIndex = next
        nextState.isPlaying = true
        updatedBinding.queueStates[queue.id] = nextState
        bindings[displayID] = updatedBinding
        publishBindings()
        publishLegacyQueues()
        persistQueues()
        do {
            try apply(
                item: item,
                to: display,
                policy: playbackPolicy,
                transition: effectiveTransition(queue: queue, state: nextState),
                preserveQueue: true,
                advanceAfterVideoCompletion: shouldAdvanceAfterVideoCompletion(queue: queue, item: item)
            )
            scheduleQueueTimerIfNeeded(for: displayID, queue: queue, state: nextState, item: item)
        } catch {
            // The next timer tick will try the next available item.
        }
    }

    private func nextQueueIndex(queue: PlaybackQueue, state: DisplayQueueState) -> Int? {
        let available = queue.wallpaperIDs.indices.filter { queueItems[queue.wallpaperIDs[$0]]?.availability == .available }
        guard !available.isEmpty else { return nil }
        if effectivePlaybackMode(queue: queue, state: state) == .random {
            let candidates = available.filter { available.count == 1 || $0 != state.currentIndex }
            return candidates.randomElement()
        }
        if let currentPosition = available.firstIndex(of: state.currentIndex) {
            let nextPosition = currentPosition + 1
            if nextPosition < available.count { return available[nextPosition] }
            if effectiveCompletionBehavior(queue: queue, state: state) == .loop { return available[0] }
            return nil
        }
        return available.first
    }

    private func nextAvailableIndex(in queue: PlaybackQueue, state: DisplayQueueState, preferCurrent: Bool) -> Int? {
        let available = queue.wallpaperIDs.indices.filter { queueItems[queue.wallpaperIDs[$0]]?.availability == .available }
        guard !available.isEmpty else { return nil }
        if preferCurrent, available.contains(state.currentIndex) { return state.currentIndex }
        return available.first
    }

    private func present(
        _ replacement: WallpaperWindowController,
        replacing previous: WallpaperWindowController?,
        effect: WallpaperTransitionEffect,
        on screen: NSScreen
    ) {
        let targetFrame = screen.frame
        let window = replacement.window
        switch effect {
        case .cut:
            previous?.teardownAndClose()
            window?.alphaValue = 1
            replacement.showWindow(nil)
            window?.makeKeyAndOrderFront(nil)
            window?.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
        case .crossfade:
            window?.alphaValue = 0
            replacement.showWindow(nil)
            window?.makeKeyAndOrderFront(nil)
            window?.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.45
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window?.animator().alphaValue = 1
                previous?.window?.animator().alphaValue = 0
            } completionHandler: {
                previous?.teardownAndClose()
            }
        case .slideLeft, .slideRight:
            let direction: CGFloat = effect == .slideLeft ? 1 : -1
            window?.setFrame(targetFrame.offsetBy(dx: direction * targetFrame.width, dy: 0), display: false)
            window?.alphaValue = 1
            replacement.showWindow(nil)
            window?.makeKeyAndOrderFront(nil)
            window?.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.5
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window?.animator().setFrame(targetFrame, display: true)
                previous?.window?.animator().alphaValue = 0
            } completionHandler: {
                previous?.teardownAndClose()
            }
        case .zoom:
            let inset = min(targetFrame.width, targetFrame.height) * 0.08
            window?.setFrame(targetFrame.insetBy(dx: inset, dy: inset), display: false)
            window?.alphaValue = 0
            replacement.showWindow(nil)
            window?.makeKeyAndOrderFront(nil)
            window?.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.5
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window?.animator().setFrame(targetFrame, display: true)
                window?.animator().alphaValue = 1
                previous?.window?.animator().alphaValue = 0
            } completionHandler: {
                previous?.teardownAndClose()
            }
        }
    }

    private func handleScreenChange() {
        guard let store, let items = try? store.items() else { return }
        reapply(to: currentDisplays(), policy: playbackPolicy, items: items)
    }

    private func currentDisplays() -> [DisplayService.Display] {
        NSScreen.screens.enumerated().map { index, screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            let id = number.map { "display-\($0.uint32Value)" } ?? "display-\(index)"
            return DisplayService.Display(id: id, name: screen.localizedName.isEmpty ? "显示器 \(index + 1)" : screen.localizedName, screen: screen)
        }
    }

    private func displayID(for screen: NSScreen) -> String {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number.map { "display-\($0.uint32Value)" } ?? "display-0"
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private final class WallpaperWindowController: NSWindowController {
    private let wallpaperContentView: WallpaperContentView
    private let isWebWallpaper: Bool

    var playbackState: WallpaperManager.PlaybackState {
        wallpaperContentView.playbackState
    }

    init(
        item: WallpaperItem,
        screen: NSScreen,
        policy: PlaybackPolicy,
        advanceAfterVideoCompletion: Bool = false,
        onVideoPlaybackCompleted: (() -> Void)? = nil
    ) throws {
        isWebWallpaper = item.type == .web
        let window = WallpaperWindow(
            screen: screen,
            allowsMouseEvents: item.type == .web && policy.webWallpaperInteractionEnabled
        )
        let contentView = try WallpaperContentView(
            item: item,
            policy: policy,
            loops: policy.loops && !advanceAfterVideoCompletion,
            onVideoPlaybackCompleted: onVideoPlaybackCompleted,
            frame: NSRect(origin: .zero, size: screen.frame.size)
        )
        wallpaperContentView = contentView
        window.contentView = contentView
        super.init(window: window)
    }

    func togglePlayback() {
        wallpaperContentView.togglePlayback()
    }

    func setPlaybackEnabled(_ isPlaying: Bool) {
        wallpaperContentView.setPlaybackEnabled(isPlaying)
    }

    func setMuted(_ muted: Bool) {
        wallpaperContentView.setMuted(muted)
    }

    func setFitMode(_ fitMode: WallpaperFitMode) {
        wallpaperContentView.setFitMode(fitMode)
    }

    func setWebInteractionEnabled(_ enabled: Bool) {
        (window as? WallpaperWindow)?.setAllowsMouseEvents(isWebWallpaper && enabled)
    }

    func setSystemSuspended(_ suspended: Bool, reloadWebContentOnResume: Bool) {
        wallpaperContentView.setSystemSuspended(
            suspended,
            reloadWebContentOnResume: reloadWebContentOnResume
        )
    }

    /// Explicitly releases the resources owned by a wallpaper window before it
    /// is removed from the manager. AppKit keeps borderless windows around when
    /// `isReleasedWhenClosed` is false, so relying on `close()` alone leaves the
    /// AVFoundation/WebKit view tree alive across queue transitions.
    func teardownAndClose() {
        wallpaperContentView.teardown()
        window?.contentView = nil
        window?.orderOut(nil)
        window?.close()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class WallpaperWindow: NSWindow {
    private var allowsMouseEvents: Bool

    init(screen: NSScreen, allowsMouseEvents: Bool = false) {
        self.allowsMouseEvents = allowsMouseEvents
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        setFrame(screen.frame, display: false)
        title = "WallpaperMac"
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        ignoresMouseEvents = !allowsMouseEvents
        acceptsMouseMovedEvents = allowsMouseEvents
        level = Self.wallpaperLevel(interactive: allowsMouseEvents)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // These windows are recreated for every queue transition. Allow AppKit
        // to release the native window once the controller has torn it down.
        isReleasedWhenClosed = true
    }

    func setAllowsMouseEvents(_ enabled: Bool) {
        allowsMouseEvents = enabled
        ignoresMouseEvents = !enabled
        acceptsMouseMovedEvents = enabled
        level = Self.wallpaperLevel(interactive: enabled)
    }

    private static func wallpaperLevel(interactive: Bool) -> NSWindow.Level {
        let key: CGWindowLevelKey = interactive ? .desktopIconWindow : .desktopWindow
        let offset = interactive ? 1 : 0
        return NSWindow.Level(rawValue: Int(CGWindowLevelForKey(key)) + offset)
    }

    override var canBecomeKey: Bool {
        allowsMouseEvents
    }

    override var canBecomeMain: Bool {
        allowsMouseEvents
    }
}

private final class WallpaperContentView: NSView, WKNavigationDelegate {
    private let item: WallpaperItem
    /// The user's requested playback state. System suspension never changes this value.
    private var isPlaying: Bool
    private var isSystemSuspended = false
    private var isMuted: Bool
    private var fitMode: WallpaperFitMode
    private let loops: Bool
    private let onVideoPlaybackCompleted: (() -> Void)?
    private var imageLayer: CALayer?
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var streamingController: WallpaperVideoStreamController?
    private var webView: WKWebView?
    private var loopObserver: NSObjectProtocol?
    private var compatibilityTask: Task<Void, Never>?
    private var isTornDown = false

    var playbackState: WallpaperManager.PlaybackState {
        switch item.type {
        case .image:
            return .staticImage
        case .video, .web:
            return isPlaying && !isSystemSuspended
                ? .playing(isMuted: isMuted)
                : .paused(isMuted: isMuted)
        }
    }

    init(
        item: WallpaperItem,
        policy: PlaybackPolicy,
        loops: Bool,
        onVideoPlaybackCompleted: (() -> Void)?,
        frame: NSRect
    ) throws {
        self.item = item
        self.isPlaying = policy.isPlaying
        self.isMuted = policy.isMuted
        self.fitMode = policy.fitMode
        self.loops = loops
        self.onVideoPlaybackCompleted = onVideoPlaybackCompleted
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        try configureContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        isPlaying = false

        if let loopObserver {
            NotificationCenter.default.removeObserver(loopObserver)
            self.loopObserver = nil
        }
        compatibilityTask?.cancel()
        compatibilityTask = nil
        streamingController?.teardown()
        streamingController = nil

        player?.pause()
        playerLayer?.player = nil
        player?.replaceCurrentItem(with: nil)
        playerLayer?.removeFromSuperlayer()
        imageLayer?.removeFromSuperlayer()
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        layer?.contents = nil
        playerLayer = nil
        imageLayer = nil
        player = nil

        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
    }

    deinit {
        teardown()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard item.type == .web else { return super.hitTest(point) }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        item.type == .web
    }

    override func mouseDown(with event: NSEvent) {
        guard item.type == .web else {
            super.mouseDown(with: event)
            return
        }
        dispatchWebMouseEvent(event, phase: .mouseDown)
    }

    override func mouseUp(with event: NSEvent) {
        guard item.type == .web else {
            super.mouseUp(with: event)
            return
        }
        dispatchWebMouseEvent(event, phase: .mouseUp)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if item.type == .web, let webView {
            window?.makeFirstResponder(webView)
        }
    }

    private func dispatchWebMouseEvent(_ event: NSEvent, phase: WebMouseEventPhase) {
        guard let webView else { return }
        let localPoint = convert(event.locationInWindow, from: nil)
        let x = max(0, min(bounds.width, localPoint.x))
        let y = max(0, min(bounds.height, bounds.height - localPoint.y))
        let script = WebMouseEventScript.source(x: x, y: y, phase: phase)
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    override func layout() {
        super.layout()
        imageLayer?.frame = bounds
        playerLayer?.frame = bounds
        streamingController?.setFrame(bounds)
        webView?.frame = bounds
    }

    func togglePlayback() {
        guard !isTornDown, item.type != .image else { return }
        isPlaying.toggle()
        applyPlaybackState()
    }

    func setPlaybackEnabled(_ isPlaying: Bool) {
        guard !isTornDown, item.type != .image else { return }
        self.isPlaying = isPlaying
        applyPlaybackState()
    }

    func setFitMode(_ fitMode: WallpaperFitMode) {
        guard !isTornDown, self.fitMode != fitMode else { return }
        self.fitMode = fitMode
        imageLayer?.contentsGravity = imageContentsGravity
        playerLayer?.videoGravity = videoGravity
        streamingController?.setVideoGravity(videoGravity)
    }

    func setSystemSuspended(_ suspended: Bool, reloadWebContentOnResume: Bool) {
        guard !isTornDown else { return }
        let wasSuspended = isSystemSuspended
        isSystemSuspended = suspended
        if wasSuspended && !suspended && reloadWebContentOnResume && item.type == .web {
            webView?.reload()
            return
        }
        applyPlaybackState()
    }

    private var imageContentsGravity: CALayerContentsGravity {
        isPortraitAsset || fitMode == .fit ? .resizeAspect : .resizeAspectFill
    }

    private var videoGravity: AVLayerVideoGravity {
        isPortraitAsset || fitMode == .fit ? .resizeAspect : .resizeAspectFill
    }

    private var isPortraitAsset: Bool {
        if let width = item.metadata?.pixelWidth,
           let height = item.metadata?.pixelHeight,
           width > 0,
           height > 0 {
            return height > width
        }
        if let thumbnailURL = item.thumbnailURL,
           let image = NSImage(contentsOf: thumbnailURL) {
            return image.size.height > image.size.width
        }
        if item.type == .image,
           let image = NSImage(contentsOf: item.sourceURL) {
            return image.size.height > image.size.width
        }
        return false
    }

    private func applyPlaybackState() {
        let shouldPlay = isPlaying && !isSystemSuspended
        switch item.type {
        case .image:
            break
        case .video:
            if let streamingController {
                streamingController.setPlaying(shouldPlay)
            } else if shouldPlay {
                player?.play()
            } else {
                player?.pause()
            }
        case .web:
            evaluateMediaScript(shouldPlay ? "play" : "pause")
        }
    }

    func setMuted(_ muted: Bool) {
        guard !isTornDown, item.type != .image else { return }
        isMuted = muted
        player?.isMuted = muted
        if item.type == .web {
            let value = muted ? "true" : "false"
            webView?.evaluateJavaScript("document.querySelectorAll('video,audio').forEach(function(media){ media.muted = \(value); media.volume = \(muted ? 0 : 1); });", completionHandler: nil)
        }
    }

    private func configureContent() throws {
        switch item.type {
        case .image:
            guard let image = NSImage(contentsOf: item.sourceURL),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw WallpaperContentError.cannotLoadResource(item.sourceURL)
            }
            let imageLayer = CALayer()
            imageLayer.frame = bounds
            imageLayer.contents = cgImage
            imageLayer.contentsGravity = imageContentsGravity
            imageLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            imageLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            layer?.addSublayer(imageLayer)
            self.imageLayer = imageLayer
        case .video:
            configureVideoPlayback(at: item.playbackURL ?? item.sourceURL)
        case .web:
            let configuration = WKWebViewConfiguration()
            configuration.mediaTypesRequiringUserActionForPlayback = []
            let webView = WKWebView(frame: bounds, configuration: configuration)
            webView.autoresizingMask = [.width, .height]
            webView.allowsBackForwardNavigationGestures = false
            webView.navigationDelegate = self
            webView.setValue(false, forKey: "drawsBackground")
            let entryURL = item.entryURL ?? item.sourceURL
            let readRoot = item.sourceURL.hasDirectoryPath ? item.sourceURL : item.sourceURL.deletingLastPathComponent()
            webView.loadFileURL(entryURL, allowingReadAccessTo: readRoot)
            addSubview(webView)
            self.webView = webView
        }
    }

    private func configureVideoPlayback(at sourceURL: URL) {
        compatibilityTask = Task { [weak self] in
            guard let self else { return }
            do {
                let asset = AVURLAsset(url: sourceURL)
                let isPlayable = try await asset.load(.isPlayable)
                let codec = try await videoCodec(for: asset)
                guard !Task.isCancelled else { return }
                guard VideoPlaybackCompatibility.requiresConversion(
                    codec: codec,
                    isPlayable: isPlayable
                ) else {
                    await MainActor.run { [weak self] in
                        self?.installVideoPlayer(at: sourceURL)
                    }
                    return
                }

                await MainActor.run { [weak self] in
                    self?.installStreamingVideoPlayer(at: sourceURL)
                }
            } catch {
                NSLog("WallpaperMac compatibility playback failed for \(sourceURL.path): \(error.localizedDescription)")
            }
        }
    }

    private func installStreamingVideoPlayer(at sourceURL: URL) {
        guard !isTornDown, streamingController == nil else { return }
        let controller = WallpaperVideoStreamController(
            sourceURL: sourceURL,
            isPlaying: isPlaying && !isSystemSuspended,
            videoGravity: videoGravity,
            loops: loops,
            frame: bounds,
            onVideoPlaybackCompleted: onVideoPlaybackCompleted
        )
        streamingController = controller
        layer?.addSublayer(controller.displayLayer)
        controller.start()
    }

    private func installVideoPlayer(at playbackURL: URL) {
        guard !isTornDown, player == nil else { return }
        let player = AVPlayer(url: playbackURL)
        player.automaticallyWaitsToMinimizeStalling = true
        player.currentItem?.preferredForwardBufferDuration = VideoPlaybackCompatibility.preferredForwardBufferSeconds
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = videoGravity
        // The player is installed after asynchronous codec inspection, so the
        // view may already have completed its initial layout pass.
        playerLayer.frame = bounds
        layer?.addSublayer(playerLayer)
        needsLayout = true
        self.player = player
        self.playerLayer = playerLayer
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self, weak player] _ in
            guard let self, !self.isTornDown else { return }
            if self.loops {
                player?.seek(to: .zero)
                if self.isPlaying && !self.isSystemSuspended { player?.play() }
            } else {
                self.onVideoPlaybackCompleted?()
            }
        }
        player.isMuted = isMuted
        if isPlaying { player.play() }
    }

    private func videoCodec(for asset: AVURLAsset) async throws -> String? {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first,
              let description = try await track.load(.formatDescriptions).first else {
            return nil
        }
        let codec = CMFormatDescriptionGetMediaSubType(description)
        return String(
            format: "%c%c%c%c",
            (codec >> 24) & 0xff,
            (codec >> 16) & 0xff,
            (codec >> 8) & 0xff,
            codec & 0xff
        ).lowercased()
    }

    private func evaluateMediaScript(_ action: String) {
        let script = "document.querySelectorAll('video,audio').forEach(function(media){ var result = media.\(action)(); if (result && result.catch) { result.catch(function() {}); } });"
        webView?.evaluateJavaScript(script, completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        setMuted(isMuted)
        if isPlaying && !isSystemSuspended {
            evaluateMediaScript("play")
        }
    }


}

private enum WallpaperContentError: Error, LocalizedError {
    case cannotLoadResource(URL)

    var errorDescription: String? {
        switch self {
        case .cannotLoadResource(let url):
            return "无法加载壁纸资源：\(url.path)"
        }
    }
}
