import AVFoundation
import XCTest
@testable import HorseWhisprer

@MainActor
final class NativeDictationTests: XCTestCase {
    func testAudioChunksDoNotRepublishUnchangedRecordingState() async throws {
        let f = fixture()
        f.settings.insertBehavior = .typeOnly
        var states: [DictationActivity] = []
        f.coordinator.onStateChange = { states.append($0.activity) }
        let processed = expectation(description: "100 chunks inserted before stop")
        processed.expectedFulfillmentCount = 100
        f.live.onUpdate = { _ in processed.fulfill() }
        _ = try await f.coordinator.toggleDictation()
        for _ in 0..<100 {
            f.capture.channel.yield(.init(samples: [1], sampleRate: 16_000))
        }
        await fulfillment(of: [processed], timeout: 3)
        await Task.yield()
        XCTAssertFalse(f.capture.stopped)
        XCTAssertEqual(f.live.updates.count, 100)
        XCTAssertEqual(states.filter { $0 == .recording(.insertingLive) }.count, 1,
                       "20 ms audio chunks must not redraw the entire interface")

        let paused = expectation(description: "live insertion pause remains observable")
        f.live.onUpdate = nil
        f.live.result = .paused
        f.coordinator.onStateChange = { state in
            states.append(state.activity)
            if state.activity == .recording(.liveInsertionPaused) { paused.fulfill() }
        }
        f.capture.channel.yield(.init(samples: [2], sampleRate: 16_000))
        await fulfillment(of: [paused], timeout: 3)
        let final = try await f.coordinator.toggleDictation()
        XCTAssertEqual(final.activity, .finished(.liveInsertionPaused))
        XCTAssertTrue(states.contains(.stopping))
        XCTAssertTrue(states.contains(.transcribing))
    }

    func testIdlePreparationNeverStartsCaptureAndDoesNotRunDuringRecordingOrTermination() async throws {
        let f = fixture()
        var order: [String] = []
        f.capture.onPrepare = { order.append("input") }
        f.feedback.onPrepare = { order.append("cue") }
        f.coordinator.prepareStreamingCapture()
        XCTAssertEqual(order, ["input", "cue"])
        XCTAssertEqual(f.capture.starts, 0)
        _ = try await f.coordinator.toggleDictation()
        f.coordinator.prepareStreamingCapture()
        XCTAssertEqual(order, ["input", "cue"])
        f.coordinator.prepareForTermination()
        f.coordinator.prepareStreamingCapture()
        XCTAssertEqual(order, ["input", "cue"])
    }

    func testCatalogPreservesWhisperDefaultAndAddsNativeModels() {
        let catalog = ModelCatalogService()
        XCTAssertEqual(catalog.defaultModel.id, "base.en")
        XCTAssertEqual(catalog.models.count, Set(catalog.models.map(\.id)).count)
        XCTAssertEqual(catalog.model(for: "parakeet-unified")?.engineKind, .parakeet)
        XCTAssertEqual(catalog.model(for: "nemotron-streaming")?.engineKind.isStreaming, true)
        XCTAssertTrue(catalog.whisperModels.allSatisfy { $0.engineKind == .whisper })
    }

    func testStreamingProcessesBeforeStopAndInsertsOnlyFinalText() async throws {
        let f = fixture()
        let state = try await f.coordinator.toggleDictation()
        XCTAssertTrue(state.isRecording)
        XCTAssertEqual(f.recorder.starts, 0)
        f.capture.channel.yield(.init(samples: [1], sampleRate: 16_000))
        await f.engine.session.firstAppend.waitUntilEntered()
        XCTAssertTrue(f.insertion.texts.isEmpty)
        f.settings.selectedModelID = "tiny.en" // A session retains its starting engine.
        f.capture.channel.yield(.init(samples: [2], sampleRate: 16_000))
        let stopped = try await f.coordinator.toggleDictation()
        XCTAssertEqual(stopped.status, "Done: copied")
        XCTAssertEqual(f.insertion.texts, ["final transcript"])
        let chunks = await f.engine.session.chunks
        let finishes = await f.engine.session.finishes
        XCTAssertEqual(chunks, [[1], [2]])
        XCTAssertEqual(finishes, 1)
        XCTAssertEqual(f.engine.batchCalls, 0)
    }

