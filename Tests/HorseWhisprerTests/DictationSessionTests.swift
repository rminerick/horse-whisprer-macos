import XCTest
@testable import HorseWhisprer

@MainActor
final class DictationSessionTests: XCTestCase {
    func testRepeatedStartWhilePermissionPendingStartsOnlyOnce() async throws {
        let fixture = fixture()
        let gate = TestGate()
        fixture.permissions.gate = gate
        let start = Task { try await fixture.coordinator.toggleDictation() }
        await gate.waitUntilEntered()
        let duplicate = try await fixture.coordinator.toggleDictation()
        XCTAssertTrue(duplicate.isBusy)
        XCTAssertEqual(fixture.recorder.starts, 0)
        await gate.open()
        let started = try await start.value
        XCTAssertTrue(started.isRecording)
        XCTAssertEqual(fixture.recorder.starts, 1)
    }

    func testRepeatedStopWhileCuePendingTranscribesOnlyOnce() async throws {
        let fixture = fixture()
        _ = try await fixture.coordinator.toggleDictation()
        let gate = TestGate()
        fixture.feedback.stopGate = gate
        let stop = Task { try await fixture.coordinator.toggleDictation() }
        await gate.waitUntilEntered()
        let duplicate = try await fixture.coordinator.toggleDictation()
        XCTAssertTrue(duplicate.isBusy)
        XCTAssertEqual(fixture.recorder.stops, 1)
        await gate.open()
        _ = try await stop.value
        let calls = await fixture.engine.calls
        XCTAssertEqual(calls, 1)
    }

    func testStartDuringTranscriptionCannotOverwriteRecordingState() async throws {
        let fixture = fixture()
        let gate = TestGate()
        await fixture.engine.setGate(gate)
        _ = try await fixture.coordinator.toggleDictation()
        let stop = Task { try await fixture.coordinator.toggleDictation() }
        await gate.waitUntilEntered()
        let blocked = try await fixture.coordinator.toggleDictation()
        XCTAssertTrue(blocked.isBusy)
        XCTAssertFalse(blocked.isRecording)
        XCTAssertEqual(fixture.recorder.starts, 1)
        await gate.open()
        _ = try await stop.value
        let next = try await fixture.coordinator.toggleDictation()
        XCTAssertTrue(next.isRecording)
        XCTAssertEqual(fixture.recorder.starts, 2)
    }

    func testTerminationDuringStartupCannotStartRecorder() async throws {
        let fixture = fixture()
        let gate = TestGate()
        fixture.permissions.gate = gate
        let start = Task { try await fixture.coordinator.toggleDictation() }
        await gate.waitUntilEntered()
        fixture.coordinator.prepareForTermination()
        await gate.open()
        let result = try await start.value
        XCTAssertEqual(result.status, "Quitting")
        XCTAssertEqual(fixture.recorder.starts, 0)
        XCTAssertEqual(fixture.output.begins, 0)
    }

    func testTerminationDuringTranscriptionSuppressesInsertionAndLateState() async throws {
        let fixture = fixture()
        let gate = TestGate()
        await fixture.engine.setGate(gate)
        _ = try await fixture.coordinator.toggleDictation()
        let stop = Task { try await fixture.coordinator.toggleDictation() }
        await gate.waitUntilEntered()
        fixture.coordinator.prepareForTermination()
        await gate.open()
        let result = try await stop.value
        XCTAssertEqual(result.status, "Quitting")
        XCTAssertTrue(fixture.insertion.texts.isEmpty)
    }

    func testFailureReleasesSessionForRetry() async throws {
        let fixture = fixture()
        fixture.recorder.failStart = true
        let failed = try await fixture.coordinator.toggleDictation()
        XCTAssertEqual(failed.status, "Failed")
        fixture.recorder.failStart = false
        let retry = try await fixture.coordinator.toggleDictation()
        XCTAssertTrue(retry.isRecording)
    }

    func testCancelledTranscriptionDoesNotInsert() async throws {
        let fixture = fixture()
        let gate = TestGate()
        await fixture.engine.setGate(gate)
        _ = try await fixture.coordinator.toggleDictation()
        let stop = Task { try await fixture.coordinator.toggleDictation() }
        await gate.waitUntilEntered()
        stop.cancel()
        await gate.open()
        let result = try await stop.value
        XCTAssertEqual(result.status, "Cancelled")
        XCTAssertTrue(fixture.insertion.texts.isEmpty)
        let retry = try await fixture.coordinator.toggleDictation()
        XCTAssertTrue(retry.isRecording)
    }

    private func fixture() -> SessionFixture {
        let settings = makeTestSettings()
        settings.insertBehavior = .copyOnly
        settings.playRecordingCues = false
        return SessionFixture(settings: settings)
    }
}

@MainActor
final class SessionFixture {
    let permissions = SessionPermissions()
    let recorder = SessionRecorder()
    let feedback = SessionFeedback()
    let output = SessionOutput()
    let insertion = SessionInsertion()
    let engine = SessionEngine()
    let coordinator: TranscriptionCoordinator

