import Foundation

/// `URLSessionDownloadTask` wrapper that reports byte progress while the
/// system streams the file to disk. The async `URLSession.download(for:)`
/// convenience API only surfaces a final result, which turns the UI progress
/// bar into an indeterminate spinner.
final class ProgressDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(tempURL: URL, totalBytes: Int64), Error>?
    private var progressHandler: (@Sendable (UpdateDownloadProgress) -> Void)?
    private var session: URLSession?

    func download(
        from url: URL,
        timeout: TimeInterval = 600,
        onProgress: (@Sendable (UpdateDownloadProgress) -> Void)?
    ) async throws -> (tempURL: URL, totalBytes: Int64) {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            self.progressHandler = onProgress
            lock.unlock()

            var request = URLRequest(url: url)
            request.timeoutInterval = timeout
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("WallpaperMac", forHTTPHeaderField: "User-Agent")

            let configuration = URLSessionConfiguration.ephemeral
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            lock.lock()
            self.session = session
            lock.unlock()
            session.downloadTask(with: request).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        lock.lock()
        let handler = progressHandler
        lock.unlock()
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        handler?(UpdateDownloadProgress(bytesReceived: totalBytesWritten, totalBytes: total))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
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

        let total = downloadTask.countOfBytesExpectedToReceive > 0
            ? downloadTask.countOfBytesExpectedToReceive
            : ((try? FileManager.default.attributesOfItem(atPath: kept.path)[.size] as? Int64) ?? 0)

        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: kept)
            finish(.failure(UpdateDownloadError.httpStatus(http.statusCode)))
            return
        }
        finish(.success((tempURL: kept, totalBytes: total)))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(UpdateDownloadError.network(error.localizedDescription)))
        }
    }

    private func finish(_ result: Result<(tempURL: URL, totalBytes: Int64), Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        self.progressHandler = nil
        let session = self.session
        self.session = nil
        lock.unlock()
        session?.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }
}
