import AppKit
import SwiftUI

/// What the popover asks the app delegate to do.
struct MenuBarPopoverActions {
    var toggleDictation: @MainActor () -> Void
    var cancelDictation: @MainActor () -> Void
    var openSettings: @MainActor (SettingsTab) -> Void
    var checkForUpdates: (@MainActor () -> Void)?
    var quit: @MainActor () -> Void
}

/// The menu bar popover: start button, quick switches and recent transcripts.
@MainActor
struct MenuBarPopoverView: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: TranscriptHistoryStore
    let actions: MenuBarPopoverActions

    private var needsSetup: Bool {
        !appModel.setupIssues.isEmpty
    }

    private var idleStatus: String {
        if needsSetup { return "Setup required" }
        return "Ready"
    }

    /// Installed models, plus the selected one even when it still needs a download.
    private var modelChoices: [ASRModelDescriptor] {
        var choices = appModel.installedModels
        if !choices.contains(where: { $0.id == appModel.selectedModel.id }) {
            choices.insert(appModel.selectedModel, at: 0)
        }
        return choices
    }

    private var modelSelection: Binding<String> {
        Binding(
            get: { appModel.selectedModel.id },
            set: { id in
                if let model = appModel.modelCatalog.model(for: id) {
                    appModel.selectModel(model)
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if appModel.activity.isInFlight {
                sessionContent
            } else {
                idleContent
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    // MARK: Idle

    @ViewBuilder
    private var idleContent: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("Horse Whisprer")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                HStack(spacing: 6) {
                    Circle()
                        .fill(needsSetup ? Color.orange : Color.green)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(idleStatus)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            Button {
                actions.openSettings(appModel.selectedSettingsTab)
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.bordered)
            .help("Open Settings")
            .accessibilityLabel("Open Settings")
        }

        if needsSetup {
            Button {
                actions.openSettings(.permissions)
            } label: {
                Text("Finish Setup")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        } else {
            Button(action: actions.toggleDictation) {
                HStack(spacing: 10) {
                    Image(systemName: "mic.fill")
                    Text("Start dictation")
                    Spacer(minLength: 8)
                    KeyCapsView(labels: appModel.triggerKeyCaps, onAccent: true)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(appModel.isBusy)
        }

        if let error = appModel.lastError, !error.isEmpty {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        VStack(spacing: 8) {
            switchRow("Model") {
                Picker("Model", selection: modelSelection) {
                    ForEach(modelChoices) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
            }

            switchRow("Insert") {
                Picker("Insert", selection: $settings.insertBehavior) {
                    ForEach(InsertBehavior.allCases) { behavior in
                        Text(behavior.title).tag(behavior)
                    }
                }
            }

            if appModel.selectedModel.engineKind == .whisper {
                switchRow("Language") {
                    Picker("Language", selection: $settings.languageCode) {
                        Text("Auto detect").tag(WhisperLanguage.autoDetectCode)
                        Divider()
                        ForEach(WhisperLanguage.all) { language in
                            Text(language.name).tag(language.code)
                        }
                    }
                }
            }
        }

        recentTranscripts

        Divider()

        HStack(spacing: 14) {
            if let checkForUpdates = actions.checkForUpdates {
                Button("Check for Updates…", action: checkForUpdates)
            }
            Spacer()
            Button("Quit", action: actions.quit)
        }
        .buttonStyle(.plain)
        .font(.system(size: 12.5))
        .foregroundStyle(.secondary)
    }

    private func switchRow<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .leading)
            control()
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var recentTranscripts: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recent")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                if !history.records.isEmpty {
                    Button("Show all") {
                        actions.openSettings(.history)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                }
            }

            if history.records.isEmpty {
                Text(settings.historyRetention == .off
                     ? "History is off. Turn it on in Settings, under General."
                     : "What you dictate shows up here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(history.records.prefix(3)) { record in
                    Divider()
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.text)
                                .font(.system(size: 13.5))
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("\(record.targetDisplayName) · \(record.createdAt.formatted(date: .omitted, time: .shortened)) · \(record.outcome)")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        TranscriptCopyButton {
                            appModel.copyToClipboard(record.text)
                        }
                    }
                }
            }
        }
    }

    // MARK: While dictating

    @ViewBuilder
    private var sessionContent: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.red)
                .frame(width: 12, height: 12)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.red.opacity(0.14)))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(appModel.isRecording ? "Recording" : "Working")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Text(appModel.statusMessage)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let startedAt = appModel.recordingStartedAt {
                Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .accessibilityLabel("Elapsed time")
            }
        }

        if let partial = appModel.partialTranscript, !partial.isEmpty {
            Text(partial)
                .font(.system(size: 14))
                .lineLimit(5)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06)))
        }

        HStack(spacing: 8) {
            Button(action: actions.toggleDictation) {
                Label("Stop and insert", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!appModel.isRecording)

            Button(action: actions.cancelDictation) {
                HStack(spacing: 8) {
                    Text("Cancel")
                    if settings.escapeCancelsDictation {
                        KeyCapsView(labels: ["esc"])
                    }
                }
            }
            .controlSize(.large)
        }

        VStack(spacing: 6) {
            infoRow("Model", appModel.selectedModel.displayName)
            if let target = appModel.targetApplicationName {
                infoRow("Going to", target)
            }
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .leading)
            Text(value)
                .fontWeight(.medium)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
    }
}
