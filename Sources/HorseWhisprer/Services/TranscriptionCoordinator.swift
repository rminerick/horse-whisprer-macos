import AppKit
import CoreAudio
import Foundation
import OSLog

func shouldPlayStartCueBeforeRecording(
    playRecordingCues: Bool,
    inputRoute: CuePlaybackRoute?,
    outputRoute: CuePlaybackRoute?
) -> Bool {
    guard playRecordingCues,
          let outputRoute,
          isBluetoothAudioRoute(outputRoute) else {
        return false
    }

    guard let inputRoute else {
        return false
    }

    if inputRoute.uid == outputRoute.uid {
        return true
    }

    return isBluetoothAudioRoute(inputRoute) && isBluetoothAudioRoute(outputRoute)
}

func isBluetoothAudioRoute(_ route: CuePlaybackRoute) -> Bool {
    route.transportType == kAudioDeviceTransportTypeBluetooth ||
    route.transportType == kAudioDeviceTransportTypeBluetoothLE
}

enum CoordinatorError: LocalizedError {
    case microphoneDenied
    case accessibilityDenied
    case recordingUnavailable

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Microphone permission is required."
        case .accessibilityDenied:
            return "Accessibility permission is required for paste and typed insertion."
        case .recordingUnavailable:
            return "No recording was available to transcribe."
        }
    }
}

@MainActor
protocol DictationPermissions {
    var accessibilityGranted: Bool { get }
    func requestMicrophoneIfNeeded() async -> MicrophoneAccessResult
    func refreshAccessibility(promptAccessibility: Bool)
}

@MainActor
protocol DictationRecording {
    func prepareForRecording(shouldWarmInput: Bool) async
    func startRecording() throws -> URL
    func stopRecording(shouldPrewarmNextInput: Bool) -> URL?
    func discardPreparedRecording()
}

@MainActor
protocol DictationFeedback {
    func prepareStartCue()
    func beginRecordingFeedback() async -> UInt64
    func playStartCueToCompletion() async
    func endRecordingFeedback() async
    func cancelRecordingFeedback() async
    func stopImmediately()
}

extension DictationFeedback {
    func prepareStartCue() {}
    func playStartCueToCompletion() async {
        let delay = await beginRecordingFeedback()
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
    }
}

@MainActor
protocol DictationInsertion {
    func captureInsertionTarget()
    func insert(text: String, behavior: InsertBehavior) async -> InsertionOutcome
    func insert(text: String, behavior: InsertBehavior, pasteTiming: ClipboardPasteTiming,
                expectedBundleIdentifier: String?, canDeliver: @MainActor () -> Bool) async -> InsertionOutcome
}

extension PermissionService: DictationPermissions {}
extension RecordingController: DictationRecording {}
extension RecordingFeedbackService: DictationFeedback {}
extension TextInsertionService: DictationInsertion {}

@MainActor
final class TranscriptionCoordinator {
    let engine: ASREngine
    var onStateChange: ((CoordinatorState) -> Void)?

