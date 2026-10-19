import XCTest
@testable import HorseWhisprer

@MainActor
final class NativeModelStoreTests: XCTestCase {
    func testIncompleteDownloadIsNotInstalledAndCancelRetainsOwnershipUntilCleanup() async throws {
        let root = temporaryRoot()
        let gate = TestGate()
        let store = NativeModelStore(root: root) { _, stage, progress in
            try Data([1]).write(to: stage.appendingPathComponent("partial"))
            progress(0.5)
            await gate.wait() // Simulates a downloader which finishes after cancellation.
        }
        let model = ModelCatalogService().nativeModels[0]
        store.install(model)
        await gate.waitUntilEntered()
        XCTAssertNil(store.directory(for: model))
        store.cancel(model)
        store.install(model) // Must not start a second writer before the first has settled.
        await gate.open()
        await waitUntil { store.state(for: model) == .notInstalled }
        XCTAssertNil(store.directory(for: model))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testInstallPublishesAfterValidationAndSurvivesRelaunch() async throws {
        let root = temporaryRoot()
        let gate = TestGate()
        let store = NativeModelStore(root: root) { _, stage, _ in
            try Data([1, 2]).write(to: stage.appendingPathComponent("model"))
            await gate.wait()
        }
        let model = ModelCatalogService().nativeModels[1]
        store.install(model)
        await gate.waitUntilEntered()
        XCTAssertNil(store.directory(for: model))
        await gate.open()
        await waitUntil { store.directory(for: model) != nil }
        let relaunched = NativeModelStore(root: root)
        guard case .installed = relaunched.state(for: model) else { return XCTFail("Missing installed record") }
        try relaunched.remove(model)
        XCTAssertNil(relaunched.directory(for: model))
    }

    func testFailedValidationCleansStagingAndAllowsRetry() async throws {
        let root = temporaryRoot()
        let store = NativeModelStore(root: root) { _, stage, _ in
            try Data([1]).write(to: stage.appendingPathComponent("model"))
            throw NativeASRError.invalidAudio
        }
        let model = ModelCatalogService().nativeModels[0]
        store.install(model)
        await waitUntil { store.state(for: model).failureMessage != nil }
        XCTAssertNil(store.directory(for: model))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        store.install(model)
        XCTAssertNotNil(store.state(for: model).progressValue)
        await waitUntil { store.state(for: model).failureMessage != nil }
    }

    func testRelaunchRecoversAbandonedDownloadsButPreservesActiveLeaseAndInstalledFiles() throws {
        let root = temporaryRoot()
        let abandoned = root.appendingPathComponent(".download-\(UUID().uuidString)")
        let active = root.appendingPathComponent(".download-\(UUID().uuidString)")
        let installed = root.appendingPathComponent("parakeet-unified")
        for directory in [abandoned, active, installed] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // File left behind by an exited process: no live descriptor holds it.
        try Data().write(to: abandoned.appendingPathComponent(".lease"))
        try Data([1]).write(to: abandoned.appendingPathComponent("partial-model"))
        let activeLease = try NativeDownloadLease(directory: active)
        _ = NativeModelStore(root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.path))
        withExtendedLifetime(activeLease) {}
    }

    private func temporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("State did not settle")
    }
}
