import XCTest
@testable import HorseWhisprer

@MainActor
final class StreamingInsertionModeTests: XCTestCase {
    func testDefaultAndLegacyPreferenceMigration() {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(AppSettings(defaults: defaults).streamingInsertionMode, .verified)
        defaults.set(false, forKey: AppSettings.Keys.liveStreamingInsertion)
        XCTAssertEqual(AppSettings(defaults: defaults).streamingInsertionMode, .onStop)
        defaults.set(true, forKey: AppSettings.Keys.liveStreamingInsertion)
        XCTAssertEqual(AppSettings(defaults: defaults).streamingInsertionMode, .verified)
    }

    func testModePersistsAndLegacyTogglePreservesExplicitAppendOnlyChoice() {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.streamingInsertionMode = .appendOnly
        settings.liveStreamingInsertion = true
        XCTAssertEqual(AppSettings(defaults: defaults).streamingInsertionMode, .appendOnly)
        settings.liveStreamingInsertion = false
        XCTAssertEqual(AppSettings(defaults: defaults).streamingInsertionMode, .onStop)
        settings.liveStreamingInsertion = true
        XCTAssertEqual(settings.streamingInsertionMode, .verified)
    }

    func testUnknownModeFallsBackToLegacyChoice() {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("future-mode", forKey: AppSettings.Keys.streamingInsertionMode)
        defaults.set(false, forKey: AppSettings.Keys.liveStreamingInsertion)
        XCTAssertEqual(AppSettings(defaults: defaults).streamingInsertionMode, .onStop)
    }

    func testRouterSelectsOnlyRequestedStrategyAndNeverDowngradesVerified() async {
        let verified = ModeInsertion()
        let append = ModeInsertion()
        verified.result = .unavailable
        let router = ConfigurableLiveTextInsertion(verified: verified, appendOnly: append)
        router.begin(mode: .verified)
        let unavailable = await router.update("test")
        XCTAssertEqual(unavailable, .unavailable)
        XCTAssertEqual(append.begins, 0)
        XCTAssertTrue(append.texts.isEmpty)
        router.begin(mode: .appendOnly)
        _ = await router.finish("new text")
        XCTAssertEqual(append.begins, 1)
        XCTAssertEqual(append.texts, ["new text"])
        XCTAssertEqual(verified.texts, ["test"])
        XCTAssertGreaterThan(verified.cancels, 0)
    }

    func testApplicationOverrideWinsAndRemovalRestoresCurrentDefault() {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.setStreamingOverride(for: "test.chat", name: "Chat", mode: .appendOnly)
        settings.setStreamingOverride(for: "test.editor", name: "Editor", mode: .onStop)
        settings.streamingInsertionMode = .onStop
        let restored = AppSettings(defaults: defaults)
        XCTAssertEqual(restored.streamingMode(for: "test.chat"), .appendOnly)
        XCTAssertEqual(restored.streamingMode(for: "test.editor"), .onStop)
        XCTAssertEqual(restored.streamingMode(for: "test.other"), .onStop)
        XCTAssertEqual(restored.streamingMode(for: nil), .onStop)
        XCTAssertEqual(restored.applicationStreamingNames["test.chat"], "Chat")
        restored.setStreamingOverride(for: "test.chat", name: "Renamed Chat", mode: .verified)
        XCTAssertEqual(restored.applicationStreamingModes.count, 2)
        restored.setStreamingOverride(for: "test.chat", name: "Renamed Chat", mode: nil)
        XCTAssertEqual(restored.streamingMode(for: "test.chat"), .onStop)
        XCTAssertNil(AppSettings(defaults: defaults).applicationStreamingNames["test.chat"])
    }

