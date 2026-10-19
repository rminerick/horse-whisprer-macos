import SwiftUI

@MainActor
struct AboutPane: View {
    @ObservedObject var appModel: AppModel

    var body: some View {
        Form {
            Section("Free and open source") {
                Text("Horse Whisprer is free to use. No account, activation, or subscription is required.")
                Text("App code is available under the MIT license. Third-party libraries and model weights retain their own licenses.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Updates") {
                LabeledContent("Build", value: appModel.distributionSummary)
                Text(appModel.updatesEnabled
                     ? "Automatic updates are available for this signed official build."
                     : appModel.updatesSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if appModel.updatesEnabled, let check = appModel.checkForUpdatesAction {
                    Button("Check for Updates…", action: check)
                }
            }
        }
        .formStyle(.grouped)
    }
}
