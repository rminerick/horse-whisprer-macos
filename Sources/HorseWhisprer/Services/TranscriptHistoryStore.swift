import Foundation

/// Keeps recent transcripts so one that could not be inserted is never lost.
/// Nothing touches the disk unless the user chooses `HistoryRetention.onDisk`.
@MainActor
final class TranscriptHistoryStore: ObservableObject {
    @Published private(set) var records: [TranscriptRecord] = []
    private(set) var retention: HistoryRetention

    var latestTranscript: String? { records.first?.text }

    private let fileURL: URL?
    private let limit: Int
    private let fileManager: FileManager

    init(retention: HistoryRetention, fileURL: URL? = TranscriptHistoryStore.defaultFileURL(),
         limit: Int = 200, fileManager: FileManager = .default) {
        self.retention = retention
        self.fileURL = fileURL
        self.limit = max(1, limit)
        self.fileManager = fileManager

        switch retention {
        case .onDisk: records = load()
        case .off, .untilQuit: removeFile()
        }
    }

    nonisolated static func defaultFileURL(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        supportDirectory: URL? = nil
    ) -> URL? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty,
              let directory = supportDirectory ?? (try? AppPaths.applicationSupportDirectory()) else { return nil }
        // Preserve the production file; development and other bundle identities
        // must never read or delete it using their independent preferences.
        let fileName = bundleIdentifier == "com.rminerick.HorseWhisprer"
            ? "history.json" : "history-\(bundleIdentifier).json"
        return directory.appendingPathComponent(fileName)
    }

    func setRetention(_ newValue: HistoryRetention) {
        guard newValue != retention else { return }
        retention = newValue
        switch newValue {
        case .off:
            records = []
            removeFile()
        case .untilQuit:
            removeFile()
        case .onDisk:
            save()
        }
    }

    func add(_ record: TranscriptRecord) {
        guard retention != .off else { return }
        records.insert(record, at: 0)
        if records.count > limit { records.removeLast(records.count - limit) }
        persistIfNeeded()
    }

    func remove(id: TranscriptRecord.ID) {
        records.removeAll { $0.id == id }
        persistIfNeeded()
    }

    func clear() {
        records = []
        removeFile()
    }

    private func persistIfNeeded() {
        if retention == .onDisk { save() }
    }

    private func load() -> [TranscriptRecord] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([TranscriptRecord].self, from: data) else { return [] }
        return Array(decoded.prefix(limit))
    }

    private func save() {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(records) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
            // Dictated text is private: readable by the owner only.
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            AudioDiagnostics.shared.log("History", "save failed: \(error.localizedDescription)")
        }
    }

    private func removeFile() {
        guard let fileURL, fileManager.fileExists(atPath: fileURL.path) else { return }
        try? fileManager.removeItem(at: fileURL)
    }
}
