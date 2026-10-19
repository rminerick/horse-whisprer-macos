import XCTest
import ApplicationServices
@testable import HorseWhisprer

@MainActor
final class LiveTextInsertionTests: XCTestCase {
    func testOpenCodeEmptyComposerStreamsRevisesAndFinishes() async {
        // OpenCode 2.0.24 exposes U+200B for its empty composer, then
        // removes that decoration when the first keyboard input arrives.
        let target = LiveTargetStub("\u{200B}", .init(location: 0, length: 0))
        target.bundleIdentifier = "ai.opencode.desktop"
        target.nextEditResult = .init(text: "Hello", selection: .init(location: 5, length: 0))
        let live = LiveTextInsertion(log: { _ in }, capture: { target }, wait: {})
        live.begin()
        for text in ["Hello", "Hello world", "Hello there 🐴"] {
            let result = await live.update(text)
            XCTAssertEqual(result, .inserted)
            XCTAssertEqual(target.value.text, text)
        }
        let result = await live.finish("Hello there 🐴.")
        XCTAssertEqual(result, .inserted)
        XCTAssertEqual(target.value.text, "Hello there 🐴.")
        XCTAssertEqual(target.edits.count, 4, "Never replay the first insertion")
    }

    func testOpenCodeReconcilesOnlyItsExactEmptyDecoration() {
        XCTAssertTrue(LiveTextApplicationCompatibility.canReconcileInitialPlaceholder("\u{200B}", bundleIdentifier: "ai.opencode.desktop"))
        for text in ["", "\n", " ", "\u{200B}\u{200B}", "Draft\u{200B}", "\u{200B}\n"] {
            XCTAssertFalse(LiveTextApplicationCompatibility.canReconcileInitialPlaceholder(text, bundleIdentifier: "ai.opencode.desktop"))
        }
        for bundle in [nil, "other.editor", "com.apple.Safari", "com.anthropic.claudefordesktop"] {
            XCTAssertFalse(LiveTextApplicationCompatibility.canReconcileInitialPlaceholder("\u{200B}", bundleIdentifier: bundle))
        }
    }

    func testOpenCodeRejectsPartialFirstEditAndLaterMismatchesWithoutReplay() async {
        for firstEdit in [true, false] {
            let target = LiveTargetStub(firstEdit ? "\u{200B}" : "", .init(location: 0, length: 0))
            target.bundleIdentifier = "ai.opencode.desktop"
            let live = LiveTextInsertion(log: { _ in }, capture: { target }, wait: {})
            live.begin()
            if !firstEdit { _ = await live.update("Hello") }
            target.nextEditResult = .init(text: "Hello worl", selection: .init(location: 10, length: 0))
            let result = await live.update("Hello world")
            XCTAssertEqual(result, .paused)
            XCTAssertEqual(live.pauseReason, .textNotConfirmed)
            let editCount = target.edits.count
            _ = await live.finish("Hello world again")
            XCTAssertEqual(target.edits.count, editCount)
        }
    }

    func testDelayedSelectionConfirmationAcceptsOnlyTheRequestedRange() async {
        let initial = LiveTextSnapshot(text: "Hello world", selection: .init(location: 11, length: 0))
        let range = NSRange(location: 6, length: 5)
        var value = initial
        var waits = 0
        let reason = await LiveTextSelectionConfirmation.waitForSelection(from: initial, to: range,
            snapshot: { value }, canDeliver: { true }, wait: {
                waits += 1
                if waits == 2 { value = .init(text: initial.text, selection: range) }
            })
        XCTAssertNil(reason)
        XCTAssertEqual(waits, 2)
    }

    func testSelectionWaitRejectsManualEditsLostFocusAndUnconfirmedSelection() async {
        let initial = LiveTextSnapshot(text: "Hello world", selection: .init(location: 11, length: 0))
        let range = NSRange(location: 6, length: 5)
        let cases: [(LiveTextSnapshot?, LiveInsertionPauseReason)] = [
            (.init(text: "Edited", selection: range), .textChanged),
            (.init(text: initial.text, selection: .init(location: 0, length: 0)), .selectionChanged),
            (nil, .selectionUnavailable), (initial, .selectionNotConfirmed)
        ]
        for (snapshot, expected) in cases {
            let reason = await LiveTextSelectionConfirmation.waitForSelection(from: initial, to: range,
                snapshot: { snapshot }, canDeliver: { true }, wait: {})
            XCTAssertEqual(reason, expected)
        }
    }

    func testCancellationDuringSelectionPreparationNeverDispatchesOrPausesNewSession() async {
        let target = LiveTargetStub("", .init(location: 0, length: 0))
        let live = LiveTextInsertion(log: { _ in }, capture: { target }, wait: {})
        live.begin()
        target.beforeReplace = { live.cancel(); live.begin() }
        let result = await live.update("Cancelled sample")
        XCTAssertEqual(result, .paused)
        XCTAssertTrue(target.edits.isEmpty)
        target.beforeReplace = nil
        let next = await live.update("New session")
        XCTAssertEqual(next, .inserted)
        XCTAssertEqual(target.value.text, "New session")
    }

    func testSafariAndClaudeEmptyComposerStreamsRevisesAndFinishes() async {
        for bundle in ["com.apple.Safari", "com.anthropic.claudefordesktop"] {
            let target = LiveTargetStub("\n", .init(location: 0, length: 0))
            target.bundleIdentifier = bundle
            target.nextEditResult = .init(text: "Hello", selection: .init(location: 5, length: 0))
            let live = LiveTextInsertion(log: { _ in }, capture: { target }, wait: {})
            live.begin()
            for text in ["Hello", "Hello world", "Hello there 🐴"] {
                let result = await live.update(text)
                XCTAssertEqual(result, .inserted, bundle)
                XCTAssertEqual(target.value.text, text)
            }
            let result = await live.finish("Hello there 🐴.")
            XCTAssertEqual(result, .inserted)
            XCTAssertEqual(target.value.text, "Hello there 🐴.")
            XCTAssertEqual(target.edits.count, 4, "Never replay the first insertion")
        }
    }

