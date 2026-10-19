import CryptoKit
import Foundation

enum ModelInstallError: LocalizedError {
    case alreadyDownloading
    case missingTemporaryFile
    case invalidHTTPResponse
    case unexpectedFileSize(expected: Int64, actual: Int64)
    case checksumMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .alreadyDownloading:
            return "This model is already downloading."
        case .missingTemporaryFile:
            return "The downloaded model file was not available."
        case .invalidHTTPResponse:
            return "The model server returned an invalid response."
        case .unexpectedFileSize(let expected, let actual):
            return "The downloaded file size did not match. Expected \(expected) bytes, got \(actual)."
        case .checksumMismatch(let expected, let actual):
            return "The downloaded model checksum did not match. Expected \(expected), got \(actual)."
        }
    }
}

@MainActor
final class ModelInstallService: ObservableObject {
    @Published private(set) var installStates: [String: ModelInstallState] = [:]

    private let modelCatalog: ModelCatalogService
    private let fileManager: FileManager
    private let session: URLSession
    typealias Validation = @Sendable (URL, ASRModelDescriptor, Int64?) async throws -> InstalledModelRecord
    private let storageDirectory: URL?
    private let validation: Validation
    private var activeAttemptIDs: [String: UUID] = [:]
    private var validationTasks: [String: Task<InstalledModelRecord, Error>] = [:]
    private var installedRecords: [String: InstalledModelRecord] = [:]
    private var activeTasks: [String: URLSessionDownloadTask] = [:]
    private var progressObservers: [String: NSKeyValueObservation] = [:]
    private var lastPublishedProgress: [String: Double] = [:]

    init(
        modelCatalog: ModelCatalogService,
        fileManager: FileManager = .default,
        session: URLSession = .shared,
        storageDirectory: URL? = nil,
        validation: @escaping Validation = { url, model, size in
            try ModelInstallService.validateDownloadedModel(at: url, model: model, expectedFileSizeBytes: size)
        }
    ) {
        self.modelCatalog = modelCatalog
        self.fileManager = fileManager
        self.session = session
        self.storageDirectory = storageDirectory
        self.validation = validation
        refreshInstalledState()
    }

    func state(for model: ASRModelDescriptor) -> ModelInstallState {
        installStates[model.id] ?? .notInstalled
    }

    func installedRecord(for modelID: String) -> InstalledModelRecord? {
        installedRecords[modelID]
    }

    func isInstalled(_ model: ASRModelDescriptor) -> Bool {
        guard let record = installedRecords[model.id] else {
            return false
        }

        return fileManager.fileExists(atPath: managedModelURL(for: record).path)
    }

    func installedModelURL(for model: ASRModelDescriptor) -> URL? {
        guard let record = installedRecords[model.id] else {
            return nil
        }

        let url = managedModelURL(for: record)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func refreshInstalledState() {
        do {
            let persisted = try loadManifest()
            let validated = persisted.reduce(into: [String: InstalledModelRecord]()) { partialResult, entry in
                let url = managedModelURL(for: entry.value)
                guard fileManager.fileExists(atPath: url.path) else {
                    return
                }

                partialResult[entry.key] = entry.value
            }

            installedRecords = validated
            try saveManifest()
        } catch {
            installedRecords = [:]
        }

        for model in modelCatalog.whisperModels {
            if activeAttemptIDs[model.id] != nil {
                continue
            }

            if let record = installedRecords[model.id] {
                installStates[model.id] = .installed(record)
            } else if case .failed = installStates[model.id] {
                continue
            } else {
                installStates[model.id] = .notInstalled
            }
        }
    }

    func install(_ model: ASRModelDescriptor) {
        guard activeAttemptIDs[model.id] == nil else { return }

        let downloadsDirectory: URL
        let modelsDirectory: URL
        do {
            downloadsDirectory = try directory("Downloads")
            modelsDirectory = try directory("Models/Whisper")
        } catch {
            installStates[model.id] = .failed(error.localizedDescription)
            return
        }
        let attemptID = UUID()
        activeAttemptIDs[model.id] = attemptID
        installStates[model.id] = .downloading(progress: 0)

        let task = session.downloadTask(with: model.downloadURL) { [weak self] temporaryURL, response, error in
            // URLSession owns temporaryURL only until this callback returns.
            // Take ownership synchronously, before hopping to the main actor.
            let staged: Result<URL, Error> = Result {
                if let error { throw error }
                guard let temporaryURL else { throw ModelInstallError.missingTemporaryFile }
                let ownedURL = downloadsDirectory.appendingPathComponent(UUID().uuidString + ".download")
                try FileManager.default.moveItem(at: temporaryURL, to: ownedURL)
                return ownedURL
            }
            Task { @MainActor [weak self] in
                defer {
                    if case .success(let url) = staged { try? FileManager.default.removeItem(at: url) }
                }
                await self?.handleDownloadCompletion(
                    for: model,
                    attemptID: attemptID,
                    staged: staged,
                    response: response,
                    modelsDirectory: modelsDirectory
                )
            }
        }

        progressObservers[model.id] = task.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            let fractionCompleted = progress.fractionCompleted
            Task { @MainActor [weak self] in
                self?.updateDownloadProgress(for: model.id, attemptID: attemptID, progress: fractionCompleted)
            }
        }

        activeTasks[model.id] = task
        task.resume()
    }

    func cancel(modelID: String) {
        // Invalidate ownership before cancellation can enqueue a completion.
        activeAttemptIDs[modelID] = nil
        validationTasks[modelID]?.cancel()
        validationTasks[modelID] = nil
        activeTasks[modelID]?.cancel()
        activeTasks[modelID] = nil
        progressObservers[modelID] = nil
        lastPublishedProgress[modelID] = nil

        if let record = installedRecords[modelID] {
            installStates[modelID] = .installed(record)
        } else {
            installStates[modelID] = .notInstalled
        }
    }

