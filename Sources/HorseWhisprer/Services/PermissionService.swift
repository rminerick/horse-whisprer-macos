import AppKit
import AVFoundation
import ApplicationServices
import Foundation
import IOKit.hid
import Security

enum MicrophoneAccessResult {
    case granted
    case deniedAfterPrompt
    case requiresSettings
}

@MainActor
final class PermissionService: ObservableObject {
    @Published private(set) var microphoneGranted = false
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var inputMonitoringGranted = false
    @Published private(set) var hasStableCodeSignature = true

    init() {
        refresh(promptAccessibility: false)
    }

    func refresh(promptAccessibility: Bool) {
        hasStableCodeSignature = Self.detectStableCodeSignature()
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        inputMonitoringGranted = Self.detectInputMonitoringAccess()
        refreshAccessibility(promptAccessibility: promptAccessibility)
    }

    func refreshAccessibility(promptAccessibility: Bool) {
        if promptAccessibility {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            accessibilityGranted = AXIsProcessTrustedWithOptions(options)
        } else {
            accessibilityGranted = AXIsProcessTrusted()
        }

        if promptAccessibility, !accessibilityGranted {
            openAccessibilitySettings()
        }
    }

    func requestMicrophoneIfNeeded() async -> MicrophoneAccessResult {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphoneGranted = true
            return .granted
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            microphoneGranted = granted
            return granted ? .granted : .deniedAfterPrompt
        case .denied, .restricted:
            microphoneGranted = false
            return .requiresSettings
        @unknown default:
            microphoneGranted = false
            return .requiresSettings
        }
    }

    func openAccessibilitySettings() {
        openSettingsURLs(accessibilitySettingsURLs)
    }

    func openMicrophoneSettings() {
        openSettingsURLs(microphoneSettingsURLs)
    }

    func requestInputMonitoringIfNeeded() {
        guard !inputMonitoringGranted else { return }

        if #available(macOS 10.15, *) {
            let granted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            inputMonitoringGranted = granted || Self.detectInputMonitoringAccess()
        } else {
            inputMonitoringGranted = true
        }

        if !inputMonitoringGranted {
            openInputMonitoringSettingsAfterPrompt()
        }
    }

    func openInputMonitoringSettings() {
        openSettingsURLs(inputMonitoringSettingsURLs)
    }

    var canUseSpecialKeyMonitoring: Bool {
        inputMonitoringGranted
    }

    var microphoneAuthorizationStatusDescription: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return "authorized"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        case .notDetermined:
            return "notDetermined"
        @unknown default:
            return "unknown"
        }
    }

    var accessibilityGuidance: String? {
        guard !accessibilityGranted else { return nil }

        if !hasStableCodeSignature {
            return "This build is using ad hoc signing (`Sign to Run Locally`). macOS privacy permissions often do not resolve correctly for Accessibility unless the app is signed with an Apple Development or Developer ID certificate."
        }

        return nil
    }

    var inputMonitoringGuidance: String? {
        guard !inputMonitoringGranted else { return nil }

        return "Special-key triggers like fn / 🌐, left/right ⌘, ⌥, or ⌃ need Input Monitoring so Horse Whisprer can watch low-level keyboard events. macOS may not list the app there until Horse Whisprer requests access. Click `Enable Input Monitoring`, turn it on in System Settings > Privacy & Security > Input Monitoring, then relaunch or refresh the app."
    }

    var microphoneGuidance: String? {
        guard !microphoneGranted else { return nil }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            return "Click `Grant Microphone Access` to trigger macOS's permission prompt. The app will only appear in the Microphone list after that prompt has been shown."
        case .denied, .restricted:
            return "Microphone access is currently `\(microphoneAuthorizationStatusDescription)` for this app process. If you already ran `tccutil reset Microphone com.rminerick.HorseWhisprer`, fully quit Horse Whisprer, relaunch it, and if it still says denied run `tccutil reset Microphone`, then relaunch and try again."
        case .authorized:
            return nil
        @unknown default:
            return "macOS is not reporting microphone access yet. Relaunch the app and try the permission prompt again."
        }
    }

    private static func detectStableCodeSignature() -> Bool {
        var code: SecCode?
        let selfStatus = SecCodeCopySelf([], &code)
        guard selfStatus == errSecSuccess, let code else {
            return false
        }

        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(code, [], &staticCode)
        guard staticStatus == errSecSuccess, let staticCode else {
            return false
        }

        var signingInfo: CFDictionary?
        let signingStatus = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInfo)
        guard signingStatus == errSecSuccess,
              let info = signingInfo as? [String: Any] else {
            return false
        }

        if let teamIdentifier = info[kSecCodeInfoTeamIdentifier as String] as? String,
           !teamIdentifier.isEmpty {
            return true
        }

        return false
    }

    private static func detectInputMonitoringAccess() -> Bool {
        if #available(macOS 10.15, *) {
            return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        }

        return true
    }

    private var accessibilitySettingsURLs: [URL] {
        [
            URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"),
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        ].compactMap { $0 }
    }

    private var microphoneSettingsURLs: [URL] {
        [
            URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone"),
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        ].compactMap { $0 }
    }

    private var inputMonitoringSettingsURLs: [URL] {
        [
            URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent"),
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        ].compactMap { $0 }
    }

    private func openInputMonitoringSettingsAfterPrompt() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            self?.openInputMonitoringSettings()
        }
    }

    private func openSettingsURLs(_ urls: [URL]) {
        guard let primaryURL = urls.first else { return }

        let opened = NSWorkspace.shared.open(primaryURL)
        if !opened {
            Self.openURLWithOpenTool(primaryURL)
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            Self.openURLWithOpenTool(primaryURL)
        }
    }

    private nonisolated static func openURLWithOpenTool(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.absoluteString]

        try? process.run()
    }
}
