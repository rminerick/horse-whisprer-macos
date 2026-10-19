import AppKit
import Carbon
import Foundation

protocol ASREngine: AnyObject, Sendable {
    var id: String { get }
    var displayName: String { get }
    func isConfigured() -> Bool
    func prepareForTermination()
    func makeStreamingSession(model: ASRModelDescriptor, options: TranscriptionOptions) async throws -> any StreamingASRSession
    func transcribe(audioURL: URL, model: ASRModelDescriptor, options: TranscriptionOptions) async throws -> TranscriptionResult
}

extension ASREngine {
    func prepareForTermination() {}
    func makeStreamingSession(model: ASRModelDescriptor, options: TranscriptionOptions) async throws -> any StreamingASRSession {
        throw NativeASRError.unsupportedModel
    }
}

struct ASRModelDescriptor: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let displayName: String
    let fileName: String
    let downloadURL: URL
    let languages: String
    let diskSizeDescription: String
    let notes: String
    let isRecommended: Bool
    let expectedSHA256: String?
    let expectedFileSizeBytes: Int64?
    var engineKind: ASREngineKind = .whisper
}

struct InstalledModelRecord: Codable, Equatable, Hashable, Sendable {
    let modelID: String
    let relativePath: String
    let fileSizeBytes: Int64
    let sha256: String
    let installedAt: Date
}

enum ModelInstallState: Equatable, Sendable {
    case notInstalled
    case downloading(progress: Double)
    case installed(InstalledModelRecord)
    case failed(String)

    var statusLabel: String {
        switch self {
        case .notInstalled:
            return "Not installed"
        case .downloading(let progress):
            return "Downloading \(Int(progress * 100))%"
        case .installed:
            return "Installed"
        case .failed:
            return "Failed"
        }
    }

    var progressValue: Double? {
        switch self {
        case .downloading(let progress):
            return progress
        default:
            return nil
        }
    }

    var failureMessage: String? {
        if case .failed(let message) = self {
            return message
        }

        return nil
    }
}

struct TranscriptionOptions: Sendable {
    let languageCode: String
    let suppressTimestamps: Bool
    let useGPU: Bool
    /// Names and jargon to bias Whisper toward. Core ML engines ignore it.
    var vocabularyPrompt: String? = nil
}

struct TranscriptionResult: Sendable {
    let text: String
    let duration: TimeInterval
}

enum InsertBehavior: String, CaseIterable, Identifiable, Sendable {
    case pasteThenType
    case copyOnly
    case typeOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pasteThenType:
            return "Paste, then type fallback"
        case .copyOnly:
            return "Copy only"
        case .typeOnly:
            return "Type only"
        }
    }
}

enum DictationOutputAudioBehavior: String, Codable, CaseIterable, Identifiable, Sendable {
    case off
    case duck
    case mute

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:
            return "Off"
        case .duck:
            return "Duck"
        case .mute:
            return "Mute"
        }
    }

    var detail: String {
        switch self {
        case .off:
            return "Leave the current output device alone while dictating."
        case .duck:
            return "Lower the current output device while recording. Normal volume returns before the stop cue plays."
        case .mute:
            return "Mute the current output device while recording. Normal volume returns before the stop cue plays."
        }
    }
}

enum InsertionOutcome: Equatable, Sendable {
    case pasted
    case typed
    case copiedOnly
    case failed(String)

    var label: String {
        switch self {
        case .pasted:
            return "pasted"
        case .typed:
            return "typed"
        case .copiedOnly:
            return "copied"
        case .failed(let reason):
            return "failed (\(reason))"
        }
    }
}

struct HotKeyBinding: Codable, Equatable, Hashable, Sendable {
    let keyCode: UInt32
    let carbonModifiers: UInt32

    static let defaultBinding = LegacyHotKeyPreset.controlOptionSpace.binding
    static let supportedModifierMask = UInt32(cmdKey) | UInt32(optionKey) | UInt32(controlKey) | UInt32(shiftKey)

    var isValid: Bool {
        hasModifiers && !Self.modifierOnlyKeyCodes.contains(keyCode)
    }

    var displayString: String {
        (modifierLabels + [keyLabel]).joined(separator: " + ")
    }

