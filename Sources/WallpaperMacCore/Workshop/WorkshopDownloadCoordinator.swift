import Foundation

/// End-to-end orchestration for one workshop import: resolve link → metadata
/// → (optional) SteamCMD install → download → plan import.
/// All steps are injectable so tests can drive the flow without Steam.
public actor WorkshopDownloadCoordinator {
    public enum Phase: Equatable, Sendable {
        case resolving
        case fetchingMetadata
        case metadataReady(WorkshopMetadata)
        case unsupported(WorkshopUnsupportedReason)
        case preparingSteamCMD
        case installingSteamCMD(SteamCMDInstaller.State)
        case downloading(status: String?, fraction: Double?)
        case planning
        case ready(WorkshopImportPlan)
        case failed(String)
    }

    public struct Context: Sendable {
        /// Application Support/WallpaperMac — SteamCMD and staging live under it.
        public let rootDirectory: URL
        public let credentials: SteamCMDSession.Credentials?

        public init(rootDirectory: URL, credentials: SteamCMDSession.Credentials?) {
            self.rootDirectory = rootDirectory
            self.credentials = credentials
        }

        public var steamCMDDirectory: URL {
            rootDirectory.appendingPathComponent("SteamCMD", isDirectory: true)
        }

        public var stagingDirectory: URL {
            rootDirectory.appendingPathComponent("SteamWorkshop", isDirectory: true)
        }

        /// Persistent SteamCMD HOME so a successful login survives per-item
        /// staging cleanup (see SteamSessionStore).
        public var steamHomeDirectory: URL {
            rootDirectory.appendingPathComponent("SteamHome", isDirectory: true)
        }

        public var sessionConfiguration: SteamSessionConfiguration {
            SteamSessionConfiguration(
                steamHomeDirectory: steamHomeDirectory,
                steamCMDDirectory: steamCMDDirectory
            )
        }
    }

    private let metadataClient: WorkshopMetadataClient
    private let installer: SteamCMDInstaller
    private let fileManager: FileManager

    public init(
        metadataClient: WorkshopMetadataClient = WorkshopMetadataClient(),
        installer: SteamCMDInstaller = SteamCMDInstaller(),
        fileManager: FileManager = .default
    ) {
        self.metadataClient = metadataClient
        self.installer = installer
        self.fileManager = fileManager
    }

    /// Parses and validates the pasted text, then fetches metadata.
    /// Returns nil when the text is not a workshop link at all.
    public func resolveAndFetch(rawLink: String) async throws -> WorkshopMetadata? {
        guard let link = WorkshopLink.parse(rawLink) else { return nil }
        return try await metadataClient.fetch(itemID: link.itemID)
    }

    /// Ensures a usable steamcmd exists under the context root, installing
    /// from Valve's manifest when missing.
    public func ensureSteamCMD(
        context: Context,
        onState: (@Sendable (SteamCMDInstaller.State) -> Void)? = nil
    ) async throws -> URL {
        if let existing = SteamCMDInstaller.executable(in: context.steamCMDDirectory) {
            return existing
        }
        try fileManager.createDirectory(at: context.steamCMDDirectory, withIntermediateDirectories: true)
        return try await installer.install(to: context.steamCMDDirectory, onState: onState)
    }

    /// Downloads one item and returns the import plan. Throws on Steam/network
    /// failures; returns `.unsupported` plans for type rejections so the UI can
    /// show a precise reason without treating it as an error.
    public func downloadAndPlan(
        itemID: String,
        context: Context,
        onPhase: (@Sendable (Phase) -> Void)? = nil
    ) async throws -> WorkshopImportPlan {
        // itemID becomes a directory name; digits only, never traversal.
        guard itemID.allSatisfy({ $0.isASCII && $0.isNumber }),
              itemID.count >= 6, itemID.count <= 20 else {
            throw SteamCMDFailure.itemUnavailable
        }
        guard let credentials = context.credentials else {
            throw SteamCMDSession.SessionError.launchFailed("缺少 Steam 登录凭据")
        }

        onPhase?(.preparingSteamCMD)
        let executable = try await ensureSteamCMD(context: context) { state in
            onPhase?(.installingSteamCMD(state))
        }

        // Fresh staging per item so a previous partial cannot masquerade.
        // Login cache lives in the persistent Steam home, NOT here — a failed
        // download must not discard a valid session, and a successful one
        // must not leave workshop bytes next to credentials.
        let stagingRoot = context.stagingDirectory
            .appendingPathComponent(itemID, isDirectory: true)
        if fileManager.fileExists(atPath: stagingRoot.path) {
            try? fileManager.removeItem(at: stagingRoot)
        }
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: context.steamHomeDirectory, withIntermediateDirectories: true)

        let command = SteamCMDCommand(
            account: credentials.username,
            itemID: itemID,
            forceInstallDirectory: stagingRoot.path
        )

        let environment: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": context.steamHomeDirectory.path,
            "TMPDIR": stagingRoot.appendingPathComponent("tmp").path,
            "TERM": "dumb",
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8"
        ]
        try fileManager.createDirectory(
            at: stagingRoot.appendingPathComponent("tmp"),
            withIntermediateDirectories: true
        )

        onPhase?(.downloading(status: "启动 SteamCMD…", fraction: nil))
        let session = SteamCMDSession(executable: executable)
        let result: SteamCMDSession.Result
        do {
            result = try await session.run(
                command: command,
                credentials: credentials,
                environment: environment,
                workingDirectory: stagingRoot
            ) { progress in
                onPhase?(.downloading(status: progress.status, fraction: progress.fraction))
            }
        } catch {
            // Drop partial workshop bytes; the Steam home keeps any login.
            try? fileManager.removeItem(at: stagingRoot)
            throw error
        }

        if let failure = result.failure {
            try? fileManager.removeItem(at: stagingRoot)
            throw failure
        }
        guard let downloaded = result.downloadedDirectory else {
            try? fileManager.removeItem(at: stagingRoot)
            throw SteamCMDFailure.loggedInButDownloadFailed("未找到下载内容")
        }

        onPhase?(.planning)
        let plan = WorkshopImportPlanner.plan(directory: downloaded, fileManager: fileManager)

        if !plan.isSupported {
            try? fileManager.removeItem(at: stagingRoot)
        }
        return plan
    }

    /// Removes the per-item staging folder after a successful library import.
    public func cleanupStaging(itemID: String, context: Context) {
        let stagingRoot = context.stagingDirectory.appendingPathComponent(itemID, isDirectory: true)
        try? fileManager.removeItem(at: stagingRoot)
    }

    /// Reads `project.json` when the plan needs a manifest (already inside planner).
    public static func defaultRootDirectory(fileManager: FileManager = .default) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("WallpaperMac", isDirectory: true)
    }
}
