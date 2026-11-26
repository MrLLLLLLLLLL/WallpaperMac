import AppKit
import AVFoundation
import CryptoKit
import Foundation
import QuartzCore
import WallpaperMacCore

struct TestFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

@discardableResult
func expect<T: Equatable>(_ actual: T, equals expected: T, _ message: String) throws -> T {
    guard actual == expected else {
        throw TestFailure(message: "\(message)\nexpected: \(expected)\nactual: \(actual)")
    }
    return actual
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw TestFailure(message: message) }
}

func require<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw TestFailure(message: message) }
    return value
}

struct Fixture {
    let root: URL
    let library: URL
    let store: WallpaperStore

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WallpaperMacTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        library = root.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = WallpaperStore(libraryURL: library)
    }
}


func testWallpaperMetadataRoundTrips() throws {
    let metadata = WallpaperMetadata(
        pixelWidth: 3840,
        pixelHeight: 2160,
        durationSeconds: 92.5,
        fileSizeBytes: 42_000_000,
        fileExtension: "mp4"
    )
    let data = try JSONEncoder().encode(metadata)
    let decoded = try JSONDecoder().decode(WallpaperMetadata.self, from: data)
    try expect(decoded, equals: metadata, "wallpaper metadata should round-trip")
}

func testLegacyWallpaperJSONWithoutMetadataDecodes() throws {
    let fixture = try Fixture()
    let id = UUID()
    let source = fixture.root.appendingPathComponent("legacy.jpg")
    try Data("legacy".utf8).write(to: source)
    let legacy: [String: Any] = [
        "id": id.uuidString,
        "name": "legacy",
        "type": "image",
        "sourceURL": source.absoluteString,
        "storageMode": "externalReference",
        "availability": "available",
        "createdAt": "2026-07-20T00:00:00Z",
        "isFavorite": true
    ]
    let data = try JSONSerialization.data(withJSONObject: [legacy])
    try FileManager.default.createDirectory(at: fixture.library, withIntermediateDirectories: true)
    try data.write(to: fixture.library.appendingPathComponent("wallpapers.json"))

    let items = try fixture.store.items()
    try expect(items.count, equals: 1, "legacy wallpaper JSON should decode")
    try expect(items[0].metadata, equals: nil, "legacy wallpaper should default metadata to nil")
    try expect(items[0].isFavorite, "legacy favorite should be preserved")
}

func testBulkMetadataSavePreservesWallpaperState() throws {
    let fixture = try Fixture()
    let source = fixture.root.appendingPathComponent("wallpaper.png")
    try Data("image".utf8).write(to: source)
    var item = try fixture.store.importItem(at: source, storageMode: .externalReference)
    item.isFavorite = true
    let groupID = UUID()
    item.groupID = groupID
    item.metadata = WallpaperMetadata(pixelWidth: 1920, pixelHeight: 1080, fileSizeBytes: 5, fileExtension: "png")
    try fixture.store.save(items: [item])

    let reloaded = try fixture.store.items()
    guard let restored = reloaded.first else {
        throw TestFailure(message: "bulk metadata save should preserve the item")
    }
    try expect(restored.id, equals: item.id, "bulk metadata save should preserve the item ID")
    try expect(restored.isFavorite, equals: item.isFavorite, "bulk metadata save should preserve favorite state")
    try expect(restored.groupID, equals: item.groupID, "bulk metadata save should preserve group state")
    try expect(restored.metadata, equals: item.metadata, "bulk metadata save should preserve metadata")
}

func testDetectsWallpaperTypes() throws {
    try expect(WallpaperType.detect(from: URL(fileURLWithPath: "/tmp/photo.jpg")), equals: .image, "detects image")
    try expect(WallpaperType.detect(from: URL(fileURLWithPath: "/tmp/loop.mp4")), equals: .video, "detects video")
    try expect(WallpaperType.detect(from: URL(fileURLWithPath: "/tmp/site/index.html")), equals: .web, "detects web")
}

func testRemoteWebWallpaperImportPersistsWithoutNetworkAccess() throws {
    let fixture = try Fixture()
    let url = URL(string: "https://example.com/wallpaper?scene=night#top")!
    let httpURL = URL(string: "http://example.com/wallpaper")!
    try expect(WebWallpaperURL.isValid(url), "HTTPS website URLs should be accepted")
    try expect(WebWallpaperURL.isValid(httpURL), "HTTP website URLs should be accepted")
    let item = try fixture.store.importWebURL(url)

    try expect(item.type, equals: .web, "URL import should create a web wallpaper")
    try expect(item.sourceURL, equals: url, "the exact URL should be preserved")
    try expect(item.storageMode, equals: .externalReference, "a remote URL should never be copied as a file")
    let managedAssets = try FileManager.default.contentsOfDirectory(
        at: fixture.library.appendingPathComponent("Assets", isDirectory: true),
        includingPropertiesForKeys: nil,
        options: []
    )
    try expect(managedAssets.isEmpty, "URL import should not create managed site assets")

    let refreshed = try fixture.store.refreshAvailability(for: item)
    try expect(refreshed.availability, equals: .available, "network availability must not control library persistence")
    let persistedItems = try fixture.store.items()
    try expect(persistedItems.count, equals: 1, "the remote item should survive a library refresh")

    _ = try fixture.store.remove(item: refreshed)
    let remainingItems = try fixture.store.items()
    try expect(remainingItems.isEmpty, "removing the URL should remove its record")

    let invalidURLs = [
        URL(string: "file:///tmp/index.html")!,
        URL(string: "javascript:alert(1)")!,
        URL(string: "https://user:password@example.com")!
    ]
    for invalidURL in invalidURLs {
        try expect(!WebWallpaperURL.isValid(invalidURL), "non-web or credential URLs should be rejected")
        do {
            _ = try fixture.store.importWebURL(invalidURL)
            throw TestFailure(message: "invalid remote URL should not be imported")
        } catch WallpaperStoreError.invalidWebURL { }
    }
}

func mp4Box(_ type: String, payload: Data) -> Data {
    precondition(type.utf8.count == 4)
    var data = Data()
    let size = UInt32(payload.count + 8)
    data.append(contentsOf: withUnsafeBytes(of: size.bigEndian, Array.init))
    data.append(Data(type.utf8))
    data.append(payload)
    return data
}

func makeVideoFixtureData(sampleEntryType: String, includeFalsePositiveInMediaData: Bool) -> Data {
    let sampleEntryPayload = Data(repeating: 0, count: 96)
    let sampleEntry = mp4Box(sampleEntryType, payload: sampleEntryPayload)
    let stsdPayload = Data([0, 0, 0, 0, 0, 0, 0, 1]) + sampleEntry
    let stsd = mp4Box("stsd", payload: stsdPayload)
    let stbl = mp4Box("stbl", payload: stsd)
    let minf = mp4Box("minf", payload: stbl)
    let mdia = mp4Box("mdia", payload: minf)
    let trak = mp4Box("trak", payload: mdia)
    let moov = mp4Box("moov", payload: trak)
    let ftyp = mp4Box("ftyp", payload: Data([0x69, 0x73, 0x6f, 0x6d, 0, 0, 0, 1, 0x69, 0x73, 0x6f, 0x6d]))
    var mediaPayload = Data(repeating: 0x42, count: 128)
    if includeFalsePositiveInMediaData {
        mediaPayload.replaceSubrange(20..<24, with: Data([0, 0, 0, 100]))
        mediaPayload.replaceSubrange(24..<28, with: Data("hev1".utf8))
    }
    let mdat = mp4Box("mdat", payload: mediaPayload)
    return ftyp + moov + mdat
}

func testVideoPlaybackCompatibilityRequiresCacheForAV1() throws {
    try expect(
        VideoPlaybackCompatibility.requiresConversion(codec: "av01", isPlayable: false),
        equals: true,
        "AV1 videos must use a compatibility playback path when AVFoundation cannot play them"
    )
    try expect(
        VideoPlaybackCompatibility.requiresConversion(codec: "av01", isPlayable: true),
        equals: true,
        "known AV1 videos should remain on the compatibility path even if a decoder reports playable"
    )
    try expect(
        VideoPlaybackCompatibility.requiresConversion(codec: "avc1", isPlayable: true),
        equals: false,
        "native H.264 videos should continue to use the original file"
    )
    try expect(
        VideoPlaybackCompatibility.requiresConversion(codec: nil, isPlayable: false),
        equals: true,
        "unknown codecs that are not playable should use the compatibility path"
    )
    try expect(
        VideoPlaybackCompatibility.preferredForwardBufferSeconds > 0,
        "native AVPlayer playback should use a bounded forward buffer"
    )
    try expect(
        VideoPlaybackCompatibility.preferredForwardBufferSeconds <= 5,
        "native AVPlayer playback should not preload large videos into an unbounded buffer"
    )
}

func testVideoCompatibilityStreamPlanPipesDecodedFrames() throws {
    let source = URL(fileURLWithPath: "/Volumes/Media/large-input.mp4")
    let plan = VideoCompatibilityStreamPlan(sourceURL: source)
    try expect(plan.width, equals: 1920, "streaming playback should cap decoded frame width")
    try expect(plan.height, equals: 1080, "streaming playback should cap decoded frame height")
    try expect(plan.arguments.contains(source.path), "streaming command should read the original source")
    try expect(plan.arguments.contains("pipe:1"), "streaming command should emit frames to stdout")
    try expect(plan.arguments.contains("nv12"), "streaming command should use an efficient video frame pixel format")
    try expect(plan.arguments.contains("-f"), "streaming command should explicitly select raw frame output")
}


func testVideoContainerCompatibilityNormalizesRealHev1Entries() throws {
    let fixture = try Fixture()
    let source = fixture.root.appendingPathComponent("sample.mp4")
    try makeVideoFixtureData(sampleEntryType: "hev1", includeFalsePositiveInMediaData: true).write(to: source)

    let managed = try fixture.store.importItem(at: source, storageMode: .managedCopy)
    let managedData = try Data(contentsOf: managed.sourceURL)
    try expect(managedData.range(of: Data("hvc1".utf8)) != nil, "managed HEVC copy should use hvc1 sample entry")
    try expect(try VideoContainerCompatibility.needsHVC1Normalization(at: managed.sourceURL), equals: false, "managed HEVC copy should not retain a real hev1 sample entry")
    try expect(managed.playbackURL, equals: nil, "managed copy should normalize in place without a proxy")
}

func testVideoContainerCompatibilityIgnoresMediaPayloadLookalikes() throws {
    let fixture = try Fixture()
    let source = fixture.root.appendingPathComponent("lookalike.mp4")
    try makeVideoFixtureData(sampleEntryType: "avc1", includeFalsePositiveInMediaData: true).write(to: source)
    try expect(
        VideoContainerCompatibility.needsHVC1Normalization(at: source),
        equals: false,
        "media payload bytes must not be mistaken for an MP4 sample entry"
    )
}

func testExternalReferenceDoesNotPersistVideoProxy() throws {
    let fixture = try Fixture()
    let source = fixture.root.appendingPathComponent("external.mp4")
    try makeVideoFixtureData(sampleEntryType: "hev1", includeFalsePositiveInMediaData: true).write(to: source)

    let external = try fixture.store.importItem(at: source, storageMode: .externalReference)

    try expect(external.playbackURL, equals: nil, "external references must not persist a playback proxy")
    try expect(FileManager.default.fileExists(atPath: source.path), "external source must remain unchanged")
    let proxyDirectory = fixture.library.appendingPathComponent("VideoProxies")
    let proxyFiles = (try? FileManager.default.contentsOfDirectory(atPath: proxyDirectory.path)) ?? []
    try expect(proxyFiles, equals: [], "external references must not add files to VideoProxies")
}

func testStoreRemovesLegacyExternalPlaybackProxy() throws {
    let fixture = try Fixture()
    let source = fixture.root.appendingPathComponent("legacy.mp4")
    try makeVideoFixtureData(sampleEntryType: "avc1", includeFalsePositiveInMediaData: true).write(to: source)
    let proxyDirectory = fixture.library.appendingPathComponent("VideoProxies", isDirectory: true)
    try FileManager.default.createDirectory(at: proxyDirectory, withIntermediateDirectories: true)
    let proxyURL = proxyDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
    try Data("legacy-proxy".utf8).write(to: proxyURL)
    let item = WallpaperItem(
        name: "legacy",
        type: .video,
        sourceURL: source,
        playbackURL: proxyURL,
        storageMode: .externalReference
    )
    try fixture.store.save(items: [item])

    let refreshed = try fixture.store.refreshAllAvailability().first

    try expect(refreshed?.playbackURL, equals: nil, "loading the library should clear legacy external playback URLs")
    try expect(FileManager.default.fileExists(atPath: proxyURL.path), equals: false, "loading the library should delete the legacy VideoProxies copy")
}

func testManagedImportCopiesFile() throws {
    let fixture = try Fixture()
    let source = fixture.root.appendingPathComponent("sunset.jpg")
    try Data("image".utf8).write(to: source)

    let item = try fixture.store.importItem(at: source, storageMode: .managedCopy)

    try expect(item.type, equals: .image, "managed import type")
    try expect(item.storageMode, equals: .managedCopy, "managed import mode")
    try expect(item.sourceURL != source, "managed import should use a library path")
    try expect(FileManager.default.fileExists(atPath: item.sourceURL.path), "managed copy should exist")
    try expect(try fixture.store.items().count, equals: 1, "managed item should be persisted")
}

func testExternalImportKeepsReference() throws {
    let fixture = try Fixture()
    let source = fixture.root.appendingPathComponent("animation.mp4")
    try Data("video".utf8).write(to: source)

    let item = try fixture.store.importItem(at: source, storageMode: .externalReference)

    try expect(item.type, equals: .video, "external import type")
    try expect(item.storageMode, equals: .externalReference, "external import mode")
    try expect(item.sourceURL, equals: source, "external import path")
    try expect(try fixture.store.items().count, equals: 1, "external item should be persisted")
}

func testReportsMissingExternalFile() throws {
    let fixture = try Fixture()
    let source = fixture.root.appendingPathComponent("missing.png")
    try Data("image".utf8).write(to: source)
    let item = try fixture.store.importItem(at: source, storageMode: .externalReference)
    try FileManager.default.removeItem(at: source)

    let refreshed = try fixture.store.refreshAvailability(for: item)

    try expect(refreshed.availability, equals: .missing, "missing file should be reported")
    try expect(try fixture.store.items().count, equals: 1, "missing item should remain persisted")
}


func testNestedHTMLProjectIsDetected() throws {
    let fixture = try Fixture()
    let project = fixture.root.appendingPathComponent("nested-site", isDirectory: true)
    let pages = project.appendingPathComponent("pages", isDirectory: true)
    try FileManager.default.createDirectory(at: pages, withIntermediateDirectories: true)
    let nestedEntry = pages.appendingPathComponent("home.htm")
    try Data("nested".utf8).write(to: nestedEntry)

    try expect(WallpaperType.detect(from: project), equals: .web, "nested HTML project should be detected")
    try expect(fixture.store.webEntryCandidates(at: project).map(\.standardizedFileURL), equals: [nestedEntry.standardizedFileURL], "nested HTML entry should be listed")
}

func testMissingHTMLEntryIsReported() throws {
    let fixture = try Fixture()
    let project = fixture.root.appendingPathComponent("site", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let entry = project.appendingPathComponent("index.html")
    try Data("index".utf8).write(to: entry)
    let item = try fixture.store.importItem(at: project, storageMode: .externalReference, entryURL: entry)
    try FileManager.default.removeItem(at: entry)

    let refreshed = try fixture.store.refreshAvailability(for: item)
    try expect(refreshed.availability, equals: .missing, "missing HTML entry should be reported")
}

func testDisplayAssignmentsPersist() throws {
    let fixture = try Fixture()
    let assignment = DisplayAssignment(id: "display-1", displayName: "外接显示器", isConnected: true, wallpaperID: UUID(), applicationState: .applied)
    try fixture.store.save(displayAssignments: [assignment])
    let reloaded = WallpaperStore(libraryURL: fixture.library)

    try expect(try reloaded.displayAssignments(), equals: [assignment], "display assignments should persist across store instances")
}

func testManagedCopyOfNestedHTMLEntryPreservesProjectResources() throws {
    let fixture = try Fixture()
    let project = fixture.root.appendingPathComponent("site", isDirectory: true)
    let pages = project.appendingPathComponent("pages", isDirectory: true)
    let styles = pages.appendingPathComponent("styles", isDirectory: true)
    let scripts = pages.appendingPathComponent("scripts", isDirectory: true)
    try FileManager.default.createDirectory(at: styles, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)

    let entry = pages.appendingPathComponent("index.html")
    let stylesheet = styles.appendingPathComponent("site.css")
    let script = scripts.appendingPathComponent("site.js")
    try Data("<link rel=\"stylesheet\" href=\"styles/site.css\"><script src=\"scripts/site.js\"></script>".utf8).write(to: entry)
    try Data("body { color: white; }".utf8).write(to: stylesheet)
    try Data("document.body.dataset.loaded = 'true';".utf8).write(to: script)

    let item = try fixture.store.importItem(at: pages, storageMode: .managedCopy, entryURL: entry)
    let copiedProject = item.sourceURL
    let copiedEntry = copiedProject.appendingPathComponent("index.html")
    let copiedStylesheet = copiedProject.appendingPathComponent("styles/site.css")
    let copiedScript = copiedProject.appendingPathComponent("scripts/site.js")

    try expect(item.sourceURL.hasDirectoryPath, "managed HTML entry should use its copied project directory as source")
    try expect(item.entryURL?.standardizedFileURL, equals: copiedEntry.standardizedFileURL, "entryURL should point to the copied project entry")
    try expect(FileManager.default.fileExists(atPath: copiedEntry.path), "copied HTML entry should exist")
    try expect(FileManager.default.fileExists(atPath: copiedStylesheet.path), "HTML relative stylesheet should exist beside copied entry")
    try expect(FileManager.default.fileExists(atPath: copiedScript.path), "HTML relative script should exist beside copied entry")
}

func testSingleHTMLImportOnlyCopiesSelectedFile() throws {
    let fixture = try Fixture()
    let sourceDirectory = fixture.root.appendingPathComponent("source", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    let entry = sourceDirectory.appendingPathComponent("clock.html")
    try Data("<html><body>clock</body></html>".utf8).write(to: entry)
    let sibling = sourceDirectory.appendingPathComponent("unrelated.txt")
    let hidden = sourceDirectory.appendingPathComponent(".hidden-sentinel")
    let nested = sourceDirectory.appendingPathComponent("nested/payload.bin")
    try Data("unrelated".utf8).write(to: sibling)
    try Data("hidden".utf8).write(to: hidden)
    try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("payload".utf8).write(to: nested)

    let item = try fixture.store.importItem(at: entry, storageMode: .managedCopy)
    try expect(item.sourceURL.isExistingDirectory == false, "single HTML must be stored as a file, not a directory")
    try expect(item.entryURL?.standardizedFileURL, equals: item.sourceURL.standardizedFileURL, "single HTML entry should be the copied file itself")
    try expect(item.relativeEntryPath, equals: nil, "single HTML has no project-relative entry")
    let assets = fixture.library.appendingPathComponent("Assets", isDirectory: true)
    let entries = try FileManager.default.contentsOfDirectory(at: assets, includingPropertiesForKeys: nil)
    try expect(entries.count, equals: 1, "only one UUID asset directory may be created")
    try expect(entries.first?.lastPathComponent, equals: item.id.uuidString, "the asset directory must use the wallpaper UUID")
    try expect(item.sourceURL.lastPathComponent, equals: "clock.html", "the original filename should be preserved inside the UUID directory")
    try expect(item.sourceURL.deletingLastPathComponent().lastPathComponent, equals: item.id.uuidString, "the managed file should be nested inside its UUID directory")
    try expect(!FileManager.default.fileExists(atPath: item.sourceURL.appendingPathComponent("unrelated.txt").path), "unrelated sibling must not be copied")
    try expect(!FileManager.default.fileExists(atPath: item.sourceURL.appendingPathComponent(".hidden-sentinel").path), "hidden sibling must not be copied")
}

func testHTMLProjectImportPersistsSelectedEntry() throws {
    let fixture = try Fixture()
    let project = fixture.root.appendingPathComponent("site", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let index = project.appendingPathComponent("index.html")
    let alternate = project.appendingPathComponent("preview.html")
    try Data("index".utf8).write(to: index)
    try Data("preview".utf8).write(to: alternate)

    try expect(fixture.store.webEntryCandidates(at: project).count, equals: 2, "HTML project should expose both entry files")
    let item = try fixture.store.importItem(at: project, storageMode: .managedCopy, entryURL: alternate)

    try expect(item.type, equals: WallpaperType.web, "HTML project type")
    try expect(item.entryURL?.lastPathComponent, equals: Optional(alternate.lastPathComponent), "selected HTML entry")
    try expect(FileManager.default.fileExists(atPath: item.sourceURL.appendingPathComponent(alternate.lastPathComponent).path), "managed HTML project should copy directory")
}

func testUnsupportedAndMissingSourcesFailClearly() throws {
    let fixture = try Fixture()
    let unsupported = fixture.root.appendingPathComponent("notes.pdf")
    try Data("pdf".utf8).write(to: unsupported)
    do {
        _ = try fixture.store.importItem(at: unsupported, storageMode: .externalReference)
        throw TestFailure(message: "unsupported source should fail")
    } catch let error as WallpaperStoreError {
        try expect(error, equals: .unsupportedSource(unsupported), "unsupported source error")
    }

    let missing = fixture.root.appendingPathComponent("missing.mp4")
    do {
        _ = try fixture.store.importItem(at: missing, storageMode: .externalReference)
        throw TestFailure(message: "missing source should fail")
    } catch let error as WallpaperStoreError {
        try expect(error, equals: .sourceMissing(missing), "missing source error")
    }
}

func testPersistenceAndAvailabilityRecovery() throws {
    let fixture = try Fixture()
    let source = fixture.root.appendingPathComponent("photo.png")
    try Data("image".utf8).write(to: source)
    let item = try fixture.store.importItem(at: source, storageMode: .externalReference)
    try FileManager.default.removeItem(at: source)
    let missing = try fixture.store.refreshAvailability(for: item)
    try expect(missing.availability, equals: .missing, "missing state persists")
    try Data("restored".utf8).write(to: source)
    let restored = try fixture.store.refreshAvailability(for: missing)
    try expect(restored.availability, equals: .available, "available state recovers")
    let reloaded = WallpaperStore(libraryURL: fixture.library)
    try expect(try reloaded.items().first?.id, equals: item.id, "index should persist across store instances")
}


func testRelocatesMissingExternalWallpaper() throws {
    let fixture = try Fixture()
    let original = fixture.root.appendingPathComponent("original.jpg")
    let replacement = fixture.root.appendingPathComponent("replacement.jpg")
    try Data("image".utf8).write(to: original)
    try Data("replacement".utf8).write(to: replacement)

    let item = try fixture.store.importItem(at: original, storageMode: .externalReference)
    try FileManager.default.removeItem(at: original)
    let missing = try fixture.store.refreshAvailability(for: item)
    let relocated = try fixture.store.relocate(item: missing, to: replacement)

    try expect(relocated.sourceURL, equals: replacement, "relocation should update external source")
    try expect(relocated.availability, equals: .available, "relocation should restore availability")
    try expect(try fixture.store.items().first?.sourceURL, equals: replacement, "relocation should persist")
}


func testRelocatesHTMLProjectAndPreservesEntry() throws {
    let fixture = try Fixture()
    let originalProject = fixture.root.appendingPathComponent("old-site", isDirectory: true)
    let originalPages = originalProject.appendingPathComponent("pages", isDirectory: true)
    try FileManager.default.createDirectory(at: originalPages, withIntermediateDirectories: true)
    let originalEntry = originalPages.appendingPathComponent("home.html")
    try Data("old".utf8).write(to: originalEntry)

    let replacementProject = fixture.root.appendingPathComponent("new-site", isDirectory: true)
    let replacementPages = replacementProject.appendingPathComponent("pages", isDirectory: true)
    try FileManager.default.createDirectory(at: replacementPages, withIntermediateDirectories: true)
    let replacementEntry = replacementPages.appendingPathComponent("home.html")
    try Data("new".utf8).write(to: replacementEntry)

    let item = try fixture.store.importItem(at: originalProject, storageMode: .externalReference, entryURL: originalEntry)
    try FileManager.default.removeItem(at: originalProject)
    let relocated = try fixture.store.relocate(item: item, to: replacementProject)

    try expect(relocated.entryURL?.standardizedFileURL, equals: replacementEntry.standardizedFileURL, "HTML relocation should preserve relative entry")
    try expect(relocated.availability, equals: .available, "relocated HTML project should be available")
}

func testRelocationPreservesNestedEntryAfterRestart() throws {
    for storageMode in [StorageMode.externalReference, .managedCopy] {
        let fixture = try Fixture()
        let oldProject = fixture.root.appendingPathComponent("old-site-\(storageMode.rawValue)", isDirectory: true)
        let oldPages = oldProject.appendingPathComponent("pages", isDirectory: true)
        try FileManager.default.createDirectory(at: oldPages, withIntermediateDirectories: true)
        try Data("old-index".utf8).write(to: oldProject.appendingPathComponent("index.html"))
        let oldEntry = oldPages.appendingPathComponent("home.html")
        try Data("old-home".utf8).write(to: oldEntry)

        let imported = try fixture.store.importItem(at: oldProject, storageMode: storageMode, entryURL: oldEntry)
        try expect(imported.relativeEntryPath, equals: "pages/home.html", "\(storageMode) import should persist the relative entry")

        // Simulate an app restart: reload the index from disk before relocating.
        let reloadedStore = WallpaperStore(libraryURL: fixture.library)
        guard let decoded = try reloadedStore.items().first else {
            throw TestFailure(message: "imported item should persist")
        }
        try expect(decoded.relativeEntryPath, equals: "pages/home.html", "\(storageMode) relative entry should survive JSON round-trip")

        let replacement = fixture.root.appendingPathComponent("new-site-\(storageMode.rawValue)", isDirectory: true)
        let replacementPages = replacement.appendingPathComponent("pages", isDirectory: true)
        try FileManager.default.createDirectory(at: replacementPages, withIntermediateDirectories: true)
        try Data("new-index".utf8).write(to: replacement.appendingPathComponent("index.html"))
        let replacementEntry = replacementPages.appendingPathComponent("home.html")
        try Data("new-home".utf8).write(to: replacementEntry)

        try FileManager.default.removeItem(at: decoded.sourceURL)
        let missing = try reloadedStore.refreshAvailability(for: decoded)
        let relocated = try reloadedStore.relocate(item: missing, to: replacement)

        let expectedEntry = storageMode == .managedCopy
            ? decoded.sourceURL.appendingPathComponent("pages/home.html")
            : replacementEntry
        try expect(relocated.entryURL?.standardizedFileURL, equals: expectedEntry.standardizedFileURL, "\(storageMode) relocation should keep the nested entry")
        let persisted = try WallpaperStore(libraryURL: fixture.library).items().first
        try expect(persisted?.entryURL?.standardizedFileURL, equals: expectedEntry.standardizedFileURL, "\(storageMode) relocation should persist the nested entry")
        try expect(persisted?.relativeEntryPath, equals: "pages/home.html", "\(storageMode) relative entry should persist after relocation")
    }
}

func testRelocationRejectsMissingOriginalEntry() throws {
    let fixture = try Fixture()
    let oldProject = fixture.root.appendingPathComponent("old-site", isDirectory: true)
    let oldPages = oldProject.appendingPathComponent("pages", isDirectory: true)
    try FileManager.default.createDirectory(at: oldPages, withIntermediateDirectories: true)
    let oldEntry = oldPages.appendingPathComponent("home.html")
    try Data("home".utf8).write(to: oldEntry)
    let item = try fixture.store.importItem(at: oldProject, storageMode: .externalReference, entryURL: oldEntry)
    try FileManager.default.removeItem(at: oldProject)

    let replacement = fixture.root.appendingPathComponent("replacement", isDirectory: true)
    try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
    try Data("index".utf8).write(to: replacement.appendingPathComponent("index.html"))

    var didReject = false
    do {
        _ = try fixture.store.relocate(item: item, to: replacement)
    } catch WallpaperStoreError.invalidHTMLEntry(_) {
        didReject = true
    }
    try expect(didReject, "relocation must not silently switch to index.html")
    try expect(try fixture.store.items().first?.entryURL, equals: item.entryURL, "failed relocation must not persist a different entry")
}

func testRemovesManagedWallpaperAndAsset() throws {
    let fixture = try Fixture()
    let source = fixture.root.appendingPathComponent("remove-me.png")
    try Data("image".utf8).write(to: source)
    let item = try fixture.store.importItem(at: source, storageMode: .managedCopy)
    try expect(FileManager.default.fileExists(atPath: item.sourceURL.path), "managed asset should exist before removal")

    try fixture.store.remove(item: item)

    let remainingItems = try fixture.store.items()
    try expect(remainingItems.isEmpty, "removed item should leave the index")
    try expect(!FileManager.default.fileExists(atPath: item.sourceURL.path), "managed asset should be deleted")
    try expect(!FileManager.default.fileExists(atPath: item.sourceURL.deletingLastPathComponent().path), "the empty UUID asset directory should be removed too")
}

func testInvalidHTMLImportCleansManagedAsset() throws {
    let fixture = try Fixture()
    let project = fixture.root.appendingPathComponent("invalid-entry-site", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let validEntry = project.appendingPathComponent("index.html")
    try Data("index".utf8).write(to: validEntry)
    let outsideEntry = fixture.root.appendingPathComponent("outside.html")

    do {
        _ = try fixture.store.importItem(at: project, storageMode: .managedCopy, entryURL: outsideEntry)
        throw TestFailure(message: "an HTML project with an outside entry should fail")
    } catch let error as WallpaperStoreError {
        try expect(error, equals: .invalidHTMLEntry(project), "invalid HTML entry should be reported")
    }

    let assets = fixture.library.appendingPathComponent("Assets", isDirectory: true)
    let assetNames = try FileManager.default.contentsOfDirectory(atPath: assets.path)
    try expect(assetNames.isEmpty, "failed managed HTML import should clean its copied asset")
    let persistedItems = try fixture.store.items()
    try expect(persistedItems.isEmpty, "failed managed HTML import should not persist an item")
}

func testRelocateManagedWallpaperCleansCopyOnFailure() throws {
    let fixture = try Fixture()
    let source = fixture.root.appendingPathComponent("original.png")
    try Data("image".utf8).write(to: source)
    let item = try fixture.store.importItem(at: source, storageMode: .managedCopy)
    try FileManager.default.removeItem(at: item.sourceURL)

    let invalidProject = fixture.root.appendingPathComponent("invalid-site", isDirectory: true)
    try FileManager.default.createDirectory(at: invalidProject, withIntermediateDirectories: true)
    do {
        _ = try fixture.store.relocate(item: item, to: invalidProject)
        throw TestFailure(message: "a replacement with the wrong type should fail")
    } catch let error as WallpaperStoreError {
        try expect(error, equals: .unsupportedSource(invalidProject), "relocation should reject a mismatched replacement")
    }
}

func testPlaybackPolicySuspensionRules() throws {
    let policy = PlaybackPolicy(pauseOnBattery: true, pauseInFullScreenApps: true)
    try expect(policy.shouldPauseDynamicWallpaper(isOnBattery: true, isFullScreenAppActive: false), "battery policy should pause")
    try expect(policy.shouldPauseDynamicWallpaper(isOnBattery: false, isFullScreenAppActive: true), "full-screen policy should pause")
    try expect(!policy.shouldPauseDynamicWallpaper(isOnBattery: false, isFullScreenAppActive: false), "inactive conditions should not pause")

    let disabled = PlaybackPolicy(pauseOnBattery: false, pauseInFullScreenApps: false)
    try expect(!disabled.shouldPauseDynamicWallpaper(isOnBattery: true, isFullScreenAppActive: true), "disabled policies should not pause")
}

func testScreenSleepAndSessionInactivityAlwaysSuspend() throws {
    let policy = PlaybackPolicy(pauseOnBattery: false, pauseInFullScreenApps: false)
    let asleep = PlaybackActivityState(isScreenAsleep: true)
    try expect(
        policy.shouldPauseDynamicWallpaper(displayID: "any", activity: asleep),
        "a sleeping screen must suspend even with battery/fullscreen policies disabled"
    )
    let inactive = PlaybackActivityState(isSessionInactive: true)
    try expect(
        policy.shouldPauseDynamicWallpaper(displayID: "any", activity: inactive),
        "an inactive session must suspend regardless of preferences"
    )
    let awake = PlaybackActivityState()
    try expect(
        !policy.shouldPauseDynamicWallpaper(displayID: "any", activity: awake),
        "awake active screens with no policy match should not suspend"
    )
}

func testFullscreenGeometryConvertsQuartzToCocoa() throws {
    // Main screen 1920x1080, secondary stacked ABOVE it. A fullscreen window on
    // the upper display has a negative Quartz y; naive edge comparison against
    // the Cocoa frame would never match.
    let primary: CGFloat = 1080
    let quartzRect = CGRect(x: 0, y: -1200, width: 1920, height: 1200)
    let cocoa = FullscreenGeometry.cocoaRect(fromQuartz: quartzRect, primaryScreenHeight: primary)
    // Cocoa origin for the upper screen: primary - (quartzY + height) = 1080 - 0 = 1080.
    try expect(cocoa.minY, equals: 1080, "quartz->cocoa must flip around the primary screen height")
    try expect(cocoa.minX, equals: 0, "cocoa x should be preserved")
    try expect(cocoa.height, equals: 1200, "cocoa height should be preserved")
    let upperScreenFrame = CGRect(x: 0, y: 1080, width: 1920, height: 1200)
    try expect(
        FullscreenGeometry.isFullscreen(rect: cocoa, on: upperScreenFrame),
        "a fullscreen rect on a stacked upper display must be detected"
    )
    let mainScreenFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    try expect(
        !FullscreenGeometry.isFullscreen(rect: cocoa, on: mainScreenFrame),
        "the upper-display rect must not match the main screen"
    )
}

func testFullscreenGeometryToleratesMenuBarInset() throws {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    // A window covering everything but the 25pt menu bar should still count.
    let rect = CGRect(x: 0, y: 25, width: 1440, height: 875)
    try expect(
        FullscreenGeometry.isFullscreen(rect: rect, on: screen),
        "a near-fullscreen rect (menu bar inset) should pass the area threshold"
    )
    let small = CGRect(x: 100, y: 100, width: 400, height: 300)
    try expect(
        !FullscreenGeometry.isFullscreen(rect: small, on: screen),
        "a small floating window is not fullscreen"
    )
}

func testMissingIndexSkipsOrphanCleanupAndRecoversFromBackup() throws {
    let fixture = try Fixture()
    let fm = FileManager.default
    // Import one managed asset so Assets/ has a UUID directory with a file.
    let source = fixture.root.appendingPathComponent("sample.png")
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: source)
    let item = try fixture.store.importItem(at: source, storageMode: .managedCopy)
    let managedCopy = item.sourceURL
    try expect(fm.fileExists(atPath: managedCopy.path), "managed copy should exist after import")

    // Second save rotates a backup, then the live index is destroyed.
    _ = try fixture.store.update(item: item, isFavorite: true)
    let indexURL = fixture.library.appendingPathComponent("wallpapers.json")
    try fm.removeItem(at: indexURL)

    // Reload must not delete the managed asset; it should restore from .bak.
    let reloaded = try fixture.store.refreshAllAvailability()
    try expect(fm.fileExists(atPath: managedCopy.path), "a missing index must not orphan-delete managed assets")
    try expect(reloaded.contains(where: { $0.id == item.id }), "the index should be recovered from the backup")
}

func testStaleBackupRecoveryDoesNotDeleteNewerAssets() throws {
    let fixture = try Fixture()
    let fm = FileManager.default
    // Import A, then B. With the fixed save() the .bak contains A+B; simulate
    // a *stale* .bak (the pre-fix shape) by hand-writing a backup with only A
    // after B was imported.
    let sourceA = fixture.root.appendingPathComponent("a.png")
    let sourceB = fixture.root.appendingPathComponent("b.png")
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: sourceA)
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: sourceB)
    let itemA = try fixture.store.importItem(at: sourceA, storageMode: .managedCopy)
    let itemB = try fixture.store.importItem(at: sourceB, storageMode: .managedCopy)
    let copyA = itemA.sourceURL
    let copyB = itemB.sourceURL
    try expect(fm.fileExists(atPath: copyA.path) && fm.fileExists(atPath: copyB.path), "both managed copies should exist")

    // Craft the stale backup: only A.
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let staleData = try encoder.encode([itemA])
    try staleData.write(to: fixture.library.appendingPathComponent("wallpapers.json.bak"), options: .atomic)

    // Destroy the live index so recovery runs from the stale backup.
    try fm.removeItem(at: fixture.library.appendingPathComponent("wallpapers.json"))

    // First refresh recovers the stale index (A only) — B's asset must survive
    // because cleanup is disabled by the recovery marker.
    _ = try fixture.store.refreshAllAvailability()
    try expect(fm.fileExists(atPath: copyB.path), "first refresh after stale recovery must not delete B's asset")

    // A second refresh must still not delete B: the marker keeps cleanup off
    // until a fresh save() writes a reconciled index.
    _ = try fixture.store.refreshAllAvailability()
    try expect(fm.fileExists(atPath: copyB.path), "second refresh must still not delete B's asset")

    // A fresh save (field-level update) clears the recovery marker and
    // re-enables cleanup. The recovered index only contains A, so the now
    // authoritative cleanup may remove B's orphaned asset — that is correct
    // (the index is authoritative again); the point of the test is that
    // nothing is deleted while the marker is still set.
    _ = try fixture.store.update(item: itemA, isFavorite: true)
    _ = try fixture.store.refreshAllAvailability()
    try expect(
        !fm.fileExists(atPath: fixture.library.appendingPathComponent("wallpapers.json.recover").path),
        "a fresh save must clear the recovery marker"
    )
    try expect(fm.fileExists(atPath: copyA.path), "the indexed asset A survives authoritative cleanup")
}

func testLockScreenResourceResolverSelectsStaticImages() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let imageURL = root.appendingPathComponent("image.png")
    let thumbnailURL = root.appendingPathComponent("thumb.jpg")
    try Data("image".utf8).write(to: imageURL)
    try Data("thumb".utf8).write(to: thumbnailURL)

    let image = WallpaperItem(id: UUID(), name: "image", type: .image, sourceURL: imageURL, storageMode: .externalReference)
    try expect(LockScreenResourceResolver.existingImageURL(for: image), equals: imageURL, "image wallpapers should use their original file for lock-screen quality")

    let video = WallpaperItem(id: UUID(), name: "video", type: .video, sourceURL: root.appendingPathComponent("video.mp4"), storageMode: .externalReference, thumbnailURL: thumbnailURL)
    try expect(LockScreenResourceResolver.existingImageURL(for: video), equals: thumbnailURL, "video wallpapers should use their generated thumbnail")

    var overriddenVideo = video
    overriddenVideo.lockScreenOverrideURL = imageURL
    try expect(LockScreenResourceResolver.existingImageURL(for: overriddenVideo), equals: imageURL, "a user-selected lock-screen override must take precedence")

    let web = WallpaperItem(id: UUID(), name: "web", type: .web, sourceURL: imageURL, storageMode: .externalReference)
    try expect(LockScreenResourceResolver.existingImageURL(for: web) == nil, "web wallpapers without thumbnails need a live-page snapshot")
    try expect(LockScreenResourceResolver.snapshotFilename(for: web), equals: "\(web.id.uuidString).png", "web snapshot filenames must be unique per wallpaper")

    let missingImage = WallpaperItem(id: UUID(), name: "missing", type: .image, sourceURL: root.appendingPathComponent("missing.png"), storageMode: .externalReference, thumbnailURL: thumbnailURL)
    try expect(LockScreenResourceResolver.existingImageURL(for: missingImage), equals: thumbnailURL, "a missing source may still use an existing thumbnail")
}

