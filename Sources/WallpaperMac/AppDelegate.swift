import AppKit
import WallpaperMacCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Apply the saved app appearance before any window is created so the
        // titlebar is drawn in the theme's color scheme from the start.
        _ = ThemeStore.shared
        GlobalHotKeyService.shared.register {
            NotificationCenter.default.post(name: .wallpaperMacStatusHideHiddenWallpapers, object: nil)
        }
        UpdateInstaller.removeStaleInstallerBackupsIfUnlocked(targetAppURL: Bundle.main.bundleURL)
        WallpaperVideoCompatibilityService.removeLegacyPlaybackCache()
        statusBarController = StatusBarController(
            showMainWindow: { [weak self] in self?.showMainWindow() },
            showSettings: { [weak self] in self?.showSettingsWindow() },
            openLibrary: { [weak self] in self?.openLibrary() },
            quitApplication: { NSApp.terminate(nil) }
        )
        showMainWindow()

        // A freshly installed build must acknowledge the installer before any
        // modal UI can block the launch; otherwise a stale failure alert would
        // make the installer believe the new build never became healthy.
        do {
            _ = try UpdateHealthHandshake.acknowledge(arguments: CommandLine.arguments)
        } catch {
            NSLog("WallpaperMac update health acknowledgement failed: \(error.localizedDescription)")
        }

        // Consume any failure left behind by the detached installer. Record it
        // now, but defer the modal until the launch has completed so it cannot
        // delay the health acknowledgement above.
        if let failure = UpdateInstallJournal.takeFailure() {
            // Do not automatically reinstall the same version after a
            // detached-install failure. The journal's failure is shown to the
            // user, while the next daily check may discover a different one.
            if let version = failure.version {
                UserDefaults.standard.set(version, forKey: SettingsKey.automaticUpdateBlockedVersion)
            }
            Task { @MainActor [weak self] in
                self?.presentInstallFailure(failure)
            }
        }

        // Daily checks and optional unattended installs run for the whole
        // menu-bar session, independent of the settings UI.
        UpdateService.shared.updateAutomaticPreferences()
    }

    private func presentInstallFailure(_ failure: UpdateInstallFailure) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "更新未完成"
        let targetVersion = failure.version ?? "新版本"
        var details = "更新到 \(targetVersion) 未完成：\(failure.message)\n"
        if let installedVersion = UpdateInstaller.installedVersion(at: Bundle.main.bundleURL) {
            if let failedVersion = failure.version, installedVersion == failedVersion {
                details += "当前安装的是 \(installedVersion)，但未能确认安装后的首次启动是否正常。"
            } else {
                details += "当前仍使用已安装版本 \(installedVersion)。"
            }
        } else {
            details += "当前仍使用已安装版本。"
        }
        if let logPath = failure.logPath, !logPath.isEmpty {
            details += "\n\n安装日志：\(logPath)"
        }
        alert.informativeText = details
        alert.addButton(withTitle: "好")
        if let logPath = failure.logPath, !logPath.isEmpty {
            alert.addButton(withTitle: "打开安装日志")
        }
        let response = alert.runModal()
        if response == .alertSecondButtonReturn,
           let logPath = failure.logPath,
           !logPath.isEmpty {
            NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
        }
    }

    func showMainWindow() {
        if mainWindowController == nil {
            mainWindowController = MainWindowController()
        }
        mainWindowController?.showWindow(nil)
        mainWindowController?.window?.makeKeyAndOrderFront(nil)
        activateApplication()
    }

    func showSettingsWindow() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        activateApplication()
    }

    /// A direct-exec launched copy can start behind the previously active app.
    /// Prefer the modern cooperative activation API when it is available.
    private func activateApplication() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func openLibrary() {
        let defaults = UserDefaults.standard
        let defaultPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("WallpaperMac", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .path
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/WallpaperMac/Library", isDirectory: true)
                .path
        let path = defaults.string(forKey: SettingsKey.libraryPath) ?? defaultPath
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Give queued JSON writes a chance to reach disk before the process
        // exits, so a fast queue change right before quitting is not lost.
        NotificationCenter.default.post(name: .wallpaperMacFlushPersistence, object: nil)
        // Spin the run loop until the observer's async flush completes (or a
        // hard cap). A fixed sleep can return before a slow write finishes;
        // the cap bounds shutdown even if a write hangs.
        let deadline = Date(timeIntervalSinceNow: 3.0)
        while Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
            if !UserDefaults.standard.bool(forKey: "WallpaperMacPersistenceFlushPending") { break }
        }
    }
}
