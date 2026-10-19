import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct StreamingPreferencesView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            GlobalStreamingSection(settings: settings)
            ApplicationStreamingSection(settings: settings)
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 480)
    }
}

private struct GlobalStreamingSection: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Section("Streaming dictation") {
            Picker("Default insertion method", selection: $settings.insertBehavior) {
                ForEach(InsertBehavior.allCases) { behavior in
                    Text(behavior.title).tag(behavior)
                }
            }
            Picker("Default streaming behavior", selection: $settings.streamingInsertionMode) {
                ForEach(StreamingInsertionMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Text(settings.streamingInsertionMode.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Applies to streaming models such as Nemotron. Copy-only output always waits until recording ends. Changes apply to the next dictation.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct StreamingAppChoice: Identifiable {
    let id: String
    let name: String
}

private struct ApplicationStreamingSection: View {
    @ObservedObject var settings: AppSettings
    @State private var applications: [StreamingAppChoice] = []
    @State private var showsInvalidApplication = false

    var body: some View {
        Section("Per-application overrides") {
            ForEach(applications) { application in
                ApplicationStreamingRow(settings: settings, application: application)
            }
            Button("Add Application…", action: addApplication)
            Button("Add Apple Remote Desktop Preset") {
                settings.useRemoteDesktopPreset(for: "com.apple.RemoteDesktop", name: "Remote Desktop")
            }
            Text("Apps without an override use the defaults above. Preferences are selected when dictation starts. Browser overrides apply to all sites in that browser. Streaming still depends on the focused field's capabilities.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .onChange(of: settings.applicationOverrideIdentifiers, initial: true) { _, _ in refreshApplications() }
        .onChange(of: settings.applicationStreamingNames) { _, _ in refreshApplications() }
        .alert("Cannot add application", isPresented: $showsInvalidApplication) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Choose an application with a bundle identifier.")
        }
    }

    private func refreshApplications() {
        applications = settings.applicationOverrideIdentifiers.map { identifier in
            let name = settings.applicationStreamingNames[identifier] ?? identifier
            return StreamingAppChoice(id: identifier, name: name.isEmpty ? identifier : name)
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    private func addApplication() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose an Application")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier, !identifier.isEmpty else {
            showsInvalidApplication = true
            return
        }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let mode = settings.streamingMode(for: identifier)
        settings.setStreamingOverride(for: identifier, name: name, mode: mode)
    }
}

private struct ApplicationStreamingRow: View {
    @ObservedObject var settings: AppSettings
    let application: StreamingAppChoice

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading) {
                    Text(application.name).font(.headline)
                    Text(application.id).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Use Defaults") {
                    settings.removeApplicationOverrides(for: application.id)
                }
                .accessibilityLabel("Use default for \(application.name)")
            }
            Picker("Streaming", selection: Binding(
                get: { settings.applicationStreamingModes[application.id] },
                set: { settings.setStreamingOverride(for: application.id, name: application.name, mode: $0) }
            )) {
                Text("Use default").tag(nil as StreamingInsertionMode?)
                ForEach(StreamingInsertionMode.allCases) { mode in
                    Text(mode.title).tag(Optional(mode))
                }
            }
            ApplicationInsertionControls(settings: settings, application: application)
            Text(settings.streamingMode(for: application.id).explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ApplicationInsertionControls: View {
    @ObservedObject var settings: AppSettings
    let application: StreamingAppChoice

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Insertion method", selection: Binding(
                get: { settings.applicationInsertBehaviors[application.id] },
                set: { settings.setInsertOverride(for: application.id, name: application.name, behavior: $0) }
            )) {
                Text("Use default").tag(nil as InsertBehavior?)
                ForEach(InsertBehavior.allCases) { behavior in
                    Text(behavior.title).tag(Optional(behavior))
                }
            }
            Picker("Wait before paste", selection: Binding(
                get: { settings.pasteTiming(for: application.id) },
                set: { settings.setPasteTimingOverride(for: application.id, name: application.name, timing: $0) }
            )) {
                ForEach(ClipboardPasteTiming.allCases) { timing in
                    Text(timing.title).tag(timing)
                }
            }
            .disabled(settings.insertBehavior(for: application.id) != .pasteThenType)
            Button("Use Remote Desktop Preset") {
                settings.useRemoteDesktopPreset(for: application.id, name: application.name)
            }
            if settings.pasteTiming(for: application.id) != .standard {
                Text("For remote sessions, enable Use Shared Clipboard in Remote Desktop. Delayed paste keeps the transcript on the clipboard and skips pasting if the app, window, or clipboard changes. It cannot confirm delivery on the remote Mac. Use Insert when finished for remote dictation.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
final class StreamingPreferencesWindow {
    private static var controller: NSWindowController?

    static func show(settings: AppSettings) {
        if controller == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 640),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = String(localized: "Streaming Preferences")
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: StreamingPreferencesView(settings: settings))
            window.center()
            controller = NSWindowController(window: window)
        }
        NSApp.activate(ignoringOtherApps: true)
        controller?.showWindow(nil)
    }
}