    func testSafariAndClaudeNeverReconcileLostDraftsOrLaterMismatches() async {
        for bundle in ["com.apple.Safari", "com.anthropic.claudefordesktop"] {
            for initial in ["Saved draft", "\n\n", " ", "Saved draft\n"] {
                let target = LiveTargetStub(initial, .init(location: 0, length: 0))
                target.bundleIdentifier = bundle
                target.nextEditResult = .init(text: "Hello", selection: .init(location: 5, length: 0))
                let live = LiveTextInsertion(log: { _ in }, capture: { target }, wait: {})
                live.begin()
                let result = await live.update("Hello")
                XCTAssertEqual(result, .paused)
                _ = await live.finish("Hello world")
                XCTAssertEqual(target.edits.count, 1)
            }
            let target = LiveTargetStub("", .init(location: 0, length: 0))
            target.bundleIdentifier = bundle
            let live = LiveTextInsertion(log: { _ in }, capture: { target }, wait: {})
            live.begin()
            _ = await live.update("Hello")
            target.nextEditResult = .init(text: "Hello worl", selection: .init(location: 10, length: 0))
            let result = await live.update("Hello world")
            XCTAssertEqual(result, .paused)
            XCTAssertEqual(live.pauseReason, .textNotConfirmed)
        }
    }

    func testClaudeAccessibilityActivationIsRequestedOnceAndSafariIsNotModified() {
        var writes: [String] = []
        _ = LiveTextApplicationCompatibility.requestAccessibility(bundleIdentifier: "com.anthropic.claudefordesktop", readEnabled: { _ in false }, enable: {
            writes.append($0); return .success
        })
        XCTAssertEqual(writes, ["AXManualAccessibility"])
        for bundle in ["com.anthropic.claudefordesktop", "com.apple.Safari"] {
            _ = LiveTextApplicationCompatibility.requestAccessibility(bundleIdentifier: bundle, readEnabled: { _ in true }, enable: { _ in
                XCTFail("Do not reset a working tree or alter Safari"); return .failure
            })
        }
    }

    func testChatGPTAccessibilityActivationRecoversCaptureBeforeStreaming() async {
        let target = LiveTargetStub("", .init(location: 0, length: 0))
        var enabled = false
        var reads: [String] = []
        var writes: [String] = []
        let live = LiveTextInsertion(log: { _ in }, capture: { enabled ? target : nil }, wait: {})
        live.begin()
        XCTAssertTrue(target.edits.isEmpty)
        let activation = LiveTextApplicationCompatibility.requestAccessibility(bundleIdentifier: "com.openai.codex", readEnabled: {
            reads.append($0)
            return enabled
        }, enable: {
            writes.append($0)
            enabled = true
            return .success
        })
        XCTAssertEqual(activation, .success)
        XCTAssertEqual(reads, ["AXEnhancedUserInterface"])
        XCTAssertEqual(writes, ["AXEnhancedUserInterface"])
        let result = await live.update("Streaming again")
        XCTAssertEqual(result, .inserted)
        XCTAssertEqual(target.value.text, "Streaming again")
        XCTAssertEqual(target.edits.count, 1)
    }

    func testAccessibilityActivationKeepsT3SignalAndSkipsWorkingTreesAndUnknownApps() {
        var writes: [String] = []
        let result = LiveTextApplicationCompatibility.requestAccessibility(bundleIdentifier: "com.t3tools.t3code", readEnabled: { _ in nil }, enable: {
            writes.append($0)
            return .success
        })
        XCTAssertEqual(result, .success)
        XCTAssertEqual(writes, ["AXManualAccessibility"])
        for bundle in ["com.openai.codex", "com.t3tools.t3code"] {
            XCTAssertNil(LiveTextApplicationCompatibility.requestAccessibility(bundleIdentifier: bundle, readEnabled: { _ in true }, enable: { _ in
                XCTFail("Do not reset an already enabled tree")
                return .failure
            }))
        }
        for bundle in [nil, "other.editor"] as [String?] {
            XCTAssertNil(LiveTextApplicationCompatibility.requestAccessibility(bundleIdentifier: bundle, readEnabled: { _ in
                XCTFail("Do not probe unrelated apps")
                return nil
            }, enable: { _ in
                XCTFail("Do not alter unrelated apps")
                return .failure
            }))
        }
    }

    func testFailedAccessibilityRequestCanRetryOnNextDictation() {
        var writes = 0
        for expected in [AXError.cannotComplete, .success] {
            let result = LiveTextApplicationCompatibility.requestAccessibility(bundleIdentifier: "com.openai.codex", readEnabled: { _ in false }, enable: { _ in
                writes += 1
                return writes == 1 ? .cannotComplete : .success
            })
            XCTAssertEqual(result, expected)
        }
        XCTAssertEqual(writes, 2)
    }

    func testT3EmptyComposerNewlineReconcilesThenStreamsAndRevises() async {
        let target = LiveTargetStub("\n", .init(location: 0, length: 0))
        target.bundleIdentifier = "com.t3tools.t3code"
        target.nextEditResult = .init(text: "So", selection: .init(location: 2, length: 0))
        let live = LiveTextInsertion(log: { _ in }, capture: { target }, wait: {})
        live.begin()
        for transcript in ["So", "So this streams", "So this works 🐴"] {
            let result = await live.update(transcript)
            XCTAssertEqual(result, .inserted)
            XCTAssertEqual(target.value.text, transcript)
        }
        XCTAssertEqual(target.edits.count, 3)
        XCTAssertEqual(target.edits[0].0, .init(location: 0, length: 0))
        let result = await live.finish("So this works 🐴.")
        XCTAssertEqual(result, .inserted)
        XCTAssertEqual(target.value.text, "So this works 🐴.")
    }

