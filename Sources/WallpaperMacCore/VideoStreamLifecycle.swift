import Foundation

/// Exit policy for one decoder generation. Only a clean EOF may loop.
/// Decoder failures, signals and launch failures are terminal for that item;
/// callers must not restart them with the same arguments in a tight loop.
public enum VideoStreamExitPolicy {
    public static func shouldRestartAfterDrain(
        terminationStatus: Int32,
        loops: Bool,
        emittedFrameCount: Int,
        hasIncompleteTail: Bool
    ) -> Bool {
        terminationStatus == 0 && loops && emittedFrameCount > 0 && !hasIncompleteTail
    }
}

/// Byte accumulator for fixed-size raw video frames. All reads and removals
/// happen on the stream's serial frame queue, so a frame is emitted only when
/// every byte is present; an incomplete tail is never sliced by accident.
public struct VideoFrameBuffer: Equatable, Sendable {
    public let frameSize: Int
    private var data = Data()

    public init(frameSize: Int) {
        precondition(frameSize > 0)
        self.frameSize = frameSize
    }

    public var count: Int { data.count }
    public var isEmpty: Bool { data.isEmpty }

    public mutating func append(_ chunk: Data) {
        data.append(chunk)
    }

    public mutating func nextFrame() -> Data? {
        guard data.count >= frameSize else { return nil }
        let frame = data.prefix(frameSize)
        data.removeSubrange(0..<frameSize)
        return Data(frame)
    }

    public mutating func removeAll() {
        data.removeAll(keepingCapacity: true)
    }
}
