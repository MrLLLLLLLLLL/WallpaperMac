import Foundation
import WallpaperMacCore

/// Runs an interactive SteamCMD login against the persistent Steam home and
/// records the username on success. Password travels only over stdin.
actor SteamLoginService {
    enum LoginError: Error, LocalizedError {
        case notInstalled
        case launch(String)
        case failed(SteamCMDFailure)
        case exitedWithoutConfirmation

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "尚未安装 SteamCMD。请先在浏览工坊时完成一次安装，或重试。"
            case .launch(let message):
                return "无法启动 SteamCMD：\(message)"
            case .failed(let failure):
                return failure.userMessage
            case .exitedWithoutConfirmation:
                return "SteamCMD 未确认登录成功。请检查账号密码与 Steam Guard 后重试。"
            }
        }
    }

    private let coordinator = WorkshopDownloadCoordinator()
    private let sessionStore = SteamSessionStore()

    var isLoggedIn: Bool {
        let context = WorkshopDownloadCoordinator.Context(
            rootDirectory: WorkshopDownloadCoordinator.defaultRootDirectory(),
            credentials: nil
        )
        return sessionStore.isLoggedIn(configuration: context.sessionConfiguration)
    }

    var savedUsername: String? { sessionStore.savedUsername }

    /// Installs SteamCMD if needed, then performs `+login` with the supplied
    /// password answered on stdin. On success the username is persisted and
    /// SteamCMD's machine auth cache lives under SteamHome.
    func login(username: String, password: String, steamGuardCode: String?) async throws {
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUser.isEmpty else {
            throw LoginError.exitedWithoutConfirmation
        }
        let context = WorkshopDownloadCoordinator.Context(
            rootDirectory: WorkshopDownloadCoordinator.defaultRootDirectory(),
            credentials: .init(
                username: trimmedUser,
                password: password,
                steamGuardCode: steamGuardCode
            )
        )
        try sessionStore.prepareHome(context.sessionConfiguration)

        let executable = try await coordinator.ensureSteamCMD(context: context)

        // Login-only command: no workshop download, HOME = persistent SteamHome.
        let process = Process()
        process.executableURL = executable
        process.arguments = SteamLoginCommand.login(account: trimmedUser)
        process.currentDirectoryURL = context.steamHomeDirectory
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": context.steamHomeDirectory.path,
            "TMPDIR": context.steamHomeDirectory.appendingPathComponent("tmp").path,
            "TERM": "dumb",
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8"
        ]
        try FileManager.default.createDirectory(
            at: context.steamHomeDirectory.appendingPathComponent("tmp"),
            withIntermediateDirectories: true
        )

        let parser = SteamCMDOutputParser()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw LoginError.launch(error.localizedDescription)
        }

        let credentials = SteamCMDSession.Credentials(
            username: trimmedUser,
            password: password,
            steamGuardCode: steamGuardCode
        )
        let stdinHandle = stdinPipe.fileHandleForWriting
        let answered = LoginAnswered()

        let parserBox = LoginParserBox(parser)
        let reader = Task {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let handle = stdoutPipe.fileHandleForReading
                handle.readabilityHandler = { h in
                    let chunk = h.availableData
                    if chunk.isEmpty {
                        h.readabilityHandler = nil
                        cont.resume()
                        return
                    }
                    let text = String(data: chunk, encoding: .utf8)
                        ?? String(decoding: chunk, as: UTF8.self)
                    for event in parserBox.parser.consume(text) {
                        switch event {
                        case .prompt(.password):
                            if answered.markPassword() {
                                var data = Data(credentials.password.utf8)
                                data.append(0x0A)
                                try? stdinHandle.write(contentsOf: data)
                            }
                        case .prompt(.steamGuard):
                            if let code = credentials.steamGuardCode, answered.markGuard() {
                                var data = Data(code.utf8)
                                data.append(0x0A)
                                try? stdinHandle.write(contentsOf: data)
                            } else if credentials.steamGuardCode == nil {
                                if answered.markGuard() {
                                    answered.markGuardMissing()
                                    process.terminate()
                                }
                            }
                        default:
                            break
                        }
                    }
                }
            }
            for event in parserBox.parser.finish() {
                if case .prompt(.password) = event, answered.markPassword() {
                    var data = Data(credentials.password.utf8)
                    data.append(0x0A)
                    try? stdinHandle.write(contentsOf: data)
                }
            }
        }

        // Drain stderr so the child cannot block on a full pipe.
        let stderrReader = Task {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let handle = stderrPipe.fileHandleForReading
                handle.readabilityHandler = { h in
                    if h.availableData.isEmpty {
                        h.readabilityHandler = nil
                        cont.resume()
                    }
                }
            }
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(180))
        while process.isRunning {
            if ContinuousClock.now >= deadline {
                process.terminate()
                break
            }
            if Task.isCancelled {
                process.terminate()
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning {
            let killDeadline = ContinuousClock.now.advanced(by: .seconds(3))
            while process.isRunning && ContinuousClock.now < killDeadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        _ = await reader.value
        stderrReader.cancel()

        let snapshot = parser.current
        if snapshot.signInAccepted || SteamSessionStore.hasSteamLoginCache(
            in: context.steamHomeDirectory
        ) {
            sessionStore.saveUsername(trimmedUser)
            // App-owned marker: isLoggedIn must flip true immediately so the
            // browse gate does not re-prompt before SteamCMD's own cache
            // files are visible (they may nest deeper or appear later).
            sessionStore.writeSessionMarker(
                username: trimmedUser,
                configuration: context.sessionConfiguration
            )
            return
        }
        if let failure = snapshot.failure {
            throw LoginError.failed(failure)
        }
        if answered.guardMissing {
            throw LoginError.failed(.missingSteamGuardCode)
        }
        throw LoginError.exitedWithoutConfirmation
    }

    func logout() {
        let context = WorkshopDownloadCoordinator.Context(
            rootDirectory: WorkshopDownloadCoordinator.defaultRootDirectory(),
            credentials: nil
        )
        sessionStore.logout(configuration: context.sessionConfiguration)
    }
}

private final class LoginAnswered: @unchecked Sendable {
    private let lock = NSLock()
    private var passwordSent = false
    private var guardSent = false
    private(set) var guardMissing = false

    func markPassword() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if passwordSent { return false }
        passwordSent = true
        return true
    }

    func markGuard() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if guardSent { return false }
        guardSent = true
        return true
    }

    func markGuardMissing() {
        lock.lock()
        guardMissing = true
        lock.unlock()
    }
}

private final class LoginParserBox: @unchecked Sendable {
    let parser: SteamCMDOutputParser
    init(_ parser: SteamCMDOutputParser) { self.parser = parser }
}
