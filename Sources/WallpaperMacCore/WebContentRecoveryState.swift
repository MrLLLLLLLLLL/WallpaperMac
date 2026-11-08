import Foundation

/// Bounded recovery budget for one web playback session. Exponential backoff
/// prevents a crashing page from creating an unbounded reload loop.
public struct WebContentRecoveryState: Equatable, Sendable {
    public let maximumAttempts: Int
    public private(set) var attempts = 0

    public init(maximumAttempts: Int = 3) {
        self.maximumAttempts = max(1, maximumAttempts)
    }

    public var isExhausted: Bool { attempts >= maximumAttempts }

    public mutating func nextDelay(
        isPlaying: Bool,
        isSystemSuspended: Bool
    ) -> TimeInterval? {
        guard isPlaying, !isSystemSuspended, !isExhausted else { return nil }
        attempts += 1
        return TimeInterval(1 << (attempts - 1))
    }

    /// Called only after a page stays healthy for a stability window, not on
    /// every didFinish, so repeated renderer crashes still consume the budget.
    public mutating func markHealthy() {
        attempts = 0
    }

    public mutating func reset() {
        attempts = 0
    }
}
