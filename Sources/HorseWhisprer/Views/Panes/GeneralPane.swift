import SwiftUI

@MainActor
struct GeneralPane: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: TranscriptHistoryStore

    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { appModel.launchAtLoginEnabled },
            set: { appModel.setLaunchAtLogin($0) }
        )
    }

    var body: some View {
        Form {
            Section("Menu bar") {
                Picker("Clicking the icon opens", selection: $settings.menuBarStyle) {
                    ForEach(MenuBarStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)

                Text(settings.menuBarStyle.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Show the floating pill while dictating", isOn: $settings.showsDictationPill)
            }

            Section("App") {
                Toggle("Launch at login", isOn: launchAtLogin)

                if let error = appModel.launchAtLoginError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle("Keep Horse Whisprer in the Dock", isOn: $settings.showsDockIcon)

                Text("When this is off, Horse Whisprer lives in the menu bar and shows in the Dock only while this window is open.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("History") {
                Picker("Keep transcripts", selection: $settings.historyRetention) {
                    ForEach(HistoryRetention.allCases) { retention in
                        Text(retention.title).tag(retention)
                    }
                }

                Text(settings.historyRetention.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Clear History") {
                    history.clear()
                }
                .disabled(history.records.isEmpty)
            }

            Section("About") {
                LabeledContent("Version", value: appModel.appVersionSummary)
                LabeledContent("Build", value: appModel.distributionSummary)

                Text(appModel.updatesSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if appModel.updatesEnabled {
                    Button("Check for Updates…") {
                        appModel.checkForUpdatesAction?()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
