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
    public var activeQueueID: UUID
    public var queueStates: [UUID: DisplayQueueState]

    public var id: String { displayID }

    public init(
        displayID: String,
        displayName: String,
        activeQueueID: UUID = PlaybackQueue.defaultQueue.id,
        queueStates: [UUID: DisplayQueueState] = [:]
    ) {
        self.displayID = displayID
        self.displayName = displayName
        self.activeQueueID = activeQueueID
        self.queueStates = queueStates
    }

    public func state(for queueID: UUID) -> DisplayQueueState {
        queueStates[queueID] ?? DisplayQueueState(queueID: queueID)
    }

    public mutating func updateState(_ state: DisplayQueueState) {
        queueStates[state.queueID] = state
    }
}
