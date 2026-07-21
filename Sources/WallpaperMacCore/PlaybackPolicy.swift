import Foundation

public enum WallpaperFitMode: String, Codable, CaseIterable, Equatable, Sendable {
    case fill
    case fit

    public var title: String {
        switch self {
        case .fill: return "填充屏幕"
        case .fit: return "完整显示"
        }
    }
}

public struct PlaybackPolicy: Codable, Equatable, Sendable {
    public var isPlaying: Bool
    public var isMuted: Bool
    public var loops: Bool
    public var pauseOnBattery: Bool
    public var pauseInFullScreenApps: Bool
    public var reloadWebContentOnResume: Bool
    public var fitMode: WallpaperFitMode

    public init(
        isPlaying: Bool = true,
        isMuted: Bool = true,
        loops: Bool = true,
        pauseOnBattery: Bool = false,
        pauseInFullScreenApps: Bool = false,
        reloadWebContentOnResume: Bool = false,
        fitMode: WallpaperFitMode = .fill
    ) {
        self.isPlaying = isPlaying
        self.isMuted = isMuted
        self.loops = loops
        self.pauseOnBattery = pauseOnBattery
        self.pauseInFullScreenApps = pauseInFullScreenApps
        self.reloadWebContentOnResume = reloadWebContentOnResume
        self.fitMode = fitMode
    }

    public func shouldPauseDynamicWallpaper(isOnBattery: Bool, isFullScreenAppActive: Bool) -> Bool {
        (pauseOnBattery && isOnBattery) ||
            (pauseInFullScreenApps && isFullScreenAppActive)
    }
}

public enum ApplicationState: String, Codable, CaseIterable, Equatable, Sendable {
    case idle
    case applying
    case applied
    case failed
    case disconnected
}

public struct DisplayAssignment: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var displayName: String
    public var isConnected: Bool
    public var wallpaperID: UUID?
    public var applicationState: ApplicationState

    public init(
        id: String,
        displayName: String,
        isConnected: Bool,
        wallpaperID: UUID? = nil,
        applicationState: ApplicationState = .idle
    ) {
        self.id = id
        self.displayName = displayName
        self.isConnected = isConnected
        self.wallpaperID = wallpaperID
        self.applicationState = applicationState
    }
}
