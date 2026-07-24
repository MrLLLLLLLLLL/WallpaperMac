import Foundation

/// Formats application release metadata without coupling the settings UI to
/// Bundle lookup details.
public struct ApplicationVersionInfo: Equatable, Sendable {
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
