import SwiftUI

@MainActor
struct AdvancedPane: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Speech engine") {
                LabeledContent("Engine", value: appModel.engineDisplayName)

                LabeledContent("Runtime") {
                    Text(appModel.runtimeStatusSummary)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }

                LabeledContent("Model folder") {
                    Text(appModel.managedModelDirectoryPath)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }

                Button("Reveal Model Folder") {
                    appModel.revealManagedModelDirectory()
                }

                Toggle("Prefer CPU only", isOn: $settings.disableGPU)
            }

            Section {
                pathRow(title: "whisper-cli", text: $settings.whisperCLIPath, browse: appModel.chooseCLIPath)
                pathRow(title: "Model directory", text: $settings.modelDirectoryPath, browse: appModel.chooseModelDirectory)
            } header: {
                Text("Custom Whisper paths")
            } footer: {
                Text("Leave these empty to use the bundled runtime and the managed model folder. Order: custom path, then bundled runtime or managed models, then local developer fallbacks.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private func pathRow(title: String, text: Binding<String>, browse: @escaping @MainActor () -> Void) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                TextField(title, text: text, prompt: Text("Default"))
                    .labelsHidden()
                    .accessibilityLabel(title)
                Button("Browse…", action: browse)
            }
        }
    }
}
