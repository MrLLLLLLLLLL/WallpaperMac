import Foundation

public struct UpdateDownloadProgress: Equatable, Sendable {
    public let bytesReceived: Int64
    public let totalBytes: Int64?

    public init(bytesReceived: Int64, totalBytes: Int64?) {
        self.bytesReceived = bytesReceived
        self.totalBytes = totalBytes
    }

    /// `0...1` when the server reports a content length, otherwise `nil`.
    public var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(bytesReceived) / Double(totalBytes))
    }
}

public struct UpdateDownloadOutcome: Equatable, Sendable {
    /// Verified zip on disk inside the staging directory.
    public let zipFileURL: URL
    public let sha256: String
    public let stagingDirectory: URL

    public init(zipFileURL: URL, sha256: String, stagingDirectory: URL) {
        self.zipFileURL = zipFileURL
        self.sha256 = sha256
        self.stagingDirectory = stagingDirectory
    }
}

public enum UpdateDownloadError: Error, Equatable, Sendable, LocalizedError {
    case network(String)
    case httpStatus(Int)
    case checksumsUnavailable
    case checksumMissingForAsset(String)
    case checksumMismatch(expected: String, actual: String)
    case signatureMissing
    case signatureInvalid
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .network(let message):
            return "下载失败：\(message)"
        case .httpStatus(let code):
            return "下载失败：HTTP \(code)"
        case .checksumsUnavailable:
            return "无法获取校验文件，已中止安装"
        case .checksumMissingForAsset(let name):
            return "校验文件中缺少 \(name) 的记录"
        case .checksumMismatch(let expected, let actual):
            return "文件校验失败（期望 \(expected.prefix(12))…，实际 \(actual.prefix(12))…）"
        case .signatureMissing:
            return "更新包缺少数字签名，已中止安装"
        case .signatureInvalid:
            return "更新包数字签名校验失败，已中止安装"
        case .writeFailed(let message):
            return "无法写入临时文件：\(message)"
        }
    }
}

/// Downloads a release zip into a staging directory and refuses to proceed
/// unless the artifact matches the published SHA-256 and Ed25519 signature.
public actor UpdateDownloader {
    private let session: URLSession
    private let signaturePolicy: UpdateSignaturePolicy
    private let publicKeyBase64: String

    public init(
        session: URLSession = .shared,
        signaturePolicy: UpdateSignaturePolicy = .required,
        publicKeyBase64: String = UpdateSignature.releasePublicKeyBase64
    ) {
        self.session = session
        self.signaturePolicy = signaturePolicy
        self.publicKeyBase64 = publicKeyBase64
    }

    public func downloadAndVerify(
        update: AvailableUpdate,
        stagingDirectory: URL,
        onProgress: (@Sendable (UpdateDownloadProgress) -> Void)? = nil
    ) async throws -> UpdateDownloadOutcome {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        // Integrity source of truth first: without a published checksum we
        // refuse to install anything, even if the download itself succeeded.
        guard let checksumsURL = update.checksumsURL else {
            throw UpdateDownloadError.checksumsUnavailable
        }
        let checksumsData = try await fetchData(from: checksumsURL)
        let zipName = update.zipURL.lastPathComponent
        guard let expectedHash = UpdateArtifactVerifier.expectedChecksum(
            forAssetNamed: zipName,
            inChecksumsFile: checksumsData
        ) else {
            throw UpdateDownloadError.checksumMissingForAsset(zipName)
        }

        let destination = stagingDirectory.appendingPathComponent(zipName)
        _ = try await downloadFile(from: update.zipURL, to: destination, onProgress: onProgress)

        let actualHash: String
        do {
            actualHash = try UpdateArtifactVerifier.sha256Hex(ofFileAt: destination)
        } catch {
            throw UpdateDownloadError.writeFailed(error.localizedDescription)
        }
        guard actualHash == expectedHash else {
            try? fileManager.removeItem(at: destination)
            throw UpdateDownloadError.checksumMismatch(expected: expectedHash, actual: actualHash)
        }

        try await verifySignatureIfNeeded(update: update, zipFileURL: destination)

        return UpdateDownloadOutcome(
            zipFileURL: destination,
            sha256: actualHash,
            stagingDirectory: stagingDirectory
        )
    }

    private func verifySignatureIfNeeded(update: AvailableUpdate, zipFileURL: URL) async throws {
        switch signaturePolicy {
        case .required:
            guard let signatureURL = update.signatureURL else {
                try? FileManager.default.removeItem(at: zipFileURL)
                throw UpdateDownloadError.signatureMissing
            }
            try await verifySignature(signatureURL: signatureURL, zipFileURL: zipFileURL)
        case .ifPresent:
            guard let signatureURL = update.signatureURL else { return }
            try await verifySignature(signatureURL: signatureURL, zipFileURL: zipFileURL)
        }
    }

    private func verifySignature(signatureURL: URL, zipFileURL: URL) async throws {
        let signatureText: String
        do {
            let data = try await fetchData(from: signatureURL)
            guard let text = String(data: data, encoding: .utf8) else {
                throw UpdateDownloadError.signatureInvalid
            }
            signatureText = text
        } catch let error as UpdateDownloadError {
            try? FileManager.default.removeItem(at: zipFileURL)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: zipFileURL)
            throw UpdateDownloadError.signatureInvalid
        }

        guard let signatureBase64 = UpdateSignature.parseSignatureFile(signatureText) else {
            try? FileManager.default.removeItem(at: zipFileURL)
            throw UpdateDownloadError.signatureInvalid
        }

        let isValid: Bool
        do {
            isValid = try UpdateSignature.verify(
                fileAt: zipFileURL,
                signatureBase64: signatureBase64,
                publicKeyBase64: publicKeyBase64
            )
        } catch {
            try? FileManager.default.removeItem(at: zipFileURL)
            throw UpdateDownloadError.signatureInvalid
        }
        guard isValid else {
            try? FileManager.default.removeItem(at: zipFileURL)
            throw UpdateDownloadError.signatureInvalid
        }
    }

    // MARK: - Transport

    private func fetchData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("WallpaperMac", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UpdateDownloadError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw UpdateDownloadError.network("invalid response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw UpdateDownloadError.httpStatus(http.statusCode)
        }
        return data
    }

    private func downloadFile(
        from url: URL,
        to destination: URL,
        onProgress: (@Sendable (UpdateDownloadProgress) -> Void)?
    ) async throws -> Int64 {
        // System-managed transfer with live byte progress: the bytes never
        // stream through user-space one byte at a time.
        let downloader = ProgressDownload()
        let (tempURL, totalBytes) = try await downloader.download(from: url, onProgress: onProgress)

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.removeItem(at: destination)
        }
        do {
            try fileManager.moveItem(at: tempURL, to: destination)
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw UpdateDownloadError.writeFailed(error.localizedDescription)
        }

        let received = (try? fileManager.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? totalBytes
        onProgress?(UpdateDownloadProgress(bytesReceived: received, totalBytes: totalBytes))
        return received
    }
}