    private enum Phase { case idle, starting, recording, stopping, transcribing, terminated }
    private var phase = Phase.idle
    private var state = CoordinatorState(isRecording: false, isBusy: false, status: "Idle", transcribedText: nil, errorMessage: nil)
    private var transcriptionTask: Task<TranscriptionResult, Error>?
    private let settings: AppSettings
    private let permissionService: any DictationPermissions
    private let recordingController: any DictationRecording
    private let recordingFeedbackService: any DictationFeedback
    private let outputAudioService: any RecordingOutputAudioManaging
    private let textInsertionService: any DictationInsertion
    private let modelCatalog: ModelCatalogService
    private var currentRecordingURL: URL?
    private let delayCaptureForCue: @MainActor () -> Bool
    private let waitForCue: @Sendable (UInt64) async throws -> Void
    private let streamingCapture: any StreamingAudioCapturing
    private var sessionModel: ASRModelDescriptor?
    private var sessionOptions: TranscriptionOptions?
    private var sessionInsertBehavior: InsertBehavior = .pasteThenType
    private var sessionPasteTiming: ClipboardPasteTiming = .standard
    private var sessionTargetBundleIdentifier: String?
    private let liveInsertion: any LiveDictationInserting
    private let frontmostBundleIdentifier: @MainActor () -> String?
    private var sessionStreamingMode: StreamingInsertionMode = .verified
    private var usesLiveInsertion = false
    private var liveInsertionResult = LiveInsertionResult.unavailable
    private var sessionPartialTranscript: String?
    private var streamingSession: (any StreamingASRSession)?
    private var streamingTask: Task<TranscriptionResult, Error>?
    private var sessionID: UUID?
    private var startFeedbackTask: Task<Void, Never>?
    var onPartialTranscript: ((String?) -> Void)?
    /// Called once per session that produced text, whether or not it was inserted.
    var onDictationCompleted: ((CompletedDictation) -> Void)?
    private var sessionReplacements: [TextReplacementRule] = []
    private var recordingBeganAt: TimeInterval?
    private var sessionRecordedDuration: TimeInterval = 0
    private var cancelRequested = false
    /// True once finished text is on its way into the target; too late to cancel.
    private var isDelivering = false
    private let logger = Logger(subsystem: "com.rminerick.HorseWhisprer", category: "TranscriptionCoordinator")

    init(
        settings: AppSettings,
        permissionService: any DictationPermissions,
        recordingController: any DictationRecording,
        recordingFeedbackService: any DictationFeedback,
        outputAudioService: any RecordingOutputAudioManaging,
        textInsertionService: any DictationInsertion,
        engine: ASREngine,
        modelCatalog: ModelCatalogService,
        streamingCapture: any StreamingAudioCapturing = AudioQueueCapture(),
        liveInsertion: any LiveDictationInserting = ConfigurableLiveTextInsertion(),
        frontmostBundleIdentifier: @escaping @MainActor () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
        delayCaptureForCue: (@MainActor () -> Bool)? = nil,
        waitForCue: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.settings = settings
        self.permissionService = permissionService
        self.recordingController = recordingController
        self.recordingFeedbackService = recordingFeedbackService
        self.outputAudioService = outputAudioService
        self.textInsertionService = textInsertionService
        self.engine = engine
        self.modelCatalog = modelCatalog
        self.streamingCapture = streamingCapture
        self.liveInsertion = liveInsertion
        self.frontmostBundleIdentifier = frontmostBundleIdentifier
        self.delayCaptureForCue = delayCaptureForCue ?? {
            shouldPlayStartCueBeforeRecording(playRecordingCues: settings.playRecordingCues,
                inputRoute: AudioRouteDetector.currentInputRoute(), outputRoute: AudioRouteDetector.currentOutputRoute())
        }
        self.waitForCue = waitForCue
    }

    func toggleDictation() async throws -> CoordinatorState {
        // Claim the transition before the first suspension. MainActor alone does
        // not serialize a session across permission, cue, and engine awaits.
        let stopping: Bool
        switch phase {
        case .idle:
            stopping = false
            phase = .starting
            publish(isRecording: false, isBusy: true, status: "Starting…", activity: .starting)
        case .recording:
            stopping = true
            phase = .stopping
            publish(isRecording: false, isBusy: true, status: "Stopping…", activity: .stopping)
        case .starting, .stopping, .transcribing, .terminated:
            return state
        }

        do {
            try checkActive()
            if stopping {
                try await stopRecordingAndTranscribe()
            } else {
                try await startRecording()
            }
        } catch {
            guard phase != .terminated else { return state }
            guard await abortSession() else { return state }
            let wasCancelled = error is CancellationError
            // A transcript the user asked to discard is not kept anywhere.
            let retainedText = cancelRequested ? nil : sessionPartialTranscript
            cancelRequested = false
            phase = .idle
            publish(isRecording: false, isBusy: false,
                    status: wasCancelled ? "Cancelled" : "Failed",
                    transcribedText: retainedText,
                    errorMessage: wasCancelled ? nil : error.localizedDescription,
                    activity: wasCancelled ? .cancelled : .failed)
            if !wasCancelled, let retainedText {
                reportCompletion(text: retainedText, delivery: .notInserted)
            }
        }
        return state
    }

