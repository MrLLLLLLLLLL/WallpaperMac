import Foundation

/// Builds SteamCMD argument vectors for workshop downloads.
/// Passwords are never placed on the command line — SteamCMD prompts on
/// stdin and `SteamCMDSession` answers the prompt, keeping credentials out
/// of `ps` output and shell history.
public struct SteamCMDCommand: Equatable, Sendable {
    public let arguments: [String]
    public let itemID: String
    public let account: String
    public let forceInstallDirectory: String

    /// - Parameters:
    ///   - account: Steam account name (not email display name).
    ///   - itemID: published file id.
    ///   - forceInstallDirectory: staging root; workshop content lands under
    ///     `<dir>/steamapps/workshop/content/431960/<id>`.
    public init(account: String, itemID: String, forceInstallDirectory: String) {
        self.account = account
        self.itemID = itemID
        self.forceInstallDirectory = forceInstallDirectory
        self.arguments = [
            "-inhibitbootstrap",
            "+@ShutdownOnFailedCommand", "1",
            "+force_install_dir", forceInstallDirectory,
            "+login", account,
            "+workshop_download_item", WorkshopLink.wallpaperEngineAppID, itemID,
            "+quit"
        ]
    }

    /// Where SteamCMD places a completed workshop item for this command.
    public var expectedContentDirectory: URL {
        URL(fileURLWithPath: forceInstallDirectory, isDirectory: true)
            .appendingPathComponent("steamapps/workshop/content", isDirectory: true)
            .appendingPathComponent(WorkshopLink.wallpaperEngineAppID, isDirectory: true)
            .appendingPathComponent(itemID, isDirectory: true)
    }

    /// Candidate locations Steam may leave the item under (downloads/temp/content).
    public func candidateContentDirectories() -> [URL] {
        let root = URL(fileURLWithPath: forceInstallDirectory, isDirectory: true)
        let appRoot = root.appendingPathComponent("steamapps/workshop", isDirectory: true)
        return ["content", "downloads", "temp"].map { stage in
            appRoot
                .appendingPathComponent(stage, isDirectory: true)
                .appendingPathComponent(WorkshopLink.wallpaperEngineAppID, isDirectory: true)
                .appendingPathComponent(itemID, isDirectory: true)
        }
    }
}

/// Pure line-oriented parser for SteamCMD output. Feed it chunks of decoded
/// text; it answers which interactive prompt is open and whether the run
/// succeeded or failed, without touching processes or clocks.
public final class SteamCMDOutputParser: @unchecked Sendable {
    public enum Prompt: String, Equatable, Sendable {
        case password
        case steamGuard
    }

    public enum Event: Equatable, Sendable {
        case prompt(Prompt)
        case status(String)
        case progress(fraction: Double?)
        case succeeded(itemID: String, path: String?)
        case failed(SteamCMDFailure)
    }

    public struct Snapshot: Equatable, Sendable {
        public var openPrompt: Prompt?
        public var lastStatus: String?
        public var progressFraction: Double?
        public var didSucceed: Bool
        public var successPath: String?
        public var failure: SteamCMDFailure?
        /// Set when Steam named a Steam Guard method this run.
        public var sawSteamGuardChallenge: Bool
        public var signInAccepted: Bool

        init() {
            openPrompt = nil
            lastStatus = nil
            progressFraction = nil
            didSucceed = false
            successPath = nil
            failure = nil
            sawSteamGuardChallenge = false
            signInAccepted = false
        }
    }

    private let lock = NSLock()
    private var buffer = ""
    private var snapshot = Snapshot()
    private var consumedPromptLines = Set<String>()

    public init() {}

    public var current: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    /// Feeds a chunk of output and returns every event it produced, in order.
    public func consume(_ text: String) -> [Event] {
        guard !text.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }

        buffer += text
        var events: [Event] = []

        // Prompts often arrive without a trailing newline ("password: "), so
        // match them against the live buffer before line splitting.
        events.append(contentsOf: detectPromptsInBuffer())

