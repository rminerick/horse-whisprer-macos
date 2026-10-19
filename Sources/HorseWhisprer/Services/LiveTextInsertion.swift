import AppKit
import ApplicationServices

struct LiveTextSnapshot: Equatable {
    let text: String
    let selection: NSRange

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.selection == rhs.selection && lhs.text.utf16.elementsEqual(rhs.text.utf16)
    }
}

/// AXValue can describe an empty field's placeholder. Prefer the editable text
/// range and never infer emptiness just because a value looks like a placeholder.
struct LiveTextContent {
    let text: String
    let source: String
    static let maximumLength = 1_000_000

    static func read(value: String?, placeholder: String?,
                     characterCount: () -> Int?, stringForRange: (NSRange) -> String?) -> Self? {
        if let count = characterCount() {
            guard (0...maximumLength).contains(count) else { return nil }
            let ranged = stringForRange(NSRange(location: 0, length: count))
            // Do not combine a range from one editor update with another update's count.
            guard characterCount() == count else { return nil }
            if let ranged {
                guard ranged.utf16.count == count else { return nil }
                return Self(text: ranged, source: "range")
            }
            if count == 0, let value, let placeholder, !placeholder.isEmpty,
               value.utf16.elementsEqual(placeholder.utf16) {
                return Self(text: "", source: "placeholder")
            }
            guard let value, value.utf16.count == count else { return nil }
            return Self(text: value, source: "value")
        }
        guard let value, value.utf16.count <= maximumLength else { return nil }
        return Self(text: value, source: "value")
    }
}

enum LiveInsertionPauseReason: String {
    case applicationChanged, fieldChanged, focusUnavailable, textUnavailable, selectionUnavailable
    case textChanged, selectionChanged, dispatchFailed, selectionRejected
    case textNotConfirmed, selectionNotConfirmed, cancelled
    case transcriptRevisionAmbiguous

    var isTemporarilyUnavailable: Bool {
        self == .focusUnavailable || self == .textUnavailable || self == .selectionUnavailable
    }

    var message: String {
        switch self {
        case .applicationChanged: return String(localized: "The target app lost focus.")
        case .focusUnavailable: return String(localized: "The app temporarily stopped reporting its focused text field.")
        case .fieldChanged: return String(localized: "The app stopped reporting the same focused text field.")
        case .textUnavailable: return String(localized: "The app stopped exposing the text field's contents.")
        case .selectionUnavailable: return String(localized: "The app stopped exposing a valid cursor position.")
        case .textChanged: return String(localized: "The field's text changed outside the verified dictation edit.")
        case .selectionChanged: return String(localized: "The cursor or selection moved outside the verified dictation edit.")
        case .dispatchFailed: return String(localized: "The typing events could not be sent.")
        case .selectionRejected: return String(localized: "The app did not accept the selection needed to revise dictated text.")
        case .textNotConfirmed: return String(localized: "The app did not report the expected inserted text during verification.")
        case .selectionNotConfirmed: return String(localized: "The app did not report the expected cursor position during verification.")
        case .cancelled: return String(localized: "The dictation session was cancelled.")
        case .transcriptRevisionAmbiguous: return String(localized: "The recognizer revised earlier speech, so new words could not be separated safely from your correction.")
        }
    }
}

/// Serializes counts and comparisons only; never includes prompt or transcript text.
struct LiveInsertionDiagnostic {
    let stage: String
    let reason: LiveInsertionPauseReason
    let expected: LiveTextSnapshot
    let actual: LiveTextSnapshot?

    var logLine: String {
        let actualLength = actual.map { String($0.text.utf16.count) } ?? "unavailable"
        let actualSelection = actual.map { "\($0.selection.location):\($0.selection.length)" } ?? "unavailable"
        let textMatches = actual.map { expected.text.utf16.elementsEqual($0.text.utf16) } ?? false
        return "stage=\(stage) reason=\(reason.rawValue) expectedUTF16=\(expected.text.utf16.count) actualUTF16=\(actualLength) textMatches=\(textMatches) expectedSelection=\(expected.selection.location):\(expected.selection.length) actualSelection=\(actualSelection)"
    }
}

