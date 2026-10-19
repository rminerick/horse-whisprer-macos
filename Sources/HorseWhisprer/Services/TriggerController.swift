import ApplicationServices
import Carbon
import Foundation

enum TriggerRegistrationResult: Equatable {
    case registered
    case requiresInputMonitoring
    case failed(String)
}

enum SpecialKeyMonitorEvent: Equatable {
    case flagsChanged(keyCode: UInt16, flags: CGEventFlags)
    case keyDown(keyCode: UInt16)
    case keyUp(keyCode: UInt16)
}

struct SpecialKeyTriggerDetector {
    private let now: () -> TimeInterval
    private var activeModifierKeys = Set<UInt16>()
    private var trackedModifierIsDown = false
    private var trackedModifierUsedWithOtherKey = false
    private var lastCompletedSoloTapAt: TimeInterval?

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    mutating func reset() {
        activeModifierKeys.removeAll()
        trackedModifierIsDown = false
        trackedModifierUsedWithOtherKey = false
        lastCompletedSoloTapAt = nil
    }

    mutating func process(_ event: SpecialKeyMonitorEvent, trigger: SpecialKeyTrigger) -> Bool {
        switch event {
        case .flagsChanged(let keyCode, let flags):
            let previousActiveModifierKeys = activeModifierKeys
            activeModifierKeys = Self.activeModifierKeys(from: flags)

            let wasActive = previousActiveModifierKeys.contains(keyCode)
            let isActive = activeModifierKeys.contains(keyCode)

            guard wasActive != isActive else {
                if trackedModifierIsDown,
                   activeModifierKeys.contains(where: { $0 != trigger.keyCode }) {
                    trackedModifierUsedWithOtherKey = true
                }
                return false
            }

            if keyCode == trigger.keyCode {
                if isActive {
                    trackedModifierIsDown = true
                    trackedModifierUsedWithOtherKey = activeModifierKeys.contains { $0 != trigger.keyCode }
                    return false
                }

                let completedSoloTap = trackedModifierIsDown && !trackedModifierUsedWithOtherKey
                trackedModifierIsDown = false
                trackedModifierUsedWithOtherKey = false

                guard completedSoloTap else {
                    lastCompletedSoloTapAt = nil
                    return false
                }

                let currentTime = now()
                if let lastCompletedSoloTapAt,
                   currentTime - lastCompletedSoloTapAt <= Self.doubleTapTimeout {
                    self.lastCompletedSoloTapAt = nil
                    return true
                }

                lastCompletedSoloTapAt = currentTime
                return false
            }

            if trackedModifierIsDown,
               activeModifierKeys.contains(where: { $0 != trigger.keyCode }) {
                trackedModifierUsedWithOtherKey = true
            }

            return false

        case .keyDown, .keyUp:
            if trackedModifierIsDown {
                trackedModifierUsedWithOtherKey = true
            }

            return false
        }
    }

    // Keep the gesture close to Apple's double-press feel without forcing
    // users to wait a full half second for the second tap.
    private static let doubleTapTimeout: TimeInterval = 0.35

    private static func activeModifierKeys(from flags: CGEventFlags) -> Set<UInt16> {
        Set(
            SpecialKeyTrigger.allCases.compactMap { trigger in
                flags.rawValue & trigger.deviceFlagMask != 0 ? trigger.keyCode : nil
            }
        )
    }
}

/// Hold-to-talk for a special key: the key must stay down alone past a short
/// threshold before dictation starts, so ordinary shortcuts never trigger it.
struct SpecialKeyHoldDetector {
    enum Output: Equatable {
        case none
        /// The key went down alone; start the threshold timer.
        case armed
        /// The key came up early or was used with another key; stop the timer.
        case disarmed
        /// The key came up after dictation had started.
        case ended
    }

    static let holdThreshold: TimeInterval = 0.3

    private var isDown = false
    private var hasBegun = false
    private var usedWithOtherKey = false

    mutating func reset() {
        isDown = false
        hasBegun = false
        usedWithOtherKey = false
    }

    mutating func process(_ event: SpecialKeyMonitorEvent, trigger: SpecialKeyTrigger) -> Output {
        switch event {
        case .flagsChanged(let keyCode, let flags):
            let triggerIsActive = flags.rawValue & trigger.deviceFlagMask != 0
            let otherModifierIsActive = SpecialKeyTrigger.allCases.contains {
                $0.keyCode != trigger.keyCode && flags.rawValue & $0.deviceFlagMask != 0
            }

            if keyCode == trigger.keyCode {
                if triggerIsActive, !isDown {
                    isDown = true
                    hasBegun = false
                    usedWithOtherKey = otherModifierIsActive
                    return usedWithOtherKey ? .none : .armed
                }

                if !triggerIsActive, isDown {
                    let began = hasBegun
                    reset()
                    return began ? .ended : .disarmed
                }

                return .none
            }

            if isDown, !hasBegun, otherModifierIsActive {
                usedWithOtherKey = true
                return .disarmed
            }

            return .none

        case .keyDown:
            if isDown, !hasBegun {
                usedWithOtherKey = true
                return .disarmed
            }

            return .none

        case .keyUp:
            return .none
        }
    }

