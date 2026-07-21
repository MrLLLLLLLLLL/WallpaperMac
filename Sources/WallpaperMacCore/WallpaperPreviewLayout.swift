import Foundation

/// Shared layout contract for wallpaper thumbnails and the resource inspector.
/// The preview frame is intentionally landscape so portrait and square assets
/// are cropped consistently instead of changing the surrounding layout.
public enum WallpaperPreviewContentMode: String, Codable, Equatable, Sendable {
    case fill
}

public enum WallpaperPreviewLayout {
    public static let aspectRatio: Double = 16.0 / 9.0
    public static let contentMode: WallpaperPreviewContentMode = .fill

    public static func height(forWidth width: Double) -> Double {
        max(0, width) / aspectRatio
    }
}


public enum WallpaperLibraryPagination {
    public static let defaultPageSize = 48

    public static func page<Item>(from items: [Item], loadedCount: Int, pageSize: Int = defaultPageSize) -> [Item] {
        guard !items.isEmpty else { return [] }
        let safePageSize = max(1, pageSize)
        let count = min(max(safePageSize, loadedCount), items.count)
        return Array(items.prefix(count))
    }

    public static func nextLoadedCount(currentCount: Int, totalCount: Int, pageSize: Int = defaultPageSize) -> Int {
        guard currentCount < totalCount else { return currentCount }
        return min(currentCount + max(1, pageSize), totalCount)
    }
}
