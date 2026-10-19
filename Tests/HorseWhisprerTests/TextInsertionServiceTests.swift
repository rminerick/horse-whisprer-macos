import AppKit
import XCTest
@testable import HorseWhisprer

final class TextInsertionServiceTests: XCTestCase {
    @MainActor
    func testOverlappingPastesRestoreOriginalClipboard() async {
        let pasteboard = PasteboardSpy()
        pasteboard.copy(text: "original clipboard")
        let gate = TestGate()
        let restored = expectation(description: "Clipboard restored")
        pasteboard.onRestore = { restored.fulfill() }
        let service = TextInsertionService(
            frontmostApplicationProvider: { nil }, pasteboard: pasteboard,
            eventDispatcher: EventDispatcherSpy(), diagnostics: InsertionDiagnosticsSpy(),
            sleep: { _ in await gate.wait() }, observeWorkspaceNotifications: false)

        _ = await service.insert(text: "first transcript", behavior: .pasteThenType)
        _ = await service.insert(text: "second transcript", behavior: .pasteThenType)
        _ = await service.insert(text: "third transcript", behavior: .pasteThenType)
        await gate.open()
        await fulfillment(of: [restored], timeout: 2)
        XCTAssertEqual(pasteboard.currentString, "original clipboard")
    }

    @MainActor
    func testUserCopyBetweenOverlappingPastesBecomesNewBackup() async {
        let pasteboard = PasteboardSpy()
        pasteboard.copy(text: "original clipboard")
        let gate = TestGate()
        let restored = expectation(description: "Clipboard restored")
        pasteboard.onRestore = { restored.fulfill() }
        let service = TextInsertionService(
            frontmostApplicationProvider: { nil }, pasteboard: pasteboard,
            eventDispatcher: EventDispatcherSpy(), diagnostics: InsertionDiagnosticsSpy(),
            sleep: { _ in await gate.wait() }, observeWorkspaceNotifications: false)

        _ = await service.insert(text: "first transcript", behavior: .pasteThenType)
        pasteboard.copy(text: "new user copy")
        _ = await service.insert(text: "second transcript", behavior: .pasteThenType)
        await gate.open()
        await fulfillment(of: [restored], timeout: 2)
        XCTAssertEqual(pasteboard.currentString, "new user copy")
    }

    @MainActor
    func testCopyOnlyDuringPendingPasteIsNotRestoredAway() async {
        let pasteboard = PasteboardSpy()
        pasteboard.copy(text: "original clipboard")
        let gate = TestGate()
        let restored = expectation(description: "Do not overwrite deliberate copy")
        restored.isInverted = true
        pasteboard.onRestore = { restored.fulfill() }
        let service = TextInsertionService(
            frontmostApplicationProvider: { nil }, pasteboard: pasteboard,
            eventDispatcher: EventDispatcherSpy(), diagnostics: InsertionDiagnosticsSpy(),
            sleep: { _ in await gate.wait() }, observeWorkspaceNotifications: false)

        _ = await service.insert(text: "temporary transcript", behavior: .pasteThenType)
        await gate.waitUntilEntered()
        _ = await service.insert(text: "keep this copy", behavior: .copyOnly)
        await gate.open()
        await fulfillment(of: [restored], timeout: 0.1)
        XCTAssertEqual(pasteboard.currentString, "keep this copy")
    }

