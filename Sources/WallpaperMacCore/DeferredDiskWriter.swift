import Foundation

/// Coalesces frequent persistence writes (queue advancement, screen changes)
/// off the main actor. Callers snapshot their state on the main actor and hand
/// a write closure; encoding and `Data.write(.atomic)` run on a background
/// task. Writes within the debounce window collapse into one, and a pending
/// write can be flushed synchronously on demand (e.g. before termination).
public actor DeferredDiskWriter {
    private var pendingTask: Task<Void, Never>?
    private var pendingWrite: (() throws -> Void)?
    private let debounce: TimeInterval
    private let onError: @Sendable (Error) -> Void

    public init(debounce: TimeInterval = 0.4, onError: @escaping @Sendable (Error) -> Void = { _ in }) {
        self.debounce = debounce
        self.onError = onError
    }

    /// Schedules a write. The closure captures an immutable snapshot taken on
    /// the caller's actor; later submissions replace earlier pending ones.
    public func schedule(_ write: @escaping () throws -> Void) {
        pendingWrite = write
        pendingTask?.cancel()
        pendingTask = Task { [debounce] in
            try? await Task.sleep(nanoseconds: UInt64(debounce * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self.flush()
        }
    }

    /// Runs any pending write immediately and clears it. Safe to call from the
    /// main actor when a durable flush is required.
    public func flush() {
        pendingTask?.cancel()
        pendingTask = nil
        guard let write = pendingWrite else { return }
        pendingWrite = nil
        do {
            try write()
        } catch {
            onError(error)
        }
    }
}
