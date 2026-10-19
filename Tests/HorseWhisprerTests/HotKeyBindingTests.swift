import Carbon
import XCTest
@testable import HorseWhisprer

final class HotKeyBindingTests: XCTestCase {
    func testDefaultBindingIsValid() {
        XCTAssertTrue(HotKeyBinding.defaultBinding.isValid)
        XCTAssertEqual(HotKeyBinding.defaultBinding.displayString, "Control + Option + Space")
    }

    func testModifierOnlyBindingIsInvalid() {
        let binding = HotKeyBinding(
            keyCode: UInt32(kVK_RightCommand),
            carbonModifiers: UInt32(cmdKey)
        )

        XCTAssertFalse(binding.isValid)
    }

    func testDisplayStringFormatsRecordedShortcut() {
        let binding = HotKeyBinding(
            keyCode: UInt32(kVK_ANSI_D),
            carbonModifiers: UInt32(cmdKey) | UInt32(shiftKey)
        )

        XCTAssertEqual(binding.displayString, "Shift + Command + D")
    }
}
