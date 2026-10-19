import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    lazy var appModel = AppModel()

    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["HORSEWHISPRER_RUNNING_TESTS"] == "1"
    }

    private static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("main-window")
    private static let mainWindowTitle = "Horse Whisprer"
    private static let mainWindowSize = NSSize(width: 760, height: 660)

    private var statusItem: NSStatusItem?
    private var classicMenu: NSMenu?
    private var appliedMenuBarStyle: MenuBarStyle?
    private var popover: NSPopover?
    private var mainWindowController: NSWindowController?
    private var isMainWindowOpen = false
    private var pillController: DictationPillController?
    private var statusTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var isPreparingForTermination = false
    private let updateService = SparkleUpdateService()

    private lazy var menuBarIcon: NSImage? = {
        guard let image = Bundle.main.image(forResource: "MenuBarHorseTemplate") else {
            return nil
        }

        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()

    // MARK: App lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        finishLaunching()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !Self.isRunningTests else { return true }
        presentMainWindow()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        prepareForTermination()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        prepareForTermination()
    }

    private func finishLaunching() {
        guard !Self.isRunningTests else { return }
        applyActivationPolicy()
        installStatusItem()
        connectAppModel()
        appModel.configureTrigger()

        let pill = DictationPillController(appModel: appModel) { [weak self] in
            self?.openSettings(.permissions)
        }
        pill.start()
        pillController = pill

        appModel.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                Task { @MainActor [weak self] in
                    self?.appModelDidChange()
                }
            }
            .store(in: &cancellables)

        // A menu bar app stays out of the way at launch unless setup is unfinished.
        if appModel.showsOnboardingWizard {
            presentMainWindow()
        } else {
            promptForMissingSetupIfNeeded()
        }
    }

    private func connectAppModel() {
        if updateService.isEnabled {
            appModel.checkForUpdatesAction = { [weak self] in
                self?.updateService.checkForUpdates()
            }
        }
        appModel.prepareForDictationStart = { [weak self] in
            await self?.yieldFocusBeforeDictation()
        }
        // Dictating into one of our own text fields (the setup wizard's practice
        // box, a text replacement) should land there, not in the previous app.
        appModel.textInsertionService.ownTextTargetProvider = {
            NSApp.isActive && NSApp.keyWindow?.firstResponder is NSTextView
        }
    }

    private func appModelDidChange() {
        guard !isPreparingForTermination else { return }
        applyMenuBarStyle()
        applyActivationPolicy()
        updateStatusTimer()
        refreshStatusItem()
    }

    private func prepareForTermination() {
        guard !Self.isRunningTests else { return }
        guard !isPreparingForTermination else {
            return
        }

        isPreparingForTermination = true
        cancellables.removeAll()
        statusTimer?.invalidate()
        statusTimer = nil
        pillController?.stop()
        popover?.performClose(nil)
        mainWindowController?.window?.delegate = nil
        appModel.prepareForTermination()

        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    // MARK: Actions

    @objc func toggleDictation(_ sender: Any?) {
        Task { @MainActor in
            await appModel.toggleDictation()
        }
    }

    @objc func cancelDictation(_ sender: Any?) {
        Task { @MainActor in
            await appModel.cancelDictation()
        }
    }

    @objc func openMainWindow(_ sender: Any?) {
        presentMainWindow()
    }

    @objc func openSetupWizard(_ sender: Any?) {
        appModel.presentOnboardingWizard()
        presentMainWindow()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        updateService.checkForUpdates()
    }

    @objc func copyLastTranscript(_ sender: Any?) {
        if let lastResult = appModel.lastResult {
            appModel.copyToClipboard(lastResult)
        }
    }

    @objc func switchMenuBarStyle(_ sender: Any?) {
        appModel.settings.menuBarStyle = appModel.settings.menuBarStyle == .popover ? .classicMenu : .popover
    }

    @objc func quitApp(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    private func openSettings(_ tab: SettingsTab) {
        appModel.selectedSettingsTab = tab
        presentMainWindow()
    }

    // MARK: Settings window

    private func presentMainWindow() {
        appModel.refreshPermissions(promptAccessibility: false)
        popover?.performClose(nil)

        if mainWindowController == nil {
            mainWindowController = makeMainWindowController()
        }

        isMainWindowOpen = true
        applyActivationPolicy()
        NSApp.activate(ignoringOtherApps: true)
        mainWindowController?.showWindow(nil)
        mainWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    private func makeMainWindowController() -> NSWindowController {
        let hostingController = NSHostingController(rootView: SettingsView(appModel: appModel))

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.mainWindowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.identifier = Self.mainWindowIdentifier
        window.title = Self.mainWindowTitle
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(Self.mainWindowSize)
        window.center()
        // A new name so the old, wider window frame is not restored.
        window.setFrameAutosaveName("HorseWhisprerSettingsWindow")
        return NSWindowController(window: window)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender.identifier == Self.mainWindowIdentifier else {
            return true
        }

        sender.orderOut(nil)
        isMainWindowOpen = false
        applyActivationPolicy()
        return false
    }

    /// In the Dock only while the settings window is open, unless the user keeps it there.
    private func applyActivationPolicy() {
        let wanted: NSApplication.ActivationPolicy =
            (appModel.settings.showsDockIcon || isMainWindowOpen) ? .regular : .accessory
        if NSApp.activationPolicy() != wanted {
            NSApp.setActivationPolicy(wanted)
        }
    }

    private func promptForMissingSetupIfNeeded() {
        guard appModel.settings.hasCompletedOnboarding,
              appModel.shouldPromptForSetup,
              !appModel.showsOnboardingWizard,
              let summary = appModel.setupPromptSummary else {
            return
        }

        let alert = NSAlert()
        alert.messageText = "Horse Whisprer Needs Setup"
        alert.informativeText = "Complete the setup wizard before dictation will work:\n\n\(summary)"
        alert.addButton(withTitle: "Open Setup Wizard")
        alert.addButton(withTitle: "Later")
        alert.alertStyle = .informational

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            appModel.presentOnboardingWizard()
            presentMainWindow()
        }
    }

    // MARK: Status item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu(title: "Horse Whisprer")
        menu.delegate = self
        classicMenu = menu
        statusItem = item
        applyMenuBarStyle()
        refreshStatusItem()
    }

    /// Classic: the status item owns the plain menu. Popover: a click opens the
    /// popover and a right-click (or Control-click) still shows the plain menu.
    private func applyMenuBarStyle() {
        guard let statusItem, let button = statusItem.button else { return }
        let style = appModel.settings.menuBarStyle
        guard style != appliedMenuBarStyle else { return }
        appliedMenuBarStyle = style

        switch style {
        case .classicMenu:
            popover?.performClose(nil)
            button.target = nil
            button.action = nil
            statusItem.menu = classicMenu
        case .popover:
            statusItem.menu = nil
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp || (event?.modifierFlags.contains(.control) ?? false)

        if wantsMenu {
            showClassicMenuFromButton()
        } else if appModel.isRecording {
            // Stopping here keeps the app being dictated into frontmost.
            toggleDictation(nil)
        } else {
            togglePopover()
        }
    }

    private func showClassicMenuFromButton() {
        guard let button = statusItem?.button, let classicMenu else { return }
        popover?.performClose(nil)
        _ = classicMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
    }

    private func refreshStatusItem() {
        guard let button = statusItem?.button else { return }

        let usesPopover = appModel.settings.menuBarStyle == .popover
        button.image = menuBarIcon
        button.contentTintColor = appModel.isRecording ? .systemRed : nil
        button.alphaValue = appModel.isBusy ? 0.72 : 1.0

        if usesPopover, appModel.isRecording, let startedAt = appModel.recordingStartedAt {
            let seconds = max(0, Int(Date().timeIntervalSince(startedAt)))
            button.attributedTitle = NSAttributedString(
                string: String(format: " %d:%02d", seconds / 60, seconds % 60),
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)]
            )
            button.imagePosition = .imageLeading
            button.toolTip = "\(appModel.statusSummary) Click to stop and insert."
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
            button.toolTip = appModel.statusSummary
        }
    }

    /// Ticks the elapsed time next to the icon while recording in popover style.
    private func updateStatusTimer() {
        let needsTimer = appModel.isRecording && appModel.settings.menuBarStyle == .popover
        if needsTimer, statusTimer == nil {
            let timer = Timer(timeInterval: 1, target: self, selector: #selector(statusTimerFired(_:)),
                              userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common)
            statusTimer = timer
        } else if !needsTimer, statusTimer != nil {
            statusTimer?.invalidate()
            statusTimer = nil
        }
    }

    @objc private func statusTimerFired(_ timer: Timer) {
        refreshStatusItem()
    }

    // MARK: Popover

    private func togglePopover() {
        guard let button = statusItem?.button else { return }

        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }

        let popover = self.popover ?? makePopover()
        self.popover = popover
        // Snapshot the external app before activating our own panel. Workspace
        // notifications are delivered asynchronously and may still be queued.
        appModel.textInsertionService.captureInsertionTarget()
        // Transient popovers only dismiss on an outside click when their app is active.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func makePopover() -> NSPopover {
        var actions = MenuBarPopoverActions(
            toggleDictation: { [weak self] in self?.toggleDictation(nil) },
            cancelDictation: { [weak self] in self?.cancelDictation(nil) },
            openSettings: { [weak self] tab in self?.openSettings(tab) },
            checkForUpdates: nil,
            quit: { [weak self] in self?.quitApp(nil) }
        )
        if updateService.isEnabled {
            actions.checkForUpdates = { [weak self] in self?.checkForUpdates(nil) }
        }

        let hostingController = NSHostingController(rootView: MenuBarPopoverView(
            appModel: appModel,
            settings: appModel.settings,
            history: appModel.historyStore,
            actions: actions
        ))
        hostingController.sizingOptions = [.preferredContentSize]

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = hostingController
        return popover
    }

    /// The popover makes Horse Whisprer the active app. Before a session starts,
    /// close it and put the user's app back in front so text has somewhere to go.
    private func yieldFocusBeforeDictation() async {
        guard let popover, popover.isShown else { return }
        popover.performClose(nil)
        await appModel.textInsertionService.returnFocusToTarget()
    }

    // MARK: Classic menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu(menu)
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let headline = NSMenuItem(title: appModel.statusSummary, action: nil, keyEquivalent: "")
        headline.isEnabled = false
        menu.addItem(headline)
        menu.addItem(.separator())

        let toggleTitle = appModel.isRecording ? "Stop Dictation" : "Start Dictation"
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleDictation(_:)), keyEquivalent: "")
        toggleItem.target = self
        toggleItem.isEnabled = !appModel.isBusy
        menu.addItem(toggleItem)

        if appModel.activity.isInFlight {
            let cancelItem = NSMenuItem(title: "Cancel Dictation", action: #selector(cancelDictation(_:)), keyEquivalent: "")
            cancelItem.target = self
            menu.addItem(cancelItem)
        }

        let openItem = NSMenuItem(title: "Open Settings", action: #selector(openMainWindow(_:)), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let wizardItem = NSMenuItem(title: "Open Setup Wizard", action: #selector(openSetupWizard(_:)), keyEquivalent: "")
        wizardItem.target = self
        menu.addItem(wizardItem)

        let styleTitle = appModel.settings.menuBarStyle == .popover ? "Switch to Classic Menu" : "Switch to Popover"
        let styleItem = NSMenuItem(title: styleTitle, action: #selector(switchMenuBarStyle(_:)), keyEquivalent: "")
        styleItem.target = self
        menu.addItem(styleItem)

        menu.addItem(.separator())

        if updateService.isEnabled {
            let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
            updateItem.target = self
            menu.addItem(updateItem)
        } else {
            let updateItem = NSMenuItem(title: "Updates are available in official builds", action: nil, keyEquivalent: "")
            updateItem.isEnabled = false
            menu.addItem(updateItem)
        }

        menu.addItem(.separator())

        let modelItem = NSMenuItem(title: "Model: \(appModel.selectedModel.displayName)", action: nil, keyEquivalent: "")
        modelItem.isEnabled = false
        menu.addItem(modelItem)

        let engineItem = NSMenuItem(title: "Engine: \(appModel.engineDisplayName)", action: nil, keyEquivalent: "")
        engineItem.isEnabled = false
        menu.addItem(engineItem)

        if let lastResult = appModel.lastResult, !lastResult.isEmpty {
            menu.addItem(.separator())
            let recentItem = NSMenuItem(title: "Last Result: \(lastResult.prefix(60))", action: nil, keyEquivalent: "")
            recentItem.isEnabled = false
            menu.addItem(recentItem)

            let copyItem = NSMenuItem(title: "Copy Last Transcript", action: #selector(copyLastTranscript(_:)), keyEquivalent: "")
            copyItem.target = self
            menu.addItem(copyItem)
        }

        if let lastError = appModel.lastError, !lastError.isEmpty {
            menu.addItem(.separator())
            let errorItem = NSMenuItem(title: "Last Error: \(lastError)", action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            menu.addItem(errorItem)
        }

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }
}
