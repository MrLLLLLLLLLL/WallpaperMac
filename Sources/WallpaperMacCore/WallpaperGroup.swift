import Foundation

public struct WallpaperGroup: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public let createdAt: Date

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}