func testLockScreenOverridePersistsAndIsRemovedWithWallpaper() throws {
    let fixture = try Fixture()
    let source = fixture.root.appendingPathComponent("source.png")
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: source)
    let item = try fixture.store.importItem(at: source, storageMode: .externalReference)
    let directory = fixture.library.appendingPathComponent("LockScreen", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let override = directory.appendingPathComponent("\(item.id.uuidString).png")
    try Data("custom".utf8).write(to: override)

    let persisted = try fixture.store.updateLockScreenOverride(id: item.id, imageURL: override)
    try expect(persisted.lockScreenOverrideURL, equals: override, "custom lock-screen URL should persist")
    let reloaded = try require(try fixture.store.items().first, "override should survive a store reload")
    try expect(reloaded.lockScreenOverrideURL, equals: override, "override should decode from wallpapers.json")
    let touched = try fixture.store.touchLastUsed(id: item.id)
    try expect(touched.lockScreenOverrideURL, equals: override, "unrelated field updates must preserve the override")

    try fixture.store.remove(item: touched)
    try expect(!FileManager.default.fileExists(atPath: override.path), "deleting a wallpaper should remove its app-owned override")
}

func testHotKeyShortcutValidationAndPersistence() throws {
    let defaultShortcut = HotKeyShortcut.defaultHideHidden
    try expect(defaultShortcut.isValid, "the built-in shortcut must remain valid")
    try expect(defaultShortcut.displayString, equals: "⌃⌥H", "the default shortcut should render as control-option-H")

    let unmodified = HotKeyShortcut(keyCode: 0, modifiers: 0)
    try expect(!unmodified.isValid, "a bare letter must not be accepted as a global shortcut")
    let shiftOnly = HotKeyShortcut(keyCode: 0, modifiers: HotKeyShortcut.shiftModifier)
    try expect(!shiftOnly.isValid, "shift alone must not be accepted")
    let unknownModifier = HotKeyShortcut(keyCode: 0, modifiers: 0x8000)
    try expect(!unknownModifier.isValid, "unknown modifier bits must be rejected")
    let commandQ = HotKeyShortcut(keyCode: 12, modifiers: HotKeyShortcut.commandModifier)
    try expect(commandQ.validationIssue != nil, "reserved application shortcuts must be rejected before registration")
    let custom = HotKeyShortcut(
        keyCode: 8,
        modifiers: HotKeyShortcut.controlModifier | HotKeyShortcut.optionModifier | HotKeyShortcut.shiftModifier
    )
    try expect(custom.isValid, "a custom control-option-shift shortcut should be valid")
    try expect(custom.displayString, equals: "⌃⌥⇧C", "custom shortcut display should include every modifier")

    let data = try JSONEncoder().encode(custom)
    let restored = try JSONDecoder().decode(HotKeyShortcut.self, from: data)
    try expect(restored, equals: custom, "custom shortcut should survive JSON persistence")

    let suiteName = "WallpaperMacHotKeyTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    custom.save(to: defaults, key: "shortcut")
    try expect(HotKeyShortcut.load(from: defaults, key: "shortcut"), equals: custom, "a saved custom shortcut should load on the next launch")
    try expect(HotKeyShortcut.load(from: defaults, key: "missing"), equals: .defaultHideHidden, "a missing preference must fall back to the default")
}

func testUpdateAutomationPreferencesGateSchedulingAndInstall() throws {
    let now = Date()
    let defaults = UpdateAutomationPreferences()
    try expect(defaults.shouldScheduleDailyCheck, "daily checks should remain enabled by default")
    try expect(!defaults.shouldInstallAutomatically, "unattended installs must be opt-in")
    try expect(defaults.shouldCheck(now: now, lastCheck: nil), "a missing last-check date should trigger the first check")
    try expect(!defaults.shouldCheck(now: now, lastCheck: now), "a check within 24 hours should be throttled")
    try expect(
        defaults.shouldCheck(now: now.addingTimeInterval(24 * 60 * 60), lastCheck: now),
        "a check exactly 24 hours later should be allowed"
    )
    try expect(
        !defaults.shouldCheck(
            now: now.addingTimeInterval(60 * 60),
            lastCheck: now.addingTimeInterval(-24 * 60 * 60),
            lastAutomaticAttempt: now
        ),
        "a recent automatic attempt must throttle even when the last successful check is old"
    )
    try expect(
        defaults.shouldCheck(now: now, lastCheck: now.addingTimeInterval(24 * 60 * 60)),
        "a future-dated last check must not suppress checks after a clock adjustment"
    )
    try expect(
        !defaults.shouldCheck(now: now.addingTimeInterval(24 * 60 * 60), lastCheck: now, isBusy: true),
        "an in-flight check or install must suppress another scheduled attempt"
    )

    let automatic = UpdateAutomationPreferences(dailyCheckEnabled: true, automaticInstallEnabled: true)
    try expect(automatic.shouldInstallAutomatically, "enabling both switches should allow automatic installation")
    let checksDisabled = UpdateAutomationPreferences(dailyCheckEnabled: false, automaticInstallEnabled: true)
    try expect(!checksDisabled.shouldScheduleDailyCheck, "disabling checks must stop the daily timer")
    try expect(!checksDisabled.shouldInstallAutomatically, "disabling checks must also stop unattended installs")
    try expect(!checksDisabled.shouldCheck(now: now, lastCheck: nil), "disabled checks must not run even without a last-check date")
}

func testWebMouseEventScriptActivatesClickOnce() throws {
    let mouseUp = WebMouseEventScript.source(x: 120, y: 80, phase: .mouseUp)
    try expect(
        mouseUp.components(separatedBy: "target.click()").count - 1,
        equals: 1,
        "a matched mouseup should use exactly one native target click activation"
    )
    try expect(
        mouseUp.contains("if (typeof target.click === 'function')"),
        "HTML elements should use their native click activation"
    )
    try expect(
        mouseUp.contains("window.__wallpaperMacMouseDown"),
        "mouseup must inspect the saved mousedown target"
    )
    try expect(
        mouseUp.contains("Math.hypot(x - down.x, y - down.y) <= 6"),
        "dragging beyond the threshold must cancel activation"
    )
    try expect(
        mouseUp.contains("down.target === element"),
        "only the pressed target or its ancestor may be activated"
    )
    try expect(
        WebMouseEventScript.linkTarget(x: 120, y: 80).contains("element.click()") == false,
        "link preflight must not activate the target"
    )
    try expect(
        mouseUp.components(separatedBy: "new MouseEvent('click'").count - 1,
        equals: 1,
        "non-HTML elements should have one mutually exclusive fallback click activation"
    )
    try expect(
        WebMouseEventScript.activateMouseUp().contains("clientX: point ? point.x : 0"),
        "fallback click activation must preserve the real pointer coordinates"
    )
    let mouseDown = WebMouseEventScript.source(x: 120, y: 80, phase: .mouseDown)
    try expect(
        mouseDown.contains("element.click()"),
        equals: false,
        "mousedown must not activate click behavior"
    )
}

func testPlaybackPolicySupportsWebWallpaperClickEffect() throws {
    let enabledJSON = """
    {"isPlaying":true,"isMuted":true,"loops":true,"pauseOnBattery":false,
     "pauseInFullScreenApps":false,"reloadWebContentOnResume":false,
     "fitMode":"fill","webWallpaperInteractionEnabled":true}
    """
    let enabled = try JSONDecoder().decode(PlaybackPolicy.self, from: Data(enabledJSON.utf8))
    try expect(enabled.webWallpaperInteractionEnabled, "enabled wallpaper click effect should round-trip")

    let legacyJSON = """
    {"isPlaying":true,"isMuted":true,"loops":true,"pauseOnBattery":false,
     "pauseInFullScreenApps":false,"reloadWebContentOnResume":false,
     "fitMode":"fill"}
    """
    let legacy = try JSONDecoder().decode(PlaybackPolicy.self, from: Data(legacyJSON.utf8))
    try expect(
        legacy.webWallpaperInteractionEnabled,
        equals: false,
        "legacy playback policy should keep wallpaper click effect disabled"
    )
}

func testPlaybackDefaultsAndDisplayAssignmentCoding() throws {
    let policy = PlaybackPolicy()
    try expect(policy.isPlaying, "playback should default to playing")
    try expect(policy.isMuted, "video/web should default to muted")
    try expect(policy.loops, "playback should default to looping")
    try expect(policy.fitMode, equals: .fill, "wallpaper should default to fill mode")
    var fittedPolicy = policy
    fittedPolicy.fitMode = .fit
    let policyData = try JSONEncoder().encode(fittedPolicy)
    let decodedPolicy = try JSONDecoder().decode(PlaybackPolicy.self, from: policyData)
    try expect(decodedPolicy, equals: fittedPolicy, "playback fit mode should round-trip")
    let assignment = DisplayAssignment(id: "display-1", displayName: "内置显示器", isConnected: true, wallpaperID: UUID(), applicationState: .applied)
    let data = try JSONEncoder().encode(assignment)
    let decoded = try JSONDecoder().decode(DisplayAssignment.self, from: data)
    try expect(decoded, equals: assignment, "display assignment should round-trip")
}


func testLibraryConfigurationRoundTripsCustomPath() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WallpaperMacConfigurationTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let configurationDirectory = root.appendingPathComponent("Configuration", isDirectory: true)
    let libraryURL = root.appendingPathComponent("Custom Library", isDirectory: true)
    let bookmarkData = Data([0x01, 0x02, 0x03])

    let writer = WallpaperLibraryConfigurationStore(configurationDirectory: configurationDirectory)
    try writer.save(libraryURL: libraryURL, bookmarkData: bookmarkData)

    let reader = WallpaperLibraryConfigurationStore(configurationDirectory: configurationDirectory)
    let loaded = try reader.load()
    try expect(loaded?.libraryURL.standardizedFileURL, equals: libraryURL.standardizedFileURL, "custom library path should survive a new store instance")
    try expect(loaded?.bookmarkData, equals: bookmarkData, "library bookmark data should survive a new store instance")
}

func testMissingLibraryConfigurationDoesNotCreateEmptyLibrary() throws {
    let configurationDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WallpaperMacMissingConfigurationTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = WallpaperLibraryConfigurationStore(configurationDirectory: configurationDirectory)

    try expect(try store.load(), equals: nil, "missing configuration should stay absent")
    try expect(!FileManager.default.fileExists(atPath: configurationDirectory.path), "loading configuration should not create a replacement directory")
}


func testGroupsAndBulkRemovalPersist() throws {
    let fixture = try Fixture()
    let firstSource = fixture.root.appendingPathComponent("first.png")
    let secondSource = fixture.root.appendingPathComponent("second.png")
    try Data("one".utf8).write(to: firstSource)
    try Data("two".utf8).write(to: secondSource)
    var first = try fixture.store.importItem(at: firstSource, storageMode: .managedCopy)
    let second = try fixture.store.importItem(at: secondSource, storageMode: .managedCopy)
    let group = WallpaperGroup(name: "测试组")
    try fixture.store.save(groups: [group])
    first.groupID = group.id
    try fixture.store.update(item: first)

    let restoredGroups = try fixture.store.groups()
    let restoredItems = try fixture.store.items()
    try expect(restoredGroups.count, equals: 1, "wallpaper groups should round-trip")
    try expect(restoredGroups[0].id, equals: group.id, "wallpaper group ID should persist")
    try expect(restoredGroups[0].name, equals: group.name, "wallpaper group name should persist")
    try expect(restoredItems.first(where: { $0.id == first.id })?.groupID, equals: group.id, "item group assignment should persist")

    try fixture.store.remove(items: [first, second])
    try expect(try fixture.store.items(), equals: [], "bulk removal should remove all selected items")
    try expect(!FileManager.default.fileExists(atPath: first.sourceURL.path), "bulk removal should delete managed asset one")
    try expect(!FileManager.default.fileExists(atPath: second.sourceURL.path), "bulk removal should delete managed asset two")
}

func testBulkGroupAssignmentPersistsAllChangesWithOneStoreOperation() throws {
    let fixture = try Fixture()
    let sourceURLs = (1...3).map { fixture.root.appendingPathComponent("asset-\($0).png") }
    for (index, sourceURL) in sourceURLs.enumerated() {
        try Data("asset-\(index)".utf8).write(to: sourceURL)
    }
    let items = try sourceURLs.map { try fixture.store.importItem(at: $0, storageMode: .externalReference) }
    let group = WallpaperGroup(name: "批量分组")

    let updated = try fixture.store.assign(itemsWithIDs: Set(items.map(\.id)), to: group.id)

    try expect(updated.count, equals: items.count, "bulk assignment should return every selected wallpaper")
    try expect(Set(updated.compactMap(\.groupID)), equals: [group.id], "bulk assignment should update every selected wallpaper")
    let persisted = try fixture.store.items().filter { Set(items.map(\.id)).contains($0.id) }
    try expect(Set(persisted.compactMap(\.groupID)), equals: [group.id], "bulk assignment should persist all group changes")
}

func testDisplayQueueNormalizesAndPersists() throws {
    let fixture = try Fixture()
    let firstID = UUID()
    let secondID = UUID()
    var queue = DisplayPlaybackQueue(
        displayID: "display-1",
        displayName: "内置显示器",
        wallpaperIDs: [firstID, secondID],
        intervalSeconds: 0.2,
        transition: .slideLeft,
        isEnabled: true,
        currentIndex: 9
    )
    queue.normalize()
    try expect(queue.intervalSeconds, equals: 1, "queue interval should have a one-second minimum")
    try expect(queue.currentIndex, equals: 1, "queue index should wrap into the item range")
    try fixture.store.save(displayQueues: [queue])
    let restored = try fixture.store.displayQueues()
    try expect(restored, equals: [queue], "display queue should round-trip")
}

func testDisplayQueuesStayIndependent() throws {
    let first = DisplayPlaybackQueue(displayID: "display-1", displayName: "内置显示器", wallpaperIDs: [UUID()], intervalSeconds: 5, transition: .crossfade, isEnabled: true)
    let second = DisplayPlaybackQueue(displayID: "display-2", displayName: "外接显示器", wallpaperIDs: [UUID(), UUID()], intervalSeconds: 12, transition: .zoom, isEnabled: false)
    try expect(first.displayID != second.displayID, "display queues should use stable display IDs")
    try expect(first.intervalSeconds != second.intervalSeconds, "display queues should keep independent intervals")
    try expect(first.transition != second.transition, "display queues should keep independent transitions")
}

// MARK: - Steam Workshop import tests

func testWorkshopLinkParsesSupportedForms() throws {
    let forms = [
        "https://steamcommunity.com/sharedfiles/filedetails/?id=3445534475",
        "https://steamcommunity.com/workshop/filedetails/?id=3445534475&searchtext=",
        "http://steamcommunity.com/sharedfiles/filedetails/?id=3445534475",
        "steam://url/CommunityFilePage/3445534475",
        "3445534475",
        "  3445534475  "
    ]
    for form in forms {
        let link = try require(WorkshopLink.parse(form), "should parse: \(form)")
        try expect(link.itemID, equals: "3445534475", "id from \(form)")
    }
}

func testWorkshopLinkRejectsInvalidInput() throws {
    let invalids = [
        "",
        "   ",
        "1234",            // too short (could be a year)
        "2026",            // year
        "https://example.com/filedetails/?id=3445534475",
        "https://steamcommunity.com/profiles/76561198000000000",
        "not a link",
        "steam://url/OtherPage/3445534475",
        "https://steamcommunity.com/sharedfiles/filedetails/?id=abc",
        "9999999999999999999999999" // > 20 digits
    ]
    for input in invalids {
        try expect(WorkshopLink.parse(input) == nil, "should reject: \(input)")
    }
}

func testWorkshopMetadataParsesSteamResponse() throws {
    let json = """
    {"response":{"result":1,"resultcount":1,"publishedfiledetails":[{
      "publishedfileid":"3445534475",
      "result":1,
      "title":"Castorice Scene",
      "description":"A scene wallpaper",
      "file_size":"89533472",
      "preview_url":"https://images.steamusercontent.com/ugc/1/ABC/",
      "consumer_app_id":431960,
      "time_updated":1748876686,
      "tags":[{"tag":"Wallpaper"},{"tag":"Scene"},{"tag":"Everyone"}]
    }]}}
    """
    let metadata = try WorkshopMetadataParser.parse(
        data: Data(json.utf8),
        requestedID: "3445534475"
    )
    try expect(metadata.itemID, equals: "3445534475", "item id")
    try expect(metadata.title, equals: "Castorice Scene", "title")
    try expect(metadata.fileSizeBytes, equals: 89_533_472, "size parses from string")
    try expect(metadata.isAvailable, equals: true, "result 1 is available")
    try expect(metadata.isWallpaperEngineItem, equals: true, "consumer app 431960")
    try expect(metadata.kindFromTags, equals: .scene, "Scene tag wins")
    try expect(metadata.unsupportedReason, equals: .scene, "scene is unsupported in v1")
    try expect(
        metadata.previewURL?.absoluteString,
        equals: "https://images.steamusercontent.com/ugc/1/ABC/",
        "preview url"
    )
}

func testWorkshopMetadataTypeTagsAndAvailability() throws {
    func make(tags: [String], result: Int = 1, app: Int? = 431960) -> WorkshopMetadata {
        WorkshopMetadata(
            itemID: "1",
            title: "t",
            itemDescription: "",
            tags: tags,
            fileSizeBytes: nil,
            previewURL: nil,
            consumerAppID: app,
            timeUpdated: nil,
            isAvailable: result == 1
        )
    }

    try expect(make(tags: ["Video"]).kindFromTags, equals: .video, "Video tag")
    try expect(make(tags: ["Web"]).kindFromTags, equals: .web, "Web tag")
    try expect(make(tags: ["Application"]).kindFromTags, equals: .application, "Application tag")
    try expect(make(tags: ["Anime"]).kindFromTags, equals: nil, "no type tag")
    try expect(
        make(tags: ["Scene", "Video"]).kindFromTags,
        equals: .scene,
        "Application/Scene win over Video when both present"
    )
    try expect(make(tags: ["Video"]).unsupportedReason, equals: nil, "video is supported")
    try expect(make(tags: ["Video"]).unsupportedReason == nil, equals: true, "video has no reason")
    try expect(make(tags: [], result: 0).unsupportedReason, equals: .unavailable, "result != 1")
    try expect(make(tags: ["Video"], app: 730).unsupportedReason, equals: .wrongApp(730), "wrong appid")
}

func testWorkshopMetadataUnavailableResponse() throws {
    let json = """
    {"response":{"result":1,"resultcount":1,"publishedfiledetails":[{
      "publishedfileid":"999","result":9
    }]}}
    """
    let metadata = try WorkshopMetadataParser.parse(data: Data(json.utf8), requestedID: "999")
    try expect(metadata.isAvailable, equals: false, "result 9 is unavailable")
    try expect(metadata.unsupportedReason, equals: .unavailable, "unavailable reason")
}

func testWorkshopProjectManifestParsesVideoAndWeb() throws {
    let videoJSON = """
    {"title":"Aurora Drift","description":"d","type":"video","file":"Aurora.mp4","preview":"preview.jpg"}
    """
    let video = try WorkshopProjectManifest.parse(data: Data(videoJSON.utf8))
    try expect(video.kind, equals: .video, "video kind")
    try expect(video.file, equals: "Aurora.mp4", "video file")
    try expect(video.title, equals: "Aurora Drift", "title")

    let webJSON = #"{"type":"web","file":"index.html"}"#
    let web = try WorkshopProjectManifest.parse(data: Data(webJSON.utf8))
    try expect(web.kind, equals: .web, "web kind")
    try expect(web.file, equals: "index.html", "web entry")

    let sceneJSON = #"{"type":"scene","file":"scene.json"}"#
    let scene = try WorkshopProjectManifest.parse(data: Data(sceneJSON.utf8))
    try expect(scene.kind, equals: .scene, "scene kind")

    let unknown = try WorkshopProjectManifest.parse(data: Data("{}".utf8))
    try expect(unknown.kind, equals: .unknown, "missing type is unknown")
}