@MainActor
protocol LiveTextTarget: AnyObject {
    /// Nil means focus was lost, the field disappeared, or its contents cannot be read.
    var snapshotFailure: LiveInsertionPauseReason? { get }
    func canReconcileInitialPlaceholder(_ text: String) -> Bool
    func snapshot() -> LiveTextSnapshot?
    func replace(range: NSRange, with text: String, expected: LiveTextSnapshot,
                 canDeliver: @MainActor () -> Bool) async -> Bool
}

@MainActor
extension LiveTextTarget {
    var snapshotFailure: LiveInsertionPauseReason? { nil }
    func canReconcileInitialPlaceholder(_ text: String) -> Bool { false }
}

/// Electron editors may acknowledge AXSelectedTextRange before publishing it.
/// Wait only while the old selection persists; never accept changed text, a
/// third selection, lost focus, or a cancelled session as our own selection.
@MainActor
enum LiveTextSelectionConfirmation {
    static func waitForSelection(from initial: LiveTextSnapshot, to selection: NSRange,
                                 snapshot: () -> LiveTextSnapshot?, canDeliver: () -> Bool,
                                 wait: () async throws -> Void = { try await Task.sleep(for: .milliseconds(20)) }) async -> LiveInsertionPauseReason? {
        let desired = LiveTextSnapshot(text: initial.text, selection: selection)
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(250))
        for attempt in 0..<14 {
            guard canDeliver(), !Task.isCancelled else { return .cancelled }
            guard let current = snapshot() else { return .selectionUnavailable }
            guard current.text.utf16.elementsEqual(initial.text.utf16) else { return .textChanged }
            if current == desired { return nil }
            guard current.selection == initial.selection else { return .selectionChanged }
            guard attempt < 13, ContinuousClock.now < deadline else { break }
            do { try await wait() } catch { return .cancelled }
        }
        return .selectionNotConfirmed
    }
}

enum LiveTextApplicationCompatibility {
    static func canReconcileInitialPlaceholder(_ text: String, bundleIdentifier: String?) -> Bool {
        switch bundleIdentifier {
        case "com.openai.codex": return true
        // OpenCode's empty composer reports a zero-width space that disappears
        // on its first keystroke. Reconcile only that exact initial decoration.
        case "ai.opencode.desktop": return text == "\u{200B}"
        // These rich-text composers expose one empty paragraph as a newline.
        // Only reconcile that exact initial value after verifying the full edit;
        // real drafts, spaces, and multiple blank lines must still match.
        case "com.t3tools.t3code", "com.anthropic.claudefordesktop", "com.apple.Safari":
            return text == "\n"
        default: return false
        }
    }

    @MainActor
    static func prepare(_ app: NSRunningApplication) {
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.2)
        requestAccessibility(bundleIdentifier: app.bundleIdentifier, readEnabled: { attribute in
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(application, attribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
            return CFBooleanGetValue(value as! CFBoolean)
        }, enable: { attribute in
            let result = AXUIElementSetAttributeValue(application, attribute as CFString, kCFBooleanTrue)
            AudioDiagnostics.shared.log("LiveInsertion", "prepareAccessibility target=\(app.bundleIdentifier ?? "unknown") attribute=\(attribute) result=\(result.rawValue)")
            return result
        })
    }

