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
    /// Non-nil when the persisted queue files could not be loaded. While set,
    /// queue writes are blocked so the fallback state cannot overwrite the
    /// user's only copy.
    @Published private(set) var queueLoadError: String?
    /// Non-nil when the last queue save failed (for example the disk is full).
    /// This is separate from `queueLoadError`: the files are readable, but the
    /// latest write did not reach them.
    @Published private(set) var queueSaveError: String?

    /// Identity of one presentation of one wallpaper on one display.
    ///
    /// Completion callbacks from a previous controller (teardown, loop restart,
    /// rapid queue cycling) carry the session they were started with. Only the
    /// session currently installed for that display may advance the queue, so a
    /// late callback cannot skip the wallpaper the user is now looking at.
    struct PlaybackSession: Equatable, Sendable {
        let token: UUID
        let itemID: UUID
        let displayID: String

        init(itemID: UUID, displayID: String, token: UUID = UUID()) {
            self.token = token
            self.itemID = itemID
            self.displayID = displayID
        }
    }

    private var currentSessions: [String: PlaybackSession] = [:]
    private var sessionDurations: [String: Double] = [:]

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
    private var hardDeadlineTimers: [String: Timer] = [:]
    private var queueTimerGenerations: [String: Int] = [:]
    private var remainingQueueIntervals: [String: TimeInterval] = [:]
    private var remainingHardDeadlines: [String: TimeInterval] = [:]
    private var connectedDisplays: [String: DisplayService.Display] = [:]
    private var connectedIdentities: [String: DisplayIdentity] = [:]
    private var displayProfiles: [String: DisplayProfile] = [:]
    private var unmatchedLegacyAssignments: [DisplayAssignment] = []
    private var unmatchedLegacyBindings: [DisplayPlaybackBinding] = []
    private var queueItems: [UUID: WallpaperItem] = [:]
    private var queueLibrary: [UUID: PlaybackQueue] = [:]
    private var bindings: [String: DisplayPlaybackBinding] = [:]
    private weak var store: WallpaperStore?
    private var persistenceGate = LibraryPersistenceGate()
    private var playbackPolicy = PlaybackPolicy()
    private var showsHiddenWallpapers = false
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
        hardDeadlineTimers.values.forEach { $0.invalidate() }
        // WallpaperManager is main-actor isolated, but Swift does not allow
        // calling the main-actor controller teardown from deinit. All runtime
        // shutdown paths explicitly tear down controllers before removing
        // them; the app-owned manager normally lives for the process lifetime.
    }

    func configure(store: WallpaperStore, policy: PlaybackPolicy = PlaybackPolicy()) {
        for displayID in Set(queueTimers.keys).union(hardDeadlineTimers.keys) {
            invalidateQueueTimers(for: displayID)
        }
        controllers.values.forEach { $0.teardownAndClose() }
        controllers.removeAll()
        currentSessions.removeAll()
        sessionDurations.removeAll()
        displayProfiles = [:]
        connectedIdentities = [:]
        unmatchedLegacyAssignments = []
        unmatchedLegacyBindings = []
        showsHiddenWallpapers = false
        self.store = store
        self.playbackPolicy = policy
        activityMonitor?.update(policy: policy)
        loadQueues()
        loadAssignments()
    }

    func update(policy: PlaybackPolicy) {
        playbackPolicy = policy
        activityMonitor?.update(policy: policy)
        for (displayID, controller) in controllers {
            let item = assignments[displayID]?.wallpaperID.flatMap { queueItems[$0] }
            controller.setMuted(policy.isMuted)
            controller.setFitMode(item?.effectiveFitMode(global: policy.fitMode) ?? policy.fitMode)
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
        for displayID in bindings.keys {
            reconcileScheduling(for: displayID)
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
        connectedIdentities[display.id] = display.identity
        if displayProfiles[display.id] == nil {
            mergeProfiles(for: [display])
        }
        queueItems[item.id] = item
        if !preserveQueue {
            stopQueue(displayID: display.id, persist: true)
        }
        let session = PlaybackSession(itemID: item.id, displayID: display.id)
        currentSessions[display.id] = session
        sessionDurations[display.id] = Self.validDuration(item.metadata?.durationSeconds)
        let replacement = try WallpaperWindowController(
            item: item,
            screen: display.screen,
            policy: policy,
            advanceAfterVideoCompletion: advanceAfterVideoCompletion,
            onVideoPlaybackCompleted: { [weak self] in
                self?.videoPlaybackDidFinish(for: display.id, session: session)
            },
            onFrameProgress: { [weak self] in
                self?.noteVideoFrameProgress(for: display.id, session: session)
            },
            onVideoDurationChanged: { [weak self] duration in
                self?.videoDurationDidChange(for: display.id, session: session, duration: duration)
            },
            initialSystemSuspended: isSystemSuspended
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
        currentSessions.removeValue(forKey: displayID)
        sessionDurations.removeValue(forKey: displayID)
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

    /// Refreshes the manager's item cache after a field-level hidden update.
    func updateHiddenState(for items: [WallpaperItem]) {
        for item in items {
            queueItems[item.id] = item
        }
    }

    /// Applies the hidden-wallpaper switch. Locking immediately removes hidden
    /// wallpapers from screens; unlocking lets the normal restore path bring
    /// back still-assigned hidden items and hidden queue members.
    func setShowsHiddenWallpapers(
        _ shows: Bool,
        policy: PlaybackPolicy,
        items: [WallpaperItem]
    ) {
        playbackPolicy = policy
        showsHiddenWallpapers = shows
        queueItems = UniquedDictionary.build(items.map { ($0.id, $0) }, label: "queue items")
        if shows {
            reapply(to: currentDisplays(), policy: policy, items: items)
        } else {
            for display in connectedDisplays.values {
                hideHiddenPresentationIfNeeded(displayID: display.id)
            }
            for displayID in bindings.keys {
                reconcileScheduling(for: displayID)
            }
        }
    }

    private func hideHiddenPresentationIfNeeded(displayID: String) {
        guard let itemID = assignments[displayID]?.wallpaperID,
              let item = queueItems[itemID],
              item.isHidden else { return }
        guard let display = connectedDisplays[displayID] else {
            suspendPresentation(displayID: displayID)
            return
        }
        if let binding = bindings[displayID],
           let queue = queueLibrary[binding.activeQueueID] {
            var updated = binding
            var state = updated.state(for: queue.id)
            if let next = nextQueueIndex(queue: queue, state: state),
               let nextItem = queueItems[queue.wallpaperIDs[next]] {
                state.currentIndex = next
                state.isPlaying = state.isEnabled && state.isPlaying
                updated.queueStates[queue.id] = state
                bindings[displayID] = updated
                publishBindings()
                publishLegacyQueues()
                persistQueues()
                invalidateQueueTimers(for: displayID)
                var presentationPolicy = playbackPolicy
                presentationPolicy.isPlaying = state.isEnabled && state.isPlaying
                do {
                    try apply(
                        item: nextItem,
                        to: display,
                        policy: presentationPolicy,
                        preserveQueue: true
                    )
                    return
                } catch {
                    suspendPresentation(displayID: displayID)
                    return
                }
            }
            state.isPlaying = false
            updated.queueStates[queue.id] = state
            bindings[displayID] = updated
            publishBindings()
            publishLegacyQueues()
            persistQueues()
        }
        suspendPresentation(displayID: displayID)
    }

    /// Tears down a display's presentation while keeping its assignment for a
    /// later unlock. Unlike `clear(displayID:)`, the wallpaperID is retained.
    private func suspendPresentation(displayID: String) {
        invalidateQueueTimers(for: displayID)
        currentSessions.removeValue(forKey: displayID)
        sessionDurations.removeValue(forKey: displayID)
        controllers.removeValue(forKey: displayID)?.teardownAndClose()
        appliedWallpaperIDs.removeValue(forKey: displayID)
        playbackStates.removeValue(forKey: displayID)
        if assignments[displayID] != nil {
            assignments[displayID]?.applicationState = .idle
        }
        publishDisplayAssignments()
        persistAssignments()
    }

    func clear(itemID: UUID) {
        removeWallpaperIDs([itemID])
    }

    func removeWallpaperIDs(_ itemIDs: Set<UUID>) {
        guard !itemIDs.isEmpty else { return }
        let displaysShowingRemovedItem = assignments.values.compactMap { assignment -> String? in
            guard let wallpaperID = assignment.wallpaperID, itemIDs.contains(wallpaperID) else { return nil }
            return assignment.id
        }
        // Remove queue memberships first and let still-enabled displays move to
        // their successor. Only displays that lost their current item and were
        // not restarted are cleared.
        let restarted = removeWallpaperIDsFromQueues(itemIDs)
        for displayID in displaysShowingRemovedItem where !restarted.contains(displayID) {
            clear(displayID: displayID)
        }
    }

    func clearAll() {
        queueTimers.values.forEach { $0.invalidate() }
        queueTimers.removeAll()
        controllers.values.forEach { $0.teardownAndClose() }
        controllers.removeAll()
        currentSessions.removeAll()
        sessionDurations.removeAll()
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
        let previousDisplays = connectedDisplays
        connectedDisplays = UniquedDictionary.build(displays.map { ($0.id, $0) }, label: "connected displays")
        connectedIdentities = UniquedDictionary.build(
            displays.map { ($0.id, $0.identity) },
            label: "connected identities"
        )
        if displays.contains(where: { displayProfiles[$0.id] == nil }) {
            mergeProfiles(for: displays)
        }
        queueItems = UniquedDictionary.build(items.map { ($0.id, $0) }, label: "queue items")
        let connectedIDs = Set(displays.map(\.id))
        let potentiallyDisconnected = Set(previousDisplays.keys)
            .union(assignments.keys)
            .union(controllers.keys)
            .union(bindings.keys)
            .union(currentSessions.keys)
            .union(queueTimers.keys)
            .union(hardDeadlineTimers.keys)
        for key in potentiallyDisconnected where !connectedIDs.contains(key) {
            invalidateQueueTimers(for: key)
            currentSessions.removeValue(forKey: key)
            controllers.removeValue(forKey: key)?.teardownAndClose()
            sessionDurations.removeValue(forKey: key)
            if assignments[key] != nil {
                assignments[key]?.isConnected = false
                assignments[key]?.applicationState = .disconnected
            }
            appliedWallpaperIDs.removeValue(forKey: key)
            playbackStates.removeValue(forKey: key)
            connectedIdentities.removeValue(forKey: key)
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
            guard let binding = bindings[display.id] else { continue }
            let queue = queueLibrary[binding.activeQueueID]
            let state = queue.map { binding.state(for: $0.id) }
            let hasEnabledQueue = state?.isEnabled == true && queue?.wallpaperIDs.isEmpty == false
            let expectedItemID: UUID?
            if hasEnabledQueue, let queue, let state {
                expectedItemID = queue.wallpaperIDs[safe: state.currentIndex]
            } else {
                expectedItemID = assignments[display.id]?.wallpaperID
            }
            let currentItemMatches = expectedItemID != nil
                && appliedWallpaperIDs[display.id] == expectedItemID
                && currentSessions[display.id]?.itemID == expectedItemID
            let expectedAvailable = WallpaperVisibility.isEligible(
                expectedItemID.flatMap { queueItems[$0] },
                showsHidden: showsHiddenWallpapers
            )
            let geometryChanged = previousDisplays[display.id]?.screen.frame != display.screen.frame
            let action = DisplayReconciler.action(
                isConnected: true,
                wasConnected: previousDisplays[display.id] != nil,
                hasController: controllers[display.id] != nil && currentSessions[display.id] != nil,
                geometryChanged: geometryChanged,
                currentItemMatches: currentItemMatches,
                expectedItemAvailable: expectedAvailable
            )
            switch action {
            case .keep:
                reconcileMissingTimerIfNeeded(for: display.id, state: state)
                continue
            case .updateFrame:
                controllers[display.id]?.updateFrame(for: display.screen)
                reconcileMissingTimerIfNeeded(for: display.id, state: state)
                continue
            case .restore:
                if hasEnabledQueue, let queue {
                    startQueue(queueID: queue.id, on: display, policy: policy, items: items, resetIndex: false)
                    continue
                }
                guard let wallpaperID = expectedItemID,
                      let item = queueItems[wallpaperID],
                      WallpaperVisibility.isEligible(item, showsHidden: showsHiddenWallpapers) else {
                    if let wallpaperID = expectedItemID,
                       let item = queueItems[wallpaperID],
                       item.isHidden,
                       !showsHiddenWallpapers {
                        // Keep the assignment for a later unlock, but do not
                        // present a stale "applied" state while locked.
                        assignments[display.id]?.applicationState = .idle
                    }
                    continue
                }
                try? apply(item: item, to: display, policy: policy, preserveQueue: true)
            case .disconnect:
                continue
            }
        }
        publishBindings()
        publishLegacyQueues()
        publishDisplayAssignments()
        persistAssignments()
    }

    private func reconcileMissingTimerIfNeeded(for displayID: String, state: DisplayQueueState?) {
        guard let state, shouldScheduleQueue(for: displayID, state: state), queueTimers[displayID] == nil else {
            return
        }
        reconcileScheduling(for: displayID)
    }

    func restoreAssignments(to displays: [DisplayService.Display], policy: PlaybackPolicy, items: [WallpaperItem]) {
        // A crash between committing the main index and cleaning queue
        // references can leave IDs that no longer exist. The index is the
        // authority for existence; prune those dangling IDs before replaying.
        pruneDanglingQueueMembers(knownItemIDs: Set(items.map(\.id)))
        reapply(to: displays, policy: policy, items: items)
    }

    private func pruneDanglingQueueMembers(knownItemIDs: Set<UUID>) {
        var changed = false
        for (queueID, queue) in queueLibrary {
            let dangling = Set(queue.wallpaperIDs).subtracting(knownItemIDs)
            guard !dangling.isEmpty else { continue }
            var updated = queue
            updated.removeWallpaperIDs(dangling)
            queueLibrary[queueID] = updated
            changed = true
            for displayID in bindings.keys {
                guard var binding = bindings[displayID],
                      var state = binding.queueStates[queueID] else { continue }
                state.normalize(for: updated)
                binding.queueStates[queueID] = state
                bindings[displayID] = binding
            }
        }
        guard changed else { return }
        publishQueueLibrary()
        publishBindings()
        publishLegacyQueues()
        persistQueues()
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
        advanceMode: QueueAdvanceMode = .fixedInterval,
        defaultIntervalSeconds: Double = 30,
        transition: WallpaperTransitionEffect = .crossfade
    ) -> PlaybackQueue? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !persistenceGate.blocksPersistence,
              !trimmed.isEmpty,
              !playbackQueues.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return nil }
        let queue = PlaybackQueue(
            name: trimmed,
            playbackMode: playbackMode,
            completionBehavior: completionBehavior,
            advanceMode: advanceMode,
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
        guard !persistenceGate.blocksPersistence else { return false }
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
                advanceMode: normalized.advanceMode,
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
        guard !persistenceGate.blocksPersistence else { return false }
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
        guard !persistenceGate.blocksPersistence else { return }
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
        guard !persistenceGate.blocksPersistence else { return }
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
        guard !persistenceGate.blocksPersistence else { return }
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
        guard !persistenceGate.blocksPersistence else { return }
        let queueID = bindings[queue.displayID]?.activeQueueID ?? UUID()
        let isNew = queueLibrary[queueID] == nil
        let namedQueue = PlaybackQueue(
            id: queueID,
            name: isNew ? (queue.displayName.isEmpty ? "显示器队列" : queue.displayName) : (queueLibrary[queueID]?.name ?? queue.displayName),
            wallpaperIDs: queue.wallpaperIDs,
            advanceMode: queueLibrary[queueID]?.advanceMode ?? .fixedInterval,
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
        queueItems = UniquedDictionary.build(items.map { ($0.id, $0) }, label: "queue items")
        var binding = bindings[display.id] ?? DisplayPlaybackBinding(displayID: display.id, displayName: display.name)
        binding.displayName = display.name
        binding.activeQueueID = queueID
        var state = binding.state(for: queueID)
        if resetIndex { state.currentIndex = 0 }
        let availableIDs = queue.wallpaperIDs.filter {
            WallpaperVisibility.isEligible(queueItems[$0], showsHidden: showsHiddenWallpapers)
        }
        guard !availableIDs.isEmpty else {
            let hasHiddenMembers = !showsHiddenWallpapers
                && queue.wallpaperIDs.contains { queueItems[$0]?.isHidden == true }
            if hasHiddenMembers {
                // A locked hidden-only queue keeps its enabled intent so it can
                // resume after unlocking, but it must not leave a hidden
                // wallpaper on screen.
                state.isPlaying = false
                binding.queueStates[queueID] = state
                bindings[display.id] = binding
                publishBindings()
                publishLegacyQueues()
                persistQueues()
                suspendPresentation(displayID: display.id)
                return
            }
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
        let shouldPlay = state.isPlaying || !state.isEnabled
        var presentationPolicy = policy
        presentationPolicy.isPlaying = shouldPlay
        state.currentIndex = index
        state.isEnabled = true
        state.isPlaying = shouldPlay
        binding.queueStates[queueID] = state
        bindings[display.id] = binding
        publishBindings()
        publishLegacyQueues()
        persistQueues()
        invalidateQueueTimers(for: display.id)
        do {
            try apply(
                item: item,
                to: display,
                policy: presentationPolicy,
                transition: effectiveTransition(queue: queue, state: state),
                preserveQueue: true,
                advanceAfterVideoCompletion: shouldAdvanceAfterVideoCompletion(queue: queue, item: item)
            )
        } catch {
            // Do not leave the display without a timer: a failed apply would
            // otherwise stall the queue permanently (no tick, no completion).
            scheduleQueueTimer(for: display.id, interval: 5)
            return
        }
        scheduleQueueTimerIfNeeded(for: display.id, queue: queue, state: state, item: item)
    }

    func stopQueue(displayID: String, persist: Bool = true) {
        invalidateQueueTimers(for: displayID)
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
        playbackPolicy.isPlaying = isPlaying
        for (displayID, controller) in controllers {
            controller.setPlaybackEnabled(isPlaying)
            playbackStates[displayID] = controller.playbackState
            guard var binding = bindings[displayID] else { continue }
            let queueID = binding.activeQueueID
            var state = binding.state(for: queueID)
            // Pausing playback must not become a permanent queue stop. Keep
            // the user's queue intent enabled and freeze/resume scheduling in
            // one place below.
            state.isPlaying = isPlaying
            binding.queueStates[queueID] = state
            bindings[displayID] = binding
        }
        publishBindings()
        publishLegacyQueues()
        persistQueues()
        for displayID in bindings.keys {
            reconcileScheduling(for: displayID)
        }
    }

    func setMutedForAll(_ isMuted: Bool) {
        for (displayID, controller) in controllers {
            controller.setMuted(isMuted)
            playbackStates[displayID] = controller.playbackState
        }
    }

    func togglePlayback(for displayID: String) {
        guard let controller = controllers[displayID] else { return }
        if case .staticImage = controller.playbackState { return }
        guard var binding = bindings[displayID] else { return }
        let queueID = binding.activeQueueID
        var state = binding.state(for: queueID)
        // playbackState also contains system suspension. Toggle the saved user
        // intent instead of reading the effective (possibly suspended) state.
        state.isPlaying.toggle()
        playbackPolicy.isPlaying = state.isPlaying
        controller.setPlaybackEnabled(state.isPlaying)
        playbackStates[displayID] = controller.playbackState
        binding.queueStates[queueID] = state
        bindings[displayID] = binding
        publishBindings()
        publishLegacyQueues()
        persistQueues()
        reconcileScheduling(for: displayID)
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
        queueItems[wallpaper.id] = wallpaper
        let activeQueue = bindings[displayID].flatMap { queueLibrary[$0.activeQueueID] }
        let advanceAfterVideoCompletion = activeQueue?.usesCompletionAdvance(for: wallpaper.type) == true
        do {
            // New session invalidates completion callbacks from the replaced
            // controller; timers are rescheduled for the new playback below.
            let session = PlaybackSession(itemID: wallpaper.id, displayID: displayID)
            currentSessions[displayID] = session
            sessionDurations[displayID] = Self.validDuration(wallpaper.metadata?.durationSeconds)
            let replacement = try WallpaperWindowController(
                item: wallpaper,
                screen: display,
                policy: policy,
                advanceAfterVideoCompletion: advanceAfterVideoCompletion,
                onVideoPlaybackCompleted: { [weak self] in
                    self?.videoPlaybackDidFinish(for: displayID, session: session)
                },
                onFrameProgress: { [weak self] in
                    self?.noteVideoFrameProgress(for: displayID, session: session)
                },
                onVideoDurationChanged: { [weak self] duration in
                    self?.videoDurationDidChange(for: displayID, session: session, duration: duration)
                },
                initialSystemSuspended: isSystemSuspended
            )
            replacement.setSystemSuspended(isSystemSuspended, reloadWebContentOnResume: false)
            controllers[displayID]?.teardownAndClose()
            controllers[displayID] = replacement
            playbackStates[displayID] = replacement.playbackState
            replacement.window?.orderFrontRegardless()
            // Reload replaces the player entirely. Reconcile all timers for
            // the live queue state instead of arming a paused queue.
            reconcileScheduling(for: displayID)
        } catch {
            return
        }
    }

    private func loadAssignments() {
        var loaded: [String: DisplayAssignment] = [:]
        for profile in displayProfiles.values {
            guard let assignment = profile.assignment else { continue }
            let isConnected = connectedIdentities[profile.profileID] != nil
            loaded[profile.profileID] = DisplayAssignment(
                id: profile.profileID,
                displayName: profile.displayName,
                isConnected: isConnected,
                wallpaperID: assignment.wallpaperID,
                applicationState: isConnected ? assignment.applicationState : .disconnected
            )
        }
        assignments = loaded
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
            persistenceGate.recordSuccessfulLoad()
            queueLoadError = nil
            queueSaveError = nil
            return
        }
        let loadResult = store.loadPlaybackQueueConfiguration()
        if let loadError = loadResult.loadError {
            persistenceGate.recordLoadFailure(loadError)
        } else {
            persistenceGate.recordSuccessfulLoad()
        }
        queueLoadError = persistenceGate.loadError
        queueSaveError = nil
        playbackQueues = loadResult.queues
        queueLibrary = UniquedDictionary.build(loadResult.queues.map { ($0.id, $0) }, label: "playback queues")
        prepareDisplayProfiles(
            legacyBindings: loadResult.loadError == nil ? loadResult.bindings : nil
        )
        let profileBindings = displayProfiles.values.compactMap { profile -> DisplayPlaybackBinding? in
            guard let binding = profile.binding else { return nil }
            return DisplayPlaybackBinding(
                displayID: profile.profileID,
                displayName: profile.displayName,
                activeQueueID: binding.activeQueueID,
                queueStates: binding.queueStates
            )
        }
        bindings = UniquedDictionary.build(profileBindings.map { ($0.displayID, $0) }, label: "display bindings")
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

    /// Creates or refreshes stable display profiles before assignments and
    /// bindings are loaded. Runtime `CGDirectDisplayID` values are never used
    /// as persisted keys.
    private func prepareDisplayProfiles(legacyBindings: [DisplayPlaybackBinding]? = nil) {
        guard let store else {
            displayProfiles = [:]
            unmatchedLegacyAssignments = []
            unmatchedLegacyBindings = []
            connectedIdentities = [:]
            return
        }
        let displays = currentDisplays()
        connectedIdentities = UniquedDictionary.build(
            displays.map { ($0.id, $0.identity) },
            label: "connected identities"
        )
        let now = Date()
        let existing = (try? store.displayProfilesDocument()) ?? nil

        if let document = existing {
            // Import legacy files only when they are newer than the profile
            // document (for example edits made by a 0.2.8 build). The migrator
            // additionally requires the display name to match, so a swapped
            // runtime ID cannot hijack another display's queue.
            let profilesModified = displayFileModificationDate("display-profiles.json")
            let importAssignments = Self.isNewer(
                displayFileModificationDate("display-assignments.json"),
                than: profilesModified
            )
            let importBindings = Self.isNewer(
                displayFileModificationDate("display-playback-bindings.json"),
                than: profilesModified
            )
            let merged = DisplayProfileMigrator.merge(
                document: document,
                identities: displays.map(\.identity),
                legacyAssignments: (try? store.displayAssignments()) ?? [],
                legacyBindings: legacyBindings ?? [],
                overwriteAssignments: importAssignments,
                overwriteBindings: importBindings,
                now: now
            )
            applyDisplayProfileDocument(merged)
            saveProfiles(store: store)
        } else {
            let migration = DisplayProfileMigrator.migrate(
                legacyAssignments: (try? store.displayAssignments()) ?? [],
                legacyBindings: legacyBindings ?? [],
                identities: displays.map(\.identity),
                now: now
            )
            applyDisplayProfileDocument(migration.document)
            saveProfiles(store: store)
        }
    }

    private func applyDisplayProfileDocument(_ document: DisplayProfileDocument) {
        displayProfiles = UniquedDictionary.build(
            document.profiles.map { ($0.profileID, $0) },
            label: "display profiles"
        )
        unmatchedLegacyAssignments = document.unmatchedLegacyAssignments
        unmatchedLegacyBindings = document.unmatchedLegacyBindings
    }

    /// Adds profiles for displays that appeared after launch and lets a
    /// reconnecting display claim its preserved legacy records.
    private func mergeProfiles(for displays: [DisplayService.Display]) {
        guard let store else { return }
        let document = DisplayProfileDocument(
            profiles: Array(displayProfiles.values),
            unmatchedLegacyAssignments: unmatchedLegacyAssignments,
            unmatchedLegacyBindings: unmatchedLegacyBindings
        )
        let merged = DisplayProfileMigrator.merge(
            document: document,
            identities: displays.map(\.identity),
            now: Date()
        )
        applyDisplayProfileDocument(merged)
        saveProfiles(store: store)
    }

    private func displayFileModificationDate(_ name: String) -> Date? {
        guard let store else { return nil }
        let url = store.libraryURL.appendingPathComponent(name)
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private static func isNewer(_ date: Date?, than reference: Date?) -> Bool {
        guard let date else { return false }
        guard let reference else { return true }
        return date > reference
    }

    private func syncProfilesFromRuntime() {
        for (displayID, assignment) in assignments {
            guard var profile = displayProfiles[displayID] else { continue }
            profile.assignment = assignment
            displayProfiles[displayID] = profile
        }
        for (displayID, binding) in bindings {
            guard var profile = displayProfiles[displayID] else { continue }
            profile.binding = binding
            displayProfiles[displayID] = profile
        }
        for (displayID, identity) in connectedIdentities {
            guard var profile = displayProfiles[displayID] else { continue }
            profile.identity = identity
            displayProfiles[displayID] = profile
        }
    }

    private func saveProfiles(store: WallpaperStore) {
        let document = DisplayProfileDocument(
            profiles: displayProfiles.values.sorted { $0.profileID < $1.profileID },
            unmatchedLegacyAssignments: unmatchedLegacyAssignments,
            unmatchedLegacyBindings: unmatchedLegacyBindings
        )
        do {
            try store.save(displayProfilesDocument: document)
        } catch {
            NSLog("WallpaperMac failed to save display profiles: \(error.localizedDescription)")
        }
    }

    private func legacyAssignmentSnapshot() -> [DisplayAssignment] {
        let connectedLegacyIDs = Set(
            connectedIdentities.values.map(DisplayProfileMigrator.legacyDisplayID(for:))
        )
        var snapshot = unmatchedLegacyAssignments.filter { !connectedLegacyIDs.contains($0.id) }
        for (profileID, identity) in connectedIdentities {
            guard let assignment = assignments[profileID] ?? displayProfiles[profileID]?.assignment else {
                continue
            }
            snapshot.append(
                DisplayAssignment(
                    id: DisplayProfileMigrator.legacyDisplayID(for: identity),
                    displayName: identity.localizedName,
                    isConnected: true,
                    wallpaperID: assignment.wallpaperID,
                    applicationState: assignment.applicationState
                )
            )
        }
        return snapshot
    }

    private func legacyBindingSnapshot() -> [DisplayPlaybackBinding] {
        let connectedLegacyIDs = Set(
            connectedIdentities.values.map(DisplayProfileMigrator.legacyDisplayID(for:))
        )
        var snapshot = unmatchedLegacyBindings.filter { !connectedLegacyIDs.contains($0.displayID) }
        for (profileID, identity) in connectedIdentities {
            guard let binding = bindings[profileID] ?? displayProfiles[profileID]?.binding else {
                continue
            }
            snapshot.append(
                DisplayPlaybackBinding(
                    displayID: DisplayProfileMigrator.legacyDisplayID(for: identity),
                    displayName: identity.localizedName,
                    activeQueueID: binding.activeQueueID,
                    queueStates: binding.queueStates
                )
            )
        }
        return snapshot
    }

    /// True while a corrupt queue/bindings file keeps queue writes disabled.
    var isQueuePersistenceBlocked: Bool { persistenceGate.blocksPersistence }

    /// Re-reads the queue files after the user repairs/restores them.
    /// Returns true when persistence is available again.
    @discardableResult
    func retryLoadingQueues() -> Bool {
        loadQueues()
        return !persistenceGate.blocksPersistence
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
        syncProfilesFromRuntime()
        saveProfiles(store: store)
        try? store.save(displayAssignments: legacyAssignmentSnapshot())
    }

    @discardableResult
    private func removeWallpaperIDsFromQueues(_ itemIDs: Set<UUID>) -> Set<String> {
        guard !itemIDs.isEmpty else { return [] }
        var restart: [(displayID: String, queueID: UUID, removedItemID: UUID?)] = []
        for (queueID, value) in queueLibrary {
            var queue = value
            let wasChanged = queue.wallpaperIDs.contains(where: itemIDs.contains)
            guard wasChanged else { continue }

            // Capture each display's current item before membership changes.
            var currentItems: [String: UUID] = [:]
            for displayID in bindings.keys {
                guard let binding = bindings[displayID], binding.activeQueueID == queueID else { continue }
                let state = binding.state(for: queueID)
                if queue.wallpaperIDs.indices.contains(state.currentIndex) {
                    currentItems[displayID] = queue.wallpaperIDs[state.currentIndex]
                }
            }

            queue.removeWallpaperIDs(itemIDs)
            queueLibrary[queueID] = queue
            for displayID in bindings.keys {
                guard var binding = bindings[displayID], binding.activeQueueID == queueID else { continue }
                var state = binding.state(for: queueID)
                let wasEnabled = state.isEnabled
                let currentItemID = currentItems[displayID]
                let currentRemoved = currentItemID.map { itemIDs.contains($0) } ?? false
                let fallbackIndex = state.currentIndex
                state.normalize(for: queue)
                // Keep the same item when it is still present. If it was
                // removed, fall back to its old position (the successor, or
                // the previous item at the end) and restart below.
                state.currentIndex = PlaybackIndexReconciler.reconciledIndex(
                    currentItemID: currentRemoved ? nil : currentItemID,
                    fallbackIndex: fallbackIndex,
                    remainingIDs: queue.wallpaperIDs
                )
                binding.queueStates[queueID] = state
                bindings[displayID] = binding
                if wasEnabled && currentRemoved {
                    restart.append((displayID, queueID, currentItemID))
                }
            }
        }
        publishQueueLibrary()
        publishBindings()
        publishLegacyQueues()
        persistQueues()
        var restarted: Set<String> = []
        for (displayID, queueID, removedItemID) in restart {
            guard let display = connectedDisplays[displayID],
                  let items = queueItems.isEmpty ? nil : Array(queueItems.values) else { continue }
            if queueLibrary[queueID]?.wallpaperIDs.isEmpty == true {
                guard let defaultQueue = queueLibrary[defaultQueueID], !defaultQueue.wallpaperIDs.isEmpty else { continue }
                setActiveQueue(defaultQueueID, for: display, policy: playbackPolicy, items: items)
            } else {
                startQueue(queueID: queueID, on: display, policy: playbackPolicy, items: items, resetIndex: false)
            }
            // Only consider the display handled when a different item is
            // actually on screen; otherwise the old controller still shows the
            // deleted wallpaper and must be cleared below.
            if let applied = appliedWallpaperIDs[displayID], applied != removedItemID {
                restarted.insert(displayID)
            }
        }
        return restarted
    }

    private func publishLegacyQueues() {
        displayQueues = UniquedDictionary.build(bindings.values.compactMap { binding -> (String, DisplayPlaybackQueue)? in
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
        guard !persistenceGate.blocksPersistence else {
            // Loading failed: the in-memory state is a fallback, never the
            // user's data. Keep the original files untouched until a reload
            // succeeds.
            return
        }
        guard let store else { return }
        syncProfilesFromRuntime()
        saveProfiles(store: store)
        do {
            // Keep the legacy file keyed by the current runtime ID so a
            // downgraded build can still read the latest state.
            try store.save(
                playbackQueues: playbackQueues,
                displayPlaybackBindings: legacyBindingSnapshot()
            )
            queueSaveError = nil
        } catch {
            queueSaveError = "保存播放队列失败：\(error.localizedDescription)"
        }
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
            invalidateQueueTimers(for: displayID)
            bindings[displayID] = binding
            changed = true
        }
        guard changed else { return }
        publishBindings()
        publishLegacyQueues()
    }

    private func shouldAdvanceAfterVideoCompletion(queue: PlaybackQueue, item: WallpaperItem) -> Bool {
        // Images and web wallpapers have no completion event: a completion
        // queue falls back to the fixed interval for them.
        queue.usesCompletionAdvance(for: item.type)
    }

    private func scheduleQueueTimerIfNeeded(
        for displayID: String,
        queue: PlaybackQueue,
        state: DisplayQueueState,
        item: WallpaperItem,
        resumeFromSnapshot: Bool = false
    ) {
        guard shouldScheduleQueue(for: displayID, state: state) else {
            freezeQueueTimers(for: displayID)
            return
        }
        if shouldAdvanceAfterVideoCompletion(queue: queue, item: item) {
            // Still arm a watchdog: video-completion queues rely solely on the
            // player callback, so a failed start or hung decode would stall
            // the queue forever with no timer to recover. The frame heartbeat
            // re-arms this while the pipeline is alive.
            let fullWatchdog = queue.stallWatchdogInterval(
                forVideoWithDurationSeconds: durationForCurrentSession(displayID: displayID, itemID: item.id)
            )
            let watchdog = PlaybackDeadlineMath.interval(
                full: fullWatchdog,
                remaining: remainingQueueIntervals[displayID],
                resume: resumeFromSnapshot
            )
            let deadline = PlaybackDeadlineMath.interval(
                full: queue.hardDeadlineInterval,
                remaining: remainingHardDeadlines[displayID],
                resume: resumeFromSnapshot
            )
            scheduleQueueTimer(for: displayID, interval: watchdog)
            // Absolute ceiling the heartbeat cannot extend. Both callbacks
            // carry the same scheduling generation as the watchdog.
            let generation = queueTimerGenerations[displayID] ?? 0
            hardDeadlineTimers[displayID] = Timer.scheduledTimer(withTimeInterval: max(1, deadline), repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.advanceQueue(for: displayID, generation: generation)
                }
            }
        } else {
            let fullInterval = effectiveInterval(queue: queue, state: state, itemID: item.id)
            let interval = PlaybackDeadlineMath.interval(
                full: fullInterval,
                remaining: remainingQueueIntervals[displayID],
                resume: resumeFromSnapshot
            )
            scheduleQueueTimer(for: displayID, interval: interval)
        }
    }

    private func videoDurationDidChange(for displayID: String, session: PlaybackSession, duration: Double?) {
        guard currentSessions[displayID] == session else { return }
        updateDuration(for: session.itemID, duration: duration)
    }

    private static func validDuration(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private func durationForCurrentSession(displayID: String, itemID: UUID) -> Double? {
        if let duration = sessionDurations[displayID] { return duration }
        return Self.validDuration(queueItems[itemID]?.metadata?.durationSeconds)
    }

    /// Applies a persisted fit-mode change without replacing the active player
    /// or resetting its queue session.
    func updateFitMode(for item: WallpaperItem) {
        queueItems[item.id] = item
        let mode = item.effectiveFitMode(global: playbackPolicy.fitMode)
        for (displayID, assignment) in assignments where assignment.wallpaperID == item.id {
            controllers[displayID]?.setFitMode(mode)
        }
    }

    /// Updates the in-memory duration for the current player without doing a
    /// second persistence write. Metadata enrichment also calls this for items
    /// that are already on screen.
    func updateDuration(for itemID: UUID, duration: Double?) {
        guard var item = queueItems[itemID] else { return }
        if item.metadata == nil {
            item.metadata = WallpaperMetadata(durationSeconds: duration)
        } else {
            item.metadata?.durationSeconds = duration
        }
        queueItems[itemID] = item
        let normalized = Self.validDuration(duration)
        for (displayID, session) in currentSessions where session.itemID == itemID {
            // A later unavailable duration must not clear a known valid one.
            if normalized == nil && sessionDurations[displayID] != nil { continue }
            // Repeated ready/enrichment values are not a heartbeat and must
            // not extend the watchdog. Only a changed valid duration corrects
            // the current session's stall timer.
            guard sessionDurations[displayID] != normalized else { continue }
            sessionDurations[displayID] = normalized
            guard let binding = bindings[displayID],
                  let queue = queueLibrary[binding.activeQueueID],
                  queue.usesCompletionAdvance(for: .video) else { continue }
            let stall = queue.stallWatchdogInterval(
                forVideoWithDurationSeconds: durationForCurrentSession(displayID: displayID, itemID: itemID)
            )
            if let timer = queueTimers[displayID], timer.isValid {
                timer.fireDate = Date().addingTimeInterval(stall)
            } else if remainingQueueIntervals[displayID] != nil {
                // Paused: update only the saved stall snapshot. Do not create
                // a timer or touch the hard deadline/generation.
                remainingQueueIntervals[displayID] = stall
            }
        }
    }

    /// Frame heartbeat from the streaming player: the pipeline is alive, so a
    /// video-completion queue's stall watchdog is re-armed without advancing.
    ///
    /// Called on the main actor. Extends the existing timer's `fireDate`
    /// instead of rebuilding a Timer per frame (30–60 rebuilds/sec/display
    /// would churn the run loop and invalidate/replace handles needlessly).
    private func noteVideoFrameProgress(for displayID: String, session: PlaybackSession) {
        guard currentSessions[displayID] == session else { return }
        guard let binding = bindings[displayID],
              let queue = queueLibrary[binding.activeQueueID],
              let state = binding.queueStates[queue.id],
              state.isEnabled,
              state.isPlaying,
              !isSystemSuspended,
              queue.advanceMode == .videoCompletion else { return }
        let itemID = queue.wallpaperIDs[safe: state.currentIndex]
        guard itemID == session.itemID else { return }
        let duration = itemID.flatMap { durationForCurrentSession(displayID: displayID, itemID: $0) }
        let stallWindow = queue.stallWatchdogInterval(forVideoWithDurationSeconds: duration)
        if let timer = queueTimers[displayID], timer.isValid {
            timer.fireDate = Date().addingTimeInterval(stallWindow)
        } else {
            // Recreate both watchdog and hard deadline when a resume/reload
            // invalidated them; a heartbeat alone must not lose the ceiling.
            reconcileScheduling(for: displayID)
        }
    }

    private func videoPlaybackDidFinish(for displayID: String, session: PlaybackSession) {
        guard currentSessions[displayID] == session else {
            // Stale callback from a replaced or torn-down controller.
            return
        }
        guard let binding = bindings[displayID],
              let queue = queueLibrary[binding.activeQueueID],
              let state = binding.queueStates[queue.id],
              state.isEnabled,
              state.isPlaying,
              !isSystemSuspended,
              queue.advanceMode == .videoCompletion,
              let itemID = queue.wallpaperIDs[safe: state.currentIndex],
              itemID == session.itemID,
              queueItems[itemID]?.type == .video else { return }
        queueTimers.removeValue(forKey: displayID)?.invalidate()
        advanceQueue(for: displayID)
    }

    private func scheduleQueueTimer(for displayID: String, interval: Double) {
        invalidateQueueTimers(for: displayID)
        let generation = queueTimerGenerations[displayID] ?? 0
        queueTimers[displayID] = Timer.scheduledTimer(withTimeInterval: max(1, interval), repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.advanceQueue(for: displayID, generation: generation)
            }
        }
    }

    private func invalidateQueueTimers(for displayID: String) {
        queueTimerGenerations[displayID] = (queueTimerGenerations[displayID] ?? 0) + 1
        queueTimers.removeValue(forKey: displayID)?.invalidate()
        hardDeadlineTimers.removeValue(forKey: displayID)?.invalidate()
        remainingQueueIntervals.removeValue(forKey: displayID)
        remainingHardDeadlines.removeValue(forKey: displayID)
    }

    private func freezeQueueTimers(for displayID: String) {
        // Preserve the first pause's deadlines. Repeated pause notifications
        // must not overwrite the remaining time or extend it again.
        if remainingQueueIntervals[displayID] == nil, let timer = queueTimers[displayID] {
            remainingQueueIntervals[displayID] = PlaybackDeadlineMath.remaining(fireDate: timer.fireDate, now: Date())
        }
        if remainingHardDeadlines[displayID] == nil, let timer = hardDeadlineTimers[displayID] {
            remainingHardDeadlines[displayID] = PlaybackDeadlineMath.remaining(fireDate: timer.fireDate, now: Date())
        }
        queueTimerGenerations[displayID] = (queueTimerGenerations[displayID] ?? 0) + 1
        queueTimers.removeValue(forKey: displayID)?.invalidate()
        hardDeadlineTimers.removeValue(forKey: displayID)?.invalidate()
    }

    private func shouldScheduleQueue(for displayID: String, state: DisplayQueueState) -> Bool {
        PlaybackSchedulingState(
            isQueueEnabled: state.isEnabled,
            isPlaybackWanted: state.isPlaying,
            isSystemSuspended: isSystemSuspended,
            isDisplayConnected: connectedDisplays[displayID] != nil
        ).shouldSchedule
    }

    private func reconcileScheduling(for displayID: String) {
        guard let binding = bindings[displayID],
              let queue = queueLibrary[binding.activeQueueID],
              let state = binding.queueStates[queue.id],
              queue.wallpaperIDs.indices.contains(state.currentIndex),
              let item = queueItems[queue.wallpaperIDs[state.currentIndex]],
              WallpaperVisibility.isEligible(item, showsHidden: showsHiddenWallpapers) else {
            invalidateQueueTimers(for: displayID)
            return
        }
        let resumeFromSnapshot = remainingQueueIntervals[displayID] != nil || remainingHardDeadlines[displayID] != nil
        scheduleQueueTimerIfNeeded(
            for: displayID,
            queue: queue,
            state: state,
            item: item,
            resumeFromSnapshot: resumeFromSnapshot
        )
    }

    private func advanceQueue(for displayID: String, generation: Int? = nil) {
        if let generation, generation != queueTimerGenerations[displayID] { return }
        guard let binding = bindings[displayID],
              let queue = queueLibrary[binding.activeQueueID],
              let display = connectedDisplays[displayID] else {
            // A missing display is not a user stop. Preserve queue intent and
            // do not let a stale deadline persistently disable reconnection.
            invalidateQueueTimers(for: displayID)
            currentSessions.removeValue(forKey: displayID)
            sessionDurations.removeValue(forKey: displayID)
            return
        }
        let state = binding.state(for: queue.id)
        guard shouldScheduleQueue(for: displayID, state: state) else {
            // A pause is not a stop: preserve the queue's enabled intent and
            // remaining deadlines, then let resume reconcile its timers.
            freezeQueueTimers(for: displayID)
            return
        }
        guard state.isEnabled else {
            stopQueue(displayID: displayID)
            return
        }
        guard let next = nextQueueIndex(queue: queue, state: state) else {
            let hasHiddenMembers = !showsHiddenWallpapers
                && queue.wallpaperIDs.contains { queueItems[$0]?.isHidden == true }
            if hasHiddenMembers {
                // Do not destroy the queue's enabled intent just because every
                // remaining member is hidden while the switch is locked.
                var pausedState = state
                pausedState.isPlaying = false
                var updatedBinding = binding
                updatedBinding.queueStates[queue.id] = pausedState
                bindings[displayID] = updatedBinding
                publishBindings()
                publishLegacyQueues()
                persistQueues()
                suspendPresentation(displayID: displayID)
            } else {
                stopQueue(displayID: displayID)
            }
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
            var advancePolicy = playbackPolicy
            advancePolicy.isPlaying = nextState.isPlaying
            try apply(
                item: item,
                to: display,
                policy: advancePolicy,
                transition: effectiveTransition(queue: queue, state: nextState),
                preserveQueue: true,
                advanceAfterVideoCompletion: shouldAdvanceAfterVideoCompletion(queue: queue, item: item)
            )
            scheduleQueueTimerIfNeeded(for: displayID, queue: queue, state: nextState, item: item)
        } catch {
            // Keep the queue moving even when the next item fails to apply.
            // Video-completion mode has no periodic tick unless we arm one.
            if queueTimers[displayID] == nil {
                scheduleQueueTimer(for: displayID, interval: 5)
            }
        }
    }

    private func nextQueueIndex(queue: PlaybackQueue, state: DisplayQueueState) -> Int? {
        let available = WallpaperVisibility.eligibleIndices(
            in: queue,
            items: queueItems,
            showsHidden: showsHiddenWallpapers
        )
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
        let available = WallpaperVisibility.eligibleIndices(
            in: queue,
            items: queueItems,
            showsHidden: showsHiddenWallpapers
        )
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
        // Wallpaper windows are desktop-level surfaces: order them above the
        // desktop without becoming key or activating the app, so automatic
        // queue transitions never steal focus from the user's frontmost app.
        // Interactive web wallpapers still receive clicks because their windows
        // accept first mouse and do not ignore mouse events.
        switch effect {
        case .cut:
            previous?.teardownAndClose()
            window?.alphaValue = 1
            window?.orderFrontRegardless()
        case .crossfade:
            window?.alphaValue = 0
            window?.orderFrontRegardless()
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
            window?.orderFrontRegardless()
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
            window?.orderFrontRegardless()
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
            let identity = DisplayIdentityProvider.identity(for: screen)
            let name = screen.localizedName.isEmpty ? "显示器 \(index + 1)" : screen.localizedName
            return DisplayService.Display(id: identity.profileID, name: name, screen: screen, identity: identity)
        }
    }

    private func displayID(for screen: NSScreen) -> String {
        DisplayIdentityProvider.identity(for: screen).profileID
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
        onVideoPlaybackCompleted: (() -> Void)? = nil,
        onFrameProgress: (() -> Void)? = nil,
        onVideoDurationChanged: ((Double?) -> Void)? = nil,
        initialSystemSuspended: Bool = false
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
            onFrameProgress: onFrameProgress,
            onVideoDurationChanged: onVideoDurationChanged,
            initialSystemSuspended: initialSystemSuspended,
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
        wallpaperContentView.setWebInteractionEnabled(enabled)
    }

    func setSystemSuspended(_ suspended: Bool, reloadWebContentOnResume: Bool) {
        wallpaperContentView.setSystemSuspended(
            suspended,
            reloadWebContentOnResume: reloadWebContentOnResume
        )
    }

    /// Geometry-only updates keep the existing controller, player and queue
    /// session alive instead of restarting playback at zero.
    func updateFrame(for screen: NSScreen) {
        window?.setFrame(screen.frame, display: true)
        wallpaperContentView.frame = NSRect(origin: .zero, size: screen.frame.size)
        wallpaperContentView.needsLayout = true
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

private final class WallpaperContentView: NSView, WKNavigationDelegate, WKUIDelegate {
    private let item: WallpaperItem
    /// The user's requested playback state. System suspension never changes this value.
    private var isPlaying: Bool
    private var isSystemSuspended = false
    private var webInteractionEnabled: Bool
    private let reloadWebContentOnResume: Bool
    private var navigationAuthorizer = ExternalNavigationAuthorizer()
    private var isMuted: Bool
    private var fitMode: WallpaperFitMode
    private let loops: Bool
    private let onVideoPlaybackCompleted: (() -> Void)?
    private let onFrameProgress: (() -> Void)?
    private let onVideoDurationChanged: ((Double?) -> Void)?
    private var imageLayer: CALayer?
    private var imageContentLayer: CALayer?
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var playerPresentationLayer: CALayer?
    private var playerTileSize: CGSize?
    private var lastPresentationBounds: CGSize?
    private var videoNaturalSize: CGSize?
    private var progressObserver: Any?
    private var progressTracker = VideoPlaybackProgressTracker()
    private var streamingController: WallpaperVideoStreamController?
    private var webView: WKWebView?
    private var webErrorLabel: NSTextField?
    private var webRecoveryState = WebContentRecoveryState()
    private var webRecoveryWorkItem: DispatchWorkItem?
    private var webLoadTimeoutWorkItem: DispatchWorkItem?
    private var webHealthyWorkItem: DispatchWorkItem?
    private var webRecoveryGeneration = 0
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
        onFrameProgress: (() -> Void)? = nil,
        onVideoDurationChanged: ((Double?) -> Void)? = nil,
        initialSystemSuspended: Bool = false,
        frame: NSRect
    ) throws {
        self.item = item
        self.isPlaying = policy.isPlaying
        self.webInteractionEnabled = policy.webWallpaperInteractionEnabled
        self.reloadWebContentOnResume = policy.reloadWebContentOnResume
        self.isMuted = policy.isMuted
        self.fitMode = item.effectiveFitMode(global: policy.fitMode)
        self.loops = loops
        self.onVideoPlaybackCompleted = onVideoPlaybackCompleted
        self.onFrameProgress = onFrameProgress
        self.onVideoDurationChanged = onVideoDurationChanged
        self.isSystemSuspended = initialSystemSuspended
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
        releasePlaybackResources()
        removeInterfaceViews()
    }

    /// Thread-safe teardown of the playback pipeline (observers, tasks,
    /// ffmpeg, AVPlayer). Does not touch AppKit layer/view hierarchy.
    private func releasePlaybackResources() {
        isPlaying = false
        navigationAuthorizer.cancel()
        webView?.evaluateJavaScript(WebMouseEventScript.clearMouseState(), completionHandler: nil)

        if let loopObserver {
            NotificationCenter.default.removeObserver(loopObserver)
            self.loopObserver = nil
        }
        compatibilityTask?.cancel()
        compatibilityTask = nil
        webRecoveryGeneration += 1
        webRecoveryWorkItem?.cancel()
        webLoadTimeoutWorkItem?.cancel()
        webHealthyWorkItem?.cancel()
        webRecoveryWorkItem = nil
        webLoadTimeoutWorkItem = nil
        webHealthyWorkItem = nil
        if let progressObserver {
            player?.removeTimeObserver(progressObserver)
            self.progressObserver = nil
        }
        streamingController?.teardown()
        streamingController = nil

        player?.pause()
        playerLayer?.player = nil
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    /// AppKit hierarchy removal — main thread only.
    private func removeInterfaceViews() {
        playerPresentationLayer?.removeFromSuperlayer()
        playerPresentationLayer = nil
        playerTileSize = nil
        videoNaturalSize = nil
        playerLayer?.removeFromSuperlayer()
        imageLayer?.removeFromSuperlayer()
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        layer?.contents = nil
        playerLayer = nil
        imageLayer = nil
        imageContentLayer = nil

        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        webErrorLabel?.removeFromSuperview()
        webErrorLabel = nil
    }

    deinit {
        // deinit can run on any queue. Only the non-AppKit cleanup is safe
        // here; explicit runtime shutdown paths call teardown() on the main
        // thread to remove layer/view subviews before the view is destroyed.
        guard !isTornDown else { return }
        isTornDown = true
        releasePlaybackResources()
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

    private var isWebMouseDragCancelled = false
    private var webMouseDownLocation: NSPoint?

    private func cancelWebMouseGesture() {
        isWebMouseDragCancelled = true
        webMouseDownLocation = nil
        navigationAuthorizer.cancel()
        webView?.evaluateJavaScript(WebMouseEventScript.clearMouseState(), completionHandler: nil)
    }

    private func dispatchWebMouseEvent(_ event: NSEvent, phase: WebMouseEventPhase) {
        guard let webView else { return }
        let disallowedModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        if !event.modifierFlags.intersection(disallowedModifiers).isEmpty {
            cancelWebMouseGesture()
            return
        }
        if phase == .mouseDown {
            isWebMouseDragCancelled = false
        }
        let localPoint = convert(event.locationInWindow, from: nil)
        if phase == .mouseDown {
            webMouseDownLocation = localPoint
        }
        let outside = localPoint.x < 0 || localPoint.x > bounds.width || localPoint.y < 0 || localPoint.y > bounds.height
        if outside || (phase == .mouseUp && isWebMouseDragCancelled) {
            cancelWebMouseGesture()
            isWebMouseDragCancelled = false
            return
        }
        let x = max(0, min(bounds.width, localPoint.x))
        let y = max(0, min(bounds.height, bounds.height - localPoint.y))
        if phase == .mouseUp {
            // First evaluate the real activation target without clicking. The
            // host authorizes only that exact target, then activates it once.
            let evaluate = WebMouseEventScript.evaluateMouseUp(x: x, y: y)
            let gestureTime = ProcessInfo.processInfo.systemUptime
            webView.evaluateJavaScript(evaluate) { [weak self, weak webView] result, _ in
                guard let self, let webView, !self.isTornDown, self.webView === webView,
                      let payload = result as? [String: Any],
                      let shouldActivate = payload["activate"] as? Bool else { return }
                guard shouldActivate,
                      self.webInteractionEnabled,
                      self.isPlaying,
                      !self.isSystemSuspended else {
                    self.navigationAuthorizer.cancel()
                    webView.evaluateJavaScript(WebMouseEventScript.clearMouseState(), completionHandler: nil)
                    return
                }
                let urlString = payload["url"] as? String ?? ""
                if !urlString.isEmpty {
                    guard let url = URL(string: urlString), WebWallpaperURL.isValid(url) else {
                        self.navigationAuthorizer.cancel()
                        webView.evaluateJavaScript(WebMouseEventScript.clearMouseState(), completionHandler: nil)
                        return
                    }
                    self.navigationAuthorizer.prepare(
                        url: url,
                        now: gestureTime,
                        interactionEnabled: self.webInteractionEnabled,
                        isPlaying: self.isPlaying,
                        isSystemSuspended: self.isSystemSuspended
                    )
                }
                webView.evaluateJavaScript(WebMouseEventScript.activateMouseUp(), completionHandler: nil)
            }
        } else {
            let script = WebMouseEventScript.source(x: x, y: y, phase: phase)
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard item.type == .web, let start = webMouseDownLocation else { return }
        let point = convert(event.locationInWindow, from: nil)
        let outside = point.x < 0 || point.x > bounds.width || point.y < 0 || point.y > bounds.height
        // AppKit can send a drag event for a sub-pixel movement. Preserve the
        // script's 6px tolerance; only a real drag or leaving the view cancels.
        if outside || hypot(point.x - start.x, point.y - start.y) > 6 {
            cancelWebMouseGesture()
        }
    }

    override func mouseExited(with event: NSEvent) {
        guard item.type == .web else { return }
        cancelWebMouseGesture()
    }

    override func layout() {
        super.layout()
        let sizeChanged = lastPresentationBounds != bounds.size
        lastPresentationBounds = bounds.size
        if sizeChanged, fitMode == .tile {
            // Replicator grids freeze their column/row counts. Rebuild only
            // the presentation layers when the viewport changes.
            if imageContentLayer != nil { rebuildImagePresentation() }
            if playerLayer != nil { rebuildPlayerPresentation() }
        }
        imageLayer?.frame = bounds
        playerPresentationLayer?.frame = bounds
        streamingController?.setFrame(bounds)
        webView?.frame = bounds
        webErrorLabel?.frame = NSRect(
            x: bounds.minX + 24,
            y: bounds.midY - 28,
            width: max(0, bounds.width - 48),
            height: 56
        )
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
        rebuildImagePresentation()
        rebuildPlayerPresentation()
        streamingController?.setFitMode(fitMode)
    }

    func setWebInteractionEnabled(_ enabled: Bool) {
        webInteractionEnabled = enabled
        if !enabled {
            navigationAuthorizer.cancel()
            webView?.evaluateJavaScript(WebMouseEventScript.clearMouseState(), completionHandler: nil)
        }
    }

    func setSystemSuspended(_ suspended: Bool, reloadWebContentOnResume: Bool) {
        guard !isTornDown else { return }
        isSystemSuspended = suspended
        applyPlaybackState()
    }

    private func applyPlaybackState() {
        let shouldPlay = isPlaying && !isSystemSuspended
        if !shouldPlay {
            progressTracker.resetClock()
            navigationAuthorizer.cancel()
        }
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
            if !shouldPlay {
                webRecoveryGeneration += 1
                webRecoveryWorkItem?.cancel()
                webRecoveryWorkItem = nil
                webLoadTimeoutWorkItem?.cancel()
                webLoadTimeoutWorkItem = nil
                webHealthyWorkItem?.cancel()
                webHealthyWorkItem = nil
            }
            if !shouldPlay && reloadWebContentOnResume {
                // When reload-on-resume is allowed, fully release the renderer
                // so timers, CSS animation and network work stop as well.
                destroyWebContent()
                return
            }
            if shouldPlay && webView == nil && reloadWebContentOnResume {
                configureWebPlayback()
            }
            // Public WebKit API: unlike a one-time DOM pause(), this also
            // blocks later play() calls and newly inserted media.
            webView?.setAllMediaPlaybackSuspended(!shouldPlay, completionHandler: nil)
            evaluateMediaScript(shouldPlay ? "play" : "pause")
            if shouldPlay, webErrorLabel?.isHidden == false {
                scheduleWebRecovery()
            }
        }
    }

    private func destroyWebContent() {
        navigationAuthorizer.cancel()
        webRecoveryGeneration += 1
        webRecoveryWorkItem?.cancel()
        webRecoveryWorkItem = nil
        webLoadTimeoutWorkItem?.cancel()
        webLoadTimeoutWorkItem = nil
        webHealthyWorkItem?.cancel()
        webHealthyWorkItem = nil
        webView?.evaluateJavaScript(WebMouseEventScript.clearMouseState(), completionHandler: nil)
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        webErrorLabel?.removeFromSuperview()
        webErrorLabel = nil
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
            imageLayer.contents = cgImage
            imageLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            imageLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            imageContentLayer = imageLayer
            rebuildImagePresentation()
        case .video:
            configureVideoPlayback(at: item.playbackURL ?? item.sourceURL)
        case .web:
            configureWebPlayback()
        }
    }

    private var displayContentScale: CGFloat {
        window?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    }

    private func rebuildImagePresentation() {
        guard let content = imageContentLayer else { return }
        imageLayer?.removeFromSuperlayer()
        let originalSize: CGSize
        if let contents = content.contents {
            // The image branch always stores a CGImage in contents.
            let image = contents as! CGImage
            originalSize = CGSize(width: image.width, height: image.height)
        } else {
            originalSize = bounds.size
        }
        imageLayer = WallpaperLayerLayout.make(
            content: content,
            originalSize: originalSize,
            bounds: bounds,
            mode: fitMode,
            contentScale: displayContentScale
        )
        if let imageLayer {
            layer?.addSublayer(imageLayer)
        }
    }

    private func rebuildPlayerPresentation() {
        guard let content = playerLayer else { return }
        playerPresentationLayer?.removeFromSuperlayer()
        let originalSize = currentMediaSize
        playerTileSize = originalSize
        playerPresentationLayer = WallpaperLayerLayout.make(
            content: content,
            originalSize: originalSize,
            bounds: bounds,
            mode: fitMode,
            contentScale: displayContentScale
        )
        if let playerPresentationLayer {
            layer?.addSublayer(playerPresentationLayer)
        }
    }

    private var knownMediaSize: CGSize? {
        if let videoNaturalSize, videoNaturalSize.width > 0, videoNaturalSize.height > 0 {
            return videoNaturalSize
        }
        if let width = item.metadata?.pixelWidth,
           let height = item.metadata?.pixelHeight,
           width > 0, height > 0 {
            return CGSize(width: width, height: height)
        }
        if let size = player?.currentItem?.presentationSize,
           size.width > 0, size.height > 0 {
            return CGSize(width: size.width, height: size.height)
        }
        return nil
    }

    private var currentMediaSize: CGSize {
        knownMediaSize ?? bounds.size
    }

    private func configureWebPlayback() {
        guard webView == nil else { return }
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: bounds, configuration: configuration)
        webView.autoresizingMask = [.width, .height]
        webView.allowsBackForwardNavigationGestures = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        let entryURL = item.entryURL ?? item.sourceURL
        if entryURL.isFileURL {
            // A single file is authorized only for itself. A directory
            // project is authorized for the directory explicitly imported.
            let readRoot = item.sourceURL
            webView.loadFileURL(entryURL, allowingReadAccessTo: readRoot)
        } else if WebWallpaperURL.isValid(entryURL) {
            webView.load(URLRequest(url: entryURL))
        } else {
            return
        }
        addSubview(webView)
        self.webView = webView
        let errorLabel = NSTextField(wrappingLabelWithString: "网页加载失败，请检查网络后重新加载。")
        errorLabel.alignment = .center
        errorLabel.textColor = .white
        errorLabel.backgroundColor = NSColor.black.withAlphaComponent(0.72)
        errorLabel.drawsBackground = true
        errorLabel.isBezeled = false
        errorLabel.isHidden = true
        addSubview(errorLabel)
        self.webErrorLabel = errorLabel
        applyPlaybackState()
        startWebLoadWatchdog()
    }

    private func configureVideoPlayback(at sourceURL: URL) {
        compatibilityTask = Task { [weak self] in
            guard let self else { return }
            do {
                let asset = AVURLAsset(url: sourceURL)
                let isPlayable = try await asset.load(.isPlayable)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                var displaySize: CGSize?
                if let track = tracks.first {
                    let naturalSize = try await track.load(.naturalSize)
                    let transform = try await track.load(.preferredTransform)
                    let displayRect = CGRect(origin: .zero, size: naturalSize).applying(transform).standardized
                    displaySize = CGSize(width: abs(displayRect.width), height: abs(displayRect.height))
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.videoNaturalSize = displaySize
                    if self.fitMode == .tile {
                        self.rebuildPlayerPresentation()
                    }
                }
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
                // Surface the failure as playback completion so video-completion
                // queues can advance instead of waiting forever for an item that
                // never installed a player.
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    self?.onVideoPlaybackCompleted?()
                }
            }
        }
    }

    private func installStreamingVideoPlayer(at sourceURL: URL) {
        guard !isTornDown, streamingController == nil else { return }
        let controller = WallpaperVideoStreamController(
            sourceURL: sourceURL,
            isPlaying: isPlaying && !isSystemSuspended,
            loops: loops,
            frame: bounds,
            onVideoPlaybackCompleted: onVideoPlaybackCompleted,
            onFrameProgress: onFrameProgress,
            fitMode: fitMode,
            // Never use the viewport as ffmpeg's source aspect ratio: padding
            // would become permanent black bars inside every decoded frame.
            originalSize: knownMediaSize,
            contentScale: displayContentScale
        )
        streamingController = controller
        layer?.addSublayer(controller.presentationLayer)
        controller.start()
    }

    private func installVideoPlayer(at playbackURL: URL) {
        guard !isTornDown, player == nil else { return }
        let player = AVPlayer(url: playbackURL)
        player.automaticallyWaitsToMinimizeStalling = true
        player.currentItem?.preferredForwardBufferDuration = VideoPlaybackCompatibility.preferredForwardBufferSeconds
        let playerLayer = AVPlayerLayer(player: player)
        // The player is installed after asynchronous codec inspection, so the
        // view may already have completed its initial layout pass.
        playerLayer.frame = bounds
        // Install the shared player layer, then choose its presentation without
        // creating a second player for tiled mode.
        self.player = player
        self.playerLayer = playerLayer
        rebuildPlayerPresentation()
        needsLayout = true
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self, weak player] _ in
            guard let self, !self.isTornDown else { return }
            if self.loops {
                // Resume only after the seek lands; play() during an in-flight
                // seek can leave the player waiting forever on some files.
                player?.seek(to: .zero) { finished in
                    guard finished, let player else { return }
                    self.progressTracker.resetClock()
                    if self.isPlaying && !self.isSystemSuspended { player.play() }
                }
            } else {
                self.onVideoPlaybackCompleted?()
            }
        }
        player.isMuted = isMuted
        progressObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 2),
            queue: .main
        ) { [weak self, weak player] time in
            guard let self, !self.isTornDown else { return }
            guard self.isPlaying && !self.isSystemSuspended,
                  player?.timeControlStatus == .playing,
                  player?.currentItem?.status == .readyToPlay else {
                // Paused, buffering and waiting time is not playback progress.
                self.progressTracker.resetClock()
                return
            }
            let duration = player?.currentItem?.duration.seconds
            if self.fitMode == .tile, let size = player?.currentItem?.presentationSize,
               size.width > 0, size.height > 0 {
                let desired = self.currentMediaSize
                if desired != self.playerTileSize {
                    self.rebuildPlayerPresentation()
                }
            }
            let progress = self.progressTracker.sample(
                currentTime: time.seconds,
                duration: duration
            )
            if progress.durationChanged {
                self.onVideoDurationChanged?(progress.durationSeconds)
            }
            if progress.advanced {
                self.onFrameProgress?()
            }
        }
        if isPlaying && !isSystemSuspended { player.play() }
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

    private func setWebError(_ message: String?) {
        webErrorLabel?.stringValue = message ?? ""
        webErrorLabel?.isHidden = message == nil
    }

    private func startWebLoadWatchdog() {
        webLoadTimeoutWorkItem?.cancel()
        guard let webView else { return }
        let work = DispatchWorkItem { [weak self, weak webView] in
            guard let self, let webView, !self.isTornDown, self.webView === webView else { return }
            self.setWebError("网页加载超时，正在尝试恢复…")
            self.scheduleWebRecovery()
        }
        webLoadTimeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    private func scheduleWebRecovery() {
        webHealthyWorkItem?.cancel()
        webHealthyWorkItem = nil
        webLoadTimeoutWorkItem?.cancel()
        guard webRecoveryWorkItem == nil, webView != nil else { return }
        guard let delay = webRecoveryState.nextDelay(
            isPlaying: isPlaying,
            isSystemSuspended: isSystemSuspended
        ) else {
            if webRecoveryState.isExhausted {
                setWebError("网页加载失败，请手动重新加载。")
            }
            return
        }
        webRecoveryGeneration += 1
        let generation = webRecoveryGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  !self.isTornDown,
                  self.webRecoveryGeneration == generation,
                  self.isPlaying,
                  !self.isSystemSuspended else { return }
            self.webRecoveryWorkItem = nil
            self.webView?.reload()
            self.startWebLoadWatchdog()
        }
        webRecoveryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func markWebHealthy() {
        webRecoveryGeneration += 1
        setWebError(nil)
        webLoadTimeoutWorkItem?.cancel()
        webRecoveryWorkItem?.cancel()
        webRecoveryWorkItem = nil
        webHealthyWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.webRecoveryState.markHealthy()
        }
        webHealthyWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationAuthorizer.cancel()
        webView.evaluateJavaScript(WebMouseEventScript.clearMouseState(), completionHandler: nil)
        markWebHealthy()
        setMuted(isMuted)
        // Always re-apply the current state, including a pause that happened
        // before or during navigation.
        applyPlaybackState()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if item.sourceURL.isFileURL {
            decisionHandler(.allow)
            return
        }
        guard let url = navigationAction.request.url,
              WebWallpaperURL.isValid(url) else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url,
              WebWallpaperURL.isValid(url),
              navigationAuthorizer.consume(
                url: url,
                now: ProcessInfo.processInfo.systemUptime,
                interactionEnabled: webInteractionEnabled,
                isPlaying: isPlaying,
                isSystemSuspended: isSystemSuspended
              ) else {
            return nil
        }
        openExternalURL(url)
        return nil
    }

    private func openExternalURL(_ url: URL) {
        // Runtime tests can record the opener without launching a browser.
        // Normal production always uses NSWorkspace.
        guard let logPath = ProcessInfo.processInfo.environment["WALLPAPERMAC_EXTERNAL_OPEN_LOG"] else {
            NSWorkspace.shared.open(url)
            return
        }
        let line = url.absoluteString + "\n"
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: URL(fileURLWithPath: logPath))
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !isTornDown else { return }
        setWebError("网页渲染进程已终止，正在尝试恢复…")
        scheduleWebRecovery()
    }

    private func webNavigationDidFail(_ error: Error) {
        guard !isTornDown, (error as NSError).code != NSURLErrorCancelled else { return }
        setWebError("网页加载失败，正在尝试恢复…")
        NSLog("WallpaperMac web wallpaper failed to load: \(error.localizedDescription)")
        scheduleWebRecovery()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        webNavigationDidFail(error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        self.webView(webView, didFail: navigation, withError: error)
    }


}

private enum WallpaperContentError: Error, LocalizedError {
    case cannotLoadResource(URL)

    var errorDescription: String? {
        switch self {
        case .cannotLoadResource(let url):
            return "无法加载壁纸资源：\(url.isFileURL ? url.path : url.absoluteString)"
        }
    }
}
