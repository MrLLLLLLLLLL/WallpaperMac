import AVFoundation
import AppKit
import CoreMedia
import WebKit
import WallpaperMacCore

final class WallpaperWindow: NSWindow {
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

