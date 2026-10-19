import AVFoundation
import Foundation

enum CueWaveData {
    /// AVAudioPlayer accepts an in-memory RIFF file. Encode interleaved PCM16;
    /// the renderer's noninterleaved Float buffers are not file-format payloads.
    static func encode(_ buffer: AVAudioPCMBuffer, leadingSilence: TimeInterval, trailingSilence: TimeInterval = 0) throws -> Data {
        guard let samples = buffer.floatChannelData, leadingSilence.isFinite,
              leadingSilence >= 0, leadingSilence <= 60,
              trailingSilence.isFinite, trailingSilence >= 0, trailingSilence <= 60 else { throw CuePlayerError.conversionFailed }
        let channels = Int(buffer.format.channelCount)
        let rate = Int(buffer.format.sampleRate)
        let silenceFrames = Int((leadingSilence * Double(rate)).rounded())
        let trailingFrames = Int((trailingSilence * Double(rate)).rounded())
        let byteCount = (silenceFrames + Int(buffer.frameLength) + trailingFrames) * channels * 2
        guard byteCount <= Int(UInt32.max) - 36 else { throw CuePlayerError.bufferAllocationFailed }
        var data = Data()
        func word<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8); word(UInt32(36 + byteCount))
        data.append(contentsOf: "WAVEfmt ".utf8); word(UInt32(16))
        word(UInt16(1)); word(UInt16(channels)); word(UInt32(rate))
        word(UInt32(rate * channels * 2)); word(UInt16(channels * 2)); word(UInt16(16))
        data.append(contentsOf: "data".utf8); word(UInt32(byteCount))
        data.append(Data(count: silenceFrames * channels * 2))
        for frame in 0..<Int(buffer.frameLength) {
            for channel in 0..<channels {
                let sample = samples[channel][frame * buffer.stride]
                let finite = sample.isFinite ? sample : 0
                word(Int16((min(1, max(-1, finite)) * 32767).rounded()))
            }
        }
        data.append(Data(count: trailingFrames * channels * 2))
        return data
    }
}
