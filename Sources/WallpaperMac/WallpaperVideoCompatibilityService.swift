import Foundation

struct WallpaperVideoCompatibilityService {
    enum ServiceError: Error, LocalizedError {
        case ffmpegUnavailable
        case processFailed(String)
        case thumbnailFailed(String)

        var errorDescription: String? {
            switch self {
            case .ffmpegUnavailable:
                return "未找到用于视频兼容解码的 ffmpeg。"
            case .processFailed(let message):
                return "视频兼容处理失败：\(message)"
            case .thumbnailFailed(let message):
                return "视频封面提取失败：\(message)"
            }
        }
    }

    static func removeLegacyPlaybackCache() {
        let legacyURL: URL
        if let override = ProcessInfo.processInfo.environment["WALLPAPERMAC_CACHE_DIR"],
           !override.isEmpty {
            legacyURL = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            legacyURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent("WallpaperMac", isDirectory: true)
                .appendingPathComponent("VideoPlaybackCache", isDirectory: true)
                ?? FileManager.default.temporaryDirectory
                    .appendingPathComponent("WallpaperMac/VideoPlaybackCache", isDirectory: true)
        }
        try? FileManager.default.removeItem(at: legacyURL)
    }

    static func thumbnailData(
        for sourceURL: URL,
        itemID: UUID
    ) async throws -> Data {
        guard let ffmpegURL = executableURL() else {
            throw ServiceError.ffmpegUnavailable
        }
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WallpaperMac", isDirectory: true)
            .appendingPathComponent("VideoMetadata", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        let outputURL = temporaryDirectory.appendingPathComponent("\(itemID.uuidString)-thumbnail.jpg")
        try? FileManager.default.removeItem(at: outputURL)
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let arguments = [
            "-nostdin",
            "-hide_banner",
            "-loglevel", "error",
            "-y",
            "-ss", "0",
            "-i", sourceURL.path,
            "-map", "0:v:0",
            "-frames:v", "1",
            "-vf", "scale=640:640:force_original_aspect_ratio=decrease",
            "-q:v", "3",
            outputURL.path
        ]
        do {
            _ = try await run(executableURL: ffmpegURL, arguments: arguments)
            return try Data(contentsOf: outputURL)
        } catch {
            throw ServiceError.thumbnailFailed(error.localizedDescription)
        }
    }

    static func executableURL() -> URL? {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["WALLPAPERMAC_FFMPEG"],
           !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("ffmpeg") {
            candidates.append(bundled)
        }
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/ffmpeg"))
        candidates.append(URL(fileURLWithPath: "/usr/bin/ffmpeg"))
        return candidates.first {
            fileManager.isExecutableFile(atPath: $0.path)
        }
    }

    private static func run(
        executableURL: URL,
        arguments: [String]
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let errorPipe = Pipe()
            process.executableURL = executableURL
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errorPipe
            process.terminationHandler = { _ in
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if process.terminationStatus == 0 {
                    continuation.resume(returning: errorData)
                } else {
                    let detail = message.isEmpty ? "退出码 \(process.terminationStatus)" : message
                    continuation.resume(throwing: ServiceError.processFailed(detail))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