    func cancelAll() {
        for modelID in Array(activeAttemptIDs.keys) {
            cancel(modelID: modelID)
        }
    }

    func remove(_ model: ASRModelDescriptor) throws {
        cancel(modelID: model.id)

        if let record = installedRecords[model.id] {
            let url = managedModelURL(for: record)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }

        installedRecords[model.id] = nil
        installStates[model.id] = .notInstalled
        try saveManifest()
    }

    private func handleDownloadCompletion(
        for model: ASRModelDescriptor,
        attemptID: UUID,
        staged: Result<URL, Error>,
        response: URLResponse?,
        modelsDirectory: URL
    ) async {
        guard activeAttemptIDs[model.id] == attemptID else { return }
        defer {
            if activeAttemptIDs[model.id] == attemptID {
                activeAttemptIDs[model.id] = nil
                validationTasks[model.id] = nil
            }
        }
        activeTasks[model.id] = nil
        progressObservers[model.id] = nil
        lastPublishedProgress[model.id] = nil

        let temporaryURL: URL
        do {
            temporaryURL = try staged.get()
        } catch let error as URLError where error.code == .cancelled {
            installStates[model.id] = installedRecords[model.id].map(ModelInstallState.installed) ?? .notInstalled
            return
        } catch {
            installStates[model.id] = .failed(error.localizedDescription)
            return
        }

        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            installStates[model.id] = .failed(ModelInstallError.invalidHTTPResponse.localizedDescription)
            return
        }

        let expectedSize = model.expectedFileSizeBytes ?? expectedFileSize(from: response)
        let modelID = model.id
        let validate = validation
        do {
            // Keep the attempt alive through validation. Only the actor may
            // publish the file, after rechecking ownership across this await.
            let task = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                return try await validate(temporaryURL, model, expectedSize)
            }
            validationTasks[modelID] = task
            let record = try await task.value
            guard activeAttemptIDs[modelID] == attemptID else { return }
            let destinationURL = modelsDirectory.appendingPathComponent(model.fileName)
            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            }
            installedRecords[modelID] = record
            try saveManifest()
            installStates[modelID] = .installed(record)
        } catch {
            guard activeAttemptIDs[modelID] == attemptID else { return }
            installStates[modelID] = .failed(error.localizedDescription)
        }
    }

    private func updateDownloadProgress(for modelID: String, attemptID: UUID, progress: Double) {
        guard activeAttemptIDs[modelID] == attemptID, activeTasks[modelID] != nil else { return }
        let clampedProgress = min(max(progress, 0), 1)
        let previousProgress = lastPublishedProgress[modelID] ?? 0
        guard clampedProgress >= 1 || clampedProgress - previousProgress >= 0.01 else { return }
        lastPublishedProgress[modelID] = clampedProgress
        installStates[modelID] = .downloading(progress: clampedProgress)
    }

    private func expectedFileSize(from response: URLResponse?) -> Int64? {
        guard let response else {
            return nil
        }

        return response.expectedContentLength > 0 ? response.expectedContentLength : nil
    }

    private func loadManifest() throws -> [String: InstalledModelRecord] {
        let manifestURL = try manifestURL()
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return [:]
        }

        let data = try Data(contentsOf: manifestURL)
        return try JSONDecoder().decode([String: InstalledModelRecord].self, from: data)
    }

    private func saveManifest() throws {
        let manifestURL = try manifestURL()
        let data = try JSONEncoder().encode(installedRecords)
        try data.write(to: manifestURL, options: .atomic)
    }

    private func managedModelURL(for record: InstalledModelRecord) -> URL {
        do {
            return try directory("Models/Whisper").appendingPathComponent(record.relativePath)
        } catch {
            return fileManager.temporaryDirectory.appendingPathComponent(record.relativePath)
        }
    }

    private func directory(_ relativePath: String) throws -> URL {
        let root = try storageDirectory ?? AppPaths.applicationSupportDirectory()
        let url = root.appendingPathComponent(relativePath, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func manifestURL() throws -> URL {
        try directory("").appendingPathComponent("installed-models.json")
    }

    nonisolated static func validateDownloadedModel(
        at stagingURL: URL,
        model: ASRModelDescriptor,
        expectedFileSizeBytes: Int64?
    ) throws -> InstalledModelRecord {
        try Task.checkCancellation()
        let actualSize = try fileSize(at: stagingURL)
        if let expectedFileSizeBytes, expectedFileSizeBytes > 0, actualSize != expectedFileSizeBytes {
            throw ModelInstallError.unexpectedFileSize(expected: expectedFileSizeBytes, actual: actualSize)
        }
        let actualChecksum = try sha256(for: stagingURL)
        if let expectedSHA256 = model.expectedSHA256,
           actualChecksum.caseInsensitiveCompare(expectedSHA256) != .orderedSame {
            throw ModelInstallError.checksumMismatch(expected: expectedSHA256, actual: actualChecksum)
        }
        try Task.checkCancellation()
        return InstalledModelRecord(modelID: model.id, relativePath: model.fileName,
                                    fileSizeBytes: actualSize, sha256: actualChecksum, installedAt: Date())
    }

    private nonisolated static func fileSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    private nonisolated static func sha256(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()

        while try autoreleasepool(invoking: {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: 1024 * 1024)
            guard let data, !data.isEmpty else {
                return false
            }

            hasher.update(data: data)
            return true
        }) { }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
