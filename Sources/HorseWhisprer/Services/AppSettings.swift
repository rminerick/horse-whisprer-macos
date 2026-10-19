import Foundation

final class AppSettings: ObservableObject {
    @Published var whisperCLIPath: String {
        didSet { save() }
    }

    @Published var modelDirectoryPath: String {
        didSet { save() }
    }

    @Published var selectedModelID: String {
        didSet { save() }
    }

    @Published var languageCode: String {
        didSet { save() }
    }

    @Published var hotKeyBinding: HotKeyBinding {
        didSet { save() }
    }

    @Published var triggerMode: TriggerMode {
        didSet { save() }
    }

    @Published var specialKeyTrigger: SpecialKeyTrigger {
        didSet { save() }
    }

    @Published var insertBehavior: InsertBehavior {
        didSet { save() }
    }

    @Published var streamingInsertionMode: StreamingInsertionMode {
        didSet { save() }
    }

    @Published private(set) var applicationStreamingModes: [String: StreamingInsertionMode] {
        didSet { save() }
    }
    @Published private(set) var applicationStreamingNames: [String: String] {
        didSet { save() }
    }

    @Published private(set) var applicationInsertBehaviors: [String: InsertBehavior] {
        didSet { save() }
    }
    @Published private(set) var applicationPasteTimings: [String: ClipboardPasteTiming] {
        didSet { save() }
    }

    var applicationOverrideIdentifiers: Set<String> {
        Set(applicationStreamingModes.keys)
            .union(applicationInsertBehaviors.keys).union(applicationPasteTimings.keys)
    }

    func insertBehavior(for bundleIdentifier: String?) -> InsertBehavior {
        bundleIdentifier.flatMap { applicationInsertBehaviors[$0] } ?? insertBehavior
    }

    func pasteTiming(for bundleIdentifier: String?) -> ClipboardPasteTiming {
        bundleIdentifier.flatMap { applicationPasteTimings[$0] } ?? .standard
    }

    func setInsertOverride(for identifier: String, name: String, behavior: InsertBehavior?) {
        guard !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        applicationInsertBehaviors[identifier] = behavior
        updateApplicationName(identifier, name: name)
    }

    func setPasteTimingOverride(for identifier: String, name: String, timing: ClipboardPasteTiming?) {
        guard !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        applicationPasteTimings[identifier] = timing
        updateApplicationName(identifier, name: name)
    }

    func useRemoteDesktopPreset(for identifier: String, name: String) {
        setStreamingOverride(for: identifier, name: name, mode: .onStop)
        setInsertOverride(for: identifier, name: name, behavior: .pasteThenType)
        setPasteTimingOverride(for: identifier, name: name, timing: .oneSecond)
    }

    func removeApplicationOverrides(for identifier: String) {
        applicationStreamingModes[identifier] = nil
        applicationInsertBehaviors[identifier] = nil
        applicationPasteTimings[identifier] = nil
        applicationStreamingNames[identifier] = nil
    }

    private func updateApplicationName(_ identifier: String, name: String) {
        applicationStreamingNames[identifier] = applicationOverrideIdentifiers.contains(identifier) ? name : nil
    }

    func streamingMode(for bundleIdentifier: String?) -> StreamingInsertionMode {
        bundleIdentifier.flatMap { applicationStreamingModes[$0] } ?? streamingInsertionMode
    }

    func setStreamingOverride(for bundleIdentifier: String, name: String, mode: StreamingInsertionMode?) {
        guard !bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        applicationStreamingModes[bundleIdentifier] = mode
        updateApplicationName(bundleIdentifier, name: name)
    }

    /// Compatibility for the existing on/off control and older preferences.
    var liveStreamingInsertion: Bool {
        get { streamingInsertionMode != .onStop }
        set {
            if !newValue { streamingInsertionMode = .onStop }
            else if streamingInsertionMode == .onStop { streamingInsertionMode = .verified }
        }
    }

    @Published var disableGPU: Bool {
        didSet { save() }
    }

    @Published var playRecordingCues: Bool {
        didSet { save() }
    }

    @Published var dictationOutputAudioBehavior: DictationOutputAudioBehavior {
        didSet { save() }
    }

