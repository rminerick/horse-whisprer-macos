import SwiftUI

@main
struct HorseWhisprerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    #if DEBUG
    private func testInsertion(in bundleIdentifier: String) {
        Task { await appDelegate.appModel.testStreamingInsertion(expectedBundleIdentifier: bundleIdentifier) }
    }
    #endif

    var body: some Scene {
        // AppDelegate owns the settings window, the menu bar item and the pill so
        // the app can launch without opening a window. This scene only supplies
        // the app menu; its own empty window is never shown.
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(after: .appInfo) {
                #if DEBUG
                Menu("Test Insertion in 10 Seconds") {
                    Button("Safari") { testInsertion(in: "com.apple.Safari") }
                    Button("Claude") { testInsertion(in: "com.anthropic.claudefordesktop") }
                    Button("Remote Desktop") { testInsertion(in: "com.apple.RemoteDesktop") }
                }
                #endif
                Button("Check for Updates…") {
                    appDelegate.checkForUpdates(nil)
                }
            }

            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appDelegate.openMainWindow(nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandGroup(replacing: .appTermination) {
                Button("Quit Horse Whisprer") {
                    appDelegate.quitApp(nil)
                }
                .keyboardShortcut("q")
            }
        }
    }
}
