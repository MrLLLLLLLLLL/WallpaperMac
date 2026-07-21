import Foundation

public struct WallpaperLibraryConfiguration: Codable, Equatable, Sendable {
    public let libraryPath: String
    public let bookmarkData: Data?

    public init(libraryURL: URL, bookmarkData: Data? = nil) {
        self.libraryPath = libraryURL.standardizedFileURL.path
        self.bookmarkData = bookmarkData
    }

    public var libraryURL: URL {
        URL(fileURLWithPath: libraryPath, isDirectory: true)
    }
}

public final class WallpaperLibraryConfigurationStore {
    public let configurationDirectory: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private var configurationURL: URL {
        configurationDirectory.appendingPathComponent("library-configuration.json")
    }

    public init(configurationDirectory: URL, fileManager: FileManager = .default) {
        self.configurationDirectory = configurationDirectory
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    public func load() throws -> WallpaperLibraryConfiguration? {
        guard fileManager.fileExists(atPath: configurationURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: configurationURL)
        return try decoder.decode(WallpaperLibraryConfiguration.self, from: data)
    }

    @discardableResult
    public func save(libraryURL: URL, bookmarkData: Data? = nil) throws -> WallpaperLibraryConfiguration {
        let configuration = WallpaperLibraryConfiguration(libraryURL: libraryURL, bookmarkData: bookmarkData)
        try fileManager.createDirectory(at: configurationDirectory, withIntermediateDirectories: true)
        let data = try encoder.encode(configuration)
        try data.write(to: configurationURL, options: .atomic)
        return configuration
    }
}
