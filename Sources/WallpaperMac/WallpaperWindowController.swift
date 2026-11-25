import AVFoundation
import AppKit
import CoreMedia
import WebKit
import WallpaperMacCore

final class WallpaperWindowController: NSWindowController {
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
        // Wallpaper content follows the system appearance, not the app chrome theme.
        window.appearance = SystemAppearance.current
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

