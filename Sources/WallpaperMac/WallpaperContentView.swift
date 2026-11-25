import AVFoundation
import AppKit
import CoreMedia
import WebKit
import WallpaperMacCore

final class WallpaperContentView: NSView, WKNavigationDelegate, WKUIDelegate {
    private let item: WallpaperItem
    /// The user's requested playback state. System suspension never changes this value.
    private var isPlaying: Bool
    private var isSystemSuspended = false
    private var webInteractionEnabled: Bool
    private let reloadWebContentOnResume: Bool
    private var navigationAuthorizer = ExternalNavigationAuthorizer()
    private var isMuted: Bool
    private var fitMode: WallpaperFitMode
    private let loops: Bool
    private let onVideoPlaybackCompleted: (() -> Void)?
    private let onFrameProgress: (() -> Void)?
    private let onVideoDurationChanged: ((Double?) -> Void)?
    private var imageLayer: CALayer?
    private var imageContentLayer: CALayer?
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var playerPresentationLayer: CALayer?
    private var playerTileSize: CGSize?
    private var lastPresentationBounds: CGSize?
    private var videoNaturalSize: CGSize?
    private var progressObserver: Any?
    private var progressTracker = VideoPlaybackProgressTracker()
    private var streamingController: WallpaperVideoStreamController?
    private var webView: WKWebView?
    private var webErrorLabel: NSTextField?
    private var webRecoveryState = WebContentRecoveryState()
    private var webRecoveryWorkItem: DispatchWorkItem?
    private var webLoadTimeoutWorkItem: DispatchWorkItem?
    private var webHealthyWorkItem: DispatchWorkItem?
    private var webRecoveryGeneration = 0
    private var loopObserver: NSObjectProtocol?
    private var compatibilityTask: Task<Void, Never>?
    private var isTornDown = false

    var playbackState: WallpaperManager.PlaybackState {
        switch item.type {
        case .image:
            return .staticImage
        case .video, .web:
            return isPlaying && !isSystemSuspended
                ? .playing(isMuted: isMuted)
                : .paused(isMuted: isMuted)
        }
    }

    init(
        item: WallpaperItem,
        policy: PlaybackPolicy,
        loops: Bool,
        onVideoPlaybackCompleted: (() -> Void)?,
        onFrameProgress: (() -> Void)? = nil,
        onVideoDurationChanged: ((Double?) -> Void)? = nil,
        initialSystemSuspended: Bool = false,
        frame: NSRect
    ) throws {
        self.item = item
        self.isPlaying = policy.isPlaying
        self.webInteractionEnabled = policy.webWallpaperInteractionEnabled
        self.reloadWebContentOnResume = policy.reloadWebContentOnResume
        self.isMuted = policy.isMuted
        self.fitMode = item.effectiveFitMode(global: policy.fitMode)
        self.loops = loops
        self.onVideoPlaybackCompleted = onVideoPlaybackCompleted
        self.onFrameProgress = onFrameProgress
        self.onVideoDurationChanged = onVideoDurationChanged
        self.isSystemSuspended = initialSystemSuspended
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        try configureContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        releasePlaybackResources()
        removeInterfaceViews()
    }

