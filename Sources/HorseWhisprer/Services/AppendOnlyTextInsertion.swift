import AppKit
import ApplicationServices

enum AppendInputPolicy {
    static func isCorrection(type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags = [], keyCode: UInt16 = 0) -> Bool {
        let copyShortcut = type == .keyDown && modifiers.contains(.command) && keyCode == 8
        return type != .scrollWheel && !copyShortcut
    }
}

struct AppendTextState {
    let interaction: Int
    let isQuiet: Bool
    let cursorIsCollapsed: Bool
}

@MainActor
protocol AppendTextTarget: AnyObject {
    var failure: LiveInsertionPauseReason? { get }
    func state() -> AppendTextState?
    func append(_ text: String) -> Bool
    func cancel()
}

/// Explicitly opt-in: sends stable words without changing a selection or
/// claiming that the target app reported the inserted text back to us.
@MainActor
final class AppendOnlyTextInsertion: LiveDictationInserting {
    private let capture: () -> (any AppendTextTarget)?
    private var target: (any AppendTextTarget)?
    private var result = LiveInsertionResult.unavailable
    private var source = ""
    private var committedCount = 0
    private var previousPartial = ""
    private var interaction = 0
    private let now: () -> TimeInterval
    private var stableCandidate = ""
    private var stableSince: TimeInterval = 0
    private(set) var pauseReason: LiveInsertionPauseReason?

    init(capture: @escaping () -> (any AppendTextTarget)? = { AccessibilityAppendTarget.capture() },
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.capture = capture
        self.now = now
    }
    func begin() {
        cancel()
        guard let target = capture() else { return }
        guard let state = target.state(), state.cursorIsCollapsed else {
            target.cancel()
            return
        }
        self.target = target
        interaction = state.interaction
        result = .inserted
    }
    func update(_ transcript: String) async -> LiveInsertionResult { process(transcript, final: false) }
    func finish(_ transcript: String) async -> LiveInsertionResult { process(transcript, final: true) }

    private func process(_ text: String, final: Bool) -> LiveInsertionResult {
        guard result == .inserted, let target else { return result }
        guard !Task.isCancelled else { return pause(.cancelled) }
        guard let state = target.state() else {
            if target.failure?.isTemporarilyUnavailable == true, !final { return result }
            return pause(target.failure ?? .focusUnavailable)
        }
        if state.interaction != interaction {
            interaction = state.interaction
            // Speech already recognized when typing begins belongs to the user's
            // correction. Resume only subsequent speech at their settled cursor.
            committedCount = source.count - source.reversed().prefix { $0.isWhitespace }.count
            stableCandidate = ""
        }
        guard let rebased = LiveTextInsertion.rebasedFrozenCount(committedCount, from: source, to: text) else {
            return pause(.transcriptRevisionAmbiguous)
        }
        // Preserve an already emitted word separator across ASR corrections.
        let emittedSeparator = committedCount > 0 && source.prefix(committedCount).last?.isWhitespace == true
        committedCount = rebased
        if emittedSeparator {
            committedCount += text.dropFirst(committedCount).prefix { $0.isWhitespace }.count
        }
        source = text
        if !state.isQuiet || !state.cursorIsCollapsed {
            stableCandidate = ""
            previousPartial = text
            return final ? pause(.selectionChanged) : result
        }
        var stable: String
        if final { stable = text }
        else {
            let common = String(zip(previousPartial, text).prefix { String($0).utf16.elementsEqual(String($1).utf16) }.map { $0.0 })
            // Hold the final word until it has both a boundary and agreement
            // across decoder hypotheses. Never emit a partial word.
            stable = common.lastIndex(where: { $0.isWhitespace }).map { String(common[...$0]) } ?? ""
        }
        previousPartial = text
        if !final {
            // Preserve the age of an unchanged prefix while later words arrive;
            // restarting the timer on every growth would starve continuous speech.
            if stableCandidate.isEmpty || !stable.hasPrefix(stableCandidate) {
                stableCandidate = stable
                stableSince = now()
            }
            guard now() - stableSince >= 0.25 else { return result }
            let ready = stableCandidate
            stableCandidate = stable
            stableSince = now()
            stable = ready
        }
        guard stable.count > committedCount else { return result }
        let addition = String(stable.dropFirst(committedCount))
        guard target.append(addition) else { return pause(target.failure ?? .dispatchFailed) }
        committedCount = stable.count
        return result
    }
    private func pause(_ reason: LiveInsertionPauseReason) -> LiveInsertionResult {
        pauseReason = reason
        result = .paused
        target?.cancel()
        return result
    }
    func cancel() {
        target?.cancel()
        target = nil
        result = .unavailable
        pauseReason = nil
        source = ""
        previousPartial = ""
        committedCount = 0
        interaction = 0
        stableCandidate = ""
        stableSince = 0
    }
}

