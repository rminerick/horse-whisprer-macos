import CoreAudio
import XCTest
@testable import HorseWhisprer

final class RecordingOutputAudioServiceTests: XCTestCase {
    @MainActor
    func testDuckTargetCapsLoudPlaybackAtVeryLowVolume() {
        let target = SystemOutputAudioDeviceController.duckedVolumeTarget(for: 0.8)

        XCTAssertEqual(target, 0.03, accuracy: 0.0001)
    }

    @MainActor
    func testDuckTargetScalesDownAlreadyQuietPlaybackFurther() {
        let target = SystemOutputAudioDeviceController.duckedVolumeTarget(for: 0.2)

        XCTAssertEqual(target, 0.016, accuracy: 0.0001)
    }

    @MainActor
    func testOffSkipsOutputChanges() async {
        let settings = makeTestSettings()
        settings.dictationOutputAudioBehavior = .off
        let controller = OutputAudioControllerSpy()
        let service = RecordingOutputAudioService(
            settings: settings,
            deviceController: controller,
            sleep: { _ in }
        )

        service.beginRecordingSession(afterDelayNanoseconds: 0)
        await Task.yield()
        service.endRecordingSession()

        XCTAssertTrue(controller.appliedBehaviors.isEmpty)
        XCTAssertTrue(controller.restoredStates.isEmpty)
    }

    @MainActor
    func testDuckAppliesImmediatelyAndRestoresOnEnd() async {
        let settings = makeTestSettings()
        settings.dictationOutputAudioBehavior = .duck
        let controller = OutputAudioControllerSpy()
        let service = RecordingOutputAudioService(
            settings: settings,
            deviceController: controller,
            sleep: { _ in }
        )

        service.beginRecordingSession(afterDelayNanoseconds: 0)
        service.endRecordingSession()

        XCTAssertEqual(controller.appliedBehaviors, [.duck])
        XCTAssertEqual(controller.restoredStates, [controller.restorationState])
    }

    @MainActor
    func testDelayedApplyWaitsForCueWindow() async {
        let settings = makeTestSettings()
        settings.dictationOutputAudioBehavior = .mute
        let controller = OutputAudioControllerSpy()
        let sleeper = SleepGate()
        let applied = expectation(description: "delayed output audio behavior applied")
        let inputRoute = CuePlaybackRoute(uid: "built-in-input", transportType: kAudioDeviceTransportTypeBuiltIn)
        let outputRoute = CuePlaybackRoute(uid: "built-in-output", transportType: kAudioDeviceTransportTypeBuiltIn)
        let service = RecordingOutputAudioService(
            settings: settings,
            deviceController: controller,
            inputRouteProvider: { inputRoute },
            outputRouteProvider: { outputRoute },
            sleep: { delay in
                await sleeper.sleep(delay: delay)
            }
        )
        controller.onApply = { behavior in
            if behavior == .mute {
                applied.fulfill()
            }
        }

        service.beginRecordingSession(afterDelayNanoseconds: 42)
        await sleeper.waitForInvocation()
        XCTAssertTrue(controller.appliedBehaviors.isEmpty)

        await sleeper.resumeAll()
        await fulfillment(of: [applied], timeout: 1)

        XCTAssertEqual(controller.appliedBehaviors, [.mute])
    }

    @MainActor
    func testEndingBeforeDelayedApplyCancelsPendingChange() async {
        let settings = makeTestSettings()
        settings.dictationOutputAudioBehavior = .mute
        let controller = OutputAudioControllerSpy()
        let sleeper = SleepGate()
        let service = RecordingOutputAudioService(
            settings: settings,
            deviceController: controller,
            sleep: { delay in
                await sleeper.sleep(delay: delay)
            }
        )

        service.beginRecordingSession(afterDelayNanoseconds: 42)
        await sleeper.waitForInvocation()
        service.endRecordingSession()
        await sleeper.resumeAll()
        await Task.yield()

        XCTAssertTrue(controller.appliedBehaviors.isEmpty)
        XCTAssertTrue(controller.restoredStates.isEmpty)
    }

