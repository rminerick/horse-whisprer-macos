import Foundation
import Synchronization
import XCTest
@testable import HorseWhisprer

@MainActor
final class ModelInstallServiceTests: XCTestCase {
    func testDownloadSurvivesURLSessionTemporaryFileRemoval() async throws {
        let root = try temporaryDirectory()
        let session = ControlledDownloadSession()
        let catalog = ModelCatalogService()
        let service = ModelInstallService(modelCatalog: catalog, session: session, storageDirectory: root)
        let model = catalog.defaultModel.unpinned
        let bytes = Data("downloaded model fixture".utf8)
        let temporaryURL = root.appendingPathComponent("session-owned.tmp")
        try bytes.write(to: temporaryURL)
        service.install(model)
        let done = expectation(description: "installed")
        let observer = service.$installStates.sink { states in
            if case .installed = states[model.id] { done.fulfill() }
            if case .failed(let message) = states[model.id] { XCTFail(message); done.fulfill() }
        }
        // Deliver on the current actor so the scheduled Task cannot run until
        // after we simulate URLSession deleting its temporary file.
        session.createdTasks[0].complete(url: temporaryURL, response: response(model), error: nil)
        try? FileManager.default.removeItem(at: temporaryURL)
        await fulfillment(of: [done], timeout: 3)
        withExtendedLifetime(observer) {}
        let installed = try XCTUnwrap(service.installedModelURL(for: model))
        XCTAssertEqual(try Data(contentsOf: installed), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Downloads").path), [])
    }

    func testRejectedResponseCleansOwnedStagingFile() async throws {
        let root = try temporaryDirectory()
        let session = ControlledDownloadSession()
        let catalog = ModelCatalogService()
        let service = ModelInstallService(modelCatalog: catalog, session: session, storageDirectory: root)
        let model = catalog.defaultModel.unpinned
        let temporaryURL = root.appendingPathComponent("session-owned.tmp")
        try Data("error page".utf8).write(to: temporaryURL)
        service.install(model)
        let done = expectation(description: "rejected")
        let observer = service.$installStates.sink { states in
            if case .failed = states[model.id] { done.fulfill() }
        }
        session.createdTasks[0].complete(url: temporaryURL, response: response(model, status: 500), error: nil)
        await fulfillment(of: [done], timeout: 3)
        withExtendedLifetime(observer) {}
        XCTAssertFalse(service.isInstalled(model))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Downloads").path), [])
    }

    func testOldCompletionCannotClearRetriedDownload() async throws {
        let root = try temporaryDirectory()
        let session = ControlledDownloadSession()
        let catalog = ModelCatalogService()
        let model = catalog.defaultModel.unpinned
        let service = ModelInstallService(modelCatalog: catalog, session: session, storageDirectory: root)
        service.install(model)
        let old = session.createdTasks[0]
        service.cancel(modelID: model.id)
        service.install(model)
        let retry = session.createdTasks[1]
        let temporaryURL = root.appendingPathComponent("old.tmp")
        try Data("stale download".utf8).write(to: temporaryURL)
        old.complete(url: temporaryURL, response: response(model), error: nil)
        try await waitForStagingCleanup(root)
        XCTAssertEqual(service.state(for: model), .downloading(progress: 0))
        XCTAssertFalse(service.isInstalled(model))
        service.cancel(modelID: model.id)
        XCTAssertEqual(retry.cancelCount, 1, "Old completion must not disconnect the retry's task")
    }

    func testQueuedOldProgressCannotOverwriteRetryProgress() async throws {
        let root = try temporaryDirectory()
        let session = ControlledDownloadSession()
        let catalog = ModelCatalogService()
        let model = catalog.defaultModel.unpinned
        let service = ModelInstallService(modelCatalog: catalog, session: session, storageDirectory: root)
        service.install(model)
        session.createdTasks[0].progress.completedUnitCount = 90
        service.cancel(modelID: model.id)
        service.install(model)
        let progressed = expectation(description: "retry progress")
        let observer = service.$installStates.sink { states in
            if states[model.id] == .downloading(progress: 0.2) { progressed.fulfill() }
        }
        session.createdTasks[1].progress.completedUnitCount = 20
        await fulfillment(of: [progressed], timeout: 3)
        withExtendedLifetime(observer) {}
        XCTAssertEqual(service.state(for: model), .downloading(progress: 0.2))
        service.cancelAll()
    }

    func testCancelDuringValidationKeepsRetryOwnedAndCleansStaging() async throws {
        let root = try temporaryDirectory()
        let session = ControlledDownloadSession()
        let catalog = ModelCatalogService()
        let model = catalog.defaultModel.unpinned
        let gate = TestGate()
        let service = ModelInstallService(modelCatalog: catalog, session: session, storageDirectory: root,
            validation: { _, model, _ in
                await gate.wait()
                // Deliberately ignore cancellation to exercise a late success.
                return InstalledModelRecord(modelID: model.id, relativePath: model.fileName,
                    fileSizeBytes: 5, sha256: "test", installedAt: Date())
            })
        service.install(model)
        let temporaryURL = root.appendingPathComponent("old.tmp")
        try Data("stale".utf8).write(to: temporaryURL)
        session.createdTasks[0].complete(url: temporaryURL, response: response(model), error: nil)
        await gate.waitUntilEntered()
        service.install(model)
        XCTAssertEqual(session.createdTasks.count, 1, "Validation must still own the active attempt")
        XCTAssertEqual(service.state(for: model), .downloading(progress: 0))
        service.cancelAll()
        service.install(model)
        await gate.open()
        try await waitForStagingCleanup(root)
        XCTAssertEqual(service.state(for: model), .downloading(progress: 0))
        XCTAssertFalse(service.isInstalled(model))
        service.cancelAll()
        XCTAssertEqual(session.createdTasks[1].cancelCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Models/Whisper/" + model.fileName).path))
    }

    func testRemoveDuringValidationCannotReinstallModel() async throws {
        let root = try temporaryDirectory()
        let session = ControlledDownloadSession()
        let catalog = ModelCatalogService()
        let model = catalog.defaultModel.unpinned
        let gate = TestGate()
        let service = ModelInstallService(modelCatalog: catalog, session: session, storageDirectory: root,
            validation: { _, model, _ in
                await gate.wait()
                return InstalledModelRecord(modelID: model.id, relativePath: model.fileName,
                    fileSizeBytes: 5, sha256: "test", installedAt: Date())
            })
        service.install(model)
        let temporaryURL = root.appendingPathComponent("removed.tmp")
        try Data("stale".utf8).write(to: temporaryURL)
        session.createdTasks[0].complete(url: temporaryURL, response: response(model), error: nil)
        await gate.waitUntilEntered()
        try service.remove(model)
        await gate.open()
        try await waitForStagingCleanup(root)
        XCTAssertEqual(service.state(for: model), .notInstalled)
        XCTAssertNil(service.installedModelURL(for: model))
        let persisted = try Data(contentsOf: root.appendingPathComponent("installed-models.json"))
        XCTAssertEqual(try JSONDecoder().decode([String: InstalledModelRecord].self, from: persisted), [:])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Models/Whisper/" + model.fileName).path))
    }

    private func waitForStagingCleanup(_ root: URL) async throws {
        let directory = root.appendingPathComponent("Downloads")
        for _ in 0..<200 {
            if try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for stale attempt to release its staging file")
    }

    private func response(_ model: ASRModelDescriptor, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: model.downloadURL, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ModelInstallTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

// Foundation callbacks may be invoked from any thread; lock the captured task
// list and counters, even though these tests deliver callbacks on MainActor.
final class ControlledDownloadSession: URLSession, @unchecked Sendable {
    private let storage = Mutex<[ControlledDownloadTask]>([])
    var createdTasks: [ControlledDownloadTask] { storage.withLock { $0 } }
    override func downloadTask(with url: URL, completionHandler: @escaping @Sendable (URL?, URLResponse?, Error?) -> Void) -> URLSessionDownloadTask {
        let task = ControlledDownloadTask(completion: completionHandler)
        storage.withLock { $0.append(task) }
        return task
    }
}

final class ControlledDownloadTask: URLSessionDownloadTask, @unchecked Sendable {
    private let completion: @Sendable (URL?, URLResponse?, Error?) -> Void
    private let cancellations = Mutex(0)
    private let trackedProgress = Progress(totalUnitCount: 100)
    var cancelCount: Int { cancellations.withLock { $0 } }
    override var progress: Progress { trackedProgress }
    init(completion: @escaping @Sendable (URL?, URLResponse?, Error?) -> Void) {
        self.completion = completion
        super.init()
    }
    override func resume() {}
    override func cancel() { cancellations.withLock { $0 += 1 } }
    func complete(url: URL? = nil, response: URLResponse? = nil, error: Error? = nil) {
        completion(url, response, error)
    }
}