    func testT3ReconciliationDoesNotAcceptLostDraftsOrOtherApps() async {
        for (bundle, initial) in [("com.t3tools.t3code", "Existing draft"),
                                  ("com.t3tools.t3code", "\n\n"),
                                  ("com.t3tools.t3code", " "),
                                  ("other.editor", "\n")] {
            let target = LiveTargetStub(initial, .init(location: 0, length: 0))
            target.bundleIdentifier = bundle
            target.nextEditResult = .init(text: "So", selection: .init(location: 2, length: 0))
            let live = LiveTextInsertion(log: { _ in }, capture: { target }, wait: {})
            live.begin()
            let result = await live.update("So")
            XCTAssertEqual(result, .paused)
            XCTAssertEqual(live.pauseReason, .textNotConfirmed)
            _ = await live.finish("So this streams")
            XCTAssertEqual(target.edits.count, 1, "Never replay an uncertain insertion")
        }
    }

    func testTransientStartupCaptureFailureRetriesBeforeFirstSpeech() async {
        let target = LiveTargetStub("", NSRange(location: 0, length: 0))
        var captures = 0
        let live = LiveTextInsertion(log: { _ in }, capture: {
            captures += 1
            return captures >= 3 ? target : nil
        }, wait: {})
        live.begin()
        _ = await live.update("")
        XCTAssertEqual(captures, 1, "Empty audio updates must not repeatedly query AX")
        let result = await live.update("hello")
        XCTAssertEqual(result, .inserted)
        XCTAssertEqual(target.value.text, "hello")
        XCTAssertEqual(target.edits.count, 1)
    }

    func testUnsupportedCaptureRetryIsBoundedAndDoesNotRepeatOnEveryPartial() async {
        var captures = 0
        let live = LiveTextInsertion(log: { _ in }, capture: { captures += 1; return nil }, wait: {})
        live.begin()
        let first = await live.update("hello")
        let attempts = captures
        XCTAssertEqual(first, .unavailable)
        XCTAssertGreaterThan(attempts, 1)
        XCTAssertLessThanOrEqual(attempts, 12)
        _ = await live.update("hello there")
        XCTAssertEqual(captures, attempts)
    }

    func testCaptureCanRecoverOnLaterPartialWithoutRetryingEveryAudioChunk() async {
        let target = LiveTargetStub("", .init(location: 0, length: 0))
        var ready = false
        var clock: TimeInterval = 0
        var attempts = 0
        let live = LiveTextInsertion(log: { _ in }, capture: {
            attempts += 1
            return ready ? target : nil
        }, wait: {}, now: { clock })
        live.begin()
        let first = await live.update("hello")
        XCTAssertEqual(first, .unavailable)
        let initialAttempts = attempts
        ready = true
        for _ in 0..<100 { _ = await live.update("hello") }
        XCTAssertEqual(attempts, initialAttempts)
        clock = 0.3
        let recovered = await live.update("hello world")
        XCTAssertEqual(recovered, .inserted)
        XCTAssertEqual(target.value.text, "hello world")
        XCTAssertEqual(target.edits.count, 1)
    }

    func testCaptureRetryExpiresAndFinalizationCanRetryBeforeExpiry() async {
        var clock: TimeInterval = 0
        var ready: LiveTargetStub?
        let live = LiveTextInsertion(log: { _ in }, capture: { ready }, wait: {}, now: { clock })
        live.begin()
        _ = await live.update("hello")
        ready = LiveTargetStub("", .init(location: 0, length: 0))
        let final = await live.finish("hello world")
        XCTAssertEqual(final, .inserted)
        ready = nil
        live.begin()
        _ = await live.update("hello")
        clock = 11
        ready = LiveTargetStub("", .init(location: 0, length: 0))
        let expired = await live.finish("hello world")
        XCTAssertEqual(expired, .unavailable)
        XCTAssertTrue(ready!.edits.isEmpty)
    }

    func testInitialFocusRecoveryRequiresSameWindowAndNoInteraction() {
        var anchor = LiveCaptureAnchor(window: "window", field: nil, equal: ==)
        XCTAssertNil(anchor.resolve(sameApp: true, window: "window", field: nil, interacted: false))
        XCTAssertEqual(anchor.resolve(sameApp: true, window: "window", field: "field", interacted: false), "field")
        XCTAssertNil(anchor.resolve(sameApp: true, window: "window", field: "other", interacted: false))
        XCTAssertNil(anchor.resolve(sameApp: true, window: "window", field: "field", interacted: false))
        for (sameApp, window, interacted) in [(false, "window", false), (true, "other", false), (true, "window", true)] {
            var fresh = LiveCaptureAnchor(window: "window", field: nil, equal: ==)
            XCTAssertNil(fresh.resolve(sameApp: sameApp, window: window, field: "field", interacted: interacted))
            XCTAssertTrue(fresh.invalidated)
        }
        var unknownWindow = LiveCaptureAnchor<String>(window: nil, field: nil, equal: ==)
        XCTAssertNil(unknownWindow.resolve(sameApp: true, window: "window", field: "field", interacted: false))
    }

    func testCancelDuringCaptureRetryCannotCaptureIntoNewSession() async {
        var target: LiveTargetStub?
        let gate = TestGate()
        let live = LiveTextInsertion(log: { _ in }, capture: { target }, wait: { await gate.wait() })
        live.begin()
        let old = Task { await live.update("old") }
        await gate.waitUntilEntered()
        live.cancel()
        target = LiveTargetStub("", NSRange(location: 0, length: 0))
        live.begin()
        _ = await live.update("new")
        await gate.open()
        let oldResult = await old.value
        XCTAssertEqual(oldResult, .paused)
        XCTAssertEqual(target?.value.text, "new")
        XCTAssertEqual(target?.edits.count, 1)
    }

    func testTemporaryFocusedFieldReadFailureRecoversWithoutFreezingSpeech() async {
        let target = LiveTargetStub("", .init(location: 0, length: 0))
        let live = LiveTextInsertion(log: { _ in }, capture: { target }, wait: {})
        live.begin()
        _ = await live.update("hello")
        target.unavailableReason = .focusUnavailable
        target.unavailableSnapshots = 3
        let result = await live.update("hello there")
        XCTAssertEqual(result, .inserted)
        _ = await live.update("Hello world")
        XCTAssertEqual(target.value.text, "Hello world", "Temporary AX failure must not freeze already dictated text")
        XCTAssertNil(live.pauseReason)
    }