    @MainActor
    func testWorkspaceActivationUpdatesTarget() async {
        let workspace = NSWorkspace.shared
        let application = NSRunningApplication.current
        let service = TextInsertionService(
            workspace: workspace,
            ownBundleIdentifier: "test.different-app",
            frontmostApplicationProvider: { nil },
            diagnostics: InsertionDiagnosticsSpy()
        )
        workspace.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification,
                                         object: workspace,
                                         userInfo: [NSWorkspace.applicationUserInfoKey: application])
        for _ in 0..<100 where service.currentTargetName == nil { await Task.yield() }
        XCTAssertEqual(service.currentTargetName, application.localizedName ?? application.bundleIdentifier)
    }

    @MainActor
    func testCapturingBeforePopoverActivationRestoresNewTarget() async {
        let frontmost = FrontmostApplicationProvider()
        let old = ApplicationSpy(name: "Old", bundleIdentifier: "test.old")
        let current = ApplicationSpy(name: "Current", bundleIdentifier: "test.current")
        let own = ApplicationSpy(name: "Horse", bundleIdentifier: "test.horse")
        frontmost.application = old.application
        let service = TextInsertionService(
            ownBundleIdentifier: "test.horse", frontmostApplicationProvider: { frontmost.application },
            diagnostics: InsertionDiagnosticsSpy(), sleep: { _ in }, observeWorkspaceNotifications: false)
        frontmost.application = current.application
        service.captureInsertionTarget()
        frontmost.application = own.application
        await service.returnFocusToTarget()
        XCTAssertEqual(current.activationCount, 1)
        XCTAssertEqual(old.activationCount, 0)
    }

    @MainActor
    func testOwnTextFieldTargetSkipsRestoringPreviousApp() async {
        let frontmost = FrontmostApplicationProvider()
        let target = ApplicationSpy(name: "Supacode", bundleIdentifier: "com.supacode.app")
        let ownApp = ApplicationSpy(name: "Horse Whisprer", bundleIdentifier: "com.rminerick.HorseWhisprer")
        frontmost.application = target.application

        let service = TextInsertionService(
            ownBundleIdentifier: "com.rminerick.HorseWhisprer",
            frontmostApplicationProvider: { frontmost.application },
            pasteboard: PasteboardSpy(),
            eventDispatcher: EventDispatcherSpy(),
            diagnostics: InsertionDiagnosticsSpy(),
            sleep: { _ in },
            observeWorkspaceNotifications: false
        )
        service.ownTextTargetProvider = { true }

        frontmost.application = ownApp.application
        service.captureInsertionTarget()
        XCTAssertEqual(service.currentTargetName, "Horse Whisprer")

        let outcome = await service.insert(text: "test", behavior: InsertBehavior.pasteThenType)
        XCTAssertEqual(outcome, InsertionOutcome.pasted)
        XCTAssertEqual(target.activationCount, 0)

        // Only that one session targets our own window; the next goes back to the previous app.
        _ = await service.insert(text: "again", behavior: InsertBehavior.pasteThenType)
        XCTAssertEqual(target.activationCount, 1)
    }

    @MainActor
    func testRestoringDifferentTargetWaitsForFocusSettle() async {
        let frontmost = FrontmostApplicationProvider()
        let target = ApplicationSpy(name: "Supacode", bundleIdentifier: "com.supacode.app")
        let otherApp = ApplicationSpy(name: "Horse Whisprer", bundleIdentifier: "com.rminerick.HorseWhisprer")
        let pasteboard = PasteboardSpy()
        let dispatcher = EventDispatcherSpy()
        let diagnostics = InsertionDiagnosticsSpy()
        let sleeper = SleepSpy()
        frontmost.application = target.application

        let service = TextInsertionService(
            ownBundleIdentifier: "com.rminerick.HorseWhisprer",
            frontmostApplicationProvider: { frontmost.application },
            pasteboard: pasteboard,
            eventDispatcher: dispatcher,
            diagnostics: diagnostics,
            sleep: { [sleeper] delay in
                await sleeper.sleep(delay: delay)
            },
            observeWorkspaceNotifications: false
        )

        frontmost.application = otherApp.application
        service.captureInsertionTarget()

        let outcome = await service.insert(text: "test", behavior: InsertBehavior.pasteThenType)

        XCTAssertEqual(outcome, InsertionOutcome.pasted)
        let recordedInvocations = await sleeper.recordedInvocations()

        XCTAssertEqual(target.activationCount, 1)
        XCTAssertEqual(recordedInvocations, [100_000_000])
        XCTAssertEqual(diagnostics.records.last?.restoreAttempted, true)
        XCTAssertEqual(diagnostics.records.last?.waitedForFocusSettle, true)
        XCTAssertEqual(diagnostics.records.last?.focusSettleDelayMilliseconds, 100)
    }

    @MainActor
    func testAlreadyFrontmostTargetSkipsFocusSettleDelay() async {
        let frontmost = FrontmostApplicationProvider()
        let target = ApplicationSpy(name: "Supacode", bundleIdentifier: "com.supacode.app")
        let pasteboard = PasteboardSpy()
        let dispatcher = EventDispatcherSpy()
        let diagnostics = InsertionDiagnosticsSpy()
        let sleeper = SleepSpy()
        frontmost.application = target.application

        let service = TextInsertionService(
            ownBundleIdentifier: "com.rminerick.HorseWhisprer",
            frontmostApplicationProvider: { frontmost.application },
            pasteboard: pasteboard,
            eventDispatcher: dispatcher,
            diagnostics: diagnostics,
            sleep: { [sleeper] delay in
                await sleeper.sleep(delay: delay)
            },
            observeWorkspaceNotifications: false
        )

        service.captureInsertionTarget()
        let outcome = await service.insert(text: "test", behavior: InsertBehavior.pasteThenType)

        XCTAssertEqual(outcome, InsertionOutcome.pasted)
        let recordedInvocations = await sleeper.recordedInvocations()

        XCTAssertEqual(target.activationCount, 0)
        XCTAssertTrue(recordedInvocations.isEmpty)
        XCTAssertEqual(diagnostics.records.last?.restoreAttempted, false)
        XCTAssertEqual(diagnostics.records.last?.waitedForFocusSettle, false)
    }

    @MainActor
    func testPasteDispatchFailureFallsBackToTyping() async {
        let frontmost = FrontmostApplicationProvider()
        let target = ApplicationSpy(name: "Supacode", bundleIdentifier: "com.supacode.app")
        let pasteboard = PasteboardSpy()
        let dispatcher = EventDispatcherSpy()
        let diagnostics = InsertionDiagnosticsSpy()
        frontmost.application = target.application
        dispatcher.pasteResult = PasteDispatchResult(sourceCreated: true, eventsCreated: false, posted: false)
        dispatcher.typeResults = [true]

        let service = TextInsertionService(
            ownBundleIdentifier: "com.rminerick.HorseWhisprer",
            frontmostApplicationProvider: { frontmost.application },
            pasteboard: pasteboard,
            eventDispatcher: dispatcher,
            diagnostics: diagnostics,
            sleep: { _ in },
            observeWorkspaceNotifications: false
        )

        service.captureInsertionTarget()
        let outcome = await service.insert(text: "test", behavior: InsertBehavior.pasteThenType)

        XCTAssertEqual(outcome, InsertionOutcome.typed)
        XCTAssertEqual(dispatcher.typeCallCount, 1)
        XCTAssertEqual(diagnostics.records.last?.finalPath, .typedFallbackUsed)
        XCTAssertEqual(diagnostics.records.last?.pasteEventPosted, false)
        XCTAssertEqual(diagnostics.records.last?.typingAttempted, true)
    }

    @MainActor
    func testPostedPasteDoesNotTriggerTypedFallback() async {
        let frontmost = FrontmostApplicationProvider()
        let target = ApplicationSpy(name: "Supacode", bundleIdentifier: "com.supacode.app")
        let pasteboard = PasteboardSpy()
        let dispatcher = EventDispatcherSpy()
        let diagnostics = InsertionDiagnosticsSpy()
        frontmost.application = target.application
        dispatcher.pasteResult = PasteDispatchResult(sourceCreated: true, eventsCreated: true, posted: true)

        let service = TextInsertionService(
            ownBundleIdentifier: "com.rminerick.HorseWhisprer",
            frontmostApplicationProvider: { frontmost.application },
            pasteboard: pasteboard,
            eventDispatcher: dispatcher,
            diagnostics: diagnostics,
            sleep: { _ in },
            observeWorkspaceNotifications: false
        )

        service.captureInsertionTarget()
        let outcome = await service.insert(text: "test", behavior: InsertBehavior.pasteThenType)

        XCTAssertEqual(outcome, InsertionOutcome.pasted)
        XCTAssertEqual(dispatcher.typeCallCount, 0)
        XCTAssertEqual(diagnostics.records.last?.finalPath, .pasteCommandPosted)
        XCTAssertEqual(diagnostics.records.last?.pasteEventPosted, true)
        XCTAssertEqual(diagnostics.records.last?.typingAttempted, false)
    }

    @MainActor
    func testCopyOnlyRecordsCopiedPath() async {
        let frontmost = FrontmostApplicationProvider()
        let target = ApplicationSpy(name: "Supacode", bundleIdentifier: "com.supacode.app")
        let pasteboard = PasteboardSpy()
        let dispatcher = EventDispatcherSpy()
        let diagnostics = InsertionDiagnosticsSpy()
        frontmost.application = target.application

        let service = TextInsertionService(
            ownBundleIdentifier: "com.rminerick.HorseWhisprer",
            frontmostApplicationProvider: { frontmost.application },
            pasteboard: pasteboard,
            eventDispatcher: dispatcher,
            diagnostics: diagnostics,
            sleep: { _ in },
            observeWorkspaceNotifications: false
        )

        service.captureInsertionTarget()
        let outcome = await service.insert(text: "test", behavior: InsertBehavior.copyOnly)

        XCTAssertEqual(outcome, InsertionOutcome.copiedOnly)
        XCTAssertEqual(diagnostics.records.last?.finalPath, .copyOnly)
        XCTAssertEqual(diagnostics.records.last?.pasteboardChangeCountBeforeCopy, 0)
        XCTAssertEqual(diagnostics.records.last?.pasteboardChangeCountAfterCopy, 1)
    }

    @MainActor
    func testTypeOnlyRecordsTypingFailure() async {
        let frontmost = FrontmostApplicationProvider()
        let target = ApplicationSpy(name: "Supacode", bundleIdentifier: "com.supacode.app")
        let pasteboard = PasteboardSpy()
        let dispatcher = EventDispatcherSpy()
        let diagnostics = InsertionDiagnosticsSpy()
        frontmost.application = target.application
        dispatcher.typeResults = [false]

        let service = TextInsertionService(
            ownBundleIdentifier: "com.rminerick.HorseWhisprer",
            frontmostApplicationProvider: { frontmost.application },
            pasteboard: pasteboard,
            eventDispatcher: dispatcher,
            diagnostics: diagnostics,
            sleep: { _ in },
            observeWorkspaceNotifications: false
        )

        service.captureInsertionTarget()
        let outcome = await service.insert(text: "test", behavior: InsertBehavior.typeOnly)

        XCTAssertEqual(outcome, InsertionOutcome.failed("typing failed"))
        XCTAssertEqual(dispatcher.typeCallCount, 1)
        XCTAssertEqual(diagnostics.records.last?.finalPath, .typeOnlyFailed)
        XCTAssertEqual(diagnostics.records.last?.typingAttempted, true)
    }
}

