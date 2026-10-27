import Foundation

public enum UpdateInstallError: Error, Equatable, Sendable, LocalizedError {
    case notAnApplicationBundle
    case appTranslocated
    case unwritableInstallLocation(String)
    case versionMismatch(expected: String, found: String)
    case unzipFailed(String)
    case scriptFailed(String)
    case alreadyInstalling

    public var errorDescription: String? {
        switch self {
        case .notAnApplicationBundle:
            return "当前运行的不是标准 .app 壁纸程序，无法自动更新"
        case .appTranslocated:
            return "应用处于系统隔离路径，请先将 WallpaperMac 拖到“应用程序”文件夹后再更新"
        case .unwritableInstallLocation(let path):
            return "安装位置不可写：\(path)"
        case .versionMismatch(let expected, let found):
            return "安装包版本不匹配（期望 \(expected)，实际 \(found)）"
        case .unzipFailed(let message):
            return "解压更新包失败：\(message)"
        case .scriptFailed(let message):
            return "安装脚本执行失败：\(message)"
        case .alreadyInstalling:
            return "已有安装流程正在进行"
        }
    }
}

/// Validated, ready-to-install payload on disk.
public struct PreparedUpdateInstall: Equatable, Sendable {
    /// The extracted `WallpaperMac.app` inside the staging directory.
    public let appBundleURL: URL
    /// Version read from the prepared bundle's Info.plist.
    public let version: String
    /// Absolute path of the currently running app that will be replaced.
    public let targetAppURL: URL
    public let stagingDirectory: URL

    public init(appBundleURL: URL, version: String, targetAppURL: URL, stagingDirectory: URL) {
        self.appBundleURL = appBundleURL
        self.version = version
        self.targetAppURL = targetAppURL
        self.stagingDirectory = stagingDirectory
    }
}

/// Preflight checks, zip extraction, and the detached swap/relaunch handoff.
///
/// The running process never deletes its own bundle. A short shell script
/// waits for this PID to exit, moves the previous app aside, copies the new
/// bundle in place, clears quarantine, and relaunches.
public enum UpdateInstaller {
    /// Everything needed before any bytes are written to the install location.
    public static func preflight(
        runningAppURL: URL = Bundle.main.bundleURL,
        fileManager: FileManager = .default
    ) throws {
        guard runningAppURL.pathExtension == "app" else {
            throw UpdateInstallError.notAnApplicationBundle
        }
        // App Translocation runs the bundle from a randomized read-only path.
        if runningAppURL.path.contains("/AppTranslocation/") {
            throw UpdateInstallError.appTranslocated
        }
        let parent = runningAppURL.deletingLastPathComponent()
        guard fileManager.isWritableFile(atPath: parent.path) else {
            throw UpdateInstallError.unwritableInstallLocation(parent.path)
        }
    }

    /// Extracts the release zip and confirms the payload is a WallpaperMac
    /// bundle carrying the version we expect to install.
    public static func prepare(
        zipFileURL: URL,
        expectedVersion: String,
        stagingDirectory: URL,
        targetAppURL: URL = Bundle.main.bundleURL,
        fileManager: FileManager = .default
    ) throws -> PreparedUpdateInstall {
        try preflight(runningAppURL: targetAppURL, fileManager: fileManager)

        let extractDir = stagingDirectory.appendingPathComponent("extracted", isDirectory: true)
        try? fileManager.removeItem(at: extractDir)
        try fileManager.createDirectory(at: extractDir, withIntermediateDirectories: true)

        let result: ProcessRunner.Result
        do {
            result = try ProcessRunner.run(
                executableAt: URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: ["-x", "-k", zipFileURL.path, extractDir.path],
                timeout: 120
            )
        } catch let error as ProcessRunner.Failure {
            throw UpdateInstallError.unzipFailed(error.localizedDescription)
        }
        if result.status != 0 {
            throw UpdateInstallError.unzipFailed(
                result.stderrTail.isEmpty ? "ditto exited \(result.status)" : result.stderrTail
            )
        }

        let bundleURL = try locateAppBundle(in: extractDir, fileManager: fileManager)
        let version = try bundleVersion(at: bundleURL)
        guard version == expectedVersion else {
            throw UpdateInstallError.versionMismatch(expected: expectedVersion, found: version)
        }

        return PreparedUpdateInstall(
            appBundleURL: bundleURL,
            version: version,
            targetAppURL: targetAppURL,
            stagingDirectory: stagingDirectory
        )
    }

