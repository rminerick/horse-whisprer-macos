import AppKit
@preconcurrency import AVFoundation
import Foundation
import OSLog

@MainActor
protocol CuePlaying {
    func prepareOutput()
    func prepareCue(named name: NSSound.Name)
    func cueDuration(named name: NSSound.Name) -> TimeInterval?
    func playCue(named name: NSSound.Name, leadingSilence: TimeInterval, trailingSilence: TimeInterval)
    func playCueToCompletion(named name: NSSound.Name, leadingSilence: TimeInterval, trailingSilence: TimeInterval) async
    func stop()
}

extension CuePlaying {
    func prepareOutput() {}
    func playCue(named name: NSSound.Name) {
        playCue(named: name, leadingSilence: 0, trailingSilence: 0)
    }

    func playCueToCompletion(named name: NSSound.Name, leadingSilence: TimeInterval, trailingSilence: TimeInterval) async {
        playCue(named: name, leadingSilence: leadingSilence, trailingSilence: trailingSilence)
        try? await Task.sleep(for: .seconds(leadingSilence + (cueDuration(named: name) ?? 0.35)))
    }
}

@MainActor
final class RecordingFeedbackService {
    private let settings: AppSettings
    private let cuePlayer: CuePlaying
    private let routePlanner: CueRoutePlanning
    private let startCueAudiblePlaybackWindow: TimeInterval
    private let logger = Logger(subsystem: "com.rminerick.HorseWhisprer", category: "RecordingFeedback")
    private let diagnostics = AudioDiagnostics.shared
    private var generation: UInt64 = 0

    init(
        settings: AppSettings,
        cuePlayer: CuePlaying = SystemCuePlayer(),
        routePlanner: CueRoutePlanning = CueRoutePlanner(),
        startCueAudiblePlaybackWindow: TimeInterval = 0.35
    ) {
        self.settings = settings
        self.cuePlayer = cuePlayer
        self.routePlanner = routePlanner
        self.startCueAudiblePlaybackWindow = startCueAudiblePlaybackWindow

        cuePlayer.prepareCue(named: NSSound.Name(settings.startRecordingCueSoundName))
        cuePlayer.prepareCue(named: NSSound.Name(settings.stopRecordingCueSoundName))
        diagnostics.log(
            "RecordingFeedback",
            "init startCue=\(settings.startRecordingCueSoundName) stopCue=\(settings.stopRecordingCueSoundName)"
        )
    }

    func beginRecordingFeedback() async -> UInt64 {
        generation &+= 1
        let request = generation
        let cueName = NSSound.Name(settings.startRecordingCueSoundName)
        cuePlayer.prepareCue(named: cueName)

        guard settings.playRecordingCues else {
            return 0
        }

        let playbackPlan = await routePlanner.playbackPlan(for: .start)
        guard !Task.isCancelled, request == generation else { return 0 }
        playCue(named: cueName, using: playbackPlan)
        routePlanner.notePlaybackScheduled(using: playbackPlan)

        let cueDuration = cuePlayer.cueDuration(named: cueName) ?? startCueAudiblePlaybackWindow
        let totalLeadIn = playbackPlan.leadingSilence + cueDuration
        return UInt64((totalLeadIn * 1_000_000_000).rounded())
    }

    /// Used by streaming capture's independent cue task. Ducking starts only when
    /// the player confirms completion, not after an estimated Bluetooth delay.
    func playStartCueToCompletion() async {
        generation &+= 1
        let request = generation
        guard settings.playRecordingCues, !Task.isCancelled else { return }
        let name = NSSound.Name(settings.startRecordingCueSoundName)
        let plan = await routePlanner.playbackPlan(for: .streamingStart)
        guard !Task.isCancelled, request == generation else { return }
        routePlanner.notePlaybackScheduled(using: plan)
        await cuePlayer.playCueToCompletion(named: name, leadingSilence: plan.leadingSilence,
                                            trailingSilence: plan.outputKeepAlive)
    }