private final class FrontmostApplicationProvider {
    var application: TextInsertionService.TrackedApplication?
}

@MainActor
private final class ApplicationSpy {
    private final class Storage {
        var activationCount = 0
        var isTerminated = false
    }

    private let storage: Storage
    let application: TextInsertionService.TrackedApplication

    init(name: String, bundleIdentifier: String) {
        let storage = Storage()
        self.storage = storage
        application = TextInsertionService.TrackedApplication(
            localizedName: name,
            bundleIdentifier: bundleIdentifier,
            isTerminated: { [storage] in
                storage.isTerminated
            },
            activate: { [storage] in
                storage.activationCount += 1
            }
        )
    }

    var activationCount: Int {
        storage.activationCount
    }

    var isTerminated: Bool {
        get { storage.isTerminated }
        set { storage.isTerminated = newValue }
    }
}

private final class PasteboardSpy: TextInsertionPasteboardControlling {
    var onRestore: (() -> Void)?
    var currentString: String? {
        currentEntries.first?.entries.first.flatMap { String(data: $0.data, encoding: .utf8) }
    }
    private(set) var changeCount = 0
    private(set) var copiedStrings: [String] = []
    private var currentEntries: [TextInsertionPasteboardSnapshotItem] = []

    func snapshotItems() -> [TextInsertionPasteboardSnapshotItem] {
        currentEntries
    }

