import Foundation

/// One-shot authorization for opening an external URL from a web wallpaper.
/// WebKit's `.linkActivated` also covers script-generated clicks, so it is not
/// sufficient evidence of a user gesture. A native mouseUp first arms this
/// gate with the link's absolute URL; the matching navigation consumes it once.
public struct ExternalNavigationAuthorizer: Equatable, Sendable {
    public static let gestureLifetime: TimeInterval = 1

    private struct Approval: Equatable, Sendable {
        let url: String
        let expiresAt: TimeInterval
    }
    private var approval: Approval?

    public init() {}

    public mutating func prepare(
        url: URL,
        now: TimeInterval,
        interactionEnabled: Bool,
        isPlaying: Bool,
        isSystemSuspended: Bool
    ) {
        guard WebWallpaperURL.isValid(url), interactionEnabled, isPlaying, !isSystemSuspended else {
            approval = nil
            return
        }
        approval = Approval(
            url: Self.normalized(url),
            expiresAt: now + Self.gestureLifetime
        )
    }

    public mutating func consume(
        url: URL,
        now: TimeInterval,
        interactionEnabled: Bool,
        isPlaying: Bool,
        isSystemSuspended: Bool
    ) -> Bool {
        defer { approval = nil }
        guard let approval,
              WebWallpaperURL.isValid(url),
              interactionEnabled,
              isPlaying,
              !isSystemSuspended,
              now <= approval.expiresAt,
              approval.url == Self.normalized(url) else {
            return false
        }
        return true
    }

    public mutating func cancel() {
        approval = nil
    }

    private static func normalized(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if (components.scheme == "http" && components.port == 80)
            || (components.scheme == "https" && components.port == 443) {
            components.port = nil
        }
        if components.path.isEmpty { components.path = "/" }
        return components.string ?? url.absoluteString
    }
}