    /// Request before pinning the field: enabling the AX tree can replace its
    /// elements. Never toggle a working tree or disable another assistive client.
    @discardableResult
    static func requestAccessibility(bundleIdentifier: String?, readEnabled: (String) -> Bool?,
                                     enable: (String) -> AXError) -> AXError? {
        let attribute: String
        switch bundleIdentifier {
        // ChatGPT's Chromium framework uses the standard Chromium AT signal.
        // https://www.chromium.org/developers/design-documents/accessibility/
        case "com.openai.codex": attribute = "AXEnhancedUserInterface"
        // https://www.electronjs.org/docs/latest/tutorial/accessibility
        case "com.t3tools.t3code", "com.anthropic.claudefordesktop": attribute = "AXManualAccessibility"
        default: return nil
        }
        guard readEnabled(attribute) != true else { return nil }
        return enable(attribute)
    }
}

enum LiveInsertionResult: Equatable {
    case unavailable
    case inserted
    case paused
}

@MainActor
protocol LiveDictationInserting {
    var pauseReason: LiveInsertionPauseReason? { get }
    func begin()
    func begin(mode: StreamingInsertionMode)
    func update(_ transcript: String) async -> LiveInsertionResult
    func finish(_ transcript: String) async -> LiveInsertionResult
    func cancel()
}

@MainActor
extension LiveDictationInserting {
    var pauseReason: LiveInsertionPauseReason? { nil }
    func begin(mode: StreamingInsertionMode) { begin() }
    func finish(_ transcript: String) async -> LiveInsertionResult { await update(transcript) }
}

/// Owns only the current dictated range. Manual edits commit the previous range;
/// subsequent speech starts at the settled cursor without revising the user's work.
/// Uncertain dispatch or lost focus still pauses permanently to prevent duplicates.
@MainActor
final class LiveTextInsertion: LiveDictationInserting {
    private let makeCapture: () -> (() -> (any LiveTextTarget)?)
    private var pendingCapture: (() -> (any LiveTextTarget)?)?
    private(set) var pauseReason: LiveInsertionPauseReason?
    private let log: (String) -> Void
    private let wait: @Sendable () async throws -> Void
    private let now: () -> TimeInterval
    private var captureRetryStarted: TimeInterval?
    private var nextCaptureRetry: TimeInterval = 0
    private var nextUnchangedSnapshot: TimeInterval = 0
    private var target: (any LiveTextTarget)?
    private var expected: LiveTextSnapshot?
    private var dictatedRange = NSRange(location: 0, length: 0)
    private var transcript = ""
    private var sourceTranscript = ""
    private var frozenSourceCount = 0
    private var waitingForManualEdit = false
    private var result = LiveInsertionResult.unavailable
    private var generation = 0
    private var hasAttemptedEdit = false