    func testInvalidOverrideDoesNotDiscardOtherValidPreferences() {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["test.valid": "appendOnly", "test.future": "unknown", " ": "onStop"],
                     forKey: AppSettings.Keys.applicationStreamingModes)
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.applicationStreamingModes, ["test.valid": .appendOnly])
        XCTAssertEqual(settings.streamingMode(for: "test.future"), .verified)
        settings.setStreamingOverride(for: "", name: "Invalid", mode: .appendOnly)
        XCTAssertEqual(settings.applicationStreamingModes.count, 1)
    }

    func testInsertionAndTimingOverridesPersistIndependentlyAndUseCurrentDefaults() {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.insertBehavior = .typeOnly
        settings.setInsertOverride(for: "test.remote", name: "Remote", behavior: .pasteThenType)
        settings.setPasteTimingOverride(for: "test.remote", name: "Remote", timing: .twoSeconds)
        settings.setStreamingOverride(for: "test.remote", name: "Remote", mode: .onStop)
        let restored = AppSettings(defaults: defaults)
        XCTAssertEqual(restored.insertBehavior(for: "test.remote"), .pasteThenType)
        XCTAssertEqual(restored.pasteTiming(for: "test.remote"), .twoSeconds)
        XCTAssertEqual(restored.insertBehavior(for: nil), .typeOnly)
        XCTAssertEqual(restored.pasteTiming(for: "test.other"), .standard)
        restored.setStreamingOverride(for: "test.remote", name: "Remote", mode: nil)
        XCTAssertEqual(restored.applicationStreamingNames["test.remote"], "Remote")
        restored.setInsertOverride(for: "test.remote", name: "Remote", behavior: nil)
        XCTAssertEqual(restored.applicationOverrideIdentifiers, ["test.remote"])
        XCTAssertEqual(restored.insertBehavior(for: "test.remote"), .typeOnly)
        restored.removeApplicationOverrides(for: "test.remote")
        XCTAssertTrue(restored.applicationOverrideIdentifiers.isEmpty)
        let removed = AppSettings(defaults: defaults)
        XCTAssertEqual(removed.pasteTiming(for: "test.remote"), .standard)
        XCTAssertNil(removed.applicationStreamingNames["test.remote"])
    }

    func testRemotePresetDoesNotChangeGlobalOrOtherApplicationPreferences() {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.insertBehavior = .copyOnly
        settings.setStreamingOverride(for: "test.chat", name: "Chat", mode: .appendOnly)
        settings.useRemoteDesktopPreset(for: "com.apple.RemoteDesktop", name: "Remote Desktop")
        let restored = AppSettings(defaults: defaults)
        XCTAssertEqual(restored.streamingMode(for: "com.apple.RemoteDesktop"), .onStop)
        XCTAssertEqual(restored.insertBehavior(for: "com.apple.RemoteDesktop"), .pasteThenType)
        XCTAssertEqual(restored.pasteTiming(for: "com.apple.RemoteDesktop"), .oneSecond)
        XCTAssertEqual(restored.insertBehavior, .copyOnly)
        XCTAssertEqual(restored.streamingMode(for: "test.chat"), .appendOnly)
        XCTAssertEqual(restored.insertBehavior(for: "test.chat"), .copyOnly)
    }

    func testInvalidInsertionAndTimingEntriesDoNotDiscardValidEntriesOrLegacyModes() {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["test.valid": "copyOnly", "test.future": "unknown", " ": "typeOnly"],
                     forKey: AppSettings.Keys.applicationInsertBehaviors)
        defaults.set(["test.valid": "fiveSeconds", "test.future": "unknown", " ": "oneSecond"],
                     forKey: AppSettings.Keys.applicationPasteTimings)
        defaults.set(["test.old": "appendOnly"], forKey: AppSettings.Keys.applicationStreamingModes)
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.applicationInsertBehaviors, ["test.valid": .copyOnly])
        XCTAssertEqual(settings.applicationPasteTimings, ["test.valid": .fiveSeconds])
        XCTAssertEqual(settings.streamingMode(for: "test.old"), .appendOnly)
        settings.useRemoteDesktopPreset(for: " ", name: "Invalid")
        XCTAssertEqual(settings.applicationOverrideIdentifiers, ["test.valid", "test.old"])
    }

    private func defaults() -> (UserDefaults, String) {
        let name = "StreamingInsertionModeTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }
}

@MainActor
private final class ModeInsertion: LiveDictationInserting {
    var begins = 0
    var cancels = 0
    var texts: [String] = []
    var result: LiveInsertionResult = .inserted
    func begin() { begins += 1 }
    func update(_ transcript: String) async -> LiveInsertionResult { texts.append(transcript); return result }
    func cancel() { cancels += 1 }
}
