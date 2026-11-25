import Foundation
import CoreGraphics

public enum WallpaperFitMode: String, Codable, CaseIterable, Equatable, Sendable {
    case fill
    case fit
    case stretch
    case tile

    public var title: String {
        switch self {
        case .fill: return "填充"
        case .fit: return "适应"
        case .stretch: return "拉伸"
        case .tile: return "平铺"
        }
    }

    public var preservesAspectRatio: Bool {
        self != .stretch
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
    public var webWallpaperInteractionEnabled: Bool

    public init(
        isPlaying: Bool = true,
        isMuted: Bool = true,
        loops: Bool = true,
        pauseOnBattery: Bool = false,
        pauseInFullScreenApps: Bool = false,
        reloadWebContentOnResume: Bool = false,
        fitMode: WallpaperFitMode = .fill,
        webWallpaperInteractionEnabled: Bool = false
    ) {
        self.isPlaying = isPlaying
        self.isMuted = isMuted
        self.loops = loops
        self.pauseOnBattery = pauseOnBattery
        self.pauseInFullScreenApps = pauseInFullScreenApps
        self.reloadWebContentOnResume = reloadWebContentOnResume
        self.fitMode = fitMode
        self.webWallpaperInteractionEnabled = webWallpaperInteractionEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case isPlaying, isMuted, loops, pauseOnBattery, pauseInFullScreenApps
        case reloadWebContentOnResume, fitMode, webWallpaperInteractionEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isPlaying = try container.decode(Bool.self, forKey: .isPlaying)
        isMuted = try container.decode(Bool.self, forKey: .isMuted)
        loops = try container.decode(Bool.self, forKey: .loops)
        pauseOnBattery = try container.decode(Bool.self, forKey: .pauseOnBattery)
        pauseInFullScreenApps = try container.decode(Bool.self, forKey: .pauseInFullScreenApps)
        reloadWebContentOnResume = try container.decode(Bool.self, forKey: .reloadWebContentOnResume)
        fitMode = try container.decode(WallpaperFitMode.self, forKey: .fitMode)
        webWallpaperInteractionEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .webWallpaperInteractionEnabled
        ) ?? false
    }

    public func shouldPauseDynamicWallpaper(isOnBattery: Bool, isFullScreenAppActive: Bool) -> Bool {
        (pauseOnBattery && isOnBattery) ||
            (pauseInFullScreenApps && isFullScreenAppActive)
    }

    /// Per-display suspension: a sleeping screen or inactive session always
    /// suspends; battery applies to every screen, while a fullscreen app only
    /// pauses the screen that contains its window.
    public func shouldPauseDynamicWallpaper(
        displayID: String,
        activity: PlaybackActivityState
    ) -> Bool {
        activity.requiresSuspension ||
            (pauseOnBattery && activity.isOnBattery) ||
            (pauseInFullScreenApps && activity.fullScreenDisplayIDs.contains(displayID))
    }
}

public struct PlaybackActivityState: Equatable, Sendable {
    public var isOnBattery: Bool
    public var fullScreenDisplayIDs: Set<String>
    /// True while the screens are asleep (display sleep / lid closed).
    public var isScreenAsleep: Bool
    /// True while the login session is not active (locked / fast user switch).
    public var isSessionInactive: Bool

    public init(
        isOnBattery: Bool = false,
        fullScreenDisplayIDs: Set<String> = [],
        isScreenAsleep: Bool = false,
        isSessionInactive: Bool = false
    ) {
        self.isOnBattery = isOnBattery
        self.fullScreenDisplayIDs = fullScreenDisplayIDs
        self.isScreenAsleep = isScreenAsleep
        self.isSessionInactive = isSessionInactive
    }

    /// A sleeping screen or an inactive session must always suspend dynamic
    /// wallpaper regardless of the user's battery/fullscreen preferences.
    public var requiresSuspension: Bool {
        isScreenAsleep || isSessionInactive
    }
}

public enum ApplicationState: String, Codable, CaseIterable, Equatable, Sendable {
    case idle
    case applying
    case applied
    case failed
    case disconnected
}

/// Geometry helpers for deciding whether a window rect (Quartz global
/// coordinates, origin at the main screen's top-left) represents a fullscreen
/// window on a screen (Cocoa frame, origin at bottom-left). Kept as pure
/// functions so the coordinate handling is unit-testable without AppKit.
public enum FullscreenGeometry {
    /// Converts a Quartz window rect to the Cocoa coordinate space using the
    /// main (primary) screen height.
    public static func cocoaRect(fromQuartz rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryScreenHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// True when the (already Cocoa-space) rect covers essentially the whole
    /// screen frame. An intersection-area test tolerates menu-bar insets and
    /// rounding, unlike exact edge comparison.
    public static func isFullscreen(
        rect: CGRect,
        on screenFrame: CGRect,
        tolerance: CGFloat = 0.97
    ) -> Bool {
        guard screenFrame.width > 0, screenFrame.height > 0 else { return false }
        let intersection = rect.intersection(screenFrame)
        guard !intersection.isNull else { return false }
        let covered = (intersection.width * intersection.height) / (screenFrame.width * screenFrame.height)
        return covered >= tolerance
    }
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
