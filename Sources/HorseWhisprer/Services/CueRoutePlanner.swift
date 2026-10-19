import CoreAudio
import Foundation

enum CueKind: Equatable {
    case start
    case streamingStart
    case stop
    case preview
}

struct CuePlaybackRoute {
    let uid: String
    let transportType: UInt32
    var sampleRate: Double = 0
    var channelCount: UInt32 = 0

    var playbackSignature: String { "\(uid)|\(transportType)|\(sampleRate)|\(channelCount)" }

    var isBluetooth: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth || transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    var transportDescription: String {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:
            return "built-in"
        case kAudioDeviceTransportTypeBluetooth:
            return "bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE:
            return "bluetooth-le"
        case kAudioDeviceTransportTypeUSB:
            return "usb"
        case kAudioDeviceTransportTypeAggregate:
            return "aggregate"
        case kAudioDeviceTransportTypeVirtual:
            return "virtual"
        default:
            return "other-\(transportType)"
        }
    }
}

struct CuePlaybackPlan {
    let route: CuePlaybackRoute?
    let isWarm: Bool
    let leadingSilence: TimeInterval
    let outputKeepAlive: TimeInterval
}

@MainActor
protocol CueRoutePlanning {
    func playbackPlan(for cueKind: CueKind) async -> CuePlaybackPlan
    func notePlaybackScheduled(using plan: CuePlaybackPlan)
}

@MainActor
final class CueRoutePlanner: CueRoutePlanning {
    private var warmUntilByRouteUID: [String: Date] = [:]

    private let routeProvider: @MainActor () -> CuePlaybackRoute?
    private let now: @MainActor () -> Date
    private let bluetoothColdLeadIn: TimeInterval
    private let bluetoothKeepAlive: TimeInterval
    private let routeSettleTimeout: TimeInterval
    private let routeSettlePollInterval: TimeInterval
    private let sleep: @MainActor (UInt64) async -> Void

    init(
        routeProvider: @escaping @MainActor () -> CuePlaybackRoute? = AudioRouteDetector.currentOutputRoute,
        now: @escaping @MainActor () -> Date = Date.init,
        bluetoothColdLeadIn: TimeInterval = 0.8,
        bluetoothKeepAlive: TimeInterval = 45,
        routeSettleTimeout: TimeInterval = 1.2,
        routeSettlePollInterval: TimeInterval = 0.05,
        sleep: @escaping @MainActor (UInt64) async -> Void = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.routeProvider = routeProvider
        self.now = now
        self.bluetoothColdLeadIn = bluetoothColdLeadIn
        self.bluetoothKeepAlive = bluetoothKeepAlive
        self.routeSettleTimeout = routeSettleTimeout
        self.routeSettlePollInterval = routeSettlePollInterval
        self.sleep = sleep
    }

    func playbackPlan(for cueKind: CueKind) async -> CuePlaybackPlan {
        let initialPlan = currentPlan(for: cueKind)
        if cueKind == .streamingStart, let route = initialPlan.route, isBluetooth(route) {
            // Bluetooth can change profiles after the microphone starts. Starting
            // the cue inside that transition truncates its waveform. This runs in
            // the independent feedback task; capture is already collecting audio.
            await sleep(300_000_000)
        } else if shouldWaitForBluetoothRouteSettle(for: cueKind, plan: initialPlan) {
            await waitForBluetoothRouteToSettle()
        }

        return currentPlan(for: cueKind)
    }

    func notePlaybackScheduled(using plan: CuePlaybackPlan) {
        guard let route = plan.route, plan.outputKeepAlive > 0 else {
            return
        }

        warmUntilByRouteUID[route.uid] = now().addingTimeInterval(plan.outputKeepAlive)
    }

