import SwiftUI

@MainActor
struct ModelsPane: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                ForEach(appModel.modelCatalog.nativeModels) { model in
                    modelRow(model)
                }
            } header: {
                Text("Core ML · Apple Silicon")
            } footer: {
                if !NativeASRRuntime.isSupported {
                    Text("These models need an Apple Silicon Mac.")
                }
            }

            Section("Whisper · any Mac") {
                ForEach(appModel.modelCatalog.whisperModels.reversed()) { model in
                    modelRow(model)
                }
            }

            Section {
                if let error = appModel.activeModelActionError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                LabeledContent("Every model runs on this Mac") {
                    Button("Reveal Model Folder") {
                        appModel.revealManagedModelDirectory()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func modelRow(_ model: ASRModelDescriptor) -> some View {
        let state = appModel.installState(for: model)
        let isSelected = settings.selectedModelID == model.id
        let isUnsupported = model.engineKind != .whisper && !NativeASRRuntime.isSupported

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.displayName)
                            .fontWeight(.medium)
                        if model.isRecommended {
                            Image(systemName: "star.fill")
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                                .help("Recommended")
                                .accessibilityLabel("Recommended")
                        }
                    }
                    Text("\(model.languages) · \(model.diskSizeDescription) · \(model.notes)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                trailingControls(for: model, state: state, isSelected: isSelected, isUnsupported: isUnsupported)
            }

            if let failure = state.failureMessage {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func trailingControls(for model: ASRModelDescriptor, state: ModelInstallState,
                                  isSelected: Bool, isUnsupported: Bool) -> some View {
        switch state {
        case .downloading(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .frame(width: 80)
                    .accessibilityLabel("Downloading \(model.displayName)")
                Text("\(Int(progress * 100))%")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    appModel.cancelInstall(model)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Cancel download")
                .accessibilityLabel("Cancel download")
            }

        case .installed:
            HStack(spacing: 8) {
                if isSelected {
                    Label("In use", systemImage: "checkmark")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.green)
                } else {
                    Button("Use") {
                        appModel.selectModel(model)
                    }
                }

                if appModel.canRemoveManagedModel(model) {
                    Button {
                        appModel.removeManagedModel(model)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove the downloaded model")
                    .accessibilityLabel("Remove \(model.displayName)")
                }
            }

        case .notInstalled, .failed:
            HStack(spacing: 8) {
                if isSelected {
                    Text("Selected")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                Button("Download") {
                    appModel.install(model)
                }
                .disabled(isUnsupported)
            }
        }
    }
}
