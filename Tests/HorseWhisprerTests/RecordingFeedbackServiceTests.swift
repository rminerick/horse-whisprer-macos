import AppKit
import CoreAudio
import XCTest
@testable import HorseWhisprer

final class RecordingFeedbackServiceTests: XCTestCase {
    @MainActor
    func testStreamingStartCueWaitsForPlayerCompletion() async {
        let settings = makeTestSettings()
        settings.playRecordingCues = true
        let player = CuePlayerSpy()
        let gate = TestGate()
        player.completionGate = gate
        let plan = CuePlaybackPlan(route: nil, isWarm: false, leadingSilence: 0, outputKeepAlive: 0)
        let planner = CueRoutePlannerSpy(startPlan: plan, stopPlan: plan, previewPlan: plan)
        let service = RecordingFeedbackService(settings: settings, cuePlayer: player, routePlanner: planner)
        var completed = false
        let cue = Task { await service.playStartCueToCompletion(); completed = true }
        await gate.waitUntilEntered()
        XCTAssertFalse(completed)
        XCTAssertEqual(player.playedCueNames.count, 1)
        await gate.open()
        await cue.value
        XCTAssertTrue(completed)
    }

    @MainActor
    func testStopInvalidatesStartCueStillWaitingForRoute() async {
        let settings = makeTestSettings()
        settings.playRecordingCues = true
        let player = CuePlayerSpy()
        let gate = TestGate()
        let plan = CuePlaybackPlan(route: nil, isWarm: false, leadingSilence: 0, outputKeepAlive: 0)
        let planner = CueRoutePlannerSpy(startPlan: plan, stopPlan: plan, previewPlan: plan)
        planner.startGate = gate
        let service = RecordingFeedbackService(settings: settings, cuePlayer: player, routePlanner: planner)
        let cue = Task { await service.playStartCueToCompletion() }
        await gate.waitUntilEntered()
        service.stopImmediately()
        await gate.open()
        await cue.value
        XCTAssertTrue(player.playedCueNames.isEmpty)
    }

    @MainActor
    func testBeginAndEndPlaySelectedCueNames() async {
        let settings = makeTestSettings()
        settings.playRecordingCues = true
        settings.startRecordingCueSoundName = "bright"
        settings.stopRecordingCueSoundName = "soft"
        let cuePlayer = CuePlayerSpy()
        let routePlanner = CueRoutePlannerSpy(
            startPlan: CuePlaybackPlan(route: nil, isWarm: false, leadingSilence: 0, outputKeepAlive: 0),
            stopPlan: CuePlaybackPlan(route: nil, isWarm: false, leadingSilence: 0, outputKeepAlive: 0),
            previewPlan: CuePlaybackPlan(route: nil, isWarm: false, leadingSilence: 0, outputKeepAlive: 0)
        )
        let service = RecordingFeedbackService(
            settings: settings,
            cuePlayer: cuePlayer,
            routePlanner: routePlanner,
            startCueAudiblePlaybackWindow: 0.35
        )

        let leadIn = await service.beginRecordingFeedback()
        await service.endRecordingFeedback()

        XCTAssertEqual(cuePlayer.playedCueNames, [NSSound.Name("bright"), NSSound.Name("soft")])
        XCTAssertGreaterThan(leadIn, 0)
    }

    @MainActor
    func testDisabledCuesSkipAudio() async {
        let settings = makeTestSettings()
        settings.playRecordingCues = false
        settings.startRecordingCueSoundName = "standard"
        settings.stopRecordingCueSoundName = "soft"
        let cuePlayer = CuePlayerSpy()
        let routePlanner = CueRoutePlannerSpy(
            startPlan: CuePlaybackPlan(route: nil, isWarm: false, leadingSilence: 0, outputKeepAlive: 0),
            stopPlan: CuePlaybackPlan(route: nil, isWarm: false, leadingSilence: 0, outputKeepAlive: 0),
            previewPlan: CuePlaybackPlan(route: nil, isWarm: false, leadingSilence: 0, outputKeepAlive: 0)
        )
        let service = RecordingFeedbackService(
            settings: settings,
            cuePlayer: cuePlayer,
            routePlanner: routePlanner
        )

        let leadIn = await service.beginRecordingFeedback()
        await service.playStartCueToCompletion()
        await service.endRecordingFeedback()

        XCTAssertTrue(cuePlayer.playedCueNames.isEmpty)
        XCTAssertEqual(leadIn, 0)
    }