    func copy(text: String) {
        changeCount += 1
        copiedStrings.append(text)
        currentEntries = [
            TextInsertionPasteboardSnapshotItem(
                entries: [(.string, Data(text.utf8))]
            )
        ]
    }

    func restoreItems(_ items: [TextInsertionPasteboardSnapshotItem]) {
        currentEntries = items
        changeCount += 1
        onRestore?()
    }
}

private final class EventDispatcherSpy: TextInsertionEventDispatching {
    var pasteResult = PasteDispatchResult(sourceCreated: true, eventsCreated: true, posted: true)
    var typeResults: [Bool] = [true]
    private(set) var typeCallCount = 0
    private(set) var pasteCallCount = 0
    private(set) var remotePasteCallCount = 0

    func sendPasteShortcut() -> PasteDispatchResult {
        pasteCallCount += 1
        return pasteResult
    }

    @MainActor
    func sendRemotePasteShortcut(canDeliver: @MainActor () -> Bool) async -> PasteDispatchResult {
        guard canDeliver() else { return .init(sourceCreated: true, eventsCreated: true, posted: false) }
        remotePasteCallCount += 1
        return sendPasteShortcut()
    }

    func type(text: String) -> Bool {
        typeCallCount += 1
        if !typeResults.isEmpty {
            return typeResults.removeFirst()
        }

        return true
    }
}

private final class InsertionDiagnosticsSpy: InsertionDiagnosticsLogging {
    private(set) var records: [InsertionAttemptRecord] = []

    func log(_ record: InsertionAttemptRecord) {
        records.append(record)
    }
}

private actor SleepSpy {
    private var invocations: [UInt64] = []

    func sleep(delay: UInt64) async {
        invocations.append(delay)
    }

    func recordedInvocations() -> [UInt64] {
        invocations
    }
}

@MainActor
private final class RemotePasteFixture {
    let pasteboard = RemotePasteboardSpy()
    let dispatcher = EventDispatcherSpy()
    let diagnostics = InsertionDiagnosticsSpy()
    let gate = TestGate()
    var bundleIdentifier = "test.remote"
    var sameWindow = true
    var hasWindow = true
    var canDeliver = true
    var refreshCount = 0
    var refreshResult = true
    var onRefresh: (() -> Void)?
    let sleeper = SleepSpy()
    lazy var service = makeService()

    private func captureWindow() -> (@MainActor () -> Bool)? {
        guard hasWindow else { return nil }
        return { [unowned self] in self.sameWindow }
    }

    private func makeService() -> TextInsertionService {
        TextInsertionService(
        ownBundleIdentifier: "test.horse",
        frontmostApplicationProvider: { [unowned self] in
            let capturedBundle = bundleIdentifier
            return .init(localizedName: "Remote", bundleIdentifier: capturedBundle,
                         activate: { self.bundleIdentifier = capturedBundle })
        }, pasteboard: pasteboard, eventDispatcher: dispatcher, diagnostics: diagnostics,
        sleep: { [gate, sleeper] delay in await sleeper.sleep(delay: delay); await gate.wait() },
        delayedPasteTargetValidator: { [unowned self] in self.captureWindow() },
        refreshRemoteClipboard: { [unowned self] canContinue in
            refreshCount += 1
            onRefresh?()
            return refreshResult && canContinue()
        },
        observeWorkspaceNotifications: false)
    }

    func insert(timing: ClipboardPasteTiming = .oneSecond) async -> InsertionOutcome {
        await service.insert(text: "remote transcript", behavior: .pasteThenType,
            pasteTiming: timing, expectedBundleIdentifier: "test.remote", canDeliver: { self.canDeliver })
    }
}

extension TextInsertionServiceTests {
    @MainActor
    func testRemotePasteWaitsForSharingKeepsClipboardAndDispatchesOnlyOnce() async {
        let f = RemotePasteFixture()
        f.pasteboard.copy(text: "original clipboard")
        let operation = Task { await f.insert(timing: .twoSeconds) }
        await f.gate.waitUntilEntered()
        XCTAssertEqual(f.pasteboard.currentString, "remote transcript")
        XCTAssertEqual(f.pasteboard.transientCopies, 0)
        let delays = await f.sleeper.recordedInvocations()
        XCTAssertEqual(delays, [2_000_000_000])
        XCTAssertEqual(f.dispatcher.pasteCallCount, 0)
        await f.gate.open()
        let outcome = await operation.value
        XCTAssertEqual(outcome, .pasted)
        XCTAssertEqual(f.dispatcher.remotePasteCallCount, 1)
        XCTAssertEqual(f.dispatcher.pasteCallCount, 1)
        XCTAssertEqual(f.dispatcher.typeCallCount, 0)
        await Task.yield()
        XCTAssertEqual(f.pasteboard.currentString, "remote transcript")
    }

