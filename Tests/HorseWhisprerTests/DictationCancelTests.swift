import Combine
import XCTest
@testable import HorseWhisprer

@MainActor
final class DictationCancelTests: XCTestCase {
    func testCancelWhileRecordingDiscardsAudioAndAllowsRetry() async throws {
        let fixture = fixture()
        let started = try await fixture.coordinator.toggleDictation()
        XCTAssertTrue(started.isRecording)

        let cancelled = await fixture.coordinator.cancelDictation()

        XCTAssertEqual(cancelled.status, "Cancelled")
        XCTAssertEqual(cancelled.activity, .cancelled)
        XCTAssertFalse(cancelled.isRecording)
        XCTAssertFalse(cancelled.isBusy)
        XCTAssertNil(cancelled.transcribedText)
        XCTAssertTrue(fixture.insertion.texts.isEmpty)
        let calls = await fixture.engine.calls
        XCTAssertEqual(calls, 0)

        let retry = try await fixture.coordinator.toggleDictation()
        XCTAssertTrue(retry.isRecording)
    }

    func testCancelDuringTranscriptionDoesNotInsertOrKeepText() async throws {
        let fixture = fixture()
        let gate = TestGate()
        await fixture.engine.setGate(gate)
        var completions: [CompletedDictation] = []
        fixture.coordinator.onDictationCompleted = { completions.append($0) }

        _ = try await fixture.coordinator.toggleDictation()
        let stop = Task { try await fixture.coordinator.toggleDictation() }
        await gate.waitUntilEntered()
        await fixture.coordinator.cancelDictation()
        await gate.open()
        let result = try await stop.value

        XCTAssertEqual(result.status, "Cancelled")
        XCTAssertEqual(result.activity, .cancelled)
        XCTAssertNil(result.transcribedText)
        XCTAssertTrue(fixture.insertion.texts.isEmpty)
        XCTAssertTrue(completions.isEmpty)

        let retry = try await fixture.coordinator.toggleDictation()
        XCTAssertTrue(retry.isRecording)
    }

    func testCancelWhenIdleIsIgnored() async {
        let fixture = fixture()
        let state = await fixture.coordinator.cancelDictation()
        XCTAssertEqual(state.status, "Idle")
        XCTAssertEqual(state.activity, .idle)
    }

    func testMissingAccessibilityCopiesTheTranscriptInsteadOfLosingIt() async throws {
        let fixture = fixture(insertBehavior: .pasteThenType)
        fixture.permissions.accessibilityGranted = false
        var completions: [CompletedDictation] = []
        fixture.coordinator.onDictationCompleted = { completions.append($0) }

        _ = try await fixture.coordinator.toggleDictation()
        let finished = try await fixture.coordinator.toggleDictation()

        XCTAssertEqual(finished.status, "Done: copied")
        XCTAssertEqual(finished.activity, .finished(.copiedWithoutAccessibility))
        XCTAssertEqual(finished.transcribedText, "test dictation")
        XCTAssertNotNil(finished.errorMessage)
        XCTAssertEqual(fixture.insertion.texts, ["test dictation"])
        XCTAssertEqual(completions.map(\.text), ["test dictation"])
        XCTAssertEqual(completions.first?.delivery, .copiedWithoutAccessibility)
    }

    func testFinishedDictationIsReportedOnceWithItsDelivery() async throws {
        let fixture = fixture()
        var completions: [CompletedDictation] = []
        fixture.coordinator.onDictationCompleted = { completions.append($0) }

        _ = try await fixture.coordinator.toggleDictation()
        let finished = try await fixture.coordinator.toggleDictation()

        XCTAssertEqual(finished.activity, .finished(.inserted(.copiedOnly)))
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completions.first?.text, "test dictation")
        XCTAssertEqual(completions.first?.delivery, .inserted(.copiedOnly))
        XCTAssertEqual(completions.first?.modelName, "Whisper base.en")
    }

    func testReplacementsApplyBeforeInsertion() async throws {
        let settings = makeTestSettings()
        settings.selectedModelID = "base.en"
        settings.insertBehavior = .copyOnly
        settings.playRecordingCues = false
        settings.textReplacements = [TextReplacementRule(heard: "test dictation", replacement: "Test Dictation!")]
        let fixture = SessionFixture(settings: settings)

        _ = try await fixture.coordinator.toggleDictation()
        let finished = try await fixture.coordinator.toggleDictation()

        XCTAssertEqual(fixture.insertion.texts, ["Test Dictation!"])
        XCTAssertEqual(finished.transcribedText, "Test Dictation!")
    }

    func testActivityFollowsTheSession() async throws {
        let fixture = fixture()
        var activities: [DictationActivity] = []
        fixture.coordinator.onStateChange = { activities.append($0.activity) }

        _ = try await fixture.coordinator.toggleDictation()
        _ = try await fixture.coordinator.toggleDictation()

        XCTAssertEqual(activities, [
            .starting,
            .recording(.insertOnStop),
            .stopping,
            .transcribing,
            .finished(.inserted(.copiedOnly))
        ])
    }

    private func fixture(insertBehavior: InsertBehavior = .copyOnly) -> SessionFixture {
        let settings = makeTestSettings()
        settings.selectedModelID = "base.en"
        settings.insertBehavior = insertBehavior
        settings.playRecordingCues = false
        return SessionFixture(settings: settings)
    }
}

