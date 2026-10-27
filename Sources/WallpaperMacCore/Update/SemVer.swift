import Foundation

/// Semantic version parsing and comparison for release tags.
///
/// Accepts the tag shapes used by GitHub releases (`0.2.5`, `v0.2.5`) and
/// normalizes them to a `major.minor.patch` triple so update checks never
/// depend on string ordering.
public struct SemVer: Equatable, Comparable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses version text with an optional `v`/`V` prefix and up to three
    /// numeric components (`0.2.5`, `v1.0`, `2`). Missing components are zero.
    /// Anything non-numeric after the numeric prefix is rejected.
    public init?(string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" {
            text = String(text.dropFirst())
        }
        guard !text.isEmpty else { return nil }

        // Reject build metadata / prerelease suffixes such as `0.2.5-beta`;
        // release assets are published from plain version tags only.
        let components = text.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count <= 3 else { return nil }

        var numbers: [Int] = []
        for component in components {
            guard !component.isEmpty, let value = Int(component), value >= 0 else {
                return nil
            }
            numbers.append(value)
        }
        while numbers.count < 3 {
            numbers.append(0)
        }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    public var description: String {
        "\(major).\(minor).\(patch)"
    }

    public static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}
