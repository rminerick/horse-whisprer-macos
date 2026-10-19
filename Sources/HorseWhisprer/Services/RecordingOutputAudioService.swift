import AudioToolbox
import CoreAudio
import Foundation
import OSLog

struct OutputAudioRestorationState: Equatable {
    let deviceID: AudioDeviceID
    let originalMute: Bool?
    let originalVolume: Float32?
    let restoreMute: Bool
    let restoreVolume: Bool
}

@MainActor
protocol OutputAudioDeviceControlling {
    func applyBehavior(_ behavior: DictationOutputAudioBehavior) -> OutputAudioRestorationState?
    func restore(_ restorationState: OutputAudioRestorationState)
}

@MainActor
protocol RecordingOutputAudioManaging {
    func beginRecordingSession(afterDelayNanoseconds delay: UInt64)
    func endRecordingSession()
}

@MainActor
final class RecordingOutputAudioService: RecordingOutputAudioManaging {
    private let settings: AppSettings
    private let deviceController: OutputAudioDeviceControlling
    private let inputRouteProvider: @MainActor () -> CuePlaybackRoute?
    private let outputRouteProvider: @MainActor () -> CuePlaybackRoute?
    private let sleep: @MainActor (UInt64) async -> Void
    private let logger = Logger(subsystem: "com.rminerick.HorseWhisprer", category: "RecordingOutputAudio")
    private let diagnostics = AudioDiagnostics.shared

    private var pendingApplyTask: Task<Void, Never>?
    private var restorationState: OutputAudioRestorationState?
    private var sessionGeneration: UInt64 = 0

    init(
        settings: AppSettings,
        deviceController: OutputAudioDeviceControlling = SystemOutputAudioDeviceController(),
        inputRouteProvider: @escaping @MainActor () -> CuePlaybackRoute? = AudioRouteDetector.currentInputRoute,
        outputRouteProvider: @escaping @MainActor () -> CuePlaybackRoute? = AudioRouteDetector.currentOutputRoute,
        sleep: @escaping @MainActor (UInt64) async -> Void = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.settings = settings
        self.deviceController = deviceController
        self.inputRouteProvider = inputRouteProvider
        self.outputRouteProvider = outputRouteProvider
        self.sleep = sleep
    }

    func beginRecordingSession(afterDelayNanoseconds delay: UInt64) {
        sessionGeneration &+= 1
        let generation = sessionGeneration

        pendingApplyTask?.cancel()
        pendingApplyTask = nil
        restoreIfNeeded()

        guard settings.dictationOutputAudioBehavior != .off else {
            return
        }

        guard delay > 0 else {
            applyCurrentBehavior()
            return
        }

        pendingApplyTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            await self.sleep(delay)
            guard !Task.isCancelled, self.sessionGeneration == generation else {
                return
            }

            self.pendingApplyTask = nil
            self.applyCurrentBehavior()
        }
    }

    func endRecordingSession() {
        sessionGeneration &+= 1
        pendingApplyTask?.cancel()
        pendingApplyTask = nil
        restoreIfNeeded()
    }

    private func applyCurrentBehavior() {
        guard restorationState == nil else {
            return
        }

        let behavior = settings.dictationOutputAudioBehavior
        let inputRoute = inputRouteProvider()
        let outputRoute = outputRouteProvider()

        if let skipReason = skipReasonForCurrentRoutes(
            behavior: behavior,
            inputRoute: inputRoute,
            outputRoute: outputRoute
        ) {
            logger.debug("skipping output audio behavior reason=\(skipReason, privacy: .public)")
            diagnostics.log(
                "RecordingOutputAudio",
                "skip behavior=\(behavior.rawValue) reason=\(skipReason) inputRoute=\(describe(route: inputRoute)) outputRoute=\(describe(route: outputRoute))"
            )
            return
        }

        diagnostics.log(
            "RecordingOutputAudio",
            "apply requested behavior=\(behavior.rawValue) inputRoute=\(describe(route: inputRoute)) outputRoute=\(describe(route: outputRoute))"
        )

        restorationState = deviceController.applyBehavior(behavior)
        if let restorationState {
            diagnostics.log(
                "RecordingOutputAudio",
                "apply succeeded behavior=\(behavior.rawValue) deviceID=\(restorationState.deviceID) originalMute=\(describe(restorationState.originalMute)) originalVolume=\(describe(restorationState.originalVolume)) restoreMute=\(restorationState.restoreMute) restoreVolume=\(restorationState.restoreVolume)"
            )
        } else {
            logger.debug("output audio behavior produced no device change")
            diagnostics.log(
                "RecordingOutputAudio",
                "apply produced no device change behavior=\(behavior.rawValue) inputRoute=\(describe(route: inputRoute)) outputRoute=\(describe(route: outputRoute))"
            )
        }
    }

    private func restoreIfNeeded() {
        guard let restorationState else {
            return
        }

        diagnostics.log(
            "RecordingOutputAudio",
            "restore requested deviceID=\(restorationState.deviceID) originalMute=\(describe(restorationState.originalMute)) originalVolume=\(describe(restorationState.originalVolume)) restoreMute=\(restorationState.restoreMute) restoreVolume=\(restorationState.restoreVolume)"
        )
        deviceController.restore(restorationState)
        self.restorationState = nil
    }

    private func skipReasonForCurrentRoutes(
        behavior: DictationOutputAudioBehavior,
        inputRoute: CuePlaybackRoute?,
        outputRoute: CuePlaybackRoute?
    ) -> String? {
        guard behavior == .mute,
              let inputRoute,
              let outputRoute else {
            return nil
        }

        if inputRoute.uid == outputRoute.uid {
            return "shared-route"
        }

        if isBluetooth(inputRoute) && isBluetooth(outputRoute) {
            return "bluetooth-input-output-pair"
        }

        return nil
    }

    private func isBluetooth(_ route: CuePlaybackRoute) -> Bool {
        route.transportType == kAudioDeviceTransportTypeBluetooth ||
        route.transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    private func describe(route: CuePlaybackRoute?) -> String {
        guard let route else {
            return "nil"
        }

        return "\(route.uid)|\(route.transportDescription)"
    }

    private func describe(_ value: Float32?) -> String {
        guard let value else {
            return "nil"
        }

        return String(format: "%.4f", Double(value))
    }

    private func describe(_ value: Bool?) -> String {
        guard let value else {
            return "nil"
        }

        return value ? "true" : "false"
    }
}