func testWorkshopImportPlannerRoutesSupportedTypes() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("wm-plan-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    // Video project
    let videoDir = root.appendingPathComponent("video-item", isDirectory: true)
    try FileManager.default.createDirectory(at: videoDir, withIntermediateDirectories: true)
    try Data("fake-video".utf8).write(to: videoDir.appendingPathComponent("clip.mp4"))
    try Data(#"{"type":"video","file":"clip.mp4","title":"Clip"}"#.utf8)
        .write(to: videoDir.appendingPathComponent("project.json"))

    let videoPlan = WorkshopImportPlanner.plan(directory: videoDir)
    guard case .video(let source, let title) = videoPlan else {
        throw TestFailure(message: "expected video plan, got \(videoPlan)")
    }
    try expect(source.lastPathComponent, equals: "clip.mp4", "video source file")
    try expect(title, equals: "Clip", "video title from manifest")
    try expect(videoPlan.isSupported, equals: true, "video supported")

    // Web project with nested entry
    let webDir = root.appendingPathComponent("web-item", isDirectory: true)
    try FileManager.default.createDirectory(
        at: webDir.appendingPathComponent("pages", isDirectory: true),
        withIntermediateDirectories: true
    )
    try Data("<html></html>".utf8).write(to: webDir.appendingPathComponent("pages/home.html"))
    try Data(#"{"type":"web","file":"pages/home.html"}"#.utf8)
        .write(to: webDir.appendingPathComponent("project.json"))

    let webPlan = WorkshopImportPlanner.plan(directory: webDir)
    guard case .webProject(let directory, let entry, _) = webPlan else {
        throw TestFailure(message: "expected web plan, got \(webPlan)")
    }
    try expect(directory, equals: webDir, "web directory")
    try expect(entry, equals: "pages/home.html", "web entry path")
    try expect(webPlan.isSupported, equals: true, "web supported")

    // Scene rejected
    let sceneDir = root.appendingPathComponent("scene-item", isDirectory: true)
    try FileManager.default.createDirectory(at: sceneDir, withIntermediateDirectories: true)
    try Data(#"{"type":"scene","file":"scene.json"}"#.utf8)
        .write(to: sceneDir.appendingPathComponent("project.json"))
    let scenePlan = WorkshopImportPlanner.plan(directory: sceneDir)
    guard case .unsupported(.scene) = scenePlan else {
        throw TestFailure(message: "expected scene rejection, got \(scenePlan)")
    }
    try expect(scenePlan.isSupported, equals: false, "scene unsupported")

    // Application rejected
    let appDir = root.appendingPathComponent("app-item", isDirectory: true)
    try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
    try Data(#"{"type":"application","file":"run.exe"}"#.utf8)
        .write(to: appDir.appendingPathComponent("project.json"))
    let appPlan = WorkshopImportPlanner.plan(directory: appDir)
    guard case .unsupported(.application) = appPlan else {
        throw TestFailure(message: "expected application rejection, got \(appPlan)")
    }

    // Missing entry file
    let missingDir = root.appendingPathComponent("missing-item", isDirectory: true)
    try FileManager.default.createDirectory(at: missingDir, withIntermediateDirectories: true)
    try Data(#"{"type":"video","file":"gone.mp4"}"#.utf8)
        .write(to: missingDir.appendingPathComponent("project.json"))
    let missingPlan = WorkshopImportPlanner.plan(directory: missingDir)
    guard case .unsupported(.entryFileMissingOnDisk("gone.mp4")) = missingPlan else {
        throw TestFailure(message: "expected missing entry, got \(missingPlan)")
    }

    // No project.json
    let emptyDir = root.appendingPathComponent("empty-item", isDirectory: true)
    try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
    let emptyPlan = WorkshopImportPlanner.plan(directory: emptyDir)
    guard case .unsupported(.unknownType(nil)) = emptyPlan else {
        throw TestFailure(message: "expected unknown type, got \(emptyPlan)")
    }
}

func testWorkshopImportPlannerHandlesBackslashAndTraversalEntries() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("wm-entry-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    // Windows-authored backslash path resolves to nested file.
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("videos", isDirectory: true),
        withIntermediateDirectories: true
    )
    try Data("x".utf8).write(to: root.appendingPathComponent("videos/clip.mp4"))
    let backslash = WorkshopImportPlanner.resolveEntry("videos\\clip.mp4", in: root)
    try expect(
        backslash.path.hasSuffix("videos/clip.mp4"),
        equals: true,
        "backslash entry normalizes"
    )

    // Traversal outside root fails closed.
    let escape = WorkshopImportPlanner.resolveEntry("../../etc/passwd", in: root)
    try expect(
        escape.path.contains(".invalid-entry"),
        equals: true,
        "traversal is rejected"
    )
}

func testSteamCMDCommandBuildsLoginWithoutPassword() throws {
    let command = SteamCMDCommand(
        account: "tester",
        itemID: "3445534475",
        forceInstallDirectory: "/tmp/staging"
    )
    try expect(command.arguments.contains("+login"), equals: true, "has login")
    try expect(
        command.arguments.contains(where: { $0.contains("secret") || $0.lowercased().contains("password") }),
        equals: false,
        "password must never appear in argv"
    )
    try expect(
        command.arguments.contains("-inhibitbootstrap"),
        equals: true,
        "inhibits mid-download self-update"
    )
    let loginIndex = try require(
        command.arguments.firstIndex(of: "+login"),
        "login index"
    )
    try expect(
        command.arguments[loginIndex + 1],
        equals: "tester",
        "account follows +login"
    )
    let workshopIndex = try require(
        command.arguments.firstIndex(of: "+workshop_download_item"),
        "workshop index"
    )
    try expect(command.arguments[workshopIndex + 1], equals: "431960", "WE appid")
    try expect(command.arguments[workshopIndex + 2], equals: "3445534475", "item id")
    try expect(command.arguments.last, equals: "+quit", "quits after")

    let expected = command.expectedContentDirectory.path
    try expect(
        expected.contains("steamapps/workshop/content/431960/3445534475"),
        equals: true,
        "expected content path"
    )
    let candidates = command.candidateContentDirectories()
    try expect(candidates.count, equals: 3, "content/downloads/temp candidates")
    try expect(
        candidates.contains { $0.path.contains("/downloads/431960/3445534475") },
        equals: true,
        "downloads candidate present"
    )
}

func testSteamCMDOutputParserDetectsPasswordPromptAndSuccess() throws {
    let parser = SteamCMDOutputParser()
    parser.noteExpectedItemID("3445534475")

    let passwordEvents = parser.consume("Cached credentials not found.\npassword: ")
    try expect(
        passwordEvents.contains(.prompt(.password)),
        equals: true,
        "password prompt detected without newline"
    )

    let loginEvents = parser.consume("\nLogging in user 'tester' to Steam Public...\n")
    try expect(parser.current.openPrompt, equals: nil, "password prompt cleared after login starts")

    let progressEvents = parser.consume("[ 42%] Downloading item 3445534475...\n")
    try expect(
        progressEvents.contains(where: {
            if case .progress(let f) = $0, let f { return abs(f - 0.42) < 0.001 }
            return false
        }),
        equals: true,
        "progress 42% parsed"
    )

    let successLine = #"Success. Downloaded item 3445534475 to "/tmp/staging/steamapps/workshop/content/431960/3445534475""#
    let successEvents = parser.consume(successLine + "\n")
    try expect(
        successEvents.contains {
            if case .succeeded(let id, let path) = $0 {
                return id == "3445534475" && path?.contains("431960/3445534475") == true
            }
            return false
        },
        equals: true,
        "success with path parsed"
    )
    try expect(parser.current.didSucceed, equals: true, "success recorded")
    try expect(parser.current.failure, equals: nil, "no failure on success")
}

func testSteamCMDOutputParserClassifiesFailures() throws {
    // Invalid password (real SteamCMD line from local probe)
    let passwordParser = SteamCMDOutputParser()
    let pwEvents = passwordParser.consume(
        "Logging in user 'x' to Steam Public...ERROR (Invalid Password)\n"
    )
    try expect(
        pwEvents.contains(.failed(.invalidPassword)),
        equals: true,
        "invalid password classified"
    )
    try expect(passwordParser.current.failure, equals: .invalidPassword, "failure recorded")

    // No subscription — ownership requirement
    let subParser = SteamCMDOutputParser()
    let subEvents = subParser.consume(
        "ERROR! Workshop item download failed (No subscription)\n"
    )
    try expect(
        subEvents.contains(.failed(.noSubscription)),
        equals: true,
        "no subscription classified"
    )

    // Steam Guard rejection
    let guardParser = SteamCMDOutputParser()
    let guardEvents = guardParser.consume("FAILED (Two-factor code mismatch)\n")
    try expect(
        guardEvents.contains(.failed(.twoFactorRejected)),
        equals: true,
        "two-factor mismatch classified"
    )

    // C++ log noise with parentheses must NOT count as failure
    let noiseParser = SteamCMDOutputParser()
    let noiseEvents = noiseParser.consume(
        "src/common/iopollinghelpers_osx.cpp (109) : Unexpected thread race\n"
    )
    try expect(noiseEvents.contains { if case .failed = $0 { return true }; return false },
               equals: false,
               "log noise is not a failure")
    try expect(noiseParser.current.failure, equals: nil, "no failure from noise")
}

func testSteamCMDOutputParserDetectsSteamGuardPrompt() throws {
    let parser = SteamCMDOutputParser()
    let events = parser.consume("Steam Guard code: ")
    try expect(events.contains(.prompt(.steamGuard)), equals: true, "guard prompt detected")
    try expect(parser.current.sawSteamGuardChallenge, equals: true, "challenge recorded")

    let twoFactor = SteamCMDOutputParser()
    let tfEvents = twoFactor.consume("two-factor code: ")
    try expect(tfEvents.contains(.prompt(.steamGuard)), equals: true, "two-factor prompt")
}

func testSteamCMDInstallerParsesValveManifest() throws {
    let manifestText = """
    "osx"
    {
    \t"version"\t\t"1794537082"
    \t"ostype"\t\t"macos1015"
    \t"steamcmd_public_all"
    \t{
    \t\t"file"\t\t"steamcmd_public_all.zip.5a294ec531ae00e2fd9f94c280007cd605076692"
    \t\t"size"\t\t"60349"
    \t\t"sha2"\t\t"dfa7b42940635dd870337eeb9bd1084ff88ddd25c94c3fecf2a5d7262f993d75"
    \t}
    \t"steamcmd_bins_osx"
    \t{
    \t\t"file"\t\t"steamcmd_bins_osx.zip.d9863bb289f65bd96e776ac6f99669e55136a3f0"
    \t\t"size"\t\t"19746053"
    \t\t"sha2"\t\t"ef9f5b1a8580fb6148871b0893b700e7b94e81186bc91ef07af2d95a800aaaad"
    \t}
    \t"steamcmd_osx"
    \t{
    \t\t"file"\t\t"steamcmd_osx.zip.6bbc1e7314dedcf49293f7b80d2ab667de4bbd3d"
    \t\t"size"\t\t"4024837"
    \t\t"sha2"\t\t"3f554ad38ae87a431f3788bf4cacd29a5484c93d61f399810f150a2af0804a1c"
    \t\t"IsBootstrapperPackage"\t\t"1"
    \t}
    }
    "kvsign2"
    {
    \t"osx"\t\t"078d0a3f"
    }
    """
    let manifest = try SteamCMDInstaller.parseManifest(manifestText)
    try expect(manifest.version, equals: "1794537082", "version")
    try expect(manifest.packages.count, equals: 3, "three packages")
    let names = Set(manifest.packages.map(\.name))
    try expect(
        names.isSuperset(of: ["steamcmd_osx", "steamcmd_bins_osx"]),
        equals: true,
        "required packages present"
    )
    let bins = try require(manifest.packages.first(where: { $0.name == "steamcmd_bins_osx" }), "bins")
    try expect(bins.size, equals: 19_746_053, "bins size")
    try expect(bins.sha1, equals: "d9863bb289f65bd96e776ac6f99669e55136a3f0", "sha1 from filename")
    try expect(
        bins.url.absoluteString.contains("steamcmd_bins_osx.zip."),
        equals: true,
        "package url on Valve CDN"
    )

    // Missing required package must fail closed.
    let incomplete = """
    "osx"
    {
    \t"version"\t\t"1"
    \t"steamcmd_public_all"
    \t{
    \t\t"file"\t\t"steamcmd_public_all.zip.abc"
    \t\t"size"\t\t"1"
    \t\t"sha2"\t\t"\(String(repeating: "a", count: 64))"
    \t}
    }
    """
    do {
        _ = try SteamCMDInstaller.parseManifest(incomplete)
        throw TestFailure(message: "incomplete manifest should throw")
    } catch let error as SteamCMDInstaller.InstallError {
        try expect(error, equals: .malformedManifest, "incomplete manifest fails closed")
    }

    // Garbage input fails closed.
    do {
        _ = try SteamCMDInstaller.parseManifest("not a manifest {")
        throw TestFailure(message: "garbage should throw")
    } catch is SteamCMDInstaller.InstallError {
        // expected
    }
}

func testSteamCMDSessionRunsFakeDownloaderEndToEnd() async throws {
    // A fake steamcmd that mimics prompts, validates the password it reads
    // from stdin, and creates the workshop content tree on success.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("wm-fake-steam-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let script = root.appendingPathComponent("steamcmd")
    let scriptBody = """
    #!/bin/bash
    set -e
    # Parse +force_install_dir from argv
    INSTALL_DIR=""
    prev=""
    for arg in "$@"; do
      if [ "$prev" = "+force_install_dir" ]; then INSTALL_DIR="$arg"; fi
      prev="$arg"
    done
    if [ -z "$INSTALL_DIR" ]; then INSTALL_DIR="$PWD"; fi

    echo "Cached credentials not found."
    printf "password: "
    read -r PASS
    if [ "$PASS" != "correct-horse" ]; then
      echo "Logging in user 'tester' to Steam Public...ERROR (Invalid Password)"
      exit 0
    fi
    echo "Logging in user 'tester' to Steam Public...OK"
    echo "Waiting for user info...OK"
    echo "[ 10%] Downloading item 3445534475..."
    OUT="$INSTALL_DIR/steamapps/workshop/content/431960/3445534475"
    mkdir -p "$OUT"
    echo '{"type":"video","file":"clip.mp4","title":"Fake"}' > "$OUT/project.json"
    echo "fake-video-bytes" > "$OUT/clip.mp4"
    echo "[100%] Downloading item 3445534475..."
    echo "Success. Downloaded item 3445534475 to \\"$OUT\\""
    exit 0
    """
    try scriptBody.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

    let staging = root.appendingPathComponent("staging", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

    let command = SteamCMDCommand(
        account: "tester",
        itemID: "3445534475",
        forceInstallDirectory: staging.path
    )
    let session = SteamCMDSession(executable: script, timeout: 30)

    // Wrong password → classified failure
    let badResult = try await session.run(
        command: command,
        credentials: .init(username: "tester", password: "wrong"),
        environment: ["PATH": "/usr/bin:/bin"],
        workingDirectory: staging
    )
    try expect(badResult.succeeded, equals: false, "wrong password fails")
    try expect(badResult.failure, equals: .invalidPassword, "invalid password classified")

    // Fresh staging for the good attempt
    try? FileManager.default.removeItem(at: staging)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

    var progressSeen: [String] = []
    let goodResult = try await session.run(
        command: command,
        credentials: .init(username: "tester", password: "correct-horse"),
        environment: ["PATH": "/usr/bin:/bin"],
        workingDirectory: staging
    ) { progress in
        if let status = progress.status { progressSeen.append(status) }
    }

    try expect(goodResult.succeeded, equals: true, "correct password succeeds: \(goodResult.failure ?? .timeout) \(goodResult.outputTail)")
    let downloaded = try require(goodResult.downloadedDirectory, "downloaded directory exists")
    try expect(
        FileManager.default.fileExists(atPath: downloaded.appendingPathComponent("project.json").path),
        equals: true,
        "project.json present"
    )

    // Plan the import from the fake download
    let plan = WorkshopImportPlanner.plan(directory: downloaded)
    guard case .video(let source, let title) = plan else {
        throw TestFailure(message: "expected video plan from fake download, got \(plan)")
    }
    try expect(source.lastPathComponent, equals: "clip.mp4", "video entry")
    try expect(title, equals: "Fake", "title from project.json")
    try expect(
        progressSeen.contains { $0.contains("Downloading item") || $0.contains("password") || $0.contains("Logging in") },
        equals: true,
        "progress callbacks fired"
    )
}

func testWorkshopDownloadCoordinatorResolveRejectsNonLinks() async throws {
    let coordinator = WorkshopDownloadCoordinator()
    let result = try await coordinator.resolveAndFetch(rawLink: "not a workshop link")
    try expect(result == nil, equals: true, "non-link returns nil without network")

    let year = try await coordinator.resolveAndFetch(rawLink: "2026")
    try expect(year == nil, equals: true, "bare year is not a link")
}

func testWorkshopUnsupportedReasonUserMessagesAreActionable() throws {
    let reasons: [WorkshopUnsupportedReason] = [
        .unavailable, .scene, .application, .wrongApp(730),
        .unknownType("preset"), .missingEntryFile("a"), .entryFileMissingOnDisk("b")
    ]
    for reason in reasons {
        let message = reason.userMessage
        try expect(message.count > 10, equals: true, "message for \(reason) is substantive")
        try expect(message.contains("Wallpaper") || message.contains("壁纸") || message.contains("条目") || message.contains("类型") || message.contains("入口") || message.contains("Steam") || message.contains("macOS"),
                   equals: true,
                   "message for \(reason) names the domain")
    }
}

func testSteamCMDFailureSurfacesChineseLocalizedText() throws {
    let failures: [SteamCMDFailure] = [
        .invalidPassword, .noSubscription, .missingSteamGuardCode,
        .rateLimited, .timeout, .exitedBeforeCompletion(signInAccepted: true)
    ]
    for failure in failures {
        let description = try require(failure.errorDescription, "errorDescription for \(failure)")
        try expect(description.count > 8, equals: true, "substantive message for \(failure)")
        // Bridged NSError must expose the same localized Chinese text
        // (LocalizedError.errorDescription), not the English enum default.
        try expect(
            (failure as NSError).localizedDescription,
            equals: description,
            "NSError bridge uses LocalizedError text for \(failure)"
        )
        try expect(
            description.contains("operation couldn") == false,
            equals: true,
            "not the English NSError boilerplate for \(failure)"
        )
    }
    try expect(
        SteamCMDFailure.invalidPassword.errorDescription,
        equals: SteamCMDFailure.invalidPassword.userMessage,
        "errorDescription mirrors userMessage"
    )
}

func testWorkshopMetadataRejectsNonNumericItemID() throws {
    let malicious = """
    {"response":{"result":1,"resultcount":1,"publishedfiledetails":[{
      "publishedfileid":"../../etc","result":1,"title":"x"
    }]}}
    """
    do {
        _ = try WorkshopMetadataParser.parse(data: Data(malicious.utf8), requestedID: "1")
        throw TestFailure(message: "non-numeric id should be rejected")
    } catch let error as WorkshopMetadataError {
        try expect(error, equals: .emptyResponse, "malicious id fails closed")
    }
}

func testWorkshopDownloadCoordinatorRejectsTraversalItemID() async throws {
    let coordinator = WorkshopDownloadCoordinator()
    let context = WorkshopDownloadCoordinator.Context(
        rootDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("wm-ctx-\(UUID().uuidString)", isDirectory: true),
        credentials: .init(username: "u", password: "p")
    )
    do {
        _ = try await coordinator.downloadAndPlan(itemID: "../../evil", context: context)
        throw TestFailure(message: "traversal itemID should throw")
    } catch let error as SteamCMDFailure {
        try expect(error, equals: .itemUnavailable, "traversal id classified as unavailable")
    } catch {
        throw TestFailure(message: "unexpected error \(error)")
    }
}

func testWorkshopPlanTitleOverride() throws {
    let video = WorkshopImportPlan.video(
        sourceURL: URL(fileURLWithPath: "/tmp/a.mp4"),
        title: "Aurora Drift"
    )
    try expect(video.titleOverride, equals: "Aurora Drift", "video title override")
    let web = WorkshopImportPlan.webProject(
        directory: URL(fileURLWithPath: "/tmp/p"),
        entryFile: "index.html",
        title: "Home"
    )
    try expect(web.titleOverride, equals: "Home", "web title override")
    let unsupported = WorkshopImportPlan.unsupported(.scene)
    try expect(unsupported.titleOverride == nil, equals: true, "unsupported has no title")
}

func testResolveEntryBlocksSymlinkEscape() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("wm-sym-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let inside = root.appendingPathComponent("inside", isDirectory: true)
    try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: inside.appendingPathComponent("ok.html"))

    // Symlink inside project pointing outside
    let outside = FileManager.default.temporaryDirectory
        .appendingPathComponent("wm-outside-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: outside) }
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.html"))
    let link = root.appendingPathComponent("escape")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

    let blocked = WorkshopImportPlanner.resolveEntry("escape/secret.html", in: root)
    try expect(
        blocked.path.contains(".invalid-entry"),
        equals: true,
        "symlink escape is blocked"
    )
    let allowed = WorkshopImportPlanner.resolveEntry("inside/ok.html", in: root)
    try expect(
        FileManager.default.fileExists(atPath: allowed.path),
        equals: true,
        "legitimate nested entry still resolves"
    )
}

func testWorkshopBrowseURLBuildsFiltersAndPaging() throws {
    let all = WorkshopBrowseClient.browseURL(search: "rain", page: 2, kindFilter: nil)
    let allString = all.absoluteString
    try expect(allString.contains("appid=431960"), equals: true, "app id")
    try expect(allString.contains("searchtext=rain"), equals: true, "search")
    try expect(allString.contains("p=2"), equals: true, "page")
    try expect(allString.contains("requiredtags"), equals: false, "no tag filter for nil")

    let video = WorkshopBrowseClient.browseURL(search: "", page: 1, kindFilter: .video)
    try expect(
        video.absoluteString.contains("requiredtags%5B%5D=Video") || video.absoluteString.contains("requiredtags[]=Video"),
        equals: true,
        "video tag filter"
    )
}

func testWorkshopBrowseItemIDsFromHTMLMarkers() throws {
    let html = """
    <a href="https://steamcommunity.com/sharedfiles/filedetails/?id=111111111">x</a>
    <script>{"publishedfileid":"222222222"}</script>
    <div data-publishedfileid="333333333"></div>
    <span>publishedfileid\\":\\"444444444</span>
    <a href="?id=012345">leading zero rejected</a>
    <a href="?id=99">too short</a>
    """
    let ids = WorkshopBrowseClient.itemIDs(in: html, limit: 10)
    try expect(ids, equals: ["111111111", "222222222", "333333333", "444444444"], "document order unique ids")
}

func testWorkshopBrowseItemKindFromTags() throws {
    let video = WorkshopBrowseItem(
        id: "1", title: "v", previewURL: nil, tags: ["Video", "Anime"],
        fileSizeBytes: 10, itemDescription: ""
    )
    try expect(video.kind, equals: .video, "video kind")
    try expect(video.isImportable, equals: true, "video importable")

    let scene = WorkshopBrowseItem(
        id: "2", title: "s", previewURL: nil, tags: ["Scene"],
        fileSizeBytes: nil, itemDescription: ""
    )
    try expect(scene.kind, equals: .scene, "scene kind")
    try expect(scene.isImportable, equals: false, "scene not importable")

    let app = WorkshopBrowseItem(
        id: "3", title: "a", previewURL: nil, tags: ["Application"],
        fileSizeBytes: nil, itemDescription: ""
    )
    try expect(app.isImportable, equals: false, "application not importable")
}

func testSteamSessionStoreLoginStateAndLogout() throws {
    let suite = "wm.steam.session.\(UUID().uuidString)"
    let defaults = try require(UserDefaults(suiteName: suite), "suite")
    defer { defaults.removePersistentDomain(forName: suite) }

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("wm-steam-session-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let config = SteamSessionConfiguration.standard(rootDirectory: root)
    let store = SteamSessionStore(defaults: defaults)

    try expect(store.isLoggedIn(configuration: config), equals: false, "starts logged out")
    try expect(store.savedUsername, equals: nil, "no username")

    // Fake a SteamCMD login cache
    try FileManager.default.createDirectory(at: config.steamHomeDirectory, withIntermediateDirectories: true)
    try Data("host \"valve\"".utf8).write(
        to: config.steamHomeDirectory.appendingPathComponent("config.vdf")
    )
    store.saveUsername("tester")
    try expect(store.isLoggedIn(configuration: config), equals: true, "username + cache = logged in")

    store.logout(configuration: config)
    try expect(store.savedUsername, equals: nil, "logout clears username")
    try expect(
        FileManager.default.fileExists(
            atPath: config.steamHomeDirectory.appendingPathComponent("config.vdf").path
        ),
        equals: false,
        "logout removes config.vdf"
    )
    try expect(store.isLoggedIn(configuration: config), equals: false, "logged out after logout")
}

func testSteamLoginCommandNeverPutsPasswordInArgv() throws {
    let args = SteamLoginCommand.login(account: "tester")
    try expect(args.contains("+login"), equals: true, "has login")
    let loginIndex = try require(args.firstIndex(of: "+login"), "login idx")
    try expect(args[loginIndex + 1], equals: "tester", "account after login")
    try expect(
        args.contains { $0.lowercased().contains("password") || $0.contains("secret") },
        equals: false,
        "no password-like argv"
    )
    try expect(args.last, equals: "+quit", "quits")
    try expect(args.contains("-inhibitbootstrap"), equals: true, "no mid-login self-update")
}

func testMetadataParserParseAllDropsBadRows() throws {
    let json = """
    {"response":{"result":1,"resultcount":3,"publishedfiledetails":[
      {"publishedfileid":"111111","result":1,"title":"ok","consumer_app_id":431960},
      {"publishedfileid":"../../evil","result":1,"title":"bad"},
      {"publishedfileid":"222222","result":9,"title":"gone"}
    ]}}
    """
    let rows = try WorkshopMetadataParser.parseAll(data: Data(json.utf8))
    try expect(rows.count, equals: 2, "non-numeric id dropped, result 9 kept as unavailable row")
    try expect(rows[0].itemID, equals: "111111", "first ok row")
    try expect(rows[0].isAvailable, equals: true, "available")
    try expect(rows[1].isAvailable, equals: false, "result 9 unavailable")
}

func testSteamSessionMarkerFlipsLoginImmediately() throws {
    let suite = "wm.steam.marker.\(UUID().uuidString)"
    let defaults = try require(UserDefaults(suiteName: suite), "suite")
    defer { defaults.removePersistentDomain(forName: suite) }
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("wm-steam-marker-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let config = SteamSessionConfiguration.standard(rootDirectory: root)
    let store = SteamSessionStore(defaults: defaults)

    // Username alone (no SteamCMD cache, no marker) is not logged in.
    store.saveUsername("tester")
    try expect(store.isLoggedIn(configuration: config), equals: false, "username without marker/cache")

    // Marker written on successful login flips state even before SteamCMD cache files exist.
    store.writeSessionMarker(username: "tester", configuration: config)
    try expect(store.isLoggedIn(configuration: config), equals: true, "marker counts as logged in")

    store.logout(configuration: config)
    try expect(store.isLoggedIn(configuration: config), equals: false, "logout clears marker")
}

func testSteamLoginGateNeverRepromptsAfterDismiss() throws {
    // First open, not logged in → show login.
    try expect(
        SteamLoginGate.decide(isLoggedIn: false, sheetDismissed: false, loginSucceeded: false, loginCancelled: false),
        equals: .showLogin,
        "first open prompts"
    )
    // Already logged in → browse, no sheet.
    try expect(
        SteamLoginGate.decide(isLoggedIn: true, sheetDismissed: false, loginSucceeded: false, loginCancelled: false),
        equals: .continueBrowsing,
        "logged in continues"
    )
    // Login succeeded then sheet dismissed → continue, never showLogin (the loop bug).
    try expect(
        SteamLoginGate.decide(isLoggedIn: true, sheetDismissed: true, loginSucceeded: true, loginCancelled: false),
        equals: .continueBrowsing,
        "success continues"
    )
    // Success flag set even if isLoggedIn check lags → still continue (marker race).
    try expect(
        SteamLoginGate.decide(isLoggedIn: false, sheetDismissed: true, loginSucceeded: true, loginCancelled: false),
        equals: .continueBrowsing,
        "success flag wins over lagging isLoggedIn"
    )
    // Cancel closes browse, never re-shows login.
    try expect(
        SteamLoginGate.decide(isLoggedIn: false, sheetDismissed: true, loginSucceeded: false, loginCancelled: true),
        equals: .closeBrowse,
        "cancel closes browse"
    )
    // Swipe dismiss without outcome and still logged out → close browse (no loop).
    try expect(
        SteamLoginGate.decide(isLoggedIn: false, sheetDismissed: true, loginSucceeded: false, loginCancelled: false),
        equals: .closeBrowse,
        "orphan dismiss closes browse"
    )
    // Swipe dismiss after already logged in → continue.
    try expect(
        SteamLoginGate.decide(isLoggedIn: true, sheetDismissed: true, loginSucceeded: false, loginCancelled: false),
        equals: .continueBrowsing,
        "orphan dismiss when logged in continues"
    )
    // Cancel must win even if somehow also marked success.
    try expect(
        SteamLoginGate.decide(isLoggedIn: true, sheetDismissed: true, loginSucceeded: true, loginCancelled: true),
        equals: .closeBrowse,
        "explicit cancel wins"
    )
}

func testRenameUpdateKeepsOtherWallpapers() throws {
    // Regression: the workshop title-override rename must not wipe the rest
    // of the library. save(items: [one]) is a full replace; update(item:) merges.
    let fixture = try Fixture()
    let first = WallpaperItem(
        id: UUID(), name: "existing", type: .image,
        sourceURL: fixture.root.appendingPathComponent("a.jpg"),
        storageMode: .externalReference
    )
    let second = WallpaperItem(
        id: UUID(), name: "imported", type: .image,
        sourceURL: fixture.root.appendingPathComponent("b.jpg"),
        storageMode: .externalReference
    )
    try fixture.store.save(items: [first, second])

    var renamed = second
    renamed.name = "Workshop Title"
    _ = try fixture.store.update(item: renamed)

    let items = try fixture.store.items()
    try expect(items.count, equals: 2, "rename via update must keep every wallpaper")
    try expect(
        items.first(where: { $0.id == first.id })?.name,
        equals: "existing",
        "unrelated wallpaper must survive"
    )
    try expect(
        items.first(where: { $0.id == second.id })?.name,
        equals: "Workshop Title",
        "renamed wallpaper must keep the new title"
    )
}

func testWorkshopBrowseQueryBuildsSortAndRating() throws {
    let base = WorkshopBrowseQuery()
    try expect(base.kindTag, equals: nil, "no type filter by default")
    try expect(base.excludedKindTags, equals: ["Application", "Scene"], "hides Application and Scene by default")
    try expect(base.sort, equals: .trending, "default sort trending")

    // Type filter pins the type and suppresses sibling exclusions.
    let video = WorkshopBrowseQuery(kindFilter: .video, sort: .topRated)
    try expect(video.kindTag, equals: "Video", "video tag")
    try expect(video.excludedKindTags, equals: [], "no exclusions when a type is pinned")
    let scene = WorkshopBrowseQuery(kindFilter: .scene)
    try expect(scene.kindTag, equals: "Scene", "Scene can still be explicitly requested")
    try expect(scene.excludedKindTags, equals: [], "explicit Scene filter overrides default exclusions")
    let videoURL = WorkshopBrowseClient.browseURL(for: video)
    let videoString = videoURL.absoluteString
    try expect(videoString.contains("browsesort=toprated"), equals: true, "sort in URL")
    try expect(
        videoString.contains("requiredtags%5B%5D=Video") || videoString.contains("requiredtags[]=Video"),
        equals: true,
        "video requiredtag"
    )

    // Age rating adds a second required tag; exclusions survive when no type pin.
    let rated = WorkshopBrowseQuery(ageRating: .everyone)
    let ratedURL = WorkshopBrowseClient.browseURL(for: rated)
    let ratedString = ratedURL.absoluteString
    try expect(
        ratedString.contains("Everyone"),
        equals: true,
        "age rating in requiredtags"
    )
    try expect(
        ratedString.contains("excludedtags%5B%5D=Application") || ratedString.contains("excludedtags[]=Application"),
        equals: true,
        "Application excluded alongside rating"
    )
    try expect(
        ratedString.contains("excludedtags%5B%5D=Scene") || ratedString.contains("excludedtags[]=Scene"),
        equals: true,
        "Scene excluded alongside rating"
    )

    // Page clamps to 1.
    try expect(WorkshopBrowseQuery(page: 0).page, equals: 1, "page clamped")
}

func testWorkshopBrowseItemAgeRatingFromTags() throws {
    let everyone = WorkshopBrowseItem(
        id: "1", title: "a", previewURL: nil,
        tags: ["Video", "Everyone"], fileSizeBytes: nil, itemDescription: ""
    )
    try expect(everyone.ageRating, equals: .everyone, "Everyone tag")
    let mature = WorkshopBrowseItem(
        id: "2", title: "b", previewURL: nil,
        tags: ["Video", "Mature"], fileSizeBytes: nil, itemDescription: ""
    )
    try expect(mature.ageRating, equals: .mature, "Mature tag")
    try expect(mature.isImportable, equals: true, "rating does not block import")
    let none = WorkshopBrowseItem(
        id: "3", title: "c", previewURL: nil,
        tags: ["Video"], fileSizeBytes: nil, itemDescription: ""
    )
    try expect(none.ageRating, equals: nil, "missing rating tag is nil")
}

let tests: [(String, () throws -> Void)] = [
    ("wallpaper metadata round trips", testWallpaperMetadataRoundTrips),
    ("legacy wallpaper JSON without metadata decodes", testLegacyWallpaperJSONWithoutMetadataDecodes),
    ("bulk metadata save preserves wallpaper state", testBulkMetadataSavePreservesWallpaperState),
    ("detects wallpaper types", testDetectsWallpaperTypes),
    ("imports remote web wallpapers without network checks", testRemoteWebWallpaperImportPersistsWithoutNetworkAccess),
    ("managed import copies file", testManagedImportCopiesFile),
    ("normalizes HEVC sample entries for playback", testVideoContainerCompatibilityNormalizesRealHev1Entries),
    ("external import keeps reference", testExternalImportKeepsReference),
    ("reports missing external file", testReportsMissingExternalFile),
    ("detects nested HTML project", testNestedHTMLProjectIsDetected),
    ("reports missing HTML entry", testMissingHTMLEntryIsReported),
    ("persists display assignments", testDisplayAssignmentsPersist),
    ("imports HTML project with selected entry", testHTMLProjectImportPersistsSelectedEntry),
    ("managed copy preserves nested HTML project resources", testManagedCopyOfNestedHTMLEntryPreservesProjectResources),
    ("single HTML import copies only the selected file", testSingleHTMLImportOnlyCopiesSelectedFile),
    ("rejects unsupported and missing sources", testUnsupportedAndMissingSourcesFailClearly),
    ("persists and recovers availability", testPersistenceAndAvailabilityRecovery),
    ("relocates missing external wallpaper", testRelocatesMissingExternalWallpaper),
    ("removes managed wallpaper and asset", testRemovesManagedWallpaperAndAsset),
    ("relocates HTML project and preserves entry", testRelocatesHTMLProjectAndPreservesEntry),
    ("relocation keeps nested entry after restart", testRelocationPreservesNestedEntryAfterRestart),
    ("relocation rejects a missing original entry", testRelocationRejectsMissingOriginalEntry),
    ("cleans invalid managed HTML imports", testInvalidHTMLImportCleansManagedAsset),
    ("rejects mismatched managed relocation", testRelocateManagedWallpaperCleansCopyOnFailure),
    ("activates web click once", testWebMouseEventScriptActivatesClickOnce),
    ("supports wallpaper click effect", testPlaybackPolicySupportsWebWallpaperClickEffect),
    ("encodes playback and display defaults", testPlaybackDefaultsAndDisplayAssignmentCoding),
    ("persists custom library configuration", testLibraryConfigurationRoundTripsCustomPath),
    ("does not invent missing library configuration", testMissingLibraryConfigurationDoesNotCreateEmptyLibrary),
    ("persists groups and bulk removal", testGroupsAndBulkRemovalPersist),
    ("assigns groups in bulk", testBulkGroupAssignmentPersistsAllChangesWithOneStoreOperation),
    ("normalizes and persists display queue", testDisplayQueueNormalizesAndPersists),
    ("keeps display queues independent", testDisplayQueuesStayIndependent),
    ("evaluates playback suspension rules", testPlaybackPolicySuspensionRules),
    ("resolves static lock screen resources", testLockScreenResourceResolverSelectsStaticImages),
    ("persists and removes lock screen overrides", testLockScreenOverridePersistsAndIsRemovedWithWallpaper),
    ("validates and round trips custom hotkeys", testHotKeyShortcutValidationAndPersistence),
    ("gates automatic update checks and installation", testUpdateAutomationPreferencesGateSchedulingAndInstall),
    ("suspends on screen sleep and session inactivity", testScreenSleepAndSessionInactivityAlwaysSuspend),
    ("converts fullscreen geometry quartz to cocoa", testFullscreenGeometryConvertsQuartzToCocoa),
    ("tolerates menu bar inset in fullscreen detection", testFullscreenGeometryToleratesMenuBarInset),
    ("recovers index from backup without orphan cleanup", testMissingIndexSkipsOrphanCleanupAndRecoversFromBackup),
    ("stale backup recovery never deletes newer assets", testStaleBackupRecoveryDoesNotDeleteNewerAssets),
    ("deduplicates and auto sorts playback queues", testPlaybackQueueDeduplicatesAndAutoSorts),
    ("enforces playback queue defaults and overrides", testPlaybackQueueHasDefaultConstraintsAndPerItemOverrides),
    ("persists queue advance mode", testPlaybackQueueAdvanceModeRoundTrips),
    ("maps legacy advance boolean to completion mode", testLegacyPlaybackQueueAdvanceBooleanDecodes),
    ("decodes legacy queue without advance setting", testLegacyPlaybackQueueWithoutAdvanceSettingDecodes),
    ("falls back to fixed interval for non-video items", testNonVideoItemsFallBackToFixedIntervalInCompletionMode),
    ("requires compatibility playback for AV1", testVideoPlaybackCompatibilityRequiresCacheForAV1),
    ("plans streaming compatibility playback", testVideoCompatibilityStreamPlanPipesDecodedFrames),
    ("ignores media payload lookalikes", testVideoContainerCompatibilityIgnoresMediaPayloadLookalikes),
    ("keeps external references without video proxies", testExternalReferenceDoesNotPersistVideoProxy),
    ("removes legacy external playback proxies", testStoreRemovesLegacyExternalPlaybackProxy),
    ("uses landscape 16:9 wallpaper preview layout", testWallpaperPreviewUsesLandscapeSixteenByNineLayout),
    ("uses real 20-item pagination for library and groups", testWallpaperLibraryPaginationUsesSamePageContractForGroups),
    ("sizes grid pages from the viewport without resizing tiles", testWallpaperLibraryGridPageSizeFitsViewportWithoutResizingTiles),
    ("sizes list pages from the viewport height", testWallpaperLibraryListPageSizeTracksViewportHeight),
    ("clamps pagination for tiny viewports", testWallpaperLibraryPageLayoutClampsTinyViewports),
    ("invalidates edited active queue bindings", testDisplayBindingInvalidatesEditedQueue),
    ("migrates legacy display queues", testStoreMigratesLegacyDisplayQueues),
    ("round trips display queue state", testQueueStoreRoundTripsDisplayQueueState),
    ("formats application version information", testApplicationVersionInfoFormatting),
    ("bounds video-completion stall watchdog", testPlaybackQueueStallWatchdogInterval),
    ("reconciles queue index after deleting members", testPlaybackIndexReconcilerKeepsCurrentItemAndChoosesSuccessor),
    ("separates playback pause from queue stop", testPlaybackSchedulingStateSeparatesPauseFromQueueStop),
    ("supports all fit modes and bounded tile layout", testFitModesAndTileLayout),
    ("fill covers portrait viewport on both axes", testFillCoversPortraitViewportOnBothAxes),
    ("per-wallpaper override persists and legacy inherits", testPerWallpaperFitOverridePersistsAndLegacyRecordsInherit),
    ("field-level updates preserve unrelated fields", testFieldLevelUpdatesPreserveOtherChanges),
    ("preserves remaining playback deadlines", testPlaybackDeadlineMathPreservesRemainingTime),
    ("only loops ffmpeg after a clean drained EOF", testVideoStreamExitPolicyOnlyLoopsCleanEOF),
    ("tracks AVPlayer time and duration progress", testVideoPlaybackProgressUsesActualTimeAndDuration),
    ("keeps unchanged displays during screen reconciliation", testDisplayReconcilerDoesNotRebuildUnchangedScreens),
    ("uses stable uuid display profile ids", testDisplayIdentityUsesStableUUID),
    ("migrates legacy displays by name across swapped ids", testDisplayProfileMigrationUsesNamesAcrossSwappedIDs),
    ("keeps profiles through a reboot id swap", testDisplayProfileMergeSurvivesRebootIDSwap),
    ("matches a changed uuid by hardware serial", testDisplayProfileMergeMatchesChangedUUIDBySerial),
    ("ignores a legacy record for another display", testDisplayProfileMergeIgnoresForeignLegacyRecord),
    ("fills missing profile data from an older legacy file", testDisplayProfileMergeFillsMissingDataFromOlderLegacy),
    ("keeps newer profile data over older legacy records", testDisplayProfileMergeKeepsNewerProfileData),
    ("round trips display profiles through the store", testDisplayProfilesRoundTripThroughStore),
    ("defaults legacy wallpapers to visible", testHiddenFlagDefaultsAndRoundTrips),
    ("updates hidden flag without clobbering edits", testUpdateHiddenPreservesOtherFields),
    ("derives PBKDF2-HMAC-SHA256 vectors", testPBKDF2KnownVectors),
    ("verifies hidden wallpaper passwords", testHiddenWallpaperLockVerification),
    ("filters hidden wallpapers from queues", testWallpaperVisibilityFiltersQueues),
    ("pauses fullscreen only on the matching display", testFullScreenPauseIsPerDisplay),
    ("migrates a complete wallpaper library", testLibraryMigrationCopiesCompleteLibrary),
    ("rebases resource URLs during library migration", testLibraryMigrationRebasesResourceURLs),
    ("preserves external references and backup-only migration", testLibraryMigrationPreservesExternalInsideAndBackupOnly),
    ("rejects unsafe library migration targets", testLibraryMigrationRejectsUnsafeTargets),
    ("classifies queues by hidden membership", testQueueKindFollowsHiddenMembership),
    ("resolves normal and hidden queue slots", testQueueSlotResolverMatchesQueueKind),
    ("decodes legacy display bindings into the default slot", testLegacyDisplayBindingDecodesIntoDefaultSlot),
    ("requires a one-shot native gesture for external navigation", testExternalNavigationRequiresOneShotNativeGesture),
    ("bounds WebContent recovery with healthy reset", testWebContentRecoveryUsesBoundedBackoffAndHealthyReset),
    ("delivers fragmented video tail frames without loss", testVideoFrameBufferDeliversFragmentedTailWithoutLoss),
    ("parses and compares semantic versions", testSemVerParsingAndComparison),
    ("parses newer GitHub release", testUpdateCheckerParsesNewerRelease),
    ("reports up to date releases", testUpdateCheckerReportsUpToDate),
    ("rejects malformed update payloads", testUpdateCheckerRejectsMalformedPayloads),
    ("allows missing checksums asset", testUpdateCheckerAllowsMissingChecksumsAsset),
    ("matches update asset names", testUpdateCheckerAssetNameMatching),
    ("accepts live GitHub release payload shape", testUpdateCheckerAcceptsLiveReleasePayloadShape),
    ("parses SHA256SUMS checksum files", testUpdateChecksumsParsing),
    ("ignores malformed checksum rows", testUpdateChecksumsParsingIgnoresGarbage),
    ("looks up checksums by asset name", testUpdateChecksumLookupByAssetName),
    ("matches SHA-256 known vectors", testUpdateSHA256OfDataMatchesKnownVector),
    ("detects artifact tampering", testUpdateFileVerificationDetectsTampering),
    ("streams large artifact hashes", testUpdateFileVerificationReadsLargeArtifactsInChunks),
    ("parses update asset size", testUpdateCheckerParsesAssetSize),
    ("detects download stalls by average speed", testDownloadTransferPolicyDetectsStalls),
    ("caps download attempts and keeps resume state", testDownloadRetryStateCapsAttemptsAndKeepsResume),
    ("resumes interrupted update download and verifies", testUpdateDownloadResumesInterruptedTransferAndVerifies),
    ("rejects tampered bytes after resume", testUpdateDownloadRejectsTamperedBytesAfterResume),
    ("rejects bad signature after resume", testUpdateDownloadRejectsBadSignatureAfterResume),
    ("reports stalled transfer after retry limit", testUpdateDownloadReportsStalledTransferAfterRetryLimit),
    ("quotes shell paths safely", testUpdateShellQuotingSurvivesApostrophes),
    ("waits for parent and rolls back install", testUpdateInstallScriptWaitsForParentAndRollsBack),
    ("copy failure leaves original app untouched", testUpdateCopyFailureLeavesOriginalAppUntouched),
    ("writes failure journal and relaunches old app", testUpdateFailureWritesJournalAndRelaunchesOldApp),
    ("installer startup handshake detects live and dead scripts", testInstallerStartupHandshakeDetectsLiveAndDeadScripts),
    ("generated installer uses the verified pending helper", testGeneratedInstallerUsesVerifiedPendingSwapHelper),
    ("health failure rolls back through the real helper", testHealthFailureRollsBackWithRealHelperAndJournal),
    ("failed rollback launches the preserved backup", testFailedRollbackLaunchesPreservedBackup),
    ("relaunch failure restores original app", testUpdateRelaunchFailureRestoresOriginalApp),
    ("validated sibling installs successfully", testUpdateSuccessfulInstallUsesValidatedSibling),
    ("wrong pending version aborts before swap", testUpdateRejectsWrongPendingVersionBeforeSwap),
    ("atomic swap keeps a complete app at target", testAtomicSwapKeepsCompleteAppAtTarget),
    ("atomic swap accepts installer temporary names", testAtomicSwapAcceptsInstallerTemporaryNames),
    ("removes stale installer backups but keeps previous", testRemoveStaleInstallerBackupsKeepsPrevious),
    ("round trips failed-install journal", testUpdateInstallJournalRoundTripsFailure),
    ("reads installed version from the app on disk", testInstalledVersionReadsBundlePlist),
    ("skips installing a version already on disk", testUpdateVersionGuardUsesDiskVersion),
    ("launches the replacement directly when open drops arguments", testInstallScriptUsesDirectLaunch),
    ("open without health confirmation rolls back", testUpdateOpenWithoutHealthConfirmationRollsBack),
    ("rollback failure preserves the complete old backup", testUpdateRollbackFailurePreservesBackupAndDoesNotOpenBrokenTarget),
    ("health acknowledgement matches the install token", testUpdateHealthHandshakeWritesMatchingTokenAtomically),
    ("install lock excludes other owners and releases", testUpdateInstallLockExcludesOtherOwnersAndReleases),
    ("helper accepts inherited lock and releases on exit", testInstallScriptUsesInheritedLockAndReleasesAfterHelperExit),
    ("prepares and validates update bundle", testUpdatePrepareExtractsAndValidatesBundleVersion),
    ("rejects translocated and bare binaries", testUpdatePreflightRejectsTranslocatedAndBareBinaries),
    ("locates nested app bundles", testUpdateLocateAppBundleFindsNestedLayout),
    ("round trips update signatures", testUpdateSignatureRoundTrip),
    ("rejects foreign update signatures", testUpdateSignatureRejectsForeignKeys),
    ("parses update signature files", testUpdateSignatureFileParsing),
    ("round trips signatures on disk", testUpdateSignatureFileRoundTripOnDisk),
    ("matches signature asset names", testUpdateSignatureAssetNaming),
    ("replaces queue membership keeping order", testQueueReplaceWallpaperIDsKeepsOrderAndDropsRemoved),
    ("keeps first duplicate dictionary keys", testUniquedDictionaryKeepsFirstOccurrence),
    ("patches metadata without clobbering edits", testUpdateMetadataPatchesOnlyEnrichmentFields),
    ("persists index before deleting managed files", testRemovePersistsIndexBeforeDeletingFiles),
    ("resumes legacy queue migration from partial writes", testMigrationResumesFromPlanAfterPartialWrite),
    ("requires cross-referenced modern queue files", testModernQueueValidationRequiresCrossReferences),
    ("keeps legacy display state when modern bindings are empty", testEmptyModernBindingsDoNotRetireNonEmptyLegacyQueues),
    ("blocks queue persistence after a load failure", testLibraryPersistenceGateBlocksAfterLoadFailure),
    ("load failure blocks writes and preserves bytes", testQueueLoadFailureBlocksWritesAndPreservesBytes),
    ("missing queue files allow writes", testMissingQueueFilesAllowWrites),
    ("queue load recovers after repair", testQueueLoadRecoversAfterRepair),
    ("decodes legacy items with safe fallbacks", testWallpaperItemLegacyDecodeUsesSafeFallbacks),
    ("aggregates drop URLs in drag order", testDropURLCollectorPreservesOrderAndDrainsOnce),
    ("keeps edited modern pair over legacy residual", testMigrationKeepsEditedModernPairWhenLegacyResidualExists),
    ("resumes migration from existing plan file", testMigrationResumesFromExistingPlan),
    ("recovered index does not trigger layout cleanup", testRecoveredIndexDoesNotTriggerLayoutMigrationCleanup),
    ("migrates legacy flat assets into UUID folders", testLegacyFlatAssetsMigrateToUUIDFolders),
    ("parses orphan UUID prefixes past hyphens", testOrphanCleanupParsesUUIDPrefixPastHyphens),
    ("streams signature digests matching one-shot", testStreamingSignatureDigestMatchesOneShot),
    ("kills timed-out child processes", testProcessRunnerTimesOutAndKillsChild),
    ("cleans full staging directory on install", testInstallScriptCleansFullStagingDirectory),
    ("parses workshop links", testWorkshopLinkParsesSupportedForms),
    ("rejects invalid workshop links", testWorkshopLinkRejectsInvalidInput),
    ("parses workshop metadata response", testWorkshopMetadataParsesSteamResponse),
    ("maps workshop type tags and availability", testWorkshopMetadataTypeTagsAndAvailability),
    ("parses unavailable workshop response", testWorkshopMetadataUnavailableResponse),
    ("parses workshop project manifest", testWorkshopProjectManifestParsesVideoAndWeb),
    ("routes workshop import plans by type", testWorkshopImportPlannerRoutesSupportedTypes),
    ("hardens workshop entry paths", testWorkshopImportPlannerHandlesBackslashAndTraversalEntries),
    ("builds steamcmd command without password", testSteamCMDCommandBuildsLoginWithoutPassword),
    ("parses steamcmd password prompt and success", testSteamCMDOutputParserDetectsPasswordPromptAndSuccess),
    ("classifies steamcmd failures", testSteamCMDOutputParserClassifiesFailures),
    ("detects steam guard prompts", testSteamCMDOutputParserDetectsSteamGuardPrompt),
    ("parses valve steamcmd manifest", testSteamCMDInstallerParsesValveManifest),
    ("runs fake steamcmd download end to end", { try runAsyncTest { try await testSteamCMDSessionRunsFakeDownloaderEndToEnd() } }),
    ("coordinator rejects non-links without network", { try runAsyncTest { try await testWorkshopDownloadCoordinatorResolveRejectsNonLinks() } }),
    ("workshop unsupported messages are actionable", testWorkshopUnsupportedReasonUserMessagesAreActionable),
    ("steamcmd failures use Chinese localized text", testSteamCMDFailureSurfacesChineseLocalizedText),
    ("workshop metadata rejects non-numeric ids", testWorkshopMetadataRejectsNonNumericItemID),
    ("coordinator rejects traversal item ids", { try runAsyncTest { try await testWorkshopDownloadCoordinatorRejectsTraversalItemID() } }),
    ("workshop plan exposes title override", testWorkshopPlanTitleOverride),
    ("rename update keeps other wallpapers", testRenameUpdateKeepsOtherWallpapers),
    ("resolve entry blocks symlink escape", testResolveEntryBlocksSymlinkEscape),
    ("builds workshop browse urls", testWorkshopBrowseURLBuildsFiltersAndPaging),
    ("builds browse query sort and rating", testWorkshopBrowseQueryBuildsSortAndRating),
    ("parses age rating from tags", testWorkshopBrowseItemAgeRatingFromTags),
    ("extracts workshop browse ids from html", testWorkshopBrowseItemIDsFromHTMLMarkers),
    ("maps browse item kinds from tags", testWorkshopBrowseItemKindFromTags),
    ("steam session store login state and logout", testSteamSessionStoreLoginStateAndLogout),
    ("steam session marker flips login immediately", testSteamSessionMarkerFlipsLoginImmediately),
    ("steam login gate never reprompts after dismiss", testSteamLoginGateNeverRepromptsAfterDismiss),
    ("steam login command keeps password out of argv", testSteamLoginCommandNeverPutsPasswordInArgv),
    ("metadata parseAll drops bad rows", testMetadataParserParseAllDropsBadRows),
    ("keeps deleted placeholders across reorder", testQueueReorderKeepsDeletedPlaceholders)
]

// Prints the generated installer for the end-to-end update smoke test.
if CommandLine.arguments.count >= 8, CommandLine.arguments[1] == "--print-install-script" {
    guard let parentPID = Int32(CommandLine.arguments[2]) else {
        FileHandle.standardError.write(Data("invalid parent pid\n".utf8))
        exit(2)
    }
    let resultArgument = CommandLine.arguments[7]
    let script = UpdateInstaller.installScript(
        parentPID: parentPID,
        sourceAppPath: CommandLine.arguments[3],
        targetAppPath: CommandLine.arguments[4],
        stagingPath: CommandLine.arguments[5],
        expectedVersion: CommandLine.arguments[6],
        resultFile: resultArgument == "-" ? nil : resultArgument
    )
    print(script, terminator: "")
    exit(0)
}

// Limited integration probe used by scripts/update-install-lock-smoke.sh.
// It exercises a real process/descriptor boundary without starting the app.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--update-lock-probe" {
    do {
        let lock = try UpdateInstallLock(
            targetAppURL: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        )
        print("LOCKED \(lock.ownerToken)")
        fflush(stdout)
        Thread.sleep(forTimeInterval: 2)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

// Shipping swap helper, exposed so generated-script tests can exercise the
// real producer/consumer contract instead of a permissive fake swapper.
if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--update-swap" {
    do {
        try UpdateInstaller.atomicSwap(
            pendingAppURL: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true),
            targetAppURL: URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        )
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        exit(1)
    }
}
if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--update-lock-check" {
    do {
        try UpdateInstaller.verifyInheritedLock(
            lockURL: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: false),
            expectedToken: CommandLine.arguments[3]
        )
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

// Production launch handoff, exposed for the end-to-end smoke test: acquire
// the target lock, write and spawn the generated script, wait for its startup
// marker, then exit so the script can proceed. Mirrors UpdateService exactly.
if CommandLine.arguments.count == 7, CommandLine.arguments[1] == "--launch-detached-probe" {
    let target = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    let source = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
    let staging = URL(fileURLWithPath: CommandLine.arguments[4], isDirectory: true)
    let version = CommandLine.arguments[5]
    let resultFile = URL(fileURLWithPath: CommandLine.arguments[6], isDirectory: false)
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        do {
            let lock = try UpdateInstallLock(targetAppURL: target)
            let prepared = PreparedUpdateInstall(
                appBundleURL: source,
                version: version,
                targetAppURL: target,
                stagingDirectory: staging
            )
            try await UpdateInstaller.launchDetachedInstall(
                of: prepared,
                installLock: lock,
                resultFile: resultFile
            )
            print("DETACHED_STARTED")
            fflush(stdout)
            semaphore.signal()
        } catch {
            FileHandle.standardError.write(Data("DETACHED_FAILED: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    semaphore.wait()
    exit(0)
}

// Live SteamCMD install smoke: fetch Valve's manifest, verify+extract every
// package into a temp root, then launch the installed binary with +quit.
// Network required; used by the steam workshop integration verification.
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--steamcmd-install-smoke" {
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        do {
            let installer = SteamCMDInstaller()
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("wm-steamcmd-smoke-\(UUID().uuidString)", isDirectory: true)
            print("STEAMCMD_SMOKE_DEST: \(dest.path)")
            fflush(stdout)
            let executable = try await installer.install(to: dest) { state in
                if case .ready = state { print("STEAMCMD_SMOKE_READY") }
                fflush(stdout)
            }
            // Exit 42 is SteamCMD's MAGIC_RESTART_EXITCODE: the bootstrapper
            // updated itself and wants one relaunch. Cap the loop.
            var finalStatus: Int32 = -1
            for attempt in 1...3 {
                let process = Process()
                process.executableURL = executable
                process.arguments = ["+quit"]
                process.currentDirectoryURL = dest
                process.environment = [
                    "PATH": "/usr/bin:/bin",
                    "HOME": dest.path,
                    "TERM": "dumb",
                    "LANG": "en_US.UTF-8"
                ]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                let deadline = Date().addingTimeInterval(180)
                while process.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.2)
                }
                if process.isRunning {
                    process.terminate()
                    Thread.sleep(forTimeInterval: 1)
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                    print("STEAMCMD_SMOKE_TIMEOUT")
                    fflush(stdout)
                    exit(1)
                }
                finalStatus = process.terminationStatus
                print("STEAMCMD_SMOKE_EXIT[\(attempt)]: \(finalStatus)")
                fflush(stdout)
                if finalStatus != 42 { break }
            }
            guard finalStatus == 0 else {
                print("STEAMCMD_SMOKE_BAD_EXIT: \(finalStatus)")
                fflush(stdout)
                exit(1)
            }
            print("STEAMCMD_INSTALL_SMOKE_PASSED")
            fflush(stdout)
            try? FileManager.default.removeItem(at: dest)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("STEAMCMD_SMOKE_ERROR: \(error)\n".utf8))
            exit(1)
        }
    }
    semaphore.wait()
    exit(0)
}


// Real-machine Steam login + workshop download smoke. Credentials come from
// the environment only (WALLPAPERMAC_STEAM_USER / WALLPAPERMAC_STEAM_PASS)
// and are never written to disk or argv.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--steam-live-test" {
    let itemID = CommandLine.arguments[2]
    guard let user = ProcessInfo.processInfo.environment["WALLPAPERMAC_STEAM_USER"],
          let pass = ProcessInfo.processInfo.environment["WALLPAPERMAC_STEAM_PASS"],
          !user.isEmpty, !pass.isEmpty else {
        FileHandle.standardError.write(Data("STEAM_LIVE_MISSING_CREDENTIALS\n".utf8))
        exit(2)
    }
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        do {
            let coordinator = WorkshopDownloadCoordinator()
            let context = WorkshopDownloadCoordinator.Context(
                rootDirectory: WorkshopDownloadCoordinator.defaultRootDirectory(),
                credentials: .init(username: user, password: pass, steamGuardCode: nil)
            )
            print("STEAM_LIVE_ENSURE_STEAMCMD")
            fflush(stdout)
            let plan = try await coordinator.downloadAndPlan(itemID: itemID, context: context) { phase in
                switch phase {
                case .installingSteamCMD(let state):
                    if case .ready = state { print("STEAM_LIVE_STEAMCMD_READY") }
                case .downloading(let status, let fraction):
                    if let status {
                        let pct = fraction.map { String(Int($0 * 100)) + "%" } ?? "-"
                        print("STEAM_LIVE_PROGRESS \(pct) \(status)")
                    }
                default:
                    break
                }
                fflush(stdout)
            }
            // Import into an isolated temp library (full end-to-end).
            let tempRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("wm-live-e2e-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: tempRoot.appendingPathComponent("Library"),
                withIntermediateDirectories: true
            )
            let worker = WallpaperStoreWorker(
                libraryURL: tempRoot.appendingPathComponent("Library", isDirectory: true)
            )

            switch plan {
            case .video(let source, let title):
                print("STEAM_LIVE_PLAN video title=\(title) source=\(source.lastPathComponent)")
                let result = try await worker.importItems(
                    at: [source], entryURL: nil, storageMode: .managedCopy
                )
                print("STEAM_LIVE_IMPORT ids=\(result.importedIDs.count) failures=\(result.failures)")
                guard let id = result.importedIDs.first else {
                    FileHandle.standardError.write(Data("STEAM_LIVE_IMPORT_EMPTY\n".utf8))
                    exit(1)
                }
                let items = try await worker.snapshot().items
                let item = items.first { $0.id == id }
                print("STEAM_LIVE_ITEM name=\(item?.name ?? "?") type=\(item?.type.rawValue ?? "?")")
                let exists = item.map { FileManager.default.fileExists(atPath: $0.sourceURL.path) } ?? false
                print("STEAM_LIVE_ASSET_EXISTS \(exists)")
                guard exists else {
                    FileHandle.standardError.write(Data("STEAM_LIVE_ASSET_MISSING\n".utf8))
                    exit(1)
                }
            case .webProject(let dir, let entry, let title):
                print("STEAM_LIVE_PLAN web title=\(title) entry=\(entry)")
                let entryURL = WorkshopImportPlanner.resolveEntry(entry, in: dir)
                let result = try await worker.importItems(
                    at: [dir], entryURL: entryURL, storageMode: .managedCopy
                )
                print("STEAM_LIVE_IMPORT ids=\(result.importedIDs.count) failures=\(result.failures)")
                guard result.importedIDs.first != nil else {
                    FileHandle.standardError.write(Data("STEAM_LIVE_IMPORT_EMPTY\n".utf8))
                    exit(1)
                }
            case .unsupported(let reason):
                print("STEAM_LIVE_UNSUPPORTED \(reason.userMessage)")
                print("STEAM_LIVE_DOWNLOAD_FAILED_UNSUPPORTED")
                exit(1)
            }
            fflush(stdout)
            try? FileManager.default.removeItem(at: context.stagingDirectory.appendingPathComponent(itemID))
            try? FileManager.default.removeItem(at: tempRoot)
            print("STEAM_LIVE_DOWNLOAD_PASSED")
            exit(0)
        } catch let error as SteamCMDFailure {
            FileHandle.standardError.write(Data("STEAM_LIVE_FAILURE \(error.userMessage)\n".utf8))
            exit(1)
        } catch {
            FileHandle.standardError.write(Data("STEAM_LIVE_ERROR \(error)\n".utf8))
            exit(1)
        }
    }
    semaphore.wait()
    exit(0)
}

var failures = 0
for (name, test) in tests {
    do {
        try test()
        print("PASS: \(name)")
    } catch {
        failures += 1
        print("FAIL: \(name)\n\(error)")
    }
}

if failures > 0 {
    print("\n\(failures) test(s) failed")
    exit(1)
}
print("\nAll \(tests.count) tests passed")

func testPlaybackQueueDeduplicatesAndAutoSorts() throws {
    let first = UUID()
    let second = UUID()
    let queue = PlaybackQueue(name: "工作", wallpaperIDs: [first, second, first])
    try expect(queue.wallpaperIDs, equals: [first, second], "queue should deduplicate wallpaper IDs")

    var sorted = queue
    sorted.setSortMode(.name)
    try expect(sorted.sortMode, equals: .name, "queue should support automatic name sorting")
    sorted.moveWallpaper(from: 0, to: 1)
    try expect(sorted.sortMode, equals: .custom, "manual drag should switch to custom sorting")
}

func testPlaybackQueueHasDefaultConstraintsAndPerItemOverrides() throws {

    let queue = PlaybackQueue(name: "默认队列", isDefault: true, defaultIntervalSeconds: .infinity)
    try expect(queue.name, equals: "默认队列", "default queue name should be fixed")
    try expect(queue.defaultIntervalSeconds, equals: 30, "invalid interval should use the default")

    let itemID = UUID()
    var updated = queue
    updated.setIntervalOverride(12, for: itemID)
    try expect(updated.intervalOverride(for: itemID), equals: Optional(12), "queue should store item interval overrides")
}

func testPlaybackQueueAdvanceModeRoundTrips() throws {
    let queue = PlaybackQueue(name: "视频队列", advanceMode: .videoCompletion)
    let data = try JSONEncoder().encode(queue)
    let decoded = try JSONDecoder().decode(PlaybackQueue.self, from: data)
    try expect(decoded.advanceMode, equals: .videoCompletion, "queue should persist its advance mode")
    try expect(decoded.advanceAfterVideoCompletion, "legacy flag should mirror the completion mode")
}

func testLegacyPlaybackQueueAdvanceBooleanDecodes() throws {
    // Pre-0.2.7 queues only stored the boolean.
    let queue = PlaybackQueue(name: "旧队列", advanceMode: .videoCompletion)
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(queue)) as! [String: Any]
    object.removeValue(forKey: "advanceMode")
    let data = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(PlaybackQueue.self, from: data)
    try expect(decoded.advanceMode, equals: .videoCompletion, "legacy true should map to completion mode")
}

func testLegacyPlaybackQueueWithoutAdvanceSettingDecodes() throws {
    let queue = PlaybackQueue(name: "旧队列")
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(queue)) as! [String: Any]
    object.removeValue(forKey: "advanceMode")
    object.removeValue(forKey: "advanceAfterVideoCompletion")
    let data = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(PlaybackQueue.self, from: data)
    try expect(decoded.advanceMode, equals: .fixedInterval, "legacy queues should default to timer-based switching")
}

