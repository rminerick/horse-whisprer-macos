import AVFoundation
import CoreML
import FluidAudio
import Foundation

actor NativeASRRuntime {
    private var parakeet: UnifiedAsrManager?
    private var nemotron: StreamingNemotronAsrManager?
    private var loadedKind: ASREngineKind?
    private var cpuOnly = false
    private var streamID: UUID?
    private var converter = StreamingPCMConverter()
    private var sampleDuration: TimeInterval = 0
    private let root: URL

    init(root: URL = NativeModelStore.defaultRoot) { self.root = root }

    nonisolated static var isSupported: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    static func download(kind: ASREngineKind, to directory: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard isSupported else { throw NativeASRError.unsupportedPlatform }
        switch kind {
        case .parakeet:
            let manager = UnifiedAsrManager()
            do {
                try await manager.loadModels(to: directory, progressHandler: { progress($0.fractionCompleted) })
                await manager.cleanup()
            } catch { await manager.cleanup(); throw error }
        case .nemotron:
            let manager = StreamingNemotronAsrManager(requestedChunkSize: .ms1120)
            do {
                try await manager.loadModels(to: directory, progressHandler: { progress($0.fractionCompleted) })
                await manager.cleanup()
            } catch { await manager.cleanup(); throw error }
        case .whisper: throw NativeASRError.unsupportedModel
        }
    }

    private func prepare(_ model: ASRModelDescriptor, options: TranscriptionOptions) async throws {
        guard Self.isSupported else { throw NativeASRError.unsupportedPlatform }
        guard let directory = NativeModelStore.installedDirectory(for: model, root: root) else { throw NativeASRError.modelNotInstalled }
        if loadedKind == model.engineKind, cpuOnly == !options.useGPU { return }
        await unload()
        let config = MLModelConfiguration()
        config.computeUnits = options.useGPU ? .cpuAndNeuralEngine : .cpuOnly
        switch model.engineKind {
        case .parakeet:
            let manager = UnifiedAsrManager(configuration: config)
            try await manager.loadModels(from: directory.appendingPathComponent(Repo.parakeetUnified.folderName))
            parakeet = manager
        case .nemotron:
            let manager = StreamingNemotronAsrManager(configuration: config, requestedChunkSize: .ms1120)
            try await manager.loadModels(from: directory.appendingPathComponent(Repo.nemotronStreaming1120.folderName))
            nemotron = manager
        case .whisper: throw NativeASRError.unsupportedModel
        }
        loadedKind = model.engineKind
        cpuOnly = !options.useGPU
        try Task.checkCancellation()
    }

    func transcribe(audioURL: URL, model: ASRModelDescriptor, options: TranscriptionOptions) async throws -> TranscriptionResult {
        try await prepare(model, options: options)
        let samples = try AudioConverter().resampleAudioFile(audioURL)
        try Task.checkCancellation()
        guard let parakeet else { throw NativeASRError.unsupportedModel }
        let text = try await parakeet.transcribe(samples)
        try Task.checkCancellation()
        return TranscriptionResult(text: text, duration: Double(samples.count) / 16_000)
    }

    func begin(model: ASRModelDescriptor, options: TranscriptionOptions) async throws -> any StreamingASRSession {
        try await prepare(model, options: options)
        guard let nemotron else { throw NativeASRError.unsupportedModel }
        await nemotron.reset()
        try Task.checkCancellation()
        let id = UUID()
        streamID = id
        sampleDuration = 0
        converter = StreamingPCMConverter()
        return NativeStreamingSession(runtime: self, id: id)
    }

    func append(_ chunk: DictationAudioChunk, id: UUID) async throws -> String {
        try Task.checkCancellation()
        guard streamID == id, let nemotron else { throw NativeASRError.sessionEnded }
        let samples = try converter.convert(chunk)
        if !samples.isEmpty { try await nemotron.appendAudio(Self.pcmBuffer(samples)) }
        try await nemotron.processBufferedAudio()
        try Task.checkCancellation()
        sampleDuration += Double(chunk.samples.count) / chunk.sampleRate
        return await nemotron.getPartialTranscript()
    }

    func finish(id: UUID) async throws -> TranscriptionResult {
        guard streamID == id, let nemotron else { throw NativeASRError.sessionEnded }
        let tail = try converter.finish()
        if !tail.isEmpty {
            try await nemotron.appendAudio(Self.pcmBuffer(tail))
            try await nemotron.processBufferedAudio()
        }
        let text = try await nemotron.finish()
        try Task.checkCancellation()
        streamID = nil
        return TranscriptionResult(text: text, duration: sampleDuration)
    }

    nonisolated private static func pcmBuffer(_ samples: [Float]) throws -> sending AVAudioPCMBuffer {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw NativeASRError.invalidAudio
        }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        return buffer
    }

    func cancel(id: UUID) async {
        guard streamID == id else { return }
        streamID = nil
        await nemotron?.reset()
    }

    func unload() async {
        streamID = nil
        await parakeet?.cleanup()
        await nemotron?.cleanup()
        parakeet = nil
        nemotron = nil
        loadedKind = nil
    }
}

private struct NativeStreamingSession: StreamingASRSession {
    let runtime: NativeASRRuntime
    let id: UUID
    func append(_ chunk: DictationAudioChunk) async throws -> String { try await runtime.append(chunk, id: id) }
    func finish() async throws -> TranscriptionResult { try await runtime.finish(id: id) }
    func cancel() async { await runtime.cancel(id: id) }
}

final class DictationEngineRouter: ASREngine, Sendable {
    let id = "local"
    let displayName = "Local dictation"
    let whisper: WhisperCLIEngine
    let native: NativeASRRuntime
    init(whisper: WhisperCLIEngine, native: NativeASRRuntime) { self.whisper = whisper; self.native = native }
    func isConfigured() -> Bool { whisper.isConfigured() }
    func prepareForTermination() { whisper.prepareForTermination() }
    func transcribe(audioURL: URL, model: ASRModelDescriptor, options: TranscriptionOptions) async throws -> TranscriptionResult {
        if model.engineKind == .whisper {
            await native.unload()
            return try await whisper.transcribe(audioURL: audioURL, model: model, options: options)
        }
        return try await native.transcribe(audioURL: audioURL, model: model, options: options)
    }
    func makeStreamingSession(model: ASRModelDescriptor, options: TranscriptionOptions) async throws -> any StreamingASRSession {
        try await native.begin(model: model, options: options)
    }
}