    func testStreamingFailureStopsCaptureWithoutInsertingPartialText() async throws {
        let f = fixture()
        await f.engine.session.setFailure()
        _ = try await f.coordinator.toggleDictation()
        let failed = expectation(description: "failure")
        f.coordinator.onStateChange = { if $0.status == "Failed" { failed.fulfill() } }
        f.capture.channel.yield(.init(samples: [1], sampleRate: 16_000))
        await fulfillment(of: [failed], timeout: 3)
        XCTAssertTrue(f.capture.stopped)
        XCTAssertTrue(f.insertion.texts.isEmpty)
        let cancels = await f.engine.session.cancels
        XCTAssertEqual(cancels, 1)
        let retry = try await f.coordinator.toggleDictation()
        XCTAssertTrue(retry.isRecording)
        f.coordinator.prepareForTermination()
    }

    func testAudioCapturedDuringModelLoadSurvivesStopBeforeModelIsReady() async throws {
        let f = fixture()
        let gate = TestGate()
        f.engine.loadGate = gate
        let state = try await f.coordinator.toggleDictation()
        XCTAssertTrue(state.isRecording)
        XCTAssertEqual(state.status, "Recording — buffering audio…")
        await gate.waitUntilEntered()
        XCTAssertEqual(f.capture.starts, 1)
        f.capture.channel.yield(.init(samples: [1, 2], sampleRate: 16_000))
        f.capture.channel.yield(.init(samples: [3, 4], sampleRate: 16_000))
        let beforeLoad = await f.engine.session.chunks
        XCTAssertTrue(beforeLoad.isEmpty)
        let stopping = expectation(description: "capture stopped while model still loading")
        f.coordinator.onStateChange = { if $0.status == "Transcribing…" { stopping.fulfill() } }
        let stop = Task { try await f.coordinator.toggleDictation() }
        await fulfillment(of: [stopping], timeout: 3)
        XCTAssertTrue(f.capture.stopped)
        await gate.open()
        let result = try await stop.value
        XCTAssertEqual(result.status, "Done: copied")
        let chunks = await f.engine.session.chunks
        XCTAssertEqual(chunks, [[1, 2], [3, 4]])
        XCTAssertEqual(f.insertion.texts, ["final transcript"])
    }

    func testTerminationDuringStreamingModelLoadStopsCaptureAndDiscardsBufferedAudio() async throws {
        let f = fixture()
        let gate = TestGate()
        f.engine.loadGate = gate
        _ = try await f.coordinator.toggleDictation()
        await gate.waitUntilEntered()
        f.capture.channel.yield(.init(samples: [1], sampleRate: 16_000))
        f.coordinator.prepareForTermination()
        XCTAssertTrue(f.capture.stopped)
        await gate.open()
        await f.engine.session.cancelled.waitUntilEntered()
        let result = try await f.coordinator.toggleDictation()
        XCTAssertEqual(result.status, "Quitting")
        XCTAssertEqual(f.capture.starts, 1)
        let cancels = await f.engine.session.cancels
        XCTAssertEqual(cancels, 1)
        let chunks = await f.engine.session.chunks
        XCTAssertTrue(chunks.isEmpty)
        XCTAssertTrue(f.insertion.texts.isEmpty)
    }

    func testTerminationDuringDecodeNeverFinishesOrInserts() async throws {
        let f = fixture()
        let gate = TestGate()
        await f.engine.session.setGate(gate)
        _ = try await f.coordinator.toggleDictation()
        f.capture.channel.yield(.init(samples: [1], sampleRate: 16_000))
        await gate.waitUntilEntered()
        f.coordinator.prepareForTermination()
        await gate.open()
        await f.engine.session.cancelled.waitUntilEntered()
        XCTAssertTrue(f.capture.stopped)
        XCTAssertTrue(f.insertion.texts.isEmpty)
        let finishes = await f.engine.session.finishes
        XCTAssertEqual(finishes, 0)
    }