        while let newline = buffer.firstIndex(where: { $0.isNewline }) {
            let line = String(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            events.append(contentsOf: consumeLine(line))
        }

        // Keep the un-line-terminated tail bounded.
        if buffer.count > 8192 {
            buffer = String(buffer.suffix(4096))
        }
        return events
    }

    /// Call when the process exits to flush any final unterminated line.
    public func finish() -> [Event] {
        lock.lock()
        defer { lock.unlock() }
        guard !buffer.isEmpty else { return [] }
        let rest = buffer
        buffer = ""
        return consumeLine(rest)
    }

    private func detectPromptsInBuffer() -> [Event] {
        var events: [Event] = []
        let lower = buffer.lowercased()

        // "password: " at the end of what we have seen (possibly with \r).
        if let range = lower.range(of: "password:"), range.upperBound == lower.endIndex
            || lower[range.upperBound...].allSatisfy({ $0 == " " || $0 == "\r" || $0 == "\n" }) {
            if snapshot.openPrompt != .password, !snapshot.didSucceed, snapshot.failure == nil {
                snapshot.openPrompt = .password
                events.append(.prompt(.password))
            }
        }

        // Steam Guard wording varies: "Steam Guard code:", "two-factor code:",
        // "Enter the code from your email", etc. Only treat it as a prompt when
        // it appears at the tail like an interactive ask.
        let guardMarkers = ["steam guard code:", "two-factor code:", "mobile authenticator code:"]
        for marker in guardMarkers {
            if let range = lower.range(of: marker), range.upperBound == lower.endIndex
                || lower[range.upperBound...].allSatisfy({ $0 == " " || $0 == "\r" || $0 == "\n" }) {
                snapshot.sawSteamGuardChallenge = true
                if snapshot.openPrompt != .steamGuard, !snapshot.didSucceed, snapshot.failure == nil {
                    snapshot.openPrompt = .steamGuard
                    events.append(.prompt(.steamGuard))
                }
                break
            }
        }
        return events
    }

    private func consumeLine(_ rawLine: String) -> [Event] {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return [] }
        let lower = line.lowercased()
        var events: [Event] = []

        // --- terminal outcomes first -------------------------------------
        if snapshot.failure == nil, let failure = SteamCMDFailure.match(line: line, lowercased: lower) {
            snapshot.failure = failure
            snapshot.openPrompt = nil
            events.append(.failed(failure))
            return events
        }

        // Success. Downloaded item <id> to "<path>"
        if lower.contains("success. downloaded item") {
            snapshot.didSucceed = true
            snapshot.openPrompt = nil
            let path = Self.extractQuotedPath(line) ?? Self.extractDownloadedItemPath(line)
            snapshot.successPath = path
            let id = Self.extractItemID(line) ?? itemHint
            events.append(.succeeded(itemID: id, path: path))
            return events
        }
        // Some builds only print the path form without the word Success when
        // ShutdownOnFailedCommand is off; require both id and workshop path.
        if lower.contains("workshop/content/"), let id = Self.extractItemID(line), !id.isEmpty,
           snapshot.failure == nil, !snapshot.didSucceed {
            // Do not claim success on a bare path mention; wait for Success line.
        }

        // Sign-in milestones clear the password prompt once Steam proceeds.
        if lower.contains("logging in user") || lower.contains("waiting for user info")
            || lower.contains("cached credentials not found") == false && lower.contains("logged in ok") {
            if snapshot.openPrompt == .password {
                snapshot.openPrompt = nil
            }
            if lower.contains("logged in ok") || lower.contains("waiting for user info") {
                snapshot.signInAccepted = true
            }
        }
        if lower.contains("logged in ok") {
            snapshot.signInAccepted = true
            snapshot.openPrompt = nil
        }

        // Progress: "[ 42%] Downloading item ..." or "progress: 42%"
        if let fraction = Self.extractProgress(lower) {
            snapshot.progressFraction = fraction
            events.append(.progress(fraction: fraction))
        }

