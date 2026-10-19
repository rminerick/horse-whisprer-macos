import XCTest
@testable import HorseWhisprer

final class AppDistributionTests: XCTestCase {
    func testDefaultsToCommunityWhenMissing() {
        let distribution = AppDistribution.from(infoDictionary: nil)
        XCTAssertEqual(distribution.flavor, .community)
        XCTAssertEqual(distribution.displayName, "Community build")
    }

    func testParsesOfficialFlavor() {
        let distribution = AppDistribution.from(infoDictionary: [
            "HorseWhisprerDistributionFlavor": "official"
        ])

        XCTAssertEqual(distribution.flavor, .official)
        XCTAssertTrue(distribution.isOfficial)
    }

    func testInvalidFlavorFallsBackToCommunity() {
        let distribution = AppDistribution.from(infoDictionary: [
            "HorseWhisprerDistributionFlavor": "staging"
        ])

        XCTAssertEqual(distribution.flavor, .community)
        XCTAssertFalse(distribution.isOfficial)
    }
}
