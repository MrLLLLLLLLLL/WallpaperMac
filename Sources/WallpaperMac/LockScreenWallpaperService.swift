import AppKit
import WallpaperMacCore

extension Notification.Name {
    /// Posted by WallpaperManager after a display starts presenting a new item
    /// and after a web page finishes its first real navigation.
    static let wallpaperMacAppliedWallpaperChanged = Notification.Name("WallpaperMacAppliedWallpaperChanged")
}

private enum LockScreenSyncError: LocalizedError {
    case noStaticImage(String)
    case snapshotUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .noStaticImage(let name): return "“\(name)”暂时没有可用于锁屏的静态图片。"
        case .snapshotUnavailable(let name): return "“\(name)”的页面尚未生成可用快照，请等待页面加载完成。"
        }
    }
}

/// Keeps the system desktop/lock-screen image aligned with the currently
/// applied wallpaper. The public AppKit API sets an image per NSScreen; macOS
/// decides whether that image is also used by the lock screen. No private
/// lock-screen cache or login-window files are modified.
@MainActor
final class LockScreenWallpaperService: ObservableObject {
    static let shared = LockScreenWallpaperService()

    struct Context {
        let items: () -> [WallpaperItem]
        let displays: () -> [DisplayService.Display]
        let appliedWallpaperIDs: () -> [String: UUID]
        let libraryURL: () -> URL?
        let snapshot: (String) async throws -> NSImage?
        /// Optional test seams. Production leaves both nil and uses NSWorkspace.
        let desktopImageURL: ((NSScreen) -> URL?)?
        let setDesktopImageURL: ((URL, NSScreen) throws -> Void)?

        init(
            items: @escaping () -> [WallpaperItem],
            displays: @escaping () -> [DisplayService.Display],
            appliedWallpaperIDs: @escaping () -> [String: UUID],
            libraryURL: @escaping () -> URL?,
            snapshot: @escaping (String) async throws -> NSImage?,
            desktopImageURL: ((NSScreen) -> URL?)? = nil,
            setDesktopImageURL: ((URL, NSScreen) throws -> Void)? = nil
        ) {
            self.items = items
            self.displays = displays
            self.appliedWallpaperIDs = appliedWallpaperIDs
            self.libraryURL = libraryURL
            self.snapshot = snapshot
            self.desktopImageURL = desktopImageURL
            self.setDesktopImageURL = setDesktopImageURL
        }
    }

