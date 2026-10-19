import SwiftUI

/// The settings window: a row of tabs over one pane at a time. Each pane lives
/// in its own file under Views/Panes.
@MainActor
struct SettingsView: View {
    @ObservedObject var appModel: AppModel

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            pane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, idealWidth: 760, minHeight: 560, idealHeight: 660)
        .sheet(isPresented: $appModel.showsOnboardingWizard) {
            OnboardingWizardView(appModel: appModel)
        }
        .task {
            // Pick up permission changes made in System Settings without a Refresh button.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if !appModel.setupIssues.isEmpty {
                    appModel.pollPermissions()
                }
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases) { tab in
                tabButton(tab)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
    }

    private func tabButton(_ tab: SettingsTab) -> some View {
        let isSelected = appModel.selectedSettingsTab == tab
        let needsAttention = tab == .permissions && !appModel.setupIssues.isEmpty

        return Button {
            appModel.selectedSettingsTab = tab
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 17, weight: .regular))
                    .frame(height: 22)
                    .overlay(alignment: .topTrailing) {
                        if needsAttention {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 8, height: 8)
                                .offset(x: 6, y: -2)
                        }
                    }
                Text(tab.title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(needsAttention ? "\(tab.title), needs attention" : tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var pane: some View {
        switch appModel.selectedSettingsTab {
        case .general:
            GeneralPane(appModel: appModel, settings: appModel.settings, history: appModel.historyStore)
        case .dictation:
            DictationPane(appModel: appModel, settings: appModel.settings)
        case .streaming:
            StreamingPreferencesView(settings: appModel.settings)
        case .models:
            ModelsPane(appModel: appModel, settings: appModel.settings)
        case .history:
            HistoryPane(appModel: appModel, settings: appModel.settings, history: appModel.historyStore)
        case .permissions:
            PermissionsPane(appModel: appModel, settings: appModel.settings)
        case .about:
            AboutPane(appModel: appModel)
        case .advanced:
            AdvancedPane(appModel: appModel, settings: appModel.settings)
        }
    }
}
