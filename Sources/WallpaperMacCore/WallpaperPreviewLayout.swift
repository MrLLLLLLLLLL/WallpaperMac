import Foundation

/// Shared layout contract for wallpaper thumbnails and the resource inspector.
/// The preview frame remains 16:9, while portrait resources are fitted inside
/// the frame so their full composition stays visible with black side bars.
public enum WallpaperPreviewContentMode: String, Codable, Equatable, Sendable {
    case fit
}

public enum WallpaperPreviewLayout {
    public static let aspectRatio: Double = 16.0 / 9.0
    public static let contentMode: WallpaperPreviewContentMode = .fit

    public static func height(forWidth width: Double) -> Double {
        max(0, width) / aspectRatio
    }
}

public enum WallpaperLibraryPagination {
    public static let defaultPageSize = 20

    public static func pageCount(totalCount: Int, pageSize: Int = defaultPageSize) -> Int {
        guard totalCount > 0 else { return 0 }
        let safePageSize = max(1, pageSize)
        return (totalCount + safePageSize - 1) / safePageSize
    }

    public static func normalizedPage(
        _ pageNumber: Int,
        totalCount: Int,
        pageSize: Int = defaultPageSize
    ) -> Int {
        let totalPages = pageCount(totalCount: totalCount, pageSize: pageSize)
        guard totalPages > 0 else { return 1 }
        return min(max(1, pageNumber), totalPages)
    }

    public static func page<Item>(
        from items: [Item],
        pageNumber: Int,
        pageSize: Int = defaultPageSize
    ) -> [Item] {
        guard !items.isEmpty else { return [] }
        let safePageSize = max(1, pageSize)
        let safePage = normalizedPage(pageNumber, totalCount: items.count, pageSize: safePageSize)
        let startIndex = (safePage - 1) * safePageSize
        let endIndex = min(startIndex + safePageSize, items.count)
        return Array(items[startIndex..<endIndex])
    }
}
