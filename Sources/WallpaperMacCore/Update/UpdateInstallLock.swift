import Foundation
import Darwin

/// Cross-process ownership for one target app's update transaction. The lock
/// file is deliberately not unlinked: every contender must flock the same
/// inode, and the kernel releases the lock when the last descriptor closes.
public final class UpdateInstallLock {
    public let targetAppURL: URL
    public let lockURL: URL
    public let ownerToken: String

    private let fd: Int32

    public init(targetAppURL: URL, fileManager: FileManager = .default) throws {
        let normalized = targetAppURL.standardizedFileURL
        self.targetAppURL = normalized
        self.lockURL = normalized.deletingLastPathComponent()
            .appendingPathComponent("\(normalized.lastPathComponent).update-lock")
        self.ownerToken = UUID().uuidString
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw UpdateInstallError.scriptFailed("无法打开更新安装锁：\(String(cString: strerror(errno)))")
        }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            close(descriptor)
            if errno == EWOULDBLOCK {
                throw UpdateInstallError.alreadyInstalling
            }
            throw UpdateInstallError.scriptFailed("无法取得更新安装锁：\(String(cString: strerror(errno)))")
        }
        self.fd = descriptor
        _ = ftruncate(descriptor, 0)
        _ = ownerToken.withCString { pwrite(descriptor, $0, strlen($0), 0) }
    }

    /// Used by the detached helper's standardInput. Sharing this descriptor
    /// transfers flock ownership without a release/reacquire race.
    public var fileHandle: FileHandle {
        FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    }

    deinit {
        close(fd)
    }
}
