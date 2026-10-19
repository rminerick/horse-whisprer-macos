import XCTest
@testable import HorseWhisprer

final class WhisperCLIEngineTests: XCTestCase {
    func testLargeStdoutAndStderrDoNotBlockProcessExit() async throws {
        let result = try await WhisperProcessRunner.run(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "i=0; while [ $i -lt 20000 ]; do printf 'stdout line abcdefghijklmnopqrstuvwxyz\\n'; printf 'stderr line abcdefghijklmnopqrstuvwxyz\\n' >&2; i=$((i+1)); done"])
        XCTAssertEqual(result.status, 0)
        XCTAssertLessThanOrEqual(result.standardError.utf8.count, 64 * 1024)
        XCTAssertTrue(result.standardError.contains("stderr line"))
    }

    func testFailurePreservesExitStatusAndDiagnostic() async throws {
        let result = try await WhisperProcessRunner.run(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf 'model load failed' >&2; exit 23"])
        XCTAssertEqual(result.status, 23)
        XCTAssertEqual(result.standardError, "model load failed")
    }

    func testCancellationStopsChildThatIgnoresTermination() async throws {
        let directory = try temporaryDirectory()
        let marker = directory.appendingPathComponent("started")
        let task = Task {
            try await WhisperProcessRunner.run(executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; printf '%s' $$ > \"$1\"; while :; do :; done", "fixture", marker.path])
        }
        defer { task.cancel() }
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: marker.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        let pid = try XCTUnwrap(Int32(String(contentsOf: marker, encoding: .utf8)))
        XCTAssertEqual(kill(pid, 0), -1, "The child should have been reaped")
    }

    func testAlreadyCancelledTaskDoesNotLaunchChild() async throws {
        let directory = try temporaryDirectory()
        let marker = directory.appendingPathComponent("unexpected-launch")
        let gate = TestGate()
        let task = Task {
            await gate.wait()
            return try await WhisperProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/touch"), arguments: [marker.path])
        }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.open()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testMissingExecutableThrowsInsteadOfHanging() async {
        do {
            _ = try await WhisperProcessRunner.run(executableURL: URL(fileURLWithPath: "/no-such-whisper-cli"), arguments: [])
            XCTFail("Expected launch failure")
        } catch { }
    }

    @MainActor
    func testEngineReadsTranscriptDespiteLargeCLIOutput() async throws {
        let directory = try temporaryDirectory()
        let script = directory.appendingPathComponent("whisper-cli")
        let source = """
        #!/bin/sh
        while [ "$#" -gt 0 ]; do
            if [ "$1" = '-of' ]; then shift; output="$1"; fi
            shift
        done
        i=0
        while [ $i -lt 10000 ]; do
            printf 'long stdout line abcdefghijklmnopqrstuvwxyz\\n'
            printf 'long stderr line abcdefghijklmnopqrstuvwxyz\\n' >&2
            i=$((i+1))
        done
        printf 'regression transcript\\n' > "$output.txt"
        """
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let settings = makeTestSettings()
        settings.whisperCLIPath = script.path
        settings.modelDirectoryPath = directory.path
        let model = ModelCatalogService().defaultModel
        try Data().write(to: directory.appendingPathComponent(model.fileName))
        let outputs = directory.appendingPathComponent("outputs")
        let result = try await WhisperCLIEngine(settings: settings, outputDirectory: outputs).transcribe(audioURL: directory.appendingPathComponent("audio.wav"), model: model, options: TranscriptionOptions(languageCode: "en", suppressTimestamps: true, useGPU: false))
        XCTAssertEqual(result.text, "regression transcript")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outputs.path), [])
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WhisperCLIEngineTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
