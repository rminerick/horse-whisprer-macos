import Foundation

enum SetupIssue: String, CaseIterable, Identifiable {
    case microphonePermission
    case accessibilityPermission
    case inputMonitoringPermission
    case whisperCLI
    case selectedModel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphonePermission:
            return "Microphone access is missing"
        case .accessibilityPermission:
            return "Accessibility access is missing"
        case .inputMonitoringPermission:
            return "Input Monitoring access is missing"
        case .whisperCLI:
            return "whisper.cpp is not configured"
        case .selectedModel:
            return "The selected model is not installed"
        }
    }

    var detail: String {
        switch self {
        case .microphonePermission:
            return "Horse Whisprer needs microphone access to capture dictation."
        case .accessibilityPermission:
            return "Accessibility access is required to paste or type text into other apps."
        case .inputMonitoringPermission:
            return "Input Monitoring access is required for special-key triggers like fn / 🌐 and left/right ⌘, ⌥, and ⌃."
        case .whisperCLI:
            return "Horse Whisprer needs a `whisper-cli` runtime. It will use a bundled runtime when available, or you can set a custom path in Advanced settings."
        case .selectedModel:
            return "Download the selected model in Models. For Whisper you can also point the app at a custom model directory that already contains it."
        }
    }
}

enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome
    case microphone
    case accessibility
    case whisperBackend
    case ready

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .welcome:
            return "Welcome"
        case .microphone:
            return "Microphone"
        case .accessibility:
            return "Accessibility"
        case .whisperBackend:
            return "Model"
        case .ready:
            return "Ready"
        }
    }
}
