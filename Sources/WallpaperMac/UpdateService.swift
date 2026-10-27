import AppKit
import Foundation
import WallpaperMacCore

/// Owns the update check/install lifecycle.
///
/// Lives outside SwiftUI views so daily checks run at app launch (not only
/// when the settings window appears) and an in-flight install is never
/// cancelled just because the window closed.
@MainActor
final class UpdateService: ObservableObject {
    static let shared = UpdateService()

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate(String)
        case available(AvailableUpdate)
        case downloading(AvailableUpdate, UpdateDownloadProgress?)
        case installing(AvailableUpdate)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    private var task: Task<Void, Never>?
    private let clock: @MainActor () -> Date

    init(clock: @escaping @MainActor () -> Date = { Date() }) {
        self.clock = clock
    }

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .installing:
            return true
        case .idle, .upToDate, .available, .failed:
            return false
        }
    }

    func checkForUpdates(userInitiated: Bool) {
        guard !isBusy else { return }
        phase = .checking
        let currentVersion = ApplicationVersionInfo(
            infoDictionary: Bundle.main.infoDictionary ?? [:],
            fallbackVersion: "0.2.6"
        ).version

        task = Task {
            let checker = UpdateChecker(currentVersion: currentVersion)
            do {
                let result = try await checker.check()
                switch result {
                case .upToDate(let version):
                    self.phase = .upToDate(version)
                case .updateAvailable(let update):
                    self.phase = .available(update)
                }
                UserDefaults.standard.set(self.clock(), forKey: SettingsKey.lastUpdateCheckDate)
            } catch {
                // Silent background checks only surface real updates.
                self.phase = userInitiated ? .failed(error.localizedDescription) : .idle
            }
        }
    }

    func installUpdate(_ update: AvailableUpdate) {
        guard phase == .available(update) else { return }
        phase = .downloading(update, nil)

        let stagingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WallpaperMacUpdate", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        Self.pruneStaleStagingDirectories()

        task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                try UpdateInstaller.preflight()

                let downloader = UpdateDownloader()
                let outcome = try await downloader.downloadAndVerify(
                    update: update,
                    stagingDirectory: stagingDirectory
                ) { progress in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if case .downloading(let current, _) = self.phase, current == update {
                            self.phase = .downloading(current, progress)
                        }
                    }
                }

                // prepare runs ditto + wait: must stay off the main actor.
                let prepared = try UpdateInstaller.prepare(
                    zipFileURL: outcome.zipFileURL,
                    expectedVersion: update.version,
                    stagingDirectory: outcome.stagingDirectory
                )

                await MainActor.run {
                    self.phase = .installing(update)
                }
                try UpdateInstaller.launchDetachedInstall(of: prepared)
                await MainActor.run {
                    NSApp.terminate(nil)
                }
            } catch {
                await MainActor.run {
                    self.phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    func runDailyCheckIfNeeded() {
        guard !isBusy else { return }
        let lastCheck = UserDefaults.standard.object(forKey: SettingsKey.lastUpdateCheckDate) as? Date
        if let lastCheck, clock().timeIntervalSince(lastCheck) < 24 * 60 * 60 {
            return
        }
        checkForUpdates(userInitiated: false)
    }

    /// Clears a visible "update available" or error prompt without touching a
    /// download/install already in flight.
    func dismissPrompt() {
        switch phase {
        case .available, .failed, .upToDate:
            phase = .idle
        case .idle, .checking, .downloading, .installing:
            break
        }
    }

    /// Clears abandoned staging directories from crashed installers. Skips
    /// anything modified recently so an in-flight install is never deleted.
    private static func pruneStaleStagingDirectories() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WallpaperMacUpdate", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            guard modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }
}