        // Status lines worth surfacing (skip noisy update chatter).
        if Self.isStatusLine(lower) {
            snapshot.lastStatus = line
            events.append(.status(line))
        }

        return events
    }

    private var itemHint = ""

    public func noteExpectedItemID(_ id: String) {
        lock.lock()
        itemHint = id
        lock.unlock()
    }

    private static func isStatusLine(_ lower: String) -> Bool {
        let interesting = [
            "logging in user", "logged in ok", "waiting for user info",
            "downloading item", "progress", "success. downloaded",
            "error", "failed", "no subscription", "rate limit",
            "connecting to steam", "steam guard", "two-factor",
            "workshop item", "success."
        ]
        return interesting.contains { lower.contains($0) }
    }

    private static func extractProgress(_ lower: String) -> Double? {
        // "[ 42%]" style
        if let range = lower.range(of: #"\[\s*(\d{1,3})%\]"#, options: .regularExpression) {
            let slice = lower[range]
            let digits = slice.filter { $0.isNumber }
            if let value = Double(digits), value <= 100 { return value / 100 }
        }
        // "progress: 42%" / "42.5%"
        if let range = lower.range(of: #"progress[:\s]+(\d{1,3}(?:\.\d+)?)%"#, options: .regularExpression) {
            let match = String(lower[range])
            let numbers = match.filter { $0.isNumber || $0 == "." }
            if let value = Double(numbers), value <= 100 { return value / 100 }
        }
        return nil
    }

    private static func extractQuotedPath(_ line: String) -> String? {
        guard let open = line.firstIndex(of: "\"") else { return nil }
        guard let close = line[open...].dropFirst().firstIndex(of: "\"") else { return nil }
        return String(line[line.index(after: open)..<close])
    }

    private static func extractDownloadedItemPath(_ line: String) -> String? {
        // Success. Downloaded item 123 to /path/without/quotes
        guard let range = line.range(of: " to ") else { return nil }
        var path = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        if path.hasPrefix("\"") { path = String(path.dropFirst()) }
        if path.hasSuffix("\"") { path = String(path.dropLast()) }
        // Trim trailing punctuation from sentence endings.
        while let last = path.last, last == "." || last == ")" {
            path = String(path.dropLast())
        }
        return path.isEmpty ? nil : path
    }

    private static func extractItemID(_ line: String) -> String? {
        guard let range = line.range(of: #"item\s+(\d{6,})"#, options: .regularExpression) else { return nil }
        let match = String(line[range])
        return match.split(separator: " ").last.map(String.init)
    }
}

// MARK: - Failure classification

public enum SteamCMDFailure: Error, Equatable, Sendable, LocalizedError {
    case invalidPassword
    case steamGuardRejected
    case twoFactorRejected
    case noSubscription
    case rateLimited
    case itemUnavailable
    case network(String)
    case loggedInButDownloadFailed(String)
    case exitedBeforeCompletion(signInAccepted: Bool)
    case timeout
    case missingSteamGuardCode
    case sessionExpired
    case unknown(String)

