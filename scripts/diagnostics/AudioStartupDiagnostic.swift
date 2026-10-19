import AVFoundation
import Foundation
@main struct AudioStartupDiagnostic {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw NSError(domain: "Supply output directory", code: 1) }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw NSError(domain: "Microphone permission is required for this explicit diagnostic", code: 1)
        }
        let inputUID = AudioRouteDetector.currentInputRoute()?.uid
        let outputUID = AudioRouteDetector.currentOutputRoute()?.uid
        func checkRoute() throws {
            guard inputUID == AudioRouteDetector.currentInputRoute()?.uid,
                  outputUID == AudioRouteDetector.currentOutputRoute()?.uid else {
                throw NSError(domain: "Audio route changed during measurement; rerun on a stable route", code: 1)
            }
        }
        let player = SystemCuePlayer()
        let planner = CueRoutePlanner()
        for mode in ["first", "repeat"] {
            let input = AudioQueueCapture()
            try checkRoute()
            print("ROUTE_PREPARE \(mode) input=\(AudioRouteDetector.currentInputRoute()?.uid ?? "none") output=\(AudioRouteDetector.currentOutputRoute()?.uid ?? "none")")
            try input.prepare()
            player.prepareCue(named: .init("bright"))
            player.prepareOutput()
            let tap = OutputTap(); try tap.start()
            try await Task.sleep(for: .seconds(8))
            try checkRoute()
            print("ROUTE_TRIGGER \(mode) input=\(AudioRouteDetector.currentInputRoute()?.uid ?? "none") output=\(AudioRouteDetector.currentOutputRoute()?.uid ?? "none")")
            let trigger = ProcessInfo.processInfo.systemUptime
            let stream = try await input.start()
            let captureMs = (ProcessInfo.processInfo.systemUptime-trigger)*1000
            let collected = Task { () throws -> (Int, Double) in
                var first = true; var frames = 0; var last = 0.0; var maxGap = 0.0
                for try await chunk in stream {
                    if first { print("FIRST_BUFFER \(mode) ms=\((chunk.capturedAt-trigger)*1000)"); first = false }
                    if last != 0 { maxGap = max(maxGap, chunk.capturedAt-last) }; last = chunk.capturedAt
                    frames += chunk.samples.count
                }
                return (frames, maxGap)
            }
            let cue = Task {
                let plan = await planner.playbackPlan(for: .streamingStart)
                await player.playCueToCompletion(named: .init("bright"), leadingSilence: plan.leadingSilence, trailingSilence: plan.outputKeepAlive)
            }
            print("START \(mode) inputMs=\(captureMs) cueStartMs=\((ProcessInfo.processInfo.systemUptime-trigger)*1000)")
            try await Task.sleep(for: .seconds(2))
            player.stop(); input.stop(); tap.stop()
            await cue.value
            let (frames, gap) = try await collected.value
            print("CAPTURE_CONTINUITY \(mode) seconds=\(Double(frames)/16000) maxCallbackGapMs=\(gap*1000)")
            try checkRoute()
            try tap.signal.save("direct-\(mode)", since: trigger)
        }
        // Compare against the previous production engine, including its graph
        // construction at the trigger. Discard every sample after timing it.
        for mode in ["first", "repeat"] {
            let input = StreamingAudioCapture()
            try await Task.sleep(for: .seconds(8))
            try checkRoute()
            let trigger = ProcessInfo.processInfo.systemUptime
            let chunks = try input.start()
            let collected = Task {
                var first = true
                for try await chunk in chunks {
                    if first { print("BASELINE_BUFFER \(mode) ms=\((chunk.capturedAt-trigger)*1000)"); first = false }
                }
            }
            try await Task.sleep(for: .milliseconds(500))
            input.stop()
            try await collected.value
            try checkRoute()
        }
    }
}
