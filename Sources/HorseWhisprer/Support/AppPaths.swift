import Foundation

enum AppPaths {
    static let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

    static func applicationSupportDirectory() throws -> URL {
        let url = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("HorseWhisprer", isDirectory: true)

        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func managedWhisperModelsDirectory() throws -> URL {
        let url = try applicationSupportDirectory()
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("Whisper", isDirectory: true)

        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func managedDownloadsDirectory() throws -> URL {
        let url = try applicationSupportDirectory()
            .appendingPathComponent("Downloads", isDirectory: true)

        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func installedModelsManifestURL() throws -> URL {
        try applicationSupportDirectory().appendingPathComponent("installed-models.json")
    }

    static func bundledWhisperCLIURL() -> URL? {
        Bundle.main.resourceURL?.appendingPathComponent("whisper-cli")
    }

    static func recordingsDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HorseWhisprerRecordings", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func newRecordingURL() throws -> URL {
        let filename = "recording-\(UUID().uuidString).wav"
        return try recordingsDirectory().appendingPathComponent(filename)
    }
}