func testNonVideoItemsFallBackToFixedIntervalInCompletionMode() throws {
    let completion = PlaybackQueue(name: "按视频结束", advanceMode: .videoCompletion)
    try expect(completion.usesCompletionAdvance(for: .video), "completion mode should wait for videos to end")
    try expect(!completion.usesCompletionAdvance(for: .image), "images must fall back to the fixed interval")
    try expect(!completion.usesCompletionAdvance(for: .web), "web wallpapers must fall back to the fixed interval")

    let fixed = PlaybackQueue(name: "按时长", advanceMode: .fixedInterval)
    for type in WallpaperType.allCases {
        try expect(!fixed.usesCompletionAdvance(for: type), "fixed mode should never wait for completion")
    }
}

func testWallpaperLibraryPaginationUsesSamePageContractForGroups() throws {
    let items = Array(1...101)
    try expect(WallpaperLibraryPagination.defaultPageSize, equals: 20, "library and group pages should share a 20-item default page size")
    try expect(WallpaperLibraryPagination.pageCount(totalCount: items.count), equals: 6, "101 items should create six real pages")
    try expect(WallpaperLibraryPagination.page(from: items, pageNumber: 1), equals: Array(1...20), "first page should contain only its first 20 items")
    try expect(WallpaperLibraryPagination.page(from: items, pageNumber: 2), equals: Array(21...40), "second page should not retain first-page items")
    try expect(WallpaperLibraryPagination.page(from: items, pageNumber: 6), equals: [101], "last page should contain only the remaining items")
    try expect(WallpaperLibraryPagination.normalizedPage(7, totalCount: items.count), equals: 6, "page selection should clamp to the final page")
    try expect(WallpaperLibraryPagination.normalizedPage(4, totalCount: 20), equals: 1, "deleting items should clamp the current page")
}

func testWallpaperLibraryGridPageSizeFitsViewportWithoutResizingTiles() throws {
    let baseline = WallpaperLibraryPageLayout.grid(availableWidth: 880, availableHeight: 700)
    try expect(baseline.columns, equals: 4, "880pt should fit four fixed 190pt tiles")
    try expect(baseline.tileWidth, equals: 190, "tile width should stay at the fixed card width")
    try expect(baseline.rows, equals: 3, "700pt should fit three grid rows")
    try expect(baseline.pageSize, equals: 12, "grid page should hold columns times rows")
    try expect(baseline.horizontalSpacing, equals: 24, "leftover width should become equal column spacing")

    let shorter = WallpaperLibraryPageLayout.grid(availableWidth: 880, availableHeight: 500)
    let taller = WallpaperLibraryPageLayout.grid(availableWidth: 880, availableHeight: 1000)
    try expect(shorter.tileWidth, equals: baseline.tileWidth, "a shorter viewport must not resize tiles")
    try expect(taller.tileWidth, equals: baseline.tileWidth, "a taller viewport must not resize tiles")
    try expect(shorter.pageSize, equals: 8, "a shorter viewport should hold fewer rows")
    try expect(taller.pageSize, equals: 20, "a taller viewport should hold more rows")

    let wider = WallpaperLibraryPageLayout.grid(availableWidth: 1200, availableHeight: 900)
    try expect(wider.tileWidth, equals: baseline.tileWidth, "a wider viewport must not resize tiles")
    try expect(wider.columns, equals: 5, "a wider viewport should add a column")
    try expect(wider.pageSize, equals: 20, "a wider and taller viewport should hold more wallpapers")
    try expect(wider.pageSize > baseline.pageSize, "page capacity should grow with the viewport")
}

func testWallpaperLibraryListPageSizeTracksViewportHeight() throws {
    try expect(WallpaperLibraryPageLayout.listPageSize(availableHeight: 700), equals: 8, "700pt should fit eight 76pt rows after padding")
    try expect(WallpaperLibraryPageLayout.listPageSize(availableHeight: 900), equals: 11, "a taller viewport should fit more list rows")
    let tall = WallpaperLibraryPageLayout.listPageSize(availableHeight: 2000)
    try expect(tall > 11, "list capacity should keep growing with the viewport")
}

func testWallpaperLibraryPageLayoutClampsTinyViewports() throws {
    try expect(WallpaperLibraryPageLayout.grid(availableWidth: 0, availableHeight: 0).pageSize, equals: 1, "an empty viewport should still expose one page slot")
    try expect(WallpaperLibraryPageLayout.grid(availableWidth: 100, availableHeight: 100).pageSize, equals: 1, "a tiny viewport should expose one page slot")
    try expect(WallpaperLibraryPageLayout.listPageSize(availableHeight: 0), equals: 1, "an empty list viewport should still expose one page slot")
}

func testDisplayBindingInvalidatesEditedQueue() throws {
    let queue = PlaybackQueue(name: "夜间")
    let state = DisplayQueueState(queueID: queue.id, currentIndex: 3, isPlaying: true, isEnabled: true)
    var binding = DisplayPlaybackBinding(
        displayID: "display-1",
        displayName: "内置显示器",
        activeQueueID: queue.id,
        queueStates: [queue.id: state]
    )
    try expect(binding.invalidateBoundQueue(ifMatching: queue.id), "editing the active queue should invalidate the display binding")
    try expect(!binding.state(for: queue.id).isEnabled, "invalidated queue should require the user to apply it again")
    try expect(!binding.state(for: queue.id).isPlaying, "invalidated queue should stop automatic switching")
    try expect(binding.state(for: queue.id).currentIndex, equals: 3, "queue edit should preserve the last index for reapplication")
    try expect(!binding.invalidateBoundQueue(ifMatching: UUID()), "editing another queue should not affect this display")
}

func testWallpaperPreviewUsesLandscapeSixteenByNineLayout() throws {
    try expect(WallpaperPreviewLayout.aspectRatio, equals: 16.0 / 9.0, "resource previews should use a 16:9 frame")
    try expect(WallpaperPreviewLayout.contentMode, equals: .fit, "portrait resources should be fully visible inside the landscape frame")
    try expect(WallpaperPreviewLayout.height(forWidth: 320), equals: 180, "preview frame height should be derived from its width")
    try expect(WallpaperPreviewLayout.height(forWidth: 0), equals: 0, "preview frame should not produce a negative height")
}

func testStoreMigratesLegacyDisplayQueues() throws {
    let fixture = try Fixture()
    let wallpaperID = UUID()
    let legacy = DisplayPlaybackQueue(
        displayID: "display-1",
        displayName: "内置显示器",
        wallpaperIDs: [wallpaperID],
        intervalSeconds: 45,
        transition: .zoom,
        isEnabled: true,
        currentIndex: 0
    )
    try FileManager.default.createDirectory(at: fixture.library, withIntermediateDirectories: true)
    let data = try JSONEncoder().encode([legacy])
    try data.write(to: fixture.library.appendingPathComponent("display-queues.json"))

    let queues = try fixture.store.playbackQueues()
    let bindings = try fixture.store.displayPlaybackBindings()
    try expect(queues.count, equals: 2, "migration should create default and legacy queues")
    try expect(bindings.count, equals: 1, "migration should create one display binding")
    guard let binding = bindings.first, let migratedQueue = queues.first(where: { !$0.isDefault }) else {
        throw TestFailure(message: "migration should provide a named queue and binding")
    }
    try expect(binding.activeQueueID, equals: migratedQueue.id, "display should bind to its migrated queue")
    try expect(migratedQueue.wallpaperIDs, equals: [wallpaperID], "migration should preserve wallpaper IDs")
    try expect(migratedQueue.defaultIntervalSeconds, equals: 45, "migration should preserve interval")
    try expect(migratedQueue.transition, equals: .zoom, "migration should preserve transition")
    try expect(FileManager.default.fileExists(atPath: fixture.library.appendingPathComponent("playback-queues.json").path), "migration should persist new queue file")
}

func testQueueStoreRoundTripsDisplayQueueState() throws {
    let fixture = try Fixture()
    let queue = PlaybackQueue(name: "夜间", wallpaperIDs: [UUID()], completionBehavior: .stopAfterOneCycle)
    let state = DisplayQueueState(queueID: queue.id, currentIndex: 2, isPlaying: true, isEnabled: true, overrides: QueuePlaybackOverrides(intervalSeconds: 8))
    let binding = DisplayPlaybackBinding(displayID: "display-2", displayName: "外接显示器", activeQueueID: queue.id, queueStates: [queue.id: state])
    try fixture.store.save(playbackQueues: [PlaybackQueue.defaultQueue, queue])
    try fixture.store.save(displayPlaybackBindings: [binding])

    let reloaded = WallpaperStore(libraryURL: fixture.library)
    let loadedQueues = try reloaded.playbackQueues()
    try expect(loadedQueues.map(\.id), equals: [PlaybackQueue.defaultQueue.id, queue.id], "queue IDs should round trip")
    try expect(loadedQueues.last?.completionBehavior, equals: queue.completionBehavior, "queue rules should round trip")
    let loadedBindings = try reloaded.displayPlaybackBindings()
    try expect(loadedBindings.first?.activeQueueID, equals: binding.activeQueueID, "display active queue should round trip")
    try expect(loadedBindings.first?.state(for: queue.id).currentIndex, equals: 2, "display queue index should round trip")
    try expect(loadedBindings.first?.state(for: queue.id).overrides.intervalSeconds, equals: Optional(8), "display override should round trip")
}

func testApplicationVersionInfoFormatting() throws {
    let release = ApplicationVersionInfo(
        infoDictionary: [
            "CFBundleShortVersionString": "0.2.5",
            "CFBundleVersion": "0.2.5"
        ],
        fallbackVersion: "0.2.5"
    )
    try expect(release.version, equals: "0.2.5", "bundle version should be preferred")
    try expect(release.displayText, equals: "版本 0.2.5", "matching build number should not be repeated")

    let numberedBuild = ApplicationVersionInfo(
        infoDictionary: [
            "CFBundleShortVersionString": "0.2.5",
            "CFBundleVersion": "42"
        ],
        fallbackVersion: "0.2.5"
    )
    try expect(numberedBuild.displayText, equals: "版本 0.2.5（构建 42）", "distinct build number should be displayed")

    let development = ApplicationVersionInfo(infoDictionary: [:], fallbackVersion: "0.2.5")
    try expect(development.displayText, equals: "版本 0.2.5", "development builds should use the fallback version")
}

func testPlaybackQueueStallWatchdogInterval() throws {
    let queue = PlaybackQueue(name: "夜间", defaultIntervalSeconds: 30)

    try expect(
        queue.stallWatchdogInterval(forVideoWithDurationSeconds: 10),
        equals: 30,
        "short videos should keep a minimum watchdog so a hang still recovers quickly"
    )
    try expect(
        queue.stallWatchdogInterval(forVideoWithDurationSeconds: 120),
        equals: 144,
        "long videos should use duration plus a 20% grace window"
    )
    try expect(
        queue.stallWatchdogInterval(forVideoWithDurationSeconds: nil),
        equals: PlaybackQueue.unknownDurationStallWindowSeconds,
        "unknown duration uses the stall window; the frame heartbeat covers healthy long videos"
    )
    try expect(
        queue.stallWatchdogInterval(forVideoWithDurationSeconds: .nan),
        equals: PlaybackQueue.unknownDurationStallWindowSeconds,
        "invalid duration should fall back to the stall window"
    )
    try expect(
        queue.hardDeadlineInterval,
        equals: 14_400,
        "video-completion queues have a 4h absolute ceiling the heartbeat cannot extend"
    )
}

// MARK: - Update checker (M1)

func makeReleaseJSON(
    tag: String = "v0.2.6",
    body: String = "notes",
    htmlURL: String? = "https://github.com/MrLLLLLLLLLL/WallpaperMac/releases/tag/v0.2.6",
    publishedAt: String? = "2026-10-28T10:00:00Z",
    assets: [[String: Any]] = [
        [
            "name": "WallpaperMac-v0.2.6-macOS.zip",
            "browser_download_url": "https://example.com/WallpaperMac-v0.2.6-macOS.zip"
        ],
        [
            "name": "WallpaperMac-v0.2.6-SHA256SUMS.txt",
            "browser_download_url": "https://example.com/WallpaperMac-v0.2.6-SHA256SUMS.txt"
        ]
    ]
) -> Data {
    var payload: [String: Any] = [
        "tag_name": tag,
        "body": body
    ]
    if let htmlURL { payload["html_url"] = htmlURL }
    if let publishedAt { payload["published_at"] = publishedAt }
    payload["assets"] = assets
    // swiftlint:disable:next force_try
    return try! JSONSerialization.data(withJSONObject: payload)
}

func testSemVerParsingAndComparison() throws {
    try expect(SemVer(string: "0.2.5"), equals: SemVer(major: 0, minor: 2, patch: 5), "plain version should parse")
    try expect(SemVer(string: "v0.2.5"), equals: SemVer(major: 0, minor: 2, patch: 5), "v prefix should be ignored")
    try expect(SemVer(string: "V1.2.3"), equals: SemVer(major: 1, minor: 2, patch: 3), "uppercase V prefix should be ignored")
    try expect(SemVer(string: "1.0"), equals: SemVer(major: 1, minor: 0, patch: 0), "two components should pad patch")
    try expect(SemVer(string: "2"), equals: SemVer(major: 2, minor: 0, patch: 0), "one component should pad minor and patch")
    try expect(SemVer(string: "  0.2.5  "), equals: SemVer(major: 0, minor: 2, patch: 5), "whitespace should be trimmed")

    try expect(SemVer(string: "") == nil, "empty string should not parse")
    try expect(SemVer(string: "v") == nil, "bare prefix should not parse")
    try expect(SemVer(string: "abc") == nil, "letters should not parse")
    try expect(SemVer(string: "0.2.5.1") == nil, "four components should not parse")
    try expect(SemVer(string: "0.2.5-beta") == nil, "prerelease suffix should not parse")
    try expect(SemVer(string: "1.-1.0") == nil, "negative components should not parse")
    try expect(SemVer(string: "0..5") == nil, "empty components should not parse")

    try expect(SemVer(major: 0, minor: 2, patch: 5) < SemVer(major: 0, minor: 2, patch: 6), "patch should order")
    try expect(SemVer(major: 0, minor: 2, patch: 9) < SemVer(major: 0, minor: 3, patch: 0), "minor should order before patch")
    try expect(SemVer(major: 0, minor: 9, patch: 9) < SemVer(major: 1, minor: 0, patch: 0), "major should order first")
    try expect(SemVer(major: 1, minor: 0, patch: 0) == SemVer(major: 1, minor: 0, patch: 0), "equal versions should compare equal")
    try expect(SemVer(string: "0.2.5")! < SemVer(string: "0.2.6")!, "parsed versions should compare")
    try expect(SemVer(major: 1, minor: 2, patch: 3).description, equals: "1.2.3", "description should normalize")
}

func testUpdateCheckerParsesNewerRelease() throws {
    let data = makeReleaseJSON()
    let result = try UpdateChecker.parseLatestRelease(data: data, currentVersion: "0.2.5")
    guard case .updateAvailable(let update) = result else {
        throw TestFailure(message: "expected update available, got \(result)")
    }
    try expect(update.version, equals: "0.2.6", "remote version should be normalized without v prefix")
    try expect(update.releaseNotes, equals: "notes", "release notes should pass through")
    try expect(update.zipURL.absoluteString, equals: "https://example.com/WallpaperMac-v0.2.6-macOS.zip", "zip asset should resolve")
    try expect(update.checksumsURL?.absoluteString, equals: "https://example.com/WallpaperMac-v0.2.6-SHA256SUMS.txt", "checksum asset should resolve")
    try expect(update.releasePageURL.absoluteString, equals: "https://github.com/MrLLLLLLLLLL/WallpaperMac/releases/tag/v0.2.6", "release page should resolve")
    try expect(update.publishedAt != nil, "published date should parse")
}

func testUpdateCheckerReportsUpToDate() throws {
    let same = try UpdateChecker.parseLatestRelease(data: makeReleaseJSON(tag: "v0.2.5"), currentVersion: "0.2.5")
    guard case .upToDate(let version) = same else {
        throw TestFailure(message: "same version should be up to date, got \(same)")
    }
    try expect(version, equals: "0.2.5", "up-to-date should report the running version")

    let older = try UpdateChecker.parseLatestRelease(data: makeReleaseJSON(tag: "v0.2.4"), currentVersion: "0.2.5")
    guard case .upToDate = older else {
        throw TestFailure(message: "older remote must not offer a downgrade, got \(older)")
    }
}

func testUpdateCheckerRejectsMalformedPayloads() throws {
    do {
        _ = try UpdateChecker.parseLatestRelease(data: Data("not json".utf8), currentVersion: "0.2.5")
        throw TestFailure(message: "invalid JSON should throw")
    } catch let error as UpdateCheckError {
        try expect(error, equals: .invalidResponse, "invalid JSON should map to invalidResponse")
    }

    do {
        _ = try UpdateChecker.parseLatestRelease(data: makeReleaseJSON(), currentVersion: "not-a-version")
        throw TestFailure(message: "invalid current version should throw")
    } catch let error as UpdateCheckError {
        try expect(error, equals: .invalidCurrentVersion("not-a-version"), "bad current version should be named")
    }

    do {
        _ = try UpdateChecker.parseLatestRelease(data: makeReleaseJSON(tag: "vNext"), currentVersion: "0.2.5")
        throw TestFailure(message: "invalid remote tag should throw")
    } catch let error as UpdateCheckError {
        try expect(error, equals: .invalidReleaseVersion("vNext"), "bad remote tag should be named")
    }

    let noAssets = makeReleaseJSON(assets: [])
    do {
        _ = try UpdateChecker.parseLatestRelease(data: noAssets, currentVersion: "0.2.5")
        throw TestFailure(message: "missing zip asset should throw")
    } catch let error as UpdateCheckError {
        try expect(error, equals: .missingAsset("WallpaperMac-v0.2.6-macOS.zip"), "missing zip should be named with the target version")
    }
}

func testUpdateCheckerAllowsMissingChecksumsAsset() throws {
    let data = makeReleaseJSON(assets: [
        [
            "name": "WallpaperMac-v0.2.6-macOS.zip",
            "browser_download_url": "https://example.com/WallpaperMac-v0.2.6-macOS.zip"
        ]
    ])
    let result = try UpdateChecker.parseLatestRelease(data: data, currentVersion: "0.2.5")
    guard case .updateAvailable(let update) = result else {
        throw TestFailure(message: "zip without checksums should still update-check, got \(result)")
    }
    try expect(update.checksumsURL == nil, "checksums URL should stay optional until install time")
}

func testUpdateCheckerAssetNameMatching() throws {
    try expect(UpdateChecker.isZipAssetName("WallpaperMac-v0.2.6-macOS.zip"), "release zip name should match")
    try expect(!UpdateChecker.isZipAssetName("WallpaperMac-v0.2.6-macOS.dmg"), "dmg is not the install zip")
    try expect(!UpdateChecker.isZipAssetName("Other-v1.0.0-macOS.zip"), "foreign packages should not match")
    try expect(!UpdateChecker.isZipAssetName(nil), "nil asset name should not match")

    try expect(UpdateChecker.isChecksumsAssetName("WallpaperMac-v0.2.6-SHA256SUMS.txt"), "checksums name should match")
    try expect(!UpdateChecker.isChecksumsAssetName("WallpaperMac-v0.2.6-macOS.zip"), "zip is not checksums")
    try expect(!UpdateChecker.isChecksumsAssetName(nil), "nil checksums name should not match")
}

func testUpdateCheckerAcceptsLiveReleasePayloadShape() throws {
    // Captured from api.github.com/releases/latest on 2026-10-27. Guards the
    // parser against real GitHub field drift instead of only our own fixtures.
    let livePayload = Data("""
    {
      "tag_name": "v0.2.5",
      "body": "# WallpaperMac 0.2.5\\n\\nWallpaperMac 0.2.5 release notes.",
      "html_url": "https://github.com/MrLLLLLLLLLL/WallpaperMac/releases/tag/v0.2.5",
      "published_at": "2026-10-26T21:14:37Z",
      "assets": [
        {
          "name": "WallpaperMac-v0.2.5-macOS.dmg",
          "browser_download_url": "https://github.com/MrLLLLLLLLLL/WallpaperMac/releases/download/v0.2.5/WallpaperMac-v0.2.5-macOS.dmg"
        },
        {
          "name": "WallpaperMac-v0.2.5-macOS.zip",
          "browser_download_url": "https://github.com/MrLLLLLLLLLL/WallpaperMac/releases/download/v0.2.5/WallpaperMac-v0.2.5-macOS.zip"
        },
        {
          "name": "WallpaperMac-v0.2.5-SHA256SUMS.txt",
          "browser_download_url": "https://github.com/MrLLLLLLLLLL/WallpaperMac/releases/download/v0.2.5/WallpaperMac-v0.2.5-SHA256SUMS.txt"
        }
      ]
    }
    """.utf8)

    let current = try UpdateChecker.parseLatestRelease(data: livePayload, currentVersion: "0.2.5")
    guard case .upToDate = current else {
        throw TestFailure(message: "live v0.2.5 payload should be up to date for 0.2.5, got \(current)")
    }

    let older = try UpdateChecker.parseLatestRelease(data: livePayload, currentVersion: "0.2.4")
    guard case .updateAvailable(let update) = older else {
        throw TestFailure(message: "live payload should offer an update to 0.2.4, got \(older)")
    }
    try expect(update.version, equals: "0.2.5", "live tag should normalize to the release version")
    try expect(
        update.zipURL.absoluteString,
        equals: "https://github.com/MrLLLLLLLLLL/WallpaperMac/releases/download/v0.2.5/WallpaperMac-v0.2.5-macOS.zip",
        "live zip asset URL should resolve"
    )
    try expect(
        update.checksumsURL?.absoluteString,
        equals: "https://github.com/MrLLLLLLLLLL/WallpaperMac/releases/download/v0.2.5/WallpaperMac-v0.2.5-SHA256SUMS.txt",
        "live checksum asset URL should resolve"
    )
    try expect(
        update.releasePageURL.absoluteString,
        equals: "https://github.com/MrLLLLLLLLLL/WallpaperMac/releases/tag/v0.2.5",
        "live release page URL should resolve"
    )
}

