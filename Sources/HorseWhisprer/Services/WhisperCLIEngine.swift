import Foundation

enum WhisperCLIError: LocalizedError {
    case binaryMissing
    case modelMissing(String)
    case transcriptionFailed(String)
    case noTextProduced

    var errorDescription: String? {
        switch self {
        case .binaryMissing:
            return "Could not find whisper-cli. Horse Whisprer can use a bundled runtime when available, or you can set a custom path in settings."
        case .modelMissing(let path):
            return "Could not find the selected model at \(path)."
        case .transcriptionFailed(let message):
            return message
        case .noTextProduced:
            return "whisper-cli completed but produced no text output."
        }
    }
}

final class WhisperCLIEngine: ASREngine, @unchecked Sendable {
    let id = "whisper-cli"
    let displayName = "whisper.cpp CLI"

    private let settings: AppSettings
    private let outputDirectory: URL
    private let outputFiles = TranscriptionOutputFiles()

    init(settings: AppSettings, outputDirectory: URL = FileManager.default.temporaryDirectory) {
        self.settings = settings
        self.outputDirectory = outputDirectory
    }

    func isConfigured() -> Bool {
        resolvedCLIPath() != nil
    }

    func transcribe(audioURL: URL, model: ASRModelDescriptor, options: TranscriptionOptions) async throws -> TranscriptionResult {
        guard let cliURL = resolvedCLIPath() else {
            throw WhisperCLIError.binaryMissing
        }

        let modelURL = try resolveModelPath(for: model)
        let cliPath = cliURL.path
        let modelPath = modelURL.path
        let audioPath = audioURL.path
        let languageCode = options.languageCode
        let useGPU = options.useGPU

        let sessionDirectory = try outputFiles.create(in: outputDirectory)
        defer { outputFiles.remove(sessionDirectory) }
        let outputPrefix = sessionDirectory.appendingPathComponent("transcript")
        var arguments = [
            "-m", modelPath, "-f", audioPath, "-otxt", "-of", outputPrefix.path,
            "-nt", "-np", "-l", languageCode
        ]
        if !useGPU { arguments.append("-ng") }
        if let prompt = options.vocabularyPrompt, !prompt.isEmpty { arguments += ["--prompt", prompt] }
        let startedAt = Date()
        let result = try await WhisperProcessRunner.run(executableURL: URL(fileURLWithPath: cliPath), arguments: arguments)
        try Task.checkCancellation()
        guard result.status == 0 else {
            throw WhisperCLIError.transcriptionFailed(result.standardError.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let textURL = URL(fileURLWithPath: outputPrefix.path + ".txt")
        guard FileManager.default.fileExists(atPath: textURL.path) else { throw WhisperCLIError.noTextProduced }
        let text = try String(contentsOf: textURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw WhisperCLIError.noTextProduced }
        return TranscriptionResult(text: text, duration: Date().timeIntervalSince(startedAt))
    }

    func prepareForTermination() {
        outputFiles.prepareForTermination()
    }

    func resolvedCLIPath() -> URL? {
        let configured = settings.whisperCLIPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundled = AppPaths.bundledWhisperCLIURL()?.path ?? ""
        let candidates = [
            configured,
            bundled,
            AppPaths.repoRoot.appendingPathComponent("Vendor/whisper.cpp/build/bin/whisper-cli").path,
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli"
        ].filter { !$0.isEmpty }

        return candidates
            .map(URL.init(fileURLWithPath:))
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    }

    func resolvedModelPathIfAvailable(for model: ASRModelDescriptor) -> URL? {
        let configured = settings.modelDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates: [URL]

        if configured.isEmpty {
            candidates = [
                (try? AppPaths.managedWhisperModelsDirectory())?.appendingPathComponent(model.fileName),
                AppPaths.repoRoot.appendingPathComponent("Vendor/whisper.cpp/models").appendingPathComponent(model.fileName)
            ].compactMap { $0 }
        } else {
            candidates = [URL(fileURLWithPath: configured).appendingPathComponent(model.fileName)]
        }

        return candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
    }

    private func resolveModelPath(for model: ASRModelDescriptor) throws -> URL {
        guard let modelURL = resolvedModelPathIfAvailable(for: model) else {
            let configured = settings.modelDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
            let missingPath: String

            if configured.isEmpty {
                let managedPath = (try? AppPaths.managedWhisperModelsDirectory().appendingPathComponent(model.fileName).path) ?? model.fileName
                missingPath = managedPath
            } else {
                missingPath = URL(fileURLWithPath: configured).appendingPathComponent(model.fileName).path
            }

            throw WhisperCLIError.modelMissing(missingPath)
        }

        return modelURL
    }
}
