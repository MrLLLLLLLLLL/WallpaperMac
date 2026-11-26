import Foundation

/// Where Steam login state lives for Workshop downloads.
///
/// - The **username** is persisted in UserDefaults (via the app layer).
/// - The **password is never stored by this app**. SteamCMD keeps its own
///   machine-bound login cache under `steamHomeDirectory` after a successful
///   interactive login; later `+login <user>` runs reuse that cache without
///   prompting. Deleting the home directory (logout) discards it.
/// - Workshop bytes go to a separate per-item staging directory so a failed
///   download never touches the login cache.
public struct SteamSessionConfiguration: Equatable, Sendable {
    public let steamHomeDirectory: URL
    public let steamCMDDirectory: URL

    public init(steamHomeDirectory: URL, steamCMDDirectory: URL) {
        self.steamHomeDirectory = steamHomeDirectory
        self.steamCMDDirectory = steamCMDDirectory
    }

    public static func standard(rootDirectory: URL) -> SteamSessionConfiguration {
        SteamSessionConfiguration(
            steamHomeDirectory: rootDirectory.appendingPathComponent("SteamHome", isDirectory: true),
            steamCMDDirectory: rootDirectory.appendingPathComponent("SteamCMD", isDirectory: true)
        )
    }
}

/// Login / logout commands and state checks for the Steam account used to
/// download Workshop items. Pure logic + filesystem; no UI.
public struct SteamSessionStore: Sendable {
    public static let usernameDefaultsKey = "WallpaperMac.steamWorkshopAccount"

    private let defaults: UserDefaults
    private let fileManager: FileManager

    public init(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.defaults = defaults
        self.fileManager = fileManager
    }

    /// Saved account name, if any. Presence means the user has logged in at
    /// least once; the actual auth token lives in the Steam home directory.
    public var savedUsername: String? {
        let value = defaults.string(forKey: Self.usernameDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// True when a username is saved **and** a live session marker exists.
    /// The marker is written by this app on successful login; SteamCMD's own
    /// `config.vdf`/`ssfn*` cache is accepted as a fallback so a pre-existing
    /// cache still counts. Checking only SteamCMD files is not enough right
    /// after login — SteamCMD may nest them where we do not look yet.
    public func isLoggedIn(configuration: SteamSessionConfiguration) -> Bool {
        guard savedUsername != nil else { return false }
        if hasSessionMarker(in: configuration.steamHomeDirectory) { return true }
        return Self.hasSteamLoginCache(in: configuration.steamHomeDirectory, fileManager: fileManager)
    }

    /// App-owned marker that a login completed for `username` in this home.
    public static let sessionMarkerName = ".wallpapermac-session"

    public func writeSessionMarker(username: String, configuration: SteamSessionConfiguration) {
        let home = configuration.steamHomeDirectory
        try? fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        let url = home.appendingPathComponent(Self.sessionMarkerName)
        try? Data(username.utf8).write(to: url, options: .atomic)
    }

    public func hasSessionMarker(in home: URL) -> Bool {
        fileManager.fileExists(atPath: home.appendingPathComponent(Self.sessionMarkerName).path)
    }

    public func clearSessionMarker(configuration: SteamSessionConfiguration) {
        try? fileManager.removeItem(
            at: configuration.steamHomeDirectory.appendingPathComponent(Self.sessionMarkerName)
        )
    }

    /// SteamCMD writes `config.vdf` / `ssfn*` / `steam.token` style files under
    /// HOME after a successful login. Any of these counts as a live cache.
    public static func hasSteamLoginCache(in home: URL, fileManager: FileManager = .default) -> Bool {
        guard fileManager.fileExists(atPath: home.path) else { return false }
        // config.vdf appears after the first successful authenticated run.
        let config = home.appendingPathComponent("config.vdf")
        if fileManager.fileExists(atPath: config.path) { return true }
        // Fallback: any ssfn* machine auth file at the home root.
        if let entries = try? fileManager.contentsOfDirectory(atPath: home.path) {
            if entries.contains(where: { $0.hasPrefix("ssfn") }) { return true }
            // SteamCMD sometimes nests under .steam or steam.
            for nested in [".steam", "steam", "Steam"] {
                let dir = home.appendingPathComponent(nested)
                if let sub = try? fileManager.contentsOfDirectory(atPath: dir.path),
                   sub.contains(where: { $0.hasPrefix("ssfn") || $0 == "config.vdf" }) {
                    return true
                }
                // Deeper: .steam/steam/config/config.vdf
                let deeper = dir.appendingPathComponent("steam/config/config.vdf")
                if fileManager.fileExists(atPath: deeper.path) { return true }
                let configNested = dir.appendingPathComponent("config/config.vdf")
                if fileManager.fileExists(atPath: configNested.path) { return true }
            }
        }
        return false
    }

    public func saveUsername(_ username: String) {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(trimmed, forKey: Self.usernameDefaultsKey)
    }

    /// Forgets the account and deletes SteamCMD's cached login material.
    /// SteamCMD binaries and workshop staging are left intact.
    public func logout(configuration: SteamSessionConfiguration) {
        defaults.removeObject(forKey: Self.usernameDefaultsKey)
        clearSessionMarker(configuration: configuration)
        let home = configuration.steamHomeDirectory
        guard fileManager.fileExists(atPath: home.path) else { return }
        // Remove only credential-bearing files, not the whole tree, so a
        // partial failure cannot wipe unrelated SteamCMD state.
        let targets = ["config.vdf", "config.vdf.old", "steam.token"]
        for name in targets {
            try? fileManager.removeItem(at: home.appendingPathComponent(name))
        }
        if let entries = try? fileManager.contentsOfDirectory(atPath: home.path) {
            for entry in entries where entry.hasPrefix("ssfn") {
                try? fileManager.removeItem(at: home.appendingPathComponent(entry))
            }
        }
        for nested in [".steam", "steam"] {
            let dir = home.appendingPathComponent(nested)
            if let sub = try? fileManager.contentsOfDirectory(atPath: dir.path) {
                for entry in sub where entry.hasPrefix("ssfn") || entry == "config.vdf" {
                    try? fileManager.removeItem(at: dir.appendingPathComponent(entry))
                }
                let deeper = dir.appendingPathComponent("steam/config/config.vdf")
                try? fileManager.removeItem(at: deeper)
                let nestedConfig = dir.appendingPathComponent("config/config.vdf")
                try? fileManager.removeItem(at: nestedConfig)
            }
        }
    }

    /// Ensures the persistent Steam home exists (SteamCMD needs a writable HOME).
    public func prepareHome(_ configuration: SteamSessionConfiguration) throws {
        try fileManager.createDirectory(
            at: configuration.steamHomeDirectory,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: configuration.steamCMDDirectory,
            withIntermediateDirectories: true
        )
    }
}

/// Pure command builders for SteamCMD login runs.
public enum SteamLoginCommand {
    /// Interactive login: password travels on stdin when SteamCMD prompts.
    /// Uses `-inhibitbootstrap` so a self-update cannot strand the login.
    public static func login(account: String) -> [String] {
        [
            "-inhibitbootstrap",
            "+@ShutdownOnFailedCommand", "1",
            "+login", account,
            "+quit"
        ]
    }

    /// Logout probe is just deleting the cache; no command needed.
    /// A no-op quit used to verify the runtime after install.
    public static func quitProbe() -> [String] {
        ["-inhibitbootstrap", "+quit"]
    }
}