    func prepareStartCue() {
        guard settings.playRecordingCues else { return }
        cuePlayer.prepareCue(named: NSSound.Name(settings.startRecordingCueSoundName))
        cuePlayer.prepareOutput()
    }

    func endRecordingFeedback() async {
        stopImmediately()
        await playCueIfEnabled(named: NSSound.Name(settings.stopRecordingCueSoundName))
    }

    func cancelRecordingFeedback() async {
        stopImmediately()
    }

    func stopImmediately() {
        generation &+= 1
        cuePlayer.stop()
    }

    func previewCue(named cueID: String) async {
        let cueName = NSSound.Name(cueID)
        cuePlayer.prepareCue(named: cueName)

        let playbackPlan = await routePlanner.playbackPlan(for: .preview)
        playCue(named: cueName, using: playbackPlan)
        routePlanner.notePlaybackScheduled(using: playbackPlan)
    }

    private func playCueIfEnabled(named name: NSSound.Name) async {
        guard settings.playRecordingCues else {
            return
        }

        cuePlayer.prepareCue(named: name)
        let playbackPlan = await routePlanner.playbackPlan(for: .stop)
        playCue(named: name, using: playbackPlan)
        routePlanner.notePlaybackScheduled(using: playbackPlan)
    }

    private func playCue(named name: NSSound.Name, using playbackPlan: CuePlaybackPlan) {
        cuePlayer.playCue(
            named: name,
            leadingSilence: playbackPlan.leadingSilence,
            trailingSilence: playbackPlan.outputKeepAlive
        )
        logger.info(
            "cue plan name=\(String(name), privacy: .public) route=\(playbackPlan.route?.uid ?? "unknown", privacy: .public) transport=\(playbackPlan.route?.transportDescription ?? "unknown", privacy: .public) warm=\(playbackPlan.isWarm, privacy: .public) leadingSilenceMs=\(Int((playbackPlan.leadingSilence * 1_000).rounded()), privacy: .public) keepAliveMs=\(Int((playbackPlan.outputKeepAlive * 1_000).rounded()), privacy: .public)"
        )
        diagnostics.log(
            "RecordingFeedback",
            "cue plan name=\(String(name)) route=\(playbackPlan.route?.uid ?? "unknown") transport=\(playbackPlan.route?.transportDescription ?? "unknown") warm=\(playbackPlan.isWarm) leadingSilenceMs=\(Int((playbackPlan.leadingSilence * 1_000).rounded())) keepAliveMs=\(Int((playbackPlan.outputKeepAlive * 1_000).rounded())) inputRoute=\(AudioRouteDetector.currentInputRoute()?.uid ?? "unknown") outputRoute=\(AudioRouteDetector.currentOutputRoute()?.uid ?? "unknown")"
        )
    }
}

@MainActor
final class SystemCuePlayer: NSObject, CuePlaying {
    private final class SourceBufferFeed: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        var didProvideBuffer = false

