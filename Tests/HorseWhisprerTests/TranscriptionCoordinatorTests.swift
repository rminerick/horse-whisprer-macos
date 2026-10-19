import CoreAudio
import XCTest
@testable import HorseWhisprer

final class TranscriptionCoordinatorTests: XCTestCase {
    func testRecordingBadgePreservesLiveInsertionDetails() {
        for status in ["Recording — inserting live…", "Recording — insert on stop…",
                       "Recording — live insertion paused", "Recording…"] {
            XCTAssertEqual(dictationStatusSummary(isRecording: true, isBusy: false, status: status,
                requiresSetup: true, lastError: "Old error"), status)
        }
    }

    func testBusyBadgePreservesTransitionDetailAndIdlePrecedence() {
        XCTAssertEqual(dictationStatusSummary(isRecording: false, isBusy: true, status: "Stopping…",
            requiresSetup: true, lastError: "Old error"), "Stopping…")
        XCTAssertEqual(dictationStatusSummary(isRecording: false, isBusy: false, status: "Idle",
            requiresSetup: true, lastError: "Old error"), "Setup required")
        XCTAssertEqual(dictationStatusSummary(isRecording: false, isBusy: false, status: "Idle",
            requiresSetup: false, lastError: "Old error"), "Old error")
        XCTAssertEqual(dictationStatusSummary(isRecording: false, isBusy: false, status: "Idle",
            requiresSetup: false, lastError: nil), "Idle")
    }

    func testSharedBluetoothRoutePlaysStartCueBeforeRecording() {
        let route = CuePlaybackRoute(uid: "airpods-max", transportType: kAudioDeviceTransportTypeBluetooth)

        XCTAssertTrue(
            shouldPlayStartCueBeforeRecording(
                playRecordingCues: true,
                inputRoute: route,
                outputRoute: route
            )
        )
    }

    func testBluetoothInputOutputPairPlaysStartCueBeforeRecording() {
        XCTAssertTrue(
            shouldPlayStartCueBeforeRecording(
                playRecordingCues: true,
                inputRoute: CuePlaybackRoute(uid: "airpods-input", transportType: kAudioDeviceTransportTypeBluetooth),
                outputRoute: CuePlaybackRoute(uid: "airpods-output", transportType: kAudioDeviceTransportTypeBluetooth)
            )
        )
    }

    func testBuiltInOutputKeepsExistingStartCueOrdering() {
        XCTAssertFalse(
            shouldPlayStartCueBeforeRecording(
                playRecordingCues: true,
                inputRoute: CuePlaybackRoute(uid: "built-in-input", transportType: kAudioDeviceTransportTypeBuiltIn),
                outputRoute: CuePlaybackRoute(uid: "built-in-output", transportType: kAudioDeviceTransportTypeBuiltIn)
            )
        )
    }

    func testDisabledCuesKeepExistingStartCueOrdering() {
        let route = CuePlaybackRoute(uid: "airpods-max", transportType: kAudioDeviceTransportTypeBluetooth)

        XCTAssertFalse(
            shouldPlayStartCueBeforeRecording(
                playRecordingCues: false,
                inputRoute: route,
                outputRoute: route
            )
        )
    }
}
