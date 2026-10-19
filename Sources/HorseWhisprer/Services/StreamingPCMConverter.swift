import AVFoundation
import Foundation
import os

/// One converter per recording preserves resampling phase across microphone
/// chunks. Finishing each chunk as a standalone file would add boundary artifacts.
final class StreamingPCMConverter {
    private var converter: AVAudioConverter?
    private var inputRate: Double?
    private let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!

    func convert(_ chunk: DictationAudioChunk) throws -> [Float] {
        guard !chunk.samples.isEmpty, chunk.sampleRate.isFinite, chunk.sampleRate > 0,
              chunk.samples.count <= 1_000_000 else { throw NativeASRError.invalidAudio }
        if let inputRate, inputRate != chunk.sampleRate { throw NativeASRError.invalidAudio }
        inputRate = chunk.sampleRate
        guard let inputFormat = AVAudioFormat(standardFormatWithSampleRate: chunk.sampleRate, channels: 1),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(chunk.samples.count)),
              let data = input.floatChannelData?[0] else { throw NativeASRError.invalidAudio }
        input.frameLength = input.frameCapacity
        chunk.samples.withUnsafeBufferPointer { data.update(from: $0.baseAddress!, count: $0.count) }
        if chunk.sampleRate == 16_000 { return chunk.samples }
        if converter == nil {
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
            converter?.primeMethod = .none
        }
        guard let converter else { throw NativeASRError.invalidAudio }
        return try render(converter: converter, input: input, finish: false)
    }

    func finish() throws -> [Float] {
        guard let converter else { return [] }
        return try render(converter: converter, input: nil, finish: true)
    }

    private func render(converter: AVAudioConverter, input: AVAudioPCMBuffer?, finish: Bool) throws -> [Float] {
        let capacity = AVAudioFrameCount((Double(input?.frameLength ?? 0) * 16_000 / (inputRate ?? 16_000)).rounded(.up)) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { throw NativeASRError.invalidAudio }
        let supplied = OSAllocatedUnfairLock(initialState: false)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, status in
            let first = supplied.withLock { value in let first = !value; value = true; return first }
            if first, let input {
                status.pointee = .haveData
                return input
            }
            status.pointee = finish ? .endOfStream : .noDataNow
            return nil
        }
        if let error { throw error }
        guard status != .error else { throw NativeASRError.invalidAudio }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}
