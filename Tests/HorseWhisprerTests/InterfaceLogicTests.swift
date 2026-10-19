import Carbon
import XCTest
@testable import HorseWhisprer

final class TextReplacerTests: XCTestCase {
    func testReplacesWholeWordsInAnyCapitalization() {
        let rules = [TextReplacementRule(heard: "horse whisperer", replacement: "Horse Whisprer")]
        XCTAssertEqual(TextReplacer.apply(rules, to: "Open Horse Whisperer and the horse whisperer docs."),
                       "Open Horse Whisprer and the Horse Whisprer docs.")
    }

    func testDoesNotReplaceInsideLongerWords() {
        let rules = [TextReplacementRule(heard: "cat", replacement: "dog")]
        XCTAssertEqual(TextReplacer.apply(rules, to: "The cat sat in the catalog, cat."), "The dog sat in the catalog, dog.")
    }

    func testReplacementTextIsLiteral() {
        let rules = [TextReplacementRule(heard: "c plus plus", replacement: "C++ ($1)")]
        XCTAssertEqual(TextReplacer.apply(rules, to: "I write c plus plus daily"), "I write C++ ($1) daily")
    }

    func testEmptyRulesAndBlankPhrasesLeaveTextAlone() {
        XCTAssertEqual(TextReplacer.apply([], to: "unchanged"), "unchanged")
        XCTAssertEqual(TextReplacer.apply([TextReplacementRule(heard: "  ", replacement: "x")], to: "unchanged"), "unchanged")
    }

    func testLaterRulesSeeEarlierOutput() {
        let rules = [
            TextReplacementRule(heard: "nemo tron", replacement: "Nemotron"),
            TextReplacementRule(heard: "nemotron", replacement: "Nemotron Streaming")
        ]
        XCTAssertEqual(TextReplacer.apply(rules, to: "use nemo tron"), "use Nemotron Streaming")
    }
}

@MainActor
final class TranscriptHistoryStoreTests: XCTestCase {
    func testDevRetentionNeverDeletesProductionHistory() throws {
        let directory = try temporaryFileURL().deletingLastPathComponent()
        let productionURL = try XCTUnwrap(TranscriptHistoryStore.defaultFileURL(
            bundleIdentifier: "com.rminerick.HorseWhisprer", supportDirectory: directory))
        let devURL = try XCTUnwrap(TranscriptHistoryStore.defaultFileURL(
            bundleIdentifier: "com.rminerick.HorseWhisprer.Dev", supportDirectory: directory))
        XCTAssertEqual(productionURL.lastPathComponent, "history.json")
        XCTAssertNotEqual(productionURL, devURL)
        let production = TranscriptHistoryStore(retention: .onDisk, fileURL: productionURL)
        production.add(record("production"))
        let dev = TranscriptHistoryStore(retention: .untilQuit, fileURL: devURL)
        dev.add(record("development"))
        dev.setRetention(.onDisk)
        dev.clear()
        dev.setRetention(.off)
        XCTAssertEqual(TranscriptHistoryStore(retention: .onDisk, fileURL: productionURL).records.map(\.text),
                       ["production"])
    }

    func testMissingIdentityDoesNotUseProductionHistory() {
        XCTAssertNil(TranscriptHistoryStore.defaultFileURL(bundleIdentifier: nil))
    }

    func testNewestFirstAndTrimmedToLimit() {
        let store = TranscriptHistoryStore(retention: .untilQuit, fileURL: nil, limit: 2)
        store.add(record("one"))
        store.add(record("two"))
        store.add(record("three"))
        XCTAssertEqual(store.records.map(\.text), ["three", "two"])
    }

    func testOffKeepsNothing() {
        let store = TranscriptHistoryStore(retention: .off, fileURL: nil)
        store.add(record("secret"))
        XCTAssertTrue(store.records.isEmpty)
    }