    /// Matches the failure patterns SteamCMD prints. WallpaperMachine uses the
    /// same parenthesized `failed (reason)` / `error (reason)` shape; a bare
    /// `(109)` from a C++ log line must never count as a failure.
    public static func match(line: String, lowercased lower: String) -> SteamCMDFailure? {
        // Parenthesized reason only after an error/failed keyword on the line.
        if let reason = Self.parenthesizedReason(lower) {
            if reason.contains("invalid password") || reason.contains("invalid login")
                || reason.contains("account logon denied") || (reason.contains("password") && reason.contains("invalid")) {
                return .invalidPassword
            }
            if reason.contains("two-factor") || reason.contains("twofactor")
                || (reason.contains("mobile") && reason.contains("code")) {
                return .twoFactorRejected
            }
            if reason.contains("steam guard") || reason.contains("guard code")
                || (reason.contains("guard") && reason.contains("invalid")) {
                return .steamGuardRejected
            }
            if reason.contains("no subscription") || reason.contains("no subscriptions") {
                return .noSubscription
            }
            if reason.contains("rate limit") || reason.contains("too many") {
                return .rateLimited
            }
            if reason.contains("invalid parameters") || reason.contains("file not found")
                || reason.contains("app not found") || reason.contains("published file") {
                return .itemUnavailable
            }
            if reason.contains("connection") || reason.contains("network") || reason.contains("timeout")
                || reason.contains("dns") || reason.contains("socket") {
                return .network(reason)
            }
            // Only escalate to a download failure when the line itself is an error.
            if lower.contains("error") || lower.contains("failed") {
                return .loggedInButDownloadFailed(reason)
            }
        }

        // Free-form lines without parens.
        if lower.contains("invalid password") || lower.contains("invalid login credentials") {
            return .invalidPassword
        }
        if lower.contains("no subscription") {
            return .noSubscription
        }
        if lower.contains("rate limit") {
            return .rateLimited
        }
        if lower.contains("two-factor code mismatch") || lower.contains("two-factor code incorrect")
            || lower.contains("incorrect two-factor") {
            return .twoFactorRejected
        }
        if lower.contains("steam guard code") && (lower.contains("invalid") || lower.contains("incorrect")) {
            return .steamGuardRejected
        }
        // "ERROR! Workshop item download failed" without a recognized reason.
        if lower.contains("workshop item download failed") {
            return .loggedInButDownloadFailed(line)
        }
        return nil
    }

    private static func parenthesizedReason(_ lower: String) -> String? {
        // Only a paren group that follows an error/failed keyword counts.
        guard let keywordRange = lower.range(of: #"error!?|failed"#, options: .regularExpression) else {
            return nil
        }
        guard let open = lower[keywordRange.upperBound...].firstIndex(of: "(") else { return nil }
        let afterOpen = lower[lower.index(after: open)...]
        guard let close = afterOpen.firstIndex(of: ")") else { return nil }
        let reason = String(afterOpen[..<close])
        guard !reason.isEmpty, reason.count <= 200 else { return nil }
        return reason
    }

    public var userMessage: String {
        switch self {
        case .invalidPassword:
            return "Steam 密码不正确，请检查后重试。"
        case .steamGuardRejected:
            return "Steam Guard 验证码不正确或已过期，请重新获取后重试。"
        case .twoFactorRejected:
            return "两步验证码不正确或已过期，请在 Steam 手机 App 中查看最新验证码。"
        case .noSubscription:
            return "该 Steam 账号未拥有 Wallpaper Engine，无法下载其创意工坊内容。请先在 Steam 上安装 Wallpaper Engine。"
        case .rateLimited:
            return "Steam 请求过于频繁，请稍后再试。"
        case .itemUnavailable:
            return "该工坊条目不可用（可能已被移除或链接错误）。"
        case .network(let reason):
            return "网络错误：\(reason)。大陆网络下可能需要为 steam 相关域名配置代理。"
        case .loggedInButDownloadFailed(let reason):
            return "下载失败：\(reason)"
        case .exitedBeforeCompletion(let signInAccepted):
            return signInAccepted
                ? "SteamCMD 在完成下载前退出，请确认磁盘空间和网络后重试。"
                : "SteamCMD 在登录确认前退出，请检查账号密码与 Steam Guard 后重试。"
        case .timeout:
            return "SteamCMD 执行超时，请检查网络后重试。"
        case .missingSteamGuardCode:
            return "Steam 要求 Steam Guard 验证码。请勾选“需要 Steam Guard 验证码”并填写当前验证码后重试。"
        case .sessionExpired:
            return "Steam 登录会话已失效。请到 设置 → Steam 工坊 重新登录后再下载。"
        case .unknown(let text):
            return "SteamCMD 错误：\(text)"
        }
    }

    public var errorDescription: String? { userMessage }
}
