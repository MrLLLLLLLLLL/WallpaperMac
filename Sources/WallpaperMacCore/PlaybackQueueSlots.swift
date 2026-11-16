import Foundation

/// A queue's type is derived from its current members. A queue becomes a
/// hidden queue as soon as it contains a hidden wallpaper, and returns to a
/// normal queue when the last hidden member is removed.
public enum PlaybackQueueKind: String, Codable, CaseIterable, Equatable, Sendable {
    case normal
    case hidden

    public var title: String {
        switch self {
        case .normal: return "默认"
        case .hidden: return "隐藏"
        }
    }
}

public extension PlaybackQueue {
    func kind(items: [UUID: WallpaperItem]) -> PlaybackQueueKind {
        wallpaperIDs.contains { items[$0]?.isHidden == true } ? .hidden : .normal
    }
}

/// Resolves a display's queue slot. An empty or mismatched slot is treated as
/// empty rather than silently playing another queue.
public enum QueueSlotResolver {
    public static func resolve(
        queueID: UUID?,
        expected kind: PlaybackQueueKind,
        queues: [UUID: PlaybackQueue],
        items: [UUID: WallpaperItem]
    ) -> UUID? {
        guard let queueID, let queue = queues[queueID], queue.kind(items: items) == kind else {
            return nil
        }
        return queueID
    }
}