@MainActor
final class SystemOutputAudioDeviceController: OutputAudioDeviceControlling {
    private let maximumDuckedVolume: Float32
    private let duckVolumeScale: Float32
    private let logger = Logger(subsystem: "com.rminerick.HorseWhisprer", category: "RecordingOutputAudio")
    private let diagnostics = AudioDiagnostics.shared

    init(maximumDuckedVolume: Float32 = 0.03, duckVolumeScale: Float32 = 0.08) {
        self.maximumDuckedVolume = maximumDuckedVolume
        self.duckVolumeScale = duckVolumeScale
    }

    func applyBehavior(_ behavior: DictationOutputAudioBehavior) -> OutputAudioRestorationState? {
        guard let deviceID = Self.defaultOutputDeviceID() else {
            logger.error("default output device unavailable")
            diagnostics.log("RecordingOutputAudio", "default output device unavailable behavior=\(behavior.rawValue)")
            return nil
        }

        let originalMute = Self.readMute(deviceID: deviceID)
        let originalVolume = Self.readVolume(deviceID: deviceID)
        diagnostics.log(
            "RecordingOutputAudio",
            "device state behavior=\(behavior.rawValue) deviceID=\(deviceID) originalMute=\(Self.describe(originalMute)) originalVolume=\(Self.describe(originalVolume))"
        )

        switch behavior {
        case .off:
            return nil
        case .duck:
            guard let originalVolume else {
                diagnostics.log(
                    "RecordingOutputAudio",
                    "duck skipped reason=missing-original-volume deviceID=\(deviceID)"
                )
                return nil
            }

            let duckedVolume = Self.duckedVolumeTarget(
                for: originalVolume,
                maximumVolume: maximumDuckedVolume,
                scale: duckVolumeScale
            )

            guard originalVolume > duckedVolume else {
                diagnostics.log(
                    "RecordingOutputAudio",
                    "duck skipped reason=already-at-or-below-target deviceID=\(deviceID) originalVolume=\(Self.describe(originalVolume)) targetVolume=\(Self.describe(duckedVolume))"
                )
                return nil
            }

            guard Self.writeVolume(duckedVolume, deviceID: deviceID) else {
                logger.error("failed to duck output device volume")
                diagnostics.log(
                    "RecordingOutputAudio",
                    "duck write failed deviceID=\(deviceID) targetVolume=\(Self.describe(duckedVolume))"
                )
                return nil
            }

            let readBackVolume = Self.readVolume(deviceID: deviceID)
            diagnostics.log(
                "RecordingOutputAudio",
                "duck write succeeded deviceID=\(deviceID) targetVolume=\(Self.describe(duckedVolume)) readBackVolume=\(Self.describe(readBackVolume))"
            )

            return OutputAudioRestorationState(
                deviceID: deviceID,
                originalMute: originalMute,
                originalVolume: originalVolume,
                restoreMute: false,
                restoreVolume: true
            )
        case .mute:
            if let originalMute, originalMute == false, Self.writeMute(true, deviceID: deviceID) {
                let readBackMute = Self.readMute(deviceID: deviceID)
                diagnostics.log(
                    "RecordingOutputAudio",
                    "mute write succeeded deviceID=\(deviceID) via=mute-property readBackMute=\(Self.describe(readBackMute))"
                )
                return OutputAudioRestorationState(
                    deviceID: deviceID,
                    originalMute: originalMute,
                    originalVolume: originalVolume,
                    restoreMute: true,
                    restoreVolume: false
                )
            }

            guard let originalVolume, originalVolume > 0 else {
                diagnostics.log(
                    "RecordingOutputAudio",
                    "mute skipped reason=missing-or-zero-volume deviceID=\(deviceID) originalVolume=\(Self.describe(originalVolume))"
                )
                return nil
            }

            guard Self.writeVolume(0, deviceID: deviceID) else {
                logger.error("failed to mute output device volume")
                diagnostics.log(
                    "RecordingOutputAudio",
                    "mute volume write failed deviceID=\(deviceID)"
                )
                return nil
            }

            let readBackVolume = Self.readVolume(deviceID: deviceID)
            diagnostics.log(
                "RecordingOutputAudio",
                "mute volume write succeeded deviceID=\(deviceID) readBackVolume=\(Self.describe(readBackVolume))"
            )

            return OutputAudioRestorationState(
                deviceID: deviceID,
                originalMute: originalMute,
                originalVolume: originalVolume,
                restoreMute: false,
                restoreVolume: true
            )
        }
    }

