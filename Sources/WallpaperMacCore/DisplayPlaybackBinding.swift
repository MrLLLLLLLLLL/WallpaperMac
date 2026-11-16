import Foundation

public struct DisplayQueueState: Codable, Equatable, Sendable {
    public let queueID: UUID
    public var currentIndex: Int
    public var isPlaying: Bool
    public var isEnabled: Bool
    public var overrides: QueuePlaybackOverrides

    public init(
        queueID: UUID,
        currentIndex: Int = 0,
        isPlaying: Bool = false,
        isEnabled: Bool = false,
        overrides: QueuePlaybackOverrides = QueuePlaybackOverrides()
    ) {
        self.queueID = queueID
        self.currentIndex = max(0, currentIndex)
        self.isPlaying = isPlaying
        self.isEnabled = isEnabled
        self.overrides = overrides
    }

    public mutating func normalize(for queue: PlaybackQueue?) {
        currentIndex = max(0, currentIndex)
        if let queue, !queue.wallpaperIDs.isEmpty, currentIndex >= queue.wallpaperIDs.count {
            currentIndex %= queue.wallpaperIDs.count
        } else if queue?.wallpaperIDs.isEmpty == true {
            currentIndex = 0
            isEnabled = false
        }
        if let interval = overrides.intervalSeconds, !interval.isFinite {
            overrides.intervalSeconds = nil
        }
    }
}

public struct DisplayPlaybackBinding: Identifiable, Codable, Equatable, Sendable {
    public let displayID: String
    public var displayName: String
    /// Queue used while the hidden-wallpaper switch is off.
    public var defaultQueueID: UUID
    /// Queue used while the hidden-wallpaper switch is on. Nil means empty.
    public var hiddenQueueID: UUID?
    /// The currently effective queue, kept for legacy files and published UI.
    public var activeQueueID: UUID
    public var queueStates: [UUID: DisplayQueueState]

    public var id: String { displayID }

    private enum CodingKeys: String, CodingKey {
        case displayID, displayName, defaultQueueID, hiddenQueueID, activeQueueID, queueStates
    }

    public init(
        displayID: String,
        displayName: String,
        activeQueueID: UUID = PlaybackQueue.defaultQueue.id,
        defaultQueueID: UUID? = nil,
        hiddenQueueID: UUID? = nil,
        queueStates: [UUID: DisplayQueueState] = [:]
    ) {
        self.displayID = displayID
        self.displayName = displayName
        self.defaultQueueID = defaultQueueID ?? activeQueueID
        self.hiddenQueueID = hiddenQueueID
        self.activeQueueID = activeQueueID
        self.queueStates = queueStates
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayID = try container.decode(String.self, forKey: .displayID)
        displayName = try container.decode(String.self, forKey: .displayName)
        activeQueueID = try container.decode(UUID.self, forKey: .activeQueueID)
        defaultQueueID = try container.decodeIfPresent(UUID.self, forKey: .defaultQueueID) ?? activeQueueID
        hiddenQueueID = try container.decodeIfPresent(UUID.self, forKey: .hiddenQueueID)
        queueStates = try container.decode([UUID: DisplayQueueState].self, forKey: .queueStates)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(displayID, forKey: .displayID)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(defaultQueueID, forKey: .defaultQueueID)
        try container.encodeIfPresent(hiddenQueueID, forKey: .hiddenQueueID)
        try container.encode(activeQueueID, forKey: .activeQueueID)
        try container.encode(queueStates, forKey: .queueStates)
    }

    public func queueID(for kind: PlaybackQueueKind) -> UUID? {
        switch kind {
        case .normal: return defaultQueueID
        case .hidden: return hiddenQueueID
        }
    }

    public mutating func setQueueID(_ queueID: UUID?, for kind: PlaybackQueueKind) {
        switch kind {
        case .normal:
            if let queueID { defaultQueueID = queueID }
        case .hidden:
            hiddenQueueID = queueID
        }
    }

    public func state(for queueID: UUID) -> DisplayQueueState {
        queueStates[queueID] ?? DisplayQueueState(queueID: queueID)
    }

    public mutating func updateState(_ state: DisplayQueueState) {
        queueStates[state.queueID] = state
    }

    /// Marks a bound queue as requiring explicit reapplication after its
    /// contents or playback rules change. The last index is retained so the
    /// queue can resume from the same position when applied again.
    @discardableResult
    public mutating func invalidateBoundQueue(ifMatching queueID: UUID) -> Bool {
        guard activeQueueID == queueID || defaultQueueID == queueID || hiddenQueueID == queueID else {
            return false
        }
        var state = state(for: queueID)
        state.isEnabled = false
        state.isPlaying = false
        queueStates[queueID] = state
        return true
    }
}