    @MainActor
    func testCancelDoesNotPlayStopCue() async {
        let settings = makeTestSettings()
        settings.playRecordingCues = true
        settings.startRecordingCueSoundName = "standard"
        settings.stopRecordingCueSoundName = "soft"
        let cuePlayer = CuePlayerSpy()
        let routePlanner = CueRoutePlannerSpy(
            startPlan: CuePlaybackPlan(route: nil, isWarm: false, leadingSilence: 0, outputKeepAlive: 0),
            stopPlan: CuePlaybackPlan(route: nil, isWarm: false, leadingSilence: 0, outputKeepAlive: 0),
            previewPlan: CuePlaybackPlan(route: nil, isWarm: false, leadingSilence: 0, outputKeepAlive: 0)
        )
        let service = RecordingFeedbackService(
            settings: settings,
            cuePlayer: cuePlayer,
            routePlanner: routePlanner
        )

        _ = await service.beginRecordingFeedback()
        await service.cancelRecordingFeedback()

        XCTAssertEqual(cuePlayer.playedCueNames, [NSSound.Name("standard")])
    }

    @MainActor
    func testBluetoothRouteAddsLeadingSilenceBeforeStartCue() async {
        let settings = makeTestSettings()
        settings.playRecordingCues = true
        settings.startRecordingCueSoundName = "standard"
        let cuePlayer = CuePlayerSpy()
        let route = CuePlaybackRoute(uid: "airpods", transportType: kAudioDeviceTransportTypeBluetooth)
        let routePlanner = CueRoutePlannerSpy(
            startPlan: CuePlaybackPlan(route: route, isWarm: false, leadingSilence: 0.35, outputKeepAlive: 45),
            stopPlan: CuePlaybackPlan(route: route, isWarm: true, leadingSilence: 0, outputKeepAlive: 45),
            previewPlan: CuePlaybackPlan(route: route, isWarm: false, leadingSilence: 0.35, outputKeepAlive: 45)
        )
        let service = RecordingFeedbackService(
            settings: settings,
            cuePlayer: cuePlayer,
            routePlanner: routePlanner,
            startCueAudiblePlaybackWindow: 0.35
        )

        let leadIn = await service.beginRecordingFeedback()

        XCTAssertEqual(cuePlayer.playedCueNames, [NSSound.Name("standard")])
        XCTAssertEqual(cuePlayer.leadingSilences, [0.35])
        XCTAssertEqual(cuePlayer.trailingSilences, [45])
        XCTAssertEqual(leadIn, 785_000_000)
        XCTAssertEqual(routePlanner.notedPlans.count, 1)
    }

    @MainActor
    func testPreviewUsesSameCuePathAndRoutePlanner() async {
        let settings = makeTestSettings()
        settings.playRecordingCues = true
        settings.startRecordingCueSoundName = "bright"
        let cuePlayer = CuePlayerSpy()
        let route = CuePlaybackRoute(uid: "airpods", transportType: kAudioDeviceTransportTypeBluetooth)
        let routePlanner = CueRoutePlannerSpy(
            startPlan: CuePlaybackPlan(route: route, isWarm: false, leadingSilence: 0.35, outputKeepAlive: 45),
            stopPlan: CuePlaybackPlan(route: route, isWarm: true, leadingSilence: 0, outputKeepAlive: 45),
            previewPlan: CuePlaybackPlan(route: route, isWarm: false, leadingSilence: 0.35, outputKeepAlive: 45)
        )
        let service = RecordingFeedbackService(
            settings: settings,
            cuePlayer: cuePlayer,
            routePlanner: routePlanner
        )

        await service.previewCue(named: "bright")

        XCTAssertEqual(cuePlayer.playedCueNames, [NSSound.Name("bright")])
        XCTAssertEqual(cuePlayer.leadingSilences, [0.35])
        XCTAssertEqual(cuePlayer.trailingSilences, [45])
        XCTAssertEqual(routePlanner.requestedKinds, [.preview])
    }

