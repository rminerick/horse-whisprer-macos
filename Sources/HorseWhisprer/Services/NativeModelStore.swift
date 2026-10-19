import Foundation
import FluidAudio

/// Native models are multi-file bundles. Only an atomically promoted, validated
/// directory is visible to the engine; interrupted downloads stay in staging.
@MainActor
final class NativeModelStore: ObservableObject {
    typealias Download = @Sendable (ASREngineKind, URL, @escaping @Sendable (Double) -> Void) async throws -> Void
    @Published private(set) var states: [String: ModelInstallState] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var attempts: [String: UUID] = [:]
    private let root: URL
    private let download: Download

    init(root: URL = NativeModelStore.defaultRoot, download: @escaping Download = NativeASRRuntime.download) {
        self.root = root
        self.download = download
        NativeDownloadLease.recoverAbandonedDownloads(in: root)
    }

    nonisolated static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HorseWhisprer/Models/Native", isDirectory: true)
    }

    nonisolated static func installedDirectory(for model: ASRModelDescriptor, root: URL = defaultRoot) -> URL? {
        guard model.engineKind != .whisper else { return nil }
        let directory = root.appendingPathComponent(model.id, isDirectory: true)
        guard let record = try? JSONDecoder().decode(InstalledModelRecord.self,
            from: Data(contentsOf: directory.appendingPathComponent("installed.json"))), record.modelID == model.id else { return nil }
        return directory
    }

    func directory(for model: ASRModelDescriptor) -> URL? { Self.installedDirectory(for: model, root: root) }
    func state(for model: ASRModelDescriptor) -> ModelInstallState {
        if let state = states[model.id] { return state }
        if let directory = directory(for: model),
           let data = try? Data(contentsOf: directory.appendingPathComponent("installed.json")),
           let record = try? JSONDecoder().decode(InstalledModelRecord.self, from: data) { return .installed(record) }
        return .notInstalled
    }

    func install(_ model: ASRModelDescriptor) {
        guard model.engineKind != .whisper, tasks[model.id] == nil, directory(for: model) == nil else { return }
        let attempt = UUID()
        attempts[model.id] = attempt
        let stage = root.appendingPathComponent(".download-\(UUID().uuidString)", isDirectory: true)
        states[model.id] = .downloading(progress: 0)
        tasks[model.id] = Task { [download, root] in
            defer {
                try? FileManager.default.removeItem(at: stage)
                tasks[model.id] = nil
                attempts[model.id] = nil
            }
            do {
                try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
                let lease = try NativeDownloadLease(directory: stage)
                defer { withExtendedLifetime(lease) {} }
                try await download(model.engineKind, stage) { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, self.attempts[model.id] == attempt, let task = self.tasks[model.id], !task.isCancelled else { return }
                        self.states[model.id] = .downloading(progress: min(0.99, max(0, fraction)))
                    }
                }
                try Task.checkCancellation()
                let record = InstalledModelRecord(modelID: model.id, relativePath: model.id,
                    fileSizeBytes: 0, sha256: "", installedAt: Date())
                try JSONEncoder().encode(record).write(to: stage.appendingPathComponent("installed.json"), options: .atomic)
                try FileManager.default.moveItem(at: stage, to: root.appendingPathComponent(model.id))
                states[model.id] = .installed(record)
            } catch {
                states[model.id] = Task.isCancelled ? .notInstalled : .failed(error.localizedDescription)
            }
        }
    }

    func cancel(_ model: ASRModelDescriptor) { tasks[model.id]?.cancel() }
    func cancelAll() { tasks.values.forEach { $0.cancel() } }
    func remove(_ model: ASRModelDescriptor) throws {
        guard tasks[model.id] == nil else { throw ModelInstallError.alreadyDownloading }
        if let directory = directory(for: model) { try FileManager.default.removeItem(at: directory) }
        states[model.id] = .notInstalled
    }
}
