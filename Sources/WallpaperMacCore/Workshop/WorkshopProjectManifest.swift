import Foundation

/// The `project.json` at the root of every Wallpaper Engine workshop item.
/// This is the authoritative type check after download; tags only pre-filter.
public struct WorkshopProjectManifest: Equatable, Sendable, Codable {
    public let title: String?
    public let description: String?
    /// Raw `type` field: "video" | "web" | "scene" | "application".
    public let rawType: String?
    /// Entry file relative to the project root (`Aurora.mp4`, `index.html`).
    public let file: String?
    public let preview: String?

    private struct Wire: Decodable {
        let title: String?
        let description: String?
        let type: String?
        let file: String?
        let preview: String?
    }

    public init(
        title: String? = nil,
        description: String? = nil,
        rawType: String? = nil,
        file: String? = nil,
        preview: String? = nil
    ) {
        self.title = title
        self.description = description
        self.rawType = rawType
        self.file = file
        self.preview = preview
    }

    public var kind: WorkshopKind {
        // Authors write "Web", "VIDEO", "Application"; Steam's own wire
        // format is capitalized. Compare case-insensitively.
        switch rawType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "video": return .video
        case "web": return .web
        case "scene": return .scene
        case "application": return .application
        default: return .unknown
        }
    }

    public static func parse(data: Data) throws -> WorkshopProjectManifest {
        // Wallpaper Engine authors hand-edit project.json; tolerate trailing
        // commas, // and /* */ comments, BOM, and unknown keys. Missing fields
        // simply stay nil.
        let wire: Wire
        do {
            wire = try JSONDecoder().decode(Wire.self, from: data)
        } catch {
            guard let sanitized = Self.lenientJSONData(data) else { throw error }
            wire = try JSONDecoder().decode(Wire.self, from: sanitized)
        }
        return WorkshopProjectManifest(
            title: wire.title?.trimmedOrNil,
            description: wire.description?.trimmedOrNil,
            rawType: wire.type?.trimmedOrNil,
            file: wire.file?.trimmedOrNil,
            preview: wire.preview?.trimmedOrNil
        )
    }

    /// Strips a UTF-8 BOM, `//`/`/* */` comments, and trailing commas so
    /// hand-authored manifests still parse with the standard decoder.
    static func lenientJSONData(_ data: Data) -> Data? {
        var text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        var out = ""
        out.reserveCapacity(text.utf8.count)
        var index = text.startIndex
        var inString = false
        var inLineComment = false
        var inBlockComment = false
        while index < text.endIndex {
            let char = text[index]
            let nextIndex = text.index(after: index)
            let next = nextIndex < text.endIndex ? text[nextIndex] : nil
            if inLineComment {
                if char == "\n" { inLineComment = false; out.append(char) }
                index = nextIndex
                continue
            }
            if inBlockComment {
                if char == "*", next == "/" {
                    inBlockComment = false
                    index = text.index(after: nextIndex)
                    continue
                }
                index = nextIndex
                continue
            }
            if inString {
                out.append(char)
                if char == "\\" {
                    if let next { out.append(next); index = text.index(after: nextIndex); continue }
                } else if char == "\"" {
                    inString = false
                }
                index = nextIndex
                continue
            }
            if char == "\"" {
                inString = true
                out.append(char)
                index = nextIndex
                continue
            }
            if char == "/", next == "/" {
                inLineComment = true
                index = text.index(after: nextIndex)
                continue
            }
            if char == "/", next == "*" {
                inBlockComment = true
                index = text.index(after: nextIndex)
                continue
            }
            if char == ",", next == "}" || next == "]" {
                // Trailing comma: skip the comma, keep the closing brace.
                index = nextIndex
                continue
            }
            out.append(char)
            index = nextIndex
        }
        // Only hand back a rewritten payload when it now parses as JSON;
        // a partially truncated file must still fail closed.
        guard (try? JSONSerialization.jsonObject(with: Data(out.utf8))) != nil else {
            return nil
        }
        return Data(out.utf8)
    }

    public static func parse(at url: URL) throws -> WorkshopProjectManifest {
        let data = try Data(contentsOf: url)
        return try parse(data: data)
    }
}

private extension String {
    /// Trims whitespace/newlines and returns nil for empty values so an
    /// empty `"file": ""` behaves like an absent field.
    var trimmedOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// What the importer should do with a downloaded workshop folder.
public enum WorkshopImportPlan: Equatable, Sendable {
    /// Copy the single video file into the library as a managed asset.
    case video(sourceURL: URL, title: String)
    /// Copy the project directory as a web wallpaper with the given entry.
    case webProject(directory: URL, entryFile: String, title: String)
    case unsupported(WorkshopUnsupportedReason)