    func testTerminationWhileStartCuePendingStopsCaptureAndSuppressesLateDucking() async throws {
        let f = fixture()
        let gate = TestGate()
        f.feedback.startGate = gate
        _ = try await f.coordinator.toggleDictation()
        await gate.waitUntilEntered()
        f.coordinator.prepareForTermination()
        await gate.open()
        await f.feedback.completed.waitUntilEntered()
        XCTAssertTrue(f.capture.stopped)
        XCTAssertTrue(f.insertion.texts.isEmpty)
        XCTAssertEqual(f.output.begins, 0)
    }

    func testDecodeFailureDuringStartCueDoesNotPublishRecordingAfterFailure() async throws {
        let f = fixture()
        let gate = TestGate()
        f.feedback.startGate = gate
        await f.engine.session.setFailure()
        let failed = expectation(description: "decode failed")
        var states: [CoordinatorState] = []
        f.coordinator.onStateChange = {
            states.append($0)
            if $0.status == "Failed" { failed.fulfill() }
        }
        _ = try await f.coordinator.toggleDictation()
        await gate.waitUntilEntered()
        f.capture.channel.yield(.init(samples: [1], sampleRate: 16_000))
        await fulfillment(of: [failed], timeout: 3)
        await gate.open()
        await f.feedback.completed.waitUntilEntered()
        XCTAssertEqual(states.last?.status, "Failed")
        XCTAssertTrue(f.capture.stopped)
        XCTAssertEqual(f.output.begins, 0)
    }

    func testStreamingCapturesAndStopsWithoutWaitingForBluetoothCue() async throws {
        let settings = makeTestSettings()
        settings.selectedModelID = "nemotron-streaming"
        settings.insertBehavior = .copyOnly
        let gate = TestGate()
        let f = StreamingFixture(settings: settings, delayCaptureForCue: { true },
            waitForCue: { _ in XCTFail("Streaming capture must not wait for the cue") })
        f.feedback.startGate = gate
        var states: [CoordinatorState] = []
        f.coordinator.onStateChange = { states.append($0) }
        let start = try await f.coordinator.toggleDictation()
        XCTAssertTrue(start.isRecording)
        await gate.waitUntilEntered()
        XCTAssertEqual(f.capture.starts, 1)
        f.capture.channel.yield(.init(samples: [1], sampleRate: 16_000))
        await f.engine.session.firstAppend.waitUntilEntered()
        let stopped = try await f.coordinator.toggleDictation()
        XCTAssertEqual(stopped.status, "Done: copied")
        XCTAssertTrue(f.capture.stopped)
        XCTAssertFalse(stopped.isRecording)
        let stateCountBeforeResume = states.count
        await gate.open()
        await f.feedback.completed.waitUntilEntered()
        XCTAssertFalse(states.dropFirst(stateCountBeforeResume).contains { $0.isRecording })
        XCTAssertEqual(f.output.begins, 0)
        XCTAssertEqual(f.capture.starts, 1)
        let chunks = await f.engine.session.chunks
        XCTAssertEqual(chunks, [[1]])
        XCTAssertEqual(f.insertion.texts, ["final transcript"])
    }

    func testOutputDuckingWaitsForActualCueCompletionWhileCaptureContinues() async throws {
        let f = fixture()
        let completion = TestGate()
        f.feedback.completionGate = completion
        let start = try await f.coordinator.toggleDictation()
        XCTAssertTrue(start.isRecording)
        await completion.waitUntilEntered()
        XCTAssertEqual(f.output.begins, 0)
        XCTAssertFalse(f.capture.stopped)
        f.capture.channel.yield(.init(samples: [1], sampleRate: 16_000))
        await f.engine.session.firstAppend.waitUntilEntered()
        let applied = expectation(description: "duck after playback completes")
        f.output.onBegin = { applied.fulfill() }
        await completion.open()
        await fulfillment(of: [applied], timeout: 3)
        XCTAssertEqual(f.output.begins, 1)
        _ = try await f.coordinator.toggleDictation()
    }

