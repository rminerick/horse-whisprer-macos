import XCTest
@testable import HorseWhisprer

final class RecordingCueSoundCatalogTests: XCTestCase {
    func testDefaultRecordingCuesUseHorseSounds() {
        XCTAssertEqual(RecordingCueSoundCatalog.defaultStartName, "soft")
        XCTAssertEqual(RecordingCueSoundCatalog.defaultStopName, "standard")
    }

    func testSystemCueNameSurvivesNormalization() {
        XCTAssertEqual(
            RecordingCueSoundCatalog.normalizedSoundName("Funk", fallback: RecordingCueSoundCatalog.defaultStartName),
            "Funk"
        )
    }

    func testBundledCueNameSurvivesNormalization() {
        XCTAssertEqual(
            RecordingCueSoundCatalog.normalizedSoundName("bright", fallback: RecordingCueSoundCatalog.defaultStartName),
            "bright"
        )
    }
}