@MainActor
private final class AccessibilityAppendTarget: AppendTextTarget {
    let pid: pid_t
    let element: AXUIElement
    private var monitor: Any?
    private var interaction = 0
    private var lastInput: TimeInterval = -.infinity
    private(set) var failure: LiveInsertionPauseReason?

    private init(pid: pid_t, element: AXUIElement) {
        self.pid = pid
        self.element = element
        AXUIElementSetMessagingTimeout(element, 0.2)
    }
    static func capture() -> AccessibilityAppendTarget? {
        guard AXIsProcessTrusted(), CGPreflightListenEventAccess(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        LiveTextApplicationCompatibility.prepare(app)
        guard let element = focused(pid: app.processIdentifier),
              string(element, kAXSubroleAttribute) != kAXSecureTextFieldSubrole,
              let role = string(element, kAXRoleAttribute),
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) else { return nil }
        let target = AccessibilityAppendTarget(pid: app.processIdentifier, element: element)
        guard target.state()?.cursorIsCollapsed == true else { return nil }
        target.monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak target] event in
            // Ignore our own synthetic Unicode events; only actual external edits
            // require settling and freezing previously recognized speech.
            guard event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid()) else { return }
            MainActor.assumeIsolated {
                // Scrolling and Copy settle input without consuming held speech.
                if AppendInputPolicy.isCorrection(type: event.type, modifiers: event.modifierFlags,
                                                  keyCode: event.type == .keyDown ? event.keyCode : 0) {
                    target?.interaction += 1
                }
                target?.lastInput = ProcessInfo.processInfo.systemUptime
            }
        }
        guard target.monitor != nil else { return nil }
        return target
    }
    func state() -> AppendTextState? {
        failure = nil
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { failure = .applicationChanged; return nil }
        guard let focused = Self.focused(pid: pid) else { failure = .focusUnavailable; return nil }
        guard CFEqual(focused, element) else { failure = .fieldChanged; return nil }
        guard let value = Self.attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else {
            failure = .selectionUnavailable; return nil
        }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 else {
            failure = .selectionUnavailable; return nil
        }
        return .init(interaction: interaction, isQuiet: ProcessInfo.processInfo.systemUptime - lastInput >= 0.4,
                     cursorIsCollapsed: range.length == 0)
    }
    func append(_ text: String) -> Bool {
        guard let state = state(), state.isQuiet, state.cursorIsCollapsed,
              let source = CGEventSource(stateID: .privateState) else { return false }
        var events: [CGEvent] = []
        for scalar in text.unicodeScalars {
            let units = Array(String(scalar).utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return false }
            units.withUnsafeBufferPointer {
                down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress!)
                up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress!)
            }
            events += [down, up]
        }
        for event in events { event.flags = []; event.postToPid(pid) }
        return true
    }
    func cancel() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
    private static func focused(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        guard let value = attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private static func string(_ element: AXUIElement, _ name: String) -> String? { attribute(element, name) as? String }
}
