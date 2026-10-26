import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import WallpaperMacCore

/// Streams decoded video frames directly from ffmpeg into an
/// `AVSampleBufferDisplayLayer`. The display layer requests frames only when
/// it is ready, so long videos cannot accumulate an unbounded frame queue.
final class WallpaperVideoStreamController {
    let displayLayer = AVSampleBufferDisplayLayer()

    private let sourceURL: URL
    private let loops: Bool
    private let onVideoPlaybackCompleted: (() -> Void)?
    private let frameRate: Int
    private let width: Int
    private let height: Int
    private let frameSize: Int
    private let frameQueue = DispatchQueue(
        label: "com.wallpaper.mac.video-stream-frames",
        qos: .userInitiated
    )
    private let stateLock = NSLock()
    private var isPlaying: Bool
    private var isTornDown = false
    private var isRequestingFrames = false
    private var process: Process?
    private var outputHandle: FileHandle?
    private var bufferedData = Data()
    private var frameIndex: Int64 = 0
    private var formatDescription: CMVideoFormatDescription?

    init(
        sourceURL: URL,
        isPlaying: Bool,
        videoGravity: AVLayerVideoGravity,
        loops: Bool,
        frame: CGRect,
        onVideoPlaybackCompleted: (() -> Void)?
    ) {
        let plan = VideoCompatibilityStreamPlan(sourceURL: sourceURL)
        self.sourceURL = sourceURL
        self.isPlaying = isPlaying
        self.loops = loops
        self.onVideoPlaybackCompleted = onVideoPlaybackCompleted
        self.frameRate = plan.frameRate
        self.width = plan.width
        self.height = plan.height
        self.frameSize = plan.width * plan.height * 3 / 2
        displayLayer.frame = frame
        displayLayer.videoGravity = videoGravity
    }

    func start() {
        startProcess()
    }

    func setFrame(_ frame: CGRect) {
        displayLayer.frame = frame
    }

    func setVideoGravity(_ videoGravity: AVLayerVideoGravity) {
        displayLayer.videoGravity = videoGravity
    }

    func setPlaying(_ isPlaying: Bool) {
        stateLock.lock()
        self.isPlaying = isPlaying
        if !isPlaying {
            isRequestingFrames = false
        }
        stateLock.unlock()

        if isPlaying {
            frameQueue.async { [weak self] in
                self?.startRequestingFrames()
            }
        } else {
            displayLayer.stopRequestingMediaData()
        }
    }

    func teardown() {
        stateLock.lock()
        isTornDown = true
        isPlaying = false
        isRequestingFrames = false
        let process = self.process
        let handle = self.outputHandle
        self.process = nil
        self.outputHandle = nil
        bufferedData.removeAll(keepingCapacity: true)
        stateLock.unlock()

        handle?.readabilityHandler = nil
        try? handle?.close()
        if let process, process.isRunning {
            process.terminate()
        }
        displayLayer.stopRequestingMediaData()
        displayLayer.flushAndRemoveImage()
        displayLayer.removeFromSuperlayer()
    }

    private func startProcess() {
        guard let executableURL = WallpaperVideoCompatibilityService.executableURL() else {
            NSLog("WallpaperMac streaming playback failed: ffmpeg unavailable for \(sourceURL.path)")
            return
        }

        let plan = VideoCompatibilityStreamPlan(sourceURL: sourceURL)
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executableURL
        process.arguments = plan.arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] terminatedProcess in
            self?.processDidTerminate(terminatedProcess)
        }

        stateLock.lock()
        guard !isTornDown else {
            stateLock.unlock()
            return
        }
        self.process = process
        self.outputHandle = pipe.fileHandleForReading
        bufferedData.removeAll(keepingCapacity: true)
        frameIndex = 0
        stateLock.unlock()

        do {
            try process.run()
        } catch {
            NSLog("WallpaperMac streaming playback failed to start ffmpeg: \(error.localizedDescription)")
            stateLock.lock()
            self.process = nil
            self.outputHandle = nil
            stateLock.unlock()
            return
        }
        frameQueue.async { [weak self] in
            self?.startRequestingFrames()
        }
    }

    private func startRequestingFrames() {
        stateLock.lock()
        let shouldRequest = !isTornDown && isPlaying && !isRequestingFrames
        if shouldRequest {
            isRequestingFrames = true
        }
        stateLock.unlock()
        guard shouldRequest else { return }

        displayLayer.requestMediaDataWhenReady(on: frameQueue) { [weak self] in
            self?.produceFrames()
        }
    }

    private func produceFrames() {
        while true {
            stateLock.lock()
            let cancelled = isTornDown
            let playing = isPlaying
            stateLock.unlock()
            guard !cancelled else { return }
            guard playing else {
                stopRequestingFrames()
                return
            }
            guard displayLayer.isReadyForMoreMediaData else { return }
            guard let frame = readFrame() else {
                stopRequestingFrames()
                return
            }
            let presentationIndex = frameIndex
            frameIndex += 1
            enqueue(frame, presentationIndex: presentationIndex)
        }
    }

    private func stopRequestingFrames() {
        stateLock.lock()
        isRequestingFrames = false
        stateLock.unlock()
        displayLayer.stopRequestingMediaData()
    }

    private func processDidTerminate(_ terminatedProcess: Process) {
        stateLock.lock()
        guard self.process === terminatedProcess else {
            stateLock.unlock()
            return
        }
        self.process = nil
        self.outputHandle = nil
        bufferedData.removeAll(keepingCapacity: true)
        isRequestingFrames = false
        let cancelled = isTornDown
        stateLock.unlock()

        displayLayer.stopRequestingMediaData()
        guard !cancelled else { return }
        if loops {
            startProcess()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.onVideoPlaybackCompleted?()
            }
        }
    }

    private func readFrame() -> Data? {
        stateLock.lock()
        let handle = outputHandle
        stateLock.unlock()
        guard let handle else { return nil }
        while true {
            stateLock.lock()
            let needed = frameSize - bufferedData.count
            stateLock.unlock()
            guard needed > 0 else { break }
            do {
                let chunk = try handle.read(upToCount: needed) ?? Data()
                if chunk.isEmpty {
                    return nil
                }
                stateLock.lock()
                bufferedData.append(chunk)
                stateLock.unlock()
            } catch {
                return nil
            }
        }

        stateLock.lock()
        let frame = Data(bufferedData.prefix(frameSize))
        bufferedData.removeSubrange(0..<frameSize)
        stateLock.unlock()
        return frame
    }

    private func enqueue(_ data: Data, presentationIndex: Int64) {
        stateLock.lock()
        let cancelled = isTornDown
        stateLock.unlock()
        guard !cancelled else { return }

        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard let pixelBuffer else { return }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        data.withUnsafeBytes { rawBuffer in
            guard let source = rawBuffer.baseAddress else { return }
            if let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
                let yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
                for row in 0..<height {
                    memcpy(
                        yBase.advanced(by: row * yBytesPerRow),
                        source.advanced(by: row * width),
                        width
                    )
                }
            }
            let uvOffset = width * height
            if let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) {
                let uvBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
                for row in 0..<(height / 2) {
                    memcpy(
                        uvBase.advanced(by: row * uvBytesPerRow),
                        source.advanced(by: uvOffset + row * width),
                        width
                    )
                }
            }
        }

        if formatDescription == nil {
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &formatDescription
            )
        }
        guard let formatDescription else { return }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(frameRate)),
            presentationTimeStamp: CMTime(value: presentationIndex, timescale: CMTimeScale(frameRate)),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        if let sampleBuffer {
            displayLayer.enqueue(sampleBuffer)
        }
    }
}