    func testModelLoadFailureStopsEarlyCaptureAndAllowsRetry() async throws {
        let f = fixture()
        let gate = TestGate()
        f.engine.loadGate = gate
        f.engine.failLoad = true
        _ = try await f.coordinator.toggleDictation()
        await gate.waitUntilEntered()
        f.capture.channel.yield(.init(samples: [1], sampleRate: 16_000))
        let failed = expectation(description: "model load failed")
        f.coordinator.onStateChange = { if $0.status == "Failed" { failed.fulfill() } }
        await gate.open()
        await fulfillment(of: [failed], timeout: 3)
        XCTAssertTrue(f.capture.stopped)
        XCTAssertTrue(f.insertion.texts.isEmpty)
        f.engine.failLoad = false
        let retry = try await f.coordinator.toggleDictation()
        XCTAssertTrue(retry.isRecording)
        f.coordinator.prepareForTermination()
    }

    func testEarlyAudioOverflowIsReportedAfterModelLoadsWithoutFinalInsertion() async throws {
        let f = fixture()
        let gate = TestGate()
        f.engine.loadGate = gate
        f.capture.capacity = 1
        _ = try await f.coordinator.toggleDictation()
        await gate.waitUntilEntered()
        f.capture.channel.yield(.init(samples: [1], sampleRate: 16_000))
        f.capture.channel.yield(.init(samples: [2], sampleRate: 16_000))
        let failed = expectation(description: "overflow reported")
        f.coordinator.onStateChange = {
            if $0.status == "Failed" {
                XCTAssertEqual($0.errorMessage, NativeASRError.audioOverflow.localizedDescription)
                failed.fulfill()
            }
        }
        await gate.open()
        await fulfillment(of: [failed], timeout: 3)
        XCTAssertTrue(f.capture.stopped)
        XCTAssertTrue(f.insertion.texts.isEmpty)
        let finishes = await f.engine.session.finishes
        XCTAssertEqual(finishes, 0)
    }

    func testAudioQueueReportsOverflowInsteadOfSilentlyDroppingWords() async throws {
        let channel = DictationAudioChannel(capacity: 1)
        channel.yield(.init(samples: [1], sampleRate: 16_000))
        channel.yield(.init(samples: [2], sampleRate: 16_000))
        var iterator = channel.stream.makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(first?.samples, [1])
        do { _ = try await iterator.next(); XCTFail("Expected overflow") }
        catch NativeASRError.audioOverflow {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testAudioTapRunsOffMainActorAndCopiesSamplesBeforeReturning() async throws {
        let channel = DictationAudioChannel()
        // Construct from the main actor, as start() does, then invoke on the audio side.
        let tap = StreamingAudioCapture.makeAudioTap(channel: channel)
        try await Task.detached {
            XCTAssertFalse(Thread.isMainThread)
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2))
            buffer.frameLength = 2
            let data = try XCTUnwrap(buffer.floatChannelData)
            data[0][0] = 0.2; data[0][1] = 0.4
            data[1][0] = 0.6; data[1][1] = 0.8
            tap(buffer, AVAudioTime(sampleTime: 0, atRate: 48_000))
            // The engine may reuse its buffer immediately after the tap returns.
            data[0][0] = 0; data[0][1] = 0
            data[1][0] = 0; data[1][1] = 0
            channel.finish()
        }.value
        var iterator = channel.stream.makeAsyncIterator()
        let next = try await iterator.next()
        let chunk = try XCTUnwrap(next)
        XCTAssertEqual(chunk.sampleRate, 48_000)
        XCTAssertEqual(chunk.samples.count, 2)
        XCTAssertEqual(chunk.samples[0], 0.4, accuracy: 0.00001)
        XCTAssertEqual(chunk.samples[1], 0.6, accuracy: 0.00001)
        let end = try await iterator.next()
        XCTAssertNil(end)
    }