    /// Called when the threshold timer fires. Returns true when dictation should start.
    mutating func holdThresholdReached() -> Bool {
        guard isDown, !hasBegun, !usedWithOtherKey else { return false }
        hasBegun = true
        return true
    }
}

protocol TriggerRegistering: AnyObject {
    func register(_ configuration: TriggerConfiguration, style: TriggerStyle,
                  canUseSpecialKeyMonitoring: Bool,
                  handler: @escaping (TriggerEvent) -> Void) -> TriggerRegistrationResult
    func unregister()
}

final class TriggerController: TriggerRegistering {
    private let hotKeyController = HotKeyController(identifier: 1)
    private let specialKeyMonitor = SpecialKeyTriggerMonitor()

    @discardableResult
    func register(
        _ configuration: TriggerConfiguration,
        style: TriggerStyle = .toggle,
        canUseSpecialKeyMonitoring: Bool,
        handler: @escaping (TriggerEvent) -> Void
    ) -> TriggerRegistrationResult {
        unregister()

        switch configuration.mode {
        case .standardHotKey:
            let registered = hotKeyController.register(configuration.hotKeyBinding) { isPressed in
                switch style {
                case .toggle:
                    if isPressed { handler(.toggle) }
                case .hold:
                    handler(isPressed ? .holdBegan : .holdEnded)
                }
            }
            return registered ? .registered : .failed("Unable to register the selected shortcut.")
        case .specialKey:
            guard canUseSpecialKeyMonitoring else {
                return .requiresInputMonitoring
            }

            let registered = specialKeyMonitor.register(configuration.specialKeyTrigger, style: style, handler: handler)
            return registered ? .registered : .failed("Unable to monitor the selected special key trigger.")
        }
    }

    func unregister() {
        hotKeyController.unregister()
        specialKeyMonitor.unregister()
    }
}

final class SpecialKeyTriggerMonitor: NSObject {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var handler: ((TriggerEvent) -> Void)?
    private var trigger: SpecialKeyTrigger = .rightCommandTapAlone
    private var style: TriggerStyle = .toggle
    private var detector = SpecialKeyTriggerDetector()
    private var holdDetector = SpecialKeyHoldDetector()
    private var holdTimer: Timer?

    @discardableResult
    func register(_ trigger: SpecialKeyTrigger, style: TriggerStyle = .toggle, handler: @escaping (TriggerEvent) -> Void) -> Bool {
        unregister()

        self.trigger = trigger
        self.style = style
        self.handler = handler
        detector.reset()
        holdDetector.reset()

        let mask = eventMask(for: [.flagsChanged, .keyDown, .keyUp])
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else {
                    return Unmanaged.passUnretained(event)
                }

                let monitor = Unmanaged<SpecialKeyTriggerMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        self.eventTap = eventTap
        runLoopSource = source

        return true
    }

    func unregister() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }

        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }

        holdTimer?.invalidate()
        holdTimer = nil
        detector.reset()
        holdDetector.reset()
        handler = nil
    }

    @objc private func holdTimerFired(_ timer: Timer) {
        holdTimer = nil
        if holdDetector.holdThresholdReached() {
            handler?(.holdBegan)
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let monitorEvent: SpecialKeyMonitorEvent
        switch type {
        case .flagsChanged:
            monitorEvent = .flagsChanged(
                keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
                flags: event.flags
            )
        case .keyDown:
            monitorEvent = .keyDown(keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)))
        case .keyUp:
            monitorEvent = .keyUp(keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)))
        default:
            return Unmanaged.passUnretained(event)
        }

        switch style {
        case .toggle:
            if detector.process(monitorEvent, trigger: trigger) {
                handler?(.toggle)
            }
        case .hold:
            switch holdDetector.process(monitorEvent, trigger: trigger) {
            case .none:
                break
            case .armed:
                holdTimer?.invalidate()
                // The tap is serviced on the main run loop, so the timer lands there too.
                holdTimer = Timer.scheduledTimer(
                    timeInterval: SpecialKeyHoldDetector.holdThreshold,
                    target: self,
                    selector: #selector(holdTimerFired(_:)),
                    userInfo: nil,
                    repeats: false
                )
            case .disarmed:
                holdTimer?.invalidate()
                holdTimer = nil
            case .ended:
                holdTimer?.invalidate()
                holdTimer = nil
                handler?(.holdEnded)
            }
        }

        return Unmanaged.passUnretained(event)
    }

    private func eventMask(for types: [CGEventType]) -> CGEventMask {
        types.reduce(0) { partialResult, type in
            partialResult | (1 << UInt64(type.rawValue))
        }
    }
}
