import Foundation

public enum WallpaperTransitionEffect: String, Codable, CaseIterable, Equatable, Sendable {
    case cut
    case crossfade
    case slideLeft
    case slideRight
    case zoom

    public var title: String {
        switch self {
        case .cut: return "立即切换"
        case .crossfade: return "淡入淡出"
        case .slideLeft: return "向左滑入"
        case .slideRight: return "向右滑入"
        case .zoom: return "缩放淡入"
        }
    }
}

public struct DisplayPlaybackQueue: Identifiable, Codable, Equatable, Sendable {
    public let displayID: String
    public var displayName: String
    public var wallpaperIDs: [UUID]
    public var intervalSeconds: Double
    public var transition: WallpaperTransitionEffect
    public var isEnabled: Bool
    public var currentIndex: Int

    public var id: String { displayID }

    public init(
        displayID: String,
        displayName: String,
        wallpaperIDs: [UUID] = [],
        intervalSeconds: Double = 30,
        transition: WallpaperTransitionEffect = .crossfade,
        isEnabled: Bool = false,
        currentIndex: Int = 0
    ) {
        self.displayID = displayID
        self.displayName = displayName
        self.wallpaperIDs = wallpaperIDs
        self.intervalSeconds = Self.clampedInterval(intervalSeconds)
        self.transition = transition
        self.isEnabled = isEnabled
        self.currentIndex = max(0, currentIndex)
    }

    public var normalizedIntervalSeconds: Double {
        Self.clampedInterval(intervalSeconds)
    }

    public mutating func normalize() {
        intervalSeconds = Self.clampedInterval(intervalSeconds)
        currentIndex = max(0, currentIndex)
        if wallpaperIDs.isEmpty {
            currentIndex = 0
        } else if currentIndex >= wallpaperIDs.count {
            currentIndex = currentIndex % wallpaperIDs.count
        }
    }

    private static func clampedInterval(_ value: Double) -> Double {
        guard value.isFinite else { return 30 }
        return min(max(value.rounded(), 1), 86_400)
    }
}
