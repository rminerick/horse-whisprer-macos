import AudioToolbox
import AVFoundation
import FluidAudio
import XCTest
@testable import HorseWhisprer

/// Opt-in hardware replay. The fixture player and capture queue target the supplied
/// virtual device only; neither the system input nor output selection is changed.
@MainActor
final class StartupAudioIntegrationTests: XCTestCase {
    func testRecordedSpeechThroughPreparedInputPreservesOpeningWords() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let manifest = env["HORSE_STARTUP_FIXTURES"], let uid = env["HORSE_STARTUP_DEVICE_UID"],
              let root = env["HORSE_NATIVE_SMOKE_ROOT"] else {
            throw XCTSkip("Set HORSE_STARTUP_FIXTURES, HORSE_STARTUP_DEVICE_UID, and HORSE_NATIVE_SMOKE_ROOT for hardware replay")
        }
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: URL(fileURLWithPath: manifest)))
        XCTAssertFalse(fixtures.isEmpty)
        let runtime = NativeASRRuntime(root: URL(fileURLWithPath: root))
        let model = try XCTUnwrap(ModelCatalogService().model(for: "nemotron-streaming"))
        let options = TranscriptionOptions(languageCode: "en", suppressTimestamps: true, useGPU: true)
        for fixture in fixtures {
            let path = fixture.path
            let original = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: path))
            // Remove fixture padding so speech begins within 20 ms of playback.
            let onset = original.firstIndex { abs($0) > 0.002 } ?? 0
            let samples = Array(original.dropFirst(max(0, onset - 320)))
            let baselineSession = try await runtime.begin(model: model, options: options)
            _ = try await baselineSession.append(.init(samples: samples, sampleRate: 16_000))
            let baseline = try await baselineSession.finish()
            let input = try SystemQueuedAudioInput(deviceUID: uid)
            let output = try FixtureOutput(samples: samples, deviceUID: uid)
            defer { input.stop(); output.stop() }
            // The prepared input stays stopped, including through this idle period.
            try await Task.sleep(for: .milliseconds(250))
            let playbackStart = ProcessInfo.processInfo.systemUptime
            try output.start()
            // Output hardware setup is fixture setup, not dictation startup.
            // Speech is already playing when we trigger capture below.
            let trigger = ProcessInfo.processInfo.systemUptime
            let outputStartMs = (trigger - playbackStart) * 1_000
            let chunks = try await input.start()
            let captured = Task { () throws -> [DictationAudioChunk] in
                var result: [DictationAudioChunk] = []
                for try await chunk in chunks { result.append(chunk) }
                return result
            }
            try await Task.sleep(for: .seconds(Double(samples.count) / 16_000 + 0.5))
            input.stop(); output.stop()
            let recorded = try await captured.value
            let first = try XCTUnwrap(recorded.first)
            let firstMs = (first.capturedAt - trigger) * 1_000
            XCTAssertLessThan(firstMs, 250)
            let session = try await runtime.begin(model: model, options: options)
            for chunk in recorded { _ = try await session.append(chunk) }
            let result = try await session.finish()
            let opening = words(fixture.opening)
            XCTAssertGreaterThanOrEqual(opening.count, 5)
            XCTAssertEqual(Array(words(result.text).prefix(opening.count)), opening, result.text)
            print("STARTUP_REPLAY fixture=\(URL(fileURLWithPath: path).lastPathComponent) fixtureOutputStartMs=\(Int(outputStartMs)) firstBufferMs=\(Int(firstMs)) capturedSeconds=\(Double(recorded.reduce(0) { $0 + $1.samples.count }) / 16_000) baseline=\(baseline.text) captured=\(result.text)")
        }
        await runtime.unload()
    }

    private struct Fixture: Decodable { let path: String; let opening: String }

    private func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}

@MainActor private final class FixtureOutput {
    private var queue: AudioQueueRef?
    init(samples: [Float], deviceUID: String) throws {
        var format = AudioStreamBasicDescription(mSampleRate: 16_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
            mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        try Self.check(AudioQueueNewOutput(&format, Self.callback(), nil, nil, nil, 0, &queue))
        do {
            let q = try XCTUnwrap(queue)
            var uid = deviceUID as CFString
            try Self.check(AudioQueueSetProperty(q, kAudioQueueProperty_CurrentDevice, &uid, UInt32(MemoryLayout<CFString>.size)))
            var buffer: AudioQueueBufferRef?
            try Self.check(AudioQueueAllocateBuffer(q, UInt32(samples.count * 4), &buffer))
            let b = try XCTUnwrap(buffer)
            samples.withUnsafeBytes { b.pointee.mAudioData.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            b.pointee.mAudioDataByteSize = UInt32(samples.count * 4)
            try Self.check(AudioQueueEnqueueBuffer(q, b, 0, nil))
        } catch { stop(); throw error }
    }
    func start() throws { try Self.check(AudioQueueStart(try XCTUnwrap(queue), nil)) }
    func stop() { if let queue { AudioQueueDispose(queue, true) }; queue = nil }
    private nonisolated static func callback() -> AudioQueueOutputCallback { { _, _, _ in } }
    private static func check(_ status: OSStatus) throws {
        if status != 0 { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}
