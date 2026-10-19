import XCTest
@testable import HorseWhisprer

final class ModelCatalogTests: XCTestCase {
    func testDefaultModelExistsInCatalog() {
        let catalog = ModelCatalogService()
        XCTAssertTrue(catalog.whisperModels.contains(catalog.defaultModel))
    }

    func testLookupFindsKnownModel() {
        let catalog = ModelCatalogService()
        let model = catalog.model(for: "large-v3-turbo")
        XCTAssertEqual(model?.fileName, "ggml-large-v3-turbo.bin")
    }

    func testModelsHaveDownloadURLs() {
        let catalog = ModelCatalogService()
        XCTAssertTrue(catalog.whisperModels.allSatisfy { $0.downloadURL.absoluteString.contains("huggingface.co/ggerganov/whisper.cpp") })
    }

    func testRecommendedModelsExist() {
        let catalog = ModelCatalogService()
        XCTAssertTrue(catalog.whisperModels.contains(where: \.isRecommended))
    }
}
