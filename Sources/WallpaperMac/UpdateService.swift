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

    /// Groups update failures so the UI can tell a retryable download problem
    /// apart from a verification or install failure.
    enum FailureKind: Equatable {
        case network
        case verification
        case install
        case other

        var canRetryDownload: Bool {
            self != .install
        }
    }

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate(String)
        case available(AvailableUpdate)
        case downloading(AvailableUpdate, UpdateDownloadProgress?)
        case installing(AvailableUpdate)
        case failed(FailureKind, String)
    }

    @Published private(set) var phase: Phase = .idle

    /// The update most recently approved for download. Kept after a failure so
    /// "retry download" can resume the install flow without re-checking.
    private(set) var retryUpdate: AvailableUpdate?

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

    /// True when the current failure came from the download path and the same
    /// update can be tried again without a network round-trip to GitHub.
    var canRetryDownload: Bool {
        guard retryUpdate != nil, !isBusy else { return false }
        if case .failed(let kind, _) = phase {
            return kind.canRetryDownload
        }
        return false
    }

    func checkForUpdates(userInitiated: Bool) {
        guard !isBusy else { return }
        phase = .checking
        retryUpdate = nil
        let currentVersion = ApplicationVersionInfo(
            infoDictionary: Bundle.main.infoDictionary ?? [:],
            fallbackVersion: "0.2.7"
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
                self.phase = userInitiated
                    ? .failed(Self.failureKind(for: error), error.localizedDescription)
                    : .idle
            }
        }
    }

    func installUpdate(_ update: AvailableUpdate) {
        guard !isBusy else { return }
        retryUpdate = update
        startInstall(update)
    }

    /// Retries the last approved update's download without running the GitHub
    /// release check again.
    func retryDownload() {
        guard canRetryDownload, let update = retryUpdate else { return }
        startInstall(update)
    }

    private func startInstall(_ update: AvailableUpdate) {
        // A process can outlive the bundle it was launched from (for example
        // after installing the DMG over a running copy). Compare against the
        // version on disk before downloading or replacing anything, so a
        // stale in-memory version cannot trigger a same-version swap.
        if let diskVersion = UpdateInstaller.installedVersion(at: Bundle.main.bundleURL),
           !UpdateInstaller.shouldInstall(updateVersion: update.version, installedVersion: diskVersion) {
            phase = .upToDate(diskVersion)
            return
        }
        phase = .downloading(update, nil)

        let stagingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WallpaperMacUpdate", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                try UpdateInstaller.preflight()
                // Hold the target lock across download, prepare and the
                // detached helper handoff. Another app instance must not
                // prune or replace the same target concurrently.
                let installLock = try UpdateInstallLock(targetAppURL: Bundle.main.bundleURL)
                Self.pruneStaleStagingDirectories()

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
                try UpdateInstaller.launchDetachedInstall(of: prepared, installLock: installLock)
                await MainActor.run {
                    NSApp.terminate(nil)
                }
            } catch {
                // Hard failure: remove the attempt's staging directory so no
                // partially downloaded or extracted update lingers.
                try? FileManager.default.removeItem(at: stagingDirectory)
                await MainActor.run {
                    self.retryUpdate = update
                    self.phase = .failed(Self.failureKind(for: error), error.localizedDescription)
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

    private static func failureKind(for error: Error) -> FailureKind {
        if error is UpdateInstallError {
            return .install
        }
        if let downloadError = error as? UpdateDownloadError {
            switch downloadError {
            case .network, .httpStatus, .stalled:
                return .network
            case .checksumsUnavailable, .checksumMissingForAsset,
                 .checksumMismatch, .signatureMissing, .signatureInvalid:
                return .verification
            case .writeFailed:
                return .other
            }
        }
        if error is UpdateCheckError {
            return .network
        }
        return .other
    }

    /// Clears abandoned staging directories from crashed installers. Skips
    /// anything modified recently so an in-flight install is never deleted.
    private nonisolated static func pruneStaleStagingDirectories() {
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