    func testUntilQuitNeverWritesAFile() throws {
        let url = try temporaryFileURL()
        let store = TranscriptHistoryStore(retention: .untilQuit, fileURL: url)
        store.add(record("in memory"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testOnDiskPersistsPrivatelyAndReloads() throws {
        let url = try temporaryFileURL()
        let store = TranscriptHistoryStore(retention: .onDisk, fileURL: url)
        store.add(record("first"))
        store.add(record("second"))

        let permissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue, 0o600)

        let reloaded = TranscriptHistoryStore(retention: .onDisk, fileURL: url)
        XCTAssertEqual(reloaded.records.map(\.text), ["second", "first"])
    }

    func testLeavingOnDiskRemovesTheFile() throws {
        let url = try temporaryFileURL()
        let store = TranscriptHistoryStore(retention: .onDisk, fileURL: url)
        store.add(record("saved"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        store.setRetention(.untilQuit)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(store.records.map(\.text), ["saved"])

        store.setRetention(.off)
        XCTAssertTrue(store.records.isEmpty)
    }

    func testRemoveAndClear() {
        let store = TranscriptHistoryStore(retention: .untilQuit, fileURL: nil)
        let first = record("first")
        store.add(first)
        store.add(record("second"))
        store.remove(id: first.id)
        XCTAssertEqual(store.records.map(\.text), ["second"])
        store.clear()
        XCTAssertTrue(store.records.isEmpty)
    }

    private func record(_ text: String) -> TranscriptRecord {
        TranscriptRecord(text: text, targetApplicationName: "Mail", outcome: "Pasted",
                         modelName: "Whisper base.en", recordedDuration: 3, reachedTarget: true)
    }

    private func temporaryFileURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HorseWhisprerHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("history.json")
    }
}

final class PillPresentationTests: XCTestCase {
    func testIdleShowsNothing() {
        XCTAssertNil(make(.idle))
    }

    func testSessionStatesStayUpUntilTheSessionEnds() {
        for activity in [DictationActivity.starting, .recording(.insertOnStop), .recording(.bufferingAudio),
                         .recording(.insertingLive), .recording(.liveInsertionPaused), .stopping, .transcribing] {
            XCTAssertNil(make(activity)?.lingerSeconds, "\(activity)")
        }
    }

    func testBufferingNamesTheLoadingModel() {
        XCTAssertEqual(make(.recording(.bufferingAudio))?.subtitle, "Nemotron Streaming 0.6B is loading. Your audio is buffered.")
    }

    func testLiveInsertionShowsTheLatestWords() {
        let presentation = make(.recording(.insertingLive),
                                partial: "Thanks for sending the revised quote. I looked through it this morning and the numbers work for us")
        XCTAssertEqual(presentation?.title, "…it this morning and the numbers work for us")
        XCTAssertEqual(presentation?.subtitle, "Inserting live into Mail")
    }

    func testMissingAccessibilityOffersTheFix() {
        let presentation = make(.finished(.copiedWithoutAccessibility))
        XCTAssertEqual(presentation?.action, .openPermissions)
        XCTAssertEqual(presentation?.glyph, .warning)
        XCTAssertNotNil(presentation?.lingerSeconds)
    }

    func testFailureShowsTheError() {
        XCTAssertEqual(make(.failed, lastError: "Microphone permission is required.")?.subtitle,
                       "Microphone permission is required.")
    }

    func testEscapeHintFollowsTheSetting() {
        XCTAssertEqual(make(.recording(.insertOnStop), escapeCancels: true)?.showsCancelHint, true)
        XCTAssertEqual(make(.recording(.insertOnStop), escapeCancels: false)?.showsCancelHint, false)
    }

    func testTailKeepsShortTextWhole() {
        XCTAssertEqual(PillPresentation.tail(of: "  short text "), "short text")
    }

    private func make(_ activity: DictationActivity, partial: String? = nil, lastError: String? = nil,
                      escapeCancels: Bool = true) -> PillPresentation? {
        PillPresentation.make(activity: activity, modelName: "Nemotron Streaming 0.6B", targetName: "Mail",
                              partialTranscript: partial, lastError: lastError, escapeCancels: escapeCancels)
    }
}

final class SpecialKeyHoldDetectorTests: XCTestCase {
    private let trigger = SpecialKeyTrigger.rightCommandTapAlone

    func testHoldPastThresholdBeginsAndReleaseEnds() {
        var detector = SpecialKeyHoldDetector()
        XCTAssertEqual(detector.process(holdDown(trigger), trigger: trigger), .armed)
        XCTAssertTrue(detector.holdThresholdReached())
        XCTAssertFalse(detector.holdThresholdReached(), "Dictation must start only once per hold")
        XCTAssertEqual(detector.process(letGo(trigger), trigger: trigger), .ended)
    }

    func testQuickTapNeverBegins() {
        var detector = SpecialKeyHoldDetector()
        XCTAssertEqual(detector.process(holdDown(trigger), trigger: trigger), .armed)
        XCTAssertEqual(detector.process(letGo(trigger), trigger: trigger), .disarmed)
        XCTAssertFalse(detector.holdThresholdReached())
    }

    func testUsingTheKeyInAShortcutDisarms() {
        var detector = SpecialKeyHoldDetector()
        XCTAssertEqual(detector.process(holdDown(trigger), trigger: trigger), .armed)
        XCTAssertEqual(detector.process(.keyDown(keyCode: UInt16(kVK_ANSI_C)), trigger: trigger), .disarmed)
        XCTAssertFalse(detector.holdThresholdReached())
        XCTAssertEqual(detector.process(letGo(trigger), trigger: trigger), .disarmed)
    }

    func testTypingDuringAHoldKeepsRecording() {
        var detector = SpecialKeyHoldDetector()
        _ = detector.process(holdDown(trigger), trigger: trigger)
        XCTAssertTrue(detector.holdThresholdReached())
        XCTAssertEqual(detector.process(.keyDown(keyCode: UInt16(kVK_ANSI_C)), trigger: trigger), .none)
        XCTAssertEqual(detector.process(letGo(trigger), trigger: trigger), .ended)
    }

    func testPressWithAnotherModifierAlreadyDownDoesNotArm() {
        var detector = SpecialKeyHoldDetector()
        let other = SpecialKeyTrigger.leftOptionTapAlone
        let both = CGEventFlags(rawValue: trigger.deviceFlagMask | other.deviceFlagMask)
        XCTAssertEqual(detector.process(.flagsChanged(keyCode: trigger.keyCode, flags: both), trigger: trigger), .none)
        XCTAssertFalse(detector.holdThresholdReached())
    }

    private func holdDown(_ trigger: SpecialKeyTrigger) -> SpecialKeyMonitorEvent {
        .flagsChanged(keyCode: trigger.keyCode, flags: CGEventFlags(rawValue: trigger.deviceFlagMask))
    }

    private func letGo(_ trigger: SpecialKeyTrigger) -> SpecialKeyMonitorEvent {
        .flagsChanged(keyCode: trigger.keyCode, flags: CGEventFlags(rawValue: 0))
    }
}

final class InterfaceSettingsTests: XCTestCase {
    func testNewSettingsDefaultToThePopoverAndInMemoryHistory() {
        let settings = makeTestSettings()
        XCTAssertEqual(settings.menuBarStyle, .popover)
        XCTAssertTrue(settings.showsDictationPill)
        XCTAssertFalse(settings.showsDockIcon)
        XCTAssertEqual(settings.triggerStyle, .toggle)
        XCTAssertTrue(settings.escapeCancelsDictation)
        XCTAssertEqual(settings.historyRetention, .untilQuit)
        XCTAssertNil(settings.vocabularyPrompt)
        XCTAssertTrue(settings.textReplacements.isEmpty)
    }

    func testInterfaceSettingsPersist() {
        let suite = "HorseWhisprerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        settings.menuBarStyle = .classicMenu
        settings.triggerStyle = .hold
        settings.historyRetention = .onDisk
        settings.vocabularyTerms = " Okafor, xcodegen "
        settings.textReplacements = [TextReplacementRule(heard: "horse whisperer", replacement: "Horse Whisprer")]

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.menuBarStyle, .classicMenu)
        XCTAssertEqual(reloaded.triggerStyle, .hold)
        XCTAssertEqual(reloaded.historyRetention, .onDisk)
        XCTAssertEqual(reloaded.vocabularyPrompt, "Okafor, xcodegen")
        XCTAssertEqual(reloaded.textReplacements, settings.textReplacements)
    }

    func testEveryWhisperModelIsPinned() {
        let catalog = ModelCatalogService()
        for model in catalog.whisperModels {
            let digest = model.expectedSHA256 ?? ""
            XCTAssertEqual(digest.count, 64, model.id)
            XCTAssertTrue(digest.allSatisfy(\.isHexDigit), model.id)
            XCTAssertGreaterThan(model.expectedFileSizeBytes ?? 0, 0, model.id)
        }
        XCTAssertEqual(Set(catalog.whisperModels.compactMap(\.expectedSHA256)).count, catalog.whisperModels.count)
    }

    func testLanguageListCoversWhisperAndHasNoDuplicates() {
        XCTAssertEqual(WhisperLanguage.all.count, 100)
        XCTAssertEqual(Set(WhisperLanguage.all.map(\.code)).count, 100)
        XCTAssertEqual(WhisperLanguage.displayName(for: "auto"), "Auto detect")
        XCTAssertEqual(WhisperLanguage.displayName(for: "ja"), "Japanese")
    }

    func testShortcutKeyCaps() {
        XCTAssertEqual(HotKeyBinding.defaultBinding.keyCaps, ["⌃", "⌥", "Space"])
    }
}