// MARK: - Update artifact verification (M2)

func testUpdateChecksumsParsing() throws {
    let sums = Data("""
    e45a4da60a94e99634008f7236f742d81d51309aa13bdac3ea582b02ec29e93e  dist/WallpaperMac-v0.2.5-macOS.zip
    ae85dba7bd5769cf3c5a9ecb2cc11488e585c2b3de0e9e5404c1decf5ad801a7  dist/WallpaperMac-v0.2.5-macOS.dmg
    1454089e49cf96af1490df65da7f245d7adb29df4cf81db473be8449c9ee1243 *WallpaperMac-v0.2.5-macOS.zip
    """.utf8)

    let parsed = UpdateArtifactVerifier.checksums(from: sums)
    try expect(parsed.count, equals: 2, "basename keys should collapse dist/ and bare forms")
    try expect(
        parsed["WallpaperMac-v0.2.5-macOS.zip"],
        equals: "1454089e49cf96af1490df65da7f245d7adb29df4cf81db473be8449c9ee1243",
        "binary-mode star entries should parse and later entries win"
    )
    try expect(
        parsed["WallpaperMac-v0.2.5-macOS.dmg"],
        equals: "ae85dba7bd5769cf3c5a9ecb2cc11488e585c2b3de0e9e5404c1decf5ad801a7",
        "plain two-space entries should parse"
    )
}

func testUpdateChecksumsParsingIgnoresGarbage() throws {
    let sums = Data("""
    not-a-hash  file.zip
    e45a4da60a94e99634008f7236f742d81d51309aa13bdac3ea582b02ec29e93e
    e45a4da60a94e99634008f7236f742d81d51309aa13bdac3ea582b02ec29e93  short.zip
    e45a4da60a94e99634008f7236f742d81d51309aa13bdac3ea582b02ec29e93g  badhex.zip

    e45a4da60a94e99634008f7236f742d81d51309aa13bdac3ea582b02ec29e93e  good.zip
    """.utf8)

    let parsed = UpdateArtifactVerifier.checksums(from: sums)
    try expect(parsed.count, equals: 1, "only well-formed 64-hex rows should survive")
    try expect(parsed["good.zip"] != nil, "valid rows after garbage should still parse")
}

func testUpdateChecksumLookupByAssetName() throws {
    let sums = Data("""
    e45a4da60a94e99634008f7236f742d81d51309aa13bdac3ea582b02ec29e93e  dist/WallpaperMac-v0.2.5-macOS.zip
    """.utf8)

    try expect(
        UpdateArtifactVerifier.expectedChecksum(forAssetNamed: "WallpaperMac-v0.2.5-macOS.zip", inChecksumsFile: sums),
        equals: "e45a4da60a94e99634008f7236f742d81d51309aa13bdac3ea582b02ec29e93e",
        "asset basename should resolve against dist/-prefixed rows"
    )
    try expect(
        UpdateArtifactVerifier.expectedChecksum(forAssetNamed: "WallpaperMac-v0.2.6-macOS.zip", inChecksumsFile: sums) == nil,
        "unknown assets should return nil"
    )
}

func testUpdateSHA256OfDataMatchesKnownVector() throws {
    // sha256("abc") from FIPS 180-2.
    try expect(
        UpdateArtifactVerifier.sha256Hex(ofData: Data("abc".utf8)),
        equals: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        "data digest should match the published test vector"
    )
    try expect(
        UpdateArtifactVerifier.sha256Hex(ofData: Data()),
        equals: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "empty input should match the empty digest"
    )
}

func testUpdateFileVerificationDetectsTampering() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WallpaperMacUpdateVerifierTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let artifact = root.appendingPathComponent("WallpaperMac-v0.2.6-macOS.zip")
    let goodBytes = Data("verified-payload".utf8)
    try goodBytes.write(to: artifact)

    let expected = UpdateArtifactVerifier.sha256Hex(ofData: goodBytes)
    let intact = try UpdateArtifactVerifier.verify(fileAt: artifact, expectedHash: expected)
    try expect(intact, "untouched artifact should verify")

    let caseInsensitive = try UpdateArtifactVerifier.verify(fileAt: artifact, expectedHash: expected.uppercased())
    try expect(caseInsensitive, "hash comparison should ignore case")

    try Data("tampered-payload".utf8).write(to: artifact)
    let tampered = try UpdateArtifactVerifier.verify(fileAt: artifact, expectedHash: expected)
    try expect(tampered == false, "modified artifact must fail verification")
}

func testUpdateFileVerificationReadsLargeArtifactsInChunks() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WallpaperMacUpdateChunkTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    // 3 MiB forces the streaming path to loop instead of one-shot hashing.
    let artifact = root.appendingPathComponent("large.zip")
    var payload = Data()
    payload.reserveCapacity(3 * 1024 * 1024)
    for index in 0..<(3 * 1024 * 1024) {
        payload.append(UInt8(truncatingIfNeeded: index))
    }
    try payload.write(to: artifact)

    let fileHash = try UpdateArtifactVerifier.sha256Hex(ofFileAt: artifact)
    let memoryHash = UpdateArtifactVerifier.sha256Hex(ofData: payload)
    try expect(fileHash, equals: memoryHash, "streaming hash must match one-shot hash for multi-megabyte input")
}

// MARK: - Update download transport (resume + stalls)

final class AsyncTestResult: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?

    func record(_ error: Error?) {
        lock.lock()
        self.error = error
        lock.unlock()
    }

    func recordedError() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return error
    }
}

/// Bridges an async test body into the synchronous test runner. The URLSession
/// delegate and stall timer run on their own queues, so blocking the main
/// thread here cannot starve them.
func runAsyncTest(_ body: @escaping () async throws -> Void) throws {
    let semaphore = DispatchSemaphore(value: 0)
    let result = AsyncTestResult()
    Task {
        do {
            try await body()
            result.record(nil)
        } catch {
            result.record(error)
        }
        semaphore.signal()
    }
    semaphore.wait()
    if let error = result.recordedError() {
        throw error
    }
}

/// In-process HTTP stand-in. Serves a release zip (with Range support), the
/// checksum manifest and the signature, and can go silent mid-transfer so the
/// downloader's stall watchdog has to cancel and resume it.
final class UpdateDownloadMockURLProtocol: URLProtocol {
    struct Stub {
        var statusCode: Int
        var headers: [String: String]
        var body: Data
        /// When set, send this many bytes and then stop writing. The task
        /// stays active until the downloader cancels it.
        var stallAfter: Int?
        /// When set, deliver the body in chunks instead of one burst so the
        /// progress rate can be sampled.
        var chunkSize: Int? = nil
        var chunkDelay: TimeInterval = 0.08
    }

    struct RecordedRequest {
        let path: String
        let range: String?
    }

    private static let stateLock = NSLock()
    private static var stubProvider: ((URLRequest) -> Stub)?
    private static var recorded: [RecordedRequest] = []

    static func install(_ provider: @escaping (URLRequest) -> Stub) {
        stateLock.lock()
        stubProvider = provider
        recorded = []
        stateLock.unlock()
    }

    static func requests() -> [RecordedRequest] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return recorded
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.stateLock.lock()
        Self.recorded.append(
            RecordedRequest(
                path: request.url?.path ?? "",
                range: request.value(forHTTPHeaderField: "Range")
            )
        )
        let provider = Self.stubProvider
        Self.stateLock.unlock()

        guard let provider, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let stub = provider(request)
        guard let http = HTTPURLResponse(
            url: url,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)

        if let stallAfter = stub.stallAfter {
            client?.urlProtocol(self, didLoad: Data(stub.body.prefix(stallAfter)))
            // Deliberately never finish: this is a stalled weak-network
            // transfer, not a complete response.
            return
        }
        if let chunkSize = stub.chunkSize, chunkSize > 0, stub.body.count > chunkSize {
            startChunkedDelivery(body: stub.body, chunkSize: chunkSize, delay: stub.chunkDelay)
            return
        }
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private let chunkLock = NSLock()
    private var chunkTimer: DispatchSourceTimer?
    private var chunkBody = Data()
    private var chunkOffset = 0
    private var configuredChunkSize = 0

    private func startChunkedDelivery(body: Data, chunkSize: Int, delay: TimeInterval) {
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "wallpapermac.update-download-mock.chunks")
        )
        chunkLock.lock()
        chunkBody = body
        chunkOffset = 0
        configuredChunkSize = chunkSize
        chunkTimer = timer
        chunkLock.unlock()
        timer.schedule(deadline: .now() + delay, repeating: delay)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.deliverNextChunk(timer: timer)
        }
        timer.resume()
    }

    private func deliverNextChunk(timer: DispatchSourceTimer) {
        chunkLock.lock()
        guard chunkOffset < chunkBody.count else {
            chunkOffset = 0
            chunkLock.unlock()
            timer.cancel()
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let end = min(chunkOffset + configuredChunkSize, chunkBody.count)
        let chunk = Data(chunkBody[chunkOffset..<end])
        chunkOffset = end
        chunkLock.unlock()
        client?.urlProtocol(self, didLoad: chunk)
    }

    override func stopLoading() {
        chunkLock.lock()
        let timer = chunkTimer
        chunkTimer = nil
        chunkLock.unlock()
        timer?.cancel()
    }
}

final class UpdateDownloadMockServer {
    let zip: Data
    let zipName: String
    let checksums: Data
    let signature: Data
    let stallFirstZipAfter: Int?
    let stallEveryZip: Bool

    private let lock = NSLock()
    private var zipRequestCount = 0
    private let baseURL = URL(string: "https://update.test")!

    init(
        zip: Data,
        zipName: String,
        checksums: Data,
        signature: Data,
        stallFirstZipAfter: Int?,
        stallEveryZip: Bool
    ) {
        self.zip = zip
        self.zipName = zipName
        self.checksums = checksums
        self.signature = signature
        self.stallFirstZipAfter = stallFirstZipAfter
        self.stallEveryZip = stallEveryZip
    }

    var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateDownloadMockURLProtocol.self]
        return configuration
    }

    func makeSession() -> URLSession {
        URLSession(configuration: configuration)
    }

    func install() {
        UpdateDownloadMockURLProtocol.install { [weak self] request in
            guard let self else {
                return UpdateDownloadMockURLProtocol.Stub(
                    statusCode: 500,
                    headers: [:],
                    body: Data(),
                    stallAfter: nil
                )
            }
            let path = request.url?.path ?? ""
            if path.hasSuffix("SHA256SUMS.txt") {
                return UpdateDownloadMockURLProtocol.Stub(
                    statusCode: 200,
                    headers: ["Content-Length": "\(checksums.count)"],
                    body: checksums,
                    stallAfter: nil
                )
            }
            if path.hasSuffix(".sig") {
                return UpdateDownloadMockURLProtocol.Stub(
                    statusCode: 200,
                    headers: ["Content-Length": "\(signature.count)"],
                    body: signature,
                    stallAfter: nil
                )
            }
            if path.hasSuffix(zipName) {
                return zipResponse(for: request)
            }
            return UpdateDownloadMockURLProtocol.Stub(
                statusCode: 404,
                headers: [:],
                body: Data(),
                stallAfter: nil
            )
        }
    }

    private func zipResponse(for request: URLRequest) -> UpdateDownloadMockURLProtocol.Stub {
        lock.lock()
        let attempt = zipRequestCount
        zipRequestCount += 1
        lock.unlock()

        if let range = request.value(forHTTPHeaderField: "Range"),
           let start = Self.rangeStart(range),
           start > 0,
           start < zip.count {
            let payload = Data(zip[start...])
            return UpdateDownloadMockURLProtocol.Stub(
                statusCode: 206,
                headers: [
                    "Content-Length": "\(payload.count)",
                    "Content-Range": "bytes \(start)-\(zip.count - 1)/\(zip.count)",
                    "ETag": "\"v1\"",
                    "Accept-Ranges": "bytes"
                ],
                body: payload,
                stallAfter: nil,
                chunkSize: max(1, payload.count / 4)
            )
        }

        let stallAfter = (stallEveryZip || attempt == 0) ? stallFirstZipAfter : nil
        return UpdateDownloadMockURLProtocol.Stub(
            statusCode: 200,
            headers: [
                "Content-Length": "\(zip.count)",
                "ETag": "\"v1\"",
                "Accept-Ranges": "bytes"
            ],
            body: zip,
            stallAfter: stallAfter
        )
    }

    private static func rangeStart(_ header: String) -> Int? {
        guard header.hasPrefix("bytes=") else { return nil }
        let rest = header.dropFirst("bytes=".count)
        guard let dash = rest.firstIndex(of: "-") else { return nil }
        return Int(rest[..<dash])
    }
}

final class UpdateProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UpdateDownloadProgress] = []

    func record(_ progress: UpdateDownloadProgress) {
        lock.lock()
        values.append(progress)
        lock.unlock()
    }

    var last: UpdateDownloadProgress? {
        lock.lock()
        defer { lock.unlock() }
        return values.last
    }

    var all: [UpdateDownloadProgress] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

struct UpdateDownloadFixture {
    let zip: Data
    let zipName: String
    let hash: String
    let server: UpdateDownloadMockServer
    let session: URLSession
    let publicKeyBase64: String
    let update: AvailableUpdate
    let staging: URL
}

func makeUpdateDownloadFixture(
    stallFirstZipAfter: Int? = nil,
    stallEveryZip: Bool = false,
    checksumForDifferentBytes: Bool = false,
    signatureFromDifferentKey: Bool = false
) throws -> UpdateDownloadFixture {
    let zipName = "WallpaperMac-v0.2.7-macOS.zip"
    let byteCount = 64 * 1024
    var zipBytes = [UInt8]()
    zipBytes.reserveCapacity(byteCount)
    for index in 0..<byteCount {
        zipBytes.append(UInt8((index * 31 + 7) % 251))
    }
    let zip = Data(zipBytes)
    let hash = UpdateArtifactVerifier.sha256Hex(ofData: zip)

    let expectedHash: String
    if checksumForDifferentBytes {
        var altered = zip
        altered[1024] = altered[1024] ^ 0xFF
        expectedHash = UpdateArtifactVerifier.sha256Hex(ofData: altered)
    } else {
        expectedHash = hash
    }
    let checksums = Data("\(expectedHash)  \(zipName)\n".utf8)

    let signingKey = Curve25519.Signing.PrivateKey()
    let verificationKey = signatureFromDifferentKey ? Curve25519.Signing.PrivateKey() : signingKey
    let signatureLine = try UpdateSignature.sign(data: zip, privateKey: signingKey)
    let signature = Data((signatureLine + "\n").utf8)

    let server = UpdateDownloadMockServer(
        zip: zip,
        zipName: zipName,
        checksums: checksums,
        signature: signature,
        stallFirstZipAfter: stallFirstZipAfter,
        stallEveryZip: stallEveryZip
    )
    server.install()
    let session = server.makeSession()

    let baseURL = URL(string: "https://update.test")!
    let update = AvailableUpdate(
        version: "0.2.7",
        releaseNotes: "notes",
        releasePageURL: baseURL,
        zipURL: baseURL.appendingPathComponent(zipName),
        downloadSizeBytes: Int64(zip.count),
        checksumsURL: baseURL.appendingPathComponent("SHA256SUMS.txt"),
        signatureURL: baseURL.appendingPathComponent("\(zipName).sig"),
        publishedAt: nil
    )

    let staging = FileManager.default.temporaryDirectory
        .appendingPathComponent("WallpaperMacUpdateDownloadTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

    return UpdateDownloadFixture(
        zip: zip,
        zipName: zipName,
        hash: hash,
        server: server,
        session: session,
        publicKeyBase64: verificationKey.publicKey.rawRepresentation.base64EncodedString(),
        update: update,
        staging: staging
    )
}

func makeFastStallPolicy(maximumAttempts: Int = 3) -> DownloadTransferPolicy {
    DownloadTransferPolicy(
        maximumAttempts: maximumAttempts,
        stallWindow: 0.3,
        // Low enough that the resumed chunked transfer is not itself judged
        // slow, high enough that the 8 KB trickle counts as stalled.
        minimumAverageBytesPerSecond: 50_000,
        retryDelay: 0.05
    )
}

func testUpdateCheckerParsesAssetSize() throws {
    let data = makeReleaseJSON(assets: [
        [
            "name": "WallpaperMac-v0.2.6-macOS.zip",
            "browser_download_url": "https://example.com/WallpaperMac-v0.2.6-macOS.zip",
            "size": 48_234_567
        ],
        [
            "name": "WallpaperMac-v0.2.6-SHA256SUMS.txt",
            "browser_download_url": "https://example.com/WallpaperMac-v0.2.6-SHA256SUMS.txt"
        ]
    ])
    let result = try UpdateChecker.parseLatestRelease(data: data, currentVersion: "0.2.5")
    guard case .updateAvailable(let update) = result else {
        throw TestFailure(message: "expected update available, got \(result)")
    }
    try expect(update.downloadSizeBytes, equals: 48_234_567, "zip asset size should be surfaced for the UI")
}

func testDownloadTransferPolicyDetectsStalls() throws {
    let policy = DownloadTransferPolicy(
        maximumAttempts: 3,
        stallWindow: 60,
        minimumAverageBytesPerSecond: 4 * 1024
    )
    try expect(policy.isStalled(bytesTransferred: 0, over: 60), "zero bytes over a full window is a stall")
    try expect(
        policy.isStalled(bytesTransferred: 4 * 1024 * 60 - 1, over: 60),
        "just below the floor is a stall"
    )
    try expect(
        !policy.isStalled(bytesTransferred: 4 * 1024 * 60, over: 60),
        "the average floor itself is not a stall"
    )
    try expect(!policy.isStalled(bytesTransferred: 0, over: 59), "a partial window must not be judged")
    try expect(!policy.isStalled(bytesTransferred: 1_000_000, over: 60), "a fast transfer is not stalled")
}

func testDownloadRetryStateCapsAttemptsAndKeepsResume() throws {
    var state = DownloadRetryState(policy: DownloadTransferPolicy(maximumAttempts: 3))
    try expect(state.beginAttempt(), "the first attempt should always start")
    try expect(
        state.recordFailure(.transport("reset"), canResume: true),
        equals: .retry(canResume: true),
        "a transport failure with resume data should resume"
    )
    try expect(state.beginAttempt(), "a retry should start another attempt")
    try expect(
        state.recordFailure(.stalled(averageBytesPerSecond: 100), canResume: false),
        equals: .retry(canResume: false),
        "a stall without resume data should restart from scratch"
    )
    try expect(state.beginAttempt(), "the final attempt should start")
    try expect(
        state.recordFailure(.transport("timeout"), canResume: false),
        equals: .stop(.network("网络传输反复中断（已尝试 3 次）：timeout")),
        "the attempt cap should produce a readable network error"
    )
    try expect(!state.beginAttempt(), "no attempt may start past the cap")
    try expect(state.attemptsRemaining, equals: 0, "the budget should be exhausted")

    var stallState = DownloadRetryState(policy: DownloadTransferPolicy(maximumAttempts: 1))
    try expect(stallState.beginAttempt(), "the first attempt should start")
    try expect(
        stallState.recordFailure(.stalled(averageBytesPerSecond: 0), canResume: true),
        equals: .stop(.stalled(attempts: 1)),
        "the final stall should be distinguishable from a network error"
    )

    var serverState = DownloadRetryState(policy: DownloadTransferPolicy(maximumAttempts: 2))
    try expect(serverState.beginAttempt(), "the first attempt should start")
    try expect(
        serverState.recordFailure(.server(statusCode: 503), canResume: true),
        equals: .retry(canResume: false),
        "HTTP error bodies must never be resumed"
    )

    let stallMessage = UpdateDownloadError.stalled(attempts: 3).localizedDescription
    try expect(stallMessage.contains("停滞"), "stall failures should explain the network problem")
    try expect(stallMessage.contains("3"), "stall failures should name the attempt count")
}

func testUpdateDownloadResumesInterruptedTransferAndVerifies() throws {
    try runAsyncTest {
        let fixture = try makeUpdateDownloadFixture(stallFirstZipAfter: 8 * 1024)
        defer { try? FileManager.default.removeItem(at: fixture.staging) }

        let downloader = UpdateDownloader(
            session: fixture.session,
            signaturePolicy: .required,
            publicKeyBase64: fixture.publicKeyBase64,
            transferConfiguration: fixture.server.configuration,
            transferPolicy: makeFastStallPolicy()
        )
        let progress = UpdateProgressRecorder()
        let outcome = try await downloader.downloadAndVerify(
            update: fixture.update,
            stagingDirectory: fixture.staging,
            onProgress: { progress.record($0) }
        )

        try expect(outcome.sha256, equals: fixture.hash, "resumed artifact must keep its published hash")
        let downloaded = try Data(contentsOf: outcome.zipFileURL)
        try expect(downloaded, equals: fixture.zip, "resumed download must contain the complete artifact")
        try expect(
            outcome.zipFileURL.lastPathComponent,
            equals: fixture.zipName,
            "verified artifact should keep the release name"
        )

        let requests = UpdateDownloadMockURLProtocol.requests()
        let zipIndices = requests.indices.filter { requests[$0].path.hasSuffix(fixture.zipName) }
        try expect(zipIndices.count >= 2, "a stalled transfer should be retried")
        try expect(
            zipIndices.contains { requests[$0].range != nil },
            "the retry must continue from a Range request instead of starting over"
        )

        guard let firstZip = zipIndices.first,
              let lastZip = zipIndices.last,
              let checksumsIndex = requests.firstIndex(where: { $0.path.hasSuffix("SHA256SUMS.txt") }),
              let signatureIndex = requests.firstIndex(where: { $0.path.hasSuffix(".sig") }) else {
            throw TestFailure(message: "expected checksum, zip and signature requests")
        }
        try expect(checksumsIndex < firstZip, "checksums must be fetched before the artifact")
        try expect(signatureIndex > lastZip, "signature must be checked after the completed artifact")

        guard let lastProgress = progress.last else {
            throw TestFailure(message: "expected at least one progress update")
        }
        try expect(
            lastProgress.bytesReceived,
            equals: Int64(fixture.zip.count),
            "final progress should cover the whole artifact"
        )
        try expect(
            lastProgress.totalBytes,
            equals: Int64(fixture.zip.count),
            "final progress should know the artifact size"
        )
        try expect(
            progress.all.contains { ($0.bytesPerSecond ?? 0) > 0 },
            "progress should report a transfer speed"
        )
    }
}

func testUpdateDownloadRejectsTamperedBytesAfterResume() throws {
    try runAsyncTest {
        let fixture = try makeUpdateDownloadFixture(
            stallFirstZipAfter: 8 * 1024,
            checksumForDifferentBytes: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.staging) }

        let downloader = UpdateDownloader(
            session: fixture.session,
            signaturePolicy: .required,
            publicKeyBase64: fixture.publicKeyBase64,
            transferConfiguration: fixture.server.configuration,
            transferPolicy: makeFastStallPolicy()
        )
        do {
            _ = try await downloader.downloadAndVerify(
                update: fixture.update,
                stagingDirectory: fixture.staging
            )
            throw TestFailure(message: "checksum mismatch must abort the install")
        } catch let error as UpdateDownloadError {
            guard case .checksumMismatch = error else {
                throw TestFailure(message: "expected checksumMismatch, got \(error)")
            }
        }

        try expect(
            UpdateDownloadMockURLProtocol.requests().contains { $0.range != nil },
            "verification failure must be exercised after a resumed transfer"
        )
        let destination = fixture.staging.appendingPathComponent(fixture.zipName)
        try expect(
            !FileManager.default.fileExists(atPath: destination.path),
            "a failed checksum must delete the downloaded artifact"
        )
    }
}

func testUpdateDownloadRejectsBadSignatureAfterResume() throws {
    try runAsyncTest {
        let fixture = try makeUpdateDownloadFixture(
            stallFirstZipAfter: 8 * 1024,
            signatureFromDifferentKey: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.staging) }

        let downloader = UpdateDownloader(
            session: fixture.session,
            signaturePolicy: .required,
            publicKeyBase64: fixture.publicKeyBase64,
            transferConfiguration: fixture.server.configuration,
            transferPolicy: makeFastStallPolicy()
        )
        do {
            _ = try await downloader.downloadAndVerify(
                update: fixture.update,
                stagingDirectory: fixture.staging
            )
            throw TestFailure(message: "a foreign signature must abort the install")
        } catch let error as UpdateDownloadError {
            try expect(error, equals: .signatureInvalid, "foreign signatures should surface signatureInvalid")
        }

        try expect(
            UpdateDownloadMockURLProtocol.requests().contains { $0.range != nil },
            "signature failure must be exercised after a resumed transfer"
        )
        let destination = fixture.staging.appendingPathComponent(fixture.zipName)
        try expect(
            !FileManager.default.fileExists(atPath: destination.path),
            "a failed signature must delete the downloaded artifact"
        )
    }
}

func testUpdateDownloadReportsStalledTransferAfterRetryLimit() throws {
    try runAsyncTest {
        let fixture = try makeUpdateDownloadFixture(
            stallFirstZipAfter: 0,
            stallEveryZip: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.staging) }

        let downloader = UpdateDownloader(
            session: fixture.session,
            signaturePolicy: .required,
            publicKeyBase64: fixture.publicKeyBase64,
            transferConfiguration: fixture.server.configuration,
            transferPolicy: DownloadTransferPolicy(
                maximumAttempts: 2,
                stallWindow: 0.15,
                minimumAverageBytesPerSecond: 500_000,
                retryDelay: 0.02
            )
        )
        do {
            _ = try await downloader.downloadAndVerify(
                update: fixture.update,
                stagingDirectory: fixture.staging
            )
            throw TestFailure(message: "a permanently stalled transfer must fail")
        } catch let error as UpdateDownloadError {
            try expect(
                error,
                equals: .stalled(attempts: 2),
                "an exhausted stall retry budget should report stalled attempts"
            )
        }

        try expect(
            UpdateDownloadMockURLProtocol.requests().filter { $0.path.hasSuffix(fixture.zipName) }.count == 2,
            "the downloader should stop after the configured attempt budget"
        )
        let destination = fixture.staging.appendingPathComponent(fixture.zipName)
        try expect(
            !FileManager.default.fileExists(atPath: destination.path),
            "a stalled transfer must not leave an artifact behind"
        )
    }
}

// MARK: - Update installer (M3)

func testUpdateShellQuotingSurvivesApostrophes() throws {
    try expect(
        UpdateInstaller.shellQuote("/Applications/WallpaperMac.app"),
        equals: "'/Applications/WallpaperMac.app'",
        "plain paths should be single-quoted"
    )
    try expect(
        UpdateInstaller.shellQuote("/Applications/My Dad's Apps/WallpaperMac.app"),
        equals: "'/Applications/My Dad'\\''s Apps/WallpaperMac.app'",
        "apostrophes must break out of the single-quoted region safely"
    )
}

private struct UpdateScriptFixture {
    let root: URL
    let sourceApp: URL
    let targetApp: URL
    let staging: URL
    let script: URL
    let openLog: URL
}

private func writeMiniApp(at app: URL, version: String, marker: String) throws {
    let executable = app.appendingPathComponent("Contents/MacOS/WallpaperMac")
    try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(marker.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let plist: [String: Any] = [
        "CFBundleShortVersionString": version,
        "CFBundleVersion": version,
        "CFBundleExecutable": "WallpaperMac",
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
}

/// A mini app whose executable forwards the shipping update helper commands to
/// the test binary. This lets generated-script tests exercise the real swap
/// validation without overriding WALLPAPERMAC_UPDATE_SWAPPER.
private func writeShimApp(at app: URL, version: String, probe: String) throws {
    let executable = app.appendingPathComponent("Contents/MacOS/WallpaperMac")
    try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    let quotedProbe = UpdateInstaller.shellQuote(probe)
    let script = """
    #!/bin/zsh
    if [[ "$1" == "--update-swap" ]]; then
        exec \(quotedProbe) --update-swap "$2" "$3"
    fi
    if [[ "$1" == "--update-lock-check" ]]; then
        exec \(quotedProbe) --update-lock-check "$2" "$3"
    fi
    exit 1
    """
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let plist: [String: Any] = [
        "CFBundleShortVersionString": version,
        "CFBundleVersion": version,
        "CFBundleExecutable": "WallpaperMac",
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
}

private func makeUpdateScriptFixture(expectedVersion: String = "9.9.9") throws -> UpdateScriptFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WallpaperMacUpdateScriptTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let sourceApp = root.appendingPathComponent("staging/extracted/WallpaperMac.app")
    let targetApp = root.appendingPathComponent("Applications/WallpaperMac.app")
    try writeMiniApp(at: sourceApp, version: expectedVersion, marker: "new-complete")
    try writeMiniApp(at: targetApp, version: "0.1.0", marker: "old-complete")
    let script = root.appendingPathComponent("staging/install.sh")
    let scriptText = UpdateInstaller.installScript(
        parentPID: 999_999_999,
        sourceAppPath: sourceApp.path,
        targetAppPath: targetApp.path,
        stagingPath: root.appendingPathComponent("staging").path,
        expectedVersion: expectedVersion
    )
    try scriptText.write(to: script, atomically: true, encoding: .utf8)
    return UpdateScriptFixture(
        root: root,
        sourceApp: sourceApp,
        targetApp: targetApp,
        staging: root.appendingPathComponent("staging"),
        script: script,
        openLog: root.appendingPathComponent("open.log")
    )
}

private func runUpdateScript(_ fixture: UpdateScriptFixture, ditto: String, openStatus: Int32, healthAck: Bool = true, healthWaitSteps: Int = 2, installLock: UpdateInstallLock? = nil, failRollback: Bool = false, realPendingHelper: Bool = false) throws -> Int32 {
    let fakeOpen = fixture.root.appendingPathComponent("fake-open.sh")
    let script = """
    #!/bin/zsh
    print -r -- "$@" >> "$OPEN_LOG"
    TOKEN=""
    ACK=""
    NEXT=""
    for ARG in "$@"; do
        if [[ "$ARG" == "--update-health-token" ]]; then
            NEXT="token"
        elif [[ "$ARG" == "--update-health-file" ]]; then
            NEXT="file"
        elif [[ "$NEXT" == "token" ]]; then
            TOKEN="$ARG"
            NEXT=""
        elif [[ "$NEXT" == "file" ]]; then
            ACK="$ARG"
            NEXT=""
        fi
    done
    if [[ "$OPEN_STATUS" == "0" && "$WALLPAPERMAC_HEALTH_ACK" == "1" && -n "$TOKEN" && -n "$ACK" ]]; then
        printf 'token=%s\\npid=%s\\nversion=%s\\n' "$TOKEN" "$$" "$WALLPAPERMAC_HEALTH_VERSION" > "$ACK"
    fi
    exit $OPEN_STATUS
    """
    try script.write(to: fakeOpen, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeOpen.path)
    let fakeSwapper = fixture.root.appendingPathComponent("fake-swapper.sh")
    let swapScript = """
    #!/bin/zsh
    [[ "$1" == "--update-swap" ]] || {
        [[ "$1" == "--update-lock-check" ]] || exit 2
        /usr/bin/python3 -I -c 'import os,sys; a=os.stat(sys.argv[1]); b=os.fstat(0); sys.exit((a.st_dev,a.st_ino)!=(b.st_dev,b.st_ino))' "$2" || exit 1
        [[ "$(head -n 1 "$2")" == "$3" ]] || exit 1
        exit 0
    }
    if [[ "${WALLPAPERMAC_FAIL_ROLLBACK:-0}" == "1" && -f "$WALLPAPERMAC_SWAP_COUNT" ]]; then
        exit 1
    fi
    print -r -- 'swap' >> "$WALLPAPERMAC_SWAP_COUNT"
    TEMP="${3}.swap-temp"
    mv "$3" "$TEMP"
    mv "$2" "$3"
    mv "$TEMP" "$2"
    """
    try swapScript.write(to: fakeSwapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeSwapper.path)
    if let installLock {
        let lockedScript = UpdateInstaller.installScript(
            parentPID: 999_999_999,
            sourceAppPath: fixture.sourceApp.path,
            targetAppPath: fixture.targetApp.path,
            stagingPath: fixture.staging.path,
            expectedVersion: "9.9.9",
            lockPath: installLock.lockURL.path,
            lockToken: installLock.ownerToken
        )
        try lockedScript.write(to: fixture.script, atomically: true, encoding: .utf8)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = [fixture.script.path]
    var environment: [String: String] = [
        "PATH": "/bin:/usr/bin",
        "WALLPAPERMAC_DITTO": ditto,
        "WALLPAPERMAC_OPEN": fakeOpen.path,
        "WALLPAPERMAC_XATTR": "/usr/bin/xattr",
        "WALLPAPERMAC_CODESIGN": "/usr/bin/true",
        "WALLPAPERMAC_HEALTH_WAIT_STEPS": String(healthWaitSteps),
        "WALLPAPERMAC_HEALTH_ACK": healthAck ? "1" : "0",
        "WALLPAPERMAC_HEALTH_VERSION": "9.9.9",
        "WALLPAPERMAC_FAIL_ROLLBACK": failRollback ? "1" : "0",
        "WALLPAPERMAC_SWAP_COUNT": fixture.root.appendingPathComponent("swap-count").path,
        "OPEN_LOG": fixture.openLog.path,
        "OPEN_STATUS": String(openStatus),
    ]
    if !realPendingHelper {
        environment["WALLPAPERMAC_UPDATE_SWAPPER"] = fakeSwapper.path
    }
    process.environment = environment
    process.standardOutput = FileHandle.nullDevice
    let errorLog = fixture.root.appendingPathComponent("script-error.log")
    FileManager.default.createFile(atPath: errorLog.path, contents: nil)
    process.standardError = FileHandle(forWritingAtPath: errorLog.path)
    if let installLock {
        process.standardInput = installLock.fileHandle
    }
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

private func makeFailingDitto(at url: URL) throws {
    let script = """
    #!/bin/zsh
    mkdir -p "$2/Contents/MacOS"
    print -r -- 'partial-new' > "$2/Contents/MacOS/WallpaperMac"
    exit 1
    """
    try script.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

private func appMarker(_ app: URL) -> String {
    (try? String(contentsOf: app.appendingPathComponent("Contents/MacOS/WallpaperMac"), encoding: .utf8)) ?? "MISSING"
}

func testUpdateCopyFailureLeavesOriginalAppUntouched() throws {
    let fixture = try makeUpdateScriptFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let failingDitto = fixture.root.appendingPathComponent("failing-ditto.sh")
    try makeFailingDitto(at: failingDitto)
    let status = try runUpdateScript(fixture, ditto: failingDitto.path, openStatus: 0)
    try expect(status, equals: 1, "a partial copy must fail the install")
    try expect(appMarker(fixture.targetApp), equals: "old-complete", "copy failure must leave the old app in place")
    let openLog = (try? String(contentsOf: fixture.openLog, encoding: .utf8)) ?? ""
    try expect(openLog.contains(fixture.targetApp.path), "a pre-swap failure must relaunch the existing app")
    try expect(!FileManager.default.fileExists(atPath: fixture.targetApp.appendingPathComponent("WallpaperMac.app.previous").path), "rollback must never nest the previous app")
    try expect(!FileManager.default.fileExists(atPath: fixture.targetApp.appendingPathComponent("Contents/MacOS/WallpaperMac.installing").path), "partial content must not reach the real executable path")
}

func testUpdateFailureWritesJournalAndRelaunchesOldApp() throws {
    let fixture = try makeUpdateScriptFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let failureFile = fixture.root.appendingPathComponent("last-install-failure.txt")
    let script = UpdateInstaller.installScript(
        parentPID: 999_999_999,
        sourceAppPath: fixture.sourceApp.path,
        targetAppPath: fixture.targetApp.path,
        stagingPath: fixture.staging.path,
        expectedVersion: "9.9.9",
        resultFile: failureFile.path
    )
    try script.write(to: fixture.script, atomically: true, encoding: .utf8)
    let failingDitto = fixture.root.appendingPathComponent("failing-ditto.sh")
    try makeFailingDitto(at: failingDitto)

    let status = try runUpdateScript(fixture, ditto: failingDitto.path, openStatus: 0)
    try expect(status, equals: 1, "the failing copy should abort the install")
    let failure = UpdateInstallJournal.takeFailure(directory: fixture.root)
    try expect(failure?.version, equals: "9.9.9", "the journal should record the target version")
    try expect(failure?.message.contains("unable to copy") == true, "the journal should carry the installer error")
    try expect(failure?.logPath?.hasSuffix("install.log") == true, "the journal should point at the install log")
    let openLog = (try? String(contentsOf: fixture.openLog, encoding: .utf8)) ?? ""
    try expect(openLog.contains(fixture.targetApp.path), "a failed install must relaunch the old app")
}

func testGeneratedInstallerUsesVerifiedPendingSwapHelper() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WallpaperMacPendingHelperTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let staging = root.appendingPathComponent("staging")
    let sourceApp = staging.appendingPathComponent("extracted/WallpaperMac.app")
    let targetApp = root.appendingPathComponent("Applications/WallpaperMac.app")
    let probe = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
    try writeShimApp(at: sourceApp, version: "9.9.9", probe: probe)
    try writeMiniApp(at: targetApp, version: "0.1.0", marker: "old-complete")
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    let scriptURL = staging.appendingPathComponent("install.sh")
    let script = UpdateInstaller.installScript(
        parentPID: 999_999_999,
        sourceAppPath: sourceApp.path,
        targetAppPath: targetApp.path,
        stagingPath: staging.path,
        expectedVersion: "9.9.9"
    )
    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    let fixture = UpdateScriptFixture(
        root: root,
        sourceApp: sourceApp,
        targetApp: targetApp,
        staging: staging,
        script: scriptURL,
        openLog: root.appendingPathComponent("open.log")
    )

    let status = try runUpdateScript(
        fixture,
        ditto: "/usr/bin/ditto",
        openStatus: 0,
        realPendingHelper: true
    )
    try expect(status, equals: 0, "the verified pending build should perform the swap")
    try expect(
        UpdateInstaller.installedVersion(at: targetApp),
        equals: "9.9.9",
        "the generated installer must accept its own .installing.<pid> name"
    )
    try expect(
        UpdateInstaller.installedVersion(at: targetApp.appendingPathExtension("previous")),
        equals: "0.1.0",
        "the outgoing app should be retained for rollback"
    )
    try expect(!FileManager.default.fileExists(atPath: staging.path), "a successful install should clean staging")
}

func testHealthFailureRollsBackWithRealHelperAndJournal() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WallpaperMacRealRollbackTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let staging = root.appendingPathComponent("staging")
    let sourceApp = staging.appendingPathComponent("extracted/WallpaperMac.app")
    let targetApp = root.appendingPathComponent("Applications/WallpaperMac.app")
    let failureFile = root.appendingPathComponent("last-install-failure.txt")
    let probe = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
    try writeShimApp(at: sourceApp, version: "9.9.9", probe: probe)
    try writeMiniApp(at: targetApp, version: "0.1.0", marker: "old-complete")
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    let scriptURL = staging.appendingPathComponent("install.sh")
    let script = UpdateInstaller.installScript(
        parentPID: 999_999_999,
        sourceAppPath: sourceApp.path,
        targetAppPath: targetApp.path,
        stagingPath: staging.path,
        expectedVersion: "9.9.9",
        resultFile: failureFile.path
    )
    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    let fixture = UpdateScriptFixture(
        root: root,
        sourceApp: sourceApp,
        targetApp: targetApp,
        staging: staging,
        script: scriptURL,
        openLog: root.appendingPathComponent("open.log")
    )

    let status = try runUpdateScript(
        fixture,
        ditto: "/usr/bin/ditto",
        openStatus: 0,
        healthAck: false,
        healthWaitSteps: 2,
        realPendingHelper: true
    )
    try expect(status, equals: 1, "a new build that never becomes healthy must fail the install")
    try expect(
        UpdateInstaller.installedVersion(at: targetApp),
        equals: "0.1.0",
        "the real .previous operand must roll back to the old app"
    )
    try expect(
        UpdateInstaller.installedVersion(at: targetApp.appendingPathExtension("previous")),
        equals: "9.9.9",
        "the failed new generation should remain in the backup"
    )
    let failure = UpdateInstallJournal.takeFailure(directory: root)
    try expect(
        failure?.message.contains("did not become healthy") == true,
        "the journal should record the health failure"
    )
    try expect(
        FileManager.default.fileExists(atPath: staging.appendingPathComponent("install.log").path),
        "a failed install should preserve its log"
    )
}

func testInstallerStartupHandshakeDetectsLiveAndDeadScripts() throws {
    try runAsyncTest {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WallpaperMacInstallerStartupTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let marker = root.appendingPathComponent("installer-started")

        let readyScript = root.appendingPathComponent("ready.sh")
        try "#!/bin/zsh\n: > \"$1\"\nsleep 5\n".write(to: readyScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readyScript.path)
        let ready = Process()
        ready.executableURL = URL(fileURLWithPath: "/bin/zsh")
        ready.arguments = [readyScript.path, marker.path]
        ready.standardOutput = FileHandle.nullDevice
        ready.standardError = FileHandle.nullDevice
        try ready.run()
        defer {
            if ready.isRunning { ready.terminate() }
            ready.waitUntilExit()
        }

        try await UpdateInstaller.waitForInstallerStart(markerURL: marker, process: ready, timeout: 5)
        try expect(
            FileManager.default.fileExists(atPath: marker.path),
            "a live installer publishing its startup marker should be accepted"
        )

        try FileManager.default.removeItem(at: marker)
        let deadScript = root.appendingPathComponent("dead.sh")
        try "#!/bin/zsh\nexit 1\n".write(to: deadScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: deadScript.path)
        let dead = Process()
        dead.executableURL = URL(fileURLWithPath: "/bin/zsh")
        dead.arguments = [deadScript.path]
        dead.standardOutput = FileHandle.nullDevice
        dead.standardError = FileHandle.nullDevice
        try dead.run()
        dead.waitUntilExit()

        var aborted = false
        do {
            try await UpdateInstaller.waitForInstallerStart(markerURL: marker, process: dead, timeout: 1)
        } catch {
            aborted = true
        }
        try expect(aborted, "an installer that exits before publishing its marker must abort the update")
    }
}

func testUpdateRelaunchFailureRestoresOriginalApp() throws {
    let fixture = try makeUpdateScriptFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let status = try runUpdateScript(fixture, ditto: "/usr/bin/ditto", openStatus: 1)
    try expect(status, equals: 1, "a failed relaunch must return failure")
    try expect(appMarker(fixture.targetApp), equals: "old-complete", "failed relaunch must restore the old app")
    let previous = fixture.targetApp.appendingPathExtension("previous")
    try expect(appMarker(previous), equals: "new-complete", "rollback should leave the failed new generation in the backup for diagnosis")
    try expect(!FileManager.default.fileExists(atPath: fixture.targetApp.appendingPathComponent("WallpaperMac.app.previous").path), "restore must not nest the previous app")
}

func testUpdateSuccessfulInstallUsesValidatedSibling() throws {
    let fixture = try makeUpdateScriptFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let status = try runUpdateScript(fixture, ditto: "/usr/bin/ditto", openStatus: 0)
    try expect(status, equals: 0, "a valid install should succeed")
    try expect(appMarker(fixture.targetApp), equals: "new-complete", "the validated new app should become the target")
    try expect(!FileManager.default.fileExists(atPath: fixture.staging.path), "successful install should clean staging")
    try expect(appMarker(fixture.targetApp.appendingPathExtension("previous")), equals: "old-complete", "one old generation should remain for manual rollback")
}

func testUpdateRejectsWrongPendingVersionBeforeSwap() throws {
    let fixture = try makeUpdateScriptFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let script = UpdateInstaller.installScript(
        parentPID: 999_999_999,
        sourceAppPath: fixture.sourceApp.path,
        targetAppPath: fixture.targetApp.path,
        stagingPath: fixture.staging.path,
        expectedVersion: "1.0.0"
    )
    try script.write(to: fixture.script, atomically: true, encoding: .utf8)
    let status = try runUpdateScript(fixture, ditto: "/usr/bin/ditto", openStatus: 0)
    try expect(status, equals: 1, "a wrong pending version must abort the install")
    try expect(appMarker(fixture.targetApp), equals: "old-complete", "version rejection must not move the old app")
    try expect(!FileManager.default.fileExists(atPath: fixture.targetApp.appendingPathExtension("previous").path), "version rejection must happen before backup/swap")
}

func testAtomicSwapAcceptsInstallerTemporaryNames() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WallpaperMacAtomicSwapNameTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("WallpaperMac.app")
    let pending = root.appendingPathComponent("WallpaperMac.app.installing.12345")
    let previous = root.appendingPathComponent("WallpaperMac.app.previous")
    try writeMiniApp(at: target, version: "1.0.0", marker: "old-complete")
    try writeMiniApp(at: pending, version: "2.0.0", marker: "new-complete")

    try UpdateInstaller.atomicSwap(pendingAppURL: pending, targetAppURL: target)
    try expect(appMarker(target), equals: "new-complete", "an .installing.<pid> sibling should be swapable")
    try expect(appMarker(pending), equals: "old-complete", "the old app should move into the pending slot")

    try FileManager.default.moveItem(at: pending, to: previous)
    try UpdateInstaller.atomicSwap(pendingAppURL: previous, targetAppURL: target)
    try expect(appMarker(target), equals: "old-complete", "an .previous backup should be swapable for rollback")
    try expect(appMarker(previous), equals: "new-complete", "rollback should preserve the failed new app")
}

func testRemoveStaleInstallerBackupsKeepsPrevious() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WallpaperMacStaleBackupTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("WallpaperMac.app")
    try writeMiniApp(at: target, version: "1.0.0", marker: "current")
    let staleOne = root.appendingPathComponent("WallpaperMac.app.installing.1")
    let staleTwo = root.appendingPathComponent("WallpaperMac.app.installing.2")
    let previous = root.appendingPathComponent("WallpaperMac.app.previous")
    try FileManager.default.createDirectory(at: staleOne, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: staleTwo, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)

    UpdateInstaller.removeStaleInstallerBackups(targetAppURL: target)
    try expect(!FileManager.default.fileExists(atPath: staleOne.path), "stale .installing backups should be removed")
    try expect(!FileManager.default.fileExists(atPath: staleTwo.path), "all stale .installing backups should be removed")
    try expect(FileManager.default.fileExists(atPath: previous.path), "the .previous rollback backup must be retained")
    try expect(appMarker(target), equals: "current", "the current app must not be touched")
}

func testUpdateInstallJournalRoundTripsFailure() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WallpaperMacInstallJournalTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let failure = UpdateInstallFailure(
        version: "9.9.9",
        message: "atomic replacement failed",
        logPath: "/tmp/WallpaperMacUpdate/install.log",
        recordedAt: "2026-11-24T00:00:00Z"
    )
    try UpdateInstallJournal.writeFailure(failure, directory: root)
    let taken = UpdateInstallJournal.takeFailure(directory: root)
    try expect(taken, equals: failure, "the failed-install journal should round-trip")
    try expect(UpdateInstallJournal.takeFailure(directory: root) == nil, "taking a failure should remove it")
}