    static func duckedVolumeTarget(
        for originalVolume: Float32,
        maximumVolume: Float32 = 0.03,
        scale: Float32 = 0.08
    ) -> Float32 {
        let clampedOriginalVolume = min(max(originalVolume, 0), 1)
        let scaledVolume = clampedOriginalVolume * min(max(scale, 0), 1)
        return min(min(maximumVolume, 1), max(scaledVolume, 0))
    }

    func restore(_ restorationState: OutputAudioRestorationState) {
        if restorationState.restoreVolume, let originalVolume = restorationState.originalVolume {
            let didRestoreVolume = Self.writeVolume(originalVolume, deviceID: restorationState.deviceID)
            let readBackVolume = Self.readVolume(deviceID: restorationState.deviceID)
            diagnostics.log(
                "RecordingOutputAudio",
                "restore volume deviceID=\(restorationState.deviceID) success=\(didRestoreVolume) targetVolume=\(Self.describe(originalVolume)) readBackVolume=\(Self.describe(readBackVolume))"
            )
        }

        if restorationState.restoreMute, let originalMute = restorationState.originalMute {
            let didRestoreMute = Self.writeMute(originalMute, deviceID: restorationState.deviceID)
            let readBackMute = Self.readMute(deviceID: restorationState.deviceID)
            diagnostics.log(
                "RecordingOutputAudio",
                "restore mute deviceID=\(restorationState.deviceID) success=\(didRestoreMute) targetMute=\(Self.describe(originalMute)) readBackMute=\(Self.describe(readBackMute))"
            )
        }
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
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

    private static func readMute(deviceID: AudioDeviceID) -> Bool? {
        readUInt32Property(
            selector: kAudioDevicePropertyMute,
            scope: kAudioDevicePropertyScopeOutput,
            deviceID: deviceID
        ).map { $0 != 0 }
    }

    private static func writeMute(_ value: Bool, deviceID: AudioDeviceID) -> Bool {
        writeUInt32Property(
            value ? 1 : 0,
            selector: kAudioDevicePropertyMute,
            scope: kAudioDevicePropertyScopeOutput,
            deviceID: deviceID
        )
    }

    private static func readVolume(deviceID: AudioDeviceID) -> Float32? {
        readFloat32Property(
            selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            scope: kAudioDevicePropertyScopeOutput,
            deviceID: deviceID
        )
    }

    private static func writeVolume(_ value: Float32, deviceID: AudioDeviceID) -> Bool {
        writeFloat32Property(
            min(max(value, 0), 1),
            selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            scope: kAudioDevicePropertyScopeOutput,
            deviceID: deviceID
        )
    }

    private static func readUInt32Property(
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        deviceID: AudioDeviceID
    ) -> UInt32? {
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(deviceID, &address) else {
            return nil
        }

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard status == noErr else {
            return nil
        }

        return value
    }

    private static func writeUInt32Property(
        _ value: UInt32,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        deviceID: AudioDeviceID
    ) -> Bool {
        var mutableValue = value
        let size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(deviceID, &address) else {
            return false
        }

        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &mutableValue)
        return status == noErr
    }

    private static func readFloat32Property(
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        deviceID: AudioDeviceID
    ) -> Float32? {
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(deviceID, &address) else {
            return nil
        }

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard status == noErr else {
            return nil
        }

        return value
    }

    private static func writeFloat32Property(
        _ value: Float32,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        deviceID: AudioDeviceID
    ) -> Bool {
        var mutableValue = value
        let size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(deviceID, &address) else {
            return false
        }

        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &mutableValue)
        return status == noErr
    }

    private static func describe(_ value: Float32?) -> String {
        guard let value else {
            return "nil"
        }

        return String(format: "%.4f", Double(value))
    }

    private static func describe(_ value: Bool?) -> String {
        guard let value else {
            return "nil"
        }

        return value ? "true" : "false"
    }
}