    @MainActor
    func testSharedInputAndOutputRouteAllowsDuckDeviceChange() async {
        let settings = makeTestSettings()
        settings.dictationOutputAudioBehavior = .duck
        let controller = OutputAudioControllerSpy()
        let sharedRoute = CuePlaybackRoute(uid: "shared-route", transportType: kAudioDeviceTransportTypeBuiltIn)
        let service = RecordingOutputAudioService(
            settings: settings,
            deviceController: controller,
            inputRouteProvider: { sharedRoute },
            outputRouteProvider: { sharedRoute },
            sleep: { _ in }
        )

        service.beginRecordingSession(afterDelayNanoseconds: 0)
        service.endRecordingSession()

        XCTAssertEqual(controller.appliedBehaviors, [.duck])
        XCTAssertEqual(controller.restoredStates, [controller.restorationState])
    }

    @MainActor
    func testBluetoothInputAndOutputPairAllowsDuckDeviceChange() async {
        let settings = makeTestSettings()
        settings.dictationOutputAudioBehavior = .duck
        let controller = OutputAudioControllerSpy()
        let service = RecordingOutputAudioService(
            settings: settings,
            deviceController: controller,
            inputRouteProvider: {
                CuePlaybackRoute(uid: "bt-input", transportType: kAudioDeviceTransportTypeBluetooth)
            },
            outputRouteProvider: {
                CuePlaybackRoute(uid: "bt-output", transportType: kAudioDeviceTransportTypeBluetooth)
            },
            sleep: { _ in }
        )

        service.beginRecordingSession(afterDelayNanoseconds: 0)
        service.endRecordingSession()

        XCTAssertEqual(controller.appliedBehaviors, [.duck])
        XCTAssertEqual(controller.restoredStates, [controller.restorationState])
    }

    @MainActor
    func testBluetoothInputAndOutputPairStillSkipsMute() async {
        let settings = makeTestSettings()
        settings.dictationOutputAudioBehavior = .mute
        let controller = OutputAudioControllerSpy()
        let service = RecordingOutputAudioService(
            settings: settings,
            deviceController: controller,
            inputRouteProvider: {
                CuePlaybackRoute(uid: "bt-input", transportType: kAudioDeviceTransportTypeBluetooth)
            },
            outputRouteProvider: {
                CuePlaybackRoute(uid: "bt-output", transportType: kAudioDeviceTransportTypeBluetooth)
            },
            sleep: { _ in }
        )

        service.beginRecordingSession(afterDelayNanoseconds: 0)
        service.endRecordingSession()

        XCTAssertTrue(controller.appliedBehaviors.isEmpty)
        XCTAssertTrue(controller.restoredStates.isEmpty)
    }
}

private final class OutputAudioControllerSpy: OutputAudioDeviceControlling {
    let restorationState = OutputAudioRestorationState(
        deviceID: AudioDeviceID(7),
        originalMute: false,
        originalVolume: 0.8,
        restoreMute: false,
        restoreVolume: true
    )

    private(set) var appliedBehaviors: [DictationOutputAudioBehavior] = []
    private(set) var restoredStates: [OutputAudioRestorationState] = []
    var onApply: ((DictationOutputAudioBehavior) -> Void)?

    func applyBehavior(_ behavior: DictationOutputAudioBehavior) -> OutputAudioRestorationState? {
        appliedBehaviors.append(behavior)
        onApply?(behavior)
        return restorationState
    }

    func restore(_ restorationState: OutputAudioRestorationState) {
        restoredStates.append(restorationState)
    }
}

private actor SleepGate {
    private var invocations: [UInt64] = []
    private var invocationWaiters: [CheckedContinuation<Void, Never>] = []
    private var sleepContinuations: [CheckedContinuation<Void, Never>] = []

    func sleep(delay: UInt64) async {
        invocations.append(delay)
        invocationWaiters.forEach { $0.resume() }
        invocationWaiters.removeAll()

        await withCheckedContinuation { continuation in
            sleepContinuations.append(continuation)
        }
    }

    func waitForInvocation() async {
        guard invocations.isEmpty else {
            return
        }

        await withCheckedContinuation { continuation in
            invocationWaiters.append(continuation)
        }
    }

    func resumeAll() {
        let continuations = sleepContinuations
        sleepContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }
}