    @MainActor
    func testRemotePasteDoesNotPasteAfterAppWindowClipboardOrSessionChanges() async {
        for change in 0..<5 {
            let f = RemotePasteFixture()
            let operation = Task { await f.insert() }
            await f.gate.waitUntilEntered()
            switch change {
            case 0: f.bundleIdentifier = "test.other"
            case 1: f.sameWindow = false
            case 2: f.pasteboard.copy(text: "new user copy")
            case 3: f.canDeliver = false
            default: operation.cancel()
            }
            await f.gate.open()
            let outcome = await operation.value
            if change == 2 {
                guard case .failed = outcome else { return XCTFail("Must not report copied after clipboard ownership is lost") }
            } else {
                XCTAssertEqual(outcome, .copiedOnly)
            }
            XCTAssertEqual(f.dispatcher.pasteCallCount, 0)
            XCTAssertEqual(f.dispatcher.typeCallCount, 0)
            if change == 2 { XCTAssertEqual(f.pasteboard.currentString, "new user copy") }
        }
    }

    @MainActor
    func testRemotePasteDoesNotRestoreOrSendIntoAnAlreadyDifferentApp() async {
        let f = RemotePasteFixture()
        f.bundleIdentifier = "test.other"
        let outcome = await f.insert()
        XCTAssertEqual(outcome, .copiedOnly)
        XCTAssertEqual(f.dispatcher.pasteCallCount, 0)
        XCTAssertEqual(f.pasteboard.currentString, "remote transcript")
    }

    @MainActor
    func testRemotePasteDoesNotTypeFallbackIfPasteDispatchFails() async {
        let f = RemotePasteFixture()
        f.dispatcher.pasteResult = .init(sourceCreated: false, eventsCreated: false, posted: false)
        await f.gate.open()
        let outcome = await f.insert()
        XCTAssertEqual(outcome, .copiedOnly)
        XCTAssertEqual(f.dispatcher.pasteCallCount, 1)
        XCTAssertEqual(f.dispatcher.typeCallCount, 0)
    }

    @MainActor
    func testCopyAndTypeOnlyIgnoreRemotePasteTiming() async {
        let f = RemotePasteFixture()
        let copied = await f.service.insert(text: "copy", behavior: .copyOnly, pasteTiming: .fiveSeconds,
            expectedBundleIdentifier: "test.remote", canDeliver: { true })
        let typed = await f.service.insert(text: "type", behavior: .typeOnly, pasteTiming: .fiveSeconds,
            expectedBundleIdentifier: "test.remote", canDeliver: { true })
        XCTAssertEqual(copied, .copiedOnly)
        XCTAssertEqual(typed, .typed)
        XCTAssertEqual(f.dispatcher.pasteCallCount, 0)
        XCTAssertEqual(f.dispatcher.typeCallCount, 1)
    }
}

private final class RemotePasteboardSpy: TextInsertionPasteboardControlling {
    private(set) var changeCount = 0
    private(set) var currentString: String?
    private(set) var transientCopies = 0
    func snapshotItems() -> [TextInsertionPasteboardSnapshotItem] {
        currentString.map { [.init(entries: [(.string, Data($0.utf8))])] } ?? []
    }
    var rejectCopy = false
    func replaceTextWithoutChangingOwnership(_ text: String) { currentString = text }
    func copy(text: String) {
        guard !rejectCopy else { return }
        currentString = text; changeCount += 1
    }
    func copyTransient(text: String) { transientCopies += 1; copy(text: text) }
    func restoreItems(_ items: [TextInsertionPasteboardSnapshotItem]) {
        currentString = items.first?.entries.first.flatMap { String(data: $0.data, encoding: .utf8) }
        changeCount += 1
    }
}

extension TextInsertionServiceTests {
    @MainActor
    func testRemotePasteCopiesWithoutDispatchWhenLocalWindowIsUnreadable() async {
        let f = RemotePasteFixture()
        f.hasWindow = false
        let outcome = await f.insert()
        XCTAssertEqual(outcome, .copiedOnly)
        XCTAssertEqual(f.dispatcher.pasteCallCount, 0)
        XCTAssertEqual(f.pasteboard.currentString, "remote transcript")
    }
}

extension TextInsertionServiceTests {
    @MainActor
    func testRemoteChordReportsPhysicalLeftCommandForRemoteForwarders() async {
        var events: [CGEvent] = []
        let dispatcher = QuartzTextInsertionEventDispatcher(postEvent: { events.append($0) }, pause: { _ in })
        _ = await dispatcher.sendRemotePasteShortcut(canDeliver: { true })
        // NX_DEVICELCMDKEYMASK from Apple's IOLLEvent.h. Remote clients can
        // inspect this device-dependent bit instead of the generic Command flag.
        XCTAssertEqual(events.map { $0.flags.rawValue }, [0x100008, 0x100008, 0x100008, 0])
    }

