import XCTest
@testable import HorseWhisprer

@MainActor
final class FreeDistributionTests: XCTestCase {
    func testBothDistributionsStartAndFinishWithoutActivation() async {
        for flavor in [AppDistributionFlavor.official, .community] {
            let suite = "FreeDistributionTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = AppSettings(defaults: defaults)
            settings.selectedModelID = "base.en"
            settings.insertBehavior = .copyOnly
            settings.playRecordingCues = false
            settings.escapeCancelsDictation = false
            // Legacy preferences must not affect the free version.
            defaults.set("expired-device", forKey: "licensing.deviceID.v2")
            let session = SessionFixture(settings: settings)
            let storage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: storage) }
            let model = AppModel(
                settings: settings, distribution: AppDistribution(flavor: flavor),
                historyStore: TranscriptHistoryStore(retention: .untilQuit, fileURL: nil),
                coordinator: session.coordinator,
                modelInstallService: ModelInstallService(modelCatalog: ModelCatalogService(),
                                                         storageDirectory: storage.appendingPathComponent("Whisper")),
                nativeModelStore: NativeModelStore(root: storage.appendingPathComponent("Native")),
                triggerController: FreeDistributionTrigger(), startsBackgroundServices: false)

            await model.toggleDictation()
            XCTAssertTrue(model.isRecording, "\(flavor) must start without an entitlement")
            await model.toggleDictation()
            XCTAssertEqual(session.insertion.texts, ["test dictation"])
            XCTAssertFalse(model.isRecording)
            XCTAssertNil(model.lastError)
            model.prepareForTermination()
        }
    }

    func testSettingsExposeAboutInsteadOfActivation() {
        XCTAssertTrue(SettingsTab.allCases.contains(.about))
        XCTAssertFalse(SettingsTab.allCases.map(\.rawValue).contains("license"))
    }
}

private final class FreeDistributionTrigger: TriggerRegistering {
    func register(_ configuration: TriggerConfiguration, style: TriggerStyle,
                  canUseSpecialKeyMonitoring: Bool,
                  handler: @escaping (TriggerEvent) -> Void) -> TriggerRegistrationResult { .registered }
    func unregister() {}
}
