import Foundation

/// Retry and stall-detection policy for one logical update download.
///
/// A single install attempt may involve several transport attempts: weak or
/// flaky networks frequently drop a transfer after a few hundred kilobytes.
/// Resuming the partial download avoids paying for those bytes twice.
public struct DownloadTransferPolicy: Equatable, Sendable {
    /// Total attempts for one logical download, including the first one.
    public var maximumAttempts: Int
    /// How long a transfer must run before its average speed is judged.
    public var stallWindow: TimeInterval
    /// Average bytes per second below which a transfer counts as stalled.
    public var minimumAverageBytesPerSecond: Double
    /// Pause before starting the next attempt.
    public var retryDelay: TimeInterval

    public init(
        maximumAttempts: Int = 4,
        stallWindow: TimeInterval = 60,
        minimumAverageBytesPerSecond: Double = 4 * 1024,
        retryDelay: TimeInterval = 1
    ) {
        self.maximumAttempts = max(1, maximumAttempts)
        self.stallWindow = max(0, stallWindow)
        self.minimumAverageBytesPerSecond = max(0, minimumAverageBytesPerSecond)
        self.retryDelay = max(0, retryDelay)
    }

    public static let `default` = DownloadTransferPolicy()

    /// True when a transfer that moved `bytesTransferred` over `interval` is
    /// slower than the configured floor. The window must have fully elapsed
    /// before a transfer is judged, so normal startup latency is not a stall.
    public func isStalled(bytesTransferred: Int64, over interval: TimeInterval) -> Bool {
        guard stallWindow > 0, interval >= stallWindow else { return false }
        return Double(max(0, bytesTransferred)) / interval < minimumAverageBytesPerSecond
    }
}

/// Pure retry/resume bookkeeping for one logical download.
///
/// Kept separate from `ProgressDownload` so the state machine (attempts,
/// resume decisions and the final user-facing error) can be tested without a
/// network or a URLSession.
public struct DownloadRetryState: Equatable, Sendable {
    public enum Failure: Equatable, Sendable {
        case stalled(averageBytesPerSecond: Double)
        case transport(String)
        case server(statusCode: Int)
    }

    public enum NextStep: Equatable, Sendable {
        /// Start another attempt. `canResume` is true when the failed attempt
        /// produced resume data that should be continued.
        case retry(canResume: Bool)
        case stop(UpdateDownloadError)
    }

    public let policy: DownloadTransferPolicy
    public private(set) var attemptsStarted = 0
    public private(set) var lastFailure: Failure?

    public init(policy: DownloadTransferPolicy = .default) {
        self.policy = policy
    }

    public var attemptsRemaining: Int {
        max(0, policy.maximumAttempts - attemptsStarted)
    }

    /// Registers one transport attempt. Returns false when the budget is spent.
    @discardableResult
    public mutating func beginAttempt() -> Bool {
        guard attemptsStarted < policy.maximumAttempts else { return false }
        attemptsStarted += 1
        return true
    }

    /// Records a failed attempt and decides whether another one may start.
    public mutating func recordFailure(_ failure: Failure, canResume: Bool) -> NextStep {
        lastFailure = failure
        guard attemptsStarted < policy.maximumAttempts else {
            return .stop(finalError)
        }
        switch failure {
        case .server:
            // An HTTP error body is not a partial artifact; never resume it.
            return .retry(canResume: false)
        case .stalled, .transport:
            return .retry(canResume: canResume)
        }
    }

    /// Readable reason for the terminal failure. Distinguishes a permanently
    /// slow network from a transfer that kept breaking mid-flight.
    public var finalError: UpdateDownloadError {
        switch lastFailure {
        case .stalled:
            return .stalled(attempts: attemptsStarted)
        case .transport(let message):
            if attemptsStarted > 1 {
                return .network("网络传输反复中断（已尝试 \(attemptsStarted) 次）：\(message)")
            }
            return .network(message)
        case .server(let statusCode):
            return .httpStatus(statusCode)
        case nil:
            return .network("下载失败")
        }
    }
}

