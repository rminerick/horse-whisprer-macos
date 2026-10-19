import XCTest
@testable import HorseWhisprer

final class ModelInstallStateTests: XCTestCase {
    func testDownloadingStateExposesProgress() {
        let state = ModelInstallState.downloading(progress: 0.42)
        XCTAssertNotNil(state.progressValue)
        XCTAssertEqual(state.progressValue ?? 0, 0.42, accuracy: 0.001)
        XCTAssertEqual(state.statusLabel, "Downloading 42%")
    }

    func testInstalledStateIsReportedAsInstalled() {
        let record = InstalledModelRecord(
            modelID: "base.en",
            relativePath: "ggml-base.en.bin",
            fileSizeBytes: 123,
            sha256: "abc",
            installedAt: .distantPast
        )

        let state = ModelInstallState.installed(record)
        XCTAssertEqual(state.statusLabel, "Installed")
        XCTAssertNil(state.progressValue)
    }
}