    @MainActor
    func testRemoteChordPostsModifierTransitionsAroundVWithForwardingDelays() async {
        var events: [CGEvent] = []
        var pauses: [UInt64] = []
        var eventCountsAtPause: [Int] = []
        let dispatcher = QuartzTextInsertionEventDispatcher(postEvent: { events.append($0) }, pause: {
            pauses.append($0)
            eventCountsAtPause.append(events.count)
        })
        let result = await dispatcher.sendRemotePasteShortcut(canDeliver: { true })
        XCTAssertTrue(result.posted)
        XCTAssertEqual(events.map(\.type), [.flagsChanged, .keyDown, .keyUp, .flagsChanged])
        XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [55, 9, 9, 55])
        XCTAssertEqual(events.map(\.flags), [CGEventFlags(rawValue: 0x100008), CGEventFlags(rawValue: 0x100008), CGEventFlags(rawValue: 0x100008), []])
        XCTAssertEqual(pauses, [30_000_000, 30_000_000])
        XCTAssertEqual(eventCountsAtPause, [1, 3])
    }

    @MainActor
    func testRemoteChordReleasesCommandWithoutVIfCanceledOrTargetChangesDuringDelay() async {
        for cancel in [false, true] {
            var events: [CGEvent] = []
            var validTarget = true
            let gate = TestGate()
            let dispatcher = QuartzTextInsertionEventDispatcher(postEvent: { events.append($0) }, pause: { _ in
                await gate.wait()
            })
            let task = Task { await dispatcher.sendRemotePasteShortcut(canDeliver: { validTarget }) }
            await gate.waitUntilEntered()
            XCTAssertEqual(events.map(\.flags), [CGEventFlags(rawValue: 0x100008)])
            if cancel { task.cancel() } else { validTarget = false }
            await gate.open()
            let result = await task.value
            XCTAssertFalse(result.posted)
            XCTAssertEqual(events.map(\.type), [.flagsChanged, .flagsChanged])
            XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [55, 55])
            XCTAssertEqual(events.map(\.flags), [CGEventFlags(rawValue: 0x100008), []])
        }
    }

    @MainActor
    func testRemoteChordReleasesCommandAfterPasteEvenWhenCanceled() async {
        var events: [CGEvent] = []
        let gate = TestGate()
        var pauseCount = 0
        let dispatcher = QuartzTextInsertionEventDispatcher(postEvent: { events.append($0) }, pause: { _ in
            pauseCount += 1
            if pauseCount == 2 { await gate.wait() }
        })
        let task = Task { await dispatcher.sendRemotePasteShortcut(canDeliver: { true }) }
        await gate.waitUntilEntered()
        XCTAssertEqual(events.count, 3)
        task.cancel()
        await gate.open()
        let result = await task.value
        XCTAssertTrue(result.posted)
        XCTAssertEqual(events.last?.type, .flagsChanged)
        XCTAssertEqual(events.last?.flags, [])
    }

    @MainActor
    func testInvalidRemoteTargetPostsNothingAndLocalPasteKeepsItsOriginalChord() async {
        var events: [CGEvent] = []
        let dispatcher = QuartzTextInsertionEventDispatcher(postEvent: { events.append($0) }, pause: { _ in
            XCTFail("Invalid target and local paste must not wait")
        })
        let skipped = await dispatcher.sendRemotePasteShortcut(canDeliver: { false })
        XCTAssertFalse(skipped.posted)
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(dispatcher.sendPasteShortcut().posted)
        XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp])
        XCTAssertEqual(events.map(\.flags), [.maskCommand, .maskCommand])
    }
}


extension TextInsertionServiceTests {
    @MainActor
    func testRemotePasteRejectsFailedCopyAndPartialClipboardWithoutReplaying() async {
        for rejectCopy in [true, false] {
            let f = RemotePasteFixture()
            f.pasteboard.copy(text: "old clipboard")
            f.pasteboard.rejectCopy = rejectCopy
            let operation = Task { await f.insert() }
            if !rejectCopy {
                await f.gate.waitUntilEntered()
                f.pasteboard.replaceTextWithoutChangingOwnership("remote")
                await f.gate.open()
            }
            let outcome = await operation.value
            guard case .failed = outcome else { return XCTFail("Must expose clipboard failure") }
            XCTAssertEqual(f.dispatcher.pasteCallCount, 0)
            XCTAssertEqual(f.dispatcher.typeCallCount, 0)
        }
    }

    @MainActor
    func testRemoteDesktopWaitsAtLeastTwoSecondsAndPreservesLongerWaits() async {
        for timing in [ClipboardPasteTiming.halfSecond, .oneSecond, .fiveSeconds] {
            let f = RemotePasteFixture()
            f.bundleIdentifier = "com.apple.RemoteDesktop"
            let operation = Task {
                await f.service.insert(text: "complete transcript", behavior: .pasteThenType,
                    pasteTiming: timing, expectedBundleIdentifier: f.bundleIdentifier, canDeliver: { true })
            }
            await f.gate.waitUntilEntered()
            let delays = await f.sleeper.recordedInvocations()
            XCTAssertEqual(delays, [max(timing.delayNanoseconds, 2_000_000_000)])
            XCTAssertEqual(f.dispatcher.pasteCallCount, 0)
            await f.gate.open()
            let outcome = await operation.value
            XCTAssertEqual(outcome, .pasted)
            XCTAssertEqual(f.pasteboard.currentString, "complete transcript")
            XCTAssertEqual(f.pasteboard.transientCopies, 0)
            XCTAssertEqual(f.dispatcher.remotePasteCallCount, 1)
        }
    }

