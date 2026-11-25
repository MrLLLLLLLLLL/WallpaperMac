import Foundation

/// Update automation preferences kept separate from UI storage so scheduling
/// and auto-install decisions can be tested without an app or network.
public struct UpdateAutomationPreferences: Equatable, Sendable {
    public var dailyCheckEnabled: Bool
    public var automaticInstallEnabled: Bool

    public init(dailyCheckEnabled: Bool = true, automaticInstallEnabled: Bool = false) {
        self.dailyCheckEnabled = dailyCheckEnabled
        self.automaticInstallEnabled = automaticInstallEnabled
    }

    public var shouldScheduleDailyCheck: Bool {
        dailyCheckEnabled
    }

    /// Automatic installation is intentionally subordinate to daily checks:
    /// disabling checks must also stop unattended installs.
    public var shouldInstallAutomatically: Bool {
        dailyCheckEnabled && automaticInstallEnabled
    }

    public func shouldCheck(
        now: Date,
        lastCheck: Date?,
        lastAutomaticAttempt: Date? = nil,
        isBusy: Bool = false,
        interval: TimeInterval = 24 * 60 * 60
    ) -> Bool {
        guard shouldScheduleDailyCheck, !isBusy else { return false }
        let latestActivity = [lastCheck, lastAutomaticAttempt]
            .compactMap { $0 }
            .max()
        guard let latestActivity else { return true }
        let elapsed = now.timeIntervalSince(latestActivity)
        // A clock adjustment into the past must not suppress checks forever.
        return elapsed < 0 || elapsed >= interval
    }
}
