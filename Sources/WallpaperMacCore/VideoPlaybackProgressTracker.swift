import Foundation

public struct VideoPlaybackProgress: Equatable, Sendable {
    public let advanced: Bool
    public let durationSeconds: Double?
    public let durationChanged: Bool
}

/// Tracks real playback progress, not timer callbacks. A healthy player must
/// move currentTime forward; paused/suspended samples reset the clock baseline
/// so resume does not count time spent paused as playback progress.
public struct VideoPlaybackProgressTracker: Equatable, Sendable {
    private var lastTimeSeconds: Double?
    public private(set) var durationSeconds: Double?

    public init() {}

    public mutating func resetClock() {
        lastTimeSeconds = nil
    }

    public mutating func sample(currentTime: Double, duration: Double?) -> VideoPlaybackProgress {
        let normalizedDuration = normalized(duration)
        let durationChanged = normalizedDuration != nil && normalizedDuration != durationSeconds
        if let normalizedDuration {
            durationSeconds = normalizedDuration
        }

        guard currentTime.isFinite, currentTime >= 0 else {
            resetClock()
            return VideoPlaybackProgress(
                advanced: false,
                durationSeconds: durationSeconds,
                durationChanged: durationChanged
            )
        }
        let advanced = lastTimeSeconds.map { currentTime > $0 + 0.000_001 } ?? false
        lastTimeSeconds = currentTime
        return VideoPlaybackProgress(
            advanced: advanced,
            durationSeconds: durationSeconds,
            durationChanged: durationChanged
        )
    }

    private func normalized(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }
}