    @MainActor
    func testManualRetryUsesTargetOverrideInsteadOfGlobalBehavior() async {
        let name = "HorseWhisprerTests.manualRetry.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.insertBehavior = .typeOnly
        settings.useRemoteDesktopPreset(for: "test.remote", name: "Remote")
        let f = RemotePasteFixture()
        let operation = Task { await f.service.insert(text: "whole retry", settings: settings) }
        await f.gate.waitUntilEntered()
        XCTAssertEqual(f.dispatcher.pasteCallCount, 0)
        await f.gate.open()
        let outcome = await operation.value
        XCTAssertEqual(outcome, .pasted)
        XCTAssertEqual(f.dispatcher.remotePasteCallCount, 1)
        XCTAssertEqual(f.dispatcher.typeCallCount, 0)
        XCTAssertEqual(f.pasteboard.currentString, "whole retry")
        XCTAssertEqual(f.pasteboard.transientCopies, 0)
    }

    @MainActor
    func testExplicitCopyReportsFailureAndSuccessBasedOnFullClipboardContents() {
        let f = RemotePasteFixture()
        f.pasteboard.copy(text: "old")
        f.pasteboard.rejectCopy = true
        XCTAssertFalse(f.service.copyToClipboard("new complete transcript"))
        f.pasteboard.rejectCopy = false
        XCTAssertTrue(f.service.copyToClipboard("new complete transcript"))
    }

    @MainActor
    func testSystemClipboardPublishesCompleteUnicodeAndMultilineText() {
        let board = NSPasteboard(name: .init("HorseWhisprerTests.clipboard.\(UUID())"))
        defer { board.releaseGlobally() }
        let clipboard = SystemTextInsertionPasteboard(pasteboard: board)
        let text = "First line 🐴 café\n" + String(repeating: "Full transcript. ", count: 1000)
        clipboard.copy(text: text)
        XCTAssertTrue(clipboard.contains(text: text))
        XCTAssertFalse(clipboard.contains(text: "First line"))
        XCTAssertEqual(board.pasteboardItems?.count, 1)
        XCTAssertTrue(board.types?.contains(.string) == true)
        XCTAssertFalse(board.types?.contains(.init("org.nspasteboard.TransientType")) == true)
        XCTAssertFalse(board.types?.contains(.init("org.nspasteboard.AutoGeneratedType")) == true)
    }
}


extension TextInsertionServiceTests {
    @MainActor
    func testManualRetryFromHistorySearchStillReturnsToExternalRemoteTarget() async {
        let name = "HorseWhisprerTests.manualSearchRetry.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.useRemoteDesktopPreset(for: "test.remote", name: "Remote")
        let f = RemotePasteFixture()
        let service = f.service // Remember the external app before opening History.
        f.bundleIdentifier = "test.horse"
        service.ownTextTargetProvider = { true }
        let operation = Task { await service.insert(text: "complete retry", settings: settings) }
        await f.gate.waitUntilEntered()
        XCTAssertEqual(f.bundleIdentifier, "test.remote")
        XCTAssertEqual(f.dispatcher.pasteCallCount, 0)
        await f.gate.open()
        let outcome = await operation.value
        XCTAssertEqual(outcome, .pasted)
        XCTAssertEqual(f.dispatcher.remotePasteCallCount, 1)
        XCTAssertEqual(f.pasteboard.currentString, "complete retry")
    }
}

extension TextInsertionServiceTests {
    @MainActor
    func testEveryARDTranscriptRefreshesSharingAfterPublishingCompleteClipboard() async {
        let f = RemotePasteFixture()
        f.bundleIdentifier = "com.apple.RemoteDesktop"
        var transferred: [String] = []
        f.onRefresh = { transferred.append(f.pasteboard.currentString ?? "") }
        await f.gate.open()
        for text in ["first prompt", "second different prompt", "third prompt 🐎\ncomplete"] {
            let result = await f.service.insert(text: text, behavior: .pasteThenType,
                pasteTiming: .oneSecond, expectedBundleIdentifier: "com.apple.RemoteDesktop", canDeliver: { true })
            XCTAssertEqual(result, .pasted)
            XCTAssertEqual(transferred.last, text)
        }
        XCTAssertEqual(f.refreshCount, 3)
        XCTAssertEqual(f.dispatcher.remotePasteCallCount, 3)
    }

