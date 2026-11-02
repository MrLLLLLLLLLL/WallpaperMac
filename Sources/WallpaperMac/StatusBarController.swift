import AppKit
import Combine

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var isPlaybackPaused = false
    private let togglePlaybackItem = NSMenuItem()
    private let toggleMuteItem = NSMenuItem()
    private let updateItem = NSMenuItem()
    private var updatePhaseObservation: AnyCancellable?
    private let showMainWindow: () -> Void
    private let showSettings: () -> Void
    private let openLibrary: () -> Void
    private let quitApplication: () -> Void

    private lazy var normalStatusImage = Self.makeStatusImage(showUpdateBadge: false)
    private lazy var updateStatusImage = Self.makeStatusImage(showUpdateBadge: true)

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
        observeUpdateState()
    }

    private func configureStatusItem() {
        // Use a deterministic monochrome icon so the menu extra remains visible
        // even if the system symbol catalog is unavailable.
        statusItem.length = NSStatusItem.variableLength
        statusItem.isVisible = true

        guard let button = statusItem.button else { return }
        button.image = normalStatusImage
        // Keep the short label visible as a fallback and as an accessible name
        // when the menu bar chooses not to render template artwork.
        button.title = "WM"
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = "WallpaperMac"
        button.setAccessibilityLabel("WallpaperMac")
    }

    private static func makeStatusImage(showUpdateBadge: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let back = NSBezierPath(roundedRect: NSRect(x: 2, y: 5, width: 10, height: 9), xRadius: 2, yRadius: 2)
            back.lineWidth = 1.5
            back.stroke()
            let front = NSBezierPath(roundedRect: NSRect(x: 6, y: 2, width: 10, height: 9), xRadius: 2, yRadius: 2)
            front.lineWidth = 1.5
            front.stroke()
            if showUpdateBadge {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: 12.5, y: 12.5, width: 5, height: 5)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private func configureMenu() {
        let showItem = NSMenuItem(title: "打开 WallpaperMac", action: #selector(showMainWindowAction), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        // Hidden until a check finds a newer release. Lives in the menu so a
        // background check never steals focus or opens a dialog.
        updateItem.title = "发现新版本"
        updateItem.action = #selector(showUpdateSettingsAction)
        updateItem.target = self
        updateItem.isHidden = true
        menu.addItem(updateItem)
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
            Task { @MainActor [weak self] in
                guard let self else { return }
                let playing = (note.userInfo?["isPlaying"] as? Bool) ?? true
                self.isPlaybackPaused = !playing
                self.refreshPlaybackMenuTitle()
            }
        }
    }

    private func observeUpdateState() {
        updatePhaseObservation = UpdateService.shared.$phase
            .sink { [weak self] phase in
                Task { @MainActor [weak self] in
                    self?.applyUpdatePhase(phase)
                }
            }
    }

    private func applyUpdatePhase(_ phase: UpdateService.Phase) {
        switch phase {
        case .available(let update):
            updateItem.title = "发现新版本 \(update.version)…"
            updateItem.isHidden = false
            showUpdateBadge(version: update.version)
        case .downloading(let update, _):
            updateItem.title = "正在下载更新 \(update.version)…"
            updateItem.isHidden = false
            showUpdateBadge(version: update.version)
        case .installing(let update):
            updateItem.title = "正在安装更新 \(update.version)…"
            updateItem.isHidden = false
            showUpdateBadge(version: update.version)
        case .idle, .checking, .upToDate, .failed:
            updateItem.isHidden = true
            clearUpdateBadge()
        }
    }

    private func showUpdateBadge(version: String) {
        statusItem.button?.image = updateStatusImage
        statusItem.button?.toolTip = "WallpaperMac：发现新版本 \(version)"
        statusItem.button?.setAccessibilityLabel("WallpaperMac，发现新版本 \(version)")
    }

    private func clearUpdateBadge() {
        statusItem.button?.image = normalStatusImage
        statusItem.button?.toolTip = "WallpaperMac"
        statusItem.button?.setAccessibilityLabel("WallpaperMac")
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

    @objc private func showUpdateSettingsAction() {
        showSettings()
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