    init(log: @escaping (String) -> Void = { AudioDiagnostics.shared.log("LiveInsertion", $0) },
         capture: (() -> (any LiveTextTarget)?)? = nil,
         wait: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .milliseconds(20)) },
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.log = log
        self.makeCapture = { capture ?? AccessibilityLiveTextTarget.captureForCurrentField() }
        self.wait = wait
        self.now = now
    }

    func begin() {
        cancel()
        pendingCapture = makeCapture()
        if !tryCapture() { log("begin targetCaptured=false") }
    }

    private func tryCapture() -> Bool {
        guard let target = pendingCapture?(), let snapshot = target.snapshot(),
              snapshot.selection.location >= 0, snapshot.selection.length >= 0,
              snapshot.selection.location <= snapshot.text.utf16.count,
              snapshot.selection.length <= snapshot.text.utf16.count - snapshot.selection.location else {
            return false
        }
        self.target = target
        expected = snapshot
        dictatedRange = snapshot.selection
        result = .inserted
        pendingCapture = nil
        log("begin targetCaptured=true")
        return true
    }

    func update(_ newTranscript: String) async -> LiveInsertionResult {
        await update(newTranscript, validateUnchanged: false)
    }

    private func update(_ newTranscript: String, validateUnchanged: Bool) async -> LiveInsertionResult {
        let generation = self.generation
        // Retry only before any input has been posted, and only for the field
        // pinned at begin(). Empty decoder updates must not hammer Accessibility.
        if result == .unavailable, pendingCapture != nil, !newTranscript.isEmpty {
            if captureRetryStarted == nil { captureRetryStarted = now() }
            guard now() - captureRetryStarted! < 10 else {
                pendingCapture = nil
                log("captureRetryExpired")
                return .unavailable
            }
            guard now() >= nextCaptureRetry else { return .unavailable }
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(250))
            for attempt in 0..<11 {
                guard generation == self.generation, !Task.isCancelled else { return .paused }
                if tryCapture() { break }
                guard attempt < 10, ContinuousClock.now < deadline else { break }
                do { try await wait() } catch { break }
            }
            guard generation == self.generation, !Task.isCancelled else { return .paused }
            nextCaptureRetry = now() + 0.25
        }
        guard result == .inserted, let target, var expected else { return result }
        if Task.isCancelled { return pause(.cancelled, stage: "beforeEdit", expected: expected, actual: nil) }
        // Audio chunks often repeat the same partial. Poll at most every 150ms,
        // but always validate changed text, a pending manual edit, and finalization.
        if !validateUnchanged, !waitingForManualEdit,
           newTranscript.utf16.elementsEqual(sourceTranscript.utf16), now() < nextUnchangedSnapshot {
            return .inserted
        }
        let before = target.snapshot()
        nextUnchangedSnapshot = now() + 0.15
        if before != expected {
            guard before != nil || target.snapshotFailure?.isTemporarilyUnavailable == true else {
                return pause(mismatchReason(expected: expected, actual: before, target: target, verifying: false),
                             stage: "beforeEdit", expected: expected, actual: before)
            }
            // Wait for typing/selection to settle. Never replace a user's active
            // selection and never replay the transcript they just corrected.
            waitingForManualEdit = true
            var stable = before
            var stableReads = 0
            for _ in 0..<26 {
                do { try await wait() } catch { return .paused }
                guard generation == self.generation, !Task.isCancelled else { return .paused }
                guard let current = target.snapshot() else {
                    if target.snapshotFailure?.isTemporarilyUnavailable == true {
                        stable = nil
                        stableReads = 0
                        continue
                    }
                    return pause(target.snapshotFailure ?? .textUnavailable,
                                 stage: "manualEdit", expected: expected, actual: nil)
                }
                stableReads = current == stable && current.selection.length == 0 ? stableReads + 1 : 0
                stable = current
                if stableReads >= 20 { break }
            }
            guard stableReads >= 20, let stable else { return .inserted }
            waitingForManualEdit = false
            if stable != expected {
                expected = stable
                self.expected = stable
                dictatedRange = stable.selection
                transcript = ""
                frozenSourceCount = sourceTranscript.count - sourceTranscript.reversed().prefix { $0.isWhitespace }.count
                log("resumedAfterManualEdit frozenCharacters=\(frozenSourceCount)")
            }
        } else {
            waitingForManualEdit = false
        }
        guard let nextFrozenCount = Self.rebasedFrozenCount(frozenSourceCount, from: sourceTranscript, to: newTranscript) else {
            return pause(.transcriptRevisionAmbiguous, stage: "manualEdit", expected: expected, actual: before)
        }
        let editableTranscript = String(newTranscript.dropFirst(nextFrozenCount))
        guard !editableTranscript.utf16.elementsEqual(transcript.utf16) else {
            sourceTranscript = newTranscript
            frozenSourceCount = nextFrozenCount
            return .inserted
        }
        // Compare Characters so a revision cannot split a surrogate pair or a grapheme.
        let common = String(zip(transcript, editableTranscript).prefix { String($0).utf16.elementsEqual(String($1).utf16) }.map { $0.0 })
        let prefixLength = common.utf16.count
        let replacement = String(editableTranscript.dropFirst(common.count))
        let range = NSRange(location: dictatedRange.location + prefixLength,
                            length: dictatedRange.length - prefixLength)
        let next = LiveTextSnapshot(
            text: (expected.text as NSString).replacingCharacters(in: range, with: replacement),
            selection: NSRange(location: dictatedRange.location + editableTranscript.utf16.count, length: 0))
        // Treat even a failed dispatch as potentially mutating. Never fall back to
        // pasting the whole transcript after an uncertain or partially delivered edit.
        let isFirstEdit = !hasAttemptedEdit
        hasAttemptedEdit = true
        let dispatched = await target.replace(range: range, with: replacement, expected: expected,
            canDeliver: { generation == self.generation && !Task.isCancelled })
        guard generation == self.generation, !Task.isCancelled else { return .paused }
        guard dispatched else {
            let reason = target.snapshotFailure ?? .dispatchFailed
            return pause(reason, stage: "dispatch", expected: expected, actual: target.snapshot())
        }
        var observed: LiveTextSnapshot?
        // Some editors publish text and selection through Accessibility on separate
        // updates. Wait for both to match without posting the edit a second time.
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        for attempt in 0..<51 {
            guard generation == self.generation, !Task.isCancelled else { return .paused }
            observed = target.snapshot()
            if observed == nil, let failure = target.snapshotFailure,
               failure == .applicationChanged || failure == .fieldChanged {
                return pause(failure, stage: "verification", expected: next, actual: nil)
            }
            if observed == next {
                return confirm(next, transcript: editableTranscript, source: newTranscript, frozenCount: nextFrozenCount)
            }
            guard attempt < 50, ContinuousClock.now < deadline else { break }
            do { try await wait() } catch { break }
        }
        guard generation == self.generation, !Task.isCancelled else { return .paused }
        // Some apps expose their empty composer's decoration as editable text (including
        // AXNumberOfCharacters/AXStringForRange), then drops it on the first keystroke.
        // Reconcile only this initial, non-destructive insertion after normal
        // verification has expired. Never select/delete the apparent initial text,
        // replay input, or accept a partial match or a change during later updates.
        if isFirstEdit, target.canReconcileInitialPlaceholder(expected.text), transcript.isEmpty, !expected.text.isEmpty,
           expected.selection == NSRange(location: 0, length: 0),
           dictatedRange == NSRange(location: 0, length: 0), !newTranscript.isEmpty,
           let observed,
           observed == LiveTextSnapshot(text: newTranscript,
                                        selection: NSRange(location: newTranscript.utf16.count, length: 0)) {
            log("reconciledInitialPlaceholder initialUTF16=\(expected.text.utf16.count)")
            return confirm(observed, transcript: editableTranscript, source: newTranscript, frozenCount: nextFrozenCount)
        }
        return pause(mismatchReason(expected: next, actual: observed, target: target, verifying: true),
                     stage: "verification", expected: next, actual: observed)
    }

    func finish(_ transcript: String) async -> LiveInsertionResult {
        let generation = self.generation
        nextCaptureRetry = 0
        let result = await update(transcript, validateUnchanged: true)
        guard generation == self.generation, !Task.isCancelled else { return .paused }
        if waitingForManualEdit, result == .inserted, let expected {
            return pause(.selectionChanged, stage: "finalManualEdit", expected: expected, actual: target?.snapshot())
        }
        return result
    }

    /// Align committed speech to a prefix, leaving appended words unconsumed.
    /// Ambiguous or oversized revisions pause rather than replaying or dropping
    /// an unknown amount of speech after the user's correction.
    static func rebasedFrozenCount(_ count: Int, from old: String, to new: String) -> Int? {
        guard count > 0 else { return 0 }
        let oldCharacters = Array(old)
        let newCharacters = Array(new)
        let prefix = zip(oldCharacters, newCharacters).prefix {
            String($0).lowercased() == String($1).lowercased()
        }.count
        if count <= prefix {
            // A committed final word may have been only a partial recognition
            // ("wor" -> "world"). Do not append its remaining letters to a
            // correction the user now owns; resume with the following word.
            var boundary = count
            if count > 0, count == oldCharacters.count || oldCharacters[count].isWhitespace,
               oldCharacters[count - 1].isLetter || oldCharacters[count - 1].isNumber {
                while boundary < newCharacters.count, !newCharacters[boundary].isWhitespace {
                    boundary += 1
                }
            }
            return boundary
        }
        func words(_ characters: [Character], limit: Int) -> [(text: String, end: Int)] {
            var words: [(text: String, end: Int)] = []
            var start = 0
            for end in 0...characters.count {
                if end == characters.count || characters[end].isWhitespace {
                    if start < end {
                        let text = String(characters[start..<end]).trimmingCharacters(in: .punctuationCharacters).lowercased()
                        if !text.isEmpty { words.append((text, end)) }
                        if words.count >= limit { break }
                    }
                    start = end + 1
                }
            }
            return words
        }
        let committed = words(Array(oldCharacters.prefix(count)), limit: 257)
        guard !committed.isEmpty, committed.count <= 256 else { return nil }
        let candidates = words(newCharacters, limit: committed.count + 32)
        guard !candidates.isEmpty else { return nil }
        var previous = Array(0...candidates.count)
        for i in 1...committed.count {
            var row = [i] + Array(repeating: 0, count: candidates.count)
            for j in 1...candidates.count {
                let matches = committed[i - 1].text == candidates[j - 1].text
                    || (i == committed.count && candidates[j - 1].text.hasPrefix(committed[i - 1].text))
                row[j] = min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + (matches ? 0 : 1))
            }
            previous = row
        }
        let minimum = previous.min()!
        let endpoints = previous.indices.filter { previous[$0] == minimum }
        guard endpoints.count == 1, let endpoint = endpoints.first, endpoint > 0 else { return nil }
        return candidates[endpoint - 1].end
    }

    private func confirm(_ snapshot: LiveTextSnapshot, transcript: String, source: String, frozenCount: Int) -> LiveInsertionResult {
        expected = snapshot
        dictatedRange.length = transcript.utf16.count
        self.transcript = transcript
        sourceTranscript = source
        frozenSourceCount = frozenCount
        log("confirmed insertedUTF16=\(transcript.utf16.count)")
        return .inserted
    }

    private func mismatchReason(expected: LiveTextSnapshot, actual: LiveTextSnapshot?,
                                target: any LiveTextTarget, verifying: Bool) -> LiveInsertionPauseReason {
        guard let actual else { return target.snapshotFailure ?? .textUnavailable }
        if !expected.text.utf16.elementsEqual(actual.text.utf16) { return verifying ? .textNotConfirmed : .textChanged }
        return verifying ? .selectionNotConfirmed : .selectionChanged
    }

    private func pause(_ reason: LiveInsertionPauseReason, stage: String,
                       expected: LiveTextSnapshot, actual: LiveTextSnapshot?) -> LiveInsertionResult {
        result = .paused
        pauseReason = reason
        log(LiveInsertionDiagnostic(stage: stage, reason: reason, expected: expected, actual: actual).logLine)
        return .paused
    }

    func cancel() {
        generation += 1
        pauseReason = nil
        target = nil
        pendingCapture = nil
        captureRetryStarted = nil
        nextCaptureRetry = 0
        nextUnchangedSnapshot = 0
        expected = nil
        transcript = ""
        sourceTranscript = ""
        frozenSourceCount = 0
        waitingForManualEdit = false
        hasAttemptedEdit = false
        result = .unavailable
    }
}

