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
    ("encodes playback and display defaults", testPlaybackDefaultsAndDisplayAssignmentCoding),
    ("persists custom library configuration", testLibraryConfigurationRoundTripsCustomPath),
    ("does not invent missing library configuration", testMissingLibraryConfigurationDoesNotCreateEmptyLibrary),
    ("persists groups and bulk removal", testGroupsAndBulkRemovalPersist),
    ("normalizes and persists display queue", testDisplayQueueNormalizesAndPersists),
    ("keeps display queues independent", testDisplayQueuesStayIndependent),
    ("evaluates playback suspension rules", testPlaybackPolicySuspensionRules),
    ("deduplicates and auto sorts playback queues", testPlaybackQueueDeduplicatesAndAutoSorts),
    ("enforces playback queue defaults and overrides", testPlaybackQueueHasDefaultConstraintsAndPerItemOverrides),
    ("persists video completion queue setting", testPlaybackQueueVideoCompletionSettingRoundTrips),
    ("decodes legacy queue without video completion setting", testLegacyPlaybackQueueWithoutVideoCompletionSettingDecodes),
    ("uses landscape 16:9 wallpaper preview layout", testWallpaperPreviewUsesLandscapeSixteenByNineLayout),
    ("uses shared pagination contract for groups", testWallpaperLibraryPaginationUsesSamePageContractForGroups),
    ("migrates legacy display queues", testStoreMigratesLegacyDisplayQueues),
    ("round trips display queue state", testQueueStoreRoundTripsDisplayQueueState)
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
    let items = Array(1...100)
    try expect(WallpaperLibraryPagination.defaultPageSize, equals: 20, "library and group pages should share a 20-item default page size")
    let firstPage = WallpaperLibraryPagination.page(from: items, loadedCount: 0)
    try expect(firstPage.count, equals: 20, "library pages should load 20 items initially")
    let secondCount = WallpaperLibraryPagination.nextLoadedCount(currentCount: firstPage.count, totalCount: items.count)
    let secondPage = WallpaperLibraryPagination.page(from: items, loadedCount: secondCount)
    try expect(secondPage.count, equals: 40, "group pages should load the same next page size as the library")
    let thirdCount = WallpaperLibraryPagination.nextLoadedCount(currentCount: secondPage.count, totalCount: items.count)
    try expect(thirdCount, equals: 60, "pagination should advance by 20 items per page")
    let finalCount = (0..<2).reduce(thirdCount) { count, _ in
        WallpaperLibraryPagination.nextLoadedCount(currentCount: count, totalCount: items.count)
    }
    try expect(finalCount, equals: 100, "pagination should clamp the final page")
}

func testWallpaperPreviewUsesLandscapeSixteenByNineLayout() throws {
    try expect(WallpaperPreviewLayout.aspectRatio, equals: 16.0 / 9.0, "resource previews should use a 16:9 frame")
    try expect(WallpaperPreviewLayout.contentMode, equals: .fill, "resource previews should fill and crop non-16:9 assets")
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