    func testTemporaryFocusedFieldFailureDuringVerificationDoesNotReplayEdit() async {
        let target = LiveTargetStub("", .init(location: 0, length: 0))
        target.unavailableReason = .focusUnavailable
        target.unavailableAfterEdit = 3
        let live = LiveTextInsertion(log: { _ in }, capture: { target }, wait: {})
        live.begin()
        let result = await live.update("hello")
        XCTAssertEqual(result, .inserted)
        XCTAssertEqual(target.edits.count, 1)
    }

    func testConfirmedFieldChangeStillPausesPermanently() async {
        let target = LiveTargetStub("", .init(location: 0, length: 0))
        let live = LiveTextInsertion(log: { _ in }, capture: { target }, wait: {})
        live.begin()
        _ = await live.update("hello")
        target.unavailableReason = .fieldChanged
        target.unavailableSnapshots = 1
        let result = await live.update("hello there")
        XCTAssertEqual(result, .paused)
        _ = await live.update("hello again")
        XCTAssertEqual(target.edits.count, 1)
        XCTAssertEqual(live.pauseReason, .fieldChanged)
    }

    func testUnchangedPartialsThrottleFieldReadsButChangedTextAndFinishAlwaysValidate() async {
        let target = LiveTargetStub("", .init(location: 0, length: 0))
        var clock: TimeInterval = 0
        let live = LiveTextInsertion(log: { _ in }, capture: { target }, wait: {}, now: { clock })
        live.begin()
        _ = await live.update("hello")
        let reads = target.snapshotReads
        for _ in 0..<100 { _ = await live.update("hello") }
        XCTAssertEqual(target.snapshotReads, reads)
        clock = 0.2
        _ = await live.update("hello")
        XCTAssertEqual(target.snapshotReads, reads + 1)
        target.value = .init(text: "HI", selection: .init(location: 2, length: 0))
        _ = await live.update("hello there")
        XCTAssertEqual(target.value.text, "HI there")
        target.unavailableReason = .fieldChanged
        target.unavailableSnapshots = 1
        let final = await live.finish("hello there")
        XCTAssertEqual(final, .paused, "Finalization must not claim delivery from a cached field read")
    }

    func testManualCorrectionIsPreservedWhileNewSpeechResumesAndRevises() async {
        let target = LiveTargetStub("", NSRange(location: 0, length: 0))
        let live = LiveTextInsertion(log: { _ in }, capture: { target }, wait: {})
        live.begin()
        _ = await live.update("hello")
        target.value = .init(text: "HELLO!", selection: NSRange(location: 6, length: 0))
        let resumed = await live.update("Hello there")
        XCTAssertEqual(resumed, .inserted)
        XCTAssertEqual(target.value.text, "HELLO! there")
        _ = await live.update("Hello world")
        XCTAssertEqual(target.value.text, "HELLO! world")
        XCTAssertEqual(target.edits.last?.0, NSRange(location: 7, length: 5))
        _ = await live.update("Hello world")
        XCTAssertEqual(target.edits.count, 3)
    }

    func testActiveSelectionWaitsThenResumesAtCollapsedCursor() async {
        let target = LiveTargetStub("", NSRange(location: 0, length: 0))
        let live = LiveTextInsertion(log: { _ in }, capture: { target }, wait: {})
        live.begin()
        _ = await live.update("hello")
        target.value = .init(text: "hello", selection: NSRange(location: 0, length: 5))
        _ = await live.update("hello there")
        XCTAssertEqual(target.edits.count, 1, "Do not overwrite the user's selection")
        target.value = .init(text: "HI", selection: NSRange(location: 2, length: 0))
        _ = await live.update("hello there")
        XCTAssertEqual(target.value.text, "HI there")
    }

    func testRecognizerCompletingCorrectedWordDoesNotAppendOrphanLetters() async {
        for (old, corrected, revised, expected) in [
            ("hello wor", "Hello Earth", "hello world again", "Hello Earth again"),
            ("I can", "I will", "I can't go", "I will go"),
            ("I can ", "I will", "I can't go", "I will go"),
            ("I can", "I will", "I can’t go", "I will go")
        ] {
            let target = LiveTargetStub("", NSRange(location: 0, length: 0))
            let live = LiveTextInsertion(log: { _ in }, capture: { target }, wait: {})
            live.begin()
            _ = await live.update(old)
            target.value = .init(text: corrected, selection: NSRange(location: corrected.utf16.count, length: 0))
            _ = await live.update(revised)
            XCTAssertEqual(target.value.text, expected)
            _ = await live.update(revised + " today")
            XCTAssertEqual(target.value.text, expected + " today")
        }
    }

    func testCancelDuringManualEditSettlingCannotAffectNewSession() async {
        let target = LiveTargetStub("", NSRange(location: 0, length: 0))
        let gate = TestGate()
        let live = LiveTextInsertion(log: { _ in }, capture: { target }, wait: { await gate.wait() })
        live.begin()
        _ = await live.update("hello")
        target.value = .init(text: "corrected", selection: NSRange(location: 9, length: 0))
        let old = Task { await live.update("hello there") }
        await gate.waitUntilEntered()
        live.cancel()
        live.begin()
        _ = await live.update(" new session")
        await gate.open()
        let result = await old.value
        XCTAssertEqual(result, .paused)
        XCTAssertEqual(target.value.text, "corrected new session")
    }

    func testTemporaryAccessibilityReadFailureDuringManualEditRecovers() async {
        let target = LiveTargetStub("", NSRange(location: 0, length: 0))
        let live = LiveTextInsertion(log: { _ in }, capture: { target }, wait: {})
        live.begin()
        _ = await live.update("hello")
        target.value = .init(text: "HI", selection: NSRange(location: 2, length: 0))
        target.unavailableSnapshots = 3
        let resumed = await live.update("hello there")
        XCTAssertEqual(resumed, .inserted)
        XCTAssertEqual(target.value.text, "HI there")
    }

