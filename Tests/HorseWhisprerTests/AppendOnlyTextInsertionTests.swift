import XCTest
@testable import HorseWhisprer

@MainActor
final class AppendOnlyTextInsertionTests: XCTestCase {
    func testStableWordsWaitThenFinalFlushDoesNotDuplicate() async {
        let f = Fixture()
        await f.update("hello world")
        await f.update("hello world")
        XCTAssertTrue(f.target.additions.isEmpty)
        f.time += 0.3
        await f.update("hello world")
        XCTAssertEqual(f.target.additions, ["hello "])
        let result = await f.inserter.finish("hello world.")
        XCTAssertEqual(result, .inserted)
        XCTAssertEqual(f.target.additions, ["hello ", "world."])
    }

    func testContinuouslyGrowingPartialsDoNotStarveLiveInsertion() async {
        let f = Fixture()
        await f.update("one two")
        f.time = 0.1
        await f.update("one two three")
        f.time = 0.2
        await f.update("one two three four")
        f.time = 0.3
        await f.update("one two three four five")
        f.time = 0.4
        await f.update("one two three four five six")
        XCTAssertEqual(f.target.additions, ["one "])
        let result = await f.inserter.finish("one two three four five six")
        XCTAssertEqual(result, .inserted)
        XCTAssertEqual(f.target.additions.joined(), "one two three four five six")
    }

    func testCommittedASRRevisionDoesNotDeleteOrReplayEarlierWords() async {
        let f = Fixture()
        await f.stabilize("hello world")
        await f.stabilize("Hello wonderful world")
        let result = await f.inserter.finish("Hello wonderful world!")
        XCTAssertEqual(result, .inserted)
        XCTAssertEqual(f.target.additions.joined(), "hello wonderful world!")
    }

    func testHandTypingFreezesRecognizedSpeechAndResumesAtSettledCursor() async {
        let f = Fixture()
        await f.stabilize("hello world")
        f.target.interaction += 1
        f.target.quiet = false
        await f.update("hello world")
        XCTAssertEqual(f.target.additions, ["hello "])
        f.target.quiet = true
        await f.stabilize("hello world new words")
        let result = await f.inserter.finish("hello world new words")
        XCTAssertEqual(result, .inserted)
        XCTAssertEqual(f.target.additions.joined(), "hello  new words")
    }

    func testSelectionIsNeverOverwrittenAndFinalizationDoesNotPaste() async {
        let f = Fixture()
        f.target.collapsed = false
        await f.stabilize("keep my selection")
        XCTAssertTrue(f.target.additions.isEmpty)
        let result = await f.inserter.finish("keep my selection")
        XCTAssertEqual(result, .paused)
        XCTAssertEqual(f.inserter.pauseReason, .selectionChanged)
    }

    func testTemporaryFocusReadFailureResumesWithoutReplaying() async {
        let f = Fixture()
        await f.stabilize("hello world")
        f.target.failure = .focusUnavailable
        await f.update("hello world again")
        XCTAssertEqual(f.target.additions, ["hello "])
        f.target.failure = nil
        let result = await f.inserter.finish("hello world again")
        XCTAssertEqual(result, .inserted)
        XCTAssertEqual(f.target.additions.joined(), "hello world again")
    }

    func testPositiveFocusChangePermanentlyPauses() async {
        let f = Fixture()
        f.target.failure = .fieldChanged
        let first = await f.inserter.update("hello")
        XCTAssertEqual(first, .paused)
        f.target.failure = nil
        let final = await f.inserter.finish("hello world")
        XCTAssertEqual(final, .paused)
        XCTAssertTrue(f.target.additions.isEmpty)
    }

    func testDispatchFailureNeverRetriesPotentiallyDeliveredText() async {
        let f = Fixture()
        f.target.accepts = false
        let first = await f.inserter.finish("hello")
        XCTAssertEqual(first, .paused)
        f.target.accepts = true
        let second = await f.inserter.finish("hello world")
        XCTAssertEqual(second, .paused)
        XCTAssertEqual(f.target.additions, ["hello"])
    }

    func testUnavailableCaptureAllowsFinalInsertionAndCancelReleasesTarget() async {
        let missing = AppendOnlyTextInsertion(capture: { nil })
        missing.begin()
        let result = await missing.finish("hello")
        XCTAssertEqual(result, .unavailable)
        let f = Fixture()
        f.inserter.cancel()
        XCTAssertEqual(f.target.cancels, 1)
        let cancelled = await f.inserter.finish("hello")
        XCTAssertEqual(cancelled, .unavailable)
        XCTAssertTrue(f.target.additions.isEmpty)
    }

    func testRejectedCapturedTargetIsCancelled() async {
        let target = AppendTarget()
        target.collapsed = false
        let inserter = AppendOnlyTextInsertion(capture: { target })
        inserter.begin()
        XCTAssertEqual(target.cancels, 1)
        let result = await inserter.finish("hello")
        XCTAssertEqual(result, .unavailable)
    }

    func testNoneditingInputSettlesWithoutConsumingHeldSpeech() async {
        let f = Fixture()
        await f.stabilize("hello world")
        // Scroll/Copy only change the quiet timer, not the edit generation.
        if AppendInputPolicy.isCorrection(type: .scrollWheel) { f.target.interaction += 1 }
        if AppendInputPolicy.isCorrection(type: .keyDown, modifiers: .command, keyCode: 8) { f.target.interaction += 1 }
        f.target.quiet = false
        await f.update("hello world")
        f.target.quiet = true
        let result = await f.inserter.finish("hello world")
        XCTAssertEqual(result, .inserted)
        XCTAssertEqual(f.target.additions.joined(), "hello world")
    }

    func testUnicodeWordsAreNeverSplit() async {
        let f = Fixture()
        await f.stabilize("👨‍👩‍👧‍👦 café encore")
        let result = await f.inserter.finish("👨‍👩‍👧‍👦 café encore")
        XCTAssertEqual(result, .inserted)
        XCTAssertEqual(f.target.additions, ["👨‍👩‍👧‍👦 café ", "encore"])
    }
}

@MainActor
private final class Fixture {
    var time: TimeInterval = 0
    let target = AppendTarget()
    lazy var inserter = AppendOnlyTextInsertion(capture: { [target] in target }, now: { [unowned self] in time })
    init() { inserter.begin() }
    func update(_ text: String) async { _ = await inserter.update(text) }
    func stabilize(_ text: String) async {
        await update(text)
        await update(text)
        time += 0.3
        await update(text)
    }
}

@MainActor
private final class AppendTarget: AppendTextTarget {
    var failure: LiveInsertionPauseReason?
    var interaction = 0
    var quiet = true
    var collapsed = true
    var accepts = true
    var additions: [String] = []
    var cancels = 0
    func state() -> AppendTextState? {
        guard failure == nil else { return nil }
        return .init(interaction: interaction, isQuiet: quiet, cursorIsCollapsed: collapsed)
    }
    func append(_ text: String) -> Bool { additions.append(text); return accepts }
    func cancel() { cancels += 1 }
}
