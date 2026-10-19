import Carbon
import XCTest
@testable import HorseWhisprer

final class SpecialKeyTriggerDetectorTests: XCTestCase {
    func testEverySpecialKeyTriggerFiresOnSecondSoloTapRelease() {
        for trigger in SpecialKeyTrigger.allCases {
            var currentTime: TimeInterval = 100
            var detector = SpecialKeyTriggerDetector(now: { currentTime })

            XCTAssertFalse(
                detector.process(pressEvent(for: trigger), trigger: trigger),
                "First press should not immediately trigger for \(trigger.rawValue)"
            )

            XCTAssertFalse(
                detector.process(releaseEvent(for: trigger), trigger: trigger),
                "First release should not trigger for \(trigger.rawValue)"
            )

            currentTime += 0.2

            XCTAssertFalse(
                detector.process(pressEvent(for: trigger), trigger: trigger),
                "Second press should not immediately trigger for \(trigger.rawValue)"
            )

            XCTAssertTrue(
                detector.process(releaseEvent(for: trigger), trigger: trigger),
                "Second release should trigger for \(trigger.rawValue)"
            )
        }
    }

    func testSpecialKeyUsedInShortcutDoesNotTrigger() {
        var detector = SpecialKeyTriggerDetector(now: { 100 })

        XCTAssertFalse(
            detector.process(pressEvent(for: .rightCommandTapAlone), trigger: .rightCommandTapAlone)
        )
        XCTAssertFalse(
            detector.process(
                .keyDown(keyCode: UInt16(kVK_ANSI_D)),
                trigger: .rightCommandTapAlone
            )
        )
        XCTAssertFalse(
            detector.process(
                .keyUp(keyCode: UInt16(kVK_ANSI_D)),
                trigger: .rightCommandTapAlone
            )
        )
        XCTAssertFalse(
            detector.process(releaseEvent(for: .rightCommandTapAlone), trigger: .rightCommandTapAlone)
        )
    }

    func testOtherModifierWhileTrackedKeyHeldSuppressesTrigger() {
        var detector = SpecialKeyTriggerDetector(now: { 100 })

        XCTAssertFalse(
            detector.process(pressEvent(for: .rightCommandTapAlone), trigger: .rightCommandTapAlone)
        )
        XCTAssertFalse(
            detector.process(
                combinedPressEvent(for: .leftOptionTapAlone, active: [.rightCommandTapAlone, .leftOptionTapAlone]),
                trigger: .rightCommandTapAlone
            )
        )
        XCTAssertFalse(
            detector.process(combinedReleaseEvent(for: .rightCommandTapAlone, active: [.leftOptionTapAlone]), trigger: .rightCommandTapAlone)
        )
    }

    func testOppositeSideSiblingAlreadyHeldSuppressesTrigger() {
        var detector = SpecialKeyTriggerDetector(now: { 100 })

        XCTAssertFalse(
            detector.process(pressEvent(for: .leftCommandTapAlone), trigger: .rightCommandTapAlone)
        )
        XCTAssertFalse(
            detector.process(combinedPressEvent(for: .rightCommandTapAlone, active: [.leftCommandTapAlone, .rightCommandTapAlone]), trigger: .rightCommandTapAlone)
        )
        XCTAssertFalse(
            detector.process(combinedReleaseEvent(for: .rightCommandTapAlone, active: [.leftCommandTapAlone]), trigger: .rightCommandTapAlone)
        )
        XCTAssertFalse(
            detector.process(releaseEvent(for: .leftCommandTapAlone), trigger: .rightCommandTapAlone)
        )
    }

    func testSecondTapOutsideTimeoutDoesNotTrigger() {
        var currentTime: TimeInterval = 100
        var detector = SpecialKeyTriggerDetector(now: { currentTime })

        XCTAssertFalse(
            detector.process(pressEvent(for: .rightCommandTapAlone), trigger: .rightCommandTapAlone)
        )
        XCTAssertFalse(
            detector.process(releaseEvent(for: .rightCommandTapAlone), trigger: .rightCommandTapAlone)
        )

        currentTime += 0.8

        XCTAssertFalse(
            detector.process(pressEvent(for: .rightCommandTapAlone), trigger: .rightCommandTapAlone)
        )
        XCTAssertFalse(
            detector.process(releaseEvent(for: .rightCommandTapAlone), trigger: .rightCommandTapAlone)
        )
    }

    func testStrayReleaseEventDoesNotPoisonFutureDoubleTap() {
        var currentTime: TimeInterval = 100
        var detector = SpecialKeyTriggerDetector(now: { currentTime })

        XCTAssertFalse(
            detector.process(releaseEvent(for: .rightCommandTapAlone), trigger: .rightCommandTapAlone)
        )
        XCTAssertFalse(
            detector.process(pressEvent(for: .rightCommandTapAlone), trigger: .rightCommandTapAlone)
        )
        XCTAssertFalse(
            detector.process(releaseEvent(for: .rightCommandTapAlone), trigger: .rightCommandTapAlone)
        )

        currentTime += 0.2

        XCTAssertFalse(
            detector.process(pressEvent(for: .rightCommandTapAlone), trigger: .rightCommandTapAlone)
        )
        XCTAssertTrue(
            detector.process(releaseEvent(for: .rightCommandTapAlone), trigger: .rightCommandTapAlone)
        )
    }

    func testStaleSiblingModifierStateIsClearedByCurrentFlags() {
        var currentTime: TimeInterval = 100
        var detector = SpecialKeyTriggerDetector(now: { currentTime })

        XCTAssertFalse(
            detector.process(pressEvent(for: .leftCommandTapAlone), trigger: .rightCommandTapAlone)
        )

        XCTAssertFalse(
            detector.process(pressEvent(for: .rightCommandTapAlone), trigger: .rightCommandTapAlone)
        )
        XCTAssertFalse(
            detector.process(releaseEvent(for: .rightCommandTapAlone), trigger: .rightCommandTapAlone)
        )

        currentTime += 0.2

        XCTAssertFalse(
            detector.process(pressEvent(for: .rightCommandTapAlone), trigger: .rightCommandTapAlone)
        )
        XCTAssertTrue(
            detector.process(releaseEvent(for: .rightCommandTapAlone), trigger: .rightCommandTapAlone)
        )
    }

    private func pressEvent(for trigger: SpecialKeyTrigger) -> SpecialKeyMonitorEvent {
        .flagsChanged(
            keyCode: trigger.keyCode,
            flags: CGEventFlags(rawValue: trigger.deviceFlagMask)
        )
    }

    private func releaseEvent(for trigger: SpecialKeyTrigger) -> SpecialKeyMonitorEvent {
        .flagsChanged(keyCode: trigger.keyCode, flags: [])
    }

    private func combinedPressEvent(for trigger: SpecialKeyTrigger, active: [SpecialKeyTrigger]) -> SpecialKeyMonitorEvent {
        .flagsChanged(keyCode: trigger.keyCode, flags: flags(for: active))
    }

    private func combinedReleaseEvent(for trigger: SpecialKeyTrigger, active: [SpecialKeyTrigger]) -> SpecialKeyMonitorEvent {
        .flagsChanged(keyCode: trigger.keyCode, flags: flags(for: active))
    }

    private func flags(for triggers: [SpecialKeyTrigger]) -> CGEventFlags {
        CGEventFlags(rawValue: triggers.reduce(into: CGEventFlags.RawValue(0)) { partialResult, trigger in
            partialResult |= trigger.deviceFlagMask
        })
    }
}