    @Published var startRecordingCueSoundName: String {
        didSet { save() }
    }

    @Published var stopRecordingCueSoundName: String {
        didSet { save() }
    }

    @Published var hasCompletedOnboarding: Bool {
        didSet { save() }
    }

    @Published var menuBarStyle: MenuBarStyle {
        didSet { save() }
    }

    @Published var showsDictationPill: Bool {
        didSet { save() }
    }

    @Published var showsDockIcon: Bool {
        didSet { save() }
    }

    @Published var triggerStyle: TriggerStyle {
        didSet { save() }
    }

    @Published var escapeCancelsDictation: Bool {
        didSet { save() }
    }

    @Published var historyRetention: HistoryRetention {
        didSet { save() }
    }

    /// Names and jargon passed to Whisper as its initial prompt.
    @Published var vocabularyTerms: String {
        didSet { save() }
    }

    @Published var textReplacements: [TextReplacementRule] {
        didSet { save() }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        whisperCLIPath = defaults.string(forKey: Keys.whisperCLIPath) ?? ""
        modelDirectoryPath = defaults.string(forKey: Keys.modelDirectoryPath) ?? ""
        selectedModelID = defaults.string(forKey: Keys.selectedModelID) ?? Self.defaultModelID
        languageCode = defaults.string(forKey: Keys.languageCode) ?? "auto"
        if let configurationData = defaults.data(forKey: Keys.triggerConfiguration),
           let decodedConfiguration = try? JSONDecoder().decode(TriggerConfiguration.self, from: configurationData) {
            hotKeyBinding = decodedConfiguration.hotKeyBinding
            triggerMode = decodedConfiguration.mode
            specialKeyTrigger = decodedConfiguration.specialKeyTrigger
        } else if let bindingData = defaults.data(forKey: Keys.hotKeyBinding),
                  let decodedBinding = try? JSONDecoder().decode(HotKeyBinding.self, from: bindingData),
                  decodedBinding.isValid {
            hotKeyBinding = decodedBinding
            triggerMode = .standardHotKey
            specialKeyTrigger = .rightCommandTapAlone
        } else if let legacyRawValue = defaults.string(forKey: Keys.hotKeyPreset),
                  let legacyPreset = LegacyHotKeyPreset(rawValue: legacyRawValue) {
            hotKeyBinding = legacyPreset.binding
            triggerMode = .standardHotKey
            specialKeyTrigger = .rightCommandTapAlone
        } else {
            hotKeyBinding = .defaultBinding
            triggerMode = .standardHotKey
            specialKeyTrigger = .rightCommandTapAlone
        }
        insertBehavior = InsertBehavior(rawValue: defaults.string(forKey: Keys.insertBehavior) ?? "") ?? .pasteThenType
        streamingInsertionMode = StreamingInsertionMode(rawValue: defaults.string(forKey: Keys.streamingInsertionMode) ?? "")
            ?? ((defaults.object(forKey: Keys.liveStreamingInsertion) as? Bool ?? true) ? .verified : .onStop)
        let storedModes = defaults.dictionary(forKey: Keys.applicationStreamingModes) ?? [:]
        applicationStreamingModes = storedModes.reduce(into: [:]) { modes, entry in
            guard !entry.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let raw = entry.value as? String, let mode = StreamingInsertionMode(rawValue: raw) else { return }
            modes[entry.key] = mode
        }
        applicationInsertBehaviors = (defaults.dictionary(forKey: Keys.applicationInsertBehaviors) ?? [:]).reduce(into: [:]) { result, entry in
            guard !entry.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let raw = entry.value as? String, let behavior = InsertBehavior(rawValue: raw) else { return }
            result[entry.key] = behavior
        }
        applicationPasteTimings = (defaults.dictionary(forKey: Keys.applicationPasteTimings) ?? [:]).reduce(into: [:]) { result, entry in
            guard !entry.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let raw = entry.value as? String, let timing = ClipboardPasteTiming(rawValue: raw) else { return }
            result[entry.key] = timing
        }
        applicationStreamingNames = defaults.dictionary(forKey: Keys.applicationStreamingNames) as? [String: String] ?? [:]
        disableGPU = defaults.bool(forKey: Keys.disableGPU)
        if defaults.object(forKey: Keys.playRecordingCues) == nil {
            playRecordingCues = true
        } else {
            playRecordingCues = defaults.bool(forKey: Keys.playRecordingCues)
        }
        dictationOutputAudioBehavior = DictationOutputAudioBehavior(
            rawValue: defaults.string(forKey: Keys.dictationOutputAudioBehavior) ?? ""
        ) ?? .off
        startRecordingCueSoundName = RecordingCueSoundCatalog.normalizedSoundName(
            defaults.string(forKey: Keys.startRecordingCueSound),
            fallback: RecordingCueSoundCatalog.defaultStartName
        )
        stopRecordingCueSoundName = RecordingCueSoundCatalog.normalizedSoundName(
            defaults.string(forKey: Keys.stopRecordingCueSound),
            fallback: RecordingCueSoundCatalog.defaultStopName
        )
        hasCompletedOnboarding = defaults.bool(forKey: Keys.hasCompletedOnboarding)
        menuBarStyle = MenuBarStyle(rawValue: defaults.string(forKey: Keys.menuBarStyle) ?? "") ?? .popover
        showsDictationPill = defaults.object(forKey: Keys.showsDictationPill) as? Bool ?? true
        showsDockIcon = defaults.bool(forKey: Keys.showsDockIcon)
        triggerStyle = TriggerStyle(rawValue: defaults.string(forKey: Keys.triggerStyle) ?? "") ?? .toggle
        escapeCancelsDictation = defaults.object(forKey: Keys.escapeCancelsDictation) as? Bool ?? true
        historyRetention = HistoryRetention(rawValue: defaults.string(forKey: Keys.historyRetention) ?? "") ?? .untilQuit
        vocabularyTerms = defaults.string(forKey: Keys.vocabularyTerms) ?? ""
        if let replacementData = defaults.data(forKey: Keys.textReplacements),
           let decodedReplacements = try? JSONDecoder().decode([TextReplacementRule].self, from: replacementData) {
            textReplacements = decodedReplacements
        } else {
            textReplacements = []
        }
        clearLegacyLicensingSettings()
    }

