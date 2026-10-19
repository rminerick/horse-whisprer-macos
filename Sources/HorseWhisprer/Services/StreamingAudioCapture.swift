import AVFoundation
import Foundation

/// Bounded buffering fails explicitly rather than dropping words when inference
/// falls behind. The tap copies only samples; all inference runs off the tap.
final class DictationAudioChannel: Sendable {
    let stream: AsyncThrowingStream<DictationAudioChunk, Error>
    private let continuation: AsyncThrowingStream<DictationAudioChunk, Error>.Continuation

    init(capacity: Int = 256) {
        (stream, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(capacity))
    }
    func yield(_ chunk: DictationAudioChunk) {
        if case .dropped = continuation.yield(chunk) { continuation.finish(throwing: NativeASRError.audioOverflow) }
    }
    func finish(error: Error? = nil) { continuation.finish(throwing: error) }
}

@MainActor
final class StreamingAudioCapture: StreamingAudioCapturing {
    private var engine: AVAudioEngine?
    private var channel: DictationAudioChannel?
    private var configurationObserver: NSObjectProtocol?

    func start() throws -> AsyncThrowingStream<DictationAudioChunk, Error> {
        stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw NativeASRError.invalidAudio }
        let channel = DictationAudioChannel()
        input.installTap(onBus: 0, bufferSize: 4096, format: format,
                         block: Self.makeAudioTap(channel: channel))
        self.engine = engine
        self.channel = channel
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil,
            using: Self.makeConfigurationChangeHandler(channel: channel))
        do {
            engine.prepare()
            try engine.start()
        } catch { stop(); throw error }
        return channel.stream
    }

    // AVFAudio invokes these callbacks on its own threads. Creating them in a
    // nonisolated context avoids inheriting start()'s MainActor runtime check.
    // Only the Sendable channel crosses the boundary; PCM is copied before return.
    nonisolated static func makeAudioTap(
        channel: DictationAudioChannel
    ) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, _ in
            guard let channels = buffer.floatChannelData else {
                channel.finish(error: NativeASRError.invalidAudio)
                return
            }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }
            let channelCount = Int(buffer.format.channelCount)
            let stride = buffer.stride
            var samples = [Float](repeating: 0, count: count)
            for c in 0..<channelCount {
                for i in 0..<count { samples[i] += channels[c][i * stride] / Float(channelCount) }
            }
            channel.yield(DictationAudioChunk(samples: samples, sampleRate: buffer.format.sampleRate))
        }
    }

    nonisolated static func makeConfigurationChangeHandler(
        channel: DictationAudioChannel
    ) -> @Sendable (Notification) -> Void {
        { _ in channel.finish(error: NativeASRError.invalidAudio) }
    }

    func stop() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        channel?.finish()
        channel = nil
    }
}
