import AppKit
import Carbon
import Combine
import Foundation
import OSLog
import ServiceManagement
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: AppSettings
    @Published var isRecording = false
    @Published var isBusy = false
    private var isTestingInsertion = false
    @Published var statusMessage = "Idle"
    @Published var partialTranscript: String?
    var lastResult: String? { historyStore.latestTranscript }
    @Published var lastError: String?
    @Published var lastInsertionAttempt: InsertionAttemptRecord?
    @Published var showsOnboardingWizard = false
    @Published var onboardingStep: OnboardingStep = .welcome
    @Published var activeModelActionError: String?
    @Published private(set) var activity: DictationActivity = .idle
    @Published private(set) var recordingStartedAt: Date?
    @Published var selectedSettingsTab: SettingsTab = .general
    @Published private(set) var launchAtLoginError: String?

    let modelCatalog: ModelCatalogService
    let modelInstallService: ModelInstallService
    let permissionService: PermissionService
    let textInsertionService: TextInsertionService
    let triggerController: any TriggerRegistering
    let recordingController: RecordingController
    let recordingFeedbackService: RecordingFeedbackService
    let transcriptionCoordinator: TranscriptionCoordinator
    let whisperEngine: WhisperCLIEngine
    let nativeModelStore: NativeModelStore
    let nativeRuntime: NativeASRRuntime
    let distribution: AppDistribution
    let historyStore: TranscriptHistoryStore

    /// Runs before a session starts, for example to hand focus back from the popover.
    var prepareForDictationStart: (@MainActor () async -> Void)?
    var checkForUpdatesAction: (@MainActor () -> Void)?

    private let escapeHotKey = HotKeyController(identifier: 2)
    private var holdIsActive = false
    private var triggerConfigurationPending = false
    private var cancelWhenStarted = false
    private var toggleInFlight = false
    private var isTerminating = false
    private var isRemovingNativeModel = false
    private var cancellables = Set<AnyCancellable>()

    init(settings: AppSettings = AppSettings(),
         distribution: AppDistribution = .current(),
         historyStore: TranscriptHistoryStore? = nil,
         coordinator: TranscriptionCoordinator? = nil,
         modelInstallService: ModelInstallService? = nil,
         nativeModelStore: NativeModelStore? = nil,
         triggerController: any TriggerRegistering = TriggerController(),
         startsBackgroundServices: Bool = true) {
        let catalog = ModelCatalogService()
        let modelInstallService = modelInstallService ?? ModelInstallService(modelCatalog: catalog)
        let permissions = PermissionService()
        let insertion = TextInsertionService()
        let recorder = RecordingController()
        let recordingFeedback = RecordingFeedbackService(settings: settings)
        let recordingOutputAudio = RecordingOutputAudioService(settings: settings)
        let whisper = WhisperCLIEngine(settings: settings)
        let native = NativeASRRuntime()
        let nativeModels = nativeModelStore ?? NativeModelStore()
        let engine = DictationEngineRouter(whisper: whisper, native: native)
        let historyStore = historyStore ?? TranscriptHistoryStore(retention: settings.historyRetention)
        let coordinator = coordinator ?? TranscriptionCoordinator(
            settings: settings,
            permissionService: permissions,
            recordingController: recorder,
            recordingFeedbackService: recordingFeedback,
            outputAudioService: recordingOutputAudio,
            textInsertionService: insertion,
            engine: engine,
            modelCatalog: catalog
        )

        self.settings = settings
        self.modelCatalog = catalog
        self.modelInstallService = modelInstallService
        self.permissionService = permissions
        self.textInsertionService = insertion
        self.triggerController = triggerController
        self.recordingController = recorder
        self.recordingFeedbackService = recordingFeedback
        self.transcriptionCoordinator = coordinator
        self.whisperEngine = whisper
        self.nativeRuntime = native
        self.nativeModelStore = nativeModels
        self.distribution = distribution
        self.historyStore = historyStore
        insertion.onInsertionAttempt = { [weak self] record in
            self?.lastInsertionAttempt = record
        }

        bindCoordinator()
        bindInstaller()
        // Settings and history are separate observable objects; forward their
        // changes so anything observing the app model stays current.
        settings.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        historyStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        settings.$historyRetention.dropFirst().sink { [weak self] retention in
            self?.historyStore.setRetention(retention)
        }.store(in: &cancellables)
        settings.$triggerStyle.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.configureTrigger() }
        }.store(in: &cancellables)
        settings.$escapeCancelsDictation.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateEscapeHotKey() }
        }.store(in: &cancellables)
        evaluateOnboardingState(forcePresentation: !settings.hasCompletedOnboarding)
        guard startsBackgroundServices else { return }
        Task { @MainActor [weak self] in
            if self?.permissionService.microphoneGranted == true {
                await self?.prepareRecordingInput()
            }
        }
        settings.$selectedModelID.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in
                if self?.permissionService.microphoneGranted == true { await self?.prepareRecordingInput() }
            }
        }.store(in: &cancellables)
        settings.$playRecordingCues.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in
                if self?.permissionService.microphoneGranted == true { await self?.prepareRecordingInput() }
            }
        }.store(in: &cancellables)
    }

    var selectedModel: ASRModelDescriptor {
        modelCatalog.model(for: settings.selectedModelID) ?? modelCatalog.defaultModel
    }

    private func prepareRecordingInput() async {
        guard !isRecording, !isBusy else { return }
        if selectedModel.engineKind.isStreaming {
            recordingController.discardPreparedRecording()
            transcriptionCoordinator.prepareStreamingCapture()
        } else {
            await recordingController.prepareForRecording(shouldWarmInput: shouldPrewarmRecordingInput)
        }
    }

    var engineDisplayName: String {
        selectedModel.engineKind.displayName
    }

    private var shouldPrewarmRecordingInput: Bool {
        settings.dictationOutputAudioBehavior != .off
    }

    var isRuntimeConfigured: Bool {
        selectedModel.engineKind == .whisper ? whisperEngine.isConfigured() : NativeASRRuntime.isSupported
    }

    var runtimeStatusSummary: String {
        if selectedModel.engineKind != .whisper {
            return NativeASRRuntime.isSupported ? "Built-in Core ML runtime" : "Requires Apple Silicon"
        }
        if let path = whisperEngine.resolvedCLIPath()?.path {
            return path
        }

        return "No whisper-cli runtime found"
    }

    func previewCue(named cueID: String) {
        Task { @MainActor [weak self] in
            await self?.recordingFeedbackService.previewCue(named: cueID)
        }
    }

    func prepareForTermination() {
        isTerminating = true
        cancellables.removeAll()
        triggerController.unregister()
        escapeHotKey.unregister()
        modelInstallService.cancelAll()
        nativeModelStore.cancelAll()
        transcriptionCoordinator.prepareForTermination()
        isRecording = false
        isBusy = false
        statusMessage = "Quitting"
    }

    var managedModelDirectoryPath: String {
        (try? AppPaths.managedWhisperModelsDirectory().path) ?? "Unavailable"
    }

    var usesSpecialKeyTrigger: Bool {
        settings.triggerMode == .specialKey
    }

    var statusSummary: String {
        dictationStatusSummary(
            isRecording: isRecording, isBusy: isBusy, status: statusMessage,
            requiresSetup: !setupIssues.isEmpty, lastError: lastError)
    }

    var distributionSummary: String {
        distribution.displayName
    }

    var updatesEnabled: Bool {
        SparkleUpdateService.isAvailable()
    }

    var updatesSummary: String {
        distribution.updatesSummary
    }

    var setupIssues: [SetupIssue] {
        var issues: [SetupIssue] = []

        if !permissionService.microphoneGranted {
            issues.append(.microphonePermission)
        }

        if settings.insertBehavior != .copyOnly && !permissionService.accessibilityGranted {
            issues.append(.accessibilityPermission)
        }

        if usesSpecialKeyTrigger && !permissionService.inputMonitoringGranted {
            issues.append(.inputMonitoringPermission)
        }

        if selectedModel.engineKind == .whisper && !whisperEngine.isConfigured() {
            issues.append(.whisperCLI)
        }

        if !isSelectedModelAvailable {
            issues.append(.selectedModel)
        }

        return issues
    }

    var setupPromptSummary: String? {
        guard !setupIssues.isEmpty else { return nil }
        return setupIssues.map(\.title).joined(separator: "\n")
    }

    var shouldPromptForSetup: Bool {
        !settings.hasCompletedOnboarding || !setupIssues.isEmpty
    }

    var isSelectedModelAvailable: Bool {
        if selectedModel.engineKind != .whisper {
            return NativeASRRuntime.isSupported && nativeModelStore.directory(for: selectedModel) != nil
        }
        return whisperEngine.resolvedModelPathIfAvailable(for: selectedModel) != nil
    }

    func installState(for model: ASRModelDescriptor) -> ModelInstallState {
        if model.engineKind != .whisper { return nativeModelStore.state(for: model) }
        if let resolvedURL = whisperEngine.resolvedModelPathIfAvailable(for: model) {
            if let installedRecord = modelInstallService.installedRecord(for: model.id),
               resolvedURL.lastPathComponent == installedRecord.relativePath {
                return .installed(installedRecord)
            }

            let fileSize = (try? resolvedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            let record = InstalledModelRecord(
                modelID: model.id,
                relativePath: resolvedURL.lastPathComponent,
                fileSizeBytes: fileSize,
                sha256: "",
                installedAt: Date.distantPast
            )
            return .installed(record)
        }

        return modelInstallService.state(for: model)
    }

    func resolvedModelPath(for model: ASRModelDescriptor) -> String? {
        if model.engineKind != .whisper { return nativeModelStore.directory(for: model)?.path }
        return whisperEngine.resolvedModelPathIfAvailable(for: model)?.path
    }

    func canRemoveManagedModel(_ model: ASRModelDescriptor) -> Bool {
        if model.engineKind != .whisper { return nativeModelStore.directory(for: model) != nil }
        return modelInstallService.installedRecord(for: model.id) != nil
    }

    func installSelectedModel() {
        install(selectedModel)
    }

    func install(_ model: ASRModelDescriptor) {
        activeModelActionError = nil
        if model.engineKind == .whisper { modelInstallService.install(model) }
        else { nativeModelStore.install(model) }
        evaluateOnboardingState()
    }

    func cancelInstall(_ model: ASRModelDescriptor) {
        if model.engineKind == .whisper { modelInstallService.cancel(modelID: model.id) }
        else { nativeModelStore.cancel(model) }
        evaluateOnboardingState()
    }

    func removeManagedModel(_ model: ASRModelDescriptor) {
        activeModelActionError = nil

        guard !isRecording, !isBusy else {
            activeModelActionError = "Stop dictation before removing a model."
            return
        }
        do {
            if model.engineKind == .whisper { try modelInstallService.remove(model) }
            else {
                isBusy = true
                isRemovingNativeModel = true
                Task {
                    defer { isBusy = false; isRemovingNativeModel = false }
                    await nativeRuntime.unload()
                    do { try nativeModelStore.remove(model) }
                    catch { activeModelActionError = error.localizedDescription }
                    evaluateOnboardingState()
                }
            }
            evaluateOnboardingState()
        } catch {
            activeModelActionError = error.localizedDescription
        }
    }

    func revealManagedModelDirectory() {
        guard let url = selectedModel.engineKind == .whisper
            ? try? AppPaths.managedWhisperModelsDirectory() : NativeModelStore.defaultRoot else {
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func configureTrigger() {
        guard !isTerminating else { return }
        // Re-registering would discard the detector that owes us a key release.
        // Keep it alive until the hold ends, including while startup is awaiting.
        guard !holdIsActive else {
            triggerConfigurationPending = true
            return
        }
        triggerConfigurationPending = false
        let result = triggerController.register(
            settings.triggerConfiguration,
            style: settings.triggerStyle,
            canUseSpecialKeyMonitoring: permissionService.canUseSpecialKeyMonitoring
        ) { [weak self] event in
            Task { @MainActor [weak self] in
                await self?.handleTrigger(event)
            }
        }

        switch result {
        case .registered:
            if lastError == "Input Monitoring is required for special-key triggers." {
                lastError = nil
            }
        case .requiresInputMonitoring:
            lastError = "Input Monitoring is required for special-key triggers."
        case .failed(let message):
            lastError = message
        }
    }

    func updateHotKeyBinding(_ binding: HotKeyBinding) {
        guard binding.isValid else {
            lastError = "Shortcut must include at least one modifier and one non-modifier key."
            return
        }

        settings.hotKeyBinding = binding
        settings.triggerMode = .standardHotKey
        configureTrigger()
        statusMessage = "Hotkey updated"
        lastError = nil
    }

    func resetHotKeyBinding() {
        updateHotKeyBinding(.defaultBinding)
    }

    func updateTriggerMode(_ mode: TriggerMode) {
        settings.triggerMode = mode
        refreshPermissions(promptAccessibility: false)
        configureTrigger()
        statusMessage = mode == .specialKey ? "Special key trigger selected" : "Standard shortcut selected"
    }

    func updateSpecialKeyTrigger(_ trigger: SpecialKeyTrigger) {
        settings.specialKeyTrigger = trigger
        settings.triggerMode = .specialKey
        refreshPermissions(promptAccessibility: false)
        configureTrigger()
        statusMessage = "Special key trigger updated"
    }

    func handleTrigger(_ event: TriggerEvent) async {
        switch event {
        case .toggle:
            await toggleDictation()
        case .holdBegan:
            holdIsActive = true
            guard !isRecording, !isBusy else { return }
            await toggleDictation()
            // The key came up while the session was still starting.
            if !holdIsActive, isRecording {
                await toggleDictation()
            }
        case .holdEnded:
            holdIsActive = false
            defer {
                if triggerConfigurationPending { configureTrigger() }
            }
            if isRecording {
                await toggleDictation()
            }
        }
    }

    /// Stops the session in flight and throws its audio and text away.
    func cancelDictation() async {
        if activity == .starting {
            cancelWhenStarted = true
            return
        }
        await transcriptionCoordinator.cancelDictation()
    }

    func toggleDictation() async {
        // Own the whole command, including focus restoration,
        // before any await can allow a second trigger to enter.
        guard !isTestingInsertion else { return }
        guard !isRemovingNativeModel, !isTerminating, !toggleInFlight else { return }
        toggleInFlight = true
        defer { toggleInFlight = false }

        if !isRecording, !isBusy {
            cancelWhenStarted = false
            apply(CoordinatorState(isRecording: false, isBusy: true, status: "Starting…",
                                   transcribedText: nil, errorMessage: nil, activity: .starting))
            await prepareForDictationStart?()
            guard !isTerminating else { return }
            if cancelWhenStarted {
                cancelWhenStarted = false
                apply(CoordinatorState(isRecording: false, isBusy: false, status: "Cancelled",
                                       transcribedText: nil, errorMessage: nil, activity: .cancelled))
                return
            }
        }

        do {
            let result = try await transcriptionCoordinator.toggleDictation()
            apply(result)
            if cancelWhenStarted, isRecording {
                cancelWhenStarted = false
                await transcriptionCoordinator.cancelDictation()
            }
            let status = statusMessage
            let hasResult = lastResult != nil
            let hasError = lastError != nil
            Task.detached(priority: .utility) {
                Logger(subsystem: "com.rminerick.HorseWhisprer", category: "AppModel")
                    .info("toggleDictation completed status=\(status, privacy: .public) hasResult=\(hasResult, privacy: .public) hasError=\(hasError, privacy: .public)")
            }
        } catch {
            isRecording = false
            isBusy = false
            statusMessage = "Failed"
            lastError = error.localizedDescription
            recordingStartedAt = nil
            activity = .failed
            updateEscapeHotKey()
            let errorMessage = lastError ?? "unknown"
            Task.detached(priority: .utility) {
                Logger(subsystem: "com.rminerick.HorseWhisprer", category: "AppModel")
                    .error("toggleDictation failed error=\(errorMessage, privacy: .public)")
            }
        }
    }

    func refreshPermissions(promptAccessibility: Bool) {
        let hadInputMonitoring = permissionService.inputMonitoringGranted
        permissionService.refresh(promptAccessibility: promptAccessibility)
        if usesSpecialKeyTrigger, !hadInputMonitoring, permissionService.inputMonitoringGranted {
            configureTrigger()
        }
        evaluateOnboardingState()
        objectWillChange.send()
    }

    /// Cheap check for grants made in System Settings; publishes only when something changed.
    func pollPermissions() {
        let before = (permissionService.microphoneGranted, permissionService.accessibilityGranted,
                      permissionService.inputMonitoringGranted)
        permissionService.refresh(promptAccessibility: false)
        let after = (permissionService.microphoneGranted, permissionService.accessibilityGranted,
                     permissionService.inputMonitoringGranted)
        guard before != after else { return }

        if usesSpecialKeyTrigger, !before.2, after.2 {
            configureTrigger()
        }
        if !before.0, after.0 {
            Task { @MainActor [weak self] in
                await self?.prepareRecordingInput()
            }
        }
        evaluateOnboardingState()
        objectWillChange.send()
    }

    var triggerSummary: String {
        switch (settings.triggerMode, settings.triggerStyle) {
        case (.standardHotKey, .toggle):
            return settings.hotKeyBinding.displayString
        case (.standardHotKey, .hold):
            return "Hold \(settings.hotKeyBinding.displayString)"
        case (.specialKey, .toggle):
            return "\(settings.specialKeyTrigger.title) twice"
        case (.specialKey, .hold):
            return "Hold \(settings.specialKeyTrigger.title)"
        }
    }

    var triggerKeyCaps: [String] {
        switch settings.triggerMode {
        case .standardHotKey:
            return settings.hotKeyBinding.keyCaps
        case .specialKey:
            return settings.triggerStyle == .hold
                ? [settings.specialKeyTrigger.title]
                : [settings.specialKeyTrigger.title, "×2"]
        }
    }

    var triggerInstructions: String {
        switch (settings.triggerMode, settings.triggerStyle) {
        case (.standardHotKey, .toggle):
            return "Focus a text field and press \(settings.hotKeyBinding.displayString) to start. Press it again to stop and insert."
        case (.standardHotKey, .hold):
            return "Focus a text field, hold \(settings.hotKeyBinding.displayString) while you speak, and let go to insert."
        case (.specialKey, .toggle):
            return "Focus a text field and press \(settings.specialKeyTrigger.title) twice to start. Press it twice again to stop and insert."
        case (.specialKey, .hold):
            return "Focus a text field, hold \(settings.specialKeyTrigger.title) while you speak, and let go to insert."
        }
    }

    var targetApplicationName: String? {
        textInsertionService.currentTargetName
    }

    var installedModels: [ASRModelDescriptor] {
        modelCatalog.models.filter { model in
            if case .installed = installState(for: model) { return true }
            return false
        }
    }

    func selectModel(_ model: ASRModelDescriptor) {
        guard settings.selectedModelID != model.id else { return }
        settings.selectedModelID = model.id
        evaluateOnboardingState()
    }

    @discardableResult
    func copyToClipboard(_ text: String) -> Bool {
        textInsertionService.copyToClipboard(text)
    }

    func insertAgain(_ record: TranscriptRecord) async {
        let outcome = await textInsertionService.insert(text: record.text, settings: settings)
        statusMessage = "Insertion: \(outcome.label)"
    }

    var appVersionSummary: String {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (info?["CFBundleVersion"] as? String) ?? "?"
        return "\(version) (\(build))"
    }

    var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "Could not change the login item: \(error.localizedDescription)"
        }
        objectWillChange.send()
    }

    private func apply(_ state: CoordinatorState) {
        // @Published notifies even for equal assignments. State may also be
        // applied again when a coordinator command returns after its callback.
        if isRecording != state.isRecording { isRecording = state.isRecording }
        if isBusy != state.isBusy { isBusy = state.isBusy }
        if statusMessage != state.status { statusMessage = state.status }
        if lastError != state.errorMessage { lastError = state.errorMessage }
        if state.isRecording {
            if recordingStartedAt == nil { recordingStartedAt = Date() }
        } else if recordingStartedAt != nil {
            recordingStartedAt = nil
        }
        if activity != state.activity {
            activity = state.activity
        }
        updateEscapeHotKey()
    }

    /// Escape is claimed only while a session is in flight, so it keeps its
    /// normal meaning in every app the rest of the time.
    private func updateEscapeHotKey() {
        let shouldListen = settings.escapeCancelsDictation && activity.isInFlight
        if shouldListen, !escapeHotKey.isRegistered {
            escapeHotKey.register(HotKeyBinding(keyCode: UInt32(kVK_Escape), carbonModifiers: 0)) { [weak self] isPressed in
                guard isPressed else { return }
                Task { @MainActor [weak self] in
                    await self?.cancelDictation()
                }
            }
        } else if !shouldListen, escapeHotKey.isRegistered {
            escapeHotKey.unregister()
        }
    }

    func chooseCLIPath() {
        if let path = FilePicker.chooseFile() {
            settings.whisperCLIPath = path
            evaluateOnboardingState()
        }
    }

    func chooseModelDirectory() {
        if let path = FilePicker.chooseDirectory() {
            settings.modelDirectoryPath = path
            evaluateOnboardingState()
        }
    }

    /// Replays recognizer partials through the normal insertion paths without
    /// recording audio. The delay lets the user focus an empty test field.
    #if DEBUG
    func testStreamingInsertion(expectedBundleIdentifier: String) async {
        guard !isTestingInsertion, !isRecording, !isBusy else { return }
        isTestingInsertion = true
        defer { isTestingInsertion = false }
        statusMessage = "Click an empty target field. Insertion test starts in 10 seconds."
        do { try await Task.sleep(for: .seconds(10)) } catch { return }
        guard !isRecording, !isBusy, !Task.isCancelled,
              let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == expectedBundleIdentifier,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else {
            statusMessage = "Insertion test cancelled: the selected app is not in front."
            return
        }
        let bundle = app.bundleIdentifier
        let mode = settings.streamingMode(for: bundle)
        let behavior = settings.insertBehavior(for: bundle)
        let canDeliver: @MainActor @Sendable () -> Bool = {
            !Task.isCancelled
                && NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
        }
        let samples = ["Horse", "Horse Whisprer", "Horse Whisprer streaming test", "Horse Whisprer insertion test complete."]
        AudioDiagnostics.shared.log("InsertionTest", "begin target=\(bundle ?? "unknown") mode=\(mode.rawValue)")
        if mode == .onStop || behavior == .copyOnly {
            textInsertionService.captureInsertionTarget()
            let outcome = await textInsertionService.insert(text: samples.last!, behavior: behavior,
                pasteTiming: settings.pasteTiming(for: bundle), expectedBundleIdentifier: bundle,
                canDeliver: canDeliver)
            statusMessage = "Insertion test: \(outcome.label). Check the target field."
            AudioDiagnostics.shared.log("InsertionTest", "delivery=\(outcome.label)")
            return
        }
        let insertion = ConfigurableLiveTextInsertion()
        insertion.begin(mode: mode)
        defer { insertion.cancel() }
        var result = LiveInsertionResult.unavailable
        for (index, sample) in samples.enumerated() {
            guard canDeliver() else { statusMessage = "Insertion test cancelled: target lost focus."; return }
            if index == samples.count - 1 {
                result = await insertion.finish(sample)
            } else {
                result = await insertion.update(sample)
            }
            AudioDiagnostics.shared.log("InsertionTest", "step=\(index) result=\(result) reason=\(insertion.pauseReason?.rawValue ?? "none")")
            if result == .paused { break }
            if index < samples.count - 1 {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        statusMessage = "Streaming test: \(result). \(insertion.pauseReason?.message ?? "Check the target field.")"
    }
    #endif

    func testInsertion() async {
        guard !isTestingInsertion, !isRecording, !isBusy else { return }
        let sample = "Horse Whisprer insertion test at \(Date().formatted(date: .omitted, time: .standard))."
        let outcome = await textInsertionService.insert(text: sample, settings: settings)
        statusMessage = "Insertion: \(outcome.label)"
    }

    func evaluateOnboardingState(forcePresentation: Bool = false) {
        permissionService.refresh(promptAccessibility: false)

        if setupIssues.isEmpty {
            settings.hasCompletedOnboarding = true
            onboardingStep = .ready
            return
        }

        if forcePresentation {
            onboardingStep = .welcome
            showsOnboardingWizard = true
        }
    }

    func presentOnboardingWizard() {
        permissionService.refresh(promptAccessibility: false)
        onboardingStep = .welcome
        showsOnboardingWizard = true
    }

    func dismissOnboardingWizard() {
        settings.hasCompletedOnboarding = setupIssues.isEmpty
        showsOnboardingWizard = false
    }

    func nextOnboardingStep() {
        if onboardingStep == .ready {
            dismissOnboardingWizard()
            return
        }

        let nextIndex = min(onboardingStep.rawValue + 1, OnboardingStep.ready.rawValue)
        onboardingStep = OnboardingStep(rawValue: nextIndex) ?? .ready
    }

    func previousOnboardingStep() {
        let previousIndex = max(onboardingStep.rawValue - 1, OnboardingStep.welcome.rawValue)
        onboardingStep = OnboardingStep(rawValue: previousIndex) ?? .welcome
    }

    func grantMicrophoneAccess() async {
        let result = await permissionService.requestMicrophoneIfNeeded()

        switch result {
        case .granted:
            await prepareRecordingInput()
            statusMessage = "Microphone ready"
        case .deniedAfterPrompt:
            statusMessage = "Microphone access was denied"
        case .requiresSettings:
            permissionService.openMicrophoneSettings()
            statusMessage = "Enable microphone access in System Settings"
        }

        evaluateOnboardingState()
    }

    func openAccessibilitySettings() {
        permissionService.openAccessibilitySettings()
    }

    func requestInputMonitoringAccess() {
        permissionService.requestInputMonitoringIfNeeded()
        refreshPermissions(promptAccessibility: false)
        configureTrigger()
    }

    func openInputMonitoringSettings() {
        permissionService.openInputMonitoringSettings()
    }

    func openMicrophoneSettings() {
        permissionService.openMicrophoneSettings()
    }

    private func bindCoordinator() {
        transcriptionCoordinator.onPartialTranscript = { [weak self] text in
            guard self?.partialTranscript != text else { return }
            self?.partialTranscript = text
        }
        transcriptionCoordinator.onStateChange = { [weak self] state in
            self?.apply(state)
        }
        transcriptionCoordinator.onDictationCompleted = { [weak self] completed in
            guard let self else { return }
            self.historyStore.add(TranscriptRecord(
                text: completed.text,
                targetApplicationName: self.targetApplicationName,
                outcome: completed.delivery.label,
                modelName: completed.modelName,
                recordedDuration: completed.recordedDuration,
                reachedTarget: completed.delivery.reachedTarget
            ))
        }
    }

    private func bindInstaller() {
        nativeModelStore.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.evaluateOnboardingState()
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        modelInstallService.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.evaluateOnboardingState()
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }
}