    /// New installs start on Parakeet where Core ML models can run; Intel Macs keep Whisper.
    static var defaultModelID: String {
        NativeASRRuntime.isSupported ? "parakeet-unified" : "base.en"
    }

    /// Whisper's initial prompt, or nil when no vocabulary is set.
    var vocabularyPrompt: String? {
        let trimmed = vocabularyTerms.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var triggerConfiguration: TriggerConfiguration {
        TriggerConfiguration(
            mode: triggerMode,
            hotKeyBinding: hotKeyBinding,
            specialKeyTrigger: specialKeyTrigger
        )
    }

    private func save() {
        defaults.set(whisperCLIPath, forKey: Keys.whisperCLIPath)
        defaults.set(modelDirectoryPath, forKey: Keys.modelDirectoryPath)
        defaults.set(selectedModelID, forKey: Keys.selectedModelID)
        defaults.set(languageCode, forKey: Keys.languageCode)
        if let encodedBinding = try? JSONEncoder().encode(hotKeyBinding) {
            defaults.set(encodedBinding, forKey: Keys.hotKeyBinding)
        }
        if let encodedTriggerConfiguration = try? JSONEncoder().encode(triggerConfiguration) {
            defaults.set(encodedTriggerConfiguration, forKey: Keys.triggerConfiguration)
        }
        defaults.set(insertBehavior.rawValue, forKey: Keys.insertBehavior)
        defaults.set(applicationStreamingModes.mapValues(\.rawValue), forKey: Keys.applicationStreamingModes)
        defaults.set(applicationInsertBehaviors.mapValues(\.rawValue), forKey: Keys.applicationInsertBehaviors)
        defaults.set(applicationPasteTimings.mapValues(\.rawValue), forKey: Keys.applicationPasteTimings)
        defaults.set(applicationStreamingNames, forKey: Keys.applicationStreamingNames)
        defaults.set(streamingInsertionMode.rawValue, forKey: Keys.streamingInsertionMode)
        defaults.set(liveStreamingInsertion, forKey: Keys.liveStreamingInsertion)
        defaults.set(disableGPU, forKey: Keys.disableGPU)
        defaults.set(playRecordingCues, forKey: Keys.playRecordingCues)
        defaults.set(dictationOutputAudioBehavior.rawValue, forKey: Keys.dictationOutputAudioBehavior)
        defaults.set(startRecordingCueSoundName, forKey: Keys.startRecordingCueSound)
        defaults.set(stopRecordingCueSoundName, forKey: Keys.stopRecordingCueSound)
        defaults.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding)
        defaults.set(menuBarStyle.rawValue, forKey: Keys.menuBarStyle)
        defaults.set(showsDictationPill, forKey: Keys.showsDictationPill)
        defaults.set(showsDockIcon, forKey: Keys.showsDockIcon)
        defaults.set(triggerStyle.rawValue, forKey: Keys.triggerStyle)
        defaults.set(escapeCancelsDictation, forKey: Keys.escapeCancelsDictation)
        defaults.set(historyRetention.rawValue, forKey: Keys.historyRetention)
        defaults.set(vocabularyTerms, forKey: Keys.vocabularyTerms)
        if let encodedReplacements = try? JSONEncoder().encode(textReplacements) {
            defaults.set(encodedReplacements, forKey: Keys.textReplacements)
        }
        clearLegacyLicensingSettings()
    }

