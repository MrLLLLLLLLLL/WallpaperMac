import Foundation

/// Runs external tools without the classic `Pipe + waitUntilExit` deadlock:
/// stderr drains to a temp file, and the wait is bounded by a timeout.
public enum ProcessRunner {
    public struct Result: Equatable, Sendable {
        public let status: Int32
        public let stderrTail: String
    }

    public enum Failure: Error, Equatable, Sendable, LocalizedError {
        case launchFailed(String)
        case timedOut

        public var errorDescription: String? {
            switch self {
            case .launchFailed(let message):
                return "无法启动外部工具：\(message)"
            case .timedOut:
                return "外部工具执行超时"
            }
        }
    }

    @discardableResult
    public static func run(
        executableAt url: URL,
        arguments: [String],
        timeout: TimeInterval = 60,
        fileManager: FileManager = .default
    ) throws -> Result {
        let process = Process()
        process.executableURL = url
        process.arguments = arguments

        // Bounded, readable stderr: a pipe here fills its buffer and deadlocks
        // waitUntilExit when the child writes more than 64 KB before exiting.
        let stderrURL = fileManager.temporaryDirectory
            .appendingPathComponent("wallpapermac-proc-\(UUID().uuidString).log")
        fileManager.createFile(atPath: stderrURL.path, contents: nil)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrHandle

        do {
            try process.run()
        } catch {
            try? fileManager.removeItem(at: stderrURL)
            throw Failure.launchFailed(error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            // Escalate: SIGTERM for a graceful exit, then SIGKILL if ignored.
            process.terminate()
            let killDeadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                while process.isRunning {
                    Thread.sleep(forTimeInterval: 0.02)
                }
            }
            try? stderrHandle.close()
            try? fileManager.removeItem(at: stderrURL)
            throw Failure.timedOut
        }

        try? stderrHandle.close()
        let stderrData = (try? Data(contentsOf: stderrURL)) ?? Data()
        try? fileManager.removeItem(at: stderrURL)
        let tail = String(data: stderrData.suffix(4096), encoding: .utf8) ?? ""
        return Result(status: process.terminationStatus, stderrTail: tail)
    }
}
