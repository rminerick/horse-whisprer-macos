import AudioToolbox
import Foundation
import os

/// Creating the queue prepares the device, but does not start it or collect audio.
/// Unlike a new AVAudioEngine input graph, this avoids negotiating a second
/// Bluetooth audio unit at every trigger. The engine path remains a fallback.
@MainActor
final class AudioQueueCapture: StreamingAudioCapturing {
    private var input: (any QueuedAudioInput)?
    private var preparedRoute: String?
    private var usingFallback = false
    private var generation = 0
    private let makeInput: () throws -> any QueuedAudioInput
    private let route: () -> String?
    private let fallback: any StreamingAudioCapturing

    init(makeInput: @escaping () throws -> any QueuedAudioInput = { try SystemQueuedAudioInput() },
         route: @escaping () -> String? = { AudioRouteDetector.currentInputRoute()?.uid },
         fallback: any StreamingAudioCapturing = StreamingAudioCapture()) {
        self.makeInput = makeInput
        self.route = route
        self.fallback = fallback
    }

    func prepare() throws {
        let currentRoute = route()
        if input != nil, currentRoute == preparedRoute { return }
        input?.stop()
        input = nil
        input = try makeInput()
        preparedRoute = currentRoute
    }

    func start() async throws -> AsyncThrowingStream<DictationAudioChunk, Error> {
        let request = generation
        do {
            try prepare()
            guard let input else { throw NativeASRError.invalidAudio }
            return try await input.start()
        } catch {
            guard request == generation, !Task.isCancelled else { throw CancellationError() }
            input?.stop()
            input = nil
            AudioDiagnostics.shared.log("DictationStartup", "audioQueue unavailable; using engine fallback: \(error.localizedDescription)")
            usingFallback = true
            return try await fallback.start()
        }
    }

    func stop() {
        generation += 1
        input?.stop()
        input = nil
        if usingFallback { fallback.stop() }
        usingFallback = false
    }
}

@MainActor
protocol QueuedAudioInput: AnyObject {
    func start() async throws -> AsyncThrowingStream<DictationAudioChunk, Error>
    func stop()
}

/// Only copied Float samples and the Sendable channel cross the callback boundary.
final class QueuedInputDelivery: Sendable {
    private let channel = OSAllocatedUnfairLock<DictationAudioChannel?>(initialState: nil)
    func begin(_ channel: DictationAudioChannel) { self.channel.withLock { $0 = channel } }
    func finish(error: Error? = nil) {
        channel.withLock { $0?.finish(error: error); $0 = nil }
    }
    func receive(_ samples: [Float]) -> Bool {
        channel.withLock {
            guard let channel = $0 else { return false }
            if !samples.isEmpty { channel.yield(.init(samples: samples, sampleRate: 16_000)) }
            return true
        }
    }
}

@MainActor
final class SystemQueuedAudioInput: QueuedAudioInput {
    /// The buffers are populated before dispatching any operation. Start and
    /// disposal then run on one serial worker, never blocking the UI. This owner
    /// retains callback context until synchronous disposal has joined callbacks.
    private final class Handle: @unchecked Sendable {
        let queue: AudioQueueRef
        let delivery: QueuedInputDelivery
        let operations = QueuedInputOperations()
        var buffers: [AudioQueueBufferRef] = []
        private var disposed = false // Accessed only by the worker, then deinit.
        init(queue: AudioQueueRef, delivery: QueuedInputDelivery) { self.queue = queue; self.delivery = delivery }
        func dispose() {
            guard !disposed else { return }
            delivery.finish()
            AudioQueueDispose(queue, true)
            disposed = true
        }
        deinit { dispose() }
    }
    private var handle: Handle?