    /// Errors are kept per display: one successful screen must not hide a
    /// failure on another screen.
    @Published private(set) var errorsByDisplay: [String: String] = [:]
    var lastError: String? {
        let messages = errorsByDisplay.values.sorted()
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    private var context: Context?
    private var pendingTasks: [String: Task<Void, Never>] = [:]
    /// Monotonically increasing per-screen generation. An async task may only
    /// write if its generation and item are still current when it completes.
    private var generations: [String: Int] = [:]
    private var originalDesktopImages: [String: String]
    private var lastSyncedDesktopImages: [String: String]
    private var observers: [NSObjectProtocol] = []

    private init() {
        let defaults = UserDefaults.standard
        originalDesktopImages = defaults.dictionary(forKey: SettingsKey.originalDesktopImages) as? [String: String] ?? [:]
        lastSyncedDesktopImages = defaults.dictionary(forKey: SettingsKey.lastSyncedDesktopImages) as? [String: String] ?? [:]
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .wallpaperMacAppliedWallpaperChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                guard let self,
                      let displayID = note.userInfo?["displayID"] as? String,
                      let itemID = note.userInfo?["itemID"] as? UUID else { return }
                self.synchronize(itemID: itemID, displayID: displayID)
            }
        })
        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.synchronizeAll()
            }
        })
    }

    func configure(context: Context) {
        self.context = context
        updatePreference()
    }

    /// Applies the current opt-in setting. Disabling stops future writes and
    /// invalidates in-flight generations, but leaves the last system image in
    /// place instead of replacing it with a third-party wallpaper.
    func updatePreference() {
        let enabled = UserDefaults.standard.object(forKey: SettingsKey.lockScreenSyncEnabled) as? Bool ?? false
        guard enabled else {
            for displayID in generations.keys {
                generations[displayID] = (generations[displayID] ?? 0) + 1
            }
            pendingTasks.values.forEach { $0.cancel() }
            pendingTasks.removeAll()
            return
        }
        synchronizeAll()
    }

    private func synchronizeAll() {
        guard let context else { return }
        let items = context.items()
        for display in context.displays() {
            captureOriginalBaseline(for: display)
            guard let itemID = context.appliedWallpaperIDs()[display.id],
                  let item = items.first(where: { $0.id == itemID }) else { continue }
            schedule(item: item, display: display)
        }
    }

    private func synchronize(itemID: UUID, displayID: String) {
        guard let context,
              let item = context.items().first(where: { $0.id == itemID }),
              let display = context.displays().first(where: { $0.id == displayID }) else { return }
        schedule(item: item, display: display)
    }

    private func schedule(item: WallpaperItem, display: DisplayService.Display) {
        guard UserDefaults.standard.object(forKey: SettingsKey.lockScreenSyncEnabled) as? Bool ?? false else { return }
        let generation = (generations[display.id] ?? 0) + 1
        generations[display.id] = generation
        pendingTasks[display.id]?.cancel()
        pendingTasks[display.id] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 400_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            await self.synchronize(item: item, display: display, generation: generation)
            if self.generations[display.id] == generation {
                self.pendingTasks[display.id] = nil
            }
        }
    }

    private func synchronize(item: WallpaperItem, display: DisplayService.Display, generation: Int) async {
        guard isCurrent(generation: generation, itemID: item.id, displayID: display.id) else { return }
        do {
            guard let imageURL = try await imageURL(for: item, display: display, generation: generation) else {
                throw LockScreenSyncError.noStaticImage(item.name)
            }
            // Enrichment and snapshots are not cancellation-aware. Check the
            // generation again after they complete so an old item can never
            // overwrite a newer wallpaper or run after the switch is disabled.
            guard isCurrent(generation: generation, itemID: item.id, displayID: display.id) else { return }
            let currentDesktopURL = context?.desktopImageURL?(display.screen)
                ?? NSWorkspace.shared.desktopImageURL(for: display.screen)
            if item.type != .web,
               currentDesktopURL?.standardizedFileURL == imageURL.standardizedFileURL {
                errorsByDisplay[display.id] = nil
                lastSyncedDesktopImages[display.id] = imageURL.path
                persistDesktopImageHistory()
                return
            }
            captureOriginalBaseline(for: display)
            if let setDesktopImageURL = context?.setDesktopImageURL {
                try setDesktopImageURL(imageURL, display.screen)
            } else {
                try NSWorkspace.shared.setDesktopImageURL(imageURL, for: display.screen, options: [:])
            }
            guard isCurrent(generation: generation, itemID: item.id, displayID: display.id) else { return }
            lastSyncedDesktopImages[display.id] = imageURL.path
            persistDesktopImageHistory()
            errorsByDisplay[display.id] = nil
        } catch {
            guard isCurrent(generation: generation, itemID: item.id, displayID: display.id) else { return }
            errorsByDisplay[display.id] = "\(display.name)：\(error.localizedDescription)"
            NSLog("WallpaperMac lock-screen synchronization failed for %@: %@", display.id, error.localizedDescription)
        }
    }

    private func isCurrent(generation: Int, itemID: UUID, displayID: String) -> Bool {
        guard generations[displayID] == generation,
              let context,
              context.appliedWallpaperIDs()[displayID] == itemID else { return false }
        return UserDefaults.standard.object(forKey: SettingsKey.lockScreenSyncEnabled) as? Bool ?? false
    }

    private func imageURL(for item: WallpaperItem, display: DisplayService.Display, generation: Int) async throws -> URL? {
        // A user-selected override always wins, including for web wallpapers.
        if let override = item.lockScreenOverrideURL,
           FileManager.default.fileExists(atPath: override.path) {
            return override
        }
        // Web without an override always prefers the live page over an old
        // library thumbnail.
        if item.type != .web,
           let existing = LockScreenResourceResolver.existingImageURL(for: item) {
            return existing
        }
        switch item.type {
        case .image:
            return nil
        case .video:
            guard let libraryURL = context?.libraryURL(),
                  let enriched = await WallpaperResourceMetadataService.enrich(item: item, libraryURL: libraryURL) else {
                return nil
            }
            return LockScreenResourceResolver.existingImageURL(for: enriched)
        case .web:
            guard let context,
                  let image = try await context.snapshot(display.id),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
                throw LockScreenSyncError.snapshotUnavailable(item.name)
            }
            let directory = try snapshotDirectory(for: display)
            // A new path for every generation is intentional: AppKit caches
            // the image by URL, so replacing bytes at the old path would not
            // reliably refresh the system desktop/lock-screen image.
            let filename = LockScreenResourceResolver.snapshotFilename(for: item)
                .replacingOccurrences(of: ".png", with: "-g\(generation).png")
            let url = directory.appendingPathComponent(filename)
            try data.write(to: url, options: .atomic)
            return url
        }
    }

    private func captureOriginalBaseline(for display: DisplayService.Display) {
        guard let current = context?.desktopImageURL?(display.screen)?.path
            ?? NSWorkspace.shared.desktopImageURL(for: display.screen)?.path else { return }
        // If the current image is our previous synchronized image, retain the
        // older baseline. If the user changed it while sync was disabled, that
        // new image becomes the thing to restore on quit.
        if lastSyncedDesktopImages[display.id] == current { return }
        guard originalDesktopImages[display.id] != current else { return }
        originalDesktopImages[display.id] = current
        persistDesktopImageHistory()
    }

    private func persistDesktopImageHistory() {
        let defaults = UserDefaults.standard
        defaults.set(originalDesktopImages, forKey: SettingsKey.originalDesktopImages)
        defaults.set(lastSyncedDesktopImages, forKey: SettingsKey.lastSyncedDesktopImages)
    }

    /// Restores the per-screen images captured before synchronization. Called
    /// synchronously by AppDelegate before the process exits. The run loop is
    /// given a short chance to deliver AppKit's asynchronous image update.
    @discardableResult
    func restoreOriginalWallpapers() -> Int {
        guard let context else { return 0 }
        var restored = 0
        for (displayID, path) in originalDesktopImages {
            guard let display = context.displays().first(where: { $0.id == displayID }) else { continue }
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let currentURL = context.desktopImageURL?(display.screen)
                ?? NSWorkspace.shared.desktopImageURL(for: display.screen)
            if currentURL?.standardizedFileURL != url.standardizedFileURL {
                do {
                    if let setDesktopImageURL = context.setDesktopImageURL {
                        try setDesktopImageURL(url, display.screen)
                    } else {
                        try NSWorkspace.shared.setDesktopImageURL(url, for: display.screen, options: [:])
                    }
                    restored += 1
                } catch {
                    NSLog("WallpaperMac failed to restore wallpaper for %@: %@", displayID, error.localizedDescription)
                }
            }
        }
        lastSyncedDesktopImages.removeAll()
        persistDesktopImageHistory()
        return restored
    }

    private func snapshotDirectory(for display: DisplayService.Display) throws -> URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let safeDisplayID = display.id.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
        let directory = applicationSupport
            .appendingPathComponent("WallpaperMac", isDirectory: true)
            .appendingPathComponent("LockScreen", isDirectory: true)
            .appendingPathComponent(safeDisplayID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