    @MainActor
    func testStopCueKeepsBluetoothRouteWarm() async {
        let settings = makeTestSettings()
        settings.playRecordingCues = true
        settings.stopRecordingCueSoundName = "soft"
        let cuePlayer = CuePlayerSpy()
        let route = CuePlaybackRoute(uid: "airpods", transportType: kAudioDeviceTransportTypeBluetooth)
        let routePlanner = CueRoutePlannerSpy(
            startPlan: CuePlaybackPlan(route: route, isWarm: false, leadingSilence: 0.35, outputKeepAlive: 45),
            stopPlan: CuePlaybackPlan(route: route, isWarm: true, leadingSilence: 0, outputKeepAlive: 45),
            previewPlan: CuePlaybackPlan(route: route, isWarm: false, leadingSilence: 0.35, outputKeepAlive: 45)
        )
        let service = RecordingFeedbackService(
            settings: settings,
            cuePlayer: cuePlayer,
            routePlanner: routePlanner
        )

        await service.endRecordingFeedback()

        XCTAssertEqual(cuePlayer.playedCueNames, [NSSound.Name("soft")])
        XCTAssertEqual(cuePlayer.leadingSilences, [0])
        XCTAssertEqual(cuePlayer.trailingSilences, [45])
    }
}

private final class CuePlayerSpy: CuePlaying {
    var completionGate: TestGate?
    func playCueToCompletion(named name: NSSound.Name, leadingSilence: TimeInterval, trailingSilence: TimeInterval) async {
        playCue(named: name, leadingSilence: leadingSilence, trailingSilence: trailingSilence)
        await completionGate?.wait()
    }
    private(set) var playedCueNames: [NSSound.Name] = []
    private(set) var preparedCueNames: [NSSound.Name] = []
    private(set) var leadingSilences: [TimeInterval] = []
    private(set) var trailingSilences: [TimeInterval] = []
    private(set) var stopCallCount = 0

    func prepareCue(named name: NSSound.Name) {
        preparedCueNames.append(name)
    }

    func cueDuration(named name: NSSound.Name) -> TimeInterval? {
        switch String(name) {
        case "standard":
            return 0.435
        case "soft":
            return 0.39
        case "bright":
            return 0.385
        default:
            return 0.5
        }
    }

    func playCue(named name: NSSound.Name, leadingSilence: TimeInterval, trailingSilence: TimeInterval) {
        playedCueNames.append(name)
        leadingSilences.append(leadingSilence)
        trailingSilences.append(trailingSilence)
    }

    func stop() {
        stopCallCount += 1
    }
}

private final class CueRoutePlannerSpy: CueRoutePlanning {
    var startGate: TestGate?
    let startPlan: CuePlaybackPlan
    let stopPlan: CuePlaybackPlan
    let previewPlan: CuePlaybackPlan
    private(set) var requestedKinds: [CueKind] = []
    private(set) var notedPlans: [CuePlaybackPlan] = []

    init(startPlan: CuePlaybackPlan, stopPlan: CuePlaybackPlan, previewPlan: CuePlaybackPlan) {
        self.startPlan = startPlan
        self.stopPlan = stopPlan
        self.previewPlan = previewPlan
    }

    func playbackPlan(for cueKind: CueKind) async -> CuePlaybackPlan {
        requestedKinds.append(cueKind)
        switch cueKind {
        case .start, .streamingStart:
            await startGate?.wait()
            return startPlan
        case .stop:
            return stopPlan
        case .preview:
            return previewPlan
        }
    }

    func notePlaybackScheduled(using plan: CuePlaybackPlan) {
        notedPlans.append(plan)
    }
}

extension RecordingFeedbackServiceTests {
    @MainActor
    func testBluetoothCueDurationIncludesDrainBeforeDuckingAndTracksProfileChange() throws {
        var route = CuePlaybackRoute(uid: "airpods", transportType: kAudioDeviceTransportTypeBluetooth,
                                     sampleRate: 48000, channelCount: 2)
        let player = SystemCuePlayer(routeProvider: { route })
        let bluetoothDuration = try XCTUnwrap(player.cueDuration(named: .init("bright")))
        route = CuePlaybackRoute(uid: "speakers", transportType: kAudioDeviceTransportTypeBuiltIn)
        let wiredDuration = try XCTUnwrap(player.cueDuration(named: .init("bright")))
        XCTAssertEqual(bluetoothDuration - wiredDuration, 0.3, accuracy: 0.00001)
    }
}