    /// Discards the session in flight without inserting or keeping its text.
    /// Text that live insertion already typed stays in the field.
    @discardableResult
    func cancelDictation() async -> CoordinatorState {
        switch phase {
        case .recording:
            phase = .stopping
            cancelRequested = true
            publish(isRecording: false, isBusy: true, status: "Cancelling…", activity: .stopping)
            guard await abortSession() else { return state }
            cancelRequested = false
            sessionPartialTranscript = nil
            phase = .idle
            publish(isRecording: false, isBusy: false, status: "Cancelled", activity: .cancelled)
            prepareStreamingCapture()
        case .transcribing:
            guard !isDelivering else { break }
            // The suspended stop call observes the cancellation and unwinds through
            // toggleDictation's catch, which publishes the cancelled state.
            cancelRequested = true
            sessionPartialTranscript = nil
            transcriptionTask?.cancel()
        case .idle, .starting, .stopping, .terminated:
            break
        }
        return state
    }

    /// Tears down capture, cues and engine work for the current session.
    /// Returns false when the app began terminating during the teardown.
    private func abortSession() async -> Bool {
        liveInsertion.cancel()
        startFeedbackTask?.cancel()
        startFeedbackTask = nil
        recordingFeedbackService.stopImmediately()
        streamingCapture.stop()
        streamingTask?.cancel()
        _ = try? await streamingTask?.value
        await streamingSession?.cancel()
        streamingSession = nil
        guard phase != .terminated else { return false }
        streamingTask = nil
        streamingSession = nil
        sessionID = nil
        onPartialTranscript?(nil)
        _ = recordingController.stopRecording(shouldPrewarmNextInput: false)
        cleanupRecording()
        recordingController.discardPreparedRecording()
        outputAudioService.endRecordingSession()
        recordingFeedbackService.stopImmediately()
        return true
    }