    func testTemporaryReadFailureWithoutManualEditKeepsRecognizerRangeEditable() async {
        let target = LiveTargetStub("", NSRange(location: 0, length: 0))
        let live = LiveTextInsertion(log: { _ in }, capture: { target }, wait: {})
        live.begin()
        _ = await live.update("turn left")
        target.unavailableSnapshots = 3
        let revised = await live.update("turn right")
        XCTAssertEqual(revised, .inserted)
        XCTAssertEqual(target.value.text, "turn right")
    }

    func testCommittedWordCompletionAfterResumingDoesNotReviseManualCorrection() async {
        let target = LiveTargetStub("", NSRange(location: 0, length: 0))
        let live = LiveTextInsertion(log: { _ in }, capture: { target }, wait: {})
        live.begin()
        _ = await live.update("I can")
        target.value = .init(text: "I will", selection: NSRange(location: 6, length: 0))
        _ = await live.update("I can go")
        _ = await live.update("I can't go today")
        XCTAssertEqual(target.value.text, "I will go today")
    }

    func testRecognizerRevisionBeforeManualBoundaryDoesNotSwallowNewSpeech() async {
        for (old, revised, suffix) in [
            ("hello world", "hullo world again", " again"),
            ("hello.", "hello there", " there"),
            ("hello brave world", "hello world again", " again"),
            ("go go", "go go now", " now")
        ] {
            let target = LiveTargetStub("", NSRange(location: 0, length: 0))
            let live = LiveTextInsertion(log: { _ in }, capture: { target }, wait: {})
            live.begin()
            _ = await live.update(old)
            target.value = .init(text: "CORRECTED", selection: NSRange(location: 9, length: 0))
            let result = await live.update(revised)
            XCTAssertEqual(result, .inserted, old)
            XCTAssertEqual(target.value.text, "CORRECTED" + suffix, old)
        }
    }

    func testAmbiguousRecognizerRevisionPausesInsteadOfGuessingAtNewWords() async {
        let target = LiveTargetStub("", NSRange(location: 0, length: 0))
        let live = LiveTextInsertion(log: { _ in }, capture: { target }, wait: {})
        live.begin()
        _ = await live.update("go go")
        target.value = .init(text: "CORRECTED", selection: NSRange(location: 9, length: 0))
        let result = await live.finish("go now")
        XCTAssertEqual(result, .paused)
        XCTAssertEqual(live.pauseReason, .transcriptRevisionAmbiguous)
        XCTAssertEqual(target.value.text, "CORRECTED")
        XCTAssertEqual(target.edits.count, 1)
    }

    func testFinalSpeechDuringActiveSelectionIsReportedUndelivered() async {
        let target = LiveTargetStub("", NSRange(location: 0, length: 0))
        let live = LiveTextInsertion(log: { _ in }, capture: { target }, wait: {})
        live.begin()
        _ = await live.update("hello")
        target.value = .init(text: "hello", selection: NSRange(location: 0, length: 5))
        let result = await live.finish("hello there")
        XCTAssertEqual(result, .paused)
        XCTAssertEqual(target.value.text, "hello")
        XCTAssertEqual(target.edits.count, 1)
    }

    func testFinalSpeechIsDeliveredIfSelectionCollapsesDuringSettling() async {
        let target = LiveTargetStub("", NSRange(location: 0, length: 0))
        let gate = TestGate()
        let live = LiveTextInsertion(log: { _ in }, capture: { target }, wait: { await gate.wait() })
        live.begin()
        _ = await live.update("hello")
        target.value = .init(text: "hello", selection: NSRange(location: 0, length: 5))
        let finish = Task { await live.finish("hello there") }
        await gate.waitUntilEntered()
        target.value = .init(text: "HI", selection: NSRange(location: 2, length: 0))
        await gate.open()
        let result = await finish.value
        XCTAssertEqual(result, .inserted)
        XCTAssertEqual(target.value.text, "HI there")
    }

    func testCodexDecorationReportedAsRealTextIsReconciledOnlyAfterFirstInsertion() async {
        let target = LiveTargetStub("Ask anything", NSRange(location: 0, length: 0))
        target.reconcilesInitialPlaceholder = true
        target.nextEditResult = .init(text: "Testing", selection: NSRange(location: 7, length: 0))
        var diagnostics: [String] = []
        let live = LiveTextInsertion(log: { diagnostics.append($0) }, capture: { target }, wait: {})
        live.begin()
        for transcript in ["Testing", "Testing live dictation", "Testing live transcription 🐴"] {
            let result = await live.update(transcript)
            XCTAssertEqual(result, .inserted)
            XCTAssertEqual(target.value.text, transcript)
        }
        _ = await live.update("Testing live transcription 🐴")
        XCTAssertEqual(target.edits.count, 3)
        XCTAssertEqual(target.edits[0].0, NSRange(location: 0, length: 0))
        XCTAssertEqual(diagnostics.filter { $0.contains("reconciledInitialPlaceholder") }.count, 1)
        XCTAssertFalse(diagnostics.joined().contains("Ask anything"))
        XCTAssertFalse(diagnostics.joined().contains("Testing"))
    }

    func testInitialReconciliationRequiresOptInEmptySelectionExactTextAndCursor() async {
        let atStart = NSRange(location: 0, length: 0)
        let cases: [(Bool, NSRange, LiveTextSnapshot)] = [
            (false, atStart, .init(text: "Testing", selection: NSRange(location: 7, length: 0))),
            (true, NSRange(location: 1, length: 0), .init(text: "Testing", selection: NSRange(location: 7, length: 0))),
            (true, NSRange(location: 0, length: 1), .init(text: "Testing", selection: NSRange(location: 7, length: 0))),
            (true, atStart, .init(text: "Changed", selection: NSRange(location: 7, length: 0))),
            (true, atStart, .init(text: "Testing", selection: NSRange(location: 0, length: 0))),
            (true, atStart, .init(text: "Testing more", selection: NSRange(location: 7, length: 0)))
        ]
        for (optIn, selection, result) in cases {
            let target = LiveTargetStub("Ask anything", selection)
            target.reconcilesInitialPlaceholder = optIn
            target.nextEditResult = result
            let live = LiveTextInsertion(log: { _ in }, capture: { target }, wait: {})
            live.begin()
            let status = await live.update("Testing")
            XCTAssertEqual(status, .paused)
            _ = await live.update("Testing more")
            XCTAssertEqual(target.edits.count, 1)
        }
    }

