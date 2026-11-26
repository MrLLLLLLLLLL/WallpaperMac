import Foundation

/// Runs one SteamCMD workshop download with interactive login prompts.
/// Password and Steam Guard codes travel over stdin only — never argv — so
/// they never appear in `ps` output. Output is parsed by `SteamCMDOutputParser`.
public actor SteamCMDSession {
    public struct Credentials: Sendable {
        public let username: String
        public let password: String
        public let steamGuardCode: String?

        public init(username: String, password: String, steamGuardCode: String? = nil) {
            self.username = username
            self.password = password
            if let code = steamGuardCode {
                let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
                self.steamGuardCode = trimmed.isEmpty ? nil : trimmed
            } else {
                self.steamGuardCode = nil
            }
        }
    }

    public struct Progress: Sendable {
        public let status: String?
        public let fraction: Double?
        public let openPrompt: SteamCMDOutputParser.Prompt?

        public init(status: String?, fraction: Double?, openPrompt: SteamCMDOutputParser.Prompt?) {
            self.status = status
            self.fraction = fraction
            self.openPrompt = openPrompt
        }
    }

    public struct Result: Sendable {
        public let exitCode: Int32
        public let downloadedDirectory: URL?
        public let failure: SteamCMDFailure?
        public let outputTail: String

        public var succeeded: Bool { failure == nil && downloadedDirectory != nil }
    }

    public enum SessionError: Error, Equatable, Sendable, LocalizedError {
        case launchFailed(String)
        case timedOut
        case cancelled

        public var errorDescription: String? {
            switch self {
            case .launchFailed(let message):
                return "无法启动 SteamCMD：\(message)"
            case .timedOut:
                return "SteamCMD 执行超时，请检查网络后重试。"
            case .cancelled:
                return "下载已取消。"
            }
        }
    }

    private let executable: URL
    private let timeout: TimeInterval

    public init(executable: URL, timeout: TimeInterval = 600) {
        self.executable = executable
        self.timeout = timeout
    }

    /// Runs the command to completion. `onProgress` is called on an arbitrary
    /// actor context for each meaningful output event.
    public func run(
        command: SteamCMDCommand,
        credentials: Credentials,
        environment: [String: String],
        workingDirectory: URL,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> Result {
        let parser = SteamCMDOutputParser()
        parser.noteExpectedItemID(command.itemID)

        let process = Process()
        process.executableURL = executable
        process.arguments = command.arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Drain stderr into the same logical stream via a side buffer so a
        // full stderr pipe can never deadlock the child.
        let stderrBuffer = LineBuffer()

        do {
            try process.run()
        } catch {
            throw SessionError.launchFailed(error.localizedDescription)
        }

        let group = AsyncStream<SteamCMDOutputParser.Event>.makeStream()
        let parserRef = ParserBox(parser)

        // stdout reader
        let stdoutTask = Task {
            let handle = stdoutPipe.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                let text = String(data: chunk, encoding: .utf8)
                    ?? String(decoding: chunk, as: UTF8.self)
                for event in parserRef.parser.consume(text) {
                    group.continuation.yield(event)
                }
            }
            for event in parserRef.parser.finish() {
                group.continuation.yield(event)
            }
            group.continuation.finish()
        }

        // stderr reader (status only; failures mostly come from stdout)
        let stderrTask = Task {
            let handle = stderrPipe.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                let text = String(data: chunk, encoding: .utf8)
                    ?? String(decoding: chunk, as: UTF8.self)
                stderrBuffer.append(text)
                for event in parserRef.parser.consume(text) {
                    group.continuation.yield(event)
                }
            }
        }

        // Answer prompts from a dedicated loop. A required Steam Guard code
        // that the caller did not supply aborts immediately instead of
        // sitting on the prompt until the overall timeout.
        let credentialsCopy = credentials
        let stdinHandle = stdinPipe.fileHandleForWriting
        let answered = AnsweredPrompts()
        let missingGuard = MissingGuardFlag()
        let missingPassword = MissingGuardFlag()
        let activity = ActivityStamp()

        let eventsTask = Task {
            var lastProgress = Progress(status: nil, fraction: nil, openPrompt: nil)
            for await event in group.stream {
                activity.touch()
                switch event {
                case .prompt(.password):
                    // Empty password means "use the cached SteamHome session".
                    // If Steam still asks, the cache is gone — fail fast with a
                    // clear message instead of sending a blank line.
                    if credentialsCopy.password.isEmpty {
                        if answered.markPasswordSent() {
                            missingPassword.mark()
                        }
                    } else if answered.markPasswordSent() {
                        try? writeLine(credentialsCopy.password, to: stdinHandle)
                        onProgress?(Progress(
                            status: "正在登录 Steam…",
                            fraction: lastProgress.fraction,
                            openPrompt: nil
                        ))
                    }
                case .prompt(.steamGuard):
                    if let code = credentialsCopy.steamGuardCode, answered.markGuardSent() {
                        try? writeLine(code, to: stdinHandle)
                        onProgress?(Progress(
                            status: "正在提交 Steam Guard 验证码…",
                            fraction: lastProgress.fraction,
                            openPrompt: nil
                        ))
                    } else if credentialsCopy.steamGuardCode == nil, missingGuard.mark() {
                        onProgress?(Progress(
                            status: "需要 Steam Guard 验证码",
                            fraction: lastProgress.fraction,
                            openPrompt: .steamGuard
                        ))
                    }
                case .status(let text):
                    lastProgress = Progress(
                        status: text,
                        fraction: lastProgress.fraction,
                        openPrompt: parserRef.parser.current.openPrompt
                    )
                    onProgress?(lastProgress)
                case .progress(let fraction):
                    lastProgress = Progress(
                        status: lastProgress.status,
                        fraction: fraction ?? lastProgress.fraction,
                        openPrompt: parserRef.parser.current.openPrompt
                    )
                    onProgress?(lastProgress)
                case .succeeded, .failed:
                    break
                }
            }
        }

        // Idle timeout: the clock restarts on every SteamCMD output event so
        // a slow but healthy transfer is never killed by a fixed wall clock;
        // a silent hang still trips `timeout` seconds from the last activity.
        var lastActivity = ContinuousClock.now
        var exitCode: Int32 = -1
        while process.isRunning {
            if activity.stamp != lastActivity {
                lastActivity = activity.stamp
            }
            if missingGuard.isSet {
                terminate(process)
                stdoutTask.cancel()
                stderrTask.cancel()
                eventsTask.cancel()
                return Result(
                    exitCode: -1,
                    downloadedDirectory: nil,
                    failure: .missingSteamGuardCode,
                    outputTail: parserRef.parser.current.lastStatus ?? ""
                )
            }
            if missingPassword.isSet {
                terminate(process)
                stdoutTask.cancel()
                stderrTask.cancel()
                eventsTask.cancel()
                return Result(
                    exitCode: -1,
                    downloadedDirectory: nil,
                    failure: .sessionExpired,
                    outputTail: parserRef.parser.current.lastStatus ?? ""
                )
            }
            let idle = ContinuousClock.now - lastActivity
            if idle > .seconds(timeout) {
                terminate(process)
                stdoutTask.cancel()
                stderrTask.cancel()
                eventsTask.cancel()
                throw SessionError.timedOut
            }
            if Task.isCancelled {
                terminate(process)
                stdoutTask.cancel()
                stderrTask.cancel()
                eventsTask.cancel()
                throw SessionError.cancelled
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        exitCode = process.terminationStatus

        // Give readers a moment to drain remaining bytes.
        _ = try? await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await stdoutTask.value }
            group.addTask { await stderrTask.value }
            group.addTask { await eventsTask.value }
            try await group.waitForAll()
        }

        let snapshot = parserRef.parser.current
        let tail = snapshot.lastStatus ?? stderrBuffer.tail

        if snapshot.didSucceed {
            let dir = Self.locateDownloadedItem(
                command: command,
                snapshotPath: snapshot.successPath
            )
            if let dir {
                return Result(exitCode: exitCode, downloadedDirectory: dir, failure: nil, outputTail: tail)
            }
            // Success line but folder missing — still a failure the UI can show.
            return Result(
                exitCode: exitCode,
                downloadedDirectory: nil,
                failure: .loggedInButDownloadFailed("Steam 报告下载成功，但未在预期目录找到文件"),
                outputTail: tail
            )
        }

        let failure = snapshot.failure
            ?? .exitedBeforeCompletion(signInAccepted: snapshot.signInAccepted)
        return Result(exitCode: exitCode, downloadedDirectory: nil, failure: failure, outputTail: tail)
    }

    /// Resolves where Steam left the item: the explicit success path when it
    /// points inside our staging root, otherwise the usual candidate folders.
    public static func locateDownloadedItem(command: SteamCMDCommand, snapshotPath: String?) -> URL? {
        let fileManager = FileManager.default
        if let path = snapshotPath, !path.isEmpty {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            let staging = URL(fileURLWithPath: command.forceInstallDirectory).standardizedFileURL.path
            let standardized = url.standardizedFileURL.path
            if standardized.hasPrefix(staging + "/") || standardized == staging,
               fileManager.fileExists(atPath: standardized) {
                return url
            }
            // Path outside staging (Steam ignored force_install_dir): accept it
            // only when it clearly is our item folder.
            if standardized.contains("/\(WorkshopLink.wallpaperEngineAppID)/\(command.itemID)"),
               fileManager.fileExists(atPath: standardized) {
                return url
            }
        }
        for candidate in [command.expectedContentDirectory] + command.candidateContentDirectories() {
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private func terminate(_ process: Process) {
        process.terminate()
        let killDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while process.isRunning && ContinuousClock.now < killDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private func writeLine(_ line: String, to handle: FileHandle) throws {
        var data = Data(line.utf8)
        data.append(0x0A) // newline
        try handle.write(contentsOf: data)
    }
}

// MARK: - Small helpers

private final class ParserBox: @unchecked Sendable {
    let parser: SteamCMDOutputParser
    init(_ parser: SteamCMDOutputParser) { self.parser = parser }
}

private final class AnsweredPrompts: @unchecked Sendable {
    private let lock = NSLock()
    private var passwordSent = false
    private var guardSent = false

    func markPasswordSent() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if passwordSent { return false }
        passwordSent = true
        return true
    }

    func markGuardSent() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if guardSent { return false }
        guardSent = true
        return true
    }
}

private final class MissingGuardFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false

    func mark() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if set { return false }
        set = true
        return true
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return set
    }
}

/// Latest moment any SteamCMD output was observed; feeds the idle timeout.
private final class ActivityStamp: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ContinuousClock.now

    func touch() {
        lock.lock()
        value = ContinuousClock.now
        lock.unlock()
    }

    var stamp: ContinuousClock.Instant {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    func append(_ text: String) {
        lock.lock()
        storage += text
        if storage.count > 16384 {
            storage = String(storage.suffix(8192))
        }
        lock.unlock()
    }

    var tail: String {
        lock.lock()
        defer { lock.unlock() }
        return String(storage.suffix(2048))
    }
}
