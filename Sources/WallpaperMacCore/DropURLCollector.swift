import Foundation

/// Collects one URL per dropped `NSItemProvider`, preserving the provider
/// order the user dragged in. Providers complete on arbitrary queues and in
/// arbitrary order, so slots are filled under a lock and drained once.
public final class DropURLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var urlsByIndex: [Int: URL] = [:]
    private var answeredIndices = Set<Int>()
    private var drained = false
    private let total: Int

    public init(providerCount: Int) {
        total = max(0, providerCount)
    }

    /// Records a provider result. The first answer per slot wins; `nil` marks
    /// a provider that failed or produced nothing.
    public func submit(_ url: URL?, at index: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard !answeredIndices.contains(index) else { return }
        answeredIndices.insert(index)
        if let url {
            urlsByIndex[index] = url
        }
    }

    /// Returns the ordered URL list exactly once, when every provider answered.
    public func drain() -> [URL]? {
        lock.lock()
        defer { lock.unlock() }
        guard !drained, total > 0, answeredIndices.count == total else { return nil }
        drained = true
        var ordered = (0..<total).compactMap { urlsByIndex[$0] }
        var seen = Set<URL>()
        ordered = ordered.filter { seen.insert($0).inserted }
        return ordered
    }
}