    /// Compact key-cap labels for the interface: ["⌃", "⌥", "Space"].
    var keyCaps: [String] {
        var caps: [String] = []
        if (carbonModifiers & UInt32(controlKey)) != 0 { caps.append("⌃") }
        if (carbonModifiers & UInt32(optionKey)) != 0 { caps.append("⌥") }
        if (carbonModifiers & UInt32(shiftKey)) != 0 { caps.append("⇧") }
        if (carbonModifiers & UInt32(cmdKey)) != 0 { caps.append("⌘") }
        return caps + [keyLabel]
    }

    private var hasModifiers: Bool {
        (carbonModifiers & Self.supportedModifierMask) != 0
    }

    private var modifierLabels: [String] {
        var labels: [String] = []

        if (carbonModifiers & UInt32(controlKey)) != 0 {
            labels.append("Control")
        }

        if (carbonModifiers & UInt32(optionKey)) != 0 {
            labels.append("Option")
        }

        if (carbonModifiers & UInt32(shiftKey)) != 0 {
            labels.append("Shift")
        }

        if (carbonModifiers & UInt32(cmdKey)) != 0 {
            labels.append("Command")
        }

        return labels
    }

    private var keyLabel: String {
        Self.keyLabels[keyCode] ?? "Key \(keyCode)"
    }

    private static let modifierOnlyKeyCodes: Set<UInt32> = [
        UInt32(kVK_Command),
        UInt32(kVK_RightCommand),
        UInt32(kVK_Shift),
        UInt32(kVK_RightShift),
        UInt32(kVK_Option),
        UInt32(kVK_RightOption),
        UInt32(kVK_Control),
        UInt32(kVK_RightControl)
    ]

    private static let keyLabels: [UInt32: String] = [
        UInt32(kVK_ANSI_A): "A",
        UInt32(kVK_ANSI_B): "B",
        UInt32(kVK_ANSI_C): "C",
        UInt32(kVK_ANSI_D): "D",
        UInt32(kVK_ANSI_E): "E",
        UInt32(kVK_ANSI_F): "F",
        UInt32(kVK_ANSI_G): "G",
        UInt32(kVK_ANSI_H): "H",
        UInt32(kVK_ANSI_I): "I",
        UInt32(kVK_ANSI_J): "J",
        UInt32(kVK_ANSI_K): "K",
        UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_M): "M",
        UInt32(kVK_ANSI_N): "N",
        UInt32(kVK_ANSI_O): "O",
        UInt32(kVK_ANSI_P): "P",
        UInt32(kVK_ANSI_Q): "Q",
        UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_S): "S",
        UInt32(kVK_ANSI_T): "T",
        UInt32(kVK_ANSI_U): "U",
        UInt32(kVK_ANSI_V): "V",
        UInt32(kVK_ANSI_W): "W",
        UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_Y): "Y",
        UInt32(kVK_ANSI_Z): "Z",
        UInt32(kVK_ANSI_0): "0",
        UInt32(kVK_ANSI_1): "1",
        UInt32(kVK_ANSI_2): "2",
        UInt32(kVK_ANSI_3): "3",
        UInt32(kVK_ANSI_4): "4",
        UInt32(kVK_ANSI_5): "5",
        UInt32(kVK_ANSI_6): "6",
        UInt32(kVK_ANSI_7): "7",
        UInt32(kVK_ANSI_8): "8",
        UInt32(kVK_ANSI_9): "9",
        UInt32(kVK_Space): "Space",
        UInt32(kVK_Return): "Return",
        UInt32(kVK_Tab): "Tab",
        UInt32(kVK_Delete): "Delete",
        UInt32(kVK_ForwardDelete): "Forward Delete",
        UInt32(kVK_Escape): "Escape",
        UInt32(kVK_LeftArrow): "Left Arrow",
        UInt32(kVK_RightArrow): "Right Arrow",
        UInt32(kVK_UpArrow): "Up Arrow",
        UInt32(kVK_DownArrow): "Down Arrow",
        UInt32(kVK_ANSI_Minus): "-",
        UInt32(kVK_ANSI_Equal): "=",
        UInt32(kVK_ANSI_LeftBracket): "[",
        UInt32(kVK_ANSI_RightBracket): "]",
        UInt32(kVK_ANSI_Backslash): "\\",
        UInt32(kVK_ANSI_Semicolon): ";",
        UInt32(kVK_ANSI_Quote): "'",
        UInt32(kVK_ANSI_Comma): ",",
        UInt32(kVK_ANSI_Period): ".",
        UInt32(kVK_ANSI_Slash): "/",
        UInt32(kVK_ANSI_Grave): "`",
        UInt32(kVK_F1): "F1",
        UInt32(kVK_F2): "F2",
        UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5",
        UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7",
        UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10",
        UInt32(kVK_F11): "F11",
        UInt32(kVK_F12): "F12",
        UInt32(kVK_F13): "F13",
        UInt32(kVK_F14): "F14",
        UInt32(kVK_F15): "F15",
        UInt32(kVK_F16): "F16",
        UInt32(kVK_F17): "F17",
        UInt32(kVK_F18): "F18",
        UInt32(kVK_F19): "F19",
        UInt32(kVK_F20): "F20"
    ]
}

