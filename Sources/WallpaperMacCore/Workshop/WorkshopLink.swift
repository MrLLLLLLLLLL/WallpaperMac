import Foundation

/// A Steam Workshop item reference parsed from a pasted link, `steam://` URL, or bare id.
/// Parsing never touches the network so the UI can validate input before any request.
public struct WorkshopLink: Equatable, Sendable, Codable {
    public let itemID: String

    public init(itemID: String) {
        self.itemID = itemID
    }

    /// Accepts:
    /// - `https://steamcommunity.com/sharedfiles/filedetails/?id=…`
    /// - `https://steamcommunity.com/workshop/filedetails/?id=…`
    /// - `steam://url/CommunityFilePage/<id>`
    /// - a bare numeric id of six or more digits
    /// Anything else returns nil; short numbers (years) stay search text.
    public static func parse(_ raw: String) -> WorkshopLink? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
            if scheme == "steam" {
                // steam://url/CommunityFilePage/<id>
                let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let components = path.split(separator: "/")
                if components.count >= 2,
                   components[components.count - 2].lowercased() == "communityfilepage",
                   let id = normalizeID(String(components.last!)) {
                    return WorkshopLink(itemID: id)
                }
                return nil
            }
            if scheme == "http" || scheme == "https" {
                guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                      let host = components.host?.lowercased(),
                      host == "steamcommunity.com" || host.hasSuffix(".steamcommunity.com") else {
                    return nil
                }
                let path = components.path.lowercased()
                guard path.contains("filedetails") else { return nil }
                guard let idItem = components.queryItems?.first(where: { $0.name.lowercased() == "id" }),
                      let id = normalizeID(idItem.value ?? "") else {
                    return nil
                }
                return WorkshopLink(itemID: id)
            }
            return nil
        }

        // Bare id: digits only, six or more, no leading zeros games.
        return normalizeID(trimmed).map(WorkshopLink.init)
    }

    private static func normalizeID(_ text: String) -> String? {
        let digits = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard digits.count >= 6, digits.count <= 20,
              digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = UInt64(digits), value > 0 else {
            return nil
        }
        // Reject values that are only significant as a year (1900-2100) when
        // they have exactly four digits — already excluded by count >= 6.
        return digits
    }

    /// The Steam app id for Wallpaper Engine.
    public static let wallpaperEngineAppID = "431960"
}