    /// Thread-safe teardown of the playback pipeline (observers, tasks,
    /// ffmpeg, AVPlayer). Does not touch AppKit layer/view hierarchy.
    private func releasePlaybackResources() {
        isPlaying = false
        navigationAuthorizer.cancel()
        webView?.evaluateJavaScript(WebMouseEventScript.clearMouseState(), completionHandler: nil)

        if let loopObserver {
            NotificationCenter.default.removeObserver(loopObserver)
            self.loopObserver = nil
        }
        compatibilityTask?.cancel()
        compatibilityTask = nil
        webRecoveryGeneration += 1
        webRecoveryWorkItem?.cancel()
        webLoadTimeoutWorkItem?.cancel()
        webHealthyWorkItem?.cancel()
        webRecoveryWorkItem = nil
        webLoadTimeoutWorkItem = nil
        webHealthyWorkItem = nil
        if let progressObserver {
            player?.removeTimeObserver(progressObserver)
            self.progressObserver = nil
        }
        streamingController?.teardown()
        streamingController = nil

        player?.pause()
        playerLayer?.player = nil
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    /// AppKit hierarchy removal — main thread only.
    private func removeInterfaceViews() {
        playerPresentationLayer?.removeFromSuperlayer()
        playerPresentationLayer = nil
        playerTileSize = nil
        videoNaturalSize = nil
        playerLayer?.removeFromSuperlayer()
        imageLayer?.removeFromSuperlayer()
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        layer?.contents = nil
        playerLayer = nil
        imageLayer = nil
        imageContentLayer = nil

        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        webErrorLabel?.removeFromSuperview()
        webErrorLabel = nil
    }

    deinit {
        // deinit can run on any queue. Only the non-AppKit cleanup is safe
        // here; explicit runtime shutdown paths call teardown() on the main
        // thread to remove layer/view subviews before the view is destroyed.
        guard !isTornDown else { return }
        isTornDown = true
        releasePlaybackResources()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard item.type == .web else { return super.hitTest(point) }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        item.type == .web
    }

    override func mouseDown(with event: NSEvent) {
        guard item.type == .web else {
            super.mouseDown(with: event)
            return
        }
        dispatchWebMouseEvent(event, phase: .mouseDown)
    }

    override func mouseUp(with event: NSEvent) {
        guard item.type == .web else {
            super.mouseUp(with: event)
            return
        }
        dispatchWebMouseEvent(event, phase: .mouseUp)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if item.type == .web, let webView {
            window?.makeFirstResponder(webView)
        }
    }

    private var isWebMouseDragCancelled = false
    private var webMouseDownLocation: NSPoint?

    private func cancelWebMouseGesture() {
        isWebMouseDragCancelled = true
        webMouseDownLocation = nil
        navigationAuthorizer.cancel()
        webView?.evaluateJavaScript(WebMouseEventScript.clearMouseState(), completionHandler: nil)
    }

    private func dispatchWebMouseEvent(_ event: NSEvent, phase: WebMouseEventPhase) {
        guard let webView else { return }
        let disallowedModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        if !event.modifierFlags.intersection(disallowedModifiers).isEmpty {
            cancelWebMouseGesture()
            return
        }
        if phase == .mouseDown {
            isWebMouseDragCancelled = false
        }
        let localPoint = convert(event.locationInWindow, from: nil)
        if phase == .mouseDown {
            webMouseDownLocation = localPoint
        }
        let outside = localPoint.x < 0 || localPoint.x > bounds.width || localPoint.y < 0 || localPoint.y > bounds.height
        if outside || (phase == .mouseUp && isWebMouseDragCancelled) {
            cancelWebMouseGesture()
            isWebMouseDragCancelled = false
            return
        }
        let x = max(0, min(bounds.width, localPoint.x))
        let y = max(0, min(bounds.height, bounds.height - localPoint.y))
        if phase == .mouseUp {
            // First evaluate the real activation target without clicking. The
            // host authorizes only that exact target, then activates it once.
            let evaluate = WebMouseEventScript.evaluateMouseUp(x: x, y: y)
            let gestureTime = ProcessInfo.processInfo.systemUptime
            webView.evaluateJavaScript(evaluate) { [weak self, weak webView] result, _ in
                guard let self, let webView, !self.isTornDown, self.webView === webView,
                      let payload = result as? [String: Any],
                      let shouldActivate = payload["activate"] as? Bool else { return }
                guard shouldActivate,
                      self.webInteractionEnabled,
                      self.isPlaying,
                      !self.isSystemSuspended else {
                    self.navigationAuthorizer.cancel()
                    webView.evaluateJavaScript(WebMouseEventScript.clearMouseState(), completionHandler: nil)
                    return
                }
                let urlString = payload["url"] as? String ?? ""
                if !urlString.isEmpty {
                    guard let url = URL(string: urlString), WebWallpaperURL.isValid(url) else {
                        self.navigationAuthorizer.cancel()
                        webView.evaluateJavaScript(WebMouseEventScript.clearMouseState(), completionHandler: nil)
                        return
                    }
                    self.navigationAuthorizer.prepare(
                        url: url,
                        now: gestureTime,
                        interactionEnabled: self.webInteractionEnabled,
                        isPlaying: self.isPlaying,
                        isSystemSuspended: self.isSystemSuspended
                    )
                }
                webView.evaluateJavaScript(WebMouseEventScript.activateMouseUp(), completionHandler: nil)
            }
        } else {
            let script = WebMouseEventScript.source(x: x, y: y, phase: phase)
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard item.type == .web, let start = webMouseDownLocation else { return }
        let point = convert(event.locationInWindow, from: nil)
        let outside = point.x < 0 || point.x > bounds.width || point.y < 0 || point.y > bounds.height
        // AppKit can send a drag event for a sub-pixel movement. Preserve the
        // script's 6px tolerance; only a real drag or leaving the view cancels.
        if outside || hypot(point.x - start.x, point.y - start.y) > 6 {
            cancelWebMouseGesture()
        }
    }

    override func mouseExited(with event: NSEvent) {
        guard item.type == .web else { return }
        cancelWebMouseGesture()
    }

    override func layout() {
        super.layout()
        let sizeChanged = lastPresentationBounds != bounds.size
        lastPresentationBounds = bounds.size
        if sizeChanged, fitMode == .tile {
            // Replicator grids freeze their column/row counts. Rebuild only
            // the presentation layers when the viewport changes.
            if imageContentLayer != nil { rebuildImagePresentation() }
            if playerLayer != nil { rebuildPlayerPresentation() }
        }
        imageLayer?.frame = bounds
        playerPresentationLayer?.frame = bounds
        streamingController?.setFrame(bounds)
        webView?.frame = bounds
        webErrorLabel?.frame = NSRect(
            x: bounds.minX + 24,
            y: bounds.midY - 28,
            width: max(0, bounds.width - 48),
            height: 56
        )
    }

    func togglePlayback() {
        guard !isTornDown, item.type != .image else { return }
        isPlaying.toggle()
        applyPlaybackState()
    }

    func setPlaybackEnabled(_ isPlaying: Bool) {
        guard !isTornDown, item.type != .image else { return }
        self.isPlaying = isPlaying
        applyPlaybackState()
    }

    func setFitMode(_ fitMode: WallpaperFitMode) {
        guard !isTornDown, self.fitMode != fitMode else { return }
        self.fitMode = fitMode
        rebuildImagePresentation()
        rebuildPlayerPresentation()
        streamingController?.setFitMode(fitMode)
    }

    func setWebInteractionEnabled(_ enabled: Bool) {
        webInteractionEnabled = enabled
        if !enabled {
            navigationAuthorizer.cancel()
            webView?.evaluateJavaScript(WebMouseEventScript.clearMouseState(), completionHandler: nil)
        }
    }

    func setSystemSuspended(_ suspended: Bool, reloadWebContentOnResume: Bool) {
        guard !isTornDown else { return }
        isSystemSuspended = suspended
        applyPlaybackState()
    }

    private func applyPlaybackState() {
        let shouldPlay = isPlaying && !isSystemSuspended
        if !shouldPlay {
            progressTracker.resetClock()
            navigationAuthorizer.cancel()
        }
        switch item.type {
        case .image:
            break
        case .video:
            if let streamingController {
                streamingController.setPlaying(shouldPlay)
            } else if shouldPlay {
                player?.play()
            } else {
                player?.pause()
            }
        case .web:
            if !shouldPlay {
                webRecoveryGeneration += 1
                webRecoveryWorkItem?.cancel()
                webRecoveryWorkItem = nil
                webLoadTimeoutWorkItem?.cancel()
                webLoadTimeoutWorkItem = nil
                webHealthyWorkItem?.cancel()
                webHealthyWorkItem = nil
            }
            if !shouldPlay && reloadWebContentOnResume {
                // When reload-on-resume is allowed, fully release the renderer
                // so timers, CSS animation and network work stop as well.
                destroyWebContent()
                return
            }
            if shouldPlay && webView == nil && reloadWebContentOnResume {
                configureWebPlayback()
            }
            // Public WebKit API: unlike a one-time DOM pause(), this also
            // blocks later play() calls and newly inserted media.
            webView?.setAllMediaPlaybackSuspended(!shouldPlay, completionHandler: nil)
            evaluateMediaScript(shouldPlay ? "play" : "pause")
            if shouldPlay, webErrorLabel?.isHidden == false {
                scheduleWebRecovery()
            }
        }
    }

    private func destroyWebContent() {
        navigationAuthorizer.cancel()
        webRecoveryGeneration += 1
        webRecoveryWorkItem?.cancel()
        webRecoveryWorkItem = nil
        webLoadTimeoutWorkItem?.cancel()
        webLoadTimeoutWorkItem = nil
        webHealthyWorkItem?.cancel()
        webHealthyWorkItem = nil
        webView?.evaluateJavaScript(WebMouseEventScript.clearMouseState(), completionHandler: nil)
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        webErrorLabel?.removeFromSuperview()
        webErrorLabel = nil
    }

    func setMuted(_ muted: Bool) {
        guard !isTornDown, item.type != .image else { return }
        isMuted = muted
        player?.isMuted = muted
        if item.type == .web {
            let value = muted ? "true" : "false"
            webView?.evaluateJavaScript("document.querySelectorAll('video,audio').forEach(function(media){ media.muted = \(value); media.volume = \(muted ? 0 : 1); });", completionHandler: nil)
        }
    }

    private func configureContent() throws {
        switch item.type {
        case .image:
            guard let image = NSImage(contentsOf: item.sourceURL),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw WallpaperContentError.cannotLoadResource(item.sourceURL)
            }
            let imageLayer = CALayer()
            imageLayer.contents = cgImage
            imageLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            imageLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            imageContentLayer = imageLayer
            rebuildImagePresentation()
        case .video:
            configureVideoPlayback(at: item.playbackURL ?? item.sourceURL)
        case .web:
            configureWebPlayback()
        }
    }

    private var displayContentScale: CGFloat {
        window?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    }

    private func rebuildImagePresentation() {
        guard let content = imageContentLayer else { return }
        imageLayer?.removeFromSuperlayer()
        let originalSize: CGSize
        if let contents = content.contents {
            // The image branch always stores a CGImage in contents.
            let image = contents as! CGImage
            originalSize = CGSize(width: image.width, height: image.height)
        } else {
            originalSize = bounds.size
        }
        imageLayer = WallpaperLayerLayout.make(
            content: content,
            originalSize: originalSize,
            bounds: bounds,
            mode: fitMode,
            contentScale: displayContentScale
        )
        if let imageLayer {
            layer?.addSublayer(imageLayer)
        }
    }

    private func rebuildPlayerPresentation() {
        guard let content = playerLayer else { return }
        playerPresentationLayer?.removeFromSuperlayer()
        let originalSize = currentMediaSize
        playerTileSize = originalSize
        playerPresentationLayer = WallpaperLayerLayout.make(
            content: content,
            originalSize: originalSize,
            bounds: bounds,
            mode: fitMode,
            contentScale: displayContentScale
        )
        if let playerPresentationLayer {
            layer?.addSublayer(playerPresentationLayer)
        }
    }

    private var knownMediaSize: CGSize? {
        if let videoNaturalSize, videoNaturalSize.width > 0, videoNaturalSize.height > 0 {
            return videoNaturalSize
        }
        if let width = item.metadata?.pixelWidth,
           let height = item.metadata?.pixelHeight,
           width > 0, height > 0 {
            return CGSize(width: width, height: height)
        }
        if let size = player?.currentItem?.presentationSize,
           size.width > 0, size.height > 0 {
            return CGSize(width: size.width, height: size.height)
        }
        return nil
    }

    private var currentMediaSize: CGSize {
        knownMediaSize ?? bounds.size
    }

    private func configureWebPlayback() {
        guard webView == nil else { return }
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: bounds, configuration: configuration)
        webView.autoresizingMask = [.width, .height]
        webView.allowsBackForwardNavigationGestures = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        let entryURL = item.entryURL ?? item.sourceURL
        if entryURL.isFileURL {
            // A single file is authorized only for itself. A directory
            // project is authorized for the directory explicitly imported.
            let readRoot = item.sourceURL
            webView.loadFileURL(entryURL, allowingReadAccessTo: readRoot)
        } else if WebWallpaperURL.isValid(entryURL) {
            webView.load(URLRequest(url: entryURL))
        } else {
            return
        }
        addSubview(webView)
        self.webView = webView
        let errorLabel = NSTextField(wrappingLabelWithString: "网页加载失败，请检查网络后重新加载。")
        errorLabel.alignment = .center
        errorLabel.textColor = .white
        errorLabel.backgroundColor = NSColor.black.withAlphaComponent(0.72)
        errorLabel.drawsBackground = true
        errorLabel.isBezeled = false
        errorLabel.isHidden = true
        addSubview(errorLabel)
        self.webErrorLabel = errorLabel
        applyPlaybackState()
        startWebLoadWatchdog()
    }

