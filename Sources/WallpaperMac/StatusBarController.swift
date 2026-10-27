import AppKit

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var isPlaybackPaused = false
    private let togglePlaybackItem = NSMenuItem()
    private let toggleMuteItem = NSMenuItem()
    private let showMainWindow: () -> Void
    private let showSettings: () -> Void
    private let openLibrary: () -> Void
    private let quitApplication: () -> Void

    init(
        showMainWindow: @escaping () -> Void,
        showSettings: @escaping () -> Void,
        openLibrary: @escaping () -> Void,
        quitApplication: @escaping () -> Void
    ) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.showMainWindow = showMainWindow
        self.showSettings = showSettings
        self.openLibrary = openLibrary
        self.quitApplication = quitApplication
        super.init()
        configureStatusItem()
        configureMenu()
    }

    private func configureStatusItem() {
        // Use a deterministic monochrome icon so the menu extra remains visible
        // even if the system symbol catalog is unavailable.
        statusItem.length = NSStatusItem.variableLength
        statusItem.isVisible = true

        guard let button = statusItem.button else { return }
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.setStroke()
            let back = NSBezierPath(roundedRect: NSRect(x: 2, y: 5, width: 10, height: 9), xRadius: 2, yRadius: 2)
            back.lineWidth = 1.5
            back.stroke()
            let front = NSBezierPath(roundedRect: NSRect(x: 6, y: 2, width: 10, height: 9), xRadius: 2, yRadius: 2)
            front.lineWidth = 1.5
            front.stroke()
            return true
        }
        image.isTemplate = true
        button.image = image
        // Keep the short label visible as a fallback and as an accessible name
        // when the menu bar chooses not to render template artwork.
        button.title = "WM"
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = "WallpaperMac"
        button.setAccessibilityLabel("WallpaperMac")
    }

    private func configureMenu() {
        let showItem = NSMenuItem(title: "打开 WallpaperMac", action: #selector(showMainWindowAction), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
        menu.addItem(.separator())

        togglePlaybackItem.title = "暂停动态壁纸"
        togglePlaybackItem.action = #selector(togglePlaybackAction)
        togglePlaybackItem.target = self
        menu.addItem(togglePlaybackItem)

        toggleMuteItem.title = "静音视频与网页"
        toggleMuteItem.action = #selector(toggleMuteAction)
        toggleMuteItem.target = self
        menu.addItem(toggleMuteItem)

        menu.addItem(.separator())
        let libraryItem = NSMenuItem(title: "打开壁纸库", action: #selector(openLibraryAction), keyEquivalent: "")
        libraryItem.target = self
        menu.addItem(libraryItem)

        let settingsItem = NSMenuItem(title: "打开设置…", action: #selector(showSettingsAction), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 WallpaperMac", action: #selector(quitApplicationAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        menu.delegate = self
        statusItem.menu = menu

        NotificationCenter.default.addObserver(
            forName: .wallpaperMacPlaybackStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let playing = (note.userInfo?["isPlaying"] as? Bool) ?? true
            self.isPlaybackPaused = !playing
            self.refreshPlaybackMenuTitle()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshPlaybackMenuTitle()
    }

    private func refreshPlaybackMenuTitle() {
        togglePlaybackItem.title = isPlaybackPaused ? "恢复动态壁纸" : "暂停动态壁纸"
    }

    @objc private func showMainWindowAction() {
        showMainWindow()
    }

    @objc private func togglePlaybackAction() {
        NotificationCenter.default.post(name: .wallpaperMacStatusTogglePlayback, object: nil)
    }

    @objc private func toggleMuteAction() {
        NotificationCenter.default.post(name: .wallpaperMacStatusToggleMute, object: nil)
    }

    @objc private func openLibraryAction() {
        openLibrary()
    }

    @objc private func showSettingsAction() {
        showSettings()
    }

    @objc private func quitApplicationAction() {
        quitApplication()
    }
}

extension Notification.Name {
    static let wallpaperMacStatusTogglePlayback = Notification.Name("WallpaperMacStatusTogglePlayback")
    static let wallpaperMacStatusToggleMute = Notification.Name("WallpaperMacStatusToggleMute")
    static let wallpaperMacPlaybackStateChanged = Notification.Name("WallpaperMacPlaybackStateChanged")
}
