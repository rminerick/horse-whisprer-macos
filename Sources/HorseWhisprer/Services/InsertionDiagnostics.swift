import Foundation

protocol InsertionDiagnosticsLogging: AnyObject {
    func log(_ record: InsertionAttemptRecord)
}

final class InsertionDiagnostics: InsertionDiagnosticsLogging, @unchecked Sendable {
    static let shared = InsertionDiagnostics()

    private let queue = DispatchQueue(label: "com.rminerick.HorseWhisprer.InsertionDiagnostics")
    private let fileURL: URL
    private let formatter: ISO8601DateFormatter

    private init() {
        let logsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/HorseWhisprer", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        fileURL = logsDirectory.appendingPathComponent("text-insertion.log", isDirectory: false)
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func log(_ record: InsertionAttemptRecord) {
        let timestamp = formatter.string(from: record.attemptedAt)
        let target = sanitize(record.targetBundleIdentifier ?? record.targetApplicationName) ?? "unknown"
        let frontmost = sanitize(record.frontmostBundleIdentifier ?? record.frontmostApplicationName) ?? "unknown"
        let pasteboardBefore = record.pasteboardChangeCountBeforeCopy.map(String.init) ?? "nil"
        let pasteboardAfter = record.pasteboardChangeCountAfterCopy.map(String.init) ?? "nil"
        let line = [
            "\(timestamp)",
            "behavior=\(record.requestedBehavior.rawValue)",
            "path=\(record.finalPath.rawValue)",
            "outcome=\(record.outcome.label)",
            "target=\(target)",
            "frontmost=\(frontmost)",
            "restoreAttempted=\(record.restoreAttempted)",
            "waitedForFocusSettle=\(record.waitedForFocusSettle)",
            "focusSettleDelayMs=\(record.focusSettleDelayMilliseconds)",
            "pasteboardBefore=\(pasteboardBefore)",
            "pasteboardAfter=\(pasteboardAfter)",
            "pasteSourceCreated=\(record.pasteEventSourceCreated)",
            "pasteEventsCreated=\(record.pasteEventsCreated)",
            "pasteEventPosted=\(record.pasteEventPosted)",
            "typingAttempted=\(record.typingAttempted)"
        ].joined(separator: " ")

        queue.async { [fileURL] in
            InsertionDiagnostics.rotateIfNeeded(fileURL: fileURL)

            let data = Data((line + "\n").utf8)
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

    private func sanitize(_ value: String?) -> String? {
        value?.replacingOccurrences(of: " ", with: "_")
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
