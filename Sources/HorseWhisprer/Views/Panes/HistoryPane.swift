import SwiftUI

@MainActor
struct HistoryPane: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: TranscriptHistoryStore
    @State private var selectedID: TranscriptRecord.ID?
    @State private var searchText = ""

    private var filteredRecords: [TranscriptRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return history.records }
        return history.records.filter {
            $0.text.localizedCaseInsensitiveContains(query)
                || $0.targetDisplayName.localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedRecord: TranscriptRecord? {
        let records = filteredRecords
        return records.first(where: { $0.id == selectedID }) ?? records.first
    }

    private var retentionNote: String {
        switch settings.historyRetention {
        case .off: return "History is off."
        case .untilQuit: return "Kept until you quit. Nothing is written to disk."
        case .onDisk: return "Saved on this Mac only."
        }
    }

    var body: some View {
        if history.records.isEmpty {
            emptyState
        } else {
            HStack(spacing: 0) {
                listColumn
                    .frame(width: 290)
                Divider()
                detailColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            ContentUnavailableView(
                settings.historyRetention == .off ? "History is off" : "No transcripts yet",
                systemImage: "clock",
                description: Text(settings.historyRetention == .off
                                  ? "Turn it on to keep a transcript that could not be inserted."
                                  : "What you dictate shows up here, so nothing is lost if an insertion fails.")
            )
            if settings.historyRetention == .off {
                Button("Open General Settings") {
                    appModel.selectedSettingsTab = .general
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var listColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search what you said", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
            .padding(12)

            List(filteredRecords, selection: $selectedID) { record in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(record.targetDisplayName)
                            .font(.footnote.weight(.semibold))
                        Spacer()
                        Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(record.text)
                        .font(.callout)
                        .lineLimit(2)
                    Text(record.outcome)
                        .font(.caption)
                        .foregroundStyle(record.reachedTarget ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                }
                .padding(.vertical, 3)
                .tag(record.id)
            }
            .listStyle(.inset)

            Divider()

            HStack {
                Text(retentionNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") {
                    history.clear()
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let record = selectedRecord {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text(record.targetDisplayName)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    Spacer()
                    Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                ScrollView {
                    Text(record.text)
                        .font(.system(size: 16))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 8) {
                    TranscriptCopyButton {
                        appModel.copyToClipboard(record.text)
                    }
                    .id(record.id)

                    Button("Insert Again") {
                        Task {
                            await appModel.insertAgain(record)
                        }
                    }
                    .help("Insert this text into the app you were last using")

                    Button("Delete", role: .destructive) {
                        history.remove(id: record.id)
                    }
                }

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("Result").foregroundStyle(.secondary)
                        Text(record.outcome)
                    }
                    GridRow {
                        Text("Model").foregroundStyle(.secondary)
                        Text(record.modelName)
                    }
                    GridRow {
                        Text("Recording").foregroundStyle(.secondary)
                        Text(record.durationLabel)
                    }
                }
                .font(.callout)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
            }
            .padding(24)
        } else {
            ContentUnavailableView("No matches", systemImage: "magnifyingglass",
                                   description: Text("No transcript contains that text."))
        }
    }
}
