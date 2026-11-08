import Foundation
import CoreGraphics

public struct WallpaperTileGrid: Equatable, Sendable {
    public let columns: Int
    public let rows: Int
    public let tileSize: CGSize

    public init(columns: Int, rows: Int, tileSize: CGSize) {
        self.columns = columns
        self.rows = rows
        self.tileSize = tileSize
    }
}

public enum WallpaperTileLayout {
    /// One tile keeps the source's native dimensions. A very small source can
    /// otherwise request millions of replicated instances, so cap the grid at
    /// a bounded number and let the caller use a non-tiled fallback.
    public static let maximumTileCount = 65536

    public static func grid(
        originalSize: CGSize,
        bounds: CGSize,
        maximumTiles: Int = maximumTileCount,
        contentScale: CGFloat = 1
    ) -> WallpaperTileGrid? {
        guard originalSize.width.isFinite,
              originalSize.height.isFinite,
              bounds.width.isFinite,
              bounds.height.isFinite,
              originalSize.width > 0,
              originalSize.height > 0,
              bounds.width > 0,
              bounds.height > 0 else { return nil }
        let scale = max(1, contentScale)
        let tileWidth = originalSize.width / scale
        let tileHeight = originalSize.height / scale
        let columnCount = ceil(bounds.width / tileWidth)
        let rowCount = ceil(bounds.height / tileHeight)
        // Check the Double values before converting to Int. A tiny but valid
        // source size can otherwise overflow the integer conversion and trap.
        guard columnCount.isFinite, rowCount.isFinite,
              columnCount >= 1, rowCount >= 1,
              columnCount <= Double(maximumTiles), rowCount <= Double(maximumTiles) else {
            return nil
        }
        let columns = Int(columnCount)
        let rows = Int(rowCount)
        guard columns <= maximumTiles, rows <= maximumTiles, columns * rows <= maximumTiles else {
            return nil
        }
        return WallpaperTileGrid(
            columns: columns,
            rows: rows,
            tileSize: CGSize(width: tileWidth, height: tileHeight)
        )
    }
}