func testAtomicSwapKeepsCompleteAppAtTarget() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WallpaperMacAtomicSwapTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let pending = root.appendingPathComponent("Pending.app")
    let target = root.appendingPathComponent("WallpaperMac.app")
    try writeMiniApp(at: pending, version: "2.0.0", marker: "new-complete")
    try writeMiniApp(at: target, version: "1.0.0", marker: "old-complete")

    try UpdateInstaller.atomicSwap(pendingAppURL: pending, targetAppURL: target)
    try expect(appMarker(target), equals: "new-complete", "atomic swap should install the new app")
    try expect(appMarker(pending), equals: "old-complete", "atomic swap should move the old app to pending")

    // The same operation restores the old generation without deleting target.
    try UpdateInstaller.atomicSwap(pendingAppURL: pending, targetAppURL: target)
    try expect(appMarker(target), equals: "old-complete", "swapping back should restore the old app")
    try expect(appMarker(pending), equals: "new-complete", "swapping back should retain the new app")
}

func testUpdateOpenWithoutHealthConfirmationRollsBack() throws {
    let fixture = try makeUpdateScriptFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let status = try runUpdateScript(fixture, ditto: "/usr/bin/ditto", openStatus: 0, healthAck: false)
    try expect(status, equals: 1, "open success without a health acknowledgement must fail")
    try expect(appMarker(fixture.targetApp), equals: "old-complete", "an unhealthy launch must restore the old app")
    try expect(appMarker(fixture.targetApp.appendingPathExtension("previous")), equals: "new-complete", "the failed new generation should remain in the backup")
}

func testUpdateInstallLockExcludesOtherOwnersAndReleases() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WallpaperMacUpdateLockTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("WallpaperMac.app")
    try writeMiniApp(at: target, version: "1.0.0", marker: "old-complete")

    var first: UpdateInstallLock? = try UpdateInstallLock(targetAppURL: target)
    var rejected = false
    do {
        _ = try UpdateInstallLock(targetAppURL: target)
    } catch UpdateInstallError.alreadyInstalling {
        rejected = true
    }
    try expect(rejected, "a second owner must receive alreadyInstalling")
    try expect(FileManager.default.fileExists(atPath: first!.lockURL.path), "the lock file should remain stable for contenders")
    let token = first!.ownerToken
    first = nil
    var second: UpdateInstallLock? = try UpdateInstallLock(targetAppURL: target)
    try expect(second != nil, "closing the first descriptor should release the lock")
    try expect(second!.ownerToken != token, "a new owner needs a fresh token")
    second = nil
}

func testInstallScriptUsesInheritedLockAndReleasesAfterHelperExit() throws {
    let fixture = try makeUpdateScriptFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    var lock: UpdateInstallLock? = try UpdateInstallLock(targetAppURL: fixture.targetApp)
    let status = try runUpdateScript(
        fixture,
        ditto: "/usr/bin/ditto",
        openStatus: 0,
        healthAck: true,
        installLock: lock
    )
    if status != 0 {
        if let errorText = try? String(
            contentsOf: fixture.root.appendingPathComponent("script-error.log"),
            encoding: .utf8
        ) {
            print(errorText)
        }
    }
    try expect(status, equals: 0, "the helper should accept the inherited target lock")
    try expect(appMarker(fixture.targetApp), equals: "new-complete", "the locked helper should complete the install")
    lock = nil
    let nextLock = try UpdateInstallLock(targetAppURL: fixture.targetApp)
    _ = nextLock
}

func testUpdateRollbackFailurePreservesBackupAndDoesNotOpenBrokenTarget() throws {
    let fixture = try makeUpdateScriptFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let status = try runUpdateScript(
        fixture,
        ditto: "/usr/bin/ditto",
        openStatus: 0,
        healthAck: false,
        failRollback: true
    )
    try expect(status, equals: 1, "a failed rollback must still return failure")
    try expect(appMarker(fixture.targetApp), equals: "new-complete", "a failed rollback must not open/replace the target with a partial app")
    try expect(appMarker(fixture.targetApp.appendingPathExtension("previous")), equals: "old-complete", "the complete old app must remain in the backup")
    try expect(!FileManager.default.fileExists(atPath: fixture.targetApp.appendingPathComponent("WallpaperMac.app.previous").path), "no nested backup may be created")
}

func testFailedRollbackLaunchesPreservedBackup() throws {
    let fixture = try makeUpdateScriptFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let launchLog = fixture.root.appendingPathComponent("backup-launch.log")
    let executable = fixture.targetApp.appendingPathComponent("Contents/MacOS/WallpaperMac")
    let stub = """
    #!/bin/zsh
    if [[ "$1" == "--update-swap" ]]; then
        exit 1
    fi
    print -r -- 'launched-backup' >> \(UpdateInstaller.shellQuote(launchLog.path))
    exit 0
    """
    try stub.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

    let status = try runUpdateScript(
        fixture,
        ditto: "/usr/bin/ditto",
        openStatus: 0,
        healthAck: false,
        failRollback: true
    )
    try expect(status, equals: 1, "a failed rollback must still fail the install")
    var launchOutput = ""
    for _ in 0..<40 {
        launchOutput = (try? String(contentsOf: launchLog, encoding: .utf8)) ?? ""
        if launchOutput.contains("launched-backup") { break }
        Thread.sleep(forTimeInterval: 0.05)
    }
    try expect(
        launchOutput.contains("launched-backup"),
        "the complete old app must be launched when rollback cannot swap"
    )
    try expect(
        UpdateInstaller.installedVersion(at: fixture.targetApp),
        equals: "9.9.9",
        "the unhealthy new app must remain at the target"
    )
    try expect(
        UpdateInstaller.installedVersion(at: fixture.targetApp.appendingPathExtension("previous")),
        equals: "0.1.0",
        "the complete old app must remain in the backup"
    )
}

func testUpdateHealthHandshakeWritesMatchingTokenAtomically() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WallpaperMacHealthTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let token = UUID().uuidString
    let acknowledgement = root.appendingPathComponent("health").appendingPathComponent("ack.txt")
    let written = try UpdateHealthHandshake.acknowledge(
        arguments: ["WallpaperMac", "--update-health-token", token, "--update-health-file", acknowledgement.path],
        processID: 1234,
        version: "9.9.9"
    )
    try expect(written, "health arguments should be acknowledged")
    let contents = try String(contentsOf: acknowledgement, encoding: .utf8)
    try expect(contents.contains("token=\(token)"), "acknowledgement should carry the exact install token")
    try expect(contents.contains("pid=1234"), "acknowledgement should carry the new process ID")
    try expect(contents.contains("version=9.9.9"), "acknowledgement should carry the installed version")
    let ignored = try UpdateHealthHandshake.acknowledge(arguments: ["WallpaperMac"])
    try expect(!ignored, "an ordinary launch must not write an acknowledgement")
}

func testUpdateInstallScriptWaitsForParentAndRollsBack() throws {
    let script = UpdateInstaller.installScript(
        parentPID: 4242,
        sourceAppPath: "/tmp/staging/extracted/WallpaperMac.app",
        targetAppPath: "/Applications/WallpaperMac.app",
        stagingPath: "/tmp/staging"
    )

    try expect(script.contains("PARENT_PID=4242"), "script should wait on the updater process")
    try expect(script.contains("while kill -0 \"$PARENT_PID\""), "script must not swap bundles before we exit")
    try expect(script.contains("mv \"$TARGET_PENDING\" \"$TARGET_PREVIOUS\""), "previous build should be kept for rollback")
    try expect(script.contains("\"$DITTO\" \"$SOURCE_APP\" \"$TARGET_PENDING\""), "new bundle should be copied to a sibling before the swap")
    try expect(script.contains("--update-swap \"$TARGET_PENDING\" \"$TARGET_APP\""), "complete bundles should be exchanged atomically")
    try expect(script.contains("SWAP_STARTED=1"), "signal cleanup must track an in-flight swap")
    try expect(script.contains("PARENT_EXITED=1"), "the installer must know when the app has exited")
    try expect(script.contains("relaunching current app"), "a pre-swap failure must relaunch the known-good app")
    try expect(script.contains("RESULT_FILE="), "failed installs should write a durable failure record")
    try expect(script.contains(": > \"$STAGING_DIR/installer-started\""), "the installer must publish a startup marker before the app quits")
    try expect(script.contains("$RESULT_FILE.tmp.$$"), "failure records should be published atomically")
    let trapIndex = script.range(of: "trap finish EXIT")?.lowerBound
    let setupIndex = script.range(of: "mkdir -p \"$STAGING_DIR\"")?.lowerBound
    try expect(
        trapIndex != nil && setupIndex != nil && trapIndex! < setupIndex!,
        "the exit trap must be installed before staging setup can fail"
    )
    try expect(script.contains("TARGET_PENDING/Contents/MacOS/$EXECUTABLE_NAME"), "the verified new build should perform the swap")
    try expect(script.contains("--update-lock-check \"$LOCK_PATH\" \"$LOCK_TOKEN\""), "the Swift helper should verify the inherited lock without Python")
    try expect(script.contains("mv \"$TARGET_PENDING\" \"$TARGET_PREVIOUS\""), "the outgoing app should be retained as the backup")
    try expect(script.contains("\"$XATTR\" -cr \"$TARGET_APP\""), "quarantine bits should be cleared")
    try expect(script.contains("\"$OPEN\" -n \"$TARGET_APP\""), "relaunch should create a fresh instance even if an old instance remains")
    try expect(script.contains("--update-swap \"$BACKUP_APP\" \"$TARGET_APP\""), "rollback should atomically exchange the backup and target")
    try expect(script.contains("rm -rf \"$STAGING_DIR\""), "staging directory should be cleaned after success")
}