@MainActor
final class AppModelDictationRegressionTests: XCTestCase {
    func testRepeatedCoordinatorStateDoesNotInvalidateViews() {
        let (model, session) = fixture()
        let recording = CoordinatorState(isRecording: true, isBusy: false, status: "Recording…",
                                         transcribedText: nil, errorMessage: nil,
                                         activity: .recording(.insertingLive))
        session.coordinator.onStateChange?(recording)
        let startedAt = model.recordingStartedAt
        var updates = 0
        let subscription = model.objectWillChange.sink { updates += 1 }
        for _ in 0..<100 { session.coordinator.onStateChange?(recording) }
        XCTAssertEqual(updates, 0)
        XCTAssertEqual(model.recordingStartedAt, startedAt)
        session.coordinator.onStateChange?(CoordinatorState(
            isRecording: false, isBusy: false, status: "Cancelled", transcribedText: nil,
            errorMessage: nil, activity: .cancelled))
        XCTAssertGreaterThan(updates, 0)
        XCTAssertEqual(model.activity, .cancelled)
        XCTAssertNil(model.recordingStartedAt)
        withExtendedLifetime(subscription) {}
    }

    private func fixture(retention: HistoryRetention = .untilQuit,
                         triggerController: any TriggerRegistering = TriggerRegistrationSpy()) -> (AppModel, SessionFixture) {
        let settings = makeTestSettings()
        settings.selectedModelID = "base.en"
        settings.insertBehavior = .copyOnly
        settings.playRecordingCues = false
        settings.escapeCancelsDictation = false
        settings.historyRetention = retention
        let session = SessionFixture(settings: settings)
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent("AppModelRegression-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let model = AppModel(settings: settings,
                             historyStore: TranscriptHistoryStore(retention: retention, fileURL: nil),
                             coordinator: session.coordinator,
                             modelInstallService: ModelInstallService(modelCatalog: ModelCatalogService(),
                                                                      storageDirectory: storage.appendingPathComponent("Whisper")),
                             nativeModelStore: NativeModelStore(root: storage.appendingPathComponent("Native")),
                             triggerController: triggerController,
                             startsBackgroundServices: false)
        return (model, session)
    }

    func testSecondStartDuringFocusRestorationDoesNotStopNewSession() async {
        let (model, session) = fixture()
        let gate = TestGate()
        model.prepareForDictationStart = { await gate.wait() }
        let start = Task { await model.toggleDictation() }
        await gate.waitUntilEntered()
        XCTAssertTrue(model.isBusy)
        XCTAssertEqual(model.activity, .starting)
        await model.toggleDictation()
        XCTAssertEqual(session.recorder.starts, 0)
        await gate.open()
        await start.value
        XCTAssertEqual(session.recorder.starts, 1)
        XCTAssertEqual(session.recorder.stops, 0)
        XCTAssertTrue(model.isRecording)
        await model.cancelDictation()
    }

    func testChangingTriggerDuringHoldKeepsReleaseAndAppliesLatestConfiguration() async {
        let trigger = TriggerRegistrationSpy()
        let (model, session) = fixture(triggerController: trigger)
        model.configureTrigger()
        await model.handleTrigger(.holdBegan)
        XCTAssertTrue(model.isRecording)

        model.updateSpecialKeyTrigger(.rightCommandTapAlone)
        model.updateTriggerMode(.standardHotKey)
        XCTAssertEqual(trigger.registrations.count, 1, "Keep the original key-release listener until the hold ends")

        await model.handleTrigger(.holdEnded)
        XCTAssertEqual(session.recorder.stops, 1)
        XCTAssertFalse(model.isRecording)
        XCTAssertEqual(trigger.registrations.count, 2)
        XCTAssertEqual(trigger.registrations.last?.mode, .standardHotKey)
    }

