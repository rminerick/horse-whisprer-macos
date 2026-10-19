import XCTest
import FluidAudio
@testable import HorseWhisprer

/// Opt-in inference check. Downloads models into an isolated directory and uses
/// a supplied speech fixture; ordinary regression tests never access the network.
final class NativeModelSmokeTests: XCTestCase {
    func testRealParakeetAndNemotronInference() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let rootPath = env["HORSE_NATIVE_SMOKE_ROOT"], let audioPath = env["HORSE_NATIVE_SMOKE_AUDIO"] else {
            throw XCTSkip("Set HORSE_NATIVE_SMOKE_ROOT and HORSE_NATIVE_SMOKE_AUDIO to run real inference")
        }
        let root = URL(fileURLWithPath: rootPath)
        let audio = URL(fileURLWithPath: audioPath)
        let samples = try AudioConverter().resampleAudioFile(audio)
        let options = TranscriptionOptions(languageCode: "en", suppressTimestamps: true, useGPU: true)
        let runtime = NativeASRRuntime(root: root)
        for model in ModelCatalogService().nativeModels {
            let directory = root.appendingPathComponent(model.id)
            if NativeModelStore.installedDirectory(for: model, root: root) == nil {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try await NativeASRRuntime.download(kind: model.engineKind, to: directory) { _ in }
                let record = InstalledModelRecord(modelID: model.id, relativePath: model.id, fileSizeBytes: 0, sha256: "", installedAt: Date())
                try JSONEncoder().encode(record).write(to: directory.appendingPathComponent("installed.json"))
            }
            let result: TranscriptionResult
            if model.engineKind.isStreaming {
                let session = try await runtime.begin(model: model, options: options)
                var partial = ""
                for start in stride(from: 0, to: samples.count, by: 4096) {
                    partial = try await session.append(.init(samples: Array(samples[start..<min(start + 4096, samples.count)]), sampleRate: 16_000))
                }
                XCTAssertFalse(partial.isEmpty, "Nemotron must emit text before finish")
                result = try await session.finish()
                // A second empty session must not repeat the previous utterance.
                let next = try await runtime.begin(model: model, options: options)
                let empty = try await next.finish()
                XCTAssertTrue(empty.text.isEmpty)
            } else {
                result = try await runtime.transcribe(audioURL: audio, model: model, options: options)
            }
            print("NATIVE_SMOKE \(model.id): \(result.text)")
            XCTAssertTrue(result.text.lowercased().contains("quick brown fox"), result.text)
            XCTAssertTrue(result.text.lowercased().contains("lazy dog"), result.text)
        }
        await runtime.unload()
    }
}
