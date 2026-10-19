import AppKit
import Combine
import SwiftUI

/// Owns the floating pill: a borderless, non-activating panel that never takes
/// keyboard focus, so the app being dictated into stays frontmost.
@MainActor
final class DictationPillController {
    private static let panelSize = NSSize(width: 520, height: 104)
    private static let bottomInset: CGFloat = 28

    private let appModel: AppModel
    private let openPermissions: @MainActor () -> Void
    private var panel: NSPanel?
    private var cancellables = Set<AnyCancellable>()
    private var hideTask: Task<Void, Never>?

    init(appModel: AppModel, openPermissions: @escaping @MainActor () -> Void) {
        self.appModel = appModel
        self.openPermissions = openPermissions
    }

    func start() {
        appModel.$activity
            .removeDuplicates()
            .sink { [weak self] activity in
                // @Published fires before the value is stored; hop so the pill's
                // view reads the new activity from the model.
                Task { @MainActor [weak self] in
                    self?.activityChanged(activity)
                }
            }
            .store(in: &cancellables)

        appModel.settings.$showsDictationPill
            .dropFirst()
            .sink { [weak self] isOn in
                Task { @MainActor [weak self] in
                    if !isOn { self?.hide() }
                }
            }
            .store(in: &cancellables)
    }

    func stop() {
        cancellables.removeAll()
        hideTask?.cancel()
        hideTask = nil
        panel?.orderOut(nil)
    }

    private func activityChanged(_ activity: DictationActivity) {
        hideTask?.cancel()
        hideTask = nil

        guard appModel.settings.showsDictationPill,
              let presentation = PillPresentation.make(
                  activity: activity,
                  modelName: appModel.selectedModel.displayName,
                  targetName: appModel.targetApplicationName,
                  partialTranscript: appModel.partialTranscript,
                  lastError: appModel.lastError,
                  escapeCancels: appModel.settings.escapeCancelsDictation
              ) else {
            hide()
            return
        }

        show()

        if let linger = presentation.lingerSeconds {
            hideTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(linger))
                guard !Task.isCancelled else { return }
                self?.hide()
            }
        }
    }

    private func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if !panel.isVisible {
            position(panel)
        }
        panel.orderFrontRegardless()
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - Self.panelSize.width / 2,
            y: visible.minY + Self.bottomInset
        )
        panel.setFrame(NSRect(origin: origin, size: Self.panelSize), display: false)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.setAccessibilityLabel("Horse Whisprer dictation status")

        let model = appModel
        let openPermissions = self.openPermissions
        let content = DictationPillView(
            appModel: model,
            onCopy: {
                if let text = model.lastResult {
                    model.copyToClipboard(text)
                }
            },
            onOpenPermissions: openPermissions
        )
        panel.contentView = FirstClickHostingView(rootView: content)
        return panel
    }
}

/// Lets the pill's buttons respond to the first click even though the panel
/// never becomes key and the app is usually not frontmost.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