    private func clearLegacyLicensingSettings() {
        defaults.removeObject(forKey: Keys.localTrialGrace)
        defaults.removeObject(forKey: Keys.trialStartedAt)
        defaults.removeObject(forKey: Keys.licenseEmail)
        defaults.removeObject(forKey: Keys.installationID)
        defaults.removeObject(forKey: Keys.licenseAPIBaseURL)
        defaults.removeObject(forKey: Keys.licenseDeviceID)
    }

    enum Keys {
        static let whisperCLIPath = "settings.whisperCLIPath"
        static let modelDirectoryPath = "settings.modelDirectoryPath"
        static let selectedModelID = "settings.selectedModelID"
        static let languageCode = "settings.languageCode"
        static let triggerConfiguration = "settings.triggerConfiguration"
        static let hotKeyBinding = "settings.hotKeyBinding"
        static let hotKeyPreset = "settings.hotKeyPreset"
        static let insertBehavior = "settings.insertBehavior"
        static let applicationInsertBehaviors = "settings.applicationInsertBehaviors"
        static let applicationPasteTimings = "settings.applicationPasteTimings"
        static let applicationStreamingModes = "settings.applicationStreamingModes"
        static let applicationStreamingNames = "settings.applicationStreamingNames"
        static let streamingInsertionMode = "settings.streamingInsertionMode"
        static let liveStreamingInsertion = "settings.liveStreamingInsertion"
        static let disableGPU = "settings.disableGPU"
        static let playRecordingCues = "settings.playRecordingCues"
        static let dictationOutputAudioBehavior = "settings.dictationOutputAudioBehavior"
        static let startRecordingCueSound = "settings.startRecordingCueSound"
        static let stopRecordingCueSound = "settings.stopRecordingCueSound"
        static let hasCompletedOnboarding = "settings.hasCompletedOnboarding"
        static let menuBarStyle = "settings.menuBarStyle"
        static let showsDictationPill = "settings.showsDictationPill"
        static let showsDockIcon = "settings.showsDockIcon"
        static let triggerStyle = "settings.triggerStyle"
        static let escapeCancelsDictation = "settings.escapeCancelsDictation"
        static let historyRetention = "settings.historyRetention"
        static let vocabularyTerms = "settings.vocabularyTerms"
        static let textReplacements = "settings.textReplacements"
        static let localTrialGrace = "settings.localTrialGrace"
        static let trialStartedAt = "settings.trialStartedAt"
        static let licenseEmail = "settings.licenseEmail"
        static let installationID = "settings.installationID"
        static let licenseAPIBaseURL = "settings.licenseAPIBaseURL"
        static let licenseDeviceID = "licensing.deviceID"
    }
}
