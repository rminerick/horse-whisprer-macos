import XCTest
@testable import HorseWhisprer

final class InsertBehaviorTests: XCTestCase {
    func testInsertBehaviorTitlesAreStable() {
        XCTAssertEqual(InsertBehavior.pasteThenType.title, "Paste, then type fallback")
        XCTAssertEqual(InsertBehavior.copyOnly.title, "Copy only")
        XCTAssertEqual(InsertBehavior.typeOnly.title, "Type only")
    }
}