    init(deviceUID: String? = nil) throws {
        let delivery = QueuedInputDelivery()
        var format = AudioStreamBasicDescription(mSampleRate: 16_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
            mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var queue: AudioQueueRef?
        try Self.check(AudioQueueNewInput(&format, Self.makeCallback(), Unmanaged.passUnretained(delivery).toOpaque(), nil, nil, 0, &queue))
        guard let queue else { throw NativeASRError.invalidAudio }
        let handle = Handle(queue: queue, delivery: delivery)
        self.handle = handle
        try Self.check(AudioQueueAddPropertyListener(queue, kAudioQueueProperty_IsRunning,
            Self.makeStateCallback(), Unmanaged.passUnretained(delivery).toOpaque()))
        if let deviceUID {
            var uid = deviceUID as CFString
            try Self.check(AudioQueueSetProperty(queue, kAudioQueueProperty_CurrentDevice, &uid, UInt32(MemoryLayout<CFString>.size)))
        }
        for _ in 0..<3 {
            var buffer: AudioQueueBufferRef?
            // 20 ms per callback, with approximately 20 seconds of bounded backlog.
            try Self.check(AudioQueueAllocateBuffer(queue, 320 * 4, &buffer))
            guard let buffer else { throw NativeASRError.invalidAudio }
            handle.buffers.append(buffer)
        }
    }

    func start() async throws -> AsyncThrowingStream<DictationAudioChunk, Error> {
        guard let handle else { throw NativeASRError.invalidAudio }
        let channel = DictationAudioChannel(capacity: 1024)
        handle.delivery.begin(channel)
        do {
            try await handle.operations.start {
                for buffer in handle.buffers { try Self.check(AudioQueueEnqueueBuffer(handle.queue, buffer, 0, nil)) }
                try Self.check(AudioQueueStart(handle.queue, nil))
            }
        } catch { stop(); throw error }
        return channel.stream
    }

    func stop() {
        guard let handle else { return }
        handle.delivery.finish()
        handle.operations.stop { handle.dispose() }
        self.handle = nil
    }

    nonisolated static func makeCallback() -> AudioQueueInputCallback {
        { context, queue, buffer, time, packets, descriptions in
            SystemQueuedAudioInput.receive(context, queue, buffer, time, packets, descriptions)
        }
    }

    private nonisolated static func makeStateCallback() -> AudioQueuePropertyListenerProc {
        { context, queue, _ in
            guard let context else { return }
            var running: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioQueueGetProperty(queue, kAudioQueueProperty_IsRunning, &running, &size)
            if status != noErr || running == 0 {
                Unmanaged<QueuedInputDelivery>.fromOpaque(context).takeUnretainedValue()
                    .finish(error: NativeASRError.invalidAudio)
            }
        }
    }

    private nonisolated static func receive(_ context: UnsafeMutableRawPointer?, _ queue: AudioQueueRef,
        _ buffer: AudioQueueBufferRef, _ time: UnsafePointer<AudioTimeStamp>, _ packets: UInt32,
        _ descriptions: UnsafePointer<AudioStreamPacketDescription>?) {
        guard let context else { return }
        let delivery = Unmanaged<QueuedInputDelivery>.fromOpaque(context).takeUnretainedValue()
        let count = Int(buffer.pointee.mAudioDataByteSize) / MemoryLayout<Float>.size
        let samples = Array(UnsafeBufferPointer(start: buffer.pointee.mAudioData.assumingMemoryBound(to: Float.self), count: count))
        if delivery.receive(samples) {
            let status = AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
            if status != noErr { delivery.finish(error: NSError(domain: NSOSStatusErrorDomain, code: Int(status))) }
        }
    }

    private nonisolated static func check(_ status: OSStatus) throws {
        if status != noErr { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}

/// Serializes hardware work and makes stop invalidate an in-flight start without
/// waiting for a device driver. Disposal runs only after startup has returned.
final class QueuedInputOperations: Sendable {
    private let worker = DispatchQueue(label: "com.horsewhisprer.input", qos: .userInitiated)
    private let stopped = OSAllocatedUnfairLock(initialState: false)

    func start(_ operation: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            worker.async { [self] in
                do {
                    guard !stopped.withLock({ $0 }) else { throw CancellationError() }
                    try operation()
                    guard !stopped.withLock({ $0 }) else { throw CancellationError() }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func stop(_ dispose: @escaping @Sendable () -> Void) {
        stopped.withLock { $0 = true }
        worker.async(execute: dispose)
    }
}