    public var isSupported: Bool {
        switch self {
        case .video, .webProject: return true
        case .unsupported: return false
        }
    }

    /// Workshop title when it should replace the importer's filename-based name.
    public var titleOverride: String? {
        switch self {
        case .video(_, let title), .webProject(_, _, let title):
            return title.isEmpty ? nil : title
        case .unsupported:
            return nil
        }
    }
}

public enum WorkshopImportPlanner {
    /// Plans the import for a downloaded workshop item directory.
    /// `manifest` is read from `<directory>/project.json` when not supplied.
    public static func plan(
        directory: URL,
        manifest: WorkshopProjectManifest? = nil,
        fileManager: FileManager = .default
    ) -> WorkshopImportPlan {
        let resolvedManifest: WorkshopProjectManifest
        if let manifest {
            resolvedManifest = manifest
        } else {
            let manifestURL = directory.appendingPathComponent("project.json")
            if fileManager.fileExists(atPath: manifestURL.path),
               let parsed = try? WorkshopProjectManifest.parse(at: manifestURL) {
                resolvedManifest = parsed
            } else {
                // No (or unparseable) project.json: infer from content so a
                // lone video or a conventional web project still imports.
                return inferPlan(for: directory, fileManager: fileManager)
            }
        }

        let title = (resolvedManifest.title?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? directory.lastPathComponent

        switch resolvedManifest.kind {
        case .scene:
            return .unsupported(.scene)
        case .application:
            return .unsupported(.application)
        case .unknown:
            return .unsupported(.unknownType(resolvedManifest.rawType))
        case .video:
            let declared = resolvedManifest.file
            let file = resolveVideoEntry(manifest: resolvedManifest, directory: directory, fileManager: fileManager)
            guard let file else {
                // No `file` and no video on disk at all.
                return .unsupported(.missingEntryFile("project.json 中的 file 字段"))
            }
            let source = resolveEntry(file, in: directory)
            guard fileManager.fileExists(atPath: source.path) else {
                // Prefer the declared name in the error so the user sees
                // exactly which path project.json pointed at.
                return .unsupported(.entryFileMissingOnDisk(declared ?? file))
            }
            guard WallpaperType.detect(from: source, fileManager: fileManager) == .video else {
                return .unsupported(.unknownType(resolvedManifest.rawType))
            }
            return .video(sourceURL: source, title: title)
        case .web:
            let file = resolveWebEntry(manifest: resolvedManifest, directory: directory, fileManager: fileManager)
            guard let file else {
                return .unsupported(.missingEntryFile("project.json 中的 file 字段"))
            }
            let entry = resolveEntry(file, in: directory)
            guard fileManager.fileExists(atPath: entry.path) else {
                return .unsupported(.entryFileMissingOnDisk(file))
            }
            guard WallpaperType.detect(from: directory, fileManager: fileManager) == .web else {
                return .unsupported(.unknownType(resolvedManifest.rawType))
            }
            return .webProject(directory: directory, entryFile: file, title: title)
        }
    }

    /// Plans an import for a folder without a usable project.json: a lone
    /// video file, or a directory containing HTML, imports by convention.
    /// Anything else stays rejected as unknown.
    private static func inferPlan(
        for directory: URL,
        fileManager: FileManager = .default
    ) -> WorkshopImportPlan {
        let title = directory.lastPathComponent
        if let video = firstVideoFile(in: directory, fileManager: fileManager),
           let source = Optional(resolveEntry(video, in: directory)),
           fileManager.fileExists(atPath: source.path) {
            return .video(sourceURL: source, title: title)
        }
        if WallpaperType.detect(from: directory, fileManager: fileManager) == .web,
           let html = firstHTMLFile(in: directory, fileManager: fileManager) {
            return .webProject(directory: directory, entryFile: html, title: title)
        }
        return .unsupported(.unknownType(nil))
    }

    /// `file` for a video project: the declared path when it exists on disk,
    /// otherwise the first video file in the tree (case- and `./`-tolerant).
    private static func resolveVideoEntry(
        manifest: WorkshopProjectManifest,
        directory: URL,
        fileManager: FileManager = .default
    ) -> String? {
        if let declared = manifest.file, !declared.isEmpty {
            let resolved = resolveEntry(declared, in: directory)
            if fileManager.fileExists(atPath: resolved.path) {
                return declared
            }
            // Declared entry missing: only fall back to a discovered video
            // when the folder actually contains one, so the caller can still
            // report `entryFileMissingOnDisk` for a true typo in `file`.
            // Prefer an existing video on disk; if none, return the declared
            // name so the caller reports `entryFileMissingOnDisk(declared)`.
            return firstVideoFile(in: directory, fileManager: fileManager) ?? declared
        }
        return firstVideoFile(in: directory, fileManager: fileManager)
    }

    /// `file` for a web project: the declared path when it exists on disk,
    /// otherwise common entry names or the first HTML in the tree, otherwise
    /// the declared path (so the caller can report `entryFileMissingOnDisk`).
    private static func resolveWebEntry(
        manifest: WorkshopProjectManifest,
        directory: URL,
        fileManager: FileManager = .default
    ) -> String? {
        if let declared = manifest.file, !declared.isEmpty {
            let resolved = resolveEntry(declared, in: directory)
            if fileManager.fileExists(atPath: resolved.path) {
                return declared
            }
        }
        for candidate in ["index.html", "main.html", "index.htm", "default.html", "wallpaper.html"] {
            let resolved = resolveEntry(candidate, in: directory)
            if fileManager.fileExists(atPath: resolved.path) {
                return candidate
            }
        }
        if let discovered = firstHTMLFile(in: directory, fileManager: fileManager) {
            return discovered
        }
        // Nothing on disk: keep the declared name so the error names the
        // path project.json actually pointed at.
        return manifest.file
    }

    private static func firstVideoFile(in directory: URL, fileManager: FileManager) -> String? {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm", "avi", "mkv"]
        var found: [String] = []
        for case let candidate as URL in enumerator {
            guard (try? candidate.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true,
                  videoExtensions.contains(candidate.pathExtension.lowercased()) else { continue }
            let relative = relativePath(of: candidate, to: directory)
            found.append(relative)
        }
        return found.sorted().first
    }

    private static func firstHTMLFile(in directory: URL, fileManager: FileManager) -> String? {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var found: [String] = []
        for case let candidate as URL in enumerator {
            guard (try? candidate.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true,
                  ["html", "htm"].contains(candidate.pathExtension.lowercased()) else { continue }
            found.append(relativePath(of: candidate, to: directory))
        }
        return found.sorted().first
    }

    private static func relativePath(of url: URL, to base: URL) -> String {
        let basePath = base.standardizedFileURL.path
        let fullPath = url.standardizedFileURL.path
        guard fullPath.hasPrefix(basePath + "/") else { return url.lastPathComponent }
        return String(fullPath.dropFirst(basePath.count + 1))
    }

    /// Entry paths in project.json are relative and may use backslashes from
    /// Windows-authored projects (`.\index.html`, `pages\home.html`). They are
    /// matched case-insensitively on disk because workshop content is authored
    /// on case-insensitive Windows volumes. Reject traversal outside the
    /// project root, including escapes via symlinks inside the project.
    public static func resolveEntry(_ file: String, in directory: URL) -> URL {
        let rawNormalized = file.replacingOccurrences(of: "\\", with: "/")
        // Explicit `..` segments are never legitimate in a workshop manifest;
        // reject them before any trimming so `./../../etc/passwd` cannot be
        // laundered into a root-relative path.
        guard !rawNormalized.split(separator: "/").contains("..") else {
            return directory.appendingPathComponent(".invalid-entry")
        }
        let normalized = rawNormalized
            .trimmingCharacters(in: CharacterSet(charactersIn: "./"))
            // Collapse duplicate separators so "pages//home.html" still maps.
            .replacingOccurrences(of: "//", with: "/")
        guard !normalized.isEmpty else {
            return directory.appendingPathComponent(".invalid-entry")
        }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let candidate = directory.appendingPathComponent(normalized).standardizedFileURL
        let resolved = candidate.resolvingSymlinksInPath()
        let resolvedPath = resolved.path
        if resolvedPath == root || resolvedPath.hasPrefix(root + "/") {
            return candidate
        }
        // Case-insensitive fallback: walk each path component and resolve it
        // against the real directory listing, so "Index.HTML" finds
        // "index.html" without ever leaving the project root. Every resolved
        // path is re-checked after symlink resolution so a link inside the
        // project cannot smuggle an outside file back in.
        var current = directory.standardizedFileURL.resolvingSymlinksInPath()
        for component in normalized.split(separator: "/") {
            let child = current.appendingPathComponent(String(component))
            if fileManagerExists(child) { current = child.standardizedFileURL; continue }
            let match = try? FileManager.default.contentsOfDirectory(atPath: current.path)
                .first { $0.caseInsensitiveCompare(String(component)) == .orderedSame }
            guard let match else {
                // Unresolvable component: point at a path that cannot exist so
                // the existence check fails closed.
                return directory.appendingPathComponent(".invalid-entry")
            }
            current = current.appendingPathComponent(match).standardizedFileURL
        }
        let caseResolvedPath = current.resolvingSymlinksInPath().path
        if caseResolvedPath == root || caseResolvedPath.hasPrefix(root + "/") {
            return current
        }
        return directory.appendingPathComponent(".invalid-entry")
    }

    private static func fileManagerExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
