import Foundation

/// Grid metrics derived from the visible library viewport. Tile width stays
/// fixed as the viewport grows; only the number of columns and rows (and
/// therefore the page capacity) changes.
public struct WallpaperLibraryGridLayout: Equatable, Sendable {
    public let columns: Int
    public let rows: Int
    public let tileWidth: Double
    public let tileHeight: Double
    public let horizontalSpacing: Double
    public let verticalSpacing: Double
    public let pageSize: Int

    public init(
        columns: Int,
        rows: Int,
        tileWidth: Double,
        tileHeight: Double,
        horizontalSpacing: Double,
        verticalSpacing: Double
    ) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        self.tileWidth = max(0, tileWidth)
        self.tileHeight = max(0, tileHeight)
        self.horizontalSpacing = max(0, horizontalSpacing)
        self.verticalSpacing = max(0, verticalSpacing)
        self.pageSize = self.columns * self.rows
    }
}

/// Computes how many wallpaper cards fit in the visible library area.
///
/// Cards keep one fixed width. A wider viewport adds columns instead of
/// stretching existing cards, and leftover width becomes extra column
/// spacing; when only one column fits it is centered. The list layout uses
/// one fixed-height row per wallpaper.
public enum WallpaperLibraryPageLayout {
    public static let gridTileWidth: Double = 190
    public static let gridHorizontalSpacing: Double = 16
    public static let gridVerticalSpacing: Double = 18
    public static let contentPadding: Double = 24

    /// Gap between the 16:9 preview and the fixed-height text block.
    public static let cardTextSpacing: Double = 9
    /// Reserved space for a two-line name and one metadata line. Reserving it
    /// keeps every card the same height so page capacity is deterministic.
    public static let cardTextHeight: Double = 56
    public static var cardChromeHeight: Double { cardTextSpacing + cardTextHeight }

    public static let listRowHeight: Double = 76
    public static let listVerticalPadding: Double = 12

    public static func grid(
        availableWidth: Double,
        availableHeight: Double,
        tileWidth: Double = gridTileWidth,
        horizontalSpacing: Double = gridHorizontalSpacing,
        verticalSpacing: Double = gridVerticalSpacing,
        contentPadding: Double = contentPadding
    ) -> WallpaperLibraryGridLayout {
        let usableWidth = max(0, availableWidth - contentPadding * 2)
        let usableHeight = max(0, availableHeight - contentPadding * 2)
        let preferredWidth = max(1, tileWidth)
        let baseColumnSpacing = max(0, horizontalSpacing)
        let rowSpacing = max(0, verticalSpacing)

        let columns = max(
            1,
            Int(floor((usableWidth + baseColumnSpacing) / (preferredWidth + baseColumnSpacing)))
        )
        // A single column may be narrower than the preferred width on very
        // narrow windows; otherwise every card keeps the preferred width.
        let actualTileWidth = columns == 1 ? min(preferredWidth, usableWidth) : preferredWidth
        let cardHeight = actualTileWidth / WallpaperPreviewLayout.aspectRatio + cardChromeHeight
        let gridWidth =
            actualTileWidth * Double(columns) + baseColumnSpacing * Double(columns - 1)
        let leftoverWidth = max(0, usableWidth - gridWidth)
        let columnSpacing =
            columns > 1
                ? baseColumnSpacing + leftoverWidth / Double(columns - 1)
                : baseColumnSpacing

        let rows = max(
            1,
            Int(floor((usableHeight + rowSpacing) / (cardHeight + rowSpacing)))
        )
        return WallpaperLibraryGridLayout(
            columns: columns,
            rows: rows,
            tileWidth: actualTileWidth,
            tileHeight: cardHeight,
            horizontalSpacing: columnSpacing,
            verticalSpacing: rowSpacing
        )
    }

    public static func listPageSize(
        availableHeight: Double,
        rowHeight: Double = listRowHeight,
        verticalPadding: Double = listVerticalPadding
    ) -> Int {
        let usableHeight = max(0, availableHeight - verticalPadding * 2)
        let safeRowHeight = max(1, rowHeight)
        return max(1, Int(floor(usableHeight / safeRowHeight)))
    }
}
