import Foundation

/// Formats application release metadata without coupling the settings UI to
/// Bundle lookup details.
public struct ApplicationVersionInfo: Equatable, Sendable {
    /// Version shown when the app runs outside a packaged bundle (no
    /// `Info.plist`). Keep this in sync with the repository `VERSION` file;
    /// it is the single source the app layer reads during development.
    public static let developmentFallbackVersion = "0.2.16"

    public let version: String
    public let build: String?

    public init(infoDictionary: [String: Any], fallbackVersion: String) {
        version = Self.nonEmptyString(infoDictionary["CFBundleShortVersionString"]) ?? fallbackVersion
        build = Self.nonEmptyString(infoDictionary["CFBundleVersion"])
    }

    public var displayText: String {
        guard let build, build != version else {
            return "版本 \(version)"
        }
        return "版本 \(version)（构建 \(build)）"
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
