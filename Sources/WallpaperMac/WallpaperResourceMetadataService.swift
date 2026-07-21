import AVFoundation
import AppKit
import CoreGraphics
import ImageIO
import WallpaperMacCore

struct WallpaperResourceMetadataService {
    static func enrich(item: WallpaperItem, libraryURL: URL) async -> WallpaperItem? {
        guard item.availability == .available else { return nil }
        let fileURL = item.type == .web ? (item.entryURL ?? item.sourceURL) : item.sourceURL
        guard FileManager.default.isReadableFile(atPath: fileURL.path) else { return nil }

        var updated = item
        var metadata = item.metadata ?? WallpaperMetadata()
        metadata.fileSizeBytes = fileSize(at: item.sourceURL)
        metadata.fileExtension = fileURL.pathExtension.isEmpty ? nil : fileURL.pathExtension.lowercased()

        switch item.type {
        case .image:
            guard let imageInfo = imageInfo(at: fileURL) else { return nil }
            metadata.pixelWidth = imageInfo.width
            metadata.pixelHeight = imageInfo.height
        case .video:
            guard let videoInfo = await videoInfo(at: fileURL) else { return nil }
            metadata.pixelWidth = videoInfo.width
            metadata.pixelHeight = videoInfo.height
            metadata.durationSeconds = videoInfo.duration
            if item.thumbnailURL == nil || !FileManager.default.fileExists(atPath: item.thumbnailURL!.path) {
                if let thumbnailURL = await makeVideoThumbnail(assetURL: fileURL, itemID: item.id, libraryURL: libraryURL) {
                    updated.thumbnailURL = thumbnailURL
                }
            }
        case .web:
            break
        }

        updated.metadata = metadata
        return updated
    }

    private static func fileSize(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]), let size = values.fileSize else { return nil }
        return Int64(size)
    }

    private static func imageInfo(at url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
        return (width.intValue, height.intValue)
    }

    private static func videoInfo(at url: URL) async -> (width: Int, height: Int, duration: Double)? {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration).seconds
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else { return nil }
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let transformed = CGRect(origin: .zero, size: size).applying(transform)
            return (max(1, Int(abs(transformed.width).rounded())), max(1, Int(abs(transformed.height).rounded())), max(0, duration))
        } catch {
            return nil
        }
    }

    private static func makeVideoThumbnail(assetURL: URL, itemID: UUID, libraryURL: URL) async -> URL? {
        let thumbnailDirectory = libraryURL.appendingPathComponent("Thumbnails", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let destination = thumbnailDirectory.appendingPathComponent("\(itemID.uuidString).jpg")
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        let asset = AVURLAsset(url: assetURL)
        let image: CGImage?
        if let artwork = try? await embeddedArtwork(from: asset) {
            image = artwork
        } else {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 640, height: 640)
            // Prefer the actual first frame. A small offset is a codec-compatible fallback
            // for containers that reject an exact zero timestamp. The generator is local and
            // released immediately after this await to avoid retaining decoder state.
            if let firstFrame = try? await generateImage(generator: generator, at: .zero) {
                image = firstFrame
            } else {
                image = try? await generateImage(
                    generator: generator,
                    at: CMTime(seconds: 0.1, preferredTimescale: 600)
                )
            }
        }
        guard let image else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else { return nil }
        do {
            try data.write(to: destination, options: .atomic)
            return destination
        } catch {
            return nil
        }
    }

    private static func embeddedArtwork(from asset: AVAsset) async throws -> CGImage? {
        let metadata = try await asset.load(.metadata)
        for item in metadata {
            guard item.commonKey?.rawValue == AVMetadataKey.commonKeyArtwork.rawValue,
                  let data = try await item.load(.dataValue),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            return image
        }
        throw MetadataError.artworkUnavailable
    }

    private static func generateImage(generator: AVAssetImageGenerator, at time: CMTime) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, result, error in
                if let image, result == .succeeded {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? MetadataError.thumbnailUnavailable)
                }
            }
        }
    }

    private enum MetadataError: Error {
        case artworkUnavailable
        case thumbnailUnavailable
    }
}