    private func currentPlan(for cueKind: CueKind) -> CuePlaybackPlan {
        let route = routeProvider()
        let currentDate = now()

        guard let route else {
            return CuePlaybackPlan(route: nil, isWarm: false, leadingSilence: 0, outputKeepAlive: 0)
        }

        let warmUntil = warmUntilByRouteUID[route.uid]
        let isWarm = warmUntil.map { $0 > currentDate } ?? false

        if isBluetooth(route) {
            let leadingSilence: TimeInterval
            switch cueKind {
            case .start, .preview, .stop, .streamingStart:
                // Bluetooth output can still churn even when we recently played a cue.
                // Always gating the next startup/preview cue behind a short preroll is
                // more reliable than trusting a time-based "warm" heuristic.
                leadingSilence = bluetoothColdLeadIn
            }

            return CuePlaybackPlan(
                route: route,
                isWarm: isWarm,
                leadingSilence: leadingSilence,
                outputKeepAlive: cueKind == .streamingStart ? 0 : bluetoothKeepAlive
            )
        }

        return CuePlaybackPlan(route: route, isWarm: false, leadingSilence: 0, outputKeepAlive: 0)
    }

    private func shouldWaitForBluetoothRouteSettle(for cueKind: CueKind, plan: CuePlaybackPlan) -> Bool {
        guard cueKind == .start || cueKind == .preview,
              let route = plan.route,
              isBluetooth(route) else {
            return false
        }

        return !plan.isWarm
    }

    private func waitForBluetoothRouteToSettle() async {
        guard let initialRoute = routeProvider(), isBluetooth(initialRoute) else {
            return
        }

        let deadline = now().addingTimeInterval(routeSettleTimeout)
        var lastSignature = routeSignature(for: initialRoute)
        var consecutiveMatches = 0

        while now() < deadline {
            let sleepNanoseconds = UInt64((routeSettlePollInterval * 1_000_000_000).rounded())
            await sleep(sleepNanoseconds)

            guard let currentRoute = routeProvider(), isBluetooth(currentRoute) else {
                return
            }

            let currentSignature = routeSignature(for: currentRoute)
            if currentSignature == lastSignature {
                consecutiveMatches += 1
                if consecutiveMatches >= 2 {
                    return
                }
            } else {
                lastSignature = currentSignature
                consecutiveMatches = 0
            }
        }
    }

    private func isBluetooth(_ route: CuePlaybackRoute) -> Bool {
        route.transportType == kAudioDeviceTransportTypeBluetooth ||
        route.transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    private func routeSignature(for route: CuePlaybackRoute) -> String {
        route.playbackSignature
    }
}

enum AudioRouteDetector {
    @MainActor
    static func currentOutputRoute() -> CuePlaybackRoute? {
        route(for: kAudioHardwarePropertyDefaultOutputDevice)
    }

    @MainActor
    static func currentInputRoute() -> CuePlaybackRoute? {
        route(for: kAudioHardwarePropertyDefaultInputDevice)
    }

    private static func transportType(for deviceID: AudioDeviceID) -> UInt32? {
        var transportType = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transportType)
        guard status == noErr else {
            return nil
        }

        return transportType
    }

    private static func deviceUID(for deviceID: AudioDeviceID) -> String? {
        var uid: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = withUnsafeMutablePointer(to: &uid) { uidPointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, uidPointer)
        }
        guard status == noErr else {
            return nil
        }

        return uid as String?
    }

    private static func route(for selector: AudioObjectPropertySelector) -> CuePlaybackRoute? {
        guard let deviceID = defaultDeviceID(for: selector),
              let transportType = transportType(for: deviceID),
              let deviceUID = deviceUID(for: deviceID) else {
            return nil
        }

        var rate: Float64 = 0
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        var rateAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectGetPropertyData(deviceID, &rateAddress, 0, nil, &rateSize, &rate)
        var channels: UInt32 = 0
        var streamAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: selector == kAudioHardwarePropertyDefaultInputDevice ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var streamSize: UInt32 = 0
        if AudioObjectGetPropertyDataSize(deviceID, &streamAddress, 0, nil, &streamSize) == noErr,
           streamSize >= MemoryLayout<AudioBufferList>.size {
            let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(streamSize), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { storage.deallocate() }
            if AudioObjectGetPropertyData(deviceID, &streamAddress, 0, nil, &streamSize, storage) == noErr {
                channels = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
                    .reduce(0) { $0 + $1.mNumberChannels }
            }
        }
        return CuePlaybackRoute(uid: deviceUID, transportType: transportType, sampleRate: rate, channelCount: channels)
    }

    private static func defaultDeviceID(for selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )

        guard status == noErr, deviceID != 0 else {
            return nil
        }

        return deviceID
    }
}
