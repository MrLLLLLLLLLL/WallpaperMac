import Foundation

/// Tracks whether the persisted queue files could be loaded.
///
/// A decode/read failure must not be treated as an empty library: the manager
/// builds a fallback in-memory state so the app can still start, but writing
/// that fallback back would destroy the user's only copy. Until a later load
/// succeeds, persistence stays blocked and the load error remains visible.
public struct LibraryPersistenceGate: Equatable, Sendable {
    public private(set) var loadError: String?

    public init() {}

    /// True when writes must not touch the queue files.
    public var blocksPersistence: Bool { loadError != nil }

    public mutating func recordSuccessfulLoad() {
        loadError = nil
    }

    /// Keeps the first failure so the user sees the primary cause when both
    /// queue files fail to decode.
    public mutating func recordLoadFailure(_ message: String) {
        guard loadError == nil else { return }
        loadError = message
    }
}