/// Uses AX to validate the exact field and selection, then sends Unicode events
/// to that process. It neither activates another app nor uses the clipboard.
@MainActor
final class AccessibilityLiveTextTarget: LiveTextTarget {
    private(set) var snapshotFailure: LiveInsertionPauseReason?
    private let element: AXUIElement
    private let pid: pid_t
    private let bundleIdentifier: String?
    private var loggedContentSource: String?

    private init(element: AXUIElement, pid: pid_t, bundleIdentifier: String?) {
        self.element = element
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        AXUIElementSetMessagingTimeout(element, 0.2)
    }

    func canReconcileInitialPlaceholder(_ text: String) -> Bool {
        LiveTextApplicationCompatibility.canReconcileInitialPlaceholder(text, bundleIdentifier: bundleIdentifier)
    }

    static func captureForCurrentField() -> () -> (any LiveTextTarget)? {
        let log = { (reason: String) in
            AudioDiagnostics.shared.log("LiveInsertion", "captureUnavailable reason=\(reason)")
        }
        guard AXIsProcessTrusted() else { log("accessibilityDenied"); return { nil } }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { log("noExternalApp"); return { nil } }
        AudioDiagnostics.shared.log("LiveInsertion", "captureTarget=\(app.bundleIdentifier ?? "unknown")")
        let started = ProcessInfo.processInfo.systemUptime
        LiveTextApplicationCompatibility.prepare(app)
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.2)
        func window() -> AXUIElement? {
            guard let value = attribute(application, kAXFocusedWindowAttribute),
                  CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
        var anchor = LiveCaptureAnchor(window: window(), field: focusedElement(pid: app.processIdentifier),
                                       equal: { CFEqual($0, $1) })
        var previousFailure: String?
        return {
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            let interacted = [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown].contains {
                CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) < elapsed
            }
            guard let element = anchor.resolve(sameApp: NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                                               window: window(), field: focusedElement(pid: app.processIdentifier),
                                               interacted: interacted) else {
                let reason = anchor.invalidated ? "focusChanged" : "focusUnavailable"
                if previousFailure != reason { log(reason) }
                previousFailure = reason
                return nil
            }
            return capture(element: element, app: app) { reason in
                if previousFailure != reason { log(reason) }
                previousFailure = reason
            }
        }
    }

    private static func capture(element: AXUIElement, app: NSRunningApplication,
                                failure: (String) -> Void) -> AccessibilityLiveTextTarget? {
        guard stringAttribute(element, kAXSubroleAttribute) != kAXSecureTextFieldSubrole else {
            failure("secureField"); return nil
        }
        let role = stringAttribute(element, kAXRoleAttribute)
        guard role == kAXTextFieldRole || role == kAXTextAreaRole || role == kAXComboBoxRole else {
            failure("unsupportedRole"); return nil
        }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &settable) == .success,
              settable.boolValue else { failure("selectionNotSettable"); return nil }
        let target = AccessibilityLiveTextTarget(element: element, pid: app.processIdentifier,
                                                bundleIdentifier: app.bundleIdentifier)
        guard target.snapshot() != nil else { failure(target.snapshotFailure?.rawValue ?? "snapshotUnavailable"); return nil }
        return target
    }

    func snapshot() -> LiveTextSnapshot? {
        snapshotFailure = nil
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            snapshotFailure = .applicationChanged; return nil
        }
        guard let focused = Self.focusedElement(pid: pid) else {
            snapshotFailure = .focusUnavailable; return nil
        }
        guard CFEqual(focused, element) else {
            snapshotFailure = .fieldChanged; return nil
        }
        let rawText = Self.stringAttribute(element, kAXValueAttribute)
        let placeholder = Self.stringAttribute(element, kAXPlaceholderValueAttribute)
        var reportedCount: Int?
        let content = LiveTextContent.read(value: rawText, placeholder: placeholder, characterCount: {
            reportedCount = (Self.attribute(self.element, kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue
            return reportedCount
        }, stringForRange: { range in
            var cfRange = CFRange(location: range.location, length: range.length)
            guard let parameter = AXValueCreate(.cfRange, &cfRange) else { return nil }
            var result: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(self.element,
                kAXStringForRangeParameterizedAttribute as CFString, parameter, &result) == .success else { return nil }
            return result as? String
        })
        let source = content?.source ?? "unavailable"
        if loggedContentSource != source {
            let matchesPlaceholder = rawText.map { text in
                placeholder.map { text.utf16.elementsEqual($0.utf16) } ?? false
            } ?? false
            AudioDiagnostics.shared.log("LiveInsertion", "contentSource=\(source) valueUTF16=\(rawText.map { String($0.utf16.count) } ?? "unavailable") characterCount=\(reportedCount.map(String.init) ?? "unavailable") placeholderMatches=\(matchesPlaceholder)")
            loggedContentSource = source
        }
        guard let text = content?.text else {
            snapshotFailure = .textUnavailable; return nil
        }
        guard let raw = Self.attribute(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(raw) == AXValueGetTypeID() else {
            snapshotFailure = .selectionUnavailable; return nil
        }
        let value = raw as! AXValue
        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range), range.location >= 0, range.length >= 0,
              range.location <= text.utf16.count, range.length <= text.utf16.count - range.location else {
            snapshotFailure = .selectionUnavailable; return nil
        }
        return LiveTextSnapshot(text: text, selection: NSRange(location: range.location, length: range.length))
    }

    func replace(range: NSRange, with text: String, expected: LiveTextSnapshot,
                 canDeliver: @MainActor () -> Bool) async -> Bool {
        guard let source = CGEventSource(stateID: .privateState) else { return false }
        // Build every event before changing the selection. Each scalar is a complete
        // Unicode sequence (including both UTF-16 units of a supplementary scalar).
        var events: [CGEvent] = []
        if text.isEmpty {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false) else { return false }
            events = [down, up]
        } else {
            for scalar in text.unicodeScalars {
                let units = Array(String(scalar).utf16)
                guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return false }
                units.withUnsafeBufferPointer { pointer in
                    down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: pointer.baseAddress!)
                    up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: pointer.baseAddress!)
                }
                events += [down, up]
            }
        }
        guard canDeliver(), matches(expected) else { return false }
        if range != expected.selection {
            var selection = CFRange(location: range.location, length: range.length)
            guard let value = AXValueCreate(.cfRange, &selection),
                  AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success else {
                snapshotFailure = .selectionRejected; return false
            }
            if let failure = await LiveTextSelectionConfirmation.waitForSelection(
                from: expected, to: range, snapshot: { self.snapshot() }, canDeliver: canDeliver) {
                snapshotFailure = snapshotFailure ?? failure
                return false
            }
        }
        guard canDeliver(), matches(LiveTextSnapshot(text: expected.text, selection: range)) else { return false }
        for event in events {
            event.flags = []
            event.postToPid(pid)
        }
        return true
    }

    private func matches(_ expected: LiveTextSnapshot) -> Bool {
        guard let actual = snapshot() else { return false }
        if !actual.text.utf16.elementsEqual(expected.text.utf16) { snapshotFailure = .textChanged; return false }
        if actual.selection != expected.selection { snapshotFailure = .selectionChanged; return false }
        return true
    }

    private static func focusedElement(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        guard let value = attribute(app, kAXFocusedUIElementAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }
}

/// A missing initial AX field may recover only in the original window, before
/// any keyboard/mouse interaction. Once known, the field identity is pinned.
struct LiveCaptureAnchor<Element> {
    let window: Element?
    private(set) var field: Element?
    let equal: (Element, Element) -> Bool
    private(set) var invalidated = false

    mutating func resolve(sameApp: Bool, window currentWindow: Element?, field currentField: Element?,
                          interacted: Bool) -> Element? {
        guard !invalidated else { return nil }
        guard sameApp else { invalidated = true; return nil }
        if let field {
            guard let currentField else { return nil }
            guard equal(field, currentField) else { invalidated = true; return nil }
            return field
        }
        guard !interacted else { invalidated = true; return nil }
        guard let window, let currentWindow else { return nil }
        guard equal(window, currentWindow) else { invalidated = true; return nil }
        field = currentField
        return field
    }
}
