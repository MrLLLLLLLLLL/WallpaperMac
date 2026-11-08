import Foundation
import Darwin

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
/// The running process never deletes its own bundle. A detached shell script
/// waits for this PID to exit, builds and verifies a complete sibling, then
/// uses RENAME_SWAP to exchange old/new bundles without a target-path gap.
/// A failed relaunch swaps the previous generation back into place.
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
        installLock: UpdateInstallLock? = nil,
        fileManager: FileManager = .default
    ) throws {
        let scriptURL = prepared.stagingDirectory.appendingPathComponent("install.sh")
        let script = installScript(
            parentPID: currentProcessID,
            sourceAppPath: prepared.appBundleURL.path,
            targetAppPath: prepared.targetAppURL.path,
            stagingPath: prepared.stagingDirectory.path,
            expectedVersion: prepared.version,
            lockPath: installLock?.lockURL.path,
            lockToken: installLock?.ownerToken
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
        if let installLock {
            process.standardInput = installLock.fileHandle
        }
        // Detach from us entirely: no pipes, no inherited console coupling.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw UpdateInstallError.scriptFailed(error.localizedDescription)
        }
    }

    /// Verifies that the inherited descriptor is the same lock inode and that
    /// its current owner token matches this transaction. Runs in the existing
    /// Swift helper so installation does not depend on Python or another tool.
    public static func verifyInheritedLock(
        lockURL: URL,
        expectedToken: String
    ) throws {
        var inherited = stat()
        var lockFile = stat()
        guard fstat(0, &inherited) == 0,
              stat(lockURL.path, &lockFile) == 0,
              inherited.st_dev == lockFile.st_dev,
              inherited.st_ino == lockFile.st_ino else {
            throw UpdateInstallError.scriptFailed("更新锁描述符不匹配")
        }
        guard let data = FileManager.default.contents(atPath: lockURL.path),
              let text = String(data: data, encoding: .utf8),
              text.split(whereSeparator: \.isNewline).first.map(String.init) == expectedToken else {
            throw UpdateInstallError.scriptFailed("更新锁所有者不匹配")
        }
    }

    // MARK: - Script

    /// Atomically exchanges two complete app bundles on the same filesystem.
    /// Unlike two sequential `mv` calls, RENAME_SWAP never leaves the standard
    /// application path missing between the old and new generations.
    public static func atomicSwap(
        pendingAppURL: URL,
        targetAppURL: URL,
        fileManager: FileManager = .default
    ) throws {
        guard pendingAppURL.pathExtension == "app",
              targetAppURL.pathExtension == "app",
              pendingAppURL.deletingLastPathComponent().standardizedFileURL
                == targetAppURL.deletingLastPathComponent().standardizedFileURL else {
            throw UpdateInstallError.scriptFailed("更新交换要求同目录的两个 .app Bundle")
        }
        guard fileManager.fileExists(atPath: pendingAppURL.path),
              fileManager.fileExists(atPath: targetAppURL.path) else {
            throw UpdateInstallError.scriptFailed("交换前后的 App 必须同时存在")
        }
        if renamex_np(pendingAppURL.path, targetAppURL.path, UInt32(RENAME_SWAP)) != 0 {
            throw UpdateInstallError.scriptFailed(
                "原子交换失败：\(String(cString: strerror(errno)))"
            )
        }
    }

    /// Generated installer. Kept as plain shell so it survives the app going
    /// away mid-update and can be inspected in the staging directory.
    public static func installScript(
        parentPID: Int32,
        sourceAppPath: String,
        targetAppPath: String,
        stagingPath: String,
        expectedVersion: String? = nil,
        lockPath: String? = nil,
        lockToken: String? = nil
    ) -> String {
        """
        #!/bin/zsh
        set -euo pipefail

        PARENT_PID=\(parentPID)
        SOURCE_APP=\(shellQuote(sourceAppPath))
        TARGET_APP=\(shellQuote(targetAppPath))
        STAGING_DIR=\(shellQuote(stagingPath))
        EXPECTED_VERSION=\(shellQuote(expectedVersion ?? ""))
        DITTO="${WALLPAPERMAC_DITTO:-/usr/bin/ditto}"
        OPEN="${WALLPAPERMAC_OPEN:-/usr/bin/open}"
        XATTR="${WALLPAPERMAC_XATTR:-/usr/bin/xattr}"
        CODESIGN="${WALLPAPERMAC_CODESIGN:-/usr/bin/codesign}"
        LOCK_PATH=\(shellQuote(lockPath ?? ""))
        LOCK_TOKEN=\(shellQuote(lockToken ?? ""))
        SWAPPER="${WALLPAPERMAC_UPDATE_SWAPPER:-$TARGET_APP/Contents/MacOS/WallpaperMac}"
        TARGET_PREVIOUS="${TARGET_APP}.previous"
        TARGET_PENDING="${TARGET_APP}.installing.$$"
        BACKUP_APP="$TARGET_PENDING"
        SWAPPED=0
        SWAP_STARTED=0

        restore_previous() {
            if (( SWAPPED == 1 )) && [[ -d "$BACKUP_APP" ]]; then
                ROLLBACK_SWAPPER="${WALLPAPERMAC_UPDATE_SWAPPER:-$BACKUP_APP/Contents/MacOS/WallpaperMac}"
                if ! "$ROLLBACK_SWAPPER" --update-swap "$BACKUP_APP" "$TARGET_APP"; then
                    echo "rollback swap failed; preserving the backup for manual recovery" >&2
                    return 1
                fi
                "$OPEN" "$TARGET_APP" || true
                SWAPPED=0
            fi
        }
        finish() {
            STATUS=$?
            set +e
            if (( STATUS != 0 )); then
                restore_previous
            fi
            # A failed rollback may still have its only complete old app in
            # pending. Never delete that backup in the EXIT cleanup.
            if (( SWAPPED == 0 && SWAP_STARTED == 0 )); then
                rm -rf "$TARGET_PENDING"
            fi
            exit $STATUS
        }
        trap finish EXIT
        trap 'exit 1' INT TERM HUP
        fail() {
            echo "$1" >&2
            exit 1
        }
        verify_lock() {
            if [[ -n "$LOCK_PATH" ]]; then
                [[ -f "$LOCK_PATH" ]] || fail "update lock is missing"
                "$SWAPPER" --update-lock-check "$LOCK_PATH" "$LOCK_TOKEN" || fail "update lock verification failed"
                [[ "$(head -n 1 "$LOCK_PATH")" == "$LOCK_TOKEN" ]] || fail "update lock ownership mismatch"
            fi
        }

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

        # Build the complete replacement beside the target while the known-good
        # app remains in place. A partial copy never becomes the target.
        verify_lock
        rm -rf "$TARGET_PENDING"
        if ! "$DITTO" "$SOURCE_APP" "$TARGET_PENDING"; then
            fail "unable to copy the replacement app"
        fi
        PENDING_PLIST="$TARGET_PENDING/Contents/Info.plist"
        [[ -f "$PENDING_PLIST" ]] || fail "replacement Info.plist is missing"
        /usr/bin/plutil -lint "$PENDING_PLIST" >/dev/null || fail "replacement Info.plist is invalid"
        if [[ -n "$EXPECTED_VERSION" ]]; then
            ACTUAL_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PENDING_PLIST" 2>/dev/null || true)"
            [[ "$ACTUAL_VERSION" == "$EXPECTED_VERSION" ]] || fail "replacement version mismatch: $ACTUAL_VERSION"
        fi
        EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PENDING_PLIST" 2>/dev/null || true)"
        [[ -n "$EXECUTABLE_NAME" && -x "$TARGET_PENDING/Contents/MacOS/$EXECUTABLE_NAME" ]] || fail "replacement executable is missing"
        "$CODESIGN" --verify --deep --strict "$TARGET_PENDING" || fail "replacement signature verification failed"
        [[ -x "$SWAPPER" ]] || fail "update swap helper is unavailable"

        # RENAME_SWAP exchanges the complete old and new apps atomically. The
        # standard target path never disappears, even if the machine loses power.
        verify_lock
        rm -rf "$TARGET_PREVIOUS"
        SWAP_STARTED=1
        if ! "$SWAPPER" --update-swap "$TARGET_PENDING" "$TARGET_APP"; then
            fail "atomic replacement failed"
        fi
        SWAPPED=1
        BACKUP_APP="$TARGET_PENDING"
        if mv "$TARGET_PENDING" "$TARGET_PREVIOUS"; then
            BACKUP_APP="$TARGET_PREVIOUS"
        fi

        # In-app downloads are not quarantined; clear anyway so a restored
        # bundle never trips Gatekeeper after a partial transfer.
        "$XATTR" -cr "$TARGET_APP" 2>/dev/null || true

        HEALTH_TOKEN="$(/usr/bin/uuidgen)"
        HEALTH_ACK="$STAGING_DIR/update-health-$HEALTH_TOKEN"
        HEALTH_WAIT_STEPS="${WALLPAPERMAC_HEALTH_WAIT_STEPS:-50}"
        if "$OPEN" -n "$TARGET_APP" --args \
            --update-health-token "$HEALTH_TOKEN" \
            --update-health-file "$HEALTH_ACK"; then
            HEALTHY=0
            for (( HEALTH_STEP=0; HEALTH_STEP < HEALTH_WAIT_STEPS; HEALTH_STEP++ )); do
                if [[ -f "$HEALTH_ACK" ]] \
                    && /usr/bin/grep -q "^token=$HEALTH_TOKEN$" "$HEALTH_ACK" \
                    && /usr/bin/grep -Eq '^pid=[0-9]+$' "$HEALTH_ACK"; then
                    if [[ -z "$EXPECTED_VERSION" ]] || /usr/bin/grep -q "^version=$EXPECTED_VERSION$" "$HEALTH_ACK"; then
                        HEALTHY=1
                        break
                    fi
                fi
                sleep 0.2
            done
            if (( HEALTHY == 1 )); then
                # Clean staging only after the new instance has completed its
                # critical initialization and acknowledged this exact install.
                rm -rf "$STAGING_DIR" || true
                exit 0
            fi
            # Do not kill an unrelated existing instance. Only a process still
            # carrying this install's token is a failed new launch.
            # Match the executable path and token as literal strings. Paths
            # containing regex characters must still be cleaned up correctly.
            TARGET_APP_FOR_CLEANUP="$TARGET_APP/Contents/MacOS/WallpaperMac"
            export TARGET_APP_FOR_CLEANUP HEALTH_TOKEN
            NEW_PID="$(ps -axo pid,command | /usr/bin/awk 'index($0, ENVIRON["TARGET_APP_FOR_CLEANUP"]) && index($0, ENVIRON["HEALTH_TOKEN"]) { print $1; exit }' | head -1 || true)"
            [[ -z "$NEW_PID" ]] || kill "$NEW_PID" 2>/dev/null || true
            fail "replacement did not become healthy"
        fi
        fail "replacement failed to launch"
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
