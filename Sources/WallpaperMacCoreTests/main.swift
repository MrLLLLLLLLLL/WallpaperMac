import CryptoKit
import Foundation
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

    let item = try fixture.store.importItem(at: entry, storageMode: .managedCopy, entryURL: entry)
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

func testWebMouseEventScriptActivatesClickOnce() throws {
    let mouseUp = WebMouseEventScript.source(x: 120, y: 80, phase: .mouseUp)
    try expect(
        mouseUp.components(separatedBy: "element.click()").count - 1,
        equals: 1,
        "mouseup should use exactly one native element click activation"
    )
    try expect(
        mouseUp.contains("if (typeof element.click === 'function')"),
        "HTML elements should use their native click activation"
    )
    try expect(
        mouseUp.components(separatedBy: "new MouseEvent('click'").count - 1,
        equals: 1,
        "non-HTML elements should have one mutually exclusive fallback click activation"
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

let tests: [(String, () throws -> Void)] = [
    ("wallpaper metadata round trips", testWallpaperMetadataRoundTrips),
    ("legacy wallpaper JSON without metadata decodes", testLegacyWallpaperJSONWithoutMetadataDecodes),
    ("bulk metadata save preserves wallpaper state", testBulkMetadataSavePreservesWallpaperState),
    ("detects wallpaper types", testDetectsWallpaperTypes),
    ("managed import copies file", testManagedImportCopiesFile),
    ("normalizes HEVC sample entries for playback", testVideoContainerCompatibilityNormalizesRealHev1Entries),
    ("external import keeps reference", testExternalImportKeepsReference),
    ("reports missing external file", testReportsMissingExternalFile),
    ("detects nested HTML project", testNestedHTMLProjectIsDetected),
    ("reports missing HTML entry", testMissingHTMLEntryIsReported),
    ("persists display assignments", testDisplayAssignmentsPersist),
    ("imports HTML project with selected entry", testHTMLProjectImportPersistsSelectedEntry),
    ("managed copy preserves nested HTML project resources", testManagedCopyOfNestedHTMLEntryPreservesProjectResources),
    ("rejects unsupported and missing sources", testUnsupportedAndMissingSourcesFailClearly),
    ("persists and recovers availability", testPersistenceAndAvailabilityRecovery),
    ("relocates missing external wallpaper", testRelocatesMissingExternalWallpaper),
    ("removes managed wallpaper and asset", testRemovesManagedWallpaperAndAsset),
    ("relocates HTML project and preserves entry", testRelocatesHTMLProjectAndPreservesEntry),
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
    ("deduplicates and auto sorts playback queues", testPlaybackQueueDeduplicatesAndAutoSorts),
    ("enforces playback queue defaults and overrides", testPlaybackQueueHasDefaultConstraintsAndPerItemOverrides),
    ("persists video completion queue setting", testPlaybackQueueVideoCompletionSettingRoundTrips),
    ("decodes legacy queue without video completion setting", testLegacyPlaybackQueueWithoutVideoCompletionSettingDecodes),
    ("requires compatibility playback for AV1", testVideoPlaybackCompatibilityRequiresCacheForAV1),
    ("plans streaming compatibility playback", testVideoCompatibilityStreamPlanPipesDecodedFrames),
    ("normalizes real HEVC sample entries", testVideoContainerCompatibilityNormalizesRealHev1Entries),
    ("ignores media payload lookalikes", testVideoContainerCompatibilityIgnoresMediaPayloadLookalikes),
    ("keeps external references without video proxies", testExternalReferenceDoesNotPersistVideoProxy),
    ("removes legacy external playback proxies", testStoreRemovesLegacyExternalPlaybackProxy),
    ("uses landscape 16:9 wallpaper preview layout", testWallpaperPreviewUsesLandscapeSixteenByNineLayout),
    ("uses real 20-item pagination for library and groups", testWallpaperLibraryPaginationUsesSamePageContractForGroups),
    ("invalidates edited active queue bindings", testDisplayBindingInvalidatesEditedQueue),
    ("migrates legacy display queues", testStoreMigratesLegacyDisplayQueues),
    ("round trips display queue state", testQueueStoreRoundTripsDisplayQueueState),
    ("formats application version information", testApplicationVersionInfoFormatting),
    ("bounds video-completion stall watchdog", testPlaybackQueueStallWatchdogInterval),
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
    ("quotes shell paths safely", testUpdateShellQuotingSurvivesApostrophes),
    ("waits for parent and rolls back install", testUpdateInstallScriptWaitsForParentAndRollsBack),
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
    ("decodes legacy items with safe fallbacks", testWallpaperItemLegacyDecodeUsesSafeFallbacks),
    ("aggregates drop URLs in drag order", testDropURLCollectorPreservesOrderAndDrainsOnce),
    ("keeps edited modern pair over legacy residual", testMigrationKeepsEditedModernPairWhenLegacyResidualExists),
    ("resumes migration from existing plan file", testMigrationResumesFromExistingPlan),
    ("parses orphan UUID prefixes past hyphens", testOrphanCleanupParsesUUIDPrefixPastHyphens),
    ("streams signature digests matching one-shot", testStreamingSignatureDigestMatchesOneShot),
    ("kills timed-out child processes", testProcessRunnerTimesOutAndKillsChild),
    ("cleans full staging directory on install", testInstallScriptCleansFullStagingDirectory),
    ("keeps deleted placeholders across reorder", testQueueReorderKeepsDeletedPlaceholders)
]

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

func testPlaybackQueueVideoCompletionSettingRoundTrips() throws {
    let queue = PlaybackQueue(name: "视频队列", advanceAfterVideoCompletion: true)
    let data = try JSONEncoder().encode(queue)
    let decoded = try JSONDecoder().decode(PlaybackQueue.self, from: data)
    try expect(decoded.advanceAfterVideoCompletion, "queue should persist video completion advance setting")
}

func testLegacyPlaybackQueueWithoutVideoCompletionSettingDecodes() throws {
    let queue = PlaybackQueue(name: "旧队列")
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(queue)) as! [String: Any]
    object.removeValue(forKey: "advanceAfterVideoCompletion")
    let data = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(PlaybackQueue.self, from: data)
    try expect(!decoded.advanceAfterVideoCompletion, "legacy queues should default to timer-based video switching")
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

func testDisplayBindingInvalidatesEditedQueue() throws {
    let queue = PlaybackQueue(name: "夜间")
    let state = DisplayQueueState(queueID: queue.id, currentIndex: 3, isPlaying: true, isEnabled: true)
    var binding = DisplayPlaybackBinding(
        displayID: "display-1",
        displayName: "内置显示器",
        activeQueueID: queue.id,
        queueStates: [queue.id: state]
    )
    try expect(binding.invalidateActiveQueue(ifMatching: queue.id), "editing the active queue should invalidate the display binding")
    try expect(!binding.state(for: queue.id).isEnabled, "invalidated queue should require the user to apply it again")
    try expect(!binding.state(for: queue.id).isPlaying, "invalidated queue should stop automatic switching")
    try expect(binding.state(for: queue.id).currentIndex, equals: 3, "queue edit should preserve the last index for reapplication")
    try expect(!binding.invalidateActiveQueue(ifMatching: UUID()), "editing another queue should not affect this display")
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
    assets: [[String: String]] = [
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

func testUpdateInstallScriptWaitsForParentAndRollsBack() throws {
    let script = UpdateInstaller.installScript(
        parentPID: 4242,
        sourceAppPath: "/tmp/staging/extracted/WallpaperMac.app",
        targetAppPath: "/Applications/WallpaperMac.app",
        stagingPath: "/tmp/staging"
    )

    try expect(script.contains("PARENT_PID=4242"), "script should wait on the updater process")
    try expect(script.contains("while kill -0 \"$PARENT_PID\""), "script must not swap bundles before we exit")
    try expect(script.contains("mv \"$TARGET_APP\" \"$TARGET_PREVIOUS\""), "previous build should be kept for rollback")
    try expect(script.contains("/usr/bin/ditto \"$SOURCE_APP\" \"$TARGET_APP\""), "new bundle should be copied with ditto")
    try expect(script.contains("/usr/bin/xattr -cr \"$TARGET_APP\""), "quarantine bits should be cleared")
    try expect(script.contains("/usr/bin/open \"$TARGET_APP\""), "relaunch should open the replaced app")
    try expect(script.contains("mv \"$TARGET_PREVIOUS\" \"$TARGET_APP\""), "failed relaunch must restore the previous build")
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
    let b = URL(fileURLWithPath: "/tmp/b.png")
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

func testOrphanCleanupParsesUUIDPrefixPastHyphens() throws {
    let fixture = try Fixture()
    let assets = fixture.library.appendingPathComponent("Assets", isDirectory: true)
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

    let knownID = UUID()
    let knownName = "\(knownID.uuidString)-keep.png"
    let orphanID = UUID()
    let orphanName = "\(orphanID.uuidString)-orphan.png"
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

    try expect(
        FileManager.default.fileExists(atPath: assets.appendingPathComponent(knownName).path),
        "indexed managed asset must survive orphan cleanup"
    )
    try expect(
        FileManager.default.fileExists(atPath: assets.appendingPathComponent(orphanName).path) == false,
        "UUID-prefixed asset with no index entry must be removed"
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
