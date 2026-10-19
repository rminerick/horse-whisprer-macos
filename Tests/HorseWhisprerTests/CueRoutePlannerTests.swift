import CoreAudio
import XCTest
@testable import HorseWhisprer

final class CueRoutePlannerTests: XCTestCase {
    @MainActor
    func testStreamingCuePadsBluetoothOutputWithoutHoldingCapture() async {
        var sleeps: [UInt64] = []
        let planner = CueRoutePlanner(
            routeProvider: { CuePlaybackRoute(uid: "bt", transportType: kAudioDeviceTransportTypeBluetooth) },
            sleep: { sleeps.append($0) })
        let plan = await planner.playbackPlan(for: .streamingStart)
        XCTAssertEqual(plan.leadingSilence, 0.8)
        XCTAssertEqual(plan.outputKeepAlive, 0)
        XCTAssertEqual(sleeps, [300_000_000])
    }

    @MainActor
    func testBluetoothRouteKeepsStartupLeadInEvenWhenMarkedWarm() async {
        let route = CuePlaybackRoute(uid: "bt-route", transportType: kAudioDeviceTransportTypeBluetooth)
        var currentDate = Date(timeIntervalSince1970: 1_000)
        let planner = CueRoutePlanner(
            routeProvider: { route },
            now: { currentDate },
            bluetoothColdLeadIn: 0.35,
            bluetoothKeepAlive: 45
        )

        let coldPlan = await planner.playbackPlan(for: .start)
        XCTAssertFalse(coldPlan.isWarm)
        XCTAssertEqual(coldPlan.leadingSilence, 0.35)
        XCTAssertEqual(coldPlan.outputKeepAlive, 45)

        planner.notePlaybackScheduled(using: coldPlan)
        let warmPlan = await planner.playbackPlan(for: .start)
        XCTAssertTrue(warmPlan.isWarm)
        XCTAssertEqual(warmPlan.leadingSilence, 0.35)

        currentDate = currentDate.addingTimeInterval(46)
        let coldAgainPlan = await planner.playbackPlan(for: .start)
        XCTAssertFalse(coldAgainPlan.isWarm)
        XCTAssertEqual(coldAgainPlan.leadingSilence, 0.35)
    }

    @MainActor
    func testStopCuePadsEvenRecentlyUsedBluetoothRoute() async {
        for transport in [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE] {
            let planner = CueRoutePlanner(routeProvider: { CuePlaybackRoute(uid: "airpods", transportType: transport) })
            let first = await planner.playbackPlan(for: .stop)
            planner.notePlaybackScheduled(using: first)
            let next = await planner.playbackPlan(for: .stop)
            XCTAssertTrue(next.isWarm)
            XCTAssertEqual(next.leadingSilence, 0.8)
        }
    }

    @MainActor
    func testSameUIDProfileChangeRestartsRouteStabilityWindow() async {
        var polls = 0
        var time = Date(timeIntervalSince1970: 0)
        let planner = CueRoutePlanner(routeProvider: {
            CuePlaybackRoute(uid: "same-airpods", transportType: kAudioDeviceTransportTypeBluetooth,
                sampleRate: polls < 2 ? 48000 : 24000, channelCount: polls < 2 ? 2 : 1)
        }, now: { time }, sleep: { _ in polls += 1; time.addTimeInterval(0.05) })
        let plan = await planner.playbackPlan(for: .start)
        XCTAssertEqual(polls, 4)
        XCTAssertEqual(plan.route?.sampleRate, 24000)
        XCTAssertEqual(plan.route?.channelCount, 1)
    }

    @MainActor
    func testNonBluetoothRouteHasNoExtraDelayOrKeepAlive() async {
        let route = CuePlaybackRoute(uid: "usb-route", transportType: kAudioDeviceTransportTypeUSB)
        let planner = CueRoutePlanner(
            routeProvider: { route },
            now: Date.init,
            bluetoothColdLeadIn: 0.35,
            bluetoothKeepAlive: 45
        )

        let plan = await planner.playbackPlan(for: .start)
        XCTAssertFalse(plan.isWarm)
        XCTAssertEqual(plan.leadingSilence, 0)
        XCTAssertEqual(plan.outputKeepAlive, 0)
    }
}
