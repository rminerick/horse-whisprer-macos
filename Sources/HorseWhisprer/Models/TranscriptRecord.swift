import Foundation

/// One dictated transcript kept in History.
struct TranscriptRecord: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let text: String
    let targetApplicationName: String?
    let outcome: String
    let modelName: String
    let recordedDuration: TimeInterval
    let reachedTarget: Bool

    init(id: UUID = UUID(), createdAt: Date = Date(), text: String, targetApplicationName: String?,
         outcome: String, modelName: String, recordedDuration: TimeInterval, reachedTarget: Bool) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
        self.targetApplicationName = targetApplicationName
        self.outcome = outcome
        self.modelName = modelName
        self.recordedDuration = recordedDuration
        self.reachedTarget = reachedTarget
    }

    var targetDisplayName: String {
        guard let targetApplicationName, !targetApplicationName.isEmpty else { return "Unknown app" }
        return targetApplicationName
    }

    var durationLabel: String {
        let seconds = max(0, Int(recordedDuration.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

enum HistoryRetention: String, CaseIterable, Identifiable, Sendable {
    case off
    case untilQuit
    case onDisk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Never"
        case .untilQuit: return "Until I quit"
        case .onDisk: return "On this Mac"
        }
    }

    var detail: String {
        switch self {
        case .off:
            return "Nothing is kept after a dictation ends. A transcript that could not be inserted is lost."
        case .untilQuit:
            return "Transcripts stay in memory so you can copy or insert them again. They are gone when Horse Whisprer quits."
        case .onDisk:
            return "The most recent transcripts are saved as a file in Application Support on this Mac. They are never uploaded."
        }
    }
}
