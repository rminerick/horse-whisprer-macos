import AppKit
import SwiftUI

@MainActor
struct OnboardingWizardView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var appModel: AppModel
    @State private var practiceText = ""

    private var allSteps: [OnboardingStep] {
        OnboardingStep.allCases
    }

    private var isDarkMode: Bool {
        colorScheme == .dark
    }

    private var triggerSummary: String {
        appModel.triggerSummary
    }

    var body: some View {
        HStack(spacing: 0) {
            wizardSidebar
            Divider()
            wizardContent
        }
        .frame(minWidth: 720, minHeight: 560)
        .background(
            LinearGradient(
                colors: [
                    isDarkMode
                        ? Color(red: 0.11, green: 0.12, blue: 0.15)
                        : Color(red: 0.97, green: 0.98, blue: 0.99),
                    isDarkMode
                        ? Color(red: 0.09, green: 0.10, blue: 0.13)
                        : Color(red: 0.94, green: 0.96, blue: 0.99)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var wizardSidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Setup")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text("Get Horse Whisprer ready without hunting through every setting.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(allSteps) { step in
                    WizardStepRow(
                        step: step,
                        currentStep: appModel.onboardingStep,
                        isComplete: isStepComplete(step)
                    )
                }
            }

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                Text("\(appModel.setupIssues.count) remaining issues")
                    .font(.subheadline.weight(.semibold))
                ForEach(appModel.setupIssues.prefix(3)) { issue in
                    Text(issue.title)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(24)
        .frame(width: 210, alignment: .topLeading)
    }

    private var wizardContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(appModel.onboardingStep.title)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("Step \(appModel.onboardingStep.rawValue + 1) of \(allSteps.count)")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Close") {
                    appModel.dismissOnboardingWizard()
                }
            }

            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()

            HStack {
                Button("Back") {
                    appModel.previousOnboardingStep()
                }
                .disabled(appModel.onboardingStep == .welcome)

                Spacer()

                if appModel.onboardingStep == .ready {
                    Button("Finish") {
                        appModel.dismissOnboardingWizard()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Next") {
                        appModel.nextOnboardingStep()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch appModel.onboardingStep {
        case .welcome:
            welcomeStep
        case .microphone:
            microphoneStep
        case .accessibility:
            accessibilityStep
        case .whisperBackend:
            backendStep
        case .ready:
            readyStep
        }
    }

    private var welcomeStep: some View {
        SectionCard(
            title: "What this app needs",
            subtitle: "Local dictation is straightforward once permissions, runtime, and a model are in place.",
            symbol: "sparkles",
            accent: Color(red: 0.10, green: 0.46, blue: 0.84)
        ) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Horse Whisprer records locally, transcribes with Whisper, Parakeet, or Nemotron on your Mac, and inserts the result into the current app.")
                    .fixedSize(horizontal: false, vertical: true)

                if appModel.setupIssues.isEmpty {
                    Text("Everything Horse Whisprer needs is already set up.")
                        .foregroundStyle(.green)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(appModel.setupIssues) { issue in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(issue.title)
                                    .font(.headline)
                                Text(issue.detail)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private var microphoneStep: some View {
        SectionCard(
            title: "Microphone",
            subtitle: "Without this, the app cannot capture dictation audio.",
            symbol: "mic.fill",
            accent: Color(red: 0.00, green: 0.56, blue: 0.54)
        ) {
            VStack(alignment: .leading, spacing: 16) {
                statusPill("Microphone", isReady: appModel.permissionService.microphoneGranted)

                Text("Raw macOS status: \(appModel.permissionService.microphoneAuthorizationStatusDescription)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        Button("Grant Microphone Access") {
                            Task { await appModel.grantMicrophoneAccess() }
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Open Microphone Settings") {
                            appModel.openMicrophoneSettings()
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Button("Grant Microphone Access") {
                            Task { await appModel.grantMicrophoneAccess() }
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Open Microphone Settings") {
                            appModel.openMicrophoneSettings()
                        }
                    }
                }

                if let guidance = appModel.permissionService.microphoneGuidance {
                    notice(guidance)
                }
            }
        }
    }

    private var accessibilityStep: some View {
        SectionCard(
            title: "Accessibility and keyboard monitoring",
            subtitle: "Accessibility enables insertion. Input Monitoring is only needed for special-key triggers.",
            symbol: "keyboard.fill",
            accent: Color(red: 0.91, green: 0.55, blue: 0.12)
        ) {
            VStack(alignment: .leading, spacing: 16) {
                statusPill("Accessibility", isReady: appModel.permissionService.accessibilityGranted)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        Button("Open Accessibility Settings") {
                            appModel.openAccessibilitySettings()
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Refresh Status") {
                            appModel.refreshPermissions(promptAccessibility: false)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Button("Open Accessibility Settings") {
                            appModel.openAccessibilitySettings()
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Refresh Status") {
                            appModel.refreshPermissions(promptAccessibility: false)
                        }
                    }
                }

                if let guidance = appModel.permissionService.accessibilityGuidance {
                    notice(guidance)
                }

                if appModel.usesSpecialKeyTrigger {
                    Divider()

                    statusPill("Input Monitoring", isReady: appModel.permissionService.inputMonitoringGranted)

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            Button("Enable Input Monitoring") {
                                appModel.requestInputMonitoringAccess()
                            }
                            .buttonStyle(.borderedProminent)

                            Button("Open Input Monitoring Settings") {
                                appModel.openInputMonitoringSettings()
                            }
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Button("Enable Input Monitoring") {
                                appModel.requestInputMonitoringAccess()
                            }
                            .buttonStyle(.borderedProminent)

                            Button("Open Input Monitoring Settings") {
                                appModel.openInputMonitoringSettings()
                            }
                        }
                    }

                    if let guidance = appModel.permissionService.inputMonitoringGuidance {
                        notice(guidance)
                    }
                }
            }
        }
    }

    private var backendStep: some View {
        let model = appModel.selectedModel
        let installState = appModel.installState(for: model)

        return SectionCard(
            title: "Runtime and model",
            subtitle: "The bundled runtime works by default. Download a model in-app unless you need a custom setup.",
            symbol: "shippingbox.fill",
            accent: Color(red: 0.46, green: 0.34, blue: 0.89)
        ) {
            VStack(alignment: .leading, spacing: 16) {
                statusPill(appModel.engineDisplayName, isReady: appModel.isRuntimeConfigured)
                statusPill("Selected model", isReady: appModel.isSelectedModelAvailable, readyText: installState.statusLabel)

                Picker("Model to download", selection: $appModel.settings.selectedModelID) {
                    ForEach(appModel.modelCatalog.models) { availableModel in
                        Text(availableModel.displayName).tag(availableModel.id)
                    }
                }

                Text(model.notes)
                    .foregroundStyle(.secondary)

                if let progress = installState.progressValue {
                    ProgressView(value: progress)
                }

                if let path = appModel.resolvedModelPath(for: model) {
                    Text(path)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        backendActions(for: model, state: installState)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        backendActions(for: model, state: installState)
                    }
                }

                DisclosureGroup("Advanced overrides") {
                    VStack(alignment: .leading, spacing: 14) {
                        pathField(
                            title: "Custom whisper-cli path",
                            text: $appModel.settings.whisperCLIPath,
                            browseAction: appModel.chooseCLIPath
                        )

                        pathField(
                            title: "Custom model directory",
                            text: $appModel.settings.modelDirectoryPath,
                            browseAction: appModel.chooseModelDirectory
                        )
                    }
                    .padding(.top, 10)
                }
            }
        }
    }

    private var readyStep: some View {
        SectionCard(
            title: "Ready to dictate",
            subtitle: "One last check before Horse Whisprer moves to the menu bar.",
            symbol: "checkmark.seal.fill",
            accent: Color.green
        ) {
            VStack(alignment: .leading, spacing: 16) {
                if appModel.setupIssues.isEmpty {
                    Text("The required permissions, runtime, and selected model are in place.")
                    statusPill("Trigger", isReady: true, readyText: triggerSummary)
                    Text(appModel.triggerInstructions)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Try it here")
                            .font(.subheadline.weight(.semibold))
                        TextEditor(text: $practiceText)
                            .font(.body)
                            .frame(height: 84)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.secondary.opacity(0.3))
                            )
                            .accessibilityLabel("Practice text field")
                        Text("Click in the box, then dictate. The text lands here the same way it will in other apps.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Text("You can change the trigger later in Settings, under Dictation.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("There are still setup items left before dictation will work end-to-end.")
                    ForEach(appModel.setupIssues) { issue in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(issue.title)
                                .font(.headline)
                            Text(issue.detail)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func backendActions(for model: ASRModelDescriptor, state: ModelInstallState) -> some View {
        Group {
            switch state {
            case .downloading:
                Button("Cancel Download") {
                    appModel.cancelInstall(model)
                }
            default:
                Button("Download Selected Model") {
                    appModel.installSelectedModel()
                }
                .buttonStyle(.borderedProminent)
            }

            if appModel.canRemoveManagedModel(model) {
                Button("Remove Downloaded Model") {
                    appModel.removeManagedModel(model)
                }
            }

            Button("Reveal Model Folder") {
                appModel.revealManagedModelDirectory()
            }
        }
    }

    private func isStepComplete(_ step: OnboardingStep) -> Bool {
        switch step {
        case .welcome:
            return appModel.settings.hasCompletedOnboarding
        case .microphone:
            return appModel.permissionService.microphoneGranted
        case .accessibility:
            let accessibilityReady = appModel.permissionService.accessibilityGranted
            let inputReady = !appModel.usesSpecialKeyTrigger || appModel.permissionService.inputMonitoringGranted
            return accessibilityReady && inputReady
        case .whisperBackend:
            return appModel.isRuntimeConfigured && appModel.isSelectedModelAvailable
        case .ready:
            return appModel.setupIssues.isEmpty
        }
    }

    private func statusPill(_ title: String, isReady: Bool, readyText: String? = nil) -> some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Spacer()
            Text(readyText ?? (isReady ? "Ready" : "Missing"))
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isReady ? Color.green.opacity(0.14) : Color.orange.opacity(0.18))
                .foregroundStyle(isReady ? .green : .orange)
                .clipShape(Capsule())
        }
    }

    private func notice(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func pathField(title: String, text: Binding<String>, browseAction: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            HStack {
                TextField("", text: text)
                    .textFieldStyle(.roundedBorder)
                Button("Browse", action: browseAction)
            }
        }
    }
}

private struct WizardStepRow: View {
    let step: OnboardingStep
    let currentStep: OnboardingStep
    let isComplete: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(circleFill)
                if isComplete {
                    Image(systemName: "checkmark")
                        .font(.caption.bold())
                        .foregroundStyle(circleForeground)
                } else {
                    Text("\(step.rawValue + 1)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(circleForeground)
                }
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.subheadline.weight(currentStep == step ? .bold : .semibold))
                Text(stepSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var circleFill: Color {
        if isComplete { return .green.opacity(0.14) }
        if currentStep == step { return Color(red: 0.10, green: 0.46, blue: 0.84).opacity(0.16) }
        return .secondary.opacity(0.12)
    }

    private var circleForeground: Color {
        if isComplete { return .green }
        if currentStep == step { return Color(red: 0.10, green: 0.46, blue: 0.84) }
        return .secondary
    }

    private var rowBackground: some ShapeStyle {
        if currentStep == step {
            return AnyShapeStyle(Color.primary.opacity(0.05))
        }

        return AnyShapeStyle(Color.clear)
    }

    private var stepSubtitle: String {
        switch step {
        case .welcome:
            return "Overview"
        case .microphone:
            return "Audio capture"
        case .accessibility:
            return "Insertion access"
        case .whisperBackend:
            return "Runtime + model"
        case .ready:
            return "Final check"
        }
    }
}
