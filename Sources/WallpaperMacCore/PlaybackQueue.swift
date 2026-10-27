import Foundation

public enum QueueSortMode: String, Codable, CaseIterable, Equatable, Sendable {
    case custom
    case name
    case type
    case addedAt

    public var title: String {
        switch self {
        case .custom: return "自定义排序"
        case .name: return "按名称"
        case .type: return "按类型"
        case .addedAt: return "按添加时间"
        }
    }
}

public enum QueuePlaybackMode: String, Codable, CaseIterable, Equatable, Sendable {
    case sequential
    case random

    public var title: String {
        switch self {
        case .sequential: return "顺序播放"
        case .random: return "随机播放"
        }
    }
}

public enum QueueCompletionBehavior: String, Codable, CaseIterable, Equatable, Sendable {
    case loop
    case stopAfterOneCycle

    public var title: String {
        switch self {
        case .loop: return "循环播放"
        case .stopAfterOneCycle: return "播放一次后停止"
        }
    }
}

public struct PlaybackQueue: Identifiable, Codable, Equatable, Sendable {
    public static let defaultName = "默认队列"
    public static let defaultQueue = PlaybackQueue(name: defaultName, isDefault: true)

    public let id: UUID
    public var name: String
    public let isDefault: Bool
    public private(set) var wallpaperIDs: [UUID]
    public var sortMode: QueueSortMode
    public var playbackMode: QueuePlaybackMode
    public var completionBehavior: QueueCompletionBehavior
    /// When enabled, a video advances this queue when its media item reaches the end.
    /// The default keeps the pre-0.2.2 timer behavior for existing queues.
    public var advanceAfterVideoCompletion: Bool
    public var defaultIntervalSeconds: Double
    public var transition: WallpaperTransitionEffect
    public var itemIntervalOverrides: [UUID: Double]
    public let createdAt: Date
    public var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, name, isDefault, wallpaperIDs, sortMode, playbackMode
        case completionBehavior, advanceAfterVideoCompletion, defaultIntervalSeconds
        case transition, itemIntervalOverrides, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.isDefault = try container.decode(Bool.self, forKey: .isDefault)
        self.wallpaperIDs = Self.deduplicated(try container.decode([UUID].self, forKey: .wallpaperIDs))
        self.sortMode = try container.decode(QueueSortMode.self, forKey: .sortMode)
        self.playbackMode = try container.decode(QueuePlaybackMode.self, forKey: .playbackMode)
        self.completionBehavior = try container.decode(QueueCompletionBehavior.self, forKey: .completionBehavior)
        self.advanceAfterVideoCompletion = try container.decodeIfPresent(Bool.self, forKey: .advanceAfterVideoCompletion) ?? false
        self.defaultIntervalSeconds = Self.clampedInterval(try container.decode(Double.self, forKey: .defaultIntervalSeconds))
        self.transition = try container.decode(WallpaperTransitionEffect.self, forKey: .transition)
        self.itemIntervalOverrides = Self.normalizedOverrides(try container.decode([UUID: Double].self, forKey: .itemIntervalOverrides))
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    public init(
        id: UUID = UUID(),
        name: String,
        isDefault: Bool = false,
        wallpaperIDs: [UUID] = [],
        sortMode: QueueSortMode = .custom,
        playbackMode: QueuePlaybackMode = .sequential,
        completionBehavior: QueueCompletionBehavior = .loop,
        advanceAfterVideoCompletion: Bool = false,
        defaultIntervalSeconds: Double = 30,
        transition: WallpaperTransitionEffect = .crossfade,
        itemIntervalOverrides: [UUID: Double] = [:],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.isDefault = isDefault
        self.name = isDefault ? Self.defaultName : name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.wallpaperIDs = Self.deduplicated(wallpaperIDs)
        self.sortMode = sortMode
        self.playbackMode = playbackMode
        self.completionBehavior = completionBehavior
        self.advanceAfterVideoCompletion = advanceAfterVideoCompletion
        self.defaultIntervalSeconds = Self.clampedInterval(defaultIntervalSeconds)
        self.transition = transition
        self.itemIntervalOverrides = Self.normalizedOverrides(itemIntervalOverrides)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public mutating func normalize() {
        if isDefault { name = Self.defaultName }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        wallpaperIDs = Self.deduplicated(wallpaperIDs)
        defaultIntervalSeconds = Self.clampedInterval(defaultIntervalSeconds)
        itemIntervalOverrides = Self.normalizedOverrides(itemIntervalOverrides)
    }

    public mutating func addWallpaperIDs(_ ids: [UUID]) {
        var merged = wallpaperIDs
        for id in ids where !merged.contains(id) {
            merged.append(id)
        }
        wallpaperIDs = merged
        updatedAt = Date()
    }

    /// Replaces membership wholesale while keeping the given order.
    ///
    /// Used by the queue editor: deletions and manual reordering must stick,
    /// which an additive merge cannot express. Callers that hand-edited the
    /// order pass `markingSortMode: .custom` so later automatic sorting does
    /// not silently reshuffle the list.
    public mutating func replaceWallpaperIDs(_ ids: [UUID], markingSortMode mode: QueueSortMode? = nil) {
        wallpaperIDs = Self.deduplicated(ids)
        if let mode {
            sortMode = mode
        }
        let valid = Set(wallpaperIDs)
        itemIntervalOverrides = itemIntervalOverrides.filter { valid.contains($0.key) }
        updatedAt = Date()
    }

    public mutating func removeWallpaperIDs(_ ids: Set<UUID>) {
        wallpaperIDs.removeAll { ids.contains($0) }
        itemIntervalOverrides = itemIntervalOverrides.filter { !ids.contains($0.key) }
        updatedAt = Date()
    }

    public mutating func setSortMode(_ mode: QueueSortMode) {
        sortMode = mode
        updatedAt = Date()
    }

    public mutating func moveWallpaper(from sourceIndex: Int, to destinationIndex: Int) {
        guard wallpaperIDs.indices.contains(sourceIndex), destinationIndex >= 0, destinationIndex <= wallpaperIDs.count else { return }
        let item = wallpaperIDs.remove(at: sourceIndex)
        let adjustedDestination = sourceIndex < destinationIndex ? destinationIndex - 1 : destinationIndex
        wallpaperIDs.insert(item, at: min(max(0, adjustedDestination), wallpaperIDs.count))
        sortMode = .custom
        updatedAt = Date()
    }

    public mutating func setIntervalOverride(_ seconds: Double?, for itemID: UUID) {
        if let seconds {
            itemIntervalOverrides[itemID] = Self.clampedInterval(seconds)
        } else {
            itemIntervalOverrides.removeValue(forKey: itemID)
        }
        updatedAt = Date()
    }

    public func intervalOverride(for itemID: UUID) -> Double? {
        itemIntervalOverrides[itemID]
    }

    public func interval(for itemID: UUID) -> Double {
        itemIntervalOverrides[itemID] ?? defaultIntervalSeconds
    }

    /// Fallback timeout when a queue advances after video completion.
    ///
    /// Video-completion queues have no periodic tick, so a stall (failed
    /// decoder start, hung ffmpeg, probe error) would freeze the queue
    /// forever. The watchdog is a *stall* detector, not a playback limiter:
    ///
    /// - Known duration: fires slightly after the video should have ended.
    /// - Unknown duration: a short stall window. The player feeds a frame
    ///   heartbeat that keeps re-arming it, so healthy long videos are never
    ///   cut while a truly hung pipeline still recovers.
    ///
    /// `hardDeadlineInterval` is the absolute ceiling that a heartbeat cannot
    /// extend, applied separately per display.
    public func stallWatchdogInterval(forVideoWithDurationSeconds durationSeconds: Double?) -> Double {
        if let durationSeconds, durationSeconds.isFinite, durationSeconds > 0 {
            let grace = max(15, durationSeconds * 0.2)
            return min(max(durationSeconds + grace, 30), 86_400)
        }
        // Unknown duration: stall window only. Absence of frames for this long
        // means the pipeline is dead; the heartbeat covers healthy playback.
        return Self.unknownDurationStallWindowSeconds
    }

    /// Absolute playback ceiling for video-completion queues, independent of
    /// the stall heartbeat. Prevents an infinite, always-progressing stream
    /// from occupying a display forever.
    public var hardDeadlineInterval: Double { 4 * 60 * 60 }

    public static let unknownDurationStallWindowSeconds: Double = 60

    private static func deduplicated(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }
    }

    private static func normalizedOverrides(_ overrides: [UUID: Double]) -> [UUID: Double] {
        overrides.reduce(into: [:]) { result, entry in
            result[entry.key] = clampedInterval(entry.value)
        }
    }

    private static func clampedInterval(_ value: Double) -> Double {
        guard value.isFinite else { return 30 }
        return min(max(value.rounded(), 1), 86_400)
    }
}

public struct QueuePlaybackOverrides: Codable, Equatable, Sendable {
    public var intervalSeconds: Double?
    public var playbackMode: QueuePlaybackMode?
    public var completionBehavior: QueueCompletionBehavior?
    public var transition: WallpaperTransitionEffect?

    public init(
        intervalSeconds: Double? = nil,
        playbackMode: QueuePlaybackMode? = nil,
        completionBehavior: QueueCompletionBehavior? = nil,
        transition: WallpaperTransitionEffect? = nil
    ) {
        self.intervalSeconds = intervalSeconds.map { min(max($0.rounded(), 1), 86_400) }
        self.playbackMode = playbackMode
        self.completionBehavior = completionBehavior
        self.transition = transition
    }
}
