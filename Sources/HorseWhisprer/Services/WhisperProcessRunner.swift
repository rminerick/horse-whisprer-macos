import Darwin
import Foundation

struct WhisperProcessResult: Sendable {
    let status: Int32
    let standardError: String
}

// Each invocation owns one child. The lock protects launch/cancel/exit ownership;
// all blocking process and pipe work runs on a GCD worker, never a Swift executor.
final class WhisperProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private static let diagnosticLimit = 64 * 1024

    static func run(executableURL: URL, arguments: [String]) async throws -> WhisperProcessResult {
        let runner = WhisperProcessRunner()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try runner.execute(executableURL: executableURL, arguments: arguments) })
                }
            }
        } onCancel: {
            runner.cancel()
        }
    }

    private func execute(executableURL: URL, arguments: [String]) throws -> WhisperProcessResult {
        let child = Process()
        child.executableURL = executableURL
        child.arguments = arguments
        let stderr = Pipe()
        child.standardError = stderr
        // Transcription is written to the requested .txt file; stdout is unused.
        child.standardOutput = FileHandle.nullDevice
        defer {
            try? stderr.fileHandleForReading.close()
            try? stderr.fileHandleForWriting.close()
        }
        try lock.withLock {
            if cancelled { throw CancellationError() }
            try child.run()
            process = child
        }
        // Close our copy so EOF reflects the child closing its writer.
        try? stderr.fileHandleForWriting.close()
        var diagnostic = Data()
        do {
            while let chunk = try stderr.fileHandleForReading.read(upToCount: 16 * 1024), !chunk.isEmpty {
                diagnostic.append(chunk)
                if diagnostic.count > Self.diagnosticLimit {
                    diagnostic.removeFirst(diagnostic.count - Self.diagnosticLimit)
                }
            }
        } catch {
            cancel()
            child.waitUntilExit()
            lock.withLock { process = nil }
            throw error
        }
        child.waitUntilExit()
        return try lock.withLock {
            process = nil
            if cancelled { throw CancellationError() }
            return WhisperProcessResult(status: child.terminationStatus,
                                        standardError: String(decoding: diagnostic, as: UTF8.self))
        }
    }

    private func cancel() {
        lock.withLock {
            cancelled = true
            guard let process, process.isRunning else { return }
            process.terminate()
        }
        // A custom CLI may ignore SIGTERM. Retain the runner until the child is
        // reaped and check its Process object before using its PID again.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [self] in
            lock.withLock {
                if let process, process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }
    }
}