    init(settings: AppSettings, frontmostBundleIdentifier: @escaping @MainActor () -> String? = { nil }) {
        coordinator = TranscriptionCoordinator(settings: settings, permissionService: permissions,
            recordingController: recorder, recordingFeedbackService: feedback,
            outputAudioService: output, textInsertionService: insertion, engine: engine,
            modelCatalog: ModelCatalogService(), frontmostBundleIdentifier: frontmostBundleIdentifier)
    }
}

@MainActor final class SessionPermissions: DictationPermissions {
    var accessibilityGranted = true
    var gate: TestGate?
    func requestMicrophoneIfNeeded() async -> MicrophoneAccessResult { await gate?.wait(); return .granted }
    func refreshAccessibility(promptAccessibility: Bool) {}
}
@MainActor final class SessionRecorder: DictationRecording {
    var starts = 0
    var stops = 0
    var failStart = false
    var recordingURL = URL(fileURLWithPath: "/unused-test-recording.wav")
    var discarded = false
    func discardPreparedRecording() { discarded = true }
    func prepareForRecording(shouldWarmInput: Bool) async {}
    func startRecording() throws -> URL {
        if failStart { throw CoordinatorError.recordingUnavailable }
        starts += 1
        return recordingURL
    }
    func stopRecording(shouldPrewarmNextInput: Bool) -> URL? {
        stops += 1
        return recordingURL
    }
}
@MainActor final class SessionFeedback: DictationFeedback {
    var stopGate: TestGate?
    func beginRecordingFeedback() async -> UInt64 { 0 }
    func endRecordingFeedback() async { await stopGate?.wait() }
    func cancelRecordingFeedback() async {}
    func stopImmediately() {}
}
@MainActor final class SessionOutput: RecordingOutputAudioManaging {
    var begins = 0
    func beginRecordingSession(afterDelayNanoseconds: UInt64) { begins += 1 }
    func endRecordingSession() {}
}
@MainActor final class SessionInsertion: DictationInsertion {
    var texts: [String] = []
    var behaviors: [InsertBehavior] = []
    var timings: [ClipboardPasteTiming] = []
    var targets: [String?] = []
    func insert(text: String, behavior: InsertBehavior, pasteTiming: ClipboardPasteTiming,
                expectedBundleIdentifier: String?, canDeliver: @MainActor () -> Bool) async -> InsertionOutcome {
        timings.append(pasteTiming)
        targets.append(expectedBundleIdentifier)
        return await insert(text: text, behavior: behavior)
    }
    func captureInsertionTarget() {}
    func insert(text: String, behavior: InsertBehavior) async -> InsertionOutcome {
        texts.append(text)
        behaviors.append(behavior)
        return .copiedOnly
    }
}
actor SessionEngine: ASREngine {
    nonisolated let id = "test"
    nonisolated let displayName = "Test"
    var calls = 0
    var gate: TestGate?
    var shouldFail = false
    func setGate(_ gate: TestGate) { self.gate = gate }
    func setFailure() { shouldFail = true }
    nonisolated func isConfigured() -> Bool { true }
    func transcribe(audioURL: URL, model: ASRModelDescriptor, options: TranscriptionOptions) async throws -> TranscriptionResult {
        calls += 1
        await gate?.wait()
        if shouldFail { throw CoordinatorError.recordingUnavailable }
        return TranscriptionResult(text: "test dictation", duration: 1)
    }
}

extension DictationSessionTests {
    func testInsertionOverridesAreLatchedBeforePermissionAwaitAndRefreshNextSession() async throws {
        let settings = makeTestSettings()
        settings.selectedModelID = "tiny.en"
        settings.playRecordingCues = false
        settings.insertBehavior = .typeOnly
        settings.useRemoteDesktopPreset(for: "test.remote", name: "Remote")
        var frontmost = "test.remote"
        let f = SessionFixture(settings: settings, frontmostBundleIdentifier: { frontmost })
        let gate = TestGate()
        f.permissions.gate = gate
        let start = Task { try await f.coordinator.toggleDictation() }
        await gate.waitUntilEntered()
        frontmost = "test.editor"
        settings.setInsertOverride(for: "test.remote", name: "Remote", behavior: .copyOnly)
        settings.setPasteTimingOverride(for: "test.remote", name: "Remote", timing: .fiveSeconds)
        await gate.open()
        _ = try await start.value
        _ = try await f.coordinator.toggleDictation()
        XCTAssertEqual(f.insertion.behaviors, [.pasteThenType])
        XCTAssertEqual(f.insertion.timings, [.oneSecond])
        XCTAssertEqual(f.insertion.targets, ["test.remote"])
        f.permissions.gate = nil
        _ = try await f.coordinator.toggleDictation()
        _ = try await f.coordinator.toggleDictation()
        XCTAssertEqual(f.insertion.behaviors, [.pasteThenType, .typeOnly])
        XCTAssertEqual(f.insertion.timings, [.oneSecond, .standard])
        XCTAssertEqual(f.insertion.targets, ["test.remote", "test.editor"])
    }
}
