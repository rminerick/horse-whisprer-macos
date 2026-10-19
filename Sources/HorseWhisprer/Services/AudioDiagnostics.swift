import Foundation

final class AudioDiagnostics: @unchecked Sendable {
    static let shared = AudioDiagnostics()

    private let queue = DispatchQueue(label: "com.rminerick.HorseWhisprer.AudioDiagnostics")
    private let fileURL: URL
    private let formatter: ISO8601DateFormatter

    private init() {
        let logsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/HorseWhisprer", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        fileURL = logsDirectory.appendingPathComponent("audio-feedback.log", isDirectory: false)
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func log(_ component: String, _ message: String) {
        let timestamp = formatter.string(from: Date())
        let line = "\(timestamp) [\(component)] \(message)\n"

        queue.async { [fileURL] in
            AudioDiagnostics.rotateIfNeeded(fileURL: fileURL)

            let data = Data(line.utf8)
            if FileManager.default.fileExists(atPath: fileURL.path) == false {
                FileManager.default.createFile(atPath: fileURL.path, contents: data)
                return
            }

            guard let handle = try? FileHandle(forWritingTo: fileURL) else {
                return
            }

            defer {
                try? handle.close()
            }

            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                return
            }
        }
    }

    private static func rotateIfNeeded(fileURL: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.intValue > 262_144 else {
            return
        }

        try? Data().write(to: fileURL, options: .atomic)
    }
}
