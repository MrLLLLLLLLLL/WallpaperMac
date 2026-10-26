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
    private static let minimumSampleEntrySize: UInt64 = 86

    private struct BoxDescriptor {
        let offset: UInt64
        let type: String
        let payloadOffset: UInt64
        let endOffset: UInt64
    }

    /// Returns whether the MP4 structure contains a real `hev1` sample entry.
    /// Random `hev1` bytes in `mdat` media payloads are deliberately ignored.
    public static func needsHVC1Normalization(
        at url: URL,
        fileManager: FileManager = .default
    ) throws -> Bool {
        guard fileManager.isReadableFile(atPath: url.path) else { return false }
        return try hev1Positions(in: url, fileManager: fileManager).isEmpty == false
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

        return try positions(
            in: handle,
            range: 0..<fileSize,
            fileSize: fileSize,
            searchingSampleEntriesOnly: false
        )
    }

    /// Parses only MP4 box boundaries. The media payload in `mdat` is never
    /// scanned, preventing byte sequences inside compressed video data from
    /// being mistaken for sample-entry headers.
    private static func positions(
        in handle: FileHandle,
        range: Range<UInt64>,
        fileSize: UInt64,
        searchingSampleEntriesOnly: Bool
    ) throws -> [UInt64] {
        var results: [UInt64] = []
        var offset = range.lowerBound
        while offset + 8 <= range.upperBound {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 8), header.count == 8 else { break }
            let box = try descriptor(handle: handle, header: header, offset: offset, range: range, fileSize: fileSize)
            guard let box else { break }

            if box.type == "stsd" {
                let sampleEntryStart = min(box.payloadOffset + 8, box.endOffset)
                guard sampleEntryStart < box.endOffset else {
                    offset = box.endOffset
                    continue
                }
                let entries = try positions(
                    in: handle,
                    range: sampleEntryStart..<box.endOffset,
                    fileSize: fileSize,
                    searchingSampleEntriesOnly: true
                )
                results.append(contentsOf: entries)
            } else if searchingSampleEntriesOnly {
                if box.type == "hev1", box.endOffset - box.offset >= minimumSampleEntrySize {
                    results.append(box.offset + 4)
                }
            } else if ["moov", "trak", "mdia", "minf", "stbl"].contains(box.type) {
                let nested = try positions(
                    in: handle,
                    range: box.payloadOffset..<box.endOffset,
                    fileSize: fileSize,
                    searchingSampleEntriesOnly: false
                )
                results.append(contentsOf: nested)
            }

            guard box.endOffset > offset else { break }
            offset = box.endOffset
        }
        return results
    }

    private static func descriptor(
        handle: FileHandle,
        header: Data,
        offset: UInt64,
        range: Range<UInt64>,
        fileSize: UInt64
    ) throws -> BoxDescriptor? {
        let size32 = readUInt32(header, at: 0)
        guard let type = String(data: header.subdata(in: 4..<8), encoding: .ascii) else {
            return nil
        }

        var boxSize = UInt64(size32)
        var headerSize: UInt64 = 8
        if size32 == 1 {
            try handle.seek(toOffset: offset + 8)
            guard let extendedBytes = try handle.read(upToCount: 8), extendedBytes.count == 8 else {
                return nil
            }
            boxSize = extendedBytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            headerSize = 16
        }

        guard boxSize >= headerSize else { return nil }
        let endOffset = min(offset + boxSize, range.upperBound)
        guard endOffset > offset, endOffset <= fileSize else { return nil }
        return BoxDescriptor(
            offset: offset,
            type: type,
            payloadOffset: offset + headerSize,
            endOffset: endOffset
        )
    }

    private static func readUInt32(_ data: Data, at index: Int) -> UInt32 {
        UInt32(data[index]) << 24
            | UInt32(data[index + 1]) << 16
            | UInt32(data[index + 2]) << 8
            | UInt32(data[index + 3])
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
        _ = try fileManager.replaceItemAt(
            originalURL,
            withItemAt: temporaryURL,
            backupItemName: nil,
            options: .usingNewMetadataOnly
        )
    }
}
