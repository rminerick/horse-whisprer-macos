import Darwin
import Foundation

/// An advisory lock distinguishes abandoned staging directories from downloads
/// owned by another running app instance. The OS releases it on process exit.
final class NativeDownloadLease {
    private let descriptor: Int32
    init(directory: URL) throws {
        let path = directory.appendingPathComponent(".lease").path
        descriptor = Darwin.open(path, O_CREAT | O_EXCL | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.EWOULDBLOCK)
        }
    }
    deinit { Darwin.close(descriptor) }

    static func recoverAbandonedDownloads(in root: URL) {
        let manager = FileManager.default
        guard let directories = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for directory in directories {
            let name = directory.lastPathComponent
            guard name.hasPrefix(".download-"), UUID(uuidString: String(name.dropFirst(10))) != nil else { continue }
            // Don't create a lease: a live writer may be between mkdir and open.
            let fd = Darwin.open(directory.appendingPathComponent(".lease").path, O_RDWR | O_NOFOLLOW)
            guard fd >= 0 else { continue }
            defer { Darwin.close(fd) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { continue }
            try? manager.removeItem(at: directory)
        }
    }
}
