import AVFoundation
import CoreMedia
import VideoToolbox
import WallpaperMacCore

/// Streams decoded video frames directly from ffmpeg into an
/// `AVSampleBufferDisplayLayer`. The display layer requests frames only when
/// it is ready, so long videos cannot accumulate an unbounded frame queue.
final class WallpaperVideoStreamController {
    let displayLayer = AVSampleBufferDisplayLayer()
    private(set) var presentationLayer: CALayer
    private var tileLayers: [CALayer] = []

    private let sourceURL: URL
    private let streamArguments: [String]
    private let loops: Bool
    private let originalSize: CGSize
    private let contentScale: CGFloat
    private var fitMode: WallpaperFitMode
    private var currentFrame: CGRect
    private let onVideoPlaybackCompleted: (() -> Void)?
    private let onFrameProgress: (() -> Void)?
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
    private var bufferedData: VideoFrameBuffer
    private var generation = 0
    private var terminationStatus: Int32?
    private var completionDeliveredGeneration: Int?
    private var emittedFrameCount = 0
    private var frameIndex: Int64 = 0
    private var formatDescription: CMVideoFormatDescription?
    private var latestTileImage: CGImage?

    init(
        sourceURL: URL,
        isPlaying: Bool,
        loops: Bool,
        frame: CGRect,
        onVideoPlaybackCompleted: (() -> Void)?,
        onFrameProgress: (() -> Void)? = nil,
        fitMode: WallpaperFitMode = .fill,
        originalSize: CGSize? = nil,
        contentScale: CGFloat = 1
    ) {
        let layoutSize = originalSize ?? CGSize(width: 1920, height: 1080)
        // Keep the stream in the source's aspect ratio so tiled playback never
        // embeds the letterbox of a fixed 16:9 canvas. Cap the long side to
        // bound raw-frame bandwidth; the display layer scales for fill/fit.
        let scale = min(1, min(1920 / layoutSize.width, 1080 / layoutSize.height))
        let streamWidth = max(2, Int((layoutSize.width * scale).rounded()))
        let streamHeight = max(2, Int((layoutSize.height * scale).rounded()))
        let plan = VideoCompatibilityStreamPlan(
            sourceURL: sourceURL,
            width: streamWidth,
            height: streamHeight
        )
        self.sourceURL = sourceURL
        self.streamArguments = plan.arguments
        self.isPlaying = isPlaying
        self.loops = loops
        self.onVideoPlaybackCompleted = onVideoPlaybackCompleted
        self.onFrameProgress = onFrameProgress
        self.fitMode = fitMode
        self.originalSize = originalSize ?? CGSize(width: plan.width, height: plan.height)
        self.contentScale = max(1, contentScale)
        self.currentFrame = frame
        self.frameRate = plan.frameRate
        self.width = plan.width
        self.height = plan.height
        self.frameSize = plan.width * plan.height * 3 / 2
        self.bufferedData = VideoFrameBuffer(frameSize: plan.width * plan.height * 3 / 2)
        displayLayer.frame = frame
        presentationLayer = WallpaperLayerLayout.make(
            content: displayLayer,
            originalSize: self.originalSize,
            bounds: frame,
            mode: fitMode,
            contentScale: self.contentScale
        )
    }

    private func rebuildPresentationLayer() {
        let parent = presentationLayer.superlayer
        presentationLayer.removeFromSuperlayer()
        if fitMode == .tile {
            presentationLayer = makeTiledPresentation()
        } else {
            tileLayers.forEach { $0.contents = nil; $0.removeFromSuperlayer() }
            tileLayers.removeAll()
            latestTileImage = nil
            presentationLayer = WallpaperLayerLayout.make(
                content: displayLayer,
                originalSize: originalSize,
                bounds: currentFrame,
                mode: fitMode,
                    contentScale: contentScale
            )
        }
        parent?.addSublayer(presentationLayer)
    }