    private func configureVideoPlayback(at sourceURL: URL) {
        compatibilityTask = Task { [weak self] in
            guard let self else { return }
            do {
                let asset = AVURLAsset(url: sourceURL)
                let isPlayable = try await asset.load(.isPlayable)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                var displaySize: CGSize?
                if let track = tracks.first {
                    let naturalSize = try await track.load(.naturalSize)
                    let transform = try await track.load(.preferredTransform)
                    let displayRect = CGRect(origin: .zero, size: naturalSize).applying(transform).standardized
                    displaySize = CGSize(width: abs(displayRect.width), height: abs(displayRect.height))
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.videoNaturalSize = displaySize
                    if self.fitMode == .tile {
                        self.rebuildPlayerPresentation()
                    }
                }
                let codec = try await videoCodec(for: asset)
                guard !Task.isCancelled else { return }
                guard VideoPlaybackCompatibility.requiresConversion(
                    codec: codec,
                    isPlayable: isPlayable
                ) else {
                    await MainActor.run { [weak self] in
                        self?.installVideoPlayer(at: sourceURL)
                    }
                    return
                }

                await MainActor.run { [weak self] in
                    self?.installStreamingVideoPlayer(at: sourceURL)
                }
            } catch {
                NSLog("WallpaperMac compatibility playback failed for \(sourceURL.path): \(error.localizedDescription)")
                // Surface the failure as playback completion so video-completion
                // queues can advance instead of waiting forever for an item that
                // never installed a player.
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    self?.onVideoPlaybackCompleted?()
                }
            }
        }
    }

    private func installStreamingVideoPlayer(at sourceURL: URL) {
        guard !isTornDown, streamingController == nil else { return }
        let controller = WallpaperVideoStreamController(
            sourceURL: sourceURL,
            isPlaying: isPlaying && !isSystemSuspended,
            loops: loops,
            frame: bounds,
            onVideoPlaybackCompleted: onVideoPlaybackCompleted,
            onFrameProgress: onFrameProgress,
            fitMode: fitMode,
            // Never use the viewport as ffmpeg's source aspect ratio: padding
            // would become permanent black bars inside every decoded frame.
            originalSize: knownMediaSize,
            contentScale: displayContentScale
        )
        streamingController = controller
        layer?.addSublayer(controller.presentationLayer)
        controller.start()
    }

    private func installVideoPlayer(at playbackURL: URL) {
        guard !isTornDown, player == nil else { return }
        let player = AVPlayer(url: playbackURL)
        player.automaticallyWaitsToMinimizeStalling = true
        player.currentItem?.preferredForwardBufferDuration = VideoPlaybackCompatibility.preferredForwardBufferSeconds
        let playerLayer = AVPlayerLayer(player: player)
        // The player is installed after asynchronous codec inspection, so the
        // view may already have completed its initial layout pass.
        playerLayer.frame = bounds
        // Install the shared player layer, then choose its presentation without
        // creating a second player for tiled mode.
        self.player = player
        self.playerLayer = playerLayer
        rebuildPlayerPresentation()
        needsLayout = true
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self, weak player] _ in
            guard let self, !self.isTornDown else { return }
            if self.loops {
                // Resume only after the seek lands; play() during an in-flight
                // seek can leave the player waiting forever on some files.
                player?.seek(to: .zero) { finished in
                    guard finished, let player else { return }
                    self.progressTracker.resetClock()
                    if self.isPlaying && !self.isSystemSuspended { player.play() }
                }
            } else {
                self.onVideoPlaybackCompleted?()
            }
        }
        player.isMuted = isMuted
        progressObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 2),
            queue: .main
        ) { [weak self, weak player] time in
            guard let self, !self.isTornDown else { return }
            guard self.isPlaying && !self.isSystemSuspended,
                  player?.timeControlStatus == .playing,
                  player?.currentItem?.status == .readyToPlay else {
                // Paused, buffering and waiting time is not playback progress.
                self.progressTracker.resetClock()
                return
            }
            let duration = player?.currentItem?.duration.seconds
            if self.fitMode == .tile, let size = player?.currentItem?.presentationSize,
               size.width > 0, size.height > 0 {
                let desired = self.currentMediaSize
                if desired != self.playerTileSize {
                    self.rebuildPlayerPresentation()
                }
            }
            let progress = self.progressTracker.sample(
                currentTime: time.seconds,
                duration: duration
            )
            if progress.durationChanged {
                self.onVideoDurationChanged?(progress.durationSeconds)
            }
            if progress.advanced {
                self.onFrameProgress?()
            }
        }
        if isPlaying && !isSystemSuspended { player.play() }
    }

    private func videoCodec(for asset: AVURLAsset) async throws -> String? {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first,
              let description = try await track.load(.formatDescriptions).first else {
            return nil
        }
        let codec = CMFormatDescriptionGetMediaSubType(description)
        return String(
            format: "%c%c%c%c",
            (codec >> 24) & 0xff,
            (codec >> 16) & 0xff,
            (codec >> 8) & 0xff,
            codec & 0xff
        ).lowercased()
    }

    private func evaluateMediaScript(_ action: String) {
        let script = "document.querySelectorAll('video,audio').forEach(function(media){ var result = media.\(action)(); if (result && result.catch) { result.catch(function() {}); } });"
        webView?.evaluateJavaScript(script, completionHandler: nil)
    }

    private func setWebError(_ message: String?) {
        webErrorLabel?.stringValue = message ?? ""
        webErrorLabel?.isHidden = message == nil
    }

    private func startWebLoadWatchdog() {
        webLoadTimeoutWorkItem?.cancel()
        guard let webView else { return }
        let work = DispatchWorkItem { [weak self, weak webView] in
            guard let self, let webView, !self.isTornDown, self.webView === webView else { return }
            self.setWebError("网页加载超时，正在尝试恢复…")
            self.scheduleWebRecovery()
        }
        webLoadTimeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    private func scheduleWebRecovery() {
        webHealthyWorkItem?.cancel()
        webHealthyWorkItem = nil
        webLoadTimeoutWorkItem?.cancel()
        guard webRecoveryWorkItem == nil, webView != nil else { return }
        guard let delay = webRecoveryState.nextDelay(
            isPlaying: isPlaying,
            isSystemSuspended: isSystemSuspended
        ) else {
            if webRecoveryState.isExhausted {
                setWebError("网页加载失败，请手动重新加载。")
            }
            return
        }
        webRecoveryGeneration += 1
        let generation = webRecoveryGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  !self.isTornDown,
                  self.webRecoveryGeneration == generation,
                  self.isPlaying,
                  !self.isSystemSuspended else { return }
            self.webRecoveryWorkItem = nil
            self.webView?.reload()
            self.startWebLoadWatchdog()
        }
        webRecoveryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func markWebHealthy() {
        webRecoveryGeneration += 1
        setWebError(nil)
        webLoadTimeoutWorkItem?.cancel()
        webRecoveryWorkItem?.cancel()
        webRecoveryWorkItem = nil
        webHealthyWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.webRecoveryState.markHealthy()
        }
        webHealthyWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationAuthorizer.cancel()
        webView.evaluateJavaScript(WebMouseEventScript.clearMouseState(), completionHandler: nil)
        markWebHealthy()
        setMuted(isMuted)
        // Always re-apply the current state, including a pause that happened
        // before or during navigation.
        applyPlaybackState()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if item.sourceURL.isFileURL {
            decisionHandler(.allow)
            return
        }
        guard let url = navigationAction.request.url,
              WebWallpaperURL.isValid(url) else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url,
              WebWallpaperURL.isValid(url),
              navigationAuthorizer.consume(
                url: url,
                now: ProcessInfo.processInfo.systemUptime,
                interactionEnabled: webInteractionEnabled,
                isPlaying: isPlaying,
                isSystemSuspended: isSystemSuspended
              ) else {
            return nil
        }
        openExternalURL(url)
        return nil
    }

    private func openExternalURL(_ url: URL) {
        // Runtime tests can record the opener without launching a browser.
        // Normal production always uses NSWorkspace.
        guard let logPath = ProcessInfo.processInfo.environment["WALLPAPERMAC_EXTERNAL_OPEN_LOG"] else {
            NSWorkspace.shared.open(url)
            return
        }
        let line = url.absoluteString + "\n"
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: URL(fileURLWithPath: logPath))
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !isTornDown else { return }
        setWebError("网页渲染进程已终止，正在尝试恢复…")
        scheduleWebRecovery()
    }

    private func webNavigationDidFail(_ error: Error) {
        guard !isTornDown, (error as NSError).code != NSURLErrorCancelled else { return }
        setWebError("网页加载失败，正在尝试恢复…")
        NSLog("WallpaperMac web wallpaper failed to load: \(error.localizedDescription)")
        scheduleWebRecovery()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        webNavigationDidFail(error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        self.webView(webView, didFail: navigation, withError: error)
    }


}