    func testRevisingBackToEmptyDoesNotReenableInitialReconciliation() async {
        let target = LiveTargetStub("Existing", NSRange(location: 0, length: 0))
        target.reconcilesInitialPlaceholder = true
        let live = LiveTextInsertion(log: { _ in }, capture: { target }, wait: {})
        live.begin()
        _ = await live.update("hello")
        _ = await live.update("")
        XCTAssertEqual(target.value.text, "Existing")
        target.nextEditResult = .init(text: "new", selection: NSRange(location: 3, length: 0))
        let result = await live.update("new")
        XCTAssertEqual(result, .paused)
        XCTAssertEqual(live.pauseReason, .textNotConfirmed)
    }

    func testNewSessionCanReconcileAfterPreviousSessionAttemptedEdits() async {
        let target = LiveTargetStub("", NSRange(location: 0, length: 0))
        target.reconcilesInitialPlaceholder = true
        let live = LiveTextInsertion(log: { _ in }, capture: { target }, wait: {})
        live.begin()
        _ = await live.update("previous")
        live.cancel()
        target.value = .init(text: "Ask anything", selection: NSRange(location: 0, length: 0))
        target.nextEditResult = .init(text: "new", selection: NSRange(location: 3, length: 0))
        live.begin()
        let result = await live.update("new")
        XCTAssertEqual(result, .inserted)
    }

    func testPlaceholderBackedEmptyPromptAcceptsRepeatedUpdatesAndRevisions() async {
        let target = LiveTargetStub("", NSRange(location: 0, length: 0))
        target.accessibilityPlaceholder = "Ask anything"
        let live = LiveTextInsertion(log: { _ in }, capture: { target }, wait: {})
        live.begin()
        for transcript in ["Testing", "Testing live dictation", "Testing live transcription 🐴"] {
            let result = await live.update(transcript)
            XCTAssertEqual(result, .inserted)
            XCTAssertEqual(target.value.text, transcript)
            XCTAssertEqual(target.value.selection.location, transcript.utf16.count)
        }
        _ = await live.update("Testing live transcription 🐴")
        XCTAssertEqual(target.edits.count, 3)
    }

    func testEditableRangeExcludesPlaceholderEvenWithoutPlaceholderAttribute() {
        for placeholder: String? in [nil, "Ask anything"] {
            let content = LiveTextContent.read(value: "Ask anything", placeholder: placeholder,
                characterCount: { 0 }, stringForRange: { range in
                    XCTAssertEqual(range, NSRange(location: 0, length: 0))
                    return ""
                })
            XCTAssertEqual(content?.text, "")
            XCTAssertEqual(content?.source, "range")
        }
    }

    func testPlaceholderFallbackRequiresExplicitZeroCharacterCount() {
        for count: Int? in [nil, 0, 12] {
            let content = LiveTextContent.read(value: "Ask anything", placeholder: "Ask anything",
                characterCount: { count }, stringForRange: { _ in nil })
            XCTAssertEqual(content?.text, count == 0 ? "" : "Ask anything")
        }
        XCTAssertNil(LiveTextContent.read(value: "Actual draft", placeholder: "Ask anything",
            characterCount: { 0 }, stringForRange: { _ in nil }))
    }

    func testRealPromptEqualToPlaceholderIsPreservedDuringInsertion() async {
        let target = LiveTargetStub("Ask anything", NSRange(location: 0, length: 0))
        target.accessibilityPlaceholder = "Ask anything"
        let live = LiveTextInsertion(log: { _ in }, capture: { target })
        live.begin()
        let result = await live.update("Please ")
        XCTAssertEqual(result, .inserted)
        XCTAssertEqual(target.value.text, "Please Ask anything")
    }

    func testEditableRangeSupportsUTF16AndMissingValueAttribute() {
        let text = "🐴 e\u{301}"
        let content = LiveTextContent.read(value: nil, placeholder: nil,
            characterCount: { text.utf16.count }, stringForRange: { range in
                XCTAssertEqual(range.length, text.utf16.count)
                return text
            })
        XCTAssertEqual(content?.text, text)
    }

    func testInconsistentRangeFeedbackDoesNotFallBackToPossiblyStaleValue() {
        XCTAssertNil(LiveTextContent.read(value: "hello", placeholder: nil,
            characterCount: { 5 }, stringForRange: { _ in "hell" }))
        var reads = 0
        XCTAssertNil(LiveTextContent.read(value: "hello", placeholder: nil,
            characterCount: { reads += 1; return reads == 1 ? 5 : 6 }, stringForRange: { _ in "hello" }))
    }

    func testValueOnlyEditorsRemainSupportedAndInvalidCountsAreRejected() {
        for count: Int? in [nil, 5] {
            XCTAssertEqual(LiveTextContent.read(value: "hello", placeholder: nil,
                characterCount: { count }, stringForRange: { _ in nil })?.text, "hello")
        }
        for count in [-1, LiveTextContent.maximumLength + 1] {
            XCTAssertNil(LiveTextContent.read(value: "hello", placeholder: nil,
                characterCount: { count }, stringForRange: { _ in XCTFail("Invalid range must not be requested"); return nil }))
        }
    }

