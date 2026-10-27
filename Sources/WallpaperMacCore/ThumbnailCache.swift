import AppKit
import Foundation
import ImageIO

/// Decoded-image cache keyed by path + mtime + size.
///
/// Thumbnail rendering runs inside SwiftUI `body` evaluation; a synchronous
/// `NSImage(contentsOf:)` there stalls the main thread on every grid redraw.
/// This cache turns those reads into one decode per file version.
public final class ThumbnailCache: @unchecked Sendable {
    public static let shared = ThumbnailCache()

    // NSCache evicts under pressure; a parallel "inflight" dict would pin
    // every decoded bitmap for the lifetime of the process.
    private let cache = NSCache<NSString, NSImage>()

    public init(countLimit: Int = 256) {
        cache.countLimit = countLimit
    }

    public func image(at url: URL) -> NSImage? {
        let key = Self.cacheKey(for: url) as NSString
        if let hit = cache.object(forKey: key) {
            return hit
        }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    /// Aspect check without decoding pixels when possible.
    public func isPortrait(at url: URL) -> Bool {
        // ImageIO reads only the header — no full-bitmap decode.
        if let size = ImageDimensions.pixelSize(at: url) {
            return size.height > size.width
        }
        if let cached = image(at: url) {
            return cached.size.height > cached.size.width
        }
        return false
    }

    public func removeAll() {
        cache.removeAllObjects()
    }

    static func cacheKey(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = values?.fileSize ?? 0
        return "\(url.path)|\(mtime)|\(size)"
    }
}

public enum ImageDimensions {
    /// Reads width/height via ImageIO without decoding pixel data.
    public static func pixelSize(at url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        guard let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return (width, height)
    }

    public static func isPortrait(at url: URL) -> Bool {
        guard let size = pixelSize(at: url) else { return false }
        return size.height > size.width
    }
}