    private func reportCompletion(text: String, delivery: DictationDelivery) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onDictationCompleted?(CompletedDictation(
            text: text,
            modelName: sessionModel?.displayName ?? "",
            recordedDuration: sessionRecordedDuration,
            delivery: delivery
        ))
    }

    func prepareForTermination() {
        phase = .terminated
        startFeedbackTask?.cancel()
        startFeedbackTask = nil
        liveInsertion.cancel()
        transcriptionTask?.cancel()
        streamingCapture.stop()
        streamingTask?.cancel()
        if streamingTask == nil, let streamingSession {
            Task { await streamingSession.cancel() }
        }
        streamingSession = nil
        sessionID = nil
        onPartialTranscript?(nil)
        engine.prepareForTermination()
        _ = recordingController.stopRecording(shouldPrewarmNextInput: false)
        cleanupRecording()
        recordingController.discardPreparedRecording()
        outputAudioService.endRecordingSession()
        recordingFeedbackService.stopImmediately()
        currentRecordingURL = nil
        publish(isRecording: false, isBusy: false, status: "Quitting", activity: .idle)
    }

    private func cleanupRecording() {
        if let currentRecordingURL { try? FileManager.default.removeItem(at: currentRecordingURL) }
        currentRecordingURL = nil
    }

    private func checkActive() throws {
        try Task.checkCancellation()
        if phase == .terminated || cancelRequested { throw CancellationError() }
    }

    private func publish(isRecording: Bool, isBusy: Bool, status: String,
                         transcribedText: String? = nil, errorMessage: String? = nil,
                         activity: DictationActivity) {
        let next = CoordinatorState(isRecording: isRecording, isBusy: isBusy, status: status,
                                    transcribedText: transcribedText, errorMessage: errorMessage,
                                    activity: activity)
        // Audio arrives every 20 ms; unchanged status must not invalidate the
        // entire interface and starve the main actor's live-insertion work.
        guard next != state else { return }
        state = next
        onStateChange?(state)
    }

    private func publishRecording() {
        publish(isRecording: true, isBusy: false, status: recordingStatus, activity: .recording(recordingDetail))
    }

    private var shouldPrewarmRecordingInput: Bool {
        settings.dictationOutputAudioBehavior != .off
    }

    func prepareStreamingCapture() {
        guard phase == .idle,
              modelCatalog.model(for: settings.selectedModelID)?.engineKind.isStreaming == true else { return }
        do {
            try streamingCapture.prepare()
            recordingFeedbackService.prepareStartCue()
        }
        catch { AudioDiagnostics.shared.log("DictationStartup", "input preparation deferred: \(error.localizedDescription)") }
    }

    private func startRecording() async throws {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let model = modelCatalog.model(for: settings.selectedModelID) ?? modelCatalog.defaultModel
        let options = TranscriptionOptions(languageCode: settings.languageCode, suppressTimestamps: true,
                                           useGPU: !settings.disableGPU, vocabularyPrompt: settings.vocabularyPrompt)
        cancelRequested = false
        isDelivering = false
        recordingBeganAt = nil
        sessionRecordedDuration = 0
        sessionReplacements = settings.textReplacements
        sessionModel = model
        sessionOptions = options
        sessionTargetBundleIdentifier = frontmostBundleIdentifier()
        sessionInsertBehavior = settings.insertBehavior(for: sessionTargetBundleIdentifier)
        sessionPasteTiming = settings.pasteTiming(for: sessionTargetBundleIdentifier)
        sessionStreamingMode = settings.streamingMode(for: sessionTargetBundleIdentifier)
        usesLiveInsertion = model.engineKind.isStreaming && sessionStreamingMode != .onStop && sessionInsertBehavior != .copyOnly
        liveInsertionResult = .unavailable
        sessionPartialTranscript = nil
        liveInsertion.cancel()
        if usesLiveInsertion { liveInsertion.begin(mode: sessionStreamingMode) }
        sessionID = UUID()
        onPartialTranscript?(nil)
        textInsertionService.captureInsertionTarget()
        let microphoneResult = await permissionService.requestMicrophoneIfNeeded()
        try checkActive()
        guard microphoneResult == .granted else { throw CoordinatorError.microphoneDenied }

        // Capture immediately. The bounded audio channel retains the opening words
        // while the model loads, and the cue must never gate streaming capture.
        if model.engineKind.isStreaming {
            recordingController.discardPreparedRecording()
            let chunks = try await streamingCapture.start()
            try checkActive()
            AudioDiagnostics.shared.log("DictationStartup", "captureStartedMs=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000))")
            startStreamingTask(chunks: chunks, model: model, options: options, startedAt: startedAt)
            phase = .recording
            recordingBeganAt = ProcessInfo.processInfo.systemUptime
            startStreamingFeedback()
            publishRecording()
            return
        }

        let delayForCue = !model.engineKind.isStreaming && delayCaptureForCue()
        if delayForCue {
            let leadIn = await recordingFeedbackService.beginRecordingFeedback()
            try checkActive()
            if leadIn > 0 { try await waitForCue(leadIn) }
        }
        if !model.engineKind.isStreaming {
            await recordingController.prepareForRecording(shouldWarmInput: shouldPrewarmRecordingInput && !delayForCue)
            try checkActive()
            currentRecordingURL = try recordingController.startRecording()
        }

        let leadIn = delayForCue ? 0 : await recordingFeedbackService.beginRecordingFeedback()
        try checkActive()
        guard sessionID != nil else { return }
        outputAudioService.beginRecordingSession(afterDelayNanoseconds: leadIn)
        phase = .recording
        recordingBeganAt = ProcessInfo.processInfo.systemUptime
        let startupMilliseconds = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
        logger.info("recording started startupMs=\(startupMilliseconds, privacy: .public)")
        publishRecording()
    }

    private func startStreamingFeedback() {
        let id = sessionID
        startFeedbackTask = Task { [weak self, recordingFeedbackService] in
            await recordingFeedbackService.playStartCueToCompletion()
            guard !Task.isCancelled, let self, self.sessionID == id, self.phase == .recording else { return }
            self.startFeedbackTask = nil
            AudioDiagnostics.shared.log("DictationStartup", "startCueCompleted; applying output behavior")
            self.outputAudioService.beginRecordingSession(afterDelayNanoseconds: 0)
        }
    }

    private func startStreamingTask(chunks: AsyncThrowingStream<DictationAudioChunk, Error>,
                                    model: ASRModelDescriptor, options: TranscriptionOptions,
                                    startedAt: TimeInterval) {
        let id = sessionID
        streamingTask = Task { [weak self, engine] in
            var loadedSession: (any StreamingASRSession)?
            do {
                try Task.checkCancellation()
                let streamSession = try await engine.makeStreamingSession(model: model, options: options)
                loadedSession = streamSession
                try Task.checkCancellation()
                guard self?.sessionID == id, self != nil else { throw CancellationError() }
                self?.streamingSession = streamSession
                AudioDiagnostics.shared.log("DictationStartup", "modelReadyMs=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000))")
                if let self, self.phase == .recording {
                    self.publishRecording()
                }
                var firstChunk = true
                for try await chunk in chunks {
                    try Task.checkCancellation()
                    if firstChunk {
                        firstChunk = false
                        AudioDiagnostics.shared.log("DictationStartup", "firstBufferMs=\(Int((chunk.capturedAt - startedAt) * 1_000)) bufferedBeforeDecodeMs=\(Int((ProcessInfo.processInfo.systemUptime - chunk.capturedAt) * 1_000))")
                    }
                    let rawPartial = try await streamSession.append(chunk)
                    guard let self, self.sessionID == id else { throw CancellationError() }
                    let partial = TextReplacer.apply(self.sessionReplacements, to: rawPartial)
                    self.sessionPartialTranscript = partial
                    self.onPartialTranscript?(partial)
                    if self.usesLiveInsertion {
                        let result = await self.liveInsertion.update(partial)
                        guard self.sessionID == id else { throw CancellationError() }
                        self.liveInsertionResult = result
                        if self.phase == .recording {
                            self.publishRecording()
                        }
                    }
                }
                try Task.checkCancellation()
                return try await streamSession.finish()
            } catch {
                await loadedSession?.cancel()
                self?.streamingFailed(error, sessionID: id)
                throw error
            }
        }
    }

    private var recordingDetail: DictationActivity.RecordingDetail {
        if sessionModel?.engineKind.isStreaming == true, streamingSession == nil {
            return .bufferingAudio
        }
        guard usesLiveInsertion else { return .insertOnStop }
        switch liveInsertionResult {
        case .inserted: return .insertingLive
        case .unavailable: return .insertOnStop
        case .paused: return .liveInsertionPaused
        }
    }

    private var recordingStatus: String {
        switch recordingDetail {
        case .bufferingAudio: return "Recording — buffering audio…"
        case .insertOnStop: return usesLiveInsertion ? "Recording — waiting for a supported field; otherwise inserting when finished…" : "Recording — inserting when finished…"
        case .insertingLive: return sessionStreamingMode == .appendOnly ? "Recording — append-only streaming (unverified)…" : "Recording — inserting live…"
        case .liveInsertionPaused: return "Recording — live insertion paused"
        }
    }

    private func streamingFailed(_ error: Error, sessionID id: UUID?) {
        guard sessionID == id else { return }
        guard phase == .recording else { return }
        startFeedbackTask?.cancel()
        startFeedbackTask = nil
        liveInsertion.cancel()
        streamingCapture.stop()
        outputAudioService.endRecordingSession()
        recordingFeedbackService.stopImmediately()
        let typedLive = usesLiveInsertion && liveInsertionResult == .inserted
        sessionRecordedDuration = recordingBeganAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
        streamingTask = nil
        streamingSession = nil
        sessionID = nil
        onPartialTranscript?(nil)
        phase = .idle
        publish(isRecording: false, isBusy: false, status: "Failed", transcribedText: sessionPartialTranscript,
                errorMessage: error.localizedDescription, activity: .failed)
        if let partial = sessionPartialTranscript {
            reportCompletion(text: partial, delivery: typedLive ? .insertedLive : .notInserted)
        }
    }

    private func stopRecordingAndTranscribe() async throws {
        sessionRecordedDuration = recordingBeganAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
        startFeedbackTask?.cancel()
        startFeedbackTask = nil
        recordingFeedbackService.stopImmediately()
        streamingCapture.stop()
        let stoppedURL = streamingTask == nil
            ? recordingController.stopRecording(shouldPrewarmNextInput: shouldPrewarmRecordingInput) : nil
        outputAudioService.endRecordingSession()
        currentRecordingURL = stoppedURL ?? currentRecordingURL
        defer { cleanupRecording() }
        await recordingFeedbackService.endRecordingFeedback()
        try checkActive()

        phase = .transcribing
        publish(isRecording: false, isBusy: true, status: "Transcribing…", activity: .transcribing)

        let task: Task<TranscriptionResult, Error>
        if let streamingTask {
            task = streamingTask
        } else {
            guard let audioURL = currentRecordingURL, let model = sessionModel, let options = sessionOptions else {
                throw CoordinatorError.recordingUnavailable
            }
            task = Task { [engine] in
                try await engine.transcribe(audioURL: audioURL, model: model, options: options)
            }
        }
        transcriptionTask = task
        defer {
            isDelivering = false
            liveInsertion.cancel()
            transcriptionTask = nil
            streamingTask = nil
            streamingSession = nil
            sessionID = nil
            onPartialTranscript?(nil)
            prepareStreamingCapture()
        }
        let transcription = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try checkActive()
        let finalText = TextReplacer.apply(sessionReplacements, to: transcription.text)
        // From here on the transcript exists: any later failure must keep it.
        sessionPartialTranscript = finalText
        isDelivering = true
        if usesLiveInsertion {
            let result = await liveInsertion.finish(finalText)
            try checkActive()
            if result != .unavailable {
                phase = .idle
                let delivery: DictationDelivery = result == .inserted ? .insertedLive : .liveInsertionPaused
                publish(isRecording: false, isBusy: false,
                        status: result == .inserted ? (sessionStreamingMode == .appendOnly ? "Done: typed live (delivery unverified)" : "Done: inserted live") : "Done: live insertion paused",
                        transcribedText: finalText,
                        errorMessage: result == .paused ? "Live insertion paused: \(liveInsertion.pauseReason?.message ?? "The app could not verify the edit.") The full transcript is in History." : nil,
                        activity: .finished(delivery))
                reportCompletion(text: finalText, delivery: delivery)
                return
            }
        }
        if sessionInsertBehavior != .copyOnly {
            permissionService.refreshAccessibility(promptAccessibility: false)
            if !permissionService.accessibilityGranted {
                // Never discard finished text over a missing permission: hand it
                // to the clipboard and say why it was not inserted.
                _ = await textInsertionService.insert(text: finalText, behavior: .copyOnly)
                try checkActive()
                phase = .idle
                publish(isRecording: false, isBusy: false, status: "Done: copied",
                        transcribedText: finalText,
                        errorMessage: "Accessibility access is missing, so the text was copied to the clipboard instead of inserted.",
                        activity: .finished(.copiedWithoutAccessibility))
                reportCompletion(text: finalText, delivery: .copiedWithoutAccessibility)
                return
            }
        }
        let outcome = await textInsertionService.insert(text: finalText, behavior: sessionInsertBehavior,
            pasteTiming: sessionPasteTiming, expectedBundleIdentifier: sessionTargetBundleIdentifier,
            canDeliver: { self.phase != .terminated })
        try checkActive()
        phase = .idle
        publish(isRecording: false, isBusy: false, status: "Done: \(outcome.label)", transcribedText: finalText,
                activity: .finished(.inserted(outcome)))
        reportCompletion(text: finalText, delivery: .inserted(outcome))
    }
}