    func testAudioTapRejectsUnsupportedPCMOffMainActor() async throws {
        let channel = DictationAudioChannel()
        let tap = StreamingAudioCapture.makeAudioTap(channel: channel)
        try await Task.detached {
            let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16,
                sampleRate: 16_000, channels: 1, interleaved: false))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
            buffer.frameLength = 1
            tap(buffer, AVAudioTime(sampleTime: 0, atRate: 16_000))
            channel.finish()
        }.value
        var iterator = channel.stream.makeAsyncIterator()
        do { _ = try await iterator.next(); XCTFail("Expected invalid audio") }
        catch NativeASRError.invalidAudio {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testConfigurationChangeCallbackFailsStreamOffMainActor() async throws {
        let channel = DictationAudioChannel()
        let callback = StreamingAudioCapture.makeConfigurationChangeHandler(channel: channel)
        await Task.detached {
            XCTAssertFalse(Thread.isMainThread)
            callback(Notification(name: .AVAudioEngineConfigurationChange))
            channel.finish()
        }.value
        var iterator = channel.stream.makeAsyncIterator()
        do { _ = try await iterator.next(); XCTFail("Expected invalid audio") }
        catch NativeASRError.invalidAudio {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testLiveTextAppearsBeforeStopAndFinalDoesNotDuplicateIt() async throws {
        let f = fixture()
        f.settings.insertBehavior = .pasteThenType
        let partial = expectation(description: "live partial")
        f.live.onUpdate = { if $0 == "partial transcript" { partial.fulfill() } }
        _ = try await f.coordinator.toggleDictation()
        f.capture.channel.yield(.init(samples: [1], sampleRate: 16_000))
        await fulfillment(of: [partial], timeout: 3)
        XCTAssertEqual(f.live.begins, 1)
        XCTAssertTrue(f.insertion.texts.isEmpty)
        // Changing preferences during a session must not switch insertion modes.
        f.settings.insertBehavior = .copyOnly
        f.settings.liveStreamingInsertion = false
        let final = try await f.coordinator.toggleDictation()
        XCTAssertEqual(f.live.updates, ["partial transcript", "final transcript"])
        XCTAssertTrue(f.insertion.texts.isEmpty)
        XCTAssertEqual(final.status, "Done: inserted live")
        XCTAssertEqual(final.transcribedText, "final transcript")
    }

    func testPausedLiveInsertionRetainsFinalTranscriptWithoutPasteFallback() async throws {
        let f = fixture()
        f.settings.insertBehavior = .typeOnly
        f.live.result = .paused
        _ = try await f.coordinator.toggleDictation()
        f.capture.channel.yield(.init(samples: [1], sampleRate: 16_000))
        let final = try await f.coordinator.toggleDictation()
        XCTAssertTrue(f.insertion.texts.isEmpty)
        XCTAssertEqual(final.transcribedText, "final transcript")
        XCTAssertEqual(final.status, "Done: live insertion paused")
        XCTAssertTrue(final.errorMessage?.contains(LiveInsertionPauseReason.selectionNotConfirmed.message) == true)
    }

    func testFinalizationReportsUnsettledManualEditInsteadOfSuccessfulDelivery() async throws {
        let f = fixture()
        f.settings.insertBehavior = .typeOnly
        f.live.finalResult = .paused
        _ = try await f.coordinator.toggleDictation()
        f.capture.channel.yield(.init(samples: [1], sampleRate: 16_000))
        let final = try await f.coordinator.toggleDictation()
        XCTAssertEqual(f.live.result, .inserted, "Partial updates were active before finalization")
        XCTAssertEqual(final.status, "Done: live insertion paused")
        XCTAssertEqual(final.transcribedText, "final transcript")
        XCTAssertTrue(f.insertion.texts.isEmpty, "Do not paste a duplicate final transcript")
    }

    func testUnsupportedLiveTargetFallsBackOnlyOnceAtStop() async throws {
        let f = fixture()
        f.settings.insertBehavior = .pasteThenType
        f.live.result = .unavailable
        _ = try await f.coordinator.toggleDictation()
        f.capture.channel.yield(.init(samples: [1], sampleRate: 16_000))
        let final = try await f.coordinator.toggleDictation()
        XCTAssertEqual(f.insertion.texts, ["final transcript"])
        XCTAssertEqual(final.status, "Done: copied")
    }

    func testLiveDisabledKeepsFinalOnlyInsertion() async throws {
        let f = fixture()
        f.settings.insertBehavior = .typeOnly
        f.settings.liveStreamingInsertion = false
        _ = try await f.coordinator.toggleDictation()
        f.capture.channel.yield(.init(samples: [1], sampleRate: 16_000))
        _ = try await f.coordinator.toggleDictation()
        XCTAssertEqual(f.live.begins, 0)
        XCTAssertTrue(f.live.updates.isEmpty)
        XCTAssertEqual(f.insertion.texts, ["final transcript"])
    }

    func testTerminationDuringDecodeNeverDeliversLiveEdit() async throws {
        let f = fixture()
        f.settings.insertBehavior = .typeOnly
        let gate = TestGate()
        await f.engine.session.setGate(gate)
        _ = try await f.coordinator.toggleDictation()
        f.capture.channel.yield(.init(samples: [1], sampleRate: 16_000))
        await gate.waitUntilEntered()
        f.coordinator.prepareForTermination()
        await gate.open()
        await f.engine.session.cancelled.waitUntilEntered()
        XCTAssertTrue(f.live.updates.isEmpty)
        XCTAssertTrue(f.insertion.texts.isEmpty)
    }

    func testAppendOnlyModeIsLatchedForSession() async throws {
        let f = fixture()
        f.settings.insertBehavior = .typeOnly
        f.settings.streamingInsertionMode = .appendOnly
        _ = try await f.coordinator.toggleDictation()
        XCTAssertEqual(f.live.modes, [.appendOnly])
        f.settings.streamingInsertionMode = .verified
        let final = try await f.coordinator.toggleDictation()
        XCTAssertEqual(final.status, "Done: typed live (delivery unverified)")
        XCTAssertTrue(f.insertion.texts.isEmpty)
    }

    func testInsertWhenFinishedModeDoesNotStartLiveStrategy() async throws {
        let f = fixture()
        f.settings.insertBehavior = .typeOnly
        f.settings.streamingInsertionMode = .onStop
        _ = try await f.coordinator.toggleDictation()
        _ = try await f.coordinator.toggleDictation()
        XCTAssertTrue(f.live.modes.isEmpty)
        XCTAssertTrue(f.live.updates.isEmpty)
        XCTAssertEqual(f.insertion.texts, ["final transcript"])
    }

    func testApplicationOverrideIsLatchedUntilNextSession() async throws {
        let settings = makeTestSettings()
        settings.selectedModelID = "nemotron-streaming"
        settings.insertBehavior = .typeOnly
        settings.playRecordingCues = false
        settings.streamingInsertionMode = .onStop
        settings.setStreamingOverride(for: "test.chat", name: "Chat", mode: .appendOnly)
        var frontmost = "test.chat"
        let f = StreamingFixture(settings: settings, frontmostBundleIdentifier: { frontmost })
        _ = try await f.coordinator.toggleDictation()
        XCTAssertEqual(f.live.modes, [.appendOnly])
        frontmost = "test.editor"
        settings.setStreamingOverride(for: "test.chat", name: "Chat", mode: .onStop)
        let final = try await f.coordinator.toggleDictation()
        XCTAssertEqual(final.status, "Done: typed live (delivery unverified)")
        XCTAssertTrue(f.insertion.texts.isEmpty)
        _ = try await f.coordinator.toggleDictation()
        _ = try await f.coordinator.toggleDictation()
        XCTAssertEqual(f.live.modes, [.appendOnly])
        XCTAssertEqual(f.insertion.texts, ["final transcript"])
    }

    func testPerApplicationCopyOnlySuppressesLiveInsertion() async throws {
        let settings = makeTestSettings()
        settings.selectedModelID = "nemotron-streaming"
        settings.insertBehavior = .pasteThenType
        settings.setInsertOverride(for: "test.remote", name: "Remote", behavior: .copyOnly)
        settings.setStreamingOverride(for: "test.remote", name: "Remote", mode: .appendOnly)
        let f = StreamingFixture(settings: settings, frontmostBundleIdentifier: { "test.remote" })
        _ = try await f.coordinator.toggleDictation()
        f.capture.channel.yield(.init(samples: [1], sampleRate: 16_000))
        _ = try await f.coordinator.toggleDictation()
        XCTAssertEqual(f.live.begins, 0)
        XCTAssertEqual(f.insertion.behaviors, [.copyOnly])
        XCTAssertEqual(f.insertion.texts, ["final transcript"])
    }

    func testRemotePresetUsesOneFinalPasteWithStreamingModel() async throws {
        let settings = makeTestSettings()
        settings.selectedModelID = "nemotron-streaming"
        settings.useRemoteDesktopPreset(for: "test.remote", name: "Remote")
        let f = StreamingFixture(settings: settings, frontmostBundleIdentifier: { "test.remote" })
        _ = try await f.coordinator.toggleDictation()
        f.capture.channel.yield(.init(samples: [1], sampleRate: 16_000))
        _ = try await f.coordinator.toggleDictation()
        XCTAssertEqual(f.live.begins, 0)
        XCTAssertEqual(f.insertion.behaviors, [.pasteThenType])
        XCTAssertEqual(f.insertion.timings, [.oneSecond])
        XCTAssertEqual(f.insertion.texts, ["final transcript"])
    }

    func testCopyOnlyStillWinsOverApplicationStreamingOverride() async throws {
        let settings = makeTestSettings()
        settings.selectedModelID = "nemotron-streaming"
        settings.insertBehavior = .copyOnly
        settings.playRecordingCues = false
        settings.setStreamingOverride(for: "test.chat", name: "Chat", mode: .appendOnly)
        let f = StreamingFixture(settings: settings, frontmostBundleIdentifier: { "test.chat" })
        _ = try await f.coordinator.toggleDictation()
        _ = try await f.coordinator.toggleDictation()
        XCTAssertTrue(f.live.modes.isEmpty)
        XCTAssertEqual(f.insertion.texts, ["final transcript"])
    }

    private func fixture() -> StreamingFixture {
        let settings = makeTestSettings()
        settings.selectedModelID = "nemotron-streaming"
        settings.insertBehavior = .copyOnly
        settings.playRecordingCues = false
        return StreamingFixture(settings: settings)
    }
}

@MainActor
private final class StreamingFixture {
    let settings: AppSettings
    let recorder = SessionRecorder()
    let capture = TestStreamingCapture()
    let engine = TestStreamingEngine()
    let feedback = TestStreamingFeedback()
    let insertion = SessionInsertion()
    let live = TestLiveInsertion()
    let output = TestStreamingOutput()
    let coordinator: TranscriptionCoordinator
    init(settings: AppSettings, frontmostBundleIdentifier: @escaping @MainActor () -> String? = { nil },
         delayCaptureForCue: (@MainActor () -> Bool)? = nil,
         waitForCue: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.settings = settings
        coordinator = TranscriptionCoordinator(settings: settings, permissionService: SessionPermissions(),
            recordingController: recorder, recordingFeedbackService: feedback,
            outputAudioService: output, textInsertionService: insertion,
            engine: engine, modelCatalog: ModelCatalogService(), streamingCapture: capture, liveInsertion: live,
            frontmostBundleIdentifier: frontmostBundleIdentifier,
            delayCaptureForCue: delayCaptureForCue, waitForCue: waitForCue)
    }
}

@MainActor
private final class TestStreamingCapture: StreamingAudioCapturing {
    var onPrepare: (() -> Void)?
    func prepare() throws { onPrepare?() }
    var channel = DictationAudioChannel()
    var starts = 0
    var stopped = false
    var capacity = 256
    func start() -> AsyncThrowingStream<DictationAudioChunk, Error> {
        channel = DictationAudioChannel(capacity: capacity)
        starts += 1
        stopped = false
        return channel.stream
    }
    func stop() { stopped = true; channel.finish() }
}

@MainActor
private final class TestStreamingEngine: ASREngine {
    nonisolated let id = "test-native"
    nonisolated let displayName = "Test Native"
    let session = TestStreamingSession()
    var loadGate: TestGate?
    var failLoad = false
    var batchCalls = 0
    nonisolated func isConfigured() -> Bool { true }
    func makeStreamingSession(model: ASRModelDescriptor, options: TranscriptionOptions) async throws -> any StreamingASRSession {
        await loadGate?.wait()
        if failLoad { throw NativeASRError.modelNotInstalled }
        return session
    }
    func transcribe(audioURL: URL, model: ASRModelDescriptor, options: TranscriptionOptions) async throws -> TranscriptionResult {
        batchCalls += 1
        return .init(text: "wrong engine", duration: 0)
    }
}

private actor TestStreamingSession: StreamingASRSession {
    let firstAppend = TestGate()
    let cancelled = TestGate()
    var chunks: [[Float]] = []
    var finishes = 0
    var cancels = 0
    var failure = false
    var gate: TestGate?
    func setFailure() { failure = true }
    func setGate(_ gate: TestGate) { self.gate = gate }
    func append(_ chunk: DictationAudioChunk) async throws -> String {
        chunks.append(chunk.samples)
        await firstAppend.open()
        await firstAppend.wait()
        await gate?.wait()
        if failure { throw NativeASRError.invalidAudio }
        return "partial transcript"
    }
    func finish() -> TranscriptionResult { finishes += 1; return .init(text: "final transcript", duration: 1) }
    func cancel() async { cancels += 1; await cancelled.open(); await cancelled.wait() }
}

@MainActor
private final class TestStreamingFeedback: DictationFeedback {
    var onPrepare: (() -> Void)?
    func prepareStartCue() { onPrepare?() }
    var startGate: TestGate?
    var completionGate: TestGate?
    let completed = TestGate()
    func playStartCueToCompletion() async {
        await startGate?.wait()
        await completionGate?.wait()
        await completed.open()
        await completed.wait()
    }
    var leadIn: UInt64 = 0
    func beginRecordingFeedback() async -> UInt64 { await startGate?.wait(); return leadIn }
    func endRecordingFeedback() async {}
    func cancelRecordingFeedback() async {}
    func stopImmediately() {}
}

@MainActor
private final class TestLiveInsertion: LiveDictationInserting {
    var begins = 0
    var modes: [StreamingInsertionMode] = []
    var updates: [String] = []
    var pauseReason: LiveInsertionPauseReason? = .selectionNotConfirmed
    var result = LiveInsertionResult.inserted
    var finalResult: LiveInsertionResult?
    var onUpdate: ((String) -> Void)?
    func begin() { begins += 1 }
    func begin(mode: StreamingInsertionMode) { modes.append(mode); begin() }
    func update(_ transcript: String) async -> LiveInsertionResult {
        updates.append(transcript)
        onUpdate?(transcript)
        return result
    }
    func cancel() {}
    func finish(_ transcript: String) async -> LiveInsertionResult {
        let partialResult = await update(transcript)
        return finalResult ?? partialResult
    }
}

@MainActor
private final class TestStreamingOutput: RecordingOutputAudioManaging {
    var begins = 0
    var onBegin: (() -> Void)?
    func beginRecordingSession(afterDelayNanoseconds: UInt64) { begins += 1; onBegin?() }
    func endRecordingSession() {}
}