    /// Spawns the detached installer script and returns once it is running.
    /// The caller should quit the application immediately afterwards.
    public static func launchDetachedInstall(
        of prepared: PreparedUpdateInstall,
        currentProcessID: Int32 = ProcessInfo.processInfo.processIdentifier,
        fileManager: FileManager = .default
    ) throws {
        let scriptURL = prepared.stagingDirectory.appendingPathComponent("install.sh")
        let script = installScript(
            parentPID: currentProcessID,
            sourceAppPath: prepared.appBundleURL.path,
            targetAppPath: prepared.targetAppURL.path,
            stagingPath: prepared.stagingDirectory.path
        )
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: scriptURL.path
            )
        } catch {
            throw UpdateInstallError.scriptFailed(error.localizedDescription)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptURL.path]
        // Detach from us entirely: no pipes, no inherited console coupling.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw UpdateInstallError.scriptFailed(error.localizedDescription)
        }
    }

    // MARK: - Script

    /// Generated installer. Kept as plain shell so it survives the app going
    /// away mid-update and can be inspected in the staging directory.
    public static func installScript(
        parentPID: Int32,
        sourceAppPath: String,
        targetAppPath: String,
        stagingPath: String
    ) -> String {
        """
        #!/bin/zsh
        set -euo pipefail

        PARENT_PID=\(parentPID)
        SOURCE_APP=\(shellQuote(sourceAppPath))
        TARGET_APP=\(shellQuote(targetAppPath))
        STAGING_DIR=\(shellQuote(stagingPath))
        TARGET_PREVIOUS="${TARGET_APP}.previous"

        # Wait for the running app to exit before touching its bundle.
        # Bounded so PID reuse cannot strand the installer forever.
        WAITED=0
        while kill -0 "$PARENT_PID" 2>/dev/null; do
            sleep 0.2
            WAITED=$((WAITED + 1))
            if (( WAITED >= 150 )); then
                # 30s: either the app is stuck or the PID was recycled.
                if ! ps -p "$PARENT_PID" -o comm= 2>/dev/null | grep -q WallpaperMac; then
                    break
                fi
                echo "install aborted: parent process $PARENT_PID still running" >&2
                exit 2
            fi
        done

        # Keep the outgoing build around long enough to restore it if the
        # replacement fails to launch.
        rm -rf "$TARGET_PREVIOUS"
        if [[ -d "$TARGET_APP" ]]; then
            mv "$TARGET_APP" "$TARGET_PREVIOUS"
        fi

        if ! /usr/bin/ditto "$SOURCE_APP" "$TARGET_APP"; then
            if [[ -d "$TARGET_PREVIOUS" ]]; then
                mv "$TARGET_PREVIOUS" "$TARGET_APP"
            fi
            exit 1
        fi

        # In-app downloads are not quarantined; clear anyway so a restored
        # bundle never trips Gatekeeper after a partial transfer.
        /usr/bin/xattr -cr "$TARGET_APP" 2>/dev/null || true

        if /usr/bin/open "$TARGET_APP"; then
            # Clean staging after a successful swap; keep it on failure paths.
            rm -rf "$STAGING_DIR"
            # Leave .previous behind for one generation as a manual rollback
            # handle; the next successful install removes it.
            exit 0
        fi

        # Relaunch failed: restore the previous build and surface the failure.
        rm -rf "$TARGET_APP"
        if [[ -d "$TARGET_PREVIOUS" ]]; then
            mv "$TARGET_PREVIOUS" "$TARGET_APP"
            /usr/bin/open "$TARGET_APP" || true
        fi
        exit 1
        """
    }

    // MARK: - Helpers

    public static func locateAppBundle(
        in directory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let direct = directory.appendingPathComponent("WallpaperMac.app", isDirectory: true)
        if fileManager.fileExists(atPath: direct.path) {
            return direct
        }
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw UpdateInstallError.unzipFailed("无法枚举解压目录")
        }
        for case let candidate as URL in enumerator where candidate.pathExtension == "app" {
            return candidate
        }
        throw UpdateInstallError.unzipFailed("更新包中未找到 WallpaperMac.app")
    }

    static func bundleVersion(at appBundleURL: URL) throws -> String {
        let infoURL = appBundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = FileManager.default.contents(atPath: infoURL.path),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any],
              let version = dictionary["CFBundleShortVersionString"] as? String,
              !version.isEmpty else {
            throw UpdateInstallError.unzipFailed("无法读取更新包版本号")
        }
        return version
    }

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
