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
        switch rawType?.lowercased() {
        case "video": return .video
        case "web": return .web
        case "scene": return .scene
        case "application": return .application
        default: return .unknown
        }
    }

    public static func parse(data: Data) throws -> WorkshopProjectManifest {
        let decoder = JSONDecoder()
        // Tolerate trailing commas and unknown keys by decoding leniently:
        // missing fields simply stay nil.
        struct Wire: Decodable {
            let title: String?
            let description: String?
            let type: String?
            let file: String?
            let preview: String?
        }
        let wire = try decoder.decode(Wire.self, from: data)
        return WorkshopProjectManifest(
            title: wire.title,
            description: wire.description,
            rawType: wire.type,
            file: wire.file,
            preview: wire.preview
        )
    }

    public static func parse(at url: URL) throws -> WorkshopProjectManifest {
        let data = try Data(contentsOf: url)
        return try parse(data: data)
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
            guard fileManager.fileExists(atPath: manifestURL.path),
                  let parsed = try? WorkshopProjectManifest.parse(at: manifestURL) else {
                return .unsupported(.unknownType(nil))
            }
            resolvedManifest = parsed
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
            guard let file = resolvedManifest.file, !file.isEmpty else {
                return .unsupported(.missingEntryFile("project.json 中的 file 字段"))
            }
            let source = resolveEntry(file, in: directory)
            guard fileManager.fileExists(atPath: source.path) else {
                return .unsupported(.entryFileMissingOnDisk(file))
            }
            guard WallpaperType.detect(from: source, fileManager: fileManager) == .video else {
                return .unsupported(.unknownType(resolvedManifest.rawType))
            }
            return .video(sourceURL: source, title: title)
        case .web:
            guard let file = resolvedManifest.file, !file.isEmpty else {
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

    /// Entry paths in project.json are relative and may use backslashes from
    /// Windows-authored projects. Reject traversal outside the project root,
    /// including escapes via symlinks inside the project.
    public static func resolveEntry(_ file: String, in directory: URL) -> URL {
        let normalized = file.replacingOccurrences(of: "\\", with: "/")
        let root = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let candidate = directory.appendingPathComponent(normalized).standardizedFileURL
        let resolved = candidate.resolvingSymlinksInPath()
        let resolvedPath = resolved.path
        if resolvedPath == root || resolvedPath.hasPrefix(root + "/") {
            return candidate
        }
        // Traversal escaped the root: point at a path that cannot exist so the
        // existence check fails closed.
        return directory.appendingPathComponent(".invalid-entry")
    }
}
