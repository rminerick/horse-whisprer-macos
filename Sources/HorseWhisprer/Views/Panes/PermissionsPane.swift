import SwiftUI

@MainActor
struct PermissionsPane: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var settings: AppSettings

    private var permissions: PermissionService {
        appModel.permissionService
    }

    private var needsAccessibility: Bool {
        settings.insertBehavior != .copyOnly
    }

    var body: some View {
        Form {
            Section {
                requirementRow(
                    title: "Microphone",
                    detail: "Captures your voice. Audio is transcribed on this Mac and then deleted.",
                    isReady: permissions.microphoneGranted
                ) {
                    Button("Allow…") {
                        Task {
                            await appModel.grantMicrophoneAccess()
                        }
                    }
                }

                if let guidance = permissions.microphoneGuidance {
                    notice(guidance)
                }

                requirementRow(
                    title: "Accessibility",
                    detail: needsAccessibility
                        ? "Lets Horse Whisprer paste or type into other apps."
                        : "Not needed while text is only copied to the clipboard.",
                    isReady: permissions.accessibilityGranted || !needsAccessibility
                ) {
                    Button("Open Settings") {
                        appModel.openAccessibilitySettings()
                    }
                }

                if needsAccessibility, let guidance = permissions.accessibilityGuidance {
                    notice(guidance)
                }

                if appModel.usesSpecialKeyTrigger {
                    requirementRow(
                        title: "Input Monitoring",
                        detail: "Needed to use fn / Globe or a modifier key as the trigger.",
                        isReady: permissions.inputMonitoringGranted
                    ) {
                        Button("Enable") {
                            appModel.requestInputMonitoringAccess()
                        }
                        Button("Open Settings") {
                            appModel.openInputMonitoringSettings()
                        }
                    }

                    if let guidance = permissions.inputMonitoringGuidance {
                        notice(guidance)
                    }
                }
            } header: {
                Text("macOS permissions")
            } footer: {
                Text("This list updates on its own after you change a permission in System Settings.")
            }

            Section("Speech engine") {
                requirementRow(
                    title: "Runtime",
                    detail: appModel.runtimeStatusSummary,
                    isReady: appModel.isRuntimeConfigured
                ) {
                    Button("Advanced…") {
                        appModel.selectedSettingsTab = .advanced
                    }
                }

                requirementRow(
                    title: "Model",
                    detail: appModel.selectedModel.displayName,
                    isReady: appModel.isSelectedModelAvailable
                ) {
                    Button("Open Models") {
                        appModel.selectedSettingsTab = .models
                    }
                }
            }

            Section {
                LabeledContent("Guided setup") {
                    Button("Open Setup Wizard") {
                        appModel.presentOnboardingWizard()
                    }
                }

                LabeledContent("Insertion test") {
                    Button("Insert Sample Text") {
                        Task {
                            await appModel.testInsertion()
                        }
                    }
                    .help("Sends a sample sentence to the app you were last using")
                }

                if let attempt = appModel.lastInsertionAttempt {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(attempt.activitySummary)
                        Text(insertionDetails(for: attempt))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Use the insertion test to check pasting into an app without recording anything.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Troubleshooting")
            } footer: {
                Text("Microphone status from macOS: \(permissions.microphoneAuthorizationStatusDescription)")
            }
        }
        .formStyle(.grouped)
    }

    private func requirementRow<Actions: View>(title: String, detail: String, isReady: Bool,
                                               @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(isReady ? Color.green : Color.orange)
                .font(.title3)
                .accessibilityLabel(isReady ? "Ready" : "Needs attention")

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.medium)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !isReady {
                HStack(spacing: 8) {
                    actions()
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func notice(_ text: String) -> some View {
        Label {
            Text(text)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private func insertionDetails(for attempt: InsertionAttemptRecord) -> String {
        let target: String
        if let bundleIdentifier = attempt.targetBundleIdentifier, !bundleIdentifier.isEmpty {
            target = "\(attempt.targetDisplayName) (\(bundleIdentifier))"
        } else {
            target = attempt.targetDisplayName
        }

        let frontmost: String
        if let bundleIdentifier = attempt.frontmostBundleIdentifier, !bundleIdentifier.isEmpty {
            frontmost = "\(attempt.frontmostDisplayName) (\(bundleIdentifier))"
        } else {
            frontmost = attempt.frontmostDisplayName
        }

        let restore = attempt.restoreAttempted
            ? "Horse Whisprer brought the target app forward and waited \(attempt.focusSettleDelayMilliseconds) ms before sending input."
            : "The target app was already in front."

        return "\(attempt.finalPath.title). Target: \(target). In front before the insert: \(frontmost). \(restore)"
    }
}
