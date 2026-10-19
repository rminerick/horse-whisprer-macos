import AVFoundation
import Foundation
import OSLog

enum RecordingError: LocalizedError {
    case recorderUnavailable

    var errorDescription: String? {
        switch self {
        case .recorderUnavailable:
            return "The audio recorder could not be created."
        }
    }
}

@MainActor
protocol RecordingAudio: AnyObject {
    func prepareToRecord() -> Bool
    func record() -> Bool
    func record(forDuration duration: TimeInterval) -> Bool
    func stop()
}

extension AVAudioRecorder: RecordingAudio {}

@MainActor
final class RecordingController: NSObject {
    private var recorder: (any RecordingAudio)?
    private var currentURL: URL?
    private var preparedRecorder: (any RecordingAudio)?
    private var preparedURL: URL?
    private var lastInputWarmupDate: Date?
    private var isWarmingInput = false
    private var warmupRecorder: (any RecordingAudio)?
    private var warmupURL: URL?
    private var pendingWarmupTask: Task<Void, Never>?
    private var preparationGeneration = 0
    private let newRecordingURL: () throws -> URL
    private let makeAudioRecorder: (URL, [String: Any]) throws -> any RecordingAudio

    private let logger = Logger(subsystem: "com.rminerick.HorseWhisprer", category: "RecordingController")
    private let diagnostics = AudioDiagnostics.shared
    private let inputWarmupFreshness: TimeInterval = 15
    private let inputWarmupDuration: TimeInterval = 0.2

    private let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false
    ]

    init(
        prepareOnInit: Bool = false,
        newRecordingURL: @escaping () throws -> URL = AppPaths.newRecordingURL,
        makeAudioRecorder: @escaping (URL, [String: Any]) throws -> any RecordingAudio = { try AVAudioRecorder(url: $0, settings: $1) }
    ) {
        self.newRecordingURL = newRecordingURL
        self.makeAudioRecorder = makeAudioRecorder
        super.init()
        // AppModel chooses the active capture backend after initialization.
        // Opening a legacy recorder here can block launch even for Nemotron.
        if prepareOnInit { prewarmNextRecording() }
    }

    func prepareForRecording(shouldWarmInput: Bool = true) async {
        diagnostics.log(
            "RecordingController",
            "prepareForRecording shouldWarmInput=\(shouldWarmInput) shouldWarmRoute=\(self.shouldWarmInput) inputRoute=\(AudioRouteDetector.currentInputRoute()?.uid ?? "unknown") outputRoute=\(AudioRouteDetector.currentOutputRoute()?.uid ?? "unknown")"
        )
        guard shouldWarmInput else {
            return
        }

        guard self.shouldWarmInput else {
            return
        }

        guard !isWarmingInput else {
            return
        }

        isWarmingInput = true
        let generation = preparationGeneration
        defer {
            if generation == preparationGeneration { isWarmingInput = false }
        }

        let startedAt = Date()
        do {
            let (warmupRecorder, warmupURL) = try makeRecorder()
            self.warmupRecorder = warmupRecorder
            self.warmupURL = warmupURL
            defer {
                warmupRecorder.stop()
                try? FileManager.default.removeItem(at: warmupURL)
                if generation == preparationGeneration {
                    self.warmupRecorder = nil
                    self.warmupURL = nil
                }
            }

            guard warmupRecorder.record(forDuration: inputWarmupDuration) else {
                logger.warning("input warmup failed to start")
                diagnostics.log("RecordingController", "input warmup failed to start")
                return
            }

            let waitNanoseconds = UInt64((inputWarmupDuration + 0.05) * 1_000_000_000)
            try await Task.sleep(nanoseconds: waitNanoseconds)
            guard generation == preparationGeneration else { return }

            lastInputWarmupDate = Date()
            let durationMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
            logger.info("input warmup completed durationMs=\(durationMilliseconds, privacy: .public)")
            diagnostics.log(
                "RecordingController",
                "input warmup completed durationMs=\(durationMilliseconds) inputRoute=\(AudioRouteDetector.currentInputRoute()?.uid ?? "unknown") outputRoute=\(AudioRouteDetector.currentOutputRoute()?.uid ?? "unknown")"
            )
        } catch {
            logger.error("input warmup failed error=\(error.localizedDescription, privacy: .public)")
            diagnostics.log("RecordingController", "input warmup failed error=\(error.localizedDescription)")
        }
    }

    func startRecording() throws -> URL {
        let (recorder, url) = try preparedRecorderTuple()
        guard recorder.record() else {
            recorder.stop()
            try? FileManager.default.removeItem(at: url)
            preparedRecorder = nil
            preparedURL = nil
            diagnostics.log("RecordingController", "startRecording failed to start recorder")
            throw RecordingError.recorderUnavailable
        }

        self.recorder = recorder
        currentURL = url
        preparedRecorder = nil
        preparedURL = nil
        diagnostics.log(
            "RecordingController",
            "startRecording url=\(url.lastPathComponent) inputRoute=\(AudioRouteDetector.currentInputRoute()?.uid ?? "unknown") outputRoute=\(AudioRouteDetector.currentOutputRoute()?.uid ?? "unknown")"
        )
        return url
    }

    func stopRecording(shouldPrewarmNextInput: Bool = true) -> URL? {
        recorder?.stop()
        diagnostics.log(
            "RecordingController",
            "stopRecording url=\(currentURL?.lastPathComponent ?? "nil") shouldPrewarmNextInput=\(shouldPrewarmNextInput) inputRoute=\(AudioRouteDetector.currentInputRoute()?.uid ?? "unknown") outputRoute=\(AudioRouteDetector.currentOutputRoute()?.uid ?? "unknown")"
        )
        recorder = nil
        defer { currentURL = nil }
        guard shouldPrewarmNextInput else {
            return currentURL
        }

        prewarmNextRecording()
        let generation = preparationGeneration
        pendingWarmupTask?.cancel()
        pendingWarmupTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, self.preparationGeneration == generation else { return }
            await self.prepareForRecording()
        }
        return currentURL
    }

    func discardPreparedRecording() {
        preparationGeneration += 1
        pendingWarmupTask?.cancel()
        pendingWarmupTask = nil
        preparedRecorder?.stop()
        warmupRecorder?.stop()
        for url in [preparedURL, warmupURL].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
        preparedRecorder = nil
        preparedURL = nil
        warmupRecorder = nil
        warmupURL = nil
        isWarmingInput = false
        lastInputWarmupDate = nil
    }

    private var shouldWarmInput: Bool {
        guard let lastInputWarmupDate else {
            return true
        }

        return Date().timeIntervalSince(lastInputWarmupDate) >= inputWarmupFreshness
    }

    private func preparedRecorderTuple() throws -> (any RecordingAudio, URL) {
        if let preparedRecorder, let preparedURL {
            return (preparedRecorder, preparedURL)
        }

        let recorder = try makeRecorder()
        return (recorder.0, recorder.1)
    }

    private func prewarmNextRecording() {
        guard preparedRecorder == nil else {
            return
        }

        do {
            let (recorder, url) = try makeRecorder()
            preparedRecorder = recorder
            preparedURL = url
        } catch {
            preparedRecorder = nil
            preparedURL = nil
        }
    }

    private func makeRecorder() throws -> (any RecordingAudio, URL) {
        let url = try newRecordingURL()
        do {
            let recorder = try makeAudioRecorder(url, settings)
            guard recorder.prepareToRecord() else { throw RecordingError.recorderUnavailable }
            return (recorder, url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