func testUpdatePrepareExtractsAndValidatesBundleVersion() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WallpaperMacInstallPrepareTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    // Build a miniature app bundle and zip it the same way build-release.sh does.
    let bundleRoot = root.appendingPathComponent("WallpaperMac.app/Contents/MacOS", isDirectory: true)
    try FileManager.default.createDirectory(at: bundleRoot, withIntermediateDirectories: true)
    let infoURL = root.appendingPathComponent("WallpaperMac.app/Contents/Info.plist")
    let info = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>CFBundleShortVersionString</key>
        <string>0.2.6</string>
        <key>CFBundleVersion</key>
        <string>0.2.6</string>
    </dict>
    </plist>
    """
    try info.write(to: infoURL, atomically: true, encoding: .utf8)
    try Data("fake-binary".utf8).write(to: bundleRoot.appendingPathComponent("WallpaperMac"))

    let zipURL = root.appendingPathComponent("WallpaperMac-v0.2.6-macOS.zip")
    let zip = Process()
    zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    zip.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", root.appendingPathComponent("WallpaperMac.app").path, zipURL.path]
    try zip.run()
    zip.waitUntilExit()
    try expect(zip.terminationStatus == 0, "fixture zip should be created")

    // Target app directory must be writable: use a fake /Applications stand-in.
    let fakeApplications = root.appendingPathComponent("Applications", isDirectory: true)
    try FileManager.default.createDirectory(at: fakeApplications, withIntermediateDirectories: true)
    let targetApp = fakeApplications.appendingPathComponent("WallpaperMac.app", isDirectory: true)
    try FileManager.default.createDirectory(at: targetApp, withIntermediateDirectories: true)

    let staging = root.appendingPathComponent("staging", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

    let prepared = try UpdateInstaller.prepare(
        zipFileURL: zipURL,
        expectedVersion: "0.2.6",
        stagingDirectory: staging,
        targetAppURL: targetApp
    )
    try expect(prepared.version, equals: "0.2.6", "prepared bundle should report the release version")
    try expect(prepared.targetAppURL.path, equals: targetApp.path, "install target should be preserved")
    try expect(
        FileManager.default.fileExists(atPath: prepared.appBundleURL.appendingPathComponent("Contents/Info.plist").path),
        "extracted bundle should contain Info.plist"
    )

    do {
        _ = try UpdateInstaller.prepare(
            zipFileURL: zipURL,
            expectedVersion: "9.9.9",
            stagingDirectory: staging,
            targetAppURL: targetApp
        )
        throw TestFailure(message: "version mismatch must abort preparation")
    } catch let error as UpdateInstallError {
        try expect(
            error,
            equals: .versionMismatch(expected: "9.9.9", found: "0.2.6"),
            "mismatch should name both versions"
        )
    }
}

func testUpdatePreflightRejectsTranslocatedAndBareBinaries() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WallpaperMacPreflightTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let translocated = root
        .appendingPathComponent("AppTranslocation/ABC-123/d/WallpaperMac.app", isDirectory: true)
    try FileManager.default.createDirectory(at: translocated, withIntermediateDirectories: true)
    do {
        try UpdateInstaller.preflight(runningAppURL: translocated)
        throw TestFailure(message: "translocated bundles must be rejected")
    } catch let error as UpdateInstallError {
        try expect(error, equals: .appTranslocated, "translocation should surface its own error")
    }

    let bareBinary = root.appendingPathComponent("WallpaperMac", isDirectory: false)
    try Data("x".utf8).write(to: bareBinary)
    do {
        try UpdateInstaller.preflight(runningAppURL: bareBinary)
        throw TestFailure(message: "non-app paths must be rejected")
    } catch let error as UpdateInstallError {
        try expect(error, equals: .notAnApplicationBundle, "non-app paths should surface their own error")
    }

    // A real .app under a writable parent should pass preflight.
    let goodApp = root.appendingPathComponent("Applications/WallpaperMac.app", isDirectory: true)
    try FileManager.default.createDirectory(at: goodApp, withIntermediateDirectories: true)
    try UpdateInstaller.preflight(runningAppURL: goodApp)
}

func testUpdateLocateAppBundleFindsNestedLayout() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WallpaperMacLocateTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    do {
        _ = try UpdateInstaller.locateAppBundle(in: root)
        throw TestFailure(message: "empty extract directory should fail")
    } catch let error as UpdateInstallError {
        guard case .unzipFailed = error else {
            throw TestFailure(message: "expected unzipFailed, got \(error)")
        }
    }

    let nested = root.appendingPathComponent("payload/WallpaperMac.app", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let found = try UpdateInstaller.locateAppBundle(in: root)
    try expect(found.lastPathComponent, equals: "WallpaperMac.app", "nested app bundles should be discovered")
}

// MARK: - Update signatures (M4)

func testUpdateSignatureRoundTrip() throws {
    let privateKey = Curve25519.Signing.PrivateKey()
    let publicBase64 = privateKey.publicKey.rawRepresentation.base64EncodedString()
    let payload = Data("release-artifact-bytes".utf8)

    let signature = try UpdateSignature.sign(data: payload, privateKey: privateKey)
    let verified = try UpdateSignature.verify(data: payload, signatureBase64: signature, publicKeyBase64: publicBase64)
    try expect(verified, "freshly signed payload should verify")

    let tampered = Data("release-artifact-bytes-tampered".utf8)
    let ok = try UpdateSignature.verify(data: tampered, signatureBase64: signature, publicKeyBase64: publicBase64)
    try expect(ok == false, "tampered payload must not verify")
}

func testUpdateSignatureRejectsForeignKeys() throws {
    let signedKey = Curve25519.Signing.PrivateKey()
    let otherKey = Curve25519.Signing.PrivateKey()
    let payload = Data("payload".utf8)

    let signature = try UpdateSignature.sign(data: payload, privateKey: signedKey)
    let ok = try UpdateSignature.verify(
        data: payload,
        signatureBase64: signature,
        publicKeyBase64: otherKey.publicKey.rawRepresentation.base64EncodedString()
    )
    try expect(ok == false, "signature from another key must fail verification")

    let garbage = try UpdateSignature.verify(data: payload, signatureBase64: "not-base64-!!", publicKeyBase64: "also-not")
    try expect(garbage == false, "malformed key or signature should fail closed")
}

func testUpdateSignatureFileParsing() throws {
    try expect(
        UpdateSignature.parseSignatureFile("Zm9vYmFy\n"),
        equals: Optional("Zm9vYmFy"),
        "single payload line should parse"
    )
    try expect(
        UpdateSignature.parseSignatureFile("# comment\nZm9vYmFy\n"),
        equals: Optional("Zm9vYmFy"),
        "comments should be skipped"
    )
    try expect(
        UpdateSignature.parseSignatureFile("\n\n   \n"),
        equals: nil,
        "empty signature files should return nil"
    )
}

func testUpdateSignatureFileRoundTripOnDisk() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WallpaperMacSignatureTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let privateKey = Curve25519.Signing.PrivateKey()
    let artifact = root.appendingPathComponent("WallpaperMac-v0.2.6-macOS.zip")
    try Data("zip-bytes".utf8).write(to: artifact)

    let signature = try UpdateSignature.sign(fileAt: artifact, privateKey: privateKey)
    let signatureFile = root.appendingPathComponent("WallpaperMac-v0.2.6-macOS.zip.sig")
    try signature.write(to: signatureFile, atomically: true, encoding: .utf8)

    let loaded = try String(contentsOfFile: signatureFile.path, encoding: .utf8)
    let parsed = UpdateSignature.parseSignatureFile(loaded)
    try expect(parsed, equals: signature, "signature file should round trip through disk")

    let ok = try UpdateSignature.verify(
        fileAt: artifact,
        signatureBase64: parsed ?? "",
        publicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString()
    )
    try expect(ok, "file-based signature should verify against the artifact")
}

func testUpdateSignatureAssetNaming() throws {
    try expect(
        UpdateChecker.isSignatureAssetName("WallpaperMac-v0.2.6-macOS.zip.sig"),
        "zip signature assets should match"
    )
    try expect(
        !UpdateChecker.isSignatureAssetName("WallpaperMac-v0.2.6-macOS.zip"),
        "unsigned zip is not a signature"
    )
    try expect(
        !UpdateChecker.isSignatureAssetName("WallpaperMac-v0.2.6-macOS.dmg.sig"),
        "dmg signatures are not consumed by the app updater"
    )
}

// MARK: - Data safety fixes (batch 1)

func testQueueReplaceWallpaperIDsKeepsOrderAndDropsRemoved() throws {
    let keep = UUID()
    let removed = UUID()
    let added = UUID()
    var queue = PlaybackQueue(name: "工作", wallpaperIDs: [removed, keep], sortMode: .name)

    queue.replaceWallpaperIDs([keep, added], markingSortMode: .custom)
    try expect(queue.wallpaperIDs, equals: [keep, added], "replace must delete and keep editor order")
    try expect(queue.sortMode, equals: .custom, "manual editor saves pin custom sort mode")
    try expect(queue.wallpaperIDs.contains(removed) == false, "removed IDs must not survive a replace")

    var withOverride = PlaybackQueue(name: "备用", wallpaperIDs: [keep])
    withOverride.setIntervalOverride(42, for: keep)
    withOverride.setIntervalOverride(7, for: removed)
    withOverride.replaceWallpaperIDs([keep])
    try expect(withOverride.itemIntervalOverrides[keep], equals: Optional(42), "kept items keep interval overrides")
    try expect(withOverride.itemIntervalOverrides[removed] == nil, "removed items lose interval overrides")

    var dupe = PlaybackQueue(name: "重复")
    dupe.replaceWallpaperIDs([keep, keep, added])
    try expect(dupe.wallpaperIDs, equals: [keep, added], "replace deduplicates while preserving first-seen order")
}

func testUniquedDictionaryKeepsFirstOccurrence() throws {
    let pairs: [(String, Int)] = [("a", 1), ("b", 2), ("a", 3)]
    let dict = UniquedDictionary.build(pairs, label: "test")
    try expect(dict, equals: ["a": 1, "b": 2], "duplicate keys must keep the first value deterministically")
    try expect(UniquedDictionary.build([(String, Int)]()).isEmpty, "empty input builds an empty dictionary")
}

func testUpdateMetadataPatchesOnlyEnrichmentFields() throws {
    let fixture = try Fixture()
    let root = fixture.root.appendingPathComponent("Assets", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("photo.png")
    try Data("png".utf8).write(to: source)

    let item = WallpaperItem(
        name: "照片",
        type: .image,
        sourceURL: source,
        storageMode: .externalReference
    )
    try fixture.store.save(items: [item])

    // Simulate a concurrent rename landing after enrichment started.
    var renamed = item
    renamed.name = "重命名后"
    _ = try fixture.store.update(item: renamed)

    let patch = WallpaperStore.MetadataPatch(
        metadata: WallpaperMetadata(pixelWidth: 1920, pixelHeight: 1080),
        thumbnailURL: source
    )
    let updated = try fixture.store.updateMetadata([item.id: patch])
    try expect(updated.count, equals: 1, "one patch should update one item")

    let reloaded = try WallpaperStore(libraryURL: fixture.library).items()
    try expect(reloaded.first?.name, equals: "重命名后", "metadata patch must not clobber a concurrent rename")
    try expect(reloaded.first?.metadata?.pixelWidth, equals: 1920, "metadata fields should be written")
    try expect(reloaded.first?.thumbnailURL, equals: source, "thumbnail URL should be written")
}

func testRemovePersistsIndexBeforeDeletingFiles() throws {
    let fixture = try Fixture()
    let assets = fixture.library.appendingPathComponent("Assets", isDirectory: true)
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    let source = assets.appendingPathComponent("keepme.png")
    try Data("png".utf8).write(to: source)

    let item = WallpaperItem(
        name: "managed",
        type: .image,
        sourceURL: source,
        storageMode: .managedCopy
    )
    try fixture.store.save(items: [item])
    _ = try fixture.store.remove(item: item)

    let remaining = try WallpaperStore(libraryURL: fixture.library).items()
    try expect(remaining.isEmpty, "index entry must be gone after remove")
    try expect(FileManager.default.fileExists(atPath: source.path) == false, "managed asset should be deleted after the index write")
}

func testMigrationResumesFromPlanAfterPartialWrite() throws {
    let fixture = try Fixture()
    try FileManager.default.createDirectory(at: fixture.library, withIntermediateDirectories: true)

    let legacy = DisplayPlaybackQueue(
        displayID: "display-1",
        displayName: "内置屏幕",
        wallpaperIDs: [UUID()],
        intervalSeconds: 30,
        isEnabled: true,
        currentIndex: 0
    )
    let legacyURL = fixture.library.appendingPathComponent("display-queues.json")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let legacyList: [DisplayPlaybackQueue] = [legacy]
    try encoder.encode(legacyList).write(to: legacyURL)

    // Simulate a crash after bindings were written but before queues/marker:
    // leave only the legacy file first (fresh migration), then a plan-only state.
    let store = WallpaperStore(libraryURL: fixture.library)
    _ = try store.playbackQueues()  // triggers full migration
    let marker = fixture.library.appendingPathComponent("display-queues.migrated")
    try expect(FileManager.default.fileExists(atPath: marker.path), "migration should leave a commit marker")
    try expect(FileManager.default.fileExists(atPath: legacyURL.path) == false, "legacy file should be retired after commit")

    // Half-migration: delete marker and queues, keep bindings + restore legacy+plan path.
    let queuesURL = fixture.library.appendingPathComponent("playback-queues.json")
    try FileManager.default.removeItem(at: marker)
    try FileManager.default.removeItem(at: queuesURL)
    try encoder.encode(legacyList).write(to: legacyURL)

    // Without a plan the untrusted partial state is regenerated from legacy.
    let resumed = WallpaperStore(libraryURL: fixture.library)
    let queues = try resumed.playbackQueues()
    try expect(queues.isEmpty == false, "migration rebuild must produce queues from legacy")
    try expect(FileManager.default.fileExists(atPath: marker.path), "re-migration should commit again")
    let bindings = try resumed.displayPlaybackBindings()
    try expect(bindings.map(\.displayID), equals: ["display-1"], "legacy display binding must be preserved")
    try expect(bindings.first?.activeQueueID, equals: queues.first(where: { !$0.isDefault })?.id ?? bindings.first?.activeQueueID, "binding should reference a migrated queue")
}

func testQueueLoadFailureBlocksWritesAndPreservesBytes() throws {
    let fixture = try Fixture()
    try FileManager.default.createDirectory(at: fixture.library, withIntermediateDirectories: true)
    let queuesURL = fixture.library.appendingPathComponent("playback-queues.json")
    let bindingsURL = fixture.library.appendingPathComponent("display-playback-bindings.json")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode([PlaybackQueue.defaultQueue]).write(to: queuesURL)
    try encoder.encode([DisplayPlaybackBinding]()).write(to: bindingsURL)
    let originalBindings = try Data(contentsOf: bindingsURL)

    let corruptQueues = Data("{not json".utf8)
    try corruptQueues.write(to: queuesURL)

    let store = WallpaperStore(libraryURL: fixture.library)
    let result = store.loadPlaybackQueueConfiguration()
    try expect(result.blocksPersistence, equals: true, "a corrupt queue file must block persistence")
    var queuesFailed = false
    if case .failed = result.queuesFile { queuesFailed = true }
    try expect(queuesFailed, "the queue file should be reported as failed")
    try expect(result.bindingsFile, equals: .loaded, "readable bindings should still load")
    try expect(result.queues, equals: [PlaybackQueue.defaultQueue], "the fallback queue should stay in memory")

    var queueSaveThrew = false
    do {
        try store.save(playbackQueues: [PlaybackQueue.defaultQueue])
    } catch WallpaperStoreError.queuePersistenceBlocked(_) {
        queueSaveThrew = true
    }
    try expect(queueSaveThrew, "queue saves must be blocked after a load failure")

    var bindingSaveThrew = false
    do {
        try store.save(displayPlaybackBindings: [])
    } catch WallpaperStoreError.queuePersistenceBlocked(_) {
        bindingSaveThrew = true
    }
    try expect(bindingSaveThrew, "binding saves must be blocked after a load failure")

    try expect(try Data(contentsOf: queuesURL), equals: corruptQueues, "a blocked save must not rewrite the corrupt file")
    try expect(try Data(contentsOf: bindingsURL), equals: originalBindings, "a blocked save must not rewrite bindings")
}

func testMissingQueueFilesAllowWrites() throws {
    let fixture = try Fixture()
    let store = WallpaperStore(libraryURL: fixture.library)
    let result = store.loadPlaybackQueueConfiguration()
    try expect(result.queuesFile, equals: .missing, "a new library has no queue file")
    try expect(result.bindingsFile, equals: .missing, "a new library has no bindings file")
    try expect(result.blocksPersistence, equals: false, "missing files must not block writes")

    try store.save(playbackQueues: [.defaultQueue], displayPlaybackBindings: [])
    let reloaded = WallpaperStore(libraryURL: fixture.library).loadPlaybackQueueConfiguration()
    try expect(reloaded.blocksPersistence, equals: false, "saved files should load cleanly")
    try expect(reloaded.queues.count, equals: 1, "default queue should persist")
}

func testQueueLoadRecoversAfterRepair() throws {
    let fixture = try Fixture()
    try FileManager.default.createDirectory(at: fixture.library, withIntermediateDirectories: true)
    let queuesURL = fixture.library.appendingPathComponent("playback-queues.json")
    let bindingsURL = fixture.library.appendingPathComponent("display-playback-bindings.json")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let validQueues = try encoder.encode([PlaybackQueue.defaultQueue])
    let validBindings = try encoder.encode([DisplayPlaybackBinding]())
    try validQueues.write(to: queuesURL)
    try validBindings.write(to: bindingsURL)

    let store = WallpaperStore(libraryURL: fixture.library)
    try Data("{broken".utf8).write(to: queuesURL)
    try expect(store.loadPlaybackQueueConfiguration().blocksPersistence, equals: true, "corrupt file should block")

    // The user repairs the file outside the app; reloading the same store
    // must clear the block and allow writes again.
    try validQueues.write(to: queuesURL)
    let repaired = store.loadPlaybackQueueConfiguration()
    try expect(repaired.blocksPersistence, equals: false, "a repaired file should unblock persistence")
    try store.save(playbackQueues: [PlaybackQueue.defaultQueue], displayPlaybackBindings: [])
}

func testLibraryPersistenceGateBlocksAfterLoadFailure() throws {
    var gate = LibraryPersistenceGate()
    try expect(gate.blocksPersistence, equals: false, "a fresh gate should allow persistence")
    gate.recordLoadFailure("播放队列读取失败")
    try expect(gate.blocksPersistence, equals: true, "a load failure must block persistence")
    try expect(gate.loadError, equals: "播放队列读取失败", "the load error should stay visible")
    gate.recordLoadFailure("显示器绑定读取失败")
    try expect(gate.loadError, equals: "播放队列读取失败", "the first failure should be kept")
    gate.recordSuccessfulLoad()
    try expect(gate.blocksPersistence, equals: false, "a successful reload should unblock persistence")
    try expect(gate.loadError, equals: nil, "a successful reload should clear the error")
}

func testVideoPlaybackProgressUsesActualTimeAndDuration() throws {
    var tracker = VideoPlaybackProgressTracker()
    var sample = tracker.sample(currentTime: 0, duration: nil)
    try expect(!sample.advanced, "the first timestamp establishes a baseline")
    try expect(sample.durationSeconds, equals: nil, "unknown duration stays unknown")

    sample = tracker.sample(currentTime: 1, duration: nil)
    try expect(sample.advanced, "forward playback time is a heartbeat")

    sample = tracker.sample(currentTime: 1, duration: nil)
    try expect(!sample.advanced, "a frozen timestamp is not a heartbeat")

    sample = tracker.sample(currentTime: 0.5, duration: nil)
    try expect(!sample.advanced, "seeking backwards is not forward progress")

    sample = tracker.sample(currentTime: 2, duration: 600)
    try expect(sample.advanced, "progress continues after a seek")
    try expect(sample.durationChanged, "a newly available duration must be published")
    try expect(sample.durationSeconds, equals: 600, "the actual duration is now known")

    tracker.resetClock()
    sample = tracker.sample(currentTime: 3, duration: 600)
    try expect(!sample.advanced, "resume establishes a fresh time baseline without counting paused time")

    sample = tracker.sample(currentTime: 4, duration: nil)
    try expect(sample.durationSeconds, equals: 600, "an unavailable later duration must not clear a known duration")
    try expect(!sample.durationChanged, "an unavailable later duration must not re-arm the watchdog")
}

func testExternalNavigationRequiresOneShotNativeGesture() throws {
    let url = URL(string: "https://Example.com:443/docs")!
    let equivalent = URL(string: "https://example.com/docs")!
    let now: TimeInterval = 100
    var gate = ExternalNavigationAuthorizer()

    try expect(
        !gate.consume(url: url, now: now, interactionEnabled: true, isPlaying: true, isSystemSuspended: false),
        "script-generated navigation without a native gesture must be denied"
    )

    gate.prepare(url: url, now: now, interactionEnabled: true, isPlaying: true, isSystemSuspended: false)
    try expect(
        gate.consume(url: equivalent, now: now, interactionEnabled: true, isPlaying: true, isSystemSuspended: false),
        "one native gesture should authorize the equivalent absolute URL once"
    )
    try expect(
        !gate.consume(url: url, now: now, interactionEnabled: true, isPlaying: true, isSystemSuspended: false),
        "the same gesture must not authorize a second navigation"
    )

    gate.prepare(url: url, now: now, interactionEnabled: true, isPlaying: true, isSystemSuspended: false)
    try expect(
        !gate.consume(url: url, now: now + 2, interactionEnabled: true, isPlaying: true, isSystemSuspended: false),
        "an expired gesture must not open a browser"
    )

    gate.prepare(url: url, now: now, interactionEnabled: true, isPlaying: true, isSystemSuspended: false)
    try expect(
        !gate.consume(url: URL(string: "https://example.com/other")!, now: now, interactionEnabled: true, isPlaying: true, isSystemSuspended: false),
        "a gesture must only authorize its original target URL"
    )

    gate.prepare(url: url, now: now, interactionEnabled: true, isPlaying: true, isSystemSuspended: false)
    try expect(
        !gate.consume(url: url, now: now, interactionEnabled: false, isPlaying: true, isSystemSuspended: false),
        "interaction-disabled wallpaper must not open a browser"
    )

    gate.prepare(url: url, now: now, interactionEnabled: true, isPlaying: true, isSystemSuspended: false)
    try expect(
        !gate.consume(url: url, now: now, interactionEnabled: true, isPlaying: false, isSystemSuspended: false),
        "a paused wallpaper must not open a browser"
    )

    gate.prepare(url: url, now: now, interactionEnabled: true, isPlaying: true, isSystemSuspended: true)
    try expect(
        !gate.consume(url: url, now: now, interactionEnabled: true, isPlaying: true, isSystemSuspended: true),
        "a system-suspended wallpaper must not open a browser"
    )
}

func testWebContentRecoveryUsesBoundedBackoffAndHealthyReset() throws {
    var state = WebContentRecoveryState(maximumAttempts: 3)
    try expect(state.nextDelay(isPlaying: true, isSystemSuspended: false), equals: 1, "first recovery should be delayed by one second")
    try expect(state.nextDelay(isPlaying: true, isSystemSuspended: false), equals: 2, "second recovery should back off to two seconds")
    try expect(state.nextDelay(isPlaying: true, isSystemSuspended: false), equals: 4, "third recovery should back off to four seconds")
    try expect(state.isExhausted, "the third attempt exhausts the budget")
    try expect(state.nextDelay(isPlaying: true, isSystemSuspended: false), equals: nil, "no further reload after the budget is exhausted")
    state.markHealthy()
    try expect(state.attempts, equals: 0, "a stable healthy interval resets the budget")
    try expect(state.nextDelay(isPlaying: true, isSystemSuspended: false), equals: 1, "a new failure after stability gets a fresh budget")

    var paused = WebContentRecoveryState()
    try expect(paused.nextDelay(isPlaying: false, isSystemSuspended: false), equals: nil, "manual pause must not schedule recovery")
    try expect(paused.nextDelay(isPlaying: true, isSystemSuspended: true), equals: nil, "system suspension must not schedule recovery")
}

func testDisplayReconcilerDoesNotRebuildUnchangedScreens() throws {
    try expect(
        DisplayReconciler.action(
            isConnected: true,
            wasConnected: true,
            hasController: true,
            geometryChanged: false,
            currentItemMatches: true,
            expectedItemAvailable: true
        ),
        equals: .keep,
        "an unrelated screen event must keep the existing player"
    )
    try expect(
        DisplayReconciler.action(
            isConnected: true,
            wasConnected: true,
            hasController: true,
            geometryChanged: true,
            currentItemMatches: true,
            expectedItemAvailable: true
        ),
        equals: .updateFrame,
        "a geometry-only change should update the frame without a new player"
    )
    try expect(
        DisplayReconciler.action(
            isConnected: false,
            wasConnected: true,
            hasController: true,
            geometryChanged: false,
            currentItemMatches: true,
            expectedItemAvailable: true
        ),
        equals: .disconnect,
        "a disconnected display releases its playback resources"
    )
    try expect(
        DisplayReconciler.action(
            isConnected: true,
            wasConnected: false,
            hasController: false,
            geometryChanged: false,
            currentItemMatches: false,
            expectedItemAvailable: true
        ),
        equals: .restore,
        "a reconnected display restores only its own player"
    )
    try expect(
        DisplayReconciler.action(
            isConnected: true,
            wasConnected: true,
            hasController: true,
            geometryChanged: false,
            currentItemMatches: true,
            expectedItemAvailable: false
        ),
        equals: .restore,
        "an unavailable current item needs recovery rather than a no-op"
    )
}

func testVideoStreamExitPolicyOnlyLoopsCleanEOF() throws {
    try expect(
        VideoStreamExitPolicy.shouldRestartAfterDrain(
            terminationStatus: 0,
            loops: true,
            emittedFrameCount: 1,
            hasIncompleteTail: false
        ),
        "a clean EOF may loop after its frames are drained"
    )
    try expect(
        !VideoStreamExitPolicy.shouldRestartAfterDrain(
            terminationStatus: 0,
            loops: false,
            emittedFrameCount: 1,
            hasIncompleteTail: false
        ),
        "a clean EOF without looping must complete"
    )
    try expect(
        !VideoStreamExitPolicy.shouldRestartAfterDrain(
            terminationStatus: 1,
            loops: true,
            emittedFrameCount: 1,
            hasIncompleteTail: false
        ),
        "a decoder failure must not restart even when looping is enabled"
    )
    try expect(
        !VideoStreamExitPolicy.shouldRestartAfterDrain(
            terminationStatus: 9,
            loops: true,
            emittedFrameCount: 1,
            hasIncompleteTail: false
        ),
        "a signal-style failure must not restart"
    )
    try expect(
        !VideoStreamExitPolicy.shouldRestartAfterDrain(
            terminationStatus: 0,
            loops: true,
            emittedFrameCount: 0,
            hasIncompleteTail: false
        ),
        "a zero-frame EOF must not create a tight loop"
    )
    try expect(
        !VideoStreamExitPolicy.shouldRestartAfterDrain(
            terminationStatus: 0,
            loops: true,
            emittedFrameCount: 1,
            hasIncompleteTail: true
        ),
        "an incomplete tail must not be treated as a clean loop"
    )
}

func testVideoFrameBufferDeliversFragmentedTailWithoutLoss() throws {
    var buffer = VideoFrameBuffer(frameSize: 6)
    buffer.append(Data([0, 1, 2, 3, 4]))
    try expect(buffer.nextFrame(), equals: nil, "N-1 bytes must not produce a partial frame")
    buffer.append(Data([5]))
    try expect(buffer.nextFrame(), equals: Data([0, 1, 2, 3, 4, 5]), "the last byte must complete the tail frame")

    buffer.append(Data([6, 7, 8, 9, 10, 11, 12]))
    try expect(buffer.nextFrame(), equals: Data([6, 7, 8, 9, 10, 11]), "frames must preserve byte order")
    try expect(buffer.count, equals: 1, "one incomplete trailing byte should remain buffered")
    try expect(buffer.nextFrame(), equals: nil, "an incomplete EOF tail must not be emitted as a frame")
}

func testPlaybackDeadlineMathPreservesRemainingTime() throws {
    let now = Date(timeIntervalSince1970: 100)
    let deadline = Date(timeIntervalSince1970: 125)
    let remaining = PlaybackDeadlineMath.remaining(fireDate: deadline, now: now)
    try expect(remaining, equals: 25, "pausing at t=100 must preserve the t=125 deadline")
    try expect(
        PlaybackDeadlineMath.interval(full: 30, remaining: remaining, resume: true),
        equals: 25,
        "resume must use the saved remaining interval"
    )
    try expect(
        PlaybackDeadlineMath.interval(full: 30, remaining: nil, resume: true),
        equals: 30,
        "a missing snapshot falls back to a full interval"
    )
    let expired = PlaybackDeadlineMath.remaining(fireDate: deadline, now: Date(timeIntervalSince1970: 200))
    try expect(expired, equals: 0, "an expired deadline must clamp to zero")
}

func testPerWallpaperFitOverridePersistsAndLegacyRecordsInherit() throws {
    let fixture = try Fixture()
    let source = fixture.root.appendingPathComponent("photo.png")
    try Data("png".utf8).write(to: source)
    let item = try fixture.store.importItem(at: source, storageMode: .externalReference)
    try expect(item.fitModeOverride, equals: nil, "new items inherit the global fill mode")
    var updated = item
    updated.fitModeOverride = .stretch
    try fixture.store.save(items: [updated])
    let reloaded = try WallpaperStore(libraryURL: fixture.library).items().first
    try expect(reloaded?.fitModeOverride, equals: .stretch, "per-wallpaper override must persist")
    try expect(reloaded?.effectiveFitMode(global: .fit), equals: .stretch, "an explicit override must survive later global changes")
    var inheriting = reloaded
    inheriting?.fitModeOverride = nil
    try expect(inheriting?.effectiveFitMode(global: .tile), equals: .tile, "clearing the override must follow the current global mode")

    let legacyJSON = """
    {"id":"11111111-2222-3333-4444-555555555555","name":"legacy","type":"image","sourceURL":"file:///tmp/old.png","storageMode":"externalReference"}
    """
    let legacy = try JSONDecoder().decode(WallpaperItem.self, from: Data(legacyJSON.utf8))
    try expect(legacy.fitModeOverride, equals: nil, "legacy records without the field keep inheriting the global default")
    try expect(legacy.effectiveFitMode(global: .fill), equals: .fill, "legacy records inherit the global fill default")
}

func testFieldLevelUpdatesPreserveOtherChanges() throws {
    let fixture = try Fixture()
    let source = fixture.root.appendingPathComponent("photo.png")
    try Data("png".utf8).write(to: source)
    let item = try fixture.store.importItem(at: source, storageMode: .externalReference)
    let updated = try fixture.store.updateFitModeOverride(id: item.id, mode: .fit)
    try expect(updated.fitModeOverride, equals: .fit, "field update must persist the override")
    let touched = try fixture.store.touchLastUsed(id: item.id, date: Date(timeIntervalSince1970: 42))
    try expect(touched.fitModeOverride, equals: .fit, "last-used writes must not clobber the override")
    let reloaded = try WallpaperStore(libraryURL: fixture.library).items().first
    try expect(reloaded?.fitModeOverride, equals: .fit, "override must survive a reload")
    try expect(reloaded?.lastUsedAt?.timeIntervalSince1970, equals: 42, "last-used field must survive a reload")
    let cleared = try fixture.store.updateFitModeOverride(id: item.id, mode: nil)
    try expect(cleared.fitModeOverride, equals: nil, "clearing the override must persist")
}

func testFillCoversPortraitViewportOnBothAxes() throws {
    let contentSize = CGSize(width: 1920, height: 1080)
    let viewport = CGRect(x: 0, y: 0, width: 1600, height: 2560)
    let scale = max(viewport.width / contentSize.width, viewport.height / contentSize.height)
    let scaledSize = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
    try expect(scaledSize.width >= viewport.width && scaledSize.height >= viewport.height, "fill must cover both viewport axes")
    try expect(scaledSize.width > viewport.width, "16:9 content in a portrait 16:10 viewport must crop horizontal overflow")

    let sourceContext = CGContext(
        data: nil,
        width: Int(contentSize.width),
        height: Int(contentSize.height),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    sourceContext.setFillColor(NSColor.red.cgColor)
    sourceContext.fill(CGRect(origin: .zero, size: contentSize))
    let sourceImage = sourceContext.makeImage()!

    func render(_ mode: WallpaperFitMode) throws -> NSBitmapImageRep {
        let content = CALayer()
        content.contents = sourceImage
        let presentation = WallpaperLayerLayout.make(
            content: content,
            originalSize: contentSize,
            bounds: viewport,
            mode: mode
        )
        let canvas = CALayer()
        canvas.frame = viewport
        canvas.backgroundColor = NSColor.black.cgColor
        canvas.masksToBounds = true
        canvas.addSublayer(presentation)
        let context = CGContext(
            data: nil,
            width: Int(viewport.width),
            height: Int(viewport.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        canvas.render(in: context)
        return NSBitmapImageRep(cgImage: context.makeImage()!)
    }

    func isRed(_ color: NSColor?) -> Bool {
        guard let color else { return false }
        return color.redComponent > 0.9 && color.greenComponent < 0.1 && color.blueComponent < 0.1
    }
    func isBlack(_ color: NSColor?) -> Bool {
        guard let color else { return false }
        return color.redComponent < 0.1 && color.greenComponent < 0.1 && color.blueComponent < 0.1
    }

    let filled = try render(.fill)
    for (x, y) in [(0, 1280), (1599, 1280), (800, 0), (800, 2559)] {
        try expect(isRed(filled.colorAt(x: x, y: y)), "fill must cover the viewport edge at \(x),\(y)")
    }
    let fitted = try render(.fit)
    try expect(isBlack(fitted.colorAt(x: 800, y: 0)), "fit must preserve the aspect-fit letterbox control")
    try expect(isRed(fitted.colorAt(x: 800, y: 1280)), "fit must still render the complete source in the center")

    let playerLayer = AVPlayerLayer()
    let playerPresentation = WallpaperLayerLayout.make(content: playerLayer, originalSize: contentSize, bounds: viewport, mode: .fill)
    try expect(playerPresentation === playerLayer, "fill should install the original player layer")
    try expect(playerLayer.frame, equals: viewport, "AVPlayerLayer must cover the full portrait viewport")
    try expect(playerLayer.videoGravity, equals: .resizeAspectFill, "AVPlayerLayer fill must use aspect-fill")

    let displayLayer = AVSampleBufferDisplayLayer()
    let displayPresentation = WallpaperLayerLayout.make(content: displayLayer, originalSize: contentSize, bounds: viewport, mode: .fill)
    try expect(displayPresentation === displayLayer, "fill should install the original sample-buffer layer")
    try expect(displayLayer.frame, equals: viewport, "ffmpeg display layer must cover the full portrait viewport")
    try expect(displayLayer.videoGravity, equals: .resizeAspectFill, "ffmpeg fill must use aspect-fill")
}

func testFitModesAndTileLayout() throws {
    try expect(WallpaperFitMode.allCases, equals: [.fill, .fit, .stretch, .tile], "all four fit modes should be exposed")
    try expect(WallpaperFitMode.fill.title, equals: "填充", "fill label")
    try expect(WallpaperFitMode.fit.title, equals: "适应", "fit label")
    try expect(WallpaperFitMode.stretch.title, equals: "拉伸", "stretch label")
    try expect(WallpaperFitMode.tile.title, equals: "平铺", "tile label")
    try expect(WallpaperFitMode.stretch.preservesAspectRatio, equals: false, "stretch may distort the aspect ratio")
    try expect(WallpaperFitMode.tile.preservesAspectRatio, equals: true, "each tile must preserve its own ratio")

    let grid = WallpaperTileLayout.grid(
        originalSize: CGSize(width: 100, height: 50),
        bounds: CGSize(width: 250, height: 120)
    )
    try expect(grid?.columns, equals: 3, "tile columns should cover the width")
    try expect(grid?.rows, equals: 3, "tile rows should cover the height")
    try expect(grid?.tileSize, equals: CGSize(width: 100, height: 50), "tiles must retain native dimensions")

    let retina = WallpaperTileLayout.grid(
        originalSize: CGSize(width: 32, height: 16),
        bounds: CGSize(width: 250, height: 120),
        contentScale: 2
    )
    try expect(retina?.tileSize, equals: CGSize(width: 16, height: 8), "on a 2x screen a pixel-sized tile must use half as many points")
    try expect(retina?.columns, equals: 16, "retina tile columns must be recomputed from point size")
    try expect(retina?.rows, equals: 15, "retina tile rows must be recomputed from point size")

    let huge = WallpaperTileLayout.grid(
        originalSize: CGSize(width: 0.1, height: 0.1),
        bounds: CGSize(width: 2560, height: 1440)
    )
    try expect(huge, equals: nil, "pathological tiny assets must not request an unbounded tile grid")
    let overflowing = WallpaperTileLayout.grid(
        originalSize: CGSize(width: 1e-20, height: 1e-20),
        bounds: CGSize(width: 2560, height: 1440)
    )
    try expect(overflowing, equals: nil, "extreme positive dimensions must return nil instead of overflowing Int")
}

func testPlaybackSchedulingStateSeparatesPauseFromQueueStop() throws {
    let running = PlaybackSchedulingState(
        isQueueEnabled: true,
        isPlaybackWanted: true,
        isSystemSuspended: false,
        isDisplayConnected: true
    )
    try expect(running.shouldSchedule, "an enabled, playing, connected queue should schedule")

    let manuallyPaused = PlaybackSchedulingState(
        isQueueEnabled: true,
        isPlaybackWanted: false,
        isSystemSuspended: false,
        isDisplayConnected: true
    )
    try expect(!manuallyPaused.shouldAdvance, "manual pause must not advance even though the queue stays enabled")

    let systemSuspended = PlaybackSchedulingState(
        isQueueEnabled: true,
        isPlaybackWanted: true,
        isSystemSuspended: true,
        isDisplayConnected: true
    )
    try expect(!systemSuspended.shouldAdvance, "system suspension must not advance or change queue intent")

    let resumed = PlaybackSchedulingState(
        isQueueEnabled: true,
        isPlaybackWanted: true,
        isSystemSuspended: false,
        isDisplayConnected: true
    )
    try expect(resumed.shouldAdvance, "resume should schedule again")

    let disconnected = PlaybackSchedulingState(
        isQueueEnabled: true,
        isPlaybackWanted: true,
        isSystemSuspended: false,
        isDisplayConnected: false
    )
    try expect(!disconnected.shouldAdvance, "a disconnected display must not advance")
}

func testPlaybackIndexReconcilerKeepsCurrentItemAndChoosesSuccessor() throws {
    let a = UUID()
    let b = UUID()
    let c = UUID()
    try expect(
        PlaybackIndexReconciler.reconciledIndex(currentItemID: b, fallbackIndex: 1, remainingIDs: [b, c]),
        equals: 0,
        "removing an earlier member must keep the same current item"
    )
    try expect(
        PlaybackIndexReconciler.reconciledIndex(currentItemID: nil, fallbackIndex: 1, remainingIDs: [a, c]),
        equals: 1,
        "removing the current item must choose its successor"
    )
    try expect(
        PlaybackIndexReconciler.reconciledIndex(currentItemID: nil, fallbackIndex: 2, remainingIDs: [a]),
        equals: 0,
        "removing the last member must clamp to the previous item"
    )
    try expect(
        PlaybackIndexReconciler.reconciledIndex(currentItemID: nil, fallbackIndex: 0, remainingIDs: []),
        equals: 0,
        "an empty queue keeps index zero"
    )
}

func testEmptyModernBindingsDoNotRetireNonEmptyLegacyQueues() throws {
    let fixture = try Fixture()
    try FileManager.default.createDirectory(at: fixture.library, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601

    let wallpaperIDs = [UUID(), UUID()]
    let legacy = DisplayPlaybackQueue(
        displayID: "display-1",
        displayName: "内置屏幕",
        wallpaperIDs: wallpaperIDs,
        intervalSeconds: 45,
        transition: .zoom,
        isEnabled: true,
        currentIndex: 1
    )
    let legacyURL = fixture.library.appendingPathComponent("display-queues.json")
    try encoder.encode([legacy]).write(to: legacyURL)

    // A stale modern queues file with an empty bindings file looks decodable,
    // but it carries none of the legacy display state.
    let modernQueue = PlaybackQueue(name: "现代队列", wallpaperIDs: [])
    try encoder.encode([PlaybackQueue.defaultQueue, modernQueue])
        .write(to: fixture.library.appendingPathComponent("playback-queues.json"))
    try encoder.encode([DisplayPlaybackBinding]())
        .write(to: fixture.library.appendingPathComponent("display-playback-bindings.json"))

    let store = WallpaperStore(libraryURL: fixture.library)
    let queues = try store.playbackQueues()
    let bindings = try store.displayPlaybackBindings()

    try expect(bindings.map(\.displayID), equals: ["display-1"], "empty modern bindings must not retire legacy display state")
    guard let binding = bindings.first else {
        throw TestFailure(message: "re-migrated binding should exist")
    }
    let migratedQueue = queues.first(where: { $0.id == binding.activeQueueID })
    try expect(migratedQueue?.isDefault, equals: false, "migrated binding should reference a non-default queue")
    try expect(migratedQueue?.wallpaperIDs, equals: wallpaperIDs, "migrated queue should preserve legacy membership")
    let state = binding.queueStates[binding.activeQueueID]
    try expect(state?.currentIndex, equals: 1, "migrated binding should preserve progress")
    try expect(state?.isEnabled, equals: true, "migrated binding should preserve enabled state")
    let marker = fixture.library.appendingPathComponent("display-queues.migrated")
    try expect(FileManager.default.fileExists(atPath: marker.path), "regenerated migration should commit")
    try expect(FileManager.default.fileExists(atPath: legacyURL.path) == false, "legacy should be retired only after regeneration")
}

func testModernQueueValidationRequiresCrossReferences() throws {
    let fixture = try Fixture()
    try FileManager.default.createDirectory(at: fixture.library, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601

    let queuesURL = fixture.library.appendingPathComponent("playback-queues.json")
    let bindingsURL = fixture.library.appendingPathComponent("display-playback-bindings.json")
    let queue = PlaybackQueue(name: "单机", wallpaperIDs: [])
    let queueList: [PlaybackQueue] = [PlaybackQueue.defaultQueue, queue]
    try encoder.encode(queueList).write(to: queuesURL)

    // Queues alone without bindings must NOT be treated as a completed migration.
    var store = WallpaperStore(libraryURL: fixture.library)
    _ = try store.playbackQueues()
    let marker = fixture.library.appendingPathComponent("display-queues.migrated")
    try expect(FileManager.default.fileExists(atPath: marker.path) == false, "incomplete modern pair must not commit")

    // Complete the pair with a binding that references the queue; then commit.
    let binding = DisplayPlaybackBinding(
        displayID: "display-1",
        displayName: "内置屏幕",
        activeQueueID: queue.id,
        queueStates: [queue.id: DisplayQueueState(queueID: queue.id)]
    )
    let bindingList: [DisplayPlaybackBinding] = [binding]
    try encoder.encode(bindingList).write(to: bindingsURL)
    store = WallpaperStore(libraryURL: fixture.library)
    _ = try store.playbackQueues()
    try expect(FileManager.default.fileExists(atPath: marker.path), "decodable modern pair without legacy should be marked migrated")
}


// MARK: - Remaining safety fixes (batch 4)

func testWallpaperItemLegacyDecodeUsesSafeFallbacks() throws {
    let legacyJSON = Data("""
    {
      "id": "11111111-2222-3333-4444-555555555555",
      "name": "旧条目",
      "type": "image",
      "sourceURL": "file:///tmp/old.png",
      "storageMode": "externalReference"
    }
    """.utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let item = try decoder.decode(WallpaperItem.self, from: legacyJSON)
    try expect(item.availability, equals: .missing, "legacy items without availability must not look healthy")
    try expect(item.createdAt, equals: .distantPast, "legacy items without createdAt must not sort as newest")
    try expect(item.isFavorite, equals: false, "legacy items default to unfavorited")
}

func testDropURLCollectorPreservesOrderAndDrainsOnce() throws {
    let collector = DropURLCollector(providerCount: 3)
    let a = URL(fileURLWithPath: "/tmp/a.png")
    let c = URL(fileURLWithPath: "/tmp/c.png")

    // Out-of-order completion must still produce drag order.
    collector.submit(c, at: 2)
    try expect(collector.drain() == nil, "partial results must not drain")
    collector.submit(a, at: 0)
    collector.submit(nil, at: 1)  // failed provider
    let first = collector.drain()
    try expect(first, equals: [a, c], "ordered URLs with failures skipped")
    try expect(collector.drain() == nil, "drain happens exactly once")

    let dupe = DropURLCollector(providerCount: 2)
    dupe.submit(a, at: 0)
    dupe.submit(a, at: 1)
    try expect(dupe.drain(), equals: [a], "duplicate URLs collapse keeping first position")
}

// MARK: - Fix review regressions (FixReview-2026-10-27)

func testMigrationKeepsEditedModernPairWhenLegacyResidualExists() throws {
    let fixture = try Fixture()
    try FileManager.default.createDirectory(at: fixture.library, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601

    // Legacy leftover from an old (pre-marker) migration that succeeded.
    let legacy = DisplayPlaybackQueue(
        displayID: "display-1",
        displayName: "旧迁移",
        wallpaperIDs: [UUID()],
        intervalSeconds: 30,
        isEnabled: true,
        currentIndex: 0
    )
    let legacyList: [DisplayPlaybackQueue] = [legacy]
    try encoder.encode(legacyList).write(to: fixture.library.appendingPathComponent("display-queues.json"))

    // Modern pair the user edited after that migration (different queue).
    let editedQueue = PlaybackQueue(name: "用户编辑后", wallpaperIDs: [UUID()])
    let queueList: [PlaybackQueue] = [PlaybackQueue.defaultQueue, editedQueue]
    try encoder.encode(queueList).write(to: fixture.library.appendingPathComponent("playback-queues.json"))
    let binding = DisplayPlaybackBinding(
        displayID: "display-1",
        displayName: "用户编辑后",
        activeQueueID: editedQueue.id,
        queueStates: [editedQueue.id: DisplayQueueState(queueID: editedQueue.id)]
    )
    let bindingList: [DisplayPlaybackBinding] = [binding]
    try encoder.encode(bindingList).write(to: fixture.library.appendingPathComponent("display-playback-bindings.json"))

    let store = WallpaperStore(libraryURL: fixture.library)
    let queues = try store.playbackQueues()
    try expect(
        queues.first(where: { $0.name == "用户编辑后" }) != nil,
        "modern pair must be trusted over legacy residual — user edits must not roll back"
    )
    try expect(
        queues.first(where: { $0.name == "旧迁移" }) == nil,
        "legacy content must not overwrite a validated modern pair"
    )
    let marker = fixture.library.appendingPathComponent("display-queues.migrated")
    try expect(FileManager.default.fileExists(atPath: marker.path), "validated modern pair should commit the marker")
}

func testMigrationResumesFromExistingPlan() throws {
    let fixture = try Fixture()
    try FileManager.default.createDirectory(at: fixture.library, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601

    let queue = PlaybackQueue(name: "计划队列", wallpaperIDs: [UUID()])
    let binding = DisplayPlaybackBinding(
        displayID: "display-9",
        displayName: "计划屏",
        activeQueueID: queue.id,
        queueStates: [queue.id: DisplayQueueState(queueID: queue.id)]
    )
    // Plan left behind by a crash after writing the plan but before outputs.
    struct Plan: Codable { let queues: [PlaybackQueue]; let bindings: [DisplayPlaybackBinding] }
    try encoder.encode(Plan(queues: [PlaybackQueue.defaultQueue, queue], bindings: [binding]))
        .write(to: fixture.library.appendingPathComponent("display-queue-migration-plan.json"))

    let store = WallpaperStore(libraryURL: fixture.library)
    let queues = try store.playbackQueues()
    try expect(queues.contains(where: { $0.id == queue.id }), "plan queue UUIDs must be preserved on resume")
    let bindings = try store.displayPlaybackBindings()
    try expect(bindings.first?.activeQueueID, equals: queue.id, "plan bindings must reference the plan queue IDs")
    let marker = fixture.library.appendingPathComponent("display-queues.migrated")
    try expect(FileManager.default.fileExists(atPath: marker.path), "resume should commit the marker")
    let plan = fixture.library.appendingPathComponent("display-queue-migration-plan.json")
    try expect(FileManager.default.fileExists(atPath: plan.path) == false, "plan file should be cleaned after commit")
}

func testLegacyFlatAssetsMigrateToUUIDFolders() throws {
    let fixture = try Fixture()
    let fm = FileManager.default
    let assets = fixture.library.appendingPathComponent("Assets", isDirectory: true)
    try fm.createDirectory(at: assets, withIntermediateDirectories: true)

    let imageID = UUID()
    let oldImage = assets.appendingPathComponent("\(imageID.uuidString)-photo.png")
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: oldImage)
    let image = WallpaperItem(
        id: imageID,
        name: "legacy-image",
        type: .image,
        sourceURL: oldImage,
        storageMode: .managedCopy
    )

    let webID = UUID()
    let oldSite = assets.appendingPathComponent("\(webID.uuidString)-site", isDirectory: true)
    try fm.createDirectory(at: oldSite, withIntermediateDirectories: true)
    let oldEntry = oldSite.appendingPathComponent("index.html")
    try Data("<html></html>".utf8).write(to: oldEntry)
    let web = WallpaperItem(
        id: webID,
        name: "legacy-site",
        type: .web,
        sourceURL: oldSite,
        entryURL: oldEntry,
        relativeEntryPath: "index.html",
        storageMode: .managedCopy
    )
    try fixture.store.save(items: [image, web])

    let refreshed = try fixture.store.refreshAllAvailability()
    let migratedImage = try require(refreshed.first(where: { $0.id == imageID }), "migrated image should remain indexed")
    let migratedWeb = try require(refreshed.first(where: { $0.id == webID }), "migrated web item should remain indexed")
    let newImage = assets.appendingPathComponent(imageID.uuidString).appendingPathComponent("photo.png")
    let newSite = assets.appendingPathComponent(webID.uuidString).appendingPathComponent("site")
    try expect(migratedImage.sourceURL, equals: newImage, "legacy image should move into its UUID directory")
    try expect(migratedWeb.sourceURL, equals: newSite, "legacy web project should move into its UUID directory")
    try expect(migratedWeb.entryURL, equals: newSite.appendingPathComponent("index.html"), "web entry should follow the migrated project")
    try expect(migratedWeb.relativeEntryPath, equals: "index.html", "relative entry path must be preserved")
    try expect(!fm.fileExists(atPath: oldImage.path), "the old flat image should be moved, not duplicated")
    try expect(!fm.fileExists(atPath: oldSite.path), "the old flat project should be moved, not duplicated")
    try expect(migratedImage.availability, equals: .available, "migrated image should remain playable")
    try expect(migratedWeb.availability, equals: .available, "migrated web project should remain playable")
}

func testRecoveredIndexDoesNotTriggerLayoutMigrationCleanup() throws {
    let fixture = try Fixture()
    let fm = FileManager.default
    let source = fixture.root.appendingPathComponent("indexed.png")
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: source)
    let indexed = try fixture.store.importItem(at: source, storageMode: .managedCopy)
    let assets = fixture.library.appendingPathComponent("Assets", isDirectory: true)
    let orphanID = UUID()
    let oldOrphan = assets.appendingPathComponent("\(orphanID.uuidString)-newer.png")
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: oldOrphan)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode([indexed]).write(to: fixture.library.appendingPathComponent("wallpapers.json.bak"), options: .atomic)
    try fm.removeItem(at: fixture.library.appendingPathComponent("wallpapers.json"))

    _ = try fixture.store.refreshAllAvailability()
    try expect(fm.fileExists(atPath: oldOrphan.path), "an old-layout asset from after the backup must not be deleted during recovery")
    try expect(fm.fileExists(atPath: fixture.library.appendingPathComponent("wallpapers.json.recover").path), "recovery must keep its reconcile marker")
}

func testOrphanCleanupParsesUUIDPrefixPastHyphens() throws {
    let fixture = try Fixture()
    let assets = fixture.library.appendingPathComponent("Assets", isDirectory: true)
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

    let knownID = UUID()
    let knownName = "\(knownID.uuidString)-keep.png"
    let orphanID = UUID()
    let orphanName = "\(orphanID.uuidString)-orphan.png"
    let orphanDirectory = assets.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: orphanDirectory, withIntermediateDirectories: true)
    try Data("new-orphan".utf8).write(to: orphanDirectory.appendingPathComponent("orphan.png"))
    try Data("k".utf8).write(to: assets.appendingPathComponent(knownName))
    try Data("o".utf8).write(to: assets.appendingPathComponent(orphanName))
    // Not UUID-prefixed: must never be deleted.
    let userFile = assets.appendingPathComponent("notes.txt")
    try Data("n".utf8).write(to: userFile)

    let item = WallpaperItem(
        id: knownID,
        name: "keep",
        type: .image,
        sourceURL: assets.appendingPathComponent(knownName),
        storageMode: .managedCopy
    )
    try fixture.store.save(items: [item])
    _ = try fixture.store.refreshAllAvailability()

    let migratedKnown = assets.appendingPathComponent(knownID.uuidString).appendingPathComponent("keep.png")
    try expect(
        FileManager.default.fileExists(atPath: migratedKnown.path),
        "indexed managed asset must survive orphan cleanup after layout migration"
    )
    try expect(
        FileManager.default.fileExists(atPath: assets.appendingPathComponent(orphanName).path) == false,
        "legacy UUID-prefixed asset with no index entry must be removed"
    )
    try expect(
        FileManager.default.fileExists(atPath: orphanDirectory.path) == false,
        "an unindexed UUID directory with no index entry must be removed"
    )
    try expect(
        FileManager.default.fileExists(atPath: userFile.path),
        "non-UUID files in Assets must never be touched"
    )
}

func testStreamingSignatureDigestMatchesOneShot() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WallpaperMacSignatureStreamTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let file = root.appendingPathComponent("large.zip")
    var payload = Data()
    for index in 0..<(2 * 1024 * 1024) {
        payload.append(UInt8(truncatingIfNeeded: index))
    }
    try payload.write(to: file)

    let streamed = try UpdateArtifactVerifier.sha256Digest(ofFileAt: file)
    let oneShot = Data(SHA256.hash(data: payload))
    try expect(streamed, equals: oneShot, "streaming digest must match one-shot SHA-256")

    let privateKey = Curve25519.Signing.PrivateKey()
    let signature = try UpdateSignature.sign(fileAt: file, privateKey: privateKey)
    let ok = try UpdateSignature.verify(
        fileAt: file,
        signatureBase64: signature,
        publicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString()
    )
    try expect(ok, "sign/verify through the streaming path must round trip")
}

// MARK: - Remaining review items

func testProcessRunnerTimesOutAndKillsChild() throws {
    // /bin/sleep ignores SIGTERM in some cases? No — sleep exits on SIGTERM.
    // Use a shell trap to verify the escalate path runs at all.
    let result = try? ProcessRunner.run(
        executableAt: URL(fileURLWithPath: "/bin/sleep"),
        arguments: ["30"],
        timeout: 0.3
    )
    try expect(result == nil, "timed-out processes must throw Failure.timedOut")
    // And a fast process still returns normally.
    let ok = try ProcessRunner.run(
        executableAt: URL(fileURLWithPath: "/usr/bin/true"),
        arguments: [],
        timeout: 5
    )
    try expect(ok.status, equals: 0, "short-lived process should complete normally")
}

func testInstallScriptCleansFullStagingDirectory() throws {
    let script = UpdateInstaller.installScript(
        parentPID: 1,
        sourceAppPath: "/tmp/staging/extracted/WallpaperMac.app",
        targetAppPath: "/Applications/WallpaperMac.app",
        stagingPath: "/tmp/staging"
    )
    try expect(script.contains("STAGING_DIR='/tmp/staging'"), "script should carry the staging root")
    try expect(script.contains("rm -rf \"$STAGING_DIR\""), "success path should remove the entire staging directory")
    try expect(script.contains("WAITED >= 150"), "PID wait should be bounded")
}

func testQueueReorderKeepsDeletedPlaceholders() throws {
    // Simulate the editor's offset translation: visible rows are resolved
    // items only; wallpaperIDs retains placeholders for missing ones.
    let visible1 = UUID()
    let placeholder = UUID()
    let visible2 = UUID()
    var wallpaperIDs = [visible1, placeholder, visible2]

    // "Visible" list is [visible1, visible2]; move visible2 before visible1
    // by visible offsets (1 → 0). After translation the placeholder must
    // remain in the list — not vanish.
    let visibleIDs = [visible1, visible2]
    let wallpaperIndices = visibleIDs.compactMap { id in wallpaperIDs.firstIndex(of: id) }
    try expect(wallpaperIndices, equals: [0, 2], "visible offsets map onto wallpaperIDs slots")

    // Equivalent of Array.move(fromOffsets: [2], toOffset: 0) without the
    // SwiftUI extension (not linked into the Core test runner).
    let moved = wallpaperIDs.remove(at: 2)
    wallpaperIDs.insert(moved, at: 0)

    try expect(wallpaperIDs, equals: [visible2, visible1, placeholder], "reorder preserves the placeholder row")
    try expect(wallpaperIDs.contains(placeholder), "deleted wallpaper IDs survive reordering")
}

func makeTestDisplayIdentity(
    uuid: String? = "UUID-1",
    cgid: UInt32 = 1,
    vendor: UInt32? = 100,
    model: UInt32? = 200,
    serial: UInt32? = 300,
    name: String = "Display",
    pixelWidth: Int = 2560,
    pixelHeight: Int = 1440
) -> DisplayIdentity {
    DisplayIdentity(
        uuid: uuid,
        cgDisplayID: cgid,
        vendorNumber: vendor,
        modelNumber: model,
        serialNumber: serial,
        localizedName: name,
        geometry: DisplayGeometry(
            originX: 0,
            originY: 0,
            width: Double(pixelWidth) / 2,
            height: Double(pixelHeight) / 2,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        ),
        isBuiltIn: false
    )
}

func testDisplayIdentityUsesStableUUID() throws {
    try expect(
        makeTestDisplayIdentity(uuid: "A", cgid: 4).profileID,
        equals: "uuid-A",
        "a present UUID must be the persistent key"
    )
    try expect(
        makeTestDisplayIdentity(uuid: nil, cgid: 7).profileID,
        equals: "cgid-7",
        "a missing UUID falls back to the runtime id"
    )
}

func testDisplayProfileMigrationUsesNamesAcrossSwappedIDs() throws {
    let queueA = UUID()
    let queueB = UUID()
    let identities = [
        makeTestDisplayIdentity(uuid: "A", cgid: 2, name: "Left"),
        makeTestDisplayIdentity(uuid: "B", cgid: 1, name: "Right")
    ]
    let assignments = [
        DisplayAssignment(id: "display-1", displayName: "Right", isConnected: true, wallpaperID: UUID()),
        DisplayAssignment(id: "display-2", displayName: "Left", isConnected: true, wallpaperID: UUID())
    ]
    let bindings = [
        DisplayPlaybackBinding(displayID: "display-1", displayName: "Right", activeQueueID: queueB),
        DisplayPlaybackBinding(displayID: "display-2", displayName: "Left", activeQueueID: queueA)
    ]

    let result = DisplayProfileMigrator.migrate(
        legacyAssignments: assignments,
        legacyBindings: bindings,
        identities: identities,
        now: Date(timeIntervalSince1970: 100)
    )

    let profileA = result.document.profiles.first { $0.profileID == "uuid-A" }
    let profileB = result.document.profiles.first { $0.profileID == "uuid-B" }
    try expect(profileA?.binding?.activeQueueID, equals: queueA, "Left must keep Left's queue even though display-2 is now Left")
    try expect(profileB?.binding?.activeQueueID, equals: queueB, "Right must keep Right's queue even though display-1 is now Right")
    try expect(result.profileIDByLegacyID["display-2"], equals: "uuid-A", "legacy ids must map by name first")
    try expect(result.profileIDByLegacyID["display-1"], equals: "uuid-B", "legacy ids must map by name first")
}

func testDisplayProfileMergeSurvivesRebootIDSwap() throws {
    let queueA = UUID()
    let queueB = UUID()
    let profileA = DisplayProfile(
        profileID: "uuid-A",
        identity: makeTestDisplayIdentity(uuid: "A", cgid: 1, name: "Left"),
        binding: DisplayPlaybackBinding(displayID: "uuid-A", displayName: "Left", activeQueueID: queueA)
    )
    let profileB = DisplayProfile(
        profileID: "uuid-B",
        identity: makeTestDisplayIdentity(uuid: "B", cgid: 2, name: "Right"),
        binding: DisplayPlaybackBinding(displayID: "uuid-B", displayName: "Right", activeQueueID: queueB)
    )
    let document = DisplayProfileDocument(profiles: [profileA, profileB])

    // Reboot: macOS reassigns the runtime IDs, but the physical displays keep
    // their ColorSync UUIDs.
    let afterReboot = [
        makeTestDisplayIdentity(uuid: "A", cgid: 2, name: "Left"),
        makeTestDisplayIdentity(uuid: "B", cgid: 1, name: "Right")
    ]
    let merged = DisplayProfileMigrator.merge(
        document: document,
        identities: afterReboot,
        now: Date(timeIntervalSince1970: 200)
    )

    try expect(merged.profiles.count, equals: 2, "a reboot must not duplicate profiles")
    try expect(
        merged.profiles.first { $0.profileID == "uuid-A" }?.binding?.activeQueueID,
        equals: queueA,
        "display A must keep its queue after the runtime id swaps"
    )
    try expect(
        merged.profiles.first { $0.profileID == "uuid-B" }?.binding?.activeQueueID,
        equals: queueB,
        "display B must keep its queue after the runtime id swaps"
    )
    try expect(
        merged.profiles.first { $0.profileID == "uuid-A" }?.identity.cgDisplayID,
        equals: 2,
        "the identity snapshot should record the new runtime id"
    )
}

func testDisplayProfileMergeMatchesChangedUUIDBySerial() throws {
    let queueID = UUID()
    let document = DisplayProfileDocument(profiles: [
        DisplayProfile(
            profileID: "uuid-OLD",
            identity: makeTestDisplayIdentity(uuid: "OLD", cgid: 1, vendor: 10, model: 20, serial: 777, name: "Monitor"),
            binding: DisplayPlaybackBinding(displayID: "uuid-OLD", displayName: "Monitor", activeQueueID: queueID)
        )
    ])
    let changed = makeTestDisplayIdentity(uuid: "NEW", cgid: 5, vendor: 10, model: 20, serial: 777, name: "Monitor")

    let merged = DisplayProfileMigrator.merge(
        document: document,
        identities: [changed],
        now: Date(timeIntervalSince1970: 300)
    )

    try expect(merged.profiles.count, equals: 1, "a changed UUID with the same hardware must reuse the profile")
    try expect(merged.profiles[0].profileID, equals: "uuid-OLD", "the original stable id must be kept")
    try expect(merged.profiles[0].identity.uuid, equals: "NEW", "the identity should learn the new UUID")
    try expect(merged.profiles[0].binding?.activeQueueID, equals: queueID, "the binding must survive")
}

func testDisplayProfileMergeIgnoresForeignLegacyRecord() throws {
    let ownQueue = UUID()
    let foreignQueue = UUID()
    let document = DisplayProfileDocument(profiles: [
        DisplayProfile(
            profileID: "uuid-A",
            identity: makeTestDisplayIdentity(uuid: "A", cgid: 1, name: "Left"),
            binding: DisplayPlaybackBinding(displayID: "uuid-A", displayName: "Left", activeQueueID: ownQueue)
        )
    ])
    let foreign = DisplayPlaybackBinding(displayID: "display-1", displayName: "Right", activeQueueID: foreignQueue)

    let merged = DisplayProfileMigrator.merge(
        document: document,
        identities: [makeTestDisplayIdentity(uuid: "A", cgid: 1, name: "Left")],
        legacyBindings: [foreign],
        now: Date(timeIntervalSince1970: 400)
    )

    try expect(merged.profiles[0].binding?.activeQueueID, equals: ownQueue, "a legacy record for another display must not override the profile")
    try expect(merged.unmatchedLegacyBindings.map(\.displayID), equals: ["display-1"], "the foreign record should stay unmatched")
}

func testDisplayProfilesRoundTripThroughStore() throws {
    let fixture = try Fixture()
    let identity = makeTestDisplayIdentity(uuid: "A", cgid: 7)
    let document = DisplayProfileDocument(
        profiles: [
            DisplayProfile(
                profileID: "uuid-A",
                identity: identity,
                lastSeenAt: Date(timeIntervalSince1970: 500),
                assignment: DisplayAssignment(
                    id: "uuid-A",
                    displayName: "Display",
                    isConnected: true,
                    wallpaperID: UUID(),
                    applicationState: .applied
                )
            )
        ],
        unmatchedLegacyAssignments: [
            DisplayAssignment(id: "display-9", displayName: "Gone", isConnected: false)
        ]
    )

    try fixture.store.save(displayProfilesDocument: document)
    guard let loaded = try fixture.store.displayProfilesDocument() else {
        throw TestFailure(message: "profiles document should load")
    }
    try expect(loaded, equals: document, "profiles document should round-trip through the store")
}

func testDisplayProfileMergeFillsMissingDataFromOlderLegacy() throws {
    let queueID = UUID()
    let document = DisplayProfileDocument(profiles: [
        DisplayProfile(
            profileID: "uuid-A",
            identity: makeTestDisplayIdentity(uuid: "A", cgid: 1, name: "Left")
        )
    ])
    let legacy = DisplayPlaybackBinding(displayID: "display-1", displayName: "Left", activeQueueID: queueID)

    let merged = DisplayProfileMigrator.merge(
        document: document,
        identities: [makeTestDisplayIdentity(uuid: "A", cgid: 1, name: "Left")],
        legacyBindings: [legacy],
        overwriteBindings: false,
        now: Date(timeIntervalSince1970: 450)
    )

    try expect(
        merged.profiles[0].binding?.activeQueueID,
        equals: queueID,
        "an older legacy file must still fill a profile that has no binding"
    )
}

func testDisplayProfileMergeKeepsNewerProfileData() throws {
    let profileQueue = UUID()
    let staleQueue = UUID()
    let document = DisplayProfileDocument(profiles: [
        DisplayProfile(
            profileID: "uuid-A",
            identity: makeTestDisplayIdentity(uuid: "A", cgid: 1, name: "Left"),
            binding: DisplayPlaybackBinding(displayID: "uuid-A", displayName: "Left", activeQueueID: profileQueue)
        )
    ])
    let older = DisplayPlaybackBinding(displayID: "display-1", displayName: "Left", activeQueueID: staleQueue)

    let merged = DisplayProfileMigrator.merge(
        document: document,
        identities: [makeTestDisplayIdentity(uuid: "A", cgid: 1, name: "Left")],
        legacyBindings: [older],
        overwriteBindings: false,
        now: Date(timeIntervalSince1970: 460)
    )

    try expect(
        merged.profiles[0].binding?.activeQueueID,
        equals: profileQueue,
        "an older legacy file must not replace a profile that already has data"
    )
}

func testHiddenFlagDefaultsAndRoundTrips() throws {
    let fixture = try Fixture()
    let source = fixture.root.appendingPathComponent("hidden.png")
    try Data("png".utf8).write(to: source)
    let item = try fixture.store.importItem(at: source, storageMode: .externalReference)
    try expect(item.isHidden, equals: false, "new wallpapers must be visible")

    var hidden = item
    hidden.isHidden = true
    try fixture.store.save(items: [hidden])
    let reloaded = try WallpaperStore(libraryURL: fixture.library).items().first
    try expect(reloaded?.isHidden, equals: true, "the hidden flag must round-trip")

    let legacyJSON = """
    {"id":"11111111-2222-3333-4444-555555555555","name":"legacy","type":"image","sourceURL":"file:///tmp/old.png","storageMode":"externalReference"}
    """
    let legacy = try JSONDecoder().decode(WallpaperItem.self, from: Data(legacyJSON.utf8))
    try expect(legacy.isHidden, equals: false, "legacy records must default to visible")
}

func testUpdateHiddenPreservesOtherFields() throws {
    let fixture = try Fixture()
    let source = fixture.root.appendingPathComponent("hidden.png")
    try Data("png".utf8).write(to: source)
    var item = try fixture.store.importItem(at: source, storageMode: .externalReference)
    item.fitModeOverride = .fit
    item.isFavorite = true
    item.metadata = WallpaperMetadata(pixelWidth: 1920, pixelHeight: 1080)
    try fixture.store.save(items: [item])

    let updated = try fixture.store.updateHidden(id: item.id, isHidden: true)
    try expect(updated.isHidden, equals: true, "the hidden flag must update")
    try expect(updated.fitModeOverride, equals: .fit, "fit override must survive a hidden update")
    try expect(updated.isFavorite, equals: true, "favorite must survive a hidden update")
    try expect(updated.metadata?.pixelWidth, equals: 1920, "metadata must survive a hidden update")
}

func testPBKDF2KnownVectors() throws {
    let salt = Data("salt".utf8)
    let vectors: [(Int, String)] = [
        (1, "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b"),
        (2, "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43"),
        (4096, "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a")
    ]
    for (iterations, expected) in vectors {
        let derived = HiddenWallpaperLock.derivedKey(
            password: "password",
            salt: salt,
            iterations: iterations,
            keyLength: 32
        )
        try expect(derived.map { String(format: "%02x", $0) }.joined(), equals: expected, "PBKDF2 vector for \(iterations) iterations")
    }
}

func testHiddenWallpaperLockVerification() throws {
    guard let lock = HiddenWallpaperLock.make(password: "correct horse", iterations: 1_000) else {
        throw TestFailure(message: "the lock should be created")
    }
    try expect(lock.verify(password: "correct horse"), "the correct password must verify")
    try expect(!lock.verify(password: "wrong"), "a wrong password must not verify")
    try expect(!lock.verify(password: ""), "an empty password must not verify")
    try expect(!HiddenWallpaperLock.isValidPassword("abc"), "passwords shorter than four bytes are rejected")
    try expect(HiddenWallpaperLock.make(password: "abc") == nil, "short passwords cannot create a lock")

    var tampered = lock
    tampered.hashBase64 = Data(repeating: 0, count: 32).base64EncodedString()
    try expect(!tampered.verify(password: "correct horse"), "a tampered digest must not verify")

    let fixture = try Fixture()
    try fixture.store.save(hiddenWallpaperLock: lock)
    let loaded = try fixture.store.hiddenWallpaperLock()
    try expect(loaded, equals: lock, "the lock must round-trip through the store")
    let attributes = try FileManager.default.attributesOfItem(
        atPath: fixture.library.appendingPathComponent("hidden-wallpapers-lock.json").path
    )
    try expect((attributes[.posixPermissions] as? NSNumber)?.intValue, equals: 0o600, "the lock file must be owner-only")
}

func testWallpaperVisibilityFiltersQueues() throws {
    let hiddenID = UUID()
    let visibleID = UUID()
    let missingID = UUID()
    let unavailableID = UUID()
    let hidden = WallpaperItem(
        id: hiddenID,
        name: "hidden",
        type: .image,
        sourceURL: URL(fileURLWithPath: "/tmp/hidden.png"),
        isHidden: true,
        storageMode: .externalReference
    )
    let visible = WallpaperItem(
        id: visibleID,
        name: "visible",
        type: .image,
        sourceURL: URL(fileURLWithPath: "/tmp/visible.png"),
        storageMode: .externalReference
    )
    var unavailable = visible
    unavailable.availability = .missing
    let items = [hiddenID: hidden, visibleID: visible, unavailableID: unavailable]
    let queue = PlaybackQueue(
        name: "mixed",
        wallpaperIDs: [hiddenID, missingID, visibleID, unavailableID]
    )

    try expect(
        WallpaperVisibility.eligibleIndices(in: queue, items: items, showsHidden: false),
        equals: [2],
        "locked mode must keep only the available visible item"
    )
    try expect(
        WallpaperVisibility.eligibleIndices(in: queue, items: items, showsHidden: true),
        equals: [0, 2],
        "unlocked mode must include available hidden items"
    )
    try expect(
        WallpaperVisibility.isEligible(hidden, showsHidden: false),
        equals: false,
        "a hidden item is not eligible while locked"
    )
    try expect(
        WallpaperVisibility.isEligible(hidden, showsHidden: true),
        equals: true,
        "a hidden item is eligible after unlocking"
    )
}

func testInstalledVersionReadsBundlePlist() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WallpaperMacInstalledVersionTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("WallpaperMac.app")
    try writeMiniApp(at: app, version: "0.2.9", marker: "installed")
    try expect(
        UpdateInstaller.installedVersion(at: app),
        equals: "0.2.9",
        "the updater must read the version from the on-disk bundle"
    )
}

func testUpdateVersionGuardUsesDiskVersion() throws {
    try expect(
        !UpdateInstaller.shouldInstall(updateVersion: "0.2.9", installedVersion: "0.2.9"),
        "an on-disk version equal to the update must not be replaced"
    )
    try expect(
        !UpdateInstaller.shouldInstall(updateVersion: "0.2.9", installedVersion: "0.3.0"),
        "a newer on-disk version must not be downgraded"
    )
    try expect(
        UpdateInstaller.shouldInstall(updateVersion: "0.2.9", installedVersion: "0.2.8"),
        "an older on-disk version should update"
    )
    try expect(
        UpdateInstaller.shouldInstall(updateVersion: "0.2.9", installedVersion: nil),
        "an unreadable version should still allow the update"
    )
}

func testInstallScriptUsesDirectLaunch() throws {
    let fixture = try makeUpdateScriptFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let executable = fixture.sourceApp.appendingPathComponent("Contents/MacOS/WallpaperMac")
    let healthScript = """
    #!/bin/zsh
    TOKEN=""
    ACK=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --update-health-token) TOKEN="$2"; shift 2 ;;
            --update-health-file) ACK="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    if [[ -n "$TOKEN" && -n "$ACK" ]]; then
        printf 'token=%s\\npid=%s\\nversion=9.9.9\\n' "$TOKEN" "$$" > "$ACK"
    fi
    exit 0
    """
    try healthScript.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

    // open fails; only the direct executable launch can provide the health ack.
    let status = try runUpdateScript(fixture, ditto: "/usr/bin/ditto", openStatus: 1, healthWaitSteps: 20)
    try expect(status, equals: 0, "the direct launch should satisfy the health handshake")
    try expect(!FileManager.default.fileExists(atPath: fixture.staging.path), "a direct healthy launch should clean staging")
}

func testFullScreenPauseIsPerDisplay() throws {
    var policy = PlaybackPolicy(pauseInFullScreenApps: true)
    let fullscreen = PlaybackActivityState(
        isOnBattery: false,
        fullScreenDisplayIDs: ["display-a"]
    )
    try expect(
        policy.shouldPauseDynamicWallpaper(displayID: "display-a", activity: fullscreen),
        "the display containing the fullscreen window should pause"
    )
    try expect(
        !policy.shouldPauseDynamicWallpaper(displayID: "display-b", activity: fullscreen),
        "other displays must keep playing during a fullscreen app"
    )

    let battery = PlaybackActivityState(isOnBattery: true)
    policy.pauseOnBattery = true
    try expect(
        policy.shouldPauseDynamicWallpaper(displayID: "display-b", activity: battery),
        "battery policy still applies to every display"
    )
    policy.pauseInFullScreenApps = false
    try expect(
        !policy.shouldPauseDynamicWallpaper(displayID: "display-a", activity: fullscreen),
        "disabling the fullscreen policy must resume every display"
    )
}

func testLibraryMigrationCopiesCompleteLibrary() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WallpaperMacLibraryMigrationTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Old Library", isDirectory: true)
    let destination = root.appendingPathComponent("New Library", isDirectory: true)
    try FileManager.default.createDirectory(
        at: source.appendingPathComponent("Assets", isDirectory: true),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: source.appendingPathComponent("Thumbnails", isDirectory: true),
        withIntermediateDirectories: true
    )
    try Data("[]".utf8).write(to: source.appendingPathComponent("wallpapers.json"))
    try Data("{\"groups\":[]}".utf8).write(to: source.appendingPathComponent("wallpaper-groups.json"))
    try Data("{\"lock\":true}".utf8).write(to: source.appendingPathComponent("hidden-wallpapers-lock.json"))
    try Data("{}".utf8).write(to: source.appendingPathComponent("display-profiles.json"))
    try Data("asset".utf8).write(to: source.appendingPathComponent("Assets/asset.bin"))
    try Data("thumb".utf8).write(to: source.appendingPathComponent("Thumbnails/thumb.png"))

    let result = try WallpaperLibraryMigrator.migrate(from: source, to: destination)

    try expect(FileManager.default.fileExists(atPath: source.path), "migration must preserve the source library")
    try expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("wallpapers.json").path), "the index must be copied")
    try expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("hidden-wallpapers-lock.json").path), "the hidden lock must be copied")
    try expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Assets/asset.bin").path), "managed assets must be copied")
    try expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Thumbnails/thumb.png").path), "thumbnails must be copied")
    try expect(result.fileCount, equals: 6, "all library files should be counted")
    try expect(
        try String(contentsOf: destination.appendingPathComponent("Assets/asset.bin"), encoding: .utf8),
        equals: "asset",
        "copied bytes must match the source"
    )
}

func testLibraryMigrationRebasesResourceURLs() throws {
    let fixture = try Fixture()
    let fm = FileManager.default
    let imageSource = fixture.root.appendingPathComponent("image.png")
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageSource)
    let managedImage = try fixture.store.importItem(at: imageSource, storageMode: .managedCopy)
    let thumbnail = fixture.library.appendingPathComponent("Thumbnails/\(managedImage.id.uuidString).jpg")
    try fm.createDirectory(at: thumbnail.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("thumbnail".utf8).write(to: thumbnail)
    var imageWithThumbnail = managedImage
    imageWithThumbnail.thumbnailURL = thumbnail
    let lockOverride = fixture.library.appendingPathComponent("LockScreen/\(managedImage.id.uuidString).png")
    try fm.createDirectory(at: lockOverride.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("lock".utf8).write(to: lockOverride)
    imageWithThumbnail.lockScreenOverrideURL = lockOverride
    _ = try fixture.store.update(item: imageWithThumbnail)

    let site = fixture.root.appendingPathComponent("site", isDirectory: true)
    try fm.createDirectory(at: site, withIntermediateDirectories: true)
    try Data("<html></html>".utf8).write(to: site.appendingPathComponent("index.html"))
    let managedWeb = try fixture.store.importItem(at: site, storageMode: .managedCopy)

    let externalSource = fixture.root.appendingPathComponent("external.png")
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: externalSource)
    let external = try fixture.store.importItem(at: externalSource, storageMode: .externalReference)
    let externalThumbnail = fixture.root.appendingPathComponent("external-thumb.jpg")
    try Data("external-thumbnail".utf8).write(to: externalThumbnail)
    var externalWithThumbnail = external
    externalWithThumbnail.thumbnailURL = externalThumbnail
    _ = try fixture.store.update(item: externalWithThumbnail)

    let destination = fixture.root.appendingPathComponent("Migrated Library", isDirectory: true)
    _ = try WallpaperLibraryMigrator.migrate(from: fixture.library, to: destination)
    let migratedStore = WallpaperStore(libraryURL: destination)
    let migratedItems = try migratedStore.items()
    let migratedImage = try require(migratedItems.first(where: { $0.id == managedImage.id }), "migrated item should exist")
    let migratedWeb = try require(migratedItems.first(where: { $0.id == managedWeb.id }), "migrated item should exist")
    let migratedExternal = try require(migratedItems.first(where: { $0.id == external.id }), "migrated item should exist")

    try expect(migratedImage.sourceURL.path.hasPrefix(destination.path + "/"), "managed source must move into the new library")
    try expect(migratedImage.thumbnailURL?.path.hasPrefix(destination.appendingPathComponent("Thumbnails").path + "/") == true, "managed thumbnail must move into the new Thumbnails directory")
    try expect(fm.fileExists(atPath: migratedImage.thumbnailURL!.path), "the migrated thumbnail must exist")
    try expect(migratedImage.lockScreenOverrideURL?.path.hasPrefix(destination.appendingPathComponent("LockScreen").path + "/") == true, "custom lock-screen override must move with the library")
    try expect(fm.fileExists(atPath: migratedImage.lockScreenOverrideURL!.path), "the migrated lock-screen override must exist")
    try expect(migratedWeb.entryURL?.path.hasPrefix(destination.path + "/") == true, "managed web entry must move with the copied project")
    try expect(fm.fileExists(atPath: migratedWeb.entryURL!.path), "the migrated web entry must exist")
    try expect(migratedExternal.sourceURL, equals: external.sourceURL, "external source references must not be rewritten")
    try expect(migratedExternal.thumbnailURL, equals: externalThumbnail, "an external thumbnail outside the library must not be rewritten")

    let backupData = try Data(contentsOf: destination.appendingPathComponent("wallpapers.json.bak"))
    let backupDecoder = JSONDecoder()
    backupDecoder.dateDecodingStrategy = .iso8601
    let backupItems = try backupDecoder.decode([WallpaperItem].self, from: backupData)
    let backupImage = try require(backupItems.first(where: { $0.id == managedImage.id }), "backup item should exist")
    try expect(backupImage.thumbnailURL, equals: migratedImage.thumbnailURL, "the backup must receive the same rebased paths")

    // Removing the old library must not invalidate managed playback or the
    // copied thumbnails.
    try fm.removeItem(at: fixture.library)
    let refreshed = try migratedStore.refreshAllAvailability()
    try expect(refreshed.first(where: { $0.id == managedImage.id })?.availability, equals: .available, "managed image remains available after old-library deletion")
    try expect(refreshed.first(where: { $0.id == managedWeb.id })?.availability, equals: .available, "managed web remains available after old-library deletion")
    try expect(fm.fileExists(atPath: migratedImage.thumbnailURL!.path), "thumbnail survives old-library deletion")
}

func testLibraryMigrationPreservesExternalInsideAndBackupOnly() throws {
    let fixture = try Fixture()
    let fm = FileManager.default
    let insideSource = fixture.library.appendingPathComponent("inside.png")
    try fm.createDirectory(at: insideSource.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: insideSource)
    let externalInside = try fixture.store.importItem(at: insideSource, storageMode: .externalReference)
    let insideThumbnail = fixture.library.appendingPathComponent("Thumbnails/\(externalInside.id.uuidString).jpg")
    try fm.createDirectory(at: insideThumbnail.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("inside-thumbnail".utf8).write(to: insideThumbnail)
    var withThumbnail = externalInside
    withThumbnail.thumbnailURL = insideThumbnail
    _ = try fixture.store.update(item: withThumbnail)

    let destination = fixture.root.appendingPathComponent("External Migration", isDirectory: true)
    _ = try WallpaperLibraryMigrator.migrate(from: fixture.library, to: destination)
    let migrated = try WallpaperStore(libraryURL: destination).items()
    let item = try require(migrated.first(where: { $0.id == externalInside.id }), "external item should migrate")
    try expect(item.sourceURL, equals: insideSource, "an external source physically inside the old library must not be rewritten")
    try expect(item.thumbnailURL?.path.hasPrefix(destination.appendingPathComponent("Thumbnails").path + "/") == true, "the app-owned thumbnail inside the old library must move")

    // A backup-only library must stay backup-only after migration, and the
    // backup must be independently rewritten before recovery is attempted.
    let backupOnly = fixture.root.appendingPathComponent("Backup Only Source", isDirectory: true)
    try fm.createDirectory(at: backupOnly, withIntermediateDirectories: true)
    let backupStore = WallpaperStore(libraryURL: backupOnly)
    let backupAsset = fixture.root.appendingPathComponent("backup.png")
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: backupAsset)
    let backupItem = try backupStore.importItem(at: backupAsset, storageMode: .managedCopy)
    try fm.removeItem(at: backupOnly.appendingPathComponent("wallpapers.json"))
    let backupDestination = fixture.root.appendingPathComponent("Backup Only Destination", isDirectory: true)
    _ = try WallpaperLibraryMigrator.migrate(from: backupOnly, to: backupDestination)
    try expect(!fm.fileExists(atPath: backupDestination.appendingPathComponent("wallpapers.json").path), "migration must not invent a primary index for a backup-only library")
    let backupData = try Data(contentsOf: backupDestination.appendingPathComponent("wallpapers.json.bak"))
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let backupItems = try decoder.decode([WallpaperItem].self, from: backupData)
    let migratedBackupItem = try require(backupItems.first, "the backup item should remain decodable")
    try expect(migratedBackupItem.sourceURL.path.hasPrefix(backupDestination.path + "/"), "backup managed source must move to the new library")

    try fm.removeItem(at: backupOnly)
    let recovered = try WallpaperStore(libraryURL: backupDestination).items()
    try expect(recovered.first?.id, equals: backupItem.id, "the rebased backup should recover after the old library is deleted")
    try expect(recovered.first?.sourceURL.path.hasPrefix(backupDestination.path + "/") == true, "recovery must not reintroduce old source paths")
    try expect(fm.fileExists(atPath: backupDestination.appendingPathComponent("wallpapers.json.recover").path), "backup recovery must preserve its reconcile marker")
}

func testLibraryMigrationRejectsUnsafeTargets() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WallpaperMacLibraryMigrationRejectTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Source", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("[]".utf8).write(to: source.appendingPathComponent("wallpapers.json"))

    var samePathRejected = false
    do {
        _ = try WallpaperLibraryMigrator.migrate(from: source, to: source)
    } catch WallpaperLibraryMigrationError.sameLocation {
        samePathRejected = true
    } catch {}
    try expect(samePathRejected, "migrating onto the same path must be rejected")

    var nestedRejected = false
    do {
        _ = try WallpaperLibraryMigrator.migrate(
            from: source,
            to: source.appendingPathComponent("Nested", isDirectory: true)
        )
    } catch WallpaperLibraryMigrationError.destinationInsideSource {
        nestedRejected = true
    } catch {}
    try expect(nestedRejected, "migrating inside the source must be rejected")

    var parentRejected = false
    do {
        _ = try WallpaperLibraryMigrator.migrate(from: source, to: root)
    } catch WallpaperLibraryMigrationError.sourceInsideDestination {
        parentRejected = true
    } catch {}
    try expect(parentRejected, "migrating into a parent of the source must be rejected")

    let nonEmpty = root.appendingPathComponent("NotEmpty", isDirectory: true)
    try FileManager.default.createDirectory(at: nonEmpty, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: nonEmpty.appendingPathComponent("existing.txt"))
    var nonEmptyRejected = false
    do {
        _ = try WallpaperLibraryMigrator.migrate(from: source, to: nonEmpty)
    } catch WallpaperLibraryMigrationError.destinationNotEmpty {
        nonEmptyRejected = true
    } catch {}
    try expect(nonEmptyRejected, "a non-empty destination must be rejected")
    try expect(FileManager.default.fileExists(atPath: source.path), "failed migrations must leave the source intact")
}

func makeQueueSlotItem(id: UUID, hidden: Bool) -> WallpaperItem {
    WallpaperItem(
        id: id,
        name: hidden ? "hidden" : "visible",
        type: .image,
        sourceURL: URL(fileURLWithPath: "/tmp/\(id.uuidString).png"),
        isHidden: hidden,
        storageMode: .externalReference
    )
}

func testQueueKindFollowsHiddenMembership() throws {
    let visible = UUID()
    let hidden = UUID()
    let normalQueue = PlaybackQueue(name: "normal", wallpaperIDs: [visible])
    let hiddenQueue = PlaybackQueue(name: "hidden", wallpaperIDs: [visible, hidden])
    let emptyQueue = PlaybackQueue(name: "empty")
    let items = [
        visible: makeQueueSlotItem(id: visible, hidden: false),
        hidden: makeQueueSlotItem(id: hidden, hidden: true)
    ]

    try expect(normalQueue.kind(items: items), equals: .normal, "a queue without hidden members is a default queue")
    try expect(hiddenQueue.kind(items: items), equals: .hidden, "one hidden member makes the queue a hidden queue")
    try expect(emptyQueue.kind(items: items), equals: .normal, "an empty queue is a default queue")
}

func testQueueSlotResolverMatchesQueueKind() throws {
    let visible = UUID()
    let hidden = UUID()
    let normalQueue = PlaybackQueue(name: "normal", wallpaperIDs: [visible])
    let hiddenQueue = PlaybackQueue(name: "hidden", wallpaperIDs: [hidden])
    let items = [
        visible: makeQueueSlotItem(id: visible, hidden: false),
        hidden: makeQueueSlotItem(id: hidden, hidden: true)
    ]
    let queues = [normalQueue.id: normalQueue, hiddenQueue.id: hiddenQueue]

    try expect(
        QueueSlotResolver.resolve(queueID: normalQueue.id, expected: .normal, queues: queues, items: items),
        equals: normalQueue.id,
        "the default slot accepts a normal queue"
    )
    try expect(
        QueueSlotResolver.resolve(queueID: hiddenQueue.id, expected: .normal, queues: queues, items: items),
        equals: nil,
        "the default slot rejects a hidden queue"
    )
    try expect(
        QueueSlotResolver.resolve(queueID: hiddenQueue.id, expected: .hidden, queues: queues, items: items),
        equals: hiddenQueue.id,
        "the hidden slot accepts a hidden queue"
    )
    try expect(
        QueueSlotResolver.resolve(queueID: normalQueue.id, expected: .hidden, queues: queues, items: items),
        equals: nil,
        "the hidden slot rejects a normal queue"
    )
    try expect(
        QueueSlotResolver.resolve(queueID: nil, expected: .hidden, queues: queues, items: items),
        equals: nil,
        "an empty hidden slot resolves to empty"
    )
}

func testLegacyDisplayBindingDecodesIntoDefaultSlot() throws {
    let activeID = UUID()
    let legacyJSON = """
    {"displayID":"display-1","displayName":"Display","activeQueueID":"\(activeID.uuidString)","queueStates":[]}
    """
    let legacy = try JSONDecoder().decode(DisplayPlaybackBinding.self, from: Data(legacyJSON.utf8))
    try expect(legacy.defaultQueueID, equals: activeID, "legacy active queue becomes the default slot")
    try expect(legacy.hiddenQueueID, equals: nil, "legacy bindings start with an empty hidden slot")
    try expect(legacy.activeQueueID, equals: activeID, "legacy active queue remains readable")

    let hiddenQueue = UUID()
    var updated = legacy
    updated.setQueueID(hiddenQueue, for: .hidden)
    let roundTripped = try JSONDecoder().decode(
        DisplayPlaybackBinding.self,
        from: JSONEncoder().encode(updated)
    )
    try expect(roundTripped, equals: updated, "both queue slots must round-trip")
}
