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
    /// Coalesces queue/assignment/profile JSON writes off the main actor.
    private lazy var queueWriter = DeferredDiskWriter(onError: { [weak self] error in
        Task { @MainActor [weak self] in
            self?.queueSaveError = "保存播放队列失败：\(error.localizedDescription)"
        }
    })
    private let assignmentWriter = DeferredDiskWriter()
    private var playbackPolicy = PlaybackPolicy()
    private var showsHiddenWallpapers = false
    private var didMigrateQueueSlots = false
    private var activityState = PlaybackActivityState()
    private var systemSuspendedDisplayIDs: Set<String> = []
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
        activityMonitor = SystemActivityMonitor { [weak self] state in
            Task { @MainActor [weak self] in
                self?.applySystemActivity(state)
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
        didMigrateQueueSlots = false
        systemSuspendedDisplayIDs.removeAll()
        self.store = store
        self.playbackPolicy = policy
        loadQueues()
        loadAssignments()
    }

    func update(policy: PlaybackPolicy) {
        playbackPolicy = policy
        for (displayID, controller) in controllers {
            let item = assignments[displayID]?.wallpaperID.flatMap { queueItems[$0] }
            controller.setMuted(policy.isMuted)
            controller.setFitMode(item?.effectiveFitMode(global: policy.fitMode) ?? policy.fitMode)
            controller.setWebInteractionEnabled(policy.webWallpaperInteractionEnabled)
            playbackStates[displayID] = controller.playbackState
        }
        refreshSystemSuspension()
    }

    private func isSystemSuspended(for displayID: String) -> Bool {
        playbackPolicy.shouldPauseDynamicWallpaper(
            displayID: displayID,
            activity: activityState
        )
    }

    private var currentQueueKind: PlaybackQueueKind {
        showsHiddenWallpapers ? .hidden : .normal
    }

    func queueKind(for queue: PlaybackQueue) -> PlaybackQueueKind {
        queue.kind(items: queueItems)
    }

    /// Resolves the queue slot used by the current hidden-wallpaper mode.
    /// Empty or type-mismatched slots intentionally resolve to nil so the
    /// display stays empty instead of falling back to another queue.
    func effectiveQueueID(for displayID: String) -> UUID? {
        guard let binding = bindings[displayID] else { return nil }
        return QueueSlotResolver.resolve(
            queueID: binding.queueID(for: currentQueueKind),
            expected: currentQueueKind,
            queues: queueLibrary,
            items: queueItems
        )
    }

    func effectiveQueue(for displayID: String) -> PlaybackQueue? {
        effectiveQueueID(for: displayID).flatMap { queueLibrary[$0] }
    }

    func queueSlotID(for displayID: String, kind: PlaybackQueueKind) -> UUID? {
        bindings[displayID]?.queueID(for: kind)
    }

    /// Assigns a queue to one of a display's mode slots. A queue may only be
    /// placed in the slot matching its current content-derived kind.
    @discardableResult
    func setQueueSlot(
        _ kind: PlaybackQueueKind,
        queueID: UUID?,
        for displayID: String,
        policy: PlaybackPolicy,
        items: [WallpaperItem]
    ) -> Bool {
        guard !persistenceGate.blocksPersistence else { return false }
        queueItems = UniquedDictionary.build(items.map { ($0.id, $0) }, label: "queue items")
        playbackPolicy = policy
        if let queueID {
            guard let queue = queueLibrary[queueID], queue.kind(items: queueItems) == kind else {
                return false
            }
        } else if kind == .normal {
            return false
        }
        guard var binding = bindings[displayID] else { return false }
        binding.setQueueID(queueID, for: kind)
        bindings[displayID] = binding
        publishBindings()
        publishLegacyQueues()
        persistQueues()
        if kind == currentQueueKind, connectedDisplays[displayID] != nil {
            activateQueueSlot(for: displayID)
        }
        return true
    }

    /// Switches one display to the slot for the current hidden-wallpaper mode.
    /// The previous queue's state is retained untouched, so switching back
    /// resumes its previous index/intent.
    private func activateQueueSlot(for displayID: String) {
        guard let display = connectedDisplays[displayID],
              let binding = bindings[displayID] else { return }

        invalidateQueueTimers(for: displayID)
        currentSessions.removeValue(forKey: displayID)
        sessionDurations.removeValue(forKey: displayID)
        controllers.removeValue(forKey: displayID)?.teardownAndClose()
        appliedWallpaperIDs.removeValue(forKey: displayID)
        playbackStates.removeValue(forKey: displayID)
        assignments[displayID]?.applicationState = .idle

        var updated = binding
        if let queueID = effectiveQueueID(for: displayID),
           let queue = queueLibrary[queueID],
           !queue.wallpaperIDs.isEmpty {
            updated.activeQueueID = queueID
            bindings[displayID] = updated
            publishBindings()
            publishLegacyQueues()
            persistQueues()
            startQueue(
                queueID: queueID,
                on: display,
                policy: playbackPolicy,
                items: Array(queueItems.values),
                resetIndex: false
            )
        } else {
            updated.activeQueueID = updated.defaultQueueID
            bindings[displayID] = updated
            publishBindings()
            publishLegacyQueues()
            persistQueues()
            publishDisplayAssignments()
        }
    }

    private func applySystemActivity(_ state: PlaybackActivityState) {
        activityState = state
        refreshSystemSuspension()
    }

    /// Applies battery/fullscreen suspension only to the displays whose state
    /// actually changed. Battery policies affect every display; a fullscreen
    /// app only suspends the display containing its window.
    private func refreshSystemSuspension() {
        let candidates = Set(connectedDisplays.keys)
            .union(controllers.keys)
            .union(bindings.keys)
        let next = Set(candidates.filter { isSystemSuspended(for: $0) })
        let changed = next.symmetricDifference(systemSuspendedDisplayIDs)
        systemSuspendedDisplayIDs = next
        for displayID in changed {
            let suspended = next.contains(displayID)
            if let controller = controllers[displayID] {
                controller.setSystemSuspended(
                    suspended,
                    reloadWebContentOnResume: !suspended && playbackPolicy.reloadWebContentOnResume
                )
                playbackStates[displayID] = controller.playbackState
            }
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
        let suspended = isSystemSuspended(for: display.id)
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
            initialSystemSuspended: suspended
        )
        replacement.setSystemSuspended(suspended, reloadWebContentOnResume: false)
        if suspended {
            systemSuspendedDisplayIDs.insert(display.id)
        } else {
            systemSuspendedDisplayIDs.remove(display.id)
        }
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
        systemSuspendedDisplayIDs.remove(displayID)
        persistAssignments()
    }

    /// Refreshes the manager's item cache after a field-level hidden update.
    func updateHiddenState(for items: [WallpaperItem]) {
        for item in items {
            queueItems[item.id] = item
        }
    }

    /// Applies the hidden-wallpaper switch by activating each display's
    /// default or hidden queue slot. Empty/mismatched slots leave the display
    /// empty; fixed assignments outside a queue are restored only when
    /// eligible.
    func setShowsHiddenWallpapers(
        _ shows: Bool,
        policy: PlaybackPolicy,
        items: [WallpaperItem]
    ) {
        playbackPolicy = policy
        let modeChanged = shows != showsHiddenWallpapers
        showsHiddenWallpapers = shows
        queueItems = UniquedDictionary.build(items.map { ($0.id, $0) }, label: "queue items")
        // Only a real mode change may rebuild every display. Callers such as
        // persistHidden re-invoke this with the current mode (false -> false)
        // just to refresh queue items; tearing down then would blank and
        // restart every screen even though the active slot did not change.
        guard modeChanged else {
            for display in connectedDisplays.values where effectiveQueueID(for: display.id) == nil {
                restoreFixedAssignmentIfNeeded(displayID: display.id)
            }
            return
        }
        for display in connectedDisplays.values {
            activateQueueSlot(for: display.id)
        }
        for display in connectedDisplays.values where effectiveQueueID(for: display.id) == nil {
            restoreFixedAssignmentIfNeeded(displayID: display.id)
        }
    }

    private func restoreFixedAssignmentIfNeeded(displayID: String) {
        guard effectiveQueueID(for: displayID) == nil,
              let display = connectedDisplays[displayID],
              let itemID = assignments[displayID]?.wallpaperID,
              !assignmentIsManagedByQueue(displayID: displayID, itemID: itemID),
              let item = queueItems[itemID],
              WallpaperVisibility.isEligible(item, showsHidden: showsHiddenWallpapers) else {
            return
        }
        try? apply(item: item, to: display, policy: playbackPolicy, preserveQueue: true)
    }

    /// A fixed assignment must not be mistaken for queue playback when the
    /// current mode slot is intentionally empty.
    private func assignmentIsManagedByQueue(displayID: String, itemID: UUID) -> Bool {
        guard let binding = bindings[displayID] else { return false }
        let queueIDs = [binding.defaultQueueID, binding.hiddenQueueID].compactMap { $0 }
        return queueIDs.contains { queueLibrary[$0]?.wallpaperIDs.contains(itemID) == true }
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
        systemSuspendedDisplayIDs.removeAll()
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
        migrateLegacyQueueSlotsIfNeeded()
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
                systemSuspendedDisplayIDs.remove(key)
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
            guard bindings[display.id] != nil else { continue }
            let queue = effectiveQueue(for: display.id)
            let state = queue.flatMap { bindings[display.id]?.state(for: $0.id) }
            let hasEnabledQueue = state?.isEnabled == true && queue?.wallpaperIDs.isEmpty == false
            let expectedItemID: UUID?
            if hasEnabledQueue, let queue, let state {
                expectedItemID = queue.wallpaperIDs[safe: state.currentIndex]
            } else if let assignedItemID = assignments[display.id]?.wallpaperID,
                      !assignmentIsManagedByQueue(displayID: display.id, itemID: assignedItemID) {
                expectedItemID = assignedItemID
            } else {
                // An empty current-mode slot stays empty. Do not resurrect the
                // previous queue item through a stale display assignment.
                expectedItemID = nil
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

    /// One-time migration from the single-active-queue format. A legacy queue
    /// that contains hidden wallpapers becomes the hidden slot; the normal slot
    /// falls back to the built-in default queue.
    private func migrateLegacyQueueSlotsIfNeeded() {
        guard !didMigrateQueueSlots else { return }
        didMigrateQueueSlots = true
        var changed = false
        for displayID in Array(bindings.keys) {
            guard var binding = bindings[displayID] else { continue }
            let activeQueue = queueLibrary[binding.activeQueueID]
            if binding.hiddenQueueID == nil,
               let activeQueue,
               queueKind(for: activeQueue) == .hidden {
                binding.hiddenQueueID = activeQueue.id
                changed = true
            }
            if queueLibrary[binding.defaultQueueID] == nil
                || queueLibrary[binding.defaultQueueID].map({ queueKind(for: $0) == .hidden }) == true {
                binding.defaultQueueID = defaultQueueID
                changed = true
            }
            let target = currentQueueKind == .hidden
                ? binding.hiddenQueueID
                : binding.defaultQueueID
            if let target, binding.activeQueueID != target {
                binding.activeQueueID = target
                changed = true
            }
            bindings[displayID] = binding
        }
        if changed {
            publishBindings()
            publishLegacyQueues()
            persistQueues()
        }
    }

    /// Removes newly hidden items from queues that were still normal. Queues
    /// that already contained hidden wallpapers are already hidden queues and
    /// keep their membership.
    func removeHiddenItemsFromDefaultQueues(_ itemIDs: Set<UUID>) {
        guard !itemIDs.isEmpty, !persistenceGate.blocksPersistence else { return }
        var changedQueues = Set<UUID>()
        for (queueID, value) in queueLibrary {
            guard value.wallpaperIDs.contains(where: itemIDs.contains) else { continue }
            let otherHidden = value.wallpaperIDs.contains { id in
                !itemIDs.contains(id) && queueItems[id]?.isHidden == true
            }
            guard !otherHidden else { continue }
            var queue = value
            queue.removeWallpaperIDs(itemIDs)
            queueLibrary[queueID] = queue
            changedQueues.insert(queueID)
            for displayID in bindings.keys {
                guard var binding = bindings[displayID],
                      var state = binding.queueStates[queueID] else { continue }
                state.normalize(for: queue)
                binding.queueStates[queueID] = state
                bindings[displayID] = binding
            }
        }
        guard !changedQueues.isEmpty else { return }
        publishQueueLibrary()
        persistQueues()
        for displayID in bindings.keys {
            guard let queueID = effectiveQueueID(for: displayID),
                  changedQueues.contains(queueID),
                  connectedDisplays[displayID] != nil else { continue }
            activateQueueSlot(for: displayID)
        }
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
        guard let queue = effectiveQueue(for: displayID),
              bindings[displayID]?.state(for: queue.id).isEnabled == true else { return nil }
        return queue
    }

    func boundQueue(for displayID: String) -> PlaybackQueue? {
        effectiveQueue(for: displayID)
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
        // Snapshot which displays were actively playing this queue BEFORE
        // removing it. effectiveQueueID resolves through QueueSlotResolver,
        // which returns nil once the queue is gone — computing it after the
        // removal would always be false and skip the slot re-activation that
        // tears down the stale controller and restarts the fallback queue.
        let wasActiveIDs = Set(bindings.keys.filter { effectiveQueueID(for: $0) == id })
        queueLibrary.removeValue(forKey: id)
        for displayID in Array(bindings.keys) {
            guard var binding = bindings[displayID] else { continue }
            let wasActive = wasActiveIDs.contains(displayID)
            guard binding.defaultQueueID == id
                || binding.hiddenQueueID == id
                || binding.activeQueueID == id else { continue }
            binding.queueStates.removeValue(forKey: id)
            if binding.defaultQueueID == id {
                binding.defaultQueueID = fallbackID
            }
            if binding.hiddenQueueID == id {
                binding.hiddenQueueID = nil
            }
            if binding.activeQueueID == id {
                binding.activeQueueID = currentQueueKind == .hidden
                    ? (binding.hiddenQueueID ?? fallbackID)
                    : binding.defaultQueueID
            }
            bindings[displayID] = binding
            if wasActive, connectedDisplays[displayID] != nil {
                activateQueueSlot(for: displayID)
            }
        }
        publishQueueLibrary()
        persistQueues()
        return true
    }

    func addWallpaperIDs(_ itemIDs: [UUID], to queueID: UUID, items: [WallpaperItem]) {
        guard !persistenceGate.blocksPersistence else { return }
        guard var queue = queueLibrary[queueID] else { return }
        let byID = UniquedDictionary.build(items.map { ($0.id, $0) }, label: "queue items")
        let allowedIDs: [UUID]
        if showsHiddenWallpapers {
            allowedIDs = itemIDs
        } else {
            // While locked, hidden wallpapers cannot be added to any queue.
            allowedIDs = itemIDs.filter { byID[$0]?.isHidden != true }
        }
        guard !allowedIDs.isEmpty else { return }
        let orderedIDs: [UUID]
        switch queue.sortMode {
        case .custom:
            orderedIDs = allowedIDs
        case .name:
            orderedIDs = allowedIDs.sorted { lhs, rhs in
                (items.first(where: { $0.id == lhs })?.name ?? "").localizedStandardCompare(items.first(where: { $0.id == rhs })?.name ?? "") == .orderedAscending
            }
        case .type:
            orderedIDs = allowedIDs.sorted { lhs, rhs in
                let left = items.first(where: { $0.id == lhs })
                let right = items.first(where: { $0.id == rhs })
                if left?.type != right?.type { return String(describing: left?.type) < String(describing: right?.type) }
                return (left?.name ?? "").localizedStandardCompare(right?.name ?? "") == .orderedAscending
            }
        case .addedAt:
            orderedIDs = allowedIDs.sorted { lhs, rhs in
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
        guard let queue = queueLibrary[queueID] else { return }
        let byID = UniquedDictionary.build(items.map { ($0.id, $0) }, label: "queue items")
        _ = setQueueSlot(
            queue.kind(items: byID),
            queueID: queueID,
            for: display.id,
            policy: policy,
            items: items
        )
    }

    func saveQueue(_ queue: DisplayPlaybackQueue) {
        guard !persistenceGate.blocksPersistence else { return }
        let queueID = effectiveQueueID(for: queue.displayID) ?? defaultQueueID
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
        let kind = queueKind(for: namedQueue)
        binding.setQueueID(queueID, for: kind)
        if kind == currentQueueKind {
            binding.activeQueueID = queueID
        }
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
        guard let queueID = effectiveQueueID(for: display.id) ?? bindings[display.id]?.defaultQueueID else { return }
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
        guard var binding = bindings[displayID],
              let queueID = effectiveQueueID(for: displayID) else { return }
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
            guard var binding = bindings[displayID],
                  let queueID = effectiveQueueID(for: displayID) else { continue }
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
        guard var binding = bindings[displayID],
              let queueID = effectiveQueueID(for: displayID) else { return }
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
        let activeQueue = effectiveQueue(for: displayID)
        let advanceAfterVideoCompletion = activeQueue?.usesCompletionAdvance(for: wallpaper.type) == true
        do {
            // New session invalidates completion callbacks from the replaced
            // controller; timers are rescheduled for the new playback below.
            let session = PlaybackSession(itemID: wallpaper.id, displayID: displayID)
            currentSessions[displayID] = session
            sessionDurations[displayID] = Self.validDuration(wallpaper.metadata?.durationSeconds)
            let suspended = isSystemSuspended(for: displayID)
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
                initialSystemSuspended: suspended
            )
            replacement.setSystemSuspended(suspended, reloadWebContentOnResume: false)
            if suspended {
                systemSuspendedDisplayIDs.insert(displayID)
            } else {
                systemSuspendedDisplayIDs.remove(displayID)
            }
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
                defaultQueueID: binding.defaultQueueID,
                hiddenQueueID: binding.hiddenQueueID,
                queueStates: binding.queueStates
            )
        }
        bindings = UniquedDictionary.build(profileBindings.map { ($0.displayID, $0) }, label: "display bindings")
        for displayID in bindings.keys {
            guard var binding = bindings[displayID], queueLibrary[binding.activeQueueID] == nil else { continue }
            binding.activeQueueID = defaultQueueID
            binding.defaultQueueID = defaultQueueID
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

    private func displayProfilesDocumentSnapshot() -> DisplayProfileDocument {
        DisplayProfileDocument(
            profiles: displayProfiles.values.sorted { $0.profileID < $1.profileID },
            unmatchedLegacyAssignments: unmatchedLegacyAssignments,
            unmatchedLegacyBindings: unmatchedLegacyBindings
        )
    }

    private func saveProfiles(store: WallpaperStore) {
        let document = displayProfilesDocumentSnapshot()
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
                    defaultQueueID: binding.defaultQueueID,
                    hiddenQueueID: binding.hiddenQueueID,
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
        let assignmentsSnapshot = legacyAssignmentSnapshot()
        let profiles = displayProfilesDocumentSnapshot()
        Task {
            await assignmentWriter.schedule {
                try store.save(displayProfilesDocument: profiles)
                try store.save(displayAssignments: assignmentsSnapshot)
            }
        }
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
                guard let binding = bindings[displayID], effectiveQueueID(for: displayID) == queueID else { continue }
                let state = binding.state(for: queueID)
                if queue.wallpaperIDs.indices.contains(state.currentIndex) {
                    currentItems[displayID] = queue.wallpaperIDs[state.currentIndex]
                }
            }

            queue.removeWallpaperIDs(itemIDs)
            queueLibrary[queueID] = queue
            for displayID in bindings.keys {
                guard var binding = bindings[displayID], effectiveQueueID(for: displayID) == queueID else { continue }
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
            guard let queue = effectiveQueue(for: binding.displayID) else { return nil }
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
        // Snapshot on the main actor; the actual JSON encode + atomic write
        // happens off the main actor so queue advancement never blocks UI.
        let queues = playbackQueues
        let bindingsSnapshot = legacyBindingSnapshot()
        let profiles = displayProfilesDocumentSnapshot()
        Task {
            await queueWriter.schedule {
                try store.save(displayProfilesDocument: profiles)
                try store.save(
                    playbackQueues: queues,
                    displayPlaybackBindings: bindingsSnapshot
                )
            }
        }
    }

    /// Durable flush for callers that must guarantee the write reached disk
    /// before proceeding (e.g. process termination).
    func flushPersistence() async {
        await queueWriter.flush()
        await assignmentWriter.flush()
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
                  binding.invalidateBoundQueue(ifMatching: queueID) else { continue }
            invalidateQueueTimers(for: displayID)
            bindings[displayID] = binding
            if effectiveQueueID(for: displayID) == nil, connectedDisplays[displayID] != nil {
                // The bound queue no longer matches its slot's type. Leave the
                // display empty until the user assigns a valid queue.
                activateQueueSlot(for: displayID)
            }
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
            guard let queue = effectiveQueue(for: displayID),
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
              let queue = effectiveQueue(for: displayID),
              let state = binding.queueStates[queue.id],
              state.isEnabled,
              state.isPlaying,
              !isSystemSuspended(for: displayID),
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
              let queue = effectiveQueue(for: displayID),
              let state = binding.queueStates[queue.id],
              state.isEnabled,
              state.isPlaying,
              !isSystemSuspended(for: displayID),
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
            isSystemSuspended: isSystemSuspended(for: displayID),
            isDisplayConnected: connectedDisplays[displayID] != nil
        ).shouldSchedule
    }

    private func reconcileScheduling(for displayID: String) {
        guard let binding = bindings[displayID],
              let queue = effectiveQueue(for: displayID),
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

    /// Advances the active queue by one item. Used by the display overview
    /// and display workspace controls; fixed wallpapers ignore it.
    func skipToNextQueueItem(displayID: String) {
        guard connectedDisplays[displayID] != nil else { return }
        advanceQueue(for: displayID)
    }

    private func advanceQueue(for displayID: String, generation: Int? = nil) {
        if let generation, generation != queueTimerGenerations[displayID] { return }
        guard let binding = bindings[displayID],
              let queue = effectiveQueue(for: displayID),
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
