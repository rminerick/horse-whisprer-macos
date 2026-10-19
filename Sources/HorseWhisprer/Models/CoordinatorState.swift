import Foundation

/// How a finished dictation reached (or failed to reach) the target app.
enum DictationDelivery: Equatable, Sendable {
    case inserted(InsertionOutcome)
    case insertedLive
    case liveInsertionPaused
    /// Accessibility was missing at insertion time, so the text went to the clipboard.
    case copiedWithoutAccessibility
    case notInserted

    var label: String {
        switch self {
        case .inserted(.pasted): return "Pasted"
        case .inserted(.typed): return "Typed"
        case .inserted(.copiedOnly): return "Copied"
        case .inserted(.failed): return "Not inserted"
        case .insertedLive: return "Inserted live"
        case .liveInsertionPaused: return "Live insertion paused"
        case .copiedWithoutAccessibility: return "Copied, Accessibility access missing"
        case .notInserted: return "Not inserted"
        }
    }

    /// True when the complete transcript ended up in the target field.
    var reachedTarget: Bool {
        switch self {
        case .inserted(.pasted), .inserted(.typed), .insertedLive: return true
        default: return false
        }
    }
}

/// Structured companion to `CoordinatorState.status` so the interface never parses status strings.
enum DictationActivity: Equatable, Sendable {
    enum RecordingDetail: Equatable, Sendable {
        case insertOnStop
        case bufferingAudio
        case insertingLive
        case liveInsertionPaused
    }

    case idle
    case starting
    case recording(RecordingDetail)
    case stopping
    case transcribing
    case finished(DictationDelivery)
    case cancelled
    case failed

    /// A session is in flight: capturing, stopping or transcribing.
    var isInFlight: Bool {
        switch self {
        case .starting, .recording, .stopping, .transcribing: return true
        case .idle, .finished, .cancelled, .failed: return false
        }
    }
}

struct CoordinatorState: Equatable {
    let isRecording: Bool
    let isBusy: Bool
    let status: String
    let transcribedText: String?
    let errorMessage: String?
    var activity: DictationActivity = .idle
}

/// A transcript the coordinator produced, with enough context for history.
struct CompletedDictation: Equatable, Sendable {
    let text: String
    let modelName: String
    let recordedDuration: TimeInterval
    let delivery: DictationDelivery
}

/// Active session detail must survive presentation, including live insertion's
/// fallback and paused states. Idle setup/error precedence is unchanged.
func dictationStatusSummary(isRecording: Bool, isBusy: Bool, status: String,
                            requiresSetup: Bool, lastError: String?) -> String {
    if isRecording || isBusy { return status }
    if requiresSetup { return "Setup required" }
    return lastError ?? status
}
