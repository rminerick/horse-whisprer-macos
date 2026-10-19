import Foundation

enum ASREngineKind: String, Sendable {
    case whisper, parakeet, nemotron
    var isStreaming: Bool { self == .nemotron }
    var displayName: String {
        switch self {
        case .whisper: "Whisper CLI"
        case .parakeet: "Parakeet · Core ML"
        case .nemotron: "Nemotron · Streaming Core ML"
        }
    }
}

enum NativeASRError: LocalizedError {
    case unsupportedModel, modelNotInstalled, unsupportedPlatform, audioOverflow, invalidAudio, sessionEnded
    var errorDescription: String? {
        switch self {
        case .unsupportedModel: "This engine does not support the selected model."
        case .modelNotInstalled: "Download the selected model in Settings before dictating."
        case .unsupportedPlatform: "Parakeet and Nemotron require Apple Silicon. Select a Whisper model on this Mac."
        case .audioOverflow: "Transcription could not keep up with the microphone. Please try a shorter recording."
        case .invalidAudio: "The microphone audio format could not be processed."
        case .sessionEnded: "The transcription session has ended."
        }
    }
}

/// Copied samples cross the real-time audio callback boundary; AVAudioPCMBuffer never does.
struct DictationAudioChunk: Sendable {
    let samples: [Float]
    let sampleRate: Double
    let capturedAt = ProcessInfo.processInfo.systemUptime
}

protocol StreamingASRSession: Sendable {
    func append(_ chunk: DictationAudioChunk) async throws -> String
    func finish() async throws -> TranscriptionResult
    func cancel() async
}

@MainActor
protocol StreamingAudioCapturing {
    func prepare() throws
    func start() async throws -> AsyncThrowingStream<DictationAudioChunk, Error>
    func stop()
}

extension StreamingAudioCapturing {
    func prepare() throws {}
}