        init(buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }
    }

    private struct CueAsset {
        let buffer: AVAudioPCMBuffer
        let duration: TimeInterval
    }

    private var cueAssets: [NSSound.Name: CueAsset] = [:]
    private let renderFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)
    private var silenceBuffers: [AVAudioFrameCount: AVAudioPCMBuffer] = [:]
    private var players: [String: AVAudioPlayer] = [:]
    private var playerRouteSignature: String?
    private var activePlayer: AVAudioPlayer?
    private var keepAlivePlayer: AVAudioPlayer?
    private var outputWarmupPlayer: AVAudioPlayer?
    private var preparedOutputRoute: String?
    private var activeDelegate: PlaybackDelegate?
    private var playbackGeneration: UInt64 = 0
    private var pendingCompletion: (id: UUID, finish: @MainActor @Sendable () -> Void)?
    private let routeProvider: @MainActor () -> CuePlaybackRoute?
    private let logger = Logger(subsystem: "com.rminerick.HorseWhisprer", category: "RecordingFeedback")
    private let diagnostics = AudioDiagnostics.shared

    init(routeProvider: @escaping @MainActor () -> CuePlaybackRoute? = AudioRouteDetector.currentOutputRoute) {
        self.routeProvider = routeProvider
        super.init()
    }

    // Immutable Sendable callback; AVFAudio can invoke its delegate off MainActor.
    private final class PlaybackDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
        let completed: @MainActor @Sendable (Bool) -> Void
        init(completed: @escaping @MainActor @Sendable (Bool) -> Void) { self.completed = completed }
        nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            Task { @MainActor [completed] in completed(flag) }
        }
        nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
            Task { @MainActor [completed] in completed(false) }
        }
    }

    func prepareCue(named name: NSSound.Name) {
        // Preparing a stopped player opens its output queue without playing sound.
        // Keeping it avoids both the Bluetooth graph race and cold play() latency.
        _ = try? preparedPlayer(named: name, leadingSilence: 0).prepareToPlay()
    }

    func prepareOutput() {
        let route = routeProvider()?.playbackSignature
        guard outputWarmupPlayer == nil || preparedOutputRoute != route else { return }
        // prepareToPlay alone does not start cold Bluetooth output hardware.
        // A brief, silent playback pays that cost while idle. Retain the stopped
        // player afterward; no microphone is running and no audio is retained.
        guard let buffer = silenceBuffer(duration: 0.05),
              let player = try? AVAudioPlayer(data: CueWaveData.encode(buffer, leadingSilence: 0)) else { return }
        guard player.play() else { return }
        outputWarmupPlayer = player
        preparedOutputRoute = route
    }

    func cueDuration(named name: NSSound.Name) -> TimeInterval? {
        cueAsset(for: name).map { $0.duration + (routeProvider()?.isBluetooth == true ? 0.3 : 0) }
    }

    func playCue(named name: NSSound.Name, leadingSilence: TimeInterval, trailingSilence: TimeInterval) {
        startCue(named: name, leadingSilence: leadingSilence, trailingSilence: trailingSilence, completion: nil)
    }

    func playCueToCompletion(named name: NSSound.Name, leadingSilence: TimeInterval, trailingSilence: TimeInterval) async {
        let id = UUID()
        await withTaskCancellationHandler {
            guard !Task.isCancelled else { return }
            await withCheckedContinuation { continuation in
                startCue(named: name, leadingSilence: leadingSilence, trailingSilence: trailingSilence,
                         completion: (id, { continuation.resume() }))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                if self?.pendingCompletion?.id == id { self?.stop() }
            }
        }
    }

    private func finishPendingCue() {
        let completion = pendingCompletion
        pendingCompletion = nil
        completion?.finish()
    }

    private func preparedPlayer(named name: NSSound.Name, leadingSilence: TimeInterval) throws -> AVAudioPlayer {
        let route = routeProvider()
        if playerRouteSignature != route?.playbackSignature {
            // The same AirPods UID can switch from stereo to microphone mode.
            // A prepared queue from the previous format is no longer warm.
            players.removeAll()
            playerRouteSignature = route?.playbackSignature
        }
        let key = "\(name)|\(leadingSilence)"
        if let player = players[key] { return player }
        guard let asset = cueAsset(for: name) else { throw CuePlayerError.bufferAllocationFailed }
        // Keep the output running after the last tone, before completion permits
        // volume ducking. A separate keep-alive player starts too late for that.
        let drain = route?.isBluetooth == true ? 0.3 : 0
        let player = try AVAudioPlayer(data: CueWaveData.encode(asset.buffer, leadingSilence: leadingSilence, trailingSilence: drain))
        guard player.prepareToPlay() else { throw CuePlayerError.playerUnavailable }
        players[key] = player
        return player
    }

    private func startCue(named name: NSSound.Name, leadingSilence: TimeInterval, trailingSilence: TimeInterval,
                          completion: (id: UUID, finish: @MainActor @Sendable () -> Void)?) {
        stop()
        pendingCompletion = completion
        let generation = playbackGeneration
        do {
            let player = try preparedPlayer(named: name, leadingSilence: leadingSilence)
            let delegate = PlaybackDelegate { [weak self] success in
                guard let self, self.playbackGeneration == generation else { return }
                self.diagnostics.log("SystemCuePlayer", "direct playback completed name=\(name) success=\(success)")
                self.activePlayer = nil
                self.activeDelegate = nil
                self.finishPendingCue()
                if success, trailingSilence > 0 { self.playKeepAlive(duration: trailingSilence) }
            }
            activeDelegate = delegate
            activePlayer = player
            player.delegate = delegate
            if player.currentTime > 0 { player.currentTime = 0 }
            guard player.play() else { throw CuePlayerError.playerUnavailable }
            diagnostics.log("SystemCuePlayer", "direct playback started name=\(name) leadingSilenceMs=\(Int(leadingSilence * 1000))")
        } catch {
            diagnostics.log("SystemCuePlayer", "direct playback failed: \(error.localizedDescription)")
            stop()
        }
    }

    private func playKeepAlive(duration: TimeInterval) {
        guard let buffer = silenceBuffer(duration: duration),
              let player = try? AVAudioPlayer(data: CueWaveData.encode(buffer, leadingSilence: 0)) else { return }
        keepAlivePlayer = player
        player.play()
    }

    func stop() {
        playbackGeneration &+= 1
        // pause retains the prepared queue; stop would discard its preparation.
        activePlayer?.pause()
        activePlayer?.currentTime = 0
        activePlayer?.delegate = nil
        activePlayer = nil
        activeDelegate = nil
        keepAlivePlayer?.stop()
        keepAlivePlayer = nil
        finishPendingCue()
    }

    private func cueAsset(for name: NSSound.Name) -> CueAsset? {
        if let cueAsset = cueAssets[name] {
            return cueAsset
        }

        do {
            let cueAsset: CueAsset
            if let descriptor = RecordingCueSoundCatalog.descriptor(for: String(name)) {
                cueAsset = try makeCueAsset(descriptor: descriptor)
            } else if let url = RecordingCueSoundCatalog.audioAssetURL(for: String(name)) {
                cueAsset = try makeCueAsset(url: url)
            } else {
                logger.error("cue definition missing name=\(name, privacy: .public)")
                return nil
            }
            cueAssets[name] = cueAsset
            return cueAsset
        } catch {
            logger.error("cue player creation failed name=\(name, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func makeCueAsset(descriptor: RecordingCueDescriptor) throws -> CueAsset {
        guard let renderFormat else {
            throw CuePlayerError.missingRenderFormat
        }

        let frameCount = AVAudioFrameCount(ceil(descriptor.duration * renderFormat.sampleRate))
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: renderFormat, frameCapacity: frameCount) else {
            throw CuePlayerError.bufferAllocationFailed
        }
        outputBuffer.frameLength = frameCount

        render(descriptor: descriptor, into: outputBuffer)

        let duration = TimeInterval(outputBuffer.frameLength) / renderFormat.sampleRate
        return CueAsset(buffer: outputBuffer, duration: duration)
    }

    private func makeCueAsset(url: URL) throws -> CueAsset {
        guard let renderFormat else {
            throw CuePlayerError.missingRenderFormat
        }

        let audioFile = try AVAudioFile(forReading: url)
        let sourceFormat = audioFile.processingFormat
        let sourceFrameCount = AVAudioFrameCount(audioFile.length)
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: sourceFrameCount) else {
            throw CuePlayerError.bufferAllocationFailed
        }

        try audioFile.read(into: sourceBuffer)

        let outputBuffer: AVAudioPCMBuffer
        if sourceFormat.sampleRate == renderFormat.sampleRate &&
            sourceFormat.channelCount == renderFormat.channelCount &&
            sourceFormat.commonFormat == renderFormat.commonFormat &&
            sourceFormat.isInterleaved == renderFormat.isInterleaved {
            outputBuffer = sourceBuffer
        } else {
            let conversionRatio = renderFormat.sampleRate / sourceFormat.sampleRate
            let estimatedFrameCapacity = AVAudioFrameCount(ceil(Double(sourceBuffer.frameLength) * conversionRatio))
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: renderFormat, frameCapacity: estimatedFrameCapacity) else {
                throw CuePlayerError.bufferAllocationFailed
            }

            guard let converter = AVAudioConverter(from: sourceFormat, to: renderFormat) else {
                throw CuePlayerError.converterUnavailable
            }

            let sourceBufferFeed = SourceBufferFeed(buffer: sourceBuffer)
            var conversionError: NSError?
            let status = converter.convert(to: convertedBuffer, error: &conversionError) { _, outputStatus in
                if sourceBufferFeed.didProvideBuffer {
                    outputStatus.pointee = .endOfStream
                    return nil
                }

                sourceBufferFeed.didProvideBuffer = true
                outputStatus.pointee = .haveData
                return sourceBufferFeed.buffer
            }

            if let conversionError {
                throw conversionError
            }

            guard status != .error else {
                throw CuePlayerError.conversionFailed
            }

            outputBuffer = convertedBuffer
        }

        let duration = TimeInterval(outputBuffer.frameLength) / renderFormat.sampleRate
        return CueAsset(buffer: outputBuffer, duration: duration)
    }

    private func render(descriptor: RecordingCueDescriptor, into buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else {
            return
        }

        let sampleRate = buffer.format.sampleRate
        let channelCount = Int(buffer.format.channelCount)
        let totalFrameCount = Int(buffer.frameLength)
        for channelIndex in 0..<channelCount {
            memset(channelData[channelIndex], 0, totalFrameCount * MemoryLayout<Float>.size)
        }

        var frameOffset = 0
        for segment in descriptor.segments {
            let segmentFrameCount = Int((segment.duration * sampleRate).rounded())
            guard segmentFrameCount > 0 else {
                continue
            }

            if let frequency = segment.frequency {
                for frameIndex in 0..<segmentFrameCount {
                    let absoluteFrame = frameOffset + frameIndex
                    guard absoluteFrame < totalFrameCount else {
                        break
                    }

                    let time = Double(frameIndex) / sampleRate
                    let envelope = amplitudeEnvelope(
                        progress: Double(frameIndex) / Double(max(segmentFrameCount - 1, 1))
                    )
                    let sample = sin(2 * Double.pi * frequency * time) * Double(segment.amplitude) * envelope
                    let renderedSample = Float(sample)
                    for channelIndex in 0..<channelCount {
                        channelData[channelIndex][absoluteFrame] = renderedSample
                    }
                }
            }

            frameOffset += segmentFrameCount
        }
    }

    private func amplitudeEnvelope(progress: Double) -> Double {
        let attack = min(progress / 0.12, 1)
        let release = min((1 - progress) / 0.20, 1)
        return min(attack, release)
    }

    private func silenceBuffer(duration: TimeInterval) -> AVAudioPCMBuffer? {
        guard duration > 0, let renderFormat else {
            return nil
        }

        let frameCount = AVAudioFrameCount(ceil(duration * renderFormat.sampleRate))
        if let silenceBuffer = silenceBuffers[frameCount] {
            return silenceBuffer
        }

        guard let silenceBuffer = AVAudioPCMBuffer(pcmFormat: renderFormat, frameCapacity: frameCount) else {
            return nil
        }

        silenceBuffer.frameLength = frameCount
        if let channelData = silenceBuffer.floatChannelData {
            let byteCount = Int(frameCount) * MemoryLayout<Float>.size
            for channelIndex in 0..<Int(renderFormat.channelCount) {
                memset(channelData[channelIndex], 0, byteCount)
            }
        }

        silenceBuffers[frameCount] = silenceBuffer
        return silenceBuffer
    }
}

enum CuePlayerError: Error {
    case playerUnavailable
    case missingRenderFormat
    case bufferAllocationFailed
    case converterUnavailable
    case conversionFailed
}