    func testUpdatesAtCursorRevisesOnlyDictatedTextAndDoesNotDuplicateFinal() async {
        let target = LiveTargetStub("Before  after", NSRange(location: 7, length: 0))
        let live = LiveTextInsertion(capture: { target })
        live.begin()
        let first = await live.update("hello world")
        XCTAssertEqual(first, .inserted)
        XCTAssertEqual(target.value.text, "Before hello world after")
        _ = await live.update("hello there!")
        XCTAssertEqual(target.edits.last?.0, NSRange(location: 13, length: 5))
        XCTAssertEqual(target.value.text, "Before hello there! after")
        _ = await live.update("hello there!")
        XCTAssertEqual(target.edits.count, 2)
    }

    func testSelectedTextReplacedOnceAndFinalShorteningPreservesSurroundings() async {
        let target = LiveTargetStub("abc OLD xyz", NSRange(location: 4, length: 3))
        let live = LiveTextInsertion(capture: { target })
        live.begin()
        _ = await live.update("replacement")
        _ = await live.update("replace")
        XCTAssertEqual(target.value.text, "abc replace xyz")
        XCTAssertEqual(target.value.selection, NSRange(location: 11, length: 0))
    }

    func testUnicodeRevisionUsesUTF16RangesWithoutSplittingGraphemes() async {
        let target = LiveTargetStub("🐴: !", NSRange(location: 4, length: 0))
        let live = LiveTextInsertion(capture: { target })
        live.begin()
        _ = await live.update("cafe\u{301} 🐴")
        _ = await live.update("cafè 🐎")
        XCTAssertEqual(target.value.text, "🐴: cafè 🐎!")
        XCTAssertEqual(target.edits.last?.0.location, 7)
        XCTAssertEqual(target.value.selection.location, 11)
    }

    func testNormalizationRevisionUsesExactUTF16Prefix() async {
        let target = LiveTargetStub("", NSRange(location: 0, length: 0))
        let live = LiveTextInsertion(capture: { target })
        live.begin()
        _ = await live.update("é")
        let result = await live.update("e\u{301}x")
        XCTAssertEqual(result, .inserted)
        XCTAssertEqual(Array(target.value.text.utf16), Array("e\u{301}x".utf16))
        XCTAssertEqual(target.value.selection, NSRange(location: 3, length: 0))
        let normalized = await live.update("éx")
        XCTAssertEqual(normalized, .inserted)
        XCTAssertEqual(target.value.selection, NSRange(location: 2, length: 0))
    }

    func testCanonicallyEqualManualEditReanchorsWithoutUsingStaleUTF16Ranges() async {
        let target = LiveTargetStub("é", NSRange(location: 0, length: 0))
        let live = LiveTextInsertion(capture: { target }, wait: {})
        live.begin()
        target.value = .init(text: "e\u{301}", selection: NSRange(location: 0, length: 0))
        let result = await live.update("hello")
        XCTAssertEqual(result, .inserted)
        XCTAssertEqual(Array(target.value.text.utf16), Array("helloe\u{301}".utf16))
    }

    func testCursorMoveResumesAtNewCursorWithoutReplayingOldSpeech() async {
        let target = LiveTargetStub("", NSRange(location: 0, length: 0))
        let live = LiveTextInsertion(capture: { target })
        live.begin()
        _ = await live.update("hello")
        target.value = .init(text: "hello", selection: NSRange(location: 1, length: 0))
        let moved = await live.update("hello world")
        XCTAssertEqual(moved, .inserted)
        XCTAssertEqual(target.value.text, "h worldello")
        let final = await live.update("hello world!")
        XCTAssertEqual(final, .inserted)
        XCTAssertEqual(target.value.text, "h world!ello")
        XCTAssertEqual(target.edits.count, 3)
    }

    func testUserEditResumesButFocusLossDoesNotInsertElsewhere() async {
        for losesFocus in [false, true] {
            let target = LiveTargetStub("", NSRange(location: 0, length: 0))
            let live = LiveTextInsertion(capture: { target })
            live.begin()
            _ = await live.update("hello")
            if losesFocus { target.focused = false }
            else { target.value = .init(text: "HELLO", selection: NSRange(location: 5, length: 0)) }
            let result = await live.update("hello there")
            XCTAssertEqual(result, losesFocus ? .paused : .inserted)
            XCTAssertEqual(target.edits.count, losesFocus ? 1 : 2)
            if !losesFocus { XCTAssertEqual(target.value.text, "HELLO there") }
        }
    }

    func testUnsupportedTargetFallsBackButUnverifiedDispatchNeverDoes() async {
        let unavailable = LiveTextInsertion(capture: { nil })
        unavailable.begin()
        let noTarget = await unavailable.update("hello")
        XCTAssertEqual(noTarget, .unavailable)
        let target = LiveTargetStub("", NSRange(location: 0, length: 0))
        target.acceptEdits = false
        let live = LiveTextInsertion(capture: { target }, wait: {})
        live.begin()
        let first = await live.update("hello")
        XCTAssertEqual(first, .paused)
        let final = await live.update("hello world")
        XCTAssertEqual(final, .paused)
        XCTAssertEqual(target.edits.count, 1)
    }

    func testFailedDispatchPausesAndNextSessionStartsFresh() async {
        let target = LiveTargetStub("", NSRange(location: 0, length: 0))
        target.dispatchSucceeds = false
        let live = LiveTextInsertion(capture: { target })
        live.begin()
        let result = await live.update("hello")
        XCTAssertEqual(result, .paused)
        live.cancel()
        target.dispatchSucceeds = true
        live.begin()
        _ = await live.update("new")
        XCTAssertEqual(target.value.text, "new")
    }

    func testCancelDuringVerificationCannotMutateNewSession() async {
        let target = LiveTargetStub("", NSRange(location: 0, length: 0))
        target.acceptEdits = false
        let gate = TestGate()
        let live = LiveTextInsertion(capture: { target }, wait: { await gate.wait() })
        live.begin()
        let old = Task { await live.update("old") }
        await gate.waitUntilEntered()
        live.cancel()
        target.acceptEdits = true
        live.begin()
        _ = await live.update("new")
        await gate.open()
        let result = await old.value
        XCTAssertEqual(result, .paused)
        _ = await live.update("new session")
        XCTAssertEqual(target.value.text, "new session")
    }