/// `URLSessionDownloadTask` wrapper that reports byte progress while the
/// system streams the file to disk, and that transparently resumes a transfer
/// that stalls or drops within one install attempt.
///
/// The async `URLSession.download(for:)` convenience API only surfaces a final
/// result, which turns the UI progress bar into an indeterminate spinner and
/// gives no place to hook resume data.
final class ProgressDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct SpeedSample {
        let time: Date
        let bytesNew: Int64
    }

    private let lock = NSLock()
    private let configuration: URLSessionConfiguration
    private let policy: DownloadTransferPolicy

    private var continuation: CheckedContinuation<(tempURL: URL, totalBytes: Int64), Error>?
    private var progressHandler: (@Sendable (UpdateDownloadProgress) -> Void)?
    private var session: URLSession?
    private var request: URLRequest?
    private var activeTask: URLSessionDownloadTask?
    private var stallTimer: DispatchSourceTimer?
    private var retryState: DownloadRetryState
    private var isFinished = false
    private var isCancellingTask = false

    // Per-attempt progress bookkeeping, guarded by `lock`.
    private var attemptStartedAt = Date()
    private var firstByteTime: Date?
    private var resumeBaseline: Int64 = 0
    private var latestReportedBytes: Int64 = 0
    private var displayedBytes: Int64 = 0
    private var totalBytesExpected: Int64?
    private var samples: [SpeedSample] = []

    init(
        configuration: URLSessionConfiguration = .ephemeral,
        policy: DownloadTransferPolicy = .default
    ) {
        self.configuration = configuration
        self.policy = policy
        self.retryState = DownloadRetryState(policy: policy)
        super.init()
    }

    func download(
        from url: URL,
        timeout: TimeInterval = 600,
        onProgress: (@Sendable (UpdateDownloadProgress) -> Void)?
    ) async throws -> (tempURL: URL, totalBytes: Int64) {
        try await withCheckedThrowingContinuation { continuation in
            var request = URLRequest(url: url)
            request.timeoutInterval = timeout
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("WallpaperMac", forHTTPHeaderField: "User-Agent")

            // Copy so one download never mutates a caller-owned configuration.
            let sessionConfiguration = configuration.copy() as? URLSessionConfiguration ?? .ephemeral
            let session = URLSession(configuration: sessionConfiguration, delegate: self, delegateQueue: nil)

            lock.lock()
            self.continuation = continuation
            self.progressHandler = onProgress
            self.request = request
            self.session = session
            self.retryState = DownloadRetryState(policy: policy)
            self.isFinished = false
            self.displayedBytes = 0
            self.totalBytesExpected = nil
            lock.unlock()

            startAttempt(resumeData: nil)
        }
    }

    // MARK: - Attempts

    private func startAttempt(resumeData: Data?) {
        let now = Date()
        lock.lock()
        guard !isFinished, let session, let request else {
            lock.unlock()
            return
        }
        guard retryState.beginAttempt() else {
            let error = retryState.finalError
            lock.unlock()
            finish(.failure(error))
            return
        }

        attemptStartedAt = now
        firstByteTime = nil
        resumeBaseline = 0
        latestReportedBytes = displayedBytes
        samples.removeAll(keepingCapacity: true)
        isCancellingTask = false

        let task: URLSessionDownloadTask
        if let resumeData {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            task = session.downloadTask(with: request)
        }
        activeTask = task
        lock.unlock()

        startStallTimer()
        task.resume()
    }

    private func startStallTimer() {
        let interval = max(0.1, min(2, policy.stallWindow / 4))
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.checkForStall()
        }
        lock.lock()
        stallTimer?.cancel()
        stallTimer = timer
        lock.unlock()
        timer.resume()
    }

    private func stopStallTimerLocked() {
        stallTimer?.cancel()
        stallTimer = nil
    }

    private func checkForStall() {
        let now = Date()
        lock.lock()
        guard !isFinished, !isCancellingTask, let task = activeTask else {
            lock.unlock()
            return
        }

        // Keep the sliding window alive even while no bytes arrive, so an
        // idle transfer eventually averages down to zero.
        if firstByteTime != nil {
            appendSampleLocked(SpeedSample(time: now, bytesNew: currentNewBytesLocked()))
        }

        let average = windowSpeedLocked(now: now)
        let stalled: Bool
        if let average {
            stalled = average < policy.minimumAverageBytesPerSecond
        } else if firstByteTime == nil {
            // Nothing at all arrived (for example a hung TLS handshake).
            stalled = now.timeIntervalSince(attemptStartedAt) >= policy.stallWindow
        } else {
            stalled = false
        }

        guard stalled else {
            let handler = progressHandler
            let progress = firstByteTime == nil ? nil : makeProgressLocked(now: now)
            lock.unlock()
            if let progress { handler?(progress) }
            return
        }

        isCancellingTask = true
        let handler = progressHandler
        let progress = makeProgressLocked(now: now)
        lock.unlock()
        handler?(progress)
        task.cancel(byProducingResumeData: { [weak self] resumeData in
            self?.handleStallCancellation(task: task, resumeData: resumeData)
        })
    }

    private func handleStallCancellation(task: URLSessionDownloadTask, resumeData: Data?) {
        lock.lock()
        guard !isFinished, task === activeTask else {
            lock.unlock()
            return
        }
        activeTask = nil
        isCancellingTask = false
        stopStallTimerLocked()
        let average = windowSpeedLocked(now: Date()) ?? 0
        let decision = retryState.recordFailure(
            .stalled(averageBytesPerSecond: average),
            canResume: resumeData != nil
        )
        lock.unlock()
        handle(decision, resumeData: resumeData)
    }

    private func handle(_ decision: DownloadRetryState.NextStep, resumeData: Data?) {
        switch decision {
        case .stop(let error):
            finish(.failure(error))
        case .retry(let canResume):
            scheduleRetry(resumeData: canResume ? resumeData : nil)
        }
    }

    private func scheduleRetry(resumeData: Data?) {
        let delay = policy.retryDelay
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.startAttempt(resumeData: resumeData)
        }
    }

    // MARK: - Progress windows

    private func currentNewBytesLocked() -> Int64 {
        max(0, latestReportedBytes - resumeBaseline)
    }

    private func appendSampleLocked(_ sample: SpeedSample) {
        if let last = samples.last, sample.time.timeIntervalSince(last.time) < 0.05 {
            samples[samples.count - 1] = sample
        } else {
            samples.append(sample)
        }
        pruneSamplesLocked(now: sample.time)
    }

    /// Keeps one sample at or before the stall window as a fixed baseline, so
    /// the speed measured for every tick covers roughly `stallWindow` seconds.
    private func pruneSamplesLocked(now: Date) {
        let cutoff = now.addingTimeInterval(-policy.stallWindow)
        if let baselineIndex = samples.lastIndex(where: { $0.time <= cutoff }), baselineIndex > 0 {
            samples.removeFirst(baselineIndex)
        }
        let maxSamples = max(600, Int(policy.stallWindow * 60))
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
    }

    /// Average speed over the stall window, or nil until the window has run.
    private func windowSpeedLocked(now: Date) -> Double? {
        guard let firstByteTime,
              now.timeIntervalSince(firstByteTime) >= policy.stallWindow else {
            return nil
        }
        let cutoff = now.addingTimeInterval(-policy.stallWindow)
        guard let baseline = samples.last(where: { $0.time <= cutoff }) else { return nil }
        let newest = samples.last ?? baseline
        let elapsed = now.timeIntervalSince(baseline.time)
        guard elapsed > 0 else { return nil }
        return Double(max(0, newest.bytesNew - baseline.bytesNew)) / elapsed
    }

    /// Short-window speed used for the UI label. Falls back to the data seen
    /// so far while the download is younger than the window.
    private func recentSpeedLocked(now: Date) -> Double? {
        guard firstByteTime != nil, let first = samples.first else { return nil }
        let window = max(0.5, min(5, policy.stallWindow / 4))
        let cutoff = now.addingTimeInterval(-window)
        let baseline = samples.last(where: { $0.time <= cutoff }) ?? first
        let newest = samples.last ?? baseline
        let elapsed = now.timeIntervalSince(baseline.time)
        guard elapsed > 0 else { return nil }
        return Double(max(0, newest.bytesNew - baseline.bytesNew)) / elapsed
    }

    private func makeProgressLocked(now: Date) -> UpdateDownloadProgress {
        let received = max(displayedBytes, latestReportedBytes)
        let total = totalBytesExpected.flatMap { $0 > 0 ? $0 : nil }
        return UpdateDownloadProgress(
            bytesReceived: received,
            totalBytes: total.map { max($0, received) },
            bytesPerSecond: recentSpeedLocked(now: now)
        )
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didResumeAtOffset fileOffset: Int64,
        expectedTotalBytes: Int64
    ) {
        lock.lock()
        guard !isFinished, downloadTask === activeTask else {
            lock.unlock()
            return
        }
        if expectedTotalBytes > 0 {
            totalBytesExpected = expectedTotalBytes
        }
        // Bytes already on disk are not part of this attempt's speed window.
        resumeBaseline = max(resumeBaseline, fileOffset)
        displayedBytes = max(displayedBytes, fileOffset)
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let now = Date()
        lock.lock()
        guard !isFinished, downloadTask === activeTask else {
            lock.unlock()
            return
        }
        if firstByteTime == nil {
            firstByteTime = now
            // Resume-aware baseline: the first callback of an attempt only
            // establishes where this attempt started.
            resumeBaseline = max(resumeBaseline, totalBytesWritten)
            samples = [SpeedSample(time: now, bytesNew: 0)]
        }
        latestReportedBytes = max(latestReportedBytes, totalBytesWritten)
        displayedBytes = max(displayedBytes, latestReportedBytes)
        if totalBytesExpectedToWrite > 0 {
            totalBytesExpected = max(totalBytesExpected ?? 0, totalBytesExpectedToWrite)
        }
        appendSampleLocked(SpeedSample(time: now, bytesNew: currentNewBytesLocked()))
        let progress = makeProgressLocked(now: now)
        let handler = progressHandler
        lock.unlock()
        handler?(progress)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        lock.lock()
        guard !isFinished, downloadTask === activeTask else {
            lock.unlock()
            return
        }
        activeTask = nil
        stopStallTimerLocked()
        lock.unlock()

        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            handleServerStatusFailure(http.statusCode)
            return
        }

        // URLSession deletes the temp file when this method returns; park the
        // download in our own temporary location before resuming.
        let kept = FileManager.default.temporaryDirectory
            .appendingPathComponent("wallpapermac-download-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: kept)
        } catch {
            finish(.failure(UpdateDownloadError.writeFailed(error.localizedDescription)))
            return
        }

        let sizeOnDisk = (try? FileManager.default.attributesOfItem(atPath: kept.path))?[.size] as? Int64
        let expected = downloadTask.countOfBytesExpectedToReceive
        let total = max(sizeOnDisk ?? 0, expected > 0 ? expected : 0)
        finish(.success((tempURL: kept, totalBytes: total)))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else {
            // Success is completed in didFinishDownloadingTo.
            return
        }
        guard let downloadTask = task as? URLSessionDownloadTask else { return }
        let nsError = error as NSError
        // URLSession attaches resume data to transport errors; use it so an
        // interrupted weak-network transfer continues instead of restarting.
        let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data

        lock.lock()
        guard !isFinished, downloadTask === activeTask else {
            lock.unlock()
            return
        }
        if isCancellingTask {
            // cancel(byProducingResumeData:) owns the retry path.
            lock.unlock()
            return
        }
        activeTask = nil
        stopStallTimerLocked()
        let decision = retryState.recordFailure(
            .transport(nsError.localizedDescription),
            canResume: resumeData != nil
        )
        lock.unlock()
        handle(decision, resumeData: resumeData)
    }

    // MARK: - Completion

    private func handleServerStatusFailure(_ statusCode: Int) {
        if statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode) {
            let decision = retryState.recordFailure(.server(statusCode: statusCode), canResume: false)
            handle(decision, resumeData: nil)
        } else {
            finish(.failure(UpdateDownloadError.httpStatus(statusCode)))
        }
    }

    private func finish(_ result: Result<(tempURL: URL, totalBytes: Int64), Error>) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = self.continuation
        self.continuation = nil
        progressHandler = nil
        activeTask = nil
        stopStallTimerLocked()
        let session = self.session
        self.session = nil
        lock.unlock()

        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }
}
