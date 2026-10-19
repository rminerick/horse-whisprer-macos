import XCTest
@testable import HorseWhisprer

@MainActor
final class TemporaryFileCleanupTests: XCTestCase {
    func testAudioRemovedAfterSuccessfulTranscription() async throws {
        let fixture = try sessionFixture()
        _ = try await fixture.coordinator.toggleDictation()
        _ = try await fixture.coordinator.toggleDictation()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.recorder.recordingURL.path))
        XCTAssertEqual(fixture.insertion.texts, ["test dictation"])
    }

    func testAudioRemovedAfterFailedTranscription() async throws {
        let fixture = try sessionFixture()
        await fixture.engine.setFailure()
        _ = try await fixture.coordinator.toggleDictation()
        let result = try await fixture.coordinator.toggleDictation()
        XCTAssertEqual(result.status, "Failed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.recorder.recordingURL.path))
    }

    func testAudioRemovedAfterCancellation() async throws {
        let fixture = try sessionFixture()
        let gate = TestGate()
        await fixture.engine.setGate(gate)
        _ = try await fixture.coordinator.toggleDictation()
        let stop = Task { try await fixture.coordinator.toggleDictation() }
        await gate.waitUntilEntered()
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.recorder.recordingURL.path))
        stop.cancel()
        await gate.open()
        _ = try await stop.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.recorder.recordingURL.path))
    }

    func testTerminationRemovesActiveAudioAndDiscardsPreparedRecorder() async throws {
        let fixture = try sessionFixture()
        _ = try await fixture.coordinator.toggleDictation()
        fixture.coordinator.prepareForTermination()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.recorder.recordingURL.path))
        XCTAssertTrue(fixture.recorder.discarded)
    }

    func testDefaultRecorderInitializationDoesNotOpenAudioHardware() throws {
        let root = try temporaryDirectory()
        var creations = 0
        let recorder = RecordingController(newRecordingURL: { root.appendingPathComponent("audio.wav") },
            makeAudioRecorder: { url, _ in
                creations += 1
                try Data().write(to: url)
                return FileRecorderSpy()
            })
        XCTAssertEqual(creations, 0, "Launching with a streaming model must not initialize the legacy recorder")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        let audio = try recorder.startRecording()
        XCTAssertEqual(creations, 1, "The legacy recording path must still prepare on demand")
        XCTAssertEqual(recorder.stopRecording(shouldPrewarmNextInput: false), audio)
    }

    func testPreparedAndWarmupFilesRemovedSynchronouslyOnShutdown() async throws {
        let root = try temporaryDirectory()
        let started = expectation(description: "warmup started")
        let recorder = RecordingController(prepareOnInit: true, newRecordingURL: { root.appendingPathComponent(UUID().uuidString + ".wav") },
            makeAudioRecorder: { url, _ in
                try Data().write(to: url)
                return FileRecorderSpy(onWarmup: { started.fulfill() })
            })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 1)
        let warmup = Task { await recorder.prepareForRecording() }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 2)
        recorder.discardPreparedRecording()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        await warmup.value
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testFailedRecorderStartRemovesPreparedFile() throws {
        let root = try temporaryDirectory()
        let recorder = RecordingController(newRecordingURL: { root.appendingPathComponent(UUID().uuidString + ".wav") },
            makeAudioRecorder: { url, _ in
                try Data().write(to: url)
                return FileRecorderSpy(canRecord: false)
            })
        XCTAssertThrowsError(try recorder.startRecording())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testQueuedPrewarmCannotRecreateFilesAfterShutdown() async throws {
        let root = try temporaryDirectory()
        let unexpectedWarmup = expectation(description: "no warmup after shutdown")
        unexpectedWarmup.isInverted = true
        let recorder = RecordingController(newRecordingURL: { root.appendingPathComponent(UUID().uuidString + ".wav") },
            makeAudioRecorder: { url, _ in
                try Data().write(to: url)
                return FileRecorderSpy(onWarmup: { unexpectedWarmup.fulfill() })
            })
        let ownedAudio = try recorder.startRecording()
        _ = recorder.stopRecording()
        recorder.discardPreparedRecording()
        await fulfillment(of: [unexpectedWarmup], timeout: 0.1)
        // The completed recording belongs to the coordinator until consumed.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [ownedAudio.lastPathComponent])
    }

    func testOutputShutdownRemovesOnlyOwnedDirectoriesAndPreventsNewOnes() throws {
        let root = try temporaryDirectory()
        let sentinel = root.appendingPathComponent("unrelated.txt")
        try Data("keep".utf8).write(to: sentinel)
        let files = TranscriptionOutputFiles()
        let owned = try files.create(in: root)
        try Data("private transcript".utf8).write(to: owned.appendingPathComponent("transcript.txt"))
        files.prepareForTermination()
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertThrowsError(try files.create(in: root))
    }

    func testEngineCleansPartialTranscriptOnFailure() async throws {
        let fixture = try engineFixture(tail: "exit 3")
        do {
            _ = try await fixture.engine.transcribe(audioURL: fixture.audio, model: ModelCatalogService().defaultModel,
                options: TranscriptionOptions(languageCode: "en", suppressTimestamps: true, useGPU: false))
            XCTFail("Expected CLI failure")
        } catch { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.outputs.path), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.audio.path), "Engine must not delete caller-owned input")
    }

    func testEngineCleansPartialTranscriptOnCancellationAndTermination() async throws {
        try await assertCancelledEngineCleansOutput(terminating: true)
    }

    func testEngineCleansPartialTranscriptOnCancellationAlone() async throws {
        try await assertCancelledEngineCleansOutput(terminating: false)
    }

    private func assertCancelledEngineCleansOutput(terminating: Bool) async throws {
        let fixture = try engineFixture(tail: "while :; do :; done")
        let task = Task {
            try await fixture.engine.transcribe(audioURL: fixture.audio, model: ModelCatalogService().defaultModel,
                options: TranscriptionOptions(languageCode: "en", suppressTimestamps: true, useGPU: false))
        }
        defer { task.cancel() }
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: fixture.marker.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.marker.path))
        task.cancel()
        if terminating {
            fixture.engine.prepareForTermination()
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.outputs.path), [], "Shutdown cleanup must be synchronous")
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.outputs.path), [])
    }

    private func engineFixture(tail: String) throws -> (engine: WhisperCLIEngine, audio: URL, outputs: URL, marker: URL) {
        let root = try temporaryDirectory()
        let script = root.appendingPathComponent("cli")
        let marker = root.appendingPathComponent("ready")
        let source = """
        #!/bin/sh
        while [ "$#" -gt 0 ]; do
            if [ "$1" = '-of' ]; then shift; output="$1"; fi
            shift
        done
        printf 'partial transcript' > "$output.txt"
        touch '\(marker.path)'
        \(tail)
        """
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        try Data().write(to: root.appendingPathComponent(ModelCatalogService().defaultModel.fileName))
        let audio = root.appendingPathComponent("audio.wav")
        try Data().write(to: audio)
        let settings = makeTestSettings()
        settings.whisperCLIPath = script.path
        settings.modelDirectoryPath = root.path
        let outputs = root.appendingPathComponent("outputs")
        return (WhisperCLIEngine(settings: settings, outputDirectory: outputs), audio, outputs, marker)
    }

    private func sessionFixture() throws -> SessionFixture {
        let settings = makeTestSettings()
        settings.insertBehavior = .copyOnly
        settings.playRecordingCues = false
        let fixture = SessionFixture(settings: settings)
        fixture.recorder.recordingURL = try temporaryDirectory().appendingPathComponent("recording.wav")
        try Data("audio fixture".utf8).write(to: fixture.recorder.recordingURL)
        return fixture
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TemporaryFileCleanupTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

@MainActor
private final class FileRecorderSpy: RecordingAudio {
    let canRecord: Bool
    let onWarmup: () -> Void
    init(canRecord: Bool = true, onWarmup: @escaping () -> Void = {}) {
        self.canRecord = canRecord
        self.onWarmup = onWarmup
    }
    func prepareToRecord() -> Bool { true }
    func record() -> Bool { canRecord }
    func record(forDuration: TimeInterval) -> Bool { onWarmup(); return true }
    func stop() {}
}