    func testDelayedTextAndSelectionFeedbackDoesNotReplayOrPause() async {
        let target = LiveTargetStub("", NSRange(location: 0, length: 0))
        target.textDelay = 15
        target.selectionDelay = 8
        let live = LiveTextInsertion(log: { _ in }, capture: { target }, wait: {})
        live.begin()
        let result = await live.update("hello")
        XCTAssertEqual(result, .inserted)
        XCTAssertNil(live.pauseReason)
        XCTAssertEqual(target.edits.count, 1)
        _ = await live.update("hello world")
        XCTAssertEqual(target.value.text, "hello world")
        XCTAssertEqual(target.edits.count, 2)
    }

    func testUnconfirmedEditReportsSpecificReasonWithoutLeakingText() async {
        let target = LiveTargetStub("PRIVATE PROMPT", NSRange(location: 14, length: 0))
        target.acceptEdits = false
        var diagnostics: [String] = []
        let live = LiveTextInsertion(log: { diagnostics.append($0) }, capture: { target }, wait: {})
        live.begin()
        let result = await live.update("SECRET TRANSCRIPT")
        XCTAssertEqual(result, .paused)
        XCTAssertEqual(live.pauseReason, .textNotConfirmed)
        let pauses = diagnostics.filter { $0.contains("reason=") }
        XCTAssertEqual(pauses.count, 1)
        XCTAssertTrue(pauses[0].contains("reason=textNotConfirmed"))
        XCTAssertFalse(diagnostics.joined().contains("PRIVATE"))
        XCTAssertFalse(diagnostics.joined().contains("SECRET"))
        _ = await live.update("more")
        XCTAssertEqual(target.edits.count, 1)
        XCTAssertEqual(diagnostics.filter { $0.contains("reason=") }.count, 1)
    }

    func testUnconfirmedCursorIsDistinctFromUnconfirmedText() async {
        let target = LiveTargetStub("", NSRange(location: 0, length: 0))
        target.selectionDelay = 100
        let live = LiveTextInsertion(log: { _ in }, capture: { target }, wait: {})
        live.begin()
        let result = await live.update("hello")
        XCTAssertEqual(result, .paused)
        XCTAssertEqual(live.pauseReason, .selectionNotConfirmed)
    }

    func testCursorChangeBeforeFirstSpeechUsesCurrentInsertionPoint() async {
        let target = LiveTargetStub("abc", NSRange(location: 3, length: 0))
        let live = LiveTextInsertion(log: { _ in }, capture: { target })
        live.begin()
        target.value = .init(text: "abc", selection: NSRange(location: 0, length: 0))
        _ = await live.update("hello")
        XCTAssertNil(live.pauseReason)
        XCTAssertEqual(target.value.text, "helloabc")
        live.cancel()
        XCTAssertNil(live.pauseReason)
    }

    func testLiveInsertionSettingDefaultsOnAndPersistsOptOut() {
        let suite = "LiveTextInsertionTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.liveStreamingInsertion)
        settings.liveStreamingInsertion = false
        XCTAssertFalse(AppSettings(defaults: defaults).liveStreamingInsertion)
    }
}

@MainActor
private final class LiveTargetStub: LiveTextTarget {
    var snapshotFailure: LiveInsertionPauseReason?
    var snapshotReads = 0
    var unavailableSnapshots = 0
    var unavailableAfterEdit = 0
    var unavailableReason: LiveInsertionPauseReason = .textUnavailable
    var value: LiveTextSnapshot
    var focused = true
    var acceptEdits = true
    var dispatchSucceeds = true
    var edits: [(NSRange, String)] = []
    var textDelay = 0
    var selectionDelay = 0
    var pending: LiveTextSnapshot?
    var accessibilityPlaceholder: String?
    var reconcilesInitialPlaceholder = false
    var bundleIdentifier: String?
    func canReconcileInitialPlaceholder(_ text: String) -> Bool {
        if let bundleIdentifier {
            return LiveTextApplicationCompatibility.canReconcileInitialPlaceholder(text, bundleIdentifier: bundleIdentifier)
        }
        return reconcilesInitialPlaceholder
    }
    var nextEditResult: LiveTextSnapshot?
    init(_ text: String, _ selection: NSRange) { value = .init(text: text, selection: selection) }
    func snapshot() -> LiveTextSnapshot? {
        snapshotReads += 1
        snapshotFailure = nil
        if unavailableSnapshots > 0 {
            unavailableSnapshots -= 1
            snapshotFailure = unavailableReason
            return nil
        }
        if let pending {
            if textDelay > 0 { textDelay -= 1 }
            else if selectionDelay > 0 {
                value = .init(text: pending.text, selection: value.selection)
                selectionDelay -= 1
            } else { value = pending; self.pending = nil }
        }
        guard focused else { return nil }
        if let placeholder = accessibilityPlaceholder {
            guard let content = LiveTextContent.read(value: value.text.isEmpty ? placeholder : value.text,
                placeholder: placeholder, characterCount: { self.value.text.utf16.count },
                stringForRange: { _ in self.value.text }) else { return nil }
            return LiveTextSnapshot(text: content.text, selection: value.selection)
        }
        return value
    }
    var beforeReplace: (() async -> Void)?
    func replace(range: NSRange, with text: String, expected: LiveTextSnapshot,
                 canDeliver: @MainActor () -> Bool) async -> Bool {
        await beforeReplace?()
        guard canDeliver(), value == expected else { return false }
        edits.append((range, text))
        unavailableSnapshots = unavailableAfterEdit
        if dispatchSucceeds && acceptEdits {
            if let nextEditResult {
                value = nextEditResult
                self.nextEditResult = nil
                return true
            }
            let next = LiveTextSnapshot(text: (value.text as NSString).replacingCharacters(in: range, with: text),
                                        selection: NSRange(location: range.location + text.utf16.count, length: 0))
            if textDelay > 0 || selectionDelay > 0 { pending = next }
            else { value = next }
        }
        return dispatchSucceeds
    }
}
