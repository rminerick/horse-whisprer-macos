import Foundation

enum StreamingInsertionMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case verified
    case appendOnly
    case onStop

    var id: String { rawValue }
    var title: LocalizedStringResource {
        switch self {
        case .verified: return "Verified streaming"
        case .appendOnly: return "Append-only streaming"
        case .onStop: return "Insert when finished"
        }
    }
    var explanation: LocalizedStringResource {
        switch self {
        case .verified: return "Inserts and revises words while protecting your existing text and corrections. Unsupported fields receive text when recording ends."
        case .appendOnly: return "Waits briefly for stable words, then types them without revising earlier text. Requires Input Monitoring and a readable cursor, but does not need readable text or permission to move the cursor. Delivery cannot be verified in this mode."
        case .onStop: return "Inserts the complete transcript after you stop recording."
        }
    }
}

@MainActor
final class ConfigurableLiveTextInsertion: LiveDictationInserting {
    private let verified: any LiveDictationInserting
    private let appendOnly: any LiveDictationInserting
    private var current: any LiveDictationInserting
    init(verified: any LiveDictationInserting = LiveTextInsertion(),
         appendOnly: any LiveDictationInserting = AppendOnlyTextInsertion()) {
        self.verified = verified
        self.appendOnly = appendOnly
        current = verified
    }
    var pauseReason: LiveInsertionPauseReason? { current.pauseReason }
    func begin() { begin(mode: .verified) }
    func begin(mode: StreamingInsertionMode) {
        cancel()
        current = mode == .appendOnly ? appendOnly : verified
        current.begin()
    }
    func update(_ transcript: String) async -> LiveInsertionResult { await current.update(transcript) }
    func finish(_ transcript: String) async -> LiveInsertionResult { await current.finish(transcript) }
    func cancel() { verified.cancel(); appendOnly.cancel() }
}

/// Delayed pastes keep a normal clipboard item available for remote clipboard sharing.
enum ClipboardPasteTiming: String, CaseIterable, Identifiable, Sendable {
    case standard
    case halfSecond
    case oneSecond
    case twoSeconds
    case fiveSeconds

    var id: String { rawValue }
    var title: LocalizedStringResource {
        switch self {
        case .standard: return "Immediate (restore clipboard)"
        case .halfSecond: return "0.5 seconds (keep clipboard)"
        case .oneSecond: return "1 second (keep clipboard)"
        case .twoSeconds: return "2 seconds (keep clipboard)"
        case .fiveSeconds: return "5 seconds (keep clipboard)"
        }
    }
    var delayNanoseconds: UInt64 {
        switch self {
        case .standard: return 0
        case .halfSecond: return 500_000_000
        case .oneSecond: return 1_000_000_000
        case .twoSeconds: return 2_000_000_000
        case .fiveSeconds: return 5_000_000_000
        }
    }
}
