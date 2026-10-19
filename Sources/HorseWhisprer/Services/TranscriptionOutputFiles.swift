import Foundation

// Creation, removal, and shutdown share a lock so shutdown cannot miss a
// directory being created by a concurrently starting engine invocation.
final class TranscriptionOutputFiles: @unchecked Sendable {
    private let lock = NSLock()
    private var directories = Set<URL>()
    private var terminated = false

    func create(in root: URL) throws -> URL {
        try lock.withLock {
            if terminated { throw CancellationError() }
            let url = root.appendingPathComponent("horse-whisprer-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            directories.insert(url)
            return url
        }
    }

    func remove(_ url: URL) {
        lock.withLock {
            try? FileManager.default.removeItem(at: url)
            directories.remove(url)
        }
    }

    func prepareForTermination() {
        lock.withLock {
            terminated = true
            for url in directories { try? FileManager.default.removeItem(at: url) }
            directories.removeAll()
        }
    }
}
