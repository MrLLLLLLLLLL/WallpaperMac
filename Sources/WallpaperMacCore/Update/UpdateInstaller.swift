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

    /// Reads the version from the app bundle on disk. `Bundle.main` may still
    /// hold the version of a process that was launched before the bundle was
    /// replaced, so the installer must not trust the in-memory copy alone.
    public static func installedVersion(at appURL: URL) -> String? {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ) as? [String: Any],
              let version = plist["CFBundleShortVersionString"] as? String else {
            return nil
        }
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether an update still needs to be installed. A running process may
    /// report an older version than the bundle that is already on disk.
    public static func shouldInstall(updateVersion: String, installedVersion: String?) -> Bool {
        guard let installedVersion,
              let installed = SemVer(string: installedVersion),
              let target = SemVer(string: updateVersion) else {
            return true
        }
        return installed < target
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

    /// Spawns the detached installer script and waits until it reports that it
    /// is alive. The caller should quit the application only after this returns;
    /// if the script cannot start, the app stays open and the error is shown.
    public static func launchDetachedInstall(
        of prepared: PreparedUpdateInstall,
        currentProcessID: Int32 = ProcessInfo.processInfo.processIdentifier,
        installLock: UpdateInstallLock? = nil,
        resultFile: URL? = UpdateInstallJournal.failureFileURL,
        fileManager: FileManager = .default
    ) async throws {
        let scriptURL = prepared.stagingDirectory.appendingPathComponent("install.sh")
        let script = installScript(
            parentPID: currentProcessID,
            sourceAppPath: prepared.appBundleURL.path,
            targetAppPath: prepared.targetAppURL.path,
            stagingPath: prepared.stagingDirectory.path,
            expectedVersion: prepared.version,
            lockPath: installLock?.lockURL.path,
            lockToken: installLock?.ownerToken,
            resultFile: resultFile?.path
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

        // The generated script publishes this marker once its logging is
        // active and immediately before it starts waiting for this process.
        // Without the handshake, a syntax or setup failure would quit the app
        // and leave the user with nothing running.
        let markerURL = prepared.stagingDirectory
            .appendingPathComponent("installer-started", isDirectory: false)
        do {
            try await waitForInstallerStart(
                markerURL: markerURL,
                process: process,
                fileManager: fileManager
            )
        } catch {
            // The app is still alive and reports this failure itself. The
            // aborted script may have raced a journal write; drop it so the
            // next launch does not show a second alert with a dead log path.
            if let resultFile {
                try? fileManager.removeItem(at: resultFile)
            }
            throw error
        }
    }

    /// Waits until a detached installer reports that it is running. A process
    /// that exits before publishing the marker aborts the update so the app
    /// can stay open and report the failure instead of quitting into nothing.
    public static func waitForInstallerStart(
        markerURL: URL,
        process: Process,
        timeout: TimeInterval = 5,
        fileManager: FileManager = .default
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if fileManager.fileExists(atPath: markerURL.path) {
                // The installer cannot legitimately finish before this process
                // exits, so a marker with a dead script means it aborted.
                guard process.isRunning else {
                    throw UpdateInstallError.scriptFailed("安装脚本提前退出")
                }
                return
            }
            guard process.isRunning else { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if process.isRunning {
            process.terminate()
            // Give the exit trap time to finish before the caller removes the
            // staging directory the script's log lives in.
            let exitDeadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < exitDeadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        throw UpdateInstallError.scriptFailed("安装脚本未能启动")
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
        // The pending copy intentionally uses an installer temporary name
        // (WallpaperMac.app.installing.<pid> or WallpaperMac.app.previous).
        // Only the target must be a standard .app; the pending operand must
        // still be a complete bundle in the same directory.
        guard targetAppURL.pathExtension == "app",
              pendingAppURL.deletingLastPathComponent().standardizedFileURL
                == targetAppURL.deletingLastPathComponent().standardizedFileURL else {
            throw UpdateInstallError.scriptFailed("更新交换要求目标为 .app 且两个 Bundle 位于同一目录")
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: pendingAppURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              fileManager.fileExists(atPath: targetAppURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let pendingBundle = Bundle(url: pendingAppURL),
              let pendingExecutable = pendingBundle.executableURL,
              fileManager.fileExists(atPath: pendingExecutable.path) else {
            throw UpdateInstallError.scriptFailed("待交换的 App Bundle 不完整或不存在")
        }
        if renamex_np(pendingAppURL.path, targetAppURL.path, UInt32(RENAME_SWAP)) != 0 {
            throw UpdateInstallError.scriptFailed(
                "原子交换失败：\(String(cString: strerror(errno)))"
            )
        }
    }

    /// Generated installer. Kept as plain shell so it survives the app going
    /// away mid-update and can be inspected in the staging directory.
    ///
    /// This script is compiled into the running build. Releases 0.2.8 through
    /// 0.2.13 emitted scripts whose swap helper rejected the installer's own
    /// `.installing.<pid>` name, so those versions cannot auto-update; users
    /// on them need one manual install before this script can take effect.
    public static func installScript(
        parentPID: Int32,
        sourceAppPath: String,
        targetAppPath: String,
        stagingPath: String,
        expectedVersion: String? = nil,
        lockPath: String? = nil,
        lockToken: String? = nil,
        resultFile: String? = nil
    ) -> String {
        """
        #!/bin/zsh
        set -euo pipefail
        setopt nonomatch

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
        RESULT_FILE=\(shellQuote(resultFile ?? ""))
        LOCK_CHECKER="${WALLPAPERMAC_UPDATE_SWAPPER:-$TARGET_APP/Contents/MacOS/WallpaperMac}"
        SWAPPER="$LOCK_CHECKER"
        TARGET_PREVIOUS="${TARGET_APP}.previous"
        TARGET_PENDING="${TARGET_APP}.installing.$$"
        BACKUP_APP="$TARGET_PENDING"
        SWAPPED=0
        SWAP_STARTED=0
        PARENT_EXITED=0
        FAILURE_RECORDED=0

        LOG_FILE="$STAGING_DIR/install.log"

        launch_app() {
            local app="$1"
            local executable
            executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist" 2>/dev/null || true)"
            if [[ -n "$executable" && -x "$app/Contents/MacOS/$executable" ]]; then
                "$app/Contents/MacOS/$executable" </dev/null >/dev/null 2>&1 &
                return 0
            fi
            "$OPEN" "$app" </dev/null >/dev/null 2>&1 || true
        }

        write_failure() {
            local message="$1"
            if (( FAILURE_RECORDED == 1 )); then
                return 0
            fi
            FAILURE_RECORDED=1
            if [[ -n "$RESULT_FILE" ]]; then
                /bin/mkdir -p "$(/usr/bin/dirname "$RESULT_FILE")" 2>/dev/null || true
                # The app consumes this record on its next launch. Publish it
                # atomically so a concurrent launch never reads half a file.
                local temporary="$RESULT_FILE.tmp.$$"
                if {
                    printf 'state=failed\n'
                    printf 'version=%s\n' "$EXPECTED_VERSION"
                    printf 'message=%s\n' "$message"
                    printf 'log=%s\n' "$LOG_FILE"
                    printf 'date=%s\n' "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
                } > "$temporary" 2>/dev/null; then
                    /bin/mv -f "$temporary" "$RESULT_FILE" 2>/dev/null \
                        || /bin/rm -f "$temporary" 2>/dev/null || true
                else
                    /bin/rm -f "$temporary" 2>/dev/null || true
                fi
            fi
        }

        restore_previous() {
            if (( SWAPPED == 1 )) && [[ -d "$BACKUP_APP" ]]; then
                # Prefer the freshly installed helper, then fall back to the
                # preserved old bundle. This keeps rollback independent of
                # defects in the previous build's swap helper.
                ROLLBACK_SWAPPER="${WALLPAPERMAC_UPDATE_SWAPPER:-$TARGET_APP/Contents/MacOS/$EXECUTABLE_NAME}"
                ROLLED_BACK=0
                if "$ROLLBACK_SWAPPER" --update-swap "$BACKUP_APP" "$TARGET_APP"; then
                    ROLLED_BACK=1
                fi
                if (( ROLLED_BACK == 0 )); then
                    # A helper can exit nonzero after completing the exchange.
                    # Check the target version before swapping a second time.
                    CURRENT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TARGET_APP/Contents/Info.plist" 2>/dev/null || true)"
                    if [[ -n "$EXPECTED_VERSION" && -n "$CURRENT_VERSION" && "$CURRENT_VERSION" != "$EXPECTED_VERSION" ]]; then
                        ROLLED_BACK=1
                    fi
                fi
                if (( ROLLED_BACK == 0 )); then
                    FALLBACK_SWAPPER="${WALLPAPERMAC_UPDATE_SWAPPER:-$BACKUP_APP/Contents/MacOS/$EXECUTABLE_NAME}"
                    if [[ "$FALLBACK_SWAPPER" != "$ROLLBACK_SWAPPER" ]] \
                        && "$FALLBACK_SWAPPER" --update-swap "$BACKUP_APP" "$TARGET_APP"; then
                        ROLLED_BACK=1
                    fi
                fi
                if (( ROLLED_BACK == 0 )); then
                    # Both helpers failed to exchange the bundles. The backup
                    # is still complete, so launch it directly: leaving the user
                    # without any running app is worse than a non-standard path.
                    echo "rollback swap failed; launching the preserved backup" >&2
                    launch_app "$BACKUP_APP"
                    return 1
                fi
                launch_app "$TARGET_APP"
                SWAPPED=0
            fi
        }
        finish() {
            STATUS=$?
            set +e
            if (( STATUS != 0 )); then
                write_failure "installer exited with status $STATUS"
                if (( SWAPPED == 1 )); then
                    restore_previous
                elif [[ -d "$TARGET_APP" ]]; then
                    # A setup failure can race the app's own termination.
                    # Relaunch whenever the old process is gone; a still-running
                    # parent (the stuck 30s case) already leaves an app behind.
                    if (( PARENT_EXITED == 1 )) || ! kill -0 "$PARENT_PID" 2>/dev/null; then
                        echo "install failed before swap; relaunching current app" >&2
                        "$OPEN" -n "$TARGET_APP" </dev/null >/dev/null 2>&1 \
                            || launch_app "$TARGET_APP"
                    fi
                fi
            fi
            # If the swap never moved the old app, the pending copy is only a
            # failed new generation and can be removed. When the target already
            # carries the expected version it is the rollback backup: keep it.
            if (( SWAPPED == 0 )); then
                TARGET_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TARGET_APP/Contents/Info.plist" 2>/dev/null || true)"
                if [[ -z "$EXPECTED_VERSION" || "$TARGET_VERSION" != "$EXPECTED_VERSION" ]]; then
                    rm -rf "$TARGET_PENDING"
                fi
            fi
            exit $STATUS
        }
        # Install the cleanup trap before touching the filesystem: any later
        # setup failure must still leave a durable failure record.
        trap finish EXIT
        trap 'exit 1' INT TERM HUP

        # Keep the detached installer diagnosable even though the app launches
        # it with no console attached. A successful install removes staging;
        # a failed one leaves this log beside the generated script.
        mkdir -p "$STAGING_DIR"
        exec >>"$LOG_FILE" 2>&1
        echo "== WallpaperMac install started: $(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
        if [[ -n "$RESULT_FILE" ]]; then
            rm -f "$RESULT_FILE"
        fi
        # The app waits for this marker before quitting, so an installer that
        # cannot start never leaves the user without a running application.
        : > "$STAGING_DIR/installer-started"

        fail() {
            echo "$1" >&2
            write_failure "$1"
            exit 1
        }
        verify_lock() {
            if [[ -n "$LOCK_PATH" ]]; then
                [[ -f "$LOCK_PATH" ]] || fail "update lock is missing"
                "$LOCK_CHECKER" --update-lock-check "$LOCK_PATH" "$LOCK_TOKEN" || fail "update lock verification failed"
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
        PARENT_EXITED=1

        # Build the complete replacement beside the target while the known-good
        # app remains in place. A partial copy never becomes the target.
        verify_lock
        for stale in "${TARGET_APP}".installing.*; do
            [[ -e "$stale" ]] || continue
            [[ "$stale" == "$TARGET_PENDING" ]] && continue
            rm -rf "$stale"
        done
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
        # Let the verified new build perform the swap. A defect in the old
        # build's helper can then no longer block updates after bootstrap.
        SWAPPER="${WALLPAPERMAC_UPDATE_SWAPPER:-$TARGET_PENDING/Contents/MacOS/$EXECUTABLE_NAME}"
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
        HEALTH_WAIT_STEPS="${WALLPAPERMAC_HEALTH_WAIT_STEPS:-150}"
        HEALTHY=0
        DIRECT_PID=""
        TARGET_EXECUTABLE="$TARGET_APP/Contents/MacOS/$EXECUTABLE_NAME"

        wait_for_health() {
            local steps="$1"
            local step
            for (( step=0; step < steps; step++ )); do
                if [[ -f "$HEALTH_ACK" ]] \
                    && /usr/bin/grep -q "^token=$HEALTH_TOKEN$" "$HEALTH_ACK" \
                    && /usr/bin/grep -Eq '^pid=[0-9]+$' "$HEALTH_ACK"; then
                    if [[ -z "$EXPECTED_VERSION" ]] || /usr/bin/grep -q "^version=$EXPECTED_VERSION$" "$HEALTH_ACK"; then
                        HEALTHY=1
                        return 0
                    fi
                fi
                sleep 0.2
            done
            return 1
        }

        # Launch the executable directly first. This guarantees the health
        # arguments reach the new process; `open` can activate an existing
        # instance or race with the freshly swapped bundle and drop them.
        if [[ -n "$EXECUTABLE_NAME" && -x "$TARGET_EXECUTABLE" ]]; then
            echo "launching replacement executable directly"
            "$TARGET_EXECUTABLE" --update-health-token "$HEALTH_TOKEN" \
                --update-health-file "$HEALTH_ACK" </dev/null >/dev/null 2>&1 &
            DIRECT_PID=$!
            wait_for_health "$HEALTH_WAIT_STEPS" || true
        fi

        if (( HEALTHY == 0 )); then
            [[ -z "$DIRECT_PID" ]] || kill "$DIRECT_PID" 2>/dev/null || true
            echo "direct launch did not acknowledge; retrying through open"
            if "$OPEN" -n "$TARGET_APP" --args \
                --update-health-token "$HEALTH_TOKEN" \
                --update-health-file "$HEALTH_ACK" </dev/null; then
                wait_for_health "$HEALTH_WAIT_STEPS" || true
            fi
        fi

        if (( HEALTHY == 1 )); then
            # Clean staging only after the new instance has completed its
            # critical initialization and acknowledged this exact install.
            echo "replacement acknowledged health token"
            rm -rf "$STAGING_DIR" || true
            exit 0
        fi
        # Do not kill an unrelated existing instance. Only a process still
        # carrying this install's token is a failed new launch.
        # Match the executable path and token as literal strings. Paths
        # containing regex characters must still be cleaned up correctly.
        TARGET_APP_FOR_CLEANUP="$TARGET_EXECUTABLE"
        export TARGET_APP_FOR_CLEANUP HEALTH_TOKEN
        NEW_PID="$(ps -axo pid,command | /usr/bin/awk 'index($0, ENVIRON["TARGET_APP_FOR_CLEANUP"]) && index($0, ENVIRON["HEALTH_TOKEN"]) { print $1; exit }' | head -1 || true)"
        [[ -z "$NEW_PID" ]] || kill "$NEW_PID" 2>/dev/null || true
        [[ -z "$DIRECT_PID" ]] || kill "$DIRECT_PID" 2>/dev/null || true
        fail "replacement did not become healthy"
        """
    }

    /// Removes abandoned `.installing.<pid>` copies left by failed swaps.
    /// Callers must hold the target update lock; `...IfUnlocked` does that.
    /// `.previous` is intentionally preserved as a manual rollback backup.
    public static func removeStaleInstallerBackups(
        targetAppURL: URL,
        fileManager: FileManager = .default
    ) {
        let parent = targetAppURL.deletingLastPathComponent()
        let prefix = targetAppURL.lastPathComponent + ".installing."
        guard let entries = try? fileManager.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(prefix) {
            try? fileManager.removeItem(at: entry)
        }
    }

    /// Best-effort launch cleanup: skips when another installer holds the
    /// target lock, so an in-flight update is never disturbed.
    public static func removeStaleInstallerBackupsIfUnlocked(
        targetAppURL: URL,
        fileManager: FileManager = .default
    ) {
        guard let lock = try? UpdateInstallLock(targetAppURL: targetAppURL) else { return }
        removeStaleInstallerBackups(targetAppURL: targetAppURL, fileManager: fileManager)
        _ = lock
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
