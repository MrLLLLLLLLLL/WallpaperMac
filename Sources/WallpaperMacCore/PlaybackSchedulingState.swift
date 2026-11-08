import Foundation

/// Decides whether a display's queue may schedule or advance playback.
///
/// Queue enablement, the user's playback switch and system suspension are
/// deliberately separate: pausing playback must not turn into a permanent
/// queue stop, and system suspension must not change the saved user intent.
public enum PlaybackDeadlineMath {
    public static func remaining(fireDate: Date, now: Date) -> TimeInterval {
        max(0, fireDate.timeIntervalSince(now))
    }

    public static func interval(full: TimeInterval, remaining: TimeInterval?, resume: Bool) -> TimeInterval {
        resume ? remaining ?? full : full
    }
}

public struct PlaybackSchedulingState: Equatable, Sendable {
    public var isQueueEnabled: Bool
    public var isPlaybackWanted: Bool
    public var isSystemSuspended: Bool
    public var isDisplayConnected: Bool

    public init(
        isQueueEnabled: Bool,
        isPlaybackWanted: Bool,
        isSystemSuspended: Bool,
        isDisplayConnected: Bool
    ) {
        self.isQueueEnabled = isQueueEnabled
        self.isPlaybackWanted = isPlaybackWanted
        self.isSystemSuspended = isSystemSuspended
        self.isDisplayConnected = isDisplayConnected
    }

    public var shouldSchedule: Bool {
        isQueueEnabled && isPlaybackWanted && !isSystemSuspended && isDisplayConnected
    }

    /// Timer, completion, watchdog and hard-deadline callbacks all use the
    /// same gate so no callback can advance a paused queue.
    public var shouldAdvance: Bool { shouldSchedule }
}
