import SwiftUI

@MainActor
struct DictationPane: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var settings: AppSettings
    @State private var showsInputMonitoringAlert = false

    private var availableCueSounds: [RecordingCueSoundOption] {
        RecordingCueSoundCatalog.availableSounds
    }

    private var triggerMode: Binding<TriggerMode> {
        Binding(
            get: { settings.triggerMode },
            set: { mode in
                let wasUsingSpecialKey = appModel.usesSpecialKeyTrigger
                appModel.updateTriggerMode(mode)
                if mode == .specialKey, !wasUsingSpecialKey, !appModel.permissionService.inputMonitoringGranted {
                    showsInputMonitoringAlert = true
                }
            }
        )
    }

    private var specialKey: Binding<SpecialKeyTrigger> {
        Binding(
            get: { settings.specialKeyTrigger },
            set: { appModel.updateSpecialKeyTrigger($0) }
        )
    }

    private var usesWhisper: Bool {
        appModel.selectedModel.engineKind == .whisper
    }

    var body: some View {
        Form {
            triggerSection
            textSection
            soundSection
            vocabularySection
        }
        .formStyle(.grouped)
        .alert("A single-key trigger needs Input Monitoring", isPresented: $showsInputMonitoringAlert) {
            Button("Open System Settings") {
                appModel.openInputMonitoringSettings()
            }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("macOS controls this permission. Horse Whisprer can ask for it and open the right Settings pane, but you still need to turn it on there before fn / Globe or a modifier key can start dictation.")
        }
    }

    private var triggerSection: some View {
        Section {
            Picker("Start and stop with", selection: triggerMode) {
                Text("A shortcut").tag(TriggerMode.standardHotKey)
                Text("A single key").tag(TriggerMode.specialKey)
            }
            .pickerStyle(.segmented)

            Picker("How it works", selection: $settings.triggerStyle) {
                ForEach(TriggerStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }

            if settings.triggerMode == .standardHotKey {
                LabeledContent("Shortcut") {
                    HStack(spacing: 8) {
                        HotKeyRecorderField(
                            binding: settings.hotKeyBinding,
                            onRecord: appModel.updateHotKeyBinding
                        )
                        .frame(width: 220, height: 26)

                        Button("Reset") {
                            appModel.resetHotKeyBinding()
                        }
                    }
                }
            } else {
                Picker("Key", selection: specialKey) {
                    ForEach(SpecialKeyTrigger.allCases) { trigger in
                        Text(trigger.title).tag(trigger)
                    }
                }

                if !appModel.permissionService.inputMonitoringGranted {
                    LabeledContent("Input Monitoring is off") {
                        HStack(spacing: 8) {
                            Button("Enable") {
                                appModel.requestInputMonitoringAccess()
                            }
                            Button("Open Settings") {
                                appModel.openInputMonitoringSettings()
                            }
                        }
                    }
                }
            }

            Toggle("Escape cancels a dictation", isOn: $settings.escapeCancelsDictation)
        } header: {
            Text("Trigger")
        } footer: {
            Text(triggerFootnote)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var triggerFootnote: String {
        var lines = [appModel.triggerInstructions]
        if settings.triggerMode == .specialKey {
            lines.append("A single key needs Input Monitoring. Using the key in another shortcut does not trigger dictation.")
        } else {
            lines.append("Shortcuts work without Input Monitoring.")
        }
        if settings.escapeCancelsDictation {
            lines.append("While a dictation is running, Escape goes to Horse Whisprer instead of the app you are in.")
        }
        return lines.joined(separator: " ")
    }

    private var textSection: some View {
        Section {
            Picker("Insert text by", selection: $settings.insertBehavior) {
                ForEach(InsertBehavior.allCases) { behavior in
                    Text(behavior.title).tag(behavior)
                }
            }

            Picker("Language", selection: $settings.languageCode) {
                Text("Auto detect").tag(WhisperLanguage.autoDetectCode)
                Divider()
                ForEach(WhisperLanguage.all) { language in
                    Text(language.name).tag(language.code)
                }
            }
            .disabled(!usesWhisper)

            Toggle("Insert text while speaking", isOn: $settings.liveStreamingInsertion)
        } header: {
            Text("Text")
        } footer: {
            Text(textFootnote)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var textFootnote: String {
        var lines: [String] = []
        if !usesWhisper {
            lines.append("\(appModel.selectedModel.displayName) transcribes English; the language setting applies to Whisper models.")
        }
        lines.append("Inserting while you speak needs the Nemotron model and a supported text field. After you edit by hand, new speech resumes at the cursor once typing stops. Switching fields or an unverified insertion pauses it. The full transcript is kept according to your History setting.")
        return lines.joined(separator: " ")
    }

    private var soundSection: some View {
        Section("Sound") {
            Toggle("Play start and stop sounds", isOn: $settings.playRecordingCues)

            Picker("Start sound", selection: $settings.startRecordingCueSoundName) {
                ForEach(availableCueSounds) { sound in
                    Text(sound.title).tag(sound.name)
                }
            }
            .disabled(!settings.playRecordingCues)
            .onChange(of: settings.startRecordingCueSoundName) { _, newValue in
                appModel.previewCue(named: newValue)
            }

            Picker("Stop sound", selection: $settings.stopRecordingCueSoundName) {
                ForEach(availableCueSounds) { sound in
                    Text(sound.title).tag(sound.name)
                }
            }
            .disabled(!settings.playRecordingCues)
            .onChange(of: settings.stopRecordingCueSoundName) { _, newValue in
                appModel.previewCue(named: newValue)
            }

            Picker("Other audio while recording", selection: $settings.dictationOutputAudioBehavior) {
                ForEach(DictationOutputAudioBehavior.allCases) { behavior in
                    Text(behavior.title).tag(behavior)
                }
            }
            .pickerStyle(.segmented)

            Text(settings.dictationOutputAudioBehavior.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var vocabularySection: some View {
        Section {
            TextField("Names and terms", text: $settings.vocabularyTerms, prompt: Text("Okafor, Nemotron, xcodegen"), axis: .vertical)
                .lineLimit(1...3)

            ForEach($settings.textReplacements) { $rule in
                HStack(spacing: 8) {
                    TextField("When I say", text: $rule.heard, prompt: Text("horse whisperer"))
                        .labelsHidden()
                        .accessibilityLabel("When I say")
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("Write", text: $rule.replacement, prompt: Text("Horse Whisprer"))
                        .labelsHidden()
                        .accessibilityLabel("Write")
                    Button {
                        settings.textReplacements.removeAll { $0.id == rule.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this replacement")
                    .accessibilityLabel("Remove this replacement")
                }
            }

            Button("Add Replacement") {
                settings.textReplacements.append(TextReplacementRule())
            }
        } header: {
            Text("Vocabulary")
        } footer: {
            Text("Names and terms are given to Whisper as a hint. Replacements are applied to every transcript, whichever model made it, and match whole words in any capitalization.")
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
