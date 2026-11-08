import Foundation

/// Shared eligibility policy for library lists and queue playback. Hidden
/// wallpapers stay in the library and in queue membership; they are simply
/// not eligible while the hidden-wallpaper switch is locked.
public enum WallpaperVisibility {
    public static func isEligible(_ item: WallpaperItem?, showsHidden: Bool) -> Bool {
        guard let item else { return false }
        return item.availability == .available && (showsHidden || !item.isHidden)
    }

    public static func eligibleIndices(
        in queue: PlaybackQueue,
        items: [UUID: WallpaperItem],
        showsHidden: Bool
    ) -> [Int] {
        queue.wallpaperIDs.indices.filter { index in
            isEligible(items[queue.wallpaperIDs[index]], showsHidden: showsHidden)
        }
    }
}
