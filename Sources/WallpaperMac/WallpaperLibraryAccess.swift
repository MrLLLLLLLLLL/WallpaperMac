import Foundation
import WallpaperMacCore

@MainActor
final class WallpaperLibraryAccess {
    private let configurationStore: WallpaperLibraryConfigurationStore
    private var securityScopedURL: URL?

    init(configurationDirectory: URL) {
        configurationStore = WallpaperLibraryConfigurationStore(configurationDirectory: configurationDirectory)
    }

    deinit {
        securityScopedURL?.stopAccessingSecurityScopedResource()
    }

    func restore(defaultURL: URL, persistedPath: String?) -> URL {
        let configuration = try? configurationStore.load()
        let selectedURL = persistedPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? configuration?.libraryURL
            ?? defaultURL

        if let configuration,
           configuration.libraryURL.standardizedFileURL == selectedURL.standardizedFileURL {
            beginAccess(using: configuration.bookmarkData, fallbackURL: selectedURL)
        }
        return selectedURL.standardizedFileURL
    }

    func persist(url: URL) throws {
        let normalizedURL = url.standardizedFileURL
        let bookmarkData = try? normalizedURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        _ = try configurationStore.save(libraryURL: normalizedURL, bookmarkData: bookmarkData)
        beginAccess(using: bookmarkData, fallbackURL: normalizedURL)
    }

    private func beginAccess(using bookmarkData: Data?, fallbackURL: URL) {
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil

        guard let bookmarkData else { return }
        var isStale = false
        guard let resolvedURL = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return
        }

        if resolvedURL.startAccessingSecurityScopedResource() {
            securityScopedURL = resolvedURL
        }
        if isStale {
            let refreshedBookmark = try? resolvedURL.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            _ = try? configurationStore.save(libraryURL: fallbackURL, bookmarkData: refreshedBookmark)
        }
    }
}
