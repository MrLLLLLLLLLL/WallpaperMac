import Foundation

/// Checks GitHub Releases for a version newer than the running application.
///
/// Parsing is a pure function of the API payload so release-shape handling can
/// be tested without network access. The network path stays thin and only maps
/// transport failures onto `UpdateCheckError`.
public struct UpdateChecker: Sendable {
    public static let defaultRepository = "MrLLLLLLLLLL/WallpaperMac"

    private let apiURL: URL
    private let session: URLSession
    private let currentVersion: String

    public init(
        currentVersion: String,
        repository: String = UpdateChecker.defaultRepository,
        session: URLSession = .shared
    ) {
        self.init(
            currentVersion: currentVersion,
            apiURL: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!,
            session: session
        )
    }

    public init(currentVersion: String, apiURL: URL, session: URLSession = .shared) {
        self.currentVersion = currentVersion
        self.apiURL = apiURL
        self.session = session
    }

    // MARK: - Pure parsing

    public static func parseLatestRelease(
        data: Data,
        currentVersion: String
    ) throws -> UpdateCheckResult {
        guard let current = SemVer(string: currentVersion) else {
            throw UpdateCheckError.invalidCurrentVersion(currentVersion)
        }

        let release: GitHubRelease
        do {
            release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw UpdateCheckError.invalidResponse
        }

        guard let tag = release.tagName, !tag.isEmpty else {
            throw UpdateCheckError.invalidResponse
        }
        guard let remote = SemVer(string: tag) else {
            throw UpdateCheckError.invalidReleaseVersion(tag)
        }

        guard remote > current else {
            return .upToDate(currentVersion: current.description)
        }

        let assets = release.assets ?? []
        guard let zip = assets.first(where: { Self.isZipAssetName($0.name) && Self.assetName($0.name, matchesVersion: remote.description) }),
              let zipURLString = zip.browserDownloadUrl,
              let zipURL = URL(string: zipURLString) else {
            throw UpdateCheckError.missingAsset("WallpaperMac-v\(remote)-macOS.zip")
        }

        // checksums/sig must belong to the same release version as the zip.
        let checksumsAsset = assets.first(where: {
            Self.isChecksumsAssetName($0.name) && Self.assetName($0.name, matchesVersion: remote.description)
        })
        let checksumsURL = checksumsAsset.flatMap { asset -> URL? in
            guard let urlString = asset.browserDownloadUrl else { return nil }
            return URL(string: urlString)
        }
        let signatureAsset = assets.first(where: {
            Self.isSignatureAssetName($0.name) && Self.assetName($0.name, matchesVersion: remote.description)
        })
        let signatureURL = signatureAsset.flatMap { asset -> URL? in
            guard let urlString = asset.browserDownloadUrl else { return nil }
            return URL(string: urlString)
        }

        let notes = release.body?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let releasePageURL = (release.htmlUrl).flatMap(URL.init(string:))
            ?? URL(string: "https://github.com/\(defaultRepository)/releases/tag/\(tag)")!
        let publishedAt = (release.publishedAt).flatMap(Self.parsePublishedAt)

        return .updateAvailable(
            AvailableUpdate(
                version: remote.description,
                releaseNotes: notes,
                releasePageURL: releasePageURL,
                zipURL: zipURL,
                checksumsURL: checksumsURL,
                signatureURL: signatureURL,
                publishedAt: publishedAt
            )
        )
    }

    // MARK: - Network

    public func check() async throws -> UpdateCheckResult {
        var request = URLRequest(url: apiURL)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(
            "WallpaperMac/\(currentVersion)",
            forHTTPHeaderField: "User-Agent"
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UpdateCheckError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UpdateCheckError.invalidResponse
        }

        switch http.statusCode {
        case 200..<300:
            return try Self.parseLatestRelease(data: data, currentVersion: currentVersion)
        case 404:
            throw UpdateCheckError.notFound
        case 403, 429:
            throw UpdateCheckError.rateLimited
        default:
            throw UpdateCheckError.network("HTTP \(http.statusCode)")
        }
    }

    // MARK: - Helpers

    public static func isZipAssetName(_ name: String?) -> Bool {
        matchesAssetName(name, pattern: #"^WallpaperMac-v\d+\.\d+\.\d+-macOS\.zip$"#)
    }

    public static func isChecksumsAssetName(_ name: String?) -> Bool {
        matchesAssetName(name, pattern: #"^WallpaperMac-v\d+\.\d+\.\d+-SHA256SUMS\.txt$"#)
    }

    public static func isSignatureAssetName(_ name: String?) -> Bool {
        matchesAssetName(name, pattern: #"^WallpaperMac-v\d+\.\d+\.\d+-macOS\.zip\.sig$"#)
    }

    /// True when the asset version matches the release tag (e.g. v0.2.6).
    public static func assetName(_ name: String?, matchesVersion version: String) -> Bool {
        guard let name else { return false }
        return name.contains("-v" + version + "-")
    }

    static func matchesAssetName(_ name: String?, pattern: String) -> Bool {
        guard let name else { return false }
        return name.range(of: pattern, options: .regularExpression) != nil
    }

    private static func parsePublishedAt(_ raw: String) -> Date? {
        ISO8601DateFormatter().date(from: raw)
    }
}

// MARK: - GitHub payload

private struct GitHubRelease: Decodable {
    let tagName: String?
    let body: String?
    let htmlUrl: String?
    let publishedAt: String?
    let assets: [GitHubAsset]?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body
        case htmlUrl = "html_url"
        case publishedAt = "published_at"
        case assets
    }
}

private struct GitHubAsset: Decodable {
    let name: String?
    let browserDownloadUrl: String?

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadUrl = "browser_download_url"
    }
}