    private func makeTiledPresentation() -> CALayer {
        tileLayers.forEach { $0.removeFromSuperlayer() }
        tileLayers.removeAll()
        guard let grid = WallpaperTileLayout.grid(
            originalSize: originalSize,
            bounds: currentFrame.size,
            contentScale: contentScale
        ) else {
            return WallpaperLayerLayout.make(
                content: displayLayer,
                originalSize: originalSize,
                bounds: currentFrame,
                mode: .fill,
                    contentScale: contentScale
            )
        }
        let container = CALayer()
        container.frame = currentFrame
        container.masksToBounds = true
        displayLayer.videoGravity = .resizeAspect
        displayLayer.contentsScale = contentScale
        for row in 0..<grid.rows {
            for column in 0..<grid.columns {
                let frame = CGRect(
                    x: CGFloat(column) * grid.tileSize.width,
                    y: CGFloat(row) * grid.tileSize.height,
                    width: grid.tileSize.width,
                    height: grid.tileSize.height
                )
                let layer: CALayer
                if row == 0 && column == 0 {
                    displayLayer.frame = frame
                    layer = displayLayer
                } else {
                    layer = CALayer()
                    layer.frame = frame
                    layer.contentsGravity = .resizeAspect
                    layer.contentsScale = contentScale
                    layer.contents = latestTileImage
                    tileLayers.append(layer)
                }
                container.addSublayer(layer)
            }
        }
        return container
    }

    func start() {
        startProcess()
    }

    func setFrame(_ frame: CGRect) {
        guard currentFrame != frame else { return }
        currentFrame = frame
        stateLock.lock()
        let tiled = fitMode == .tile
        stateLock.unlock()
        if tiled {
            rebuildPresentationLayer()
        } else {
            presentationLayer.frame = frame
        }
    }

    func setFitMode(_ fitMode: WallpaperFitMode) {
        stateLock.lock()
        guard self.fitMode != fitMode else {
            stateLock.unlock()
            return
        }
        self.fitMode = fitMode
        stateLock.unlock()
        rebuildPresentationLayer()
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
        guard !isTornDown else {
            stateLock.unlock()
            return
        }
        isTornDown = true
        isPlaying = false
        isRequestingFrames = false
        generation += 1
        let process = self.process
        let handle = self.outputHandle
        let presentationLayer = self.presentationLayer
        let tileLayers = self.tileLayers
        self.process = nil
        self.outputHandle = nil
        bufferedData.removeAll()
        stateLock.unlock()

        // Order matters: terminate first so the pipe hits EOF and any blocked
        // read() on frameQueue returns. Closing the handle while read is still
        // blocked races FileHandle's own lock and can crash.
        if let process, process.isRunning {
            process.terminate()
        }
        handle?.readabilityHandler = nil
        if let handle {
            frameQueue.async {
                try? handle.close()
            }
        }
        displayLayer.stopRequestingMediaData()
        DispatchQueue.main.async { [weak self] in
            tileLayers.forEach { $0.contents = nil; $0.removeFromSuperlayer() }
            self?.latestTileImage = nil
        }
        frameQueue.async { [displayLayer, presentationLayer] in
            presentationLayer.removeFromSuperlayer()
            displayLayer.flushAndRemoveImage()
            displayLayer.removeFromSuperlayer()
        }
    }