    func testChangingTriggerDuringStartupKeepsEarlyRelease() async {
        let trigger = TriggerRegistrationSpy()
        let (model, session) = fixture(triggerController: trigger)
        model.configureTrigger()
        let gate = TestGate()
        model.prepareForDictationStart = { await gate.wait() }
        let hold = Task { await model.handleTrigger(.holdBegan) }
        await gate.waitUntilEntered()
        model.updateSpecialKeyTrigger(.rightCommandTapAlone)
        XCTAssertEqual(trigger.registrations.count, 1)
        await model.handleTrigger(.holdEnded)
        await gate.open()
        await hold.value
        XCTAssertEqual(session.recorder.starts, 1)
        XCTAssertEqual(session.recorder.stops, 1)
        XCTAssertFalse(model.isRecording)
        XCTAssertEqual(trigger.registrations.count, 2)
        XCTAssertEqual(trigger.registrations.last?.mode, .specialKey)
    }

    func testCancelDuringStartupSurvivesRepeatedTrigger() async {
        let (model, session) = fixture()
        let gate = TestGate()
        session.permissions.gate = gate
        let start = Task { await model.toggleDictation() }
        await gate.waitUntilEntered()
        await model.cancelDictation()
        await model.toggleDictation()
        await gate.open()
        await start.value
        XCTAssertEqual(model.activity, .cancelled)
        XCTAssertFalse(model.isRecording)
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(session.insertion.texts.isEmpty)
        XCTAssertNil(model.lastResult)
        XCTAssertTrue(model.historyStore.records.isEmpty)
        // Cancellation must not poison the following session.
        await model.toggleDictation()
        XCTAssertTrue(model.isRecording)
        await model.cancelDictation()
    }

    func testCancelDuringFocusRestorationDoesNotStartMicrophone() async {
        let (model, session) = fixture()
        let gate = TestGate()
        model.prepareForDictationStart = { await gate.wait() }
        let start = Task { await model.toggleDictation() }
        await gate.waitUntilEntered()
        await model.cancelDictation()
        await model.toggleDictation()
        await gate.open()
        await start.value
        XCTAssertEqual(session.recorder.starts, 0)
        XCTAssertEqual(model.activity, .cancelled)
        XCTAssertFalse(model.isBusy)
    }

    func testReleaseDuringFocusRestorationStopsAfterStarting() async {
        let (model, session) = fixture()
        let gate = TestGate()
        model.prepareForDictationStart = { await gate.wait() }
        let hold = Task { await model.handleTrigger(.holdBegan) }
        await gate.waitUntilEntered()
        await model.handleTrigger(.holdEnded)
        await gate.open()
        await hold.value
        XCTAssertEqual(session.recorder.starts, 1)
        XCTAssertEqual(session.recorder.stops, 1)
        XCTAssertFalse(model.isRecording)
        XCTAssertEqual(session.insertion.texts, ["test dictation"])
    }

    func testTerminationDuringFocusRestorationPreventsStartup() async {
        let (model, session) = fixture()
        let gate = TestGate()
        model.prepareForDictationStart = { await gate.wait() }
        let start = Task { await model.toggleDictation() }
        await gate.waitUntilEntered()
        model.prepareForTermination()
        await gate.open()
        await start.value
        XCTAssertEqual(session.recorder.starts, 0)
        XCTAssertFalse(model.isRecording)
        XCTAssertEqual(model.statusMessage, "Quitting")
    }

    func testNeverRetentionDoesNotExposeCompletedTranscript() async {
        let (model, session) = fixture(retention: .off)
        await model.toggleDictation()
        await model.toggleDictation()
        XCTAssertEqual(session.insertion.texts, ["test dictation"])
        XCTAssertNil(model.lastResult)
        XCTAssertTrue(model.historyStore.records.isEmpty)
    }

    func testClearingHistoryAlsoClearsLastTranscript() async {
        let (model, _) = fixture()
        await model.toggleDictation()
        await model.toggleDictation()
        XCTAssertEqual(model.lastResult, "test dictation")
        model.historyStore.clear()
        XCTAssertNil(model.lastResult)
    }

    func testDisablingRetentionClearsLastTranscriptSynchronously() async {
        let (model, _) = fixture()
        await model.toggleDictation()
        await model.toggleDictation()
        XCTAssertNotNil(model.lastResult)
        model.settings.historyRetention = .off
        XCTAssertNil(model.lastResult)
        XCTAssertTrue(model.historyStore.records.isEmpty)
    }
}

private final class TriggerRegistrationSpy: TriggerRegistering {
    private(set) var registrations: [TriggerConfiguration] = []
    func register(_ configuration: TriggerConfiguration, style: TriggerStyle,
                  canUseSpecialKeyMonitoring: Bool,
                  handler: @escaping (TriggerEvent) -> Void) -> TriggerRegistrationResult {
        registrations.append(configuration)
        return .registered
    }
    func unregister() {}
}
