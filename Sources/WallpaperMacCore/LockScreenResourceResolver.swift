import Foundation

/// Selects the static image that can represent a wallpaper on the macOS lock
/// screen. Video/web items without a thumbnail need an asynchronous snapshot
/// from the live player instead.
public enum LockScreenResourceResolver {
    public static func existingImageURL(
        for item: WallpaperItem,
        fileManager: FileManager = .default
    ) -> URL? {
        if item.type == .image,
           item.sourceURL.isFileURL,
           fileManager.fileExists(atPath: item.sourceURL.path) {
            return item.sourceURL
        }
        if let thumbnailURL = item.thumbnailURL,
           thumbnailURL.isFileURL,
           fileManager.fileExists(atPath: thumbnailURL.path) {
            return thumbnailURL
        }
        return nil
    }

    public static func snapshotFilename(for item: WallpaperItem) -> String {
        "\(item.id.uuidString).png"
    }
}
