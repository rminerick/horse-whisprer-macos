import Foundation

/// What a click on the menu bar icon opens.
enum MenuBarStyle: String, CaseIterable, Identifiable, Sendable {
    case popover
    case classicMenu

    var id: String { rawValue }

    var title: String {
        switch self {
        case .popover: return "Popover"
        case .classicMenu: return "Classic menu"
        }
    }

    var detail: String {
        switch self {
        case .popover:
            return "A panel with a start button, quick switches and recent transcripts. Right-click the icon for the classic menu."
        case .classicMenu:
            return "The original plain menu: status, start or stop, settings and quit."
        }
    }
}

enum TriggerStyle: String, CaseIterable, Identifiable, Sendable {
    case toggle
    case hold

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toggle: return "Press to start, press to stop"
        case .hold: return "Hold to talk"
        }
    }
}

/// What the trigger controller reports to the app.
enum TriggerEvent: Equatable, Sendable {
    case toggle
    case holdBegan
    case holdEnded
}

enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case general
    case dictation
    case streaming
    case models
    case history
    case permissions
    case about
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .streaming: return "Streaming"
        case .dictation: return "Dictation"
        case .models: return "Models"
        case .history: return "History"
        case .permissions: return "Permissions"
        case .about: return "About"
        case .advanced: return "Advanced"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .streaming: return "text.bubble"
        case .dictation: return "mic"
        case .models: return "shippingbox"
        case .history: return "clock"
        case .permissions: return "lock.shield"
        case .about: return "info.circle"
        case .advanced: return "terminal"
        }
    }
}

struct WhisperLanguage: Identifiable, Hashable, Sendable {
    let code: String
    let name: String

    var id: String { code }

    static let autoDetectCode = "auto"

    static func displayName(for code: String) -> String {
        if code == autoDetectCode { return "Auto detect" }
        return all.first(where: { $0.code == code })?.name ?? code.uppercased()
    }

    /// Every language code whisper.cpp accepts with `-l`, sorted by name.
    static let all: [WhisperLanguage] = [
        ("af", "Afrikaans"), ("sq", "Albanian"), ("am", "Amharic"), ("ar", "Arabic"), ("hy", "Armenian"),
        ("as", "Assamese"), ("az", "Azerbaijani"), ("ba", "Bashkir"), ("eu", "Basque"), ("be", "Belarusian"),
        ("bn", "Bengali"), ("bs", "Bosnian"), ("br", "Breton"), ("bg", "Bulgarian"), ("yue", "Cantonese"),
        ("ca", "Catalan"), ("zh", "Chinese"), ("hr", "Croatian"), ("cs", "Czech"), ("da", "Danish"),
        ("nl", "Dutch"), ("en", "English"), ("et", "Estonian"), ("fo", "Faroese"), ("fi", "Finnish"),
        ("fr", "French"), ("gl", "Galician"), ("ka", "Georgian"), ("de", "German"), ("el", "Greek"),
        ("gu", "Gujarati"), ("ht", "Haitian Creole"), ("ha", "Hausa"), ("haw", "Hawaiian"), ("he", "Hebrew"),
        ("hi", "Hindi"), ("hu", "Hungarian"), ("is", "Icelandic"), ("id", "Indonesian"), ("it", "Italian"),
        ("ja", "Japanese"), ("jw", "Javanese"), ("kn", "Kannada"), ("kk", "Kazakh"), ("km", "Khmer"),
        ("ko", "Korean"), ("lo", "Lao"), ("la", "Latin"), ("lv", "Latvian"), ("ln", "Lingala"),
        ("lt", "Lithuanian"), ("lb", "Luxembourgish"), ("mk", "Macedonian"), ("mg", "Malagasy"), ("ms", "Malay"),
        ("ml", "Malayalam"), ("mt", "Maltese"), ("mi", "Maori"), ("mr", "Marathi"), ("mn", "Mongolian"),
        ("my", "Myanmar"), ("ne", "Nepali"), ("no", "Norwegian"), ("nn", "Nynorsk"), ("oc", "Occitan"),
        ("ps", "Pashto"), ("fa", "Persian"), ("pl", "Polish"), ("pt", "Portuguese"), ("pa", "Punjabi"),
        ("ro", "Romanian"), ("ru", "Russian"), ("sa", "Sanskrit"), ("sr", "Serbian"), ("sn", "Shona"),
        ("sd", "Sindhi"), ("si", "Sinhala"), ("sk", "Slovak"), ("sl", "Slovenian"), ("so", "Somali"),
        ("es", "Spanish"), ("su", "Sundanese"), ("sw", "Swahili"), ("sv", "Swedish"), ("tl", "Tagalog"),
        ("tg", "Tajik"), ("ta", "Tamil"), ("tt", "Tatar"), ("te", "Telugu"), ("th", "Thai"),
        ("bo", "Tibetan"), ("tr", "Turkish"), ("tk", "Turkmen"), ("uk", "Ukrainian"), ("ur", "Urdu"),
        ("uz", "Uzbek"), ("vi", "Vietnamese"), ("cy", "Welsh"), ("yi", "Yiddish"), ("yo", "Yoruba")
    ].map { WhisperLanguage(code: $0.0, name: $0.1) }
}
