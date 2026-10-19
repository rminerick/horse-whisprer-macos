import XCTest
import os
@testable import HorseWhisprer

@MainActor
final class AudioQueueCaptureTests: XCTestCase {
    func testPreparationDoesNotStartRecordingAndIsReusedAtTrigger() async throws {
        let input = TestQueuedInput()
        var creations = 0
        let capture = AudioQueueCapture(makeInput: { creations += 1; return input }, route: { "one" })
        try capture.prepare()
        try capture.prepare()
        XCTAssertEqual(creations, 1)
        XCTAssertEqual(input.starts, 0)
        _ = try await capture.start()
        XCTAssertEqual(creations, 1)
        XCTAssertEqual(input.starts, 1)
        capture.stop()
        XCTAssertEqual(input.stops, 1)
    }

    func testRouteChangeDiscardsPreparedInputBeforeStarting() async throws {
        var route = "one"
        var inputs: [TestQueuedInput] = []
        let capture = AudioQueueCapture(makeInput: {
            let input = TestQueuedInput(); inputs.append(input); return input
        }, route: { route })
        try capture.prepare()
        route = "two"
        _ = try await capture.start()
        XCTAssertEqual(inputs.count, 2)
        XCTAssertEqual(inputs[0].starts, 0)
        XCTAssertEqual(inputs[0].stops, 1)
        XCTAssertEqual(inputs[1].starts, 1)
        capture.stop()
    }

    func testStartFailureClosesQueueAndFallsBackToEngine() async throws {
        let input = TestQueuedInput()
        input.failStart = true
        let fallback = TestFallbackCapture()
        let capture = AudioQueueCapture(makeInput: { input }, route: { "one" }, fallback: fallback)
        _ = try await capture.start()
        XCTAssertEqual(input.stops, 1)
        XCTAssertEqual(fallback.starts, 1)
        capture.stop()
        XCTAssertEqual(fallback.stops, 1)
    }

    func testQueueCreationFailureUsesFallback() async throws {
        let fallback = TestFallbackCapture()
        let capture = AudioQueueCapture(makeInput: { throw NativeASRError.invalidAudio }, fallback: fallback)
        _ = try await capture.start()
        XCTAssertEqual(fallback.starts, 1)
        capture.stop()
    }

    func testStopDuringPendingStartDoesNotLaunchFallback() async throws {
        let entered = expectation(description: "start suspended")
        let input = SuspendedQueuedInput(entered: entered)
        let fallback = TestFallbackCapture()
        let capture = AudioQueueCapture(makeInput: { input }, fallback: fallback)
        let start = Task { try await capture.start() }
        await fulfillment(of: [entered], timeout: 1)
        capture.stop()
        do { _ = try await start.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        XCTAssertEqual(fallback.starts, 0)
    }

    func testSlowDeviceStartDoesNotBlockMainActorAndStopWaitsOnlyOnWorker() async throws {
        let operations = QueuedInputOperations()
        let entered = expectation(description: "hardware start entered")
        let disposed = expectation(description: "hardware disposed")
        let release = DispatchSemaphore(value: 0)
        let order = OSAllocatedUnfairLock(initialState: [String]())
        let start = Task { @MainActor in
            try await operations.start {
                order.withLock { $0.append("start") }
                entered.fulfill()
                _ = release.wait(timeout: .now() + 3)
                order.withLock { $0.append("returned") }
            }
        }
        await fulfillment(of: [entered], timeout: 1)
        // This MainActor continuation must execute while the device is blocked.
        XCTAssertEqual(order.withLock { $0 }, ["start"])
        operations.stop {
            order.withLock { $0.append("dispose") }
            disposed.fulfill()
        }
        release.signal()
        do { try await start.value; XCTFail("Stopped startup must not succeed") }
        catch is CancellationError { }
        await fulfillment(of: [disposed], timeout: 1)
        XCTAssertEqual(order.withLock { $0 }, ["start", "returned", "dispose"])
    }

    func testStopBeforeWorkerStartsSkipsHardwareStart() async throws {
        let operations = QueuedInputOperations()
        operations.stop { }
        do {
            try await operations.start { XCTFail("Stopped input must not start") }
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
    }

    func testStopFinishesStreamAndLateSamplesCannotEnterNextSession() async throws {
        let delivery = QueuedInputDelivery()
        let first = DictationAudioChannel()
        delivery.begin(first)
        let accepted = await Task.detached { delivery.receive([0.2, -0.3, 0.4]) }.value
        XCTAssertTrue(accepted)
        delivery.finish()
        XCTAssertFalse(delivery.receive([99]))
        var firstSamples: [Float] = []
        for try await chunk in first.stream { firstSamples += chunk.samples; XCTAssertEqual(chunk.sampleRate, 16_000) }
        XCTAssertEqual(firstSamples, [0.2, -0.3, 0.4])
        let second = DictationAudioChannel()
        delivery.begin(second)
        XCTAssertTrue(delivery.receive([0.5]))
        delivery.finish()
        var secondSamples: [Float] = []
        for try await chunk in second.stream { secondSamples += chunk.samples }
        XCTAssertEqual(secondSamples, [0.5])
    }
}

@MainActor private final class TestQueuedInput: QueuedAudioInput {
    var starts = 0
    var stops = 0
    var failStart = false
    let channel = DictationAudioChannel()
    func start() throws -> AsyncThrowingStream<DictationAudioChunk, Error> {
        starts += 1
        if failStart { throw NativeASRError.invalidAudio }
        return channel.stream
    }
    func stop() { stops += 1; channel.finish() }
}

@MainActor private final class TestFallbackCapture: StreamingAudioCapturing {
    var starts = 0
    var stops = 0
    func start() throws -> AsyncThrowingStream<DictationAudioChunk, Error> {
        starts += 1
        return DictationAudioChannel().stream
    }
    func stop() { stops += 1 }
}

@MainActor private final class SuspendedQueuedInput: QueuedAudioInput {
    let entered: XCTestExpectation
    var continuation: CheckedContinuation<AsyncThrowingStream<DictationAudioChunk, Error>, Error>?
    init(entered: XCTestExpectation) { self.entered = entered }
    func start() async throws -> AsyncThrowingStream<DictationAudioChunk, Error> {
        try await withCheckedThrowingContinuation {
            continuation = $0
            entered.fulfill()
        }
    }
    func stop() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}