enum TriggerMode: String, Codable, CaseIterable, Identifiable {
    case standardHotKey
    case specialKey

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standardHotKey:
            return "Standard Shortcut"
        case .specialKey:
            return "Special Key"
        }
    }
}

enum SpecialKeyTrigger: String, Codable, CaseIterable, Identifiable {
    case fnTapAlone
    case leftControlTapAlone
    case rightControlTapAlone
    case leftOptionTapAlone
    case rightOptionTapAlone
    case leftCommandTapAlone
    case rightCommandTapAlone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fnTapAlone:
            return "fn / 🌐"
        case .leftControlTapAlone:
            return "Left ⌃"
        case .rightControlTapAlone:
            return "Right ⌃"
        case .leftOptionTapAlone:
            return "Left ⌥"
        case .rightOptionTapAlone:
            return "Right ⌥"
        case .leftCommandTapAlone:
            return "Left ⌘"
        case .rightCommandTapAlone:
            return "Right ⌘"
        }
    }

    var detail: String {
        "Press \(title) twice to toggle dictation. Using it in a shortcut will not trigger dictation."
    }

    var keyCode: UInt16 {
        switch self {
        case .fnTapAlone:
            return UInt16(kVK_Function)
        case .leftControlTapAlone:
            return UInt16(kVK_Control)
        case .rightControlTapAlone:
            return UInt16(kVK_RightControl)
        case .leftOptionTapAlone:
            return UInt16(kVK_Option)
        case .rightOptionTapAlone:
            return UInt16(kVK_RightOption)
        case .leftCommandTapAlone:
            return UInt16(kVK_Command)
        case .rightCommandTapAlone:
            return UInt16(kVK_RightCommand)
        }
    }

    var deviceFlagMask: CGEventFlags.RawValue {
        switch self {
        case .fnTapAlone:
            return CGEventFlags.maskSecondaryFn.rawValue
        case .leftControlTapAlone:
            return CGEventFlags.RawValue(NX_DEVICELCTLKEYMASK)
        case .rightControlTapAlone:
            return CGEventFlags.RawValue(NX_DEVICERCTLKEYMASK)
        case .leftOptionTapAlone:
            return CGEventFlags.RawValue(NX_DEVICELALTKEYMASK)
        case .rightOptionTapAlone:
            return CGEventFlags.RawValue(NX_DEVICERALTKEYMASK)
        case .leftCommandTapAlone:
            return CGEventFlags.RawValue(NX_DEVICELCMDKEYMASK)
        case .rightCommandTapAlone:
            return CGEventFlags.RawValue(NX_DEVICERCMDKEYMASK)
        }
    }
}

struct TriggerConfiguration: Codable, Equatable, Hashable, Sendable {
    var mode: TriggerMode
    var hotKeyBinding: HotKeyBinding
    var specialKeyTrigger: SpecialKeyTrigger

    static let defaultConfiguration = TriggerConfiguration(
        mode: .standardHotKey,
        hotKeyBinding: .defaultBinding,
        specialKeyTrigger: .rightCommandTapAlone
    )
}

enum LegacyHotKeyPreset: String {
    case controlOptionSpace
    case commandOptionSpace
    case controlOptionD

    var binding: HotKeyBinding {
        switch self {
        case .controlOptionSpace:
            return HotKeyBinding(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(controlKey) | UInt32(optionKey))
        case .commandOptionSpace:
            return HotKeyBinding(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(cmdKey) | UInt32(optionKey))
        case .controlOptionD:
            return HotKeyBinding(keyCode: UInt32(kVK_ANSI_D), carbonModifiers: UInt32(controlKey) | UInt32(optionKey))
        }
    }
}