    @MainActor
    func testARDRefreshFailureOrChangedTargetNeverPastes() async {
        for change in 0..<5 {
            let f = RemotePasteFixture()
            f.bundleIdentifier = "com.apple.RemoteDesktop"
            await f.gate.open()
            f.onRefresh = {
                switch change {
                case 0: f.refreshResult = false
                case 1: f.sameWindow = false
                case 2: f.bundleIdentifier = "another.app"
                case 3: f.canDeliver = false
                default: f.pasteboard.replaceTextWithoutChangingOwnership("different clipboard")
                }
            }
            let result = await f.service.insert(text: "new prompt", behavior: .pasteThenType,
                pasteTiming: .oneSecond, expectedBundleIdentifier: "com.apple.RemoteDesktop",
                canDeliver: { f.canDeliver })
            XCTAssertNotEqual(result, .pasted)
            XCTAssertEqual(f.dispatcher.remotePasteCallCount, 0)
        }
    }

    @MainActor
    func testOtherRemoteClientsNeverCycleFocus() async {
        let f = RemotePasteFixture()
        await f.gate.open()
        let result = await f.insert()
        XCTAssertEqual(result, .pasted)
        XCTAssertEqual(f.refreshCount, 0)
    }

    @MainActor
    func testFocusRefreshWaitsForBothActivations() async {
        var pid: pid_t? = 1
        var requested: pid_t?
        var requests: [pid_t] = []
        let result = await RemoteClipboardFocusRefresh.cycle(targetPID: 1, ownPID: 2,
            frontmostPID: { pid },
            activateOwn: { requests.append(2); requested = 2; return true },
            activateTarget: { requests.append(1); requested = 1; return true },
            canContinue: { true }, pause: { _ in
                if let pending = requested { pid = pending; requested = nil }
            })
        XCTAssertTrue(result)
        XCTAssertEqual(requests, [2, 1])
        XCTAssertEqual(pid, 1)
    }

    @MainActor
    func testFocusRefreshDoesNotReclaimFocusFromThirdApp() async {
        for stage in 0..<3 {
            var pid: pid_t? = 1
            var targetActivations = 0
            let result = await RemoteClipboardFocusRefresh.cycle(targetPID: 1, ownPID: 2,
                frontmostPID: { pid },
                activateOwn: { if stage != 0 { pid = 2 }; return true },
                activateTarget: { targetActivations += 1; return true },
                canContinue: { true }, pause: { delay in
                    if stage != 2 || delay != 100_000_000 { pid = 3 }
                })
            XCTAssertFalse(result)
            XCTAssertEqual(pid, 3)
            XCTAssertEqual(targetActivations, stage == 2 ? 1 : 0)
        }
    }

    @MainActor
    func testFocusRefreshReturnsFocusOnCancellationWithoutAuthorizingPaste() async {
        var pid: pid_t? = 1
        var valid = true
        let result = await RemoteClipboardFocusRefresh.cycle(targetPID: 1, ownPID: 2,
            frontmostPID: { pid }, activateOwn: { pid = 2; return true },
            activateTarget: { pid = 1; return true }, canContinue: { valid },
            pause: { _ in valid = false })
        XCTAssertFalse(result)
        XCTAssertEqual(pid, 1)
    }

    @MainActor
    func testFocusRefreshBoundsFailuresAndSkipsInvalidInitialTarget() async {
        for failure in 0..<4 {
            var pid: pid_t? = failure == 0 ? 3 : 1
            var pauses = 0
            var activations = 0
            let result = await RemoteClipboardFocusRefresh.cycle(targetPID: 1, ownPID: 2,
                frontmostPID: { pid }, activateOwn: {
                    activations += 1
                    if failure == 3 { pid = 2 }
                    return failure != 1
                }, activateTarget: { activations += 1; return true },
                canContinue: { true }, pause: { _ in pauses += 1 })
            XCTAssertFalse(result)
            XCTAssertLessThanOrEqual(pauses, 101)
            if failure == 0 { XCTAssertEqual(activations, 0) }
        }
    }
}

extension TextInsertionServiceTests {
    @MainActor
    func testFocusRefreshAllowsFullScreenTransitionAndReportsSuccessfulHandoff() async {
        var pid: pid_t? = 1
        var requested: pid_t = 1
        var polls = 0
        var messages: [String] = []
        let result = await RemoteClipboardFocusRefresh.cycle(targetPID: 1, ownPID: 2,
            frontmostPID: { pid }, activateOwn: { requested = 2; polls = 0; return true },
            activateTarget: { requested = 1; polls = 0; return true }, canContinue: { true },
            pause: { _ in
                polls += 1
                if polls == 45 { pid = requested }
            }, diagnose: { messages.append($0) })
        XCTAssertTrue(result)
        XCTAssertEqual(pid, 1)
        XCTAssertEqual(messages, ["focusRefresh=ownAppActive", "focusRefresh=returned deliveryValid=true"])
    }

    @MainActor
    func testFocusRefreshReportsActivationTimeoutWithoutDispatchOrReturnRequest() async {
        var messages: [String] = []
        var returnRequests = 0
        let result = await RemoteClipboardFocusRefresh.cycle(targetPID: 1, ownPID: 2,
            frontmostPID: { 1 }, activateOwn: { true },
            activateTarget: { returnRequests += 1; return true }, canContinue: { true },
            pause: { _ in }, diagnose: { messages.append($0) })
        XCTAssertFalse(result)
        XCTAssertEqual(returnRequests, 0)
        XCTAssertEqual(messages, ["focusRefresh=activationTimedOut frontmostPID=1"])
    }
}
