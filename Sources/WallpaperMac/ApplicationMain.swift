import AppKit
import WallpaperMacCore

@main
struct WallpaperMacApplication {
    @MainActor
    static func main() {
        // Detached updater helper: runs before NSApplication so the old app
        // can exchange bundles without creating windows or starting playback.
        if CommandLine.arguments.count > 1,
           CommandLine.arguments[1] == "--update-swap" {
            guard CommandLine.arguments.count == 4 else {
                FileHandle.standardError.write(Data("usage: --update-swap <pending.app> <target.app>\n".utf8))
                exit(2)
            }
            do {
                try UpdateInstaller.atomicSwap(
                    pendingAppURL: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true),
                    targetAppURL: URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
                )
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }

        if CommandLine.arguments.count > 1,
           CommandLine.arguments[1] == "--update-lock-check" {
            guard CommandLine.arguments.count == 4 else {
                FileHandle.standardError.write(Data("usage: --update-lock-check <lock-path> <owner-token>\n".utf8))
                exit(2)
            }
            do {
                try UpdateInstaller.verifyInheritedLock(
                    lockURL: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: false),
                    expectedToken: CommandLine.arguments[3]
                )
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}
