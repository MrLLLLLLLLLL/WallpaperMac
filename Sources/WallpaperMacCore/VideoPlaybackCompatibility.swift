import Foundation

/// Central policy for choosing between direct AVFoundation playback and a
/// streaming compatibility playback path.
public enum VideoPlaybackCompatibility {
    public static let preferredForwardBufferSeconds: Double = 2

    private static let conversionRequiredCodecs: Set<String> = [
        "av01",
        "av1",
        "vp09",
        "vp9"
    ]

    public static func requiresConversion(
        codec: String?,
        isPlayable: Bool
    ) -> Bool {
        if let codec {
            let normalized = codec.lowercased()
            if conversionRequiredCodecs.contains(normalized) {
                return true
            }
        }
        return !isPlayable
    }
}


public struct VideoCompatibilityStreamPlan: Equatable, Sendable {
    public let sourceURL: URL
    public let width: Int
    public let height: Int
    public let frameRate: Int
    public let arguments: [String]

    public init(
        sourceURL: URL,
        width: Int = 1920,
        height: Int = 1080,
        frameRate: Int = 30
    ) {
        let safeWidth = max(2, width - (width % 2))
        let safeHeight = max(2, height - (height % 2))
        let safeFrameRate = max(1, frameRate)
        self.sourceURL = sourceURL
        self.width = safeWidth
        self.height = safeHeight
        self.frameRate = safeFrameRate
        self.arguments = [
            "-nostdin",
            "-hide_banner",
            "-loglevel", "error",
            "-i", sourceURL.path,
            "-map", "0:v:0",
            "-an",
            "-sn",
            "-dn",
            "-vf", "scale=\(safeWidth):\(safeHeight):force_original_aspect_ratio=decrease,pad=\(safeWidth):\(safeHeight):(ow-iw)/2:(oh-ih)/2:black,fps=\(safeFrameRate)",
            "-f", "rawvideo",
            "-pix_fmt", "nv12",
            "pipe:1"
        ]
    }
}