    private func startProcess(requiresPlaying: Bool = false) {
        stateLock.lock()
        guard !isTornDown, (!requiresPlaying || isPlaying) else {
            stateLock.unlock()
            return
        }
        generation += 1
        let generation = self.generation
        terminationStatus = nil
        stateLock.unlock()

        guard let executableURL = WallpaperVideoCompatibilityService.executableURL() else {
            NSLog("WallpaperMac streaming playback failed: ffmpeg unavailable for \(sourceURL.path)")
            notifyPlaybackCompleted(generation: generation)
            return
        }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = executableURL
        process.arguments = streamArguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] terminatedProcess in
            self?.processDidTerminate(terminatedProcess)
        }

        stateLock.lock()
        guard !isTornDown, self.generation == generation else {
            stateLock.unlock()
            process.terminationHandler = nil
            return
        }
        self.process = process
        self.outputHandle = pipe.fileHandleForReading
        bufferedData.removeAll()
        emittedFrameCount = 0
        // Keep `frameIndex` monotonic across loop restarts. AVSampleBufferDisplayLayer
        // drops sample buffers whose PTS falls behind its timebase, so resetting to 0
        // on every loop froze the video after the first playthrough.
        stateLock.unlock()

        do {
            try process.run()
        } catch {
            NSLog("WallpaperMac streaming playback failed to start ffmpeg: \(error.localizedDescription)")
            stateLock.lock()
            guard self.generation == generation else {
                stateLock.unlock()
                return
            }
            self.process = nil
            self.outputHandle = nil
            stateLock.unlock()
            try? pipe.fileHandleForReading.close()
            notifyPlaybackCompleted(generation: generation)
            return
        }

        // run() outside the lock, then re-validate ownership. A very short
        // process may already have exited: that is a drain, not an orphan.
        stateLock.lock()
        let exitedBeforeReturn = self.process == nil && terminationStatus != nil && self.generation == generation
        let orphaned = (self.process !== process && !exitedBeforeReturn)
            || isTornDown
            || self.generation != generation
            || (requiresPlaying && !isPlaying)
        stateLock.unlock()
        if orphaned {
            process.terminationHandler = nil
            if process.isRunning {
                process.terminate()
            }
            // A short-lived exited process still needs its stdout drained.
            // Only a replaced/failed launch closes its reader, and that close
            // is serialized behind the current frameQueue read.
            if !exitedBeforeReturn {
                frameQueue.async {
                    try? pipe.fileHandleForReading.close()
                }
            }
            return
        }

        frameQueue.async { [weak self] in
            self?.startRequestingFrames()
        }
    }

    private func startRequestingFrames() {
        stateLock.lock()
        let needsCompletion = outputHandle == nil && terminationStatus != nil
        if needsCompletion {
            stateLock.unlock()
            finishDrainingIfPossible()
            return
        }
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
            let generation = self.generation
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
            stateLock.lock()
            let stillCurrent = generation == self.generation && isPlaying && !isTornDown
            stateLock.unlock()
            guard stillCurrent else { return }
            // Heartbeat: a frame arrived, so the pipeline is alive. Hop to the
            // main actor like notifyPlaybackCompleted — produceFrames runs on
            // frameQueue and must not touch WallpaperManager state directly.
            notifyFrameProgress(generation: generation)
            let presentationIndex = frameIndex
            frameIndex += 1
            emittedFrameCount += 1
            enqueue(frame, presentationIndex: presentationIndex, generation: generation)
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
        // Only record the exit here. The process's stdout can still contain
        // complete frames, so the serial frame queue must drain it before any
        // buffer is cleared or a loop is restarted.
        self.process = nil
        terminationStatus = terminatedProcess.terminationStatus
        let generation = self.generation
        stateLock.unlock()

        frameQueue.async { [weak self] in
            self?.drainAfterTermination(generation: generation)
        }
    }

    private func drainAfterTermination(generation: Int) {
        stateLock.lock()
        let hasExited = terminationStatus != nil && self.generation == generation
        let playing = isPlaying
        let requesting = isRequestingFrames
        stateLock.unlock()
        guard hasExited, playing else { return }
        if requesting {
            produceFrames()
        } else {
            startRequestingFrames()
        }
    }

    /// Called only on frameQueue after read() reaches EOF. Pausing leaves the
    /// drained state in place so resume can finish it; no paused loop is ever
    /// restarted in the background.
    private func finishDrainingIfPossible(expectedGeneration: Int? = nil) {
        stateLock.lock()
        guard !isTornDown,
              let status = terminationStatus,
              expectedGeneration == nil || expectedGeneration == generation else {
            stateLock.unlock()
            return
        }
        guard isPlaying else {
            stateLock.unlock()
            stopRequestingFrames()
            return
        }
        let generation = self.generation
        let handle = outputHandle
        let emittedFrames = emittedFrameCount
        let hasIncompleteTail = !bufferedData.isEmpty
        outputHandle = nil
        bufferedData.removeAll()
        stateLock.unlock()

        stopRequestingFrames()
        if let handle {
            try? handle.close()
        }
        if VideoStreamExitPolicy.shouldRestartAfterDrain(
            terminationStatus: status,
            loops: loops,
            emittedFrameCount: emittedFrames,
            hasIncompleteTail: hasIncompleteTail
        ) {
            startProcess(requiresPlaying: true)
        } else {
            notifyPlaybackCompleted(generation: generation)
        }
    }

    private func notifyPlaybackCompleted(generation: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            guard !self.isTornDown,
                  self.generation == generation,
                  self.completionDeliveredGeneration != generation else {
                self.stateLock.unlock()
                return
            }
            self.completionDeliveredGeneration = generation
            self.stateLock.unlock()
            self.onVideoPlaybackCompleted?()
        }
    }

    private func notifyFrameProgress(generation: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let isCurrent = self.generation == generation && self.isPlaying && !self.isTornDown
            self.stateLock.unlock()
            guard isCurrent else { return }
            self.onFrameProgress?()
        }
    }

    private func readFrame() -> Data? {
        stateLock.lock()
        let handle = outputHandle
        let generation = self.generation
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
                    // EOF belongs to the frame queue: all complete frames read
                    // so far are delivered before completion/looping.
                    finishDrainingIfPossible(expectedGeneration: generation)
                    return nil
                }
                stateLock.lock()
                bufferedData.append(chunk)
                stateLock.unlock()
            } catch {
                stateLock.lock()
                if terminationStatus == nil {
                    terminationStatus = -1
                }
                let failedProcess = process
                process = nil
                stateLock.unlock()
                failedProcess?.terminate()
                finishDrainingIfPossible(expectedGeneration: generation)
                return nil
            }
        }

        stateLock.lock()
        defer { stateLock.unlock() }
        return bufferedData.nextFrame()
    }

    private func enqueue(_ data: Data, presentationIndex: Int64, generation: Int) {
        stateLock.lock()
        let cancelled = isTornDown || self.generation != generation
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
            stateLock.lock()
            let shouldEnqueue = !isTornDown && self.generation == generation && isPlaying
            let tiled = fitMode == .tile
            stateLock.unlock()
            guard shouldEnqueue else { return }
            displayLayer.enqueue(sampleBuffer)
            guard tiled else { return }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            var converted: CGImage?
            VTCreateCGImageFromCVPixelBuffer(
                pixelBuffer,
                options: nil,
                imageOut: &converted
            )
            // The decoder pads non-16:9 sources into this fixed canvas. Crop
            // the padding before using the frame as a native-size tile.
            let image = converted.map {
                tileContentImage(
                    from: $0,
                    sourceSize: originalSize,
                    outputSize: CGSize(width: width, height: height)
                )
            } ?? converted
            guard let image else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isTornDown, self.generation == generation else {
                    return
                }
                self.latestTileImage = image
                self.tileLayers.forEach { $0.contents = image }
            }
        }
    }

    private func tileContentImage(
        from image: CGImage,
        sourceSize: CGSize,
        outputSize: CGSize
    ) -> CGImage {
        guard sourceSize.width > 0, sourceSize.height > 0,
              outputSize.width > 0, outputSize.height > 0 else {
            return image
        }
        let scale = min(outputSize.width / sourceSize.width, outputSize.height / sourceSize.height)
        let drawWidth = max(1, min(outputSize.width, round(sourceSize.width * scale)))
        let drawHeight = max(1, min(outputSize.height, round(sourceSize.height * scale)))
        if drawWidth >= outputSize.width && drawHeight >= outputSize.height {
            return image
        }
        let rect = CGRect(
            x: round((outputSize.width - drawWidth) / 2),
            y: round((outputSize.height - drawHeight) / 2),
            width: drawWidth,
            height: drawHeight
        )
        return image.cropping(to: rect) ?? image
    }
}
