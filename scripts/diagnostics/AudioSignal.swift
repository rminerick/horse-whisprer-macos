// Records only this diagnostic process's synthetic cue output. Microphone PCM is never saved.
import AppKit
@preconcurrency import AVFoundation
import Foundation
import os

final class AudioDiagnostics: Sendable {
    static let shared = AudioDiagnostics()
    func log(_ component: String, _ message: String) { print("\(ProcessInfo.processInfo.systemUptime) [\(component)] \(message)") }
}
final class Signal: Sendable {
    struct State: Sendable { var samples: [Float] = []; var rate = 0.0; var first = 0.0; var firstSignal = 0.0; var peak: Float = 0 }
    let state = OSAllocatedUnfairLock(initialState: State())
    nonisolated func tap() -> AVAudioNodeTapBlock {
        { [self] buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            let samples = (0..<Int(buffer.frameLength)).map { data[0][$0 * buffer.stride] }
            let peak = samples.map { abs($0) }.max() ?? 0
            state.withLock {
                if $0.first == 0 { $0.first = ProcessInfo.processInfo.systemUptime }
                if peak > 0.001 && $0.firstSignal == 0 { $0.firstSignal = ProcessInfo.processInfo.systemUptime }
                $0.peak = max($0.peak, peak); $0.rate = buffer.format.sampleRate
                $0.samples.append(contentsOf: samples)
            }
        }
    }
    func save(_ name: String, since start: Double) throws {
        let s = state.withLock { $0 }
        print("MEASURE \(name) frames=\(s.samples.count) rate=\(s.rate) peak=\(s.peak) firstMs=\((s.first-start)*1000) signalMs=\((s.firstSignal-start)*1000)")
        guard s.rate > 0, !s.samples.isEmpty else {
            throw NSError(domain: "No process-output samples captured", code: 1)
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: s.rate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(s.samples.count))!
        buffer.frameLength = buffer.frameCapacity
        s.samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        let file = try AVAudioFile(forWriting: URL(fileURLWithPath: "\(CommandLine.arguments[1])/\(name).wav"), settings: format.settings)
        try file.write(from: buffer)
    }
}
