import Foundation

/// Repairs the HEVC sample-entry tag used by some downloaded MP4 files.
///
/// `hev1` and `hvc1` use the same sample-entry layout, but AVFoundation on
/// some macOS/decoder combinations only accepts the latter for local playback.
/// The operation changes only the four-byte sample-entry type; it does not
/// decode or re-encode the video stream.
public enum VideoContainerCompatibility {
    private static let hev1 = Data("hev1".utf8)
    private static let hvc1 = Data("hvc1".utf8)
    private static let scanChunkSize = 1024 * 1024
    private static let minimumSampleEntrySize: UInt64 = 86

    /// Returns whether the file contains a plausible MP4 `hev1` sample entry.
    public static func needsHVC1Normalization(
        at url: URL,
        fileManager: FileManager = .default
    ) throws -> Bool {
        guard fileManager.isReadableFile(atPath: url.path) else { return false }
        let positions = try hev1Positions(in: url, fileManager: fileManager)
        return !positions.isEmpty
    }

    /// Rewrites `hev1` sample-entry tags in place. Returns `true` when a tag
    /// was changed. The source file is replaced atomically through a temporary
    /// sibling, so a failed operation leaves the original untouched.
    @discardableResult
    public static func normalizeHVC1InPlace(
        at url: URL,
        fileManager: FileManager = .default
    ) throws -> Bool {
        let positions = try hev1Positions(in: url, fileManager: fileManager)
        guard !positions.isEmpty else { return false }

        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".wallpapermac-normalize-\(UUID().uuidString).tmp")
        do {
            try fileManager.copyItem(at: url, to: temporaryURL)
            try patch(positions: positions, in: temporaryURL)
            try replaceItem(at: url, with: temporaryURL, fileManager: fileManager)
            return true
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    /// Copies a video and rewrites its `hev1` sample-entry tags in the copy.
    /// The original source is never modified. If no normalization is needed,
    /// the source is copied unchanged and the method returns `false`.
    @discardableResult
    public static func copyNormalizedVideo(
        from sourceURL: URL,
        to destinationURL: URL,
        fileManager: FileManager = .default
    ) throws -> Bool {
        let positions = try hev1Positions(in: sourceURL, fileManager: fileManager)
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        guard !positions.isEmpty else { return false }
        do {
            try patch(positions: positions, in: destinationURL)
            return true
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
    }

    private static func hev1Positions(
        in url: URL,
        fileManager: FileManager
    ) throws -> [UInt64] {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let sizeNumber = attributes[.size] as? NSNumber else {
            return []
        }
        let fileSize = sizeNumber.uint64Value
        guard fileSize >= minimumSampleEntrySize else { return [] }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        var positions: [UInt64] = []
        var window = Data()
        var windowStart: UInt64 = 0
        while let chunk = try handle.read(upToCount: scanChunkSize), !chunk.isEmpty {
            window.append(chunk)
            let bytes = [UInt8](window)
            var cursor = 0
            while cursor + hev1.count <= bytes.count {
                guard let match = bytes[cursor...].firstIndex(of: hev1[0]) else { break }
                let start = Int(match)
                guard start + hev1.count <= bytes.count else { break }
                if Data(bytes[start..<(start + hev1.count)]) == hev1 {
                    let absolutePosition = windowStart + UInt64(start)
                    if start >= 4 {
                        let sampleEntrySize = UInt64(bytes[start - 4]) << 24
                            | UInt64(bytes[start - 3]) << 16
                            | UInt64(bytes[start - 2]) << 8
                            | UInt64(bytes[start - 1])
                        if sampleEntrySize >= minimumSampleEntrySize,
                           absolutePosition + sampleEntrySize <= fileSize {
                            positions.append(absolutePosition)
                        }
                    }
                    cursor = start + hev1.count
                } else {
                    cursor = start + 1
                }
            }

            // Keep enough overlap for a four-byte size field and the tag.
            let retainedBytes = 11
            if window.count > retainedBytes {
                let dropCount = window.count - retainedBytes
                window.removeSubrange(0..<dropCount)
                windowStart += UInt64(dropCount)
            }
        }
        return positions
    }

    private static func patch(
        positions: [UInt64],
        in url: URL
    ) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        for position in positions {
            try handle.seek(toOffset: position)
            try handle.write(contentsOf: hvc1)
        }
        try handle.synchronize()
    }

    private static func replaceItem(
        at originalURL: URL,
        with temporaryURL: URL,
        fileManager: FileManager
    ) throws {
        if #available(macOS 10.6, *) {
            _ = try fileManager.replaceItemAt(
                originalURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: .usingNewMetadataOnly
            )
        } else {
            try fileManager.removeItem(at: originalURL)
            try fileManager.moveItem(at: temporaryURL, to: originalURL)
        }
    }
}
