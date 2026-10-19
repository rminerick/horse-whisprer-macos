import Foundation

enum InsertionExecutionPath: String, Equatable, Sendable {
    case copyOnly
    case typeOnlyTyped
    case typeOnlyFailed
    case pasteCommandPosted
    case pasteCommandFailed
    case typedFallbackUsed
    case copiedOnlyFallback

    var title: String {
        switch self {
        case .copyOnly:
            return "Copied only"
        case .typeOnlyTyped:
            return "Typed directly"
        case .typeOnlyFailed:
            return "Typing failed"
        case .pasteCommandPosted:
            return "Sent Cmd-V"
        case .pasteCommandFailed:
            return "Paste dispatch failed"
        case .typedFallbackUsed:
            return "Typed fallback"
        case .copiedOnlyFallback:
            return "Copied fallback"
        }
    }

    var detail: String {
        switch self {
        case .copyOnly:
            return "Horse Whisprer copied the transcription to the clipboard without trying to insert it."
        case .typeOnlyTyped:
            return "Horse Whisprer typed the transcription directly into the target app."
        case .typeOnlyFailed:
            return "Horse Whisprer tried to type directly, but the synthetic typing events failed."
        case .pasteCommandPosted:
            return "Horse Whisprer posted a synthetic Cmd-V event to the target app."
        case .pasteCommandFailed:
            return "Horse Whisprer could not post a synthetic Cmd-V event."
        case .typedFallbackUsed:
            return "Horse Whisprer fell back to synthetic typing after paste dispatch failed."
        case .copiedOnlyFallback:
            return "Horse Whisprer fell back to clipboard copy after paste and typing both failed."
        }
    }
}

struct InsertionAttemptRecord: Equatable, Sendable {
    let attemptedAt: Date
    let requestedBehavior: InsertBehavior
    let targetApplicationName: String?
    let targetBundleIdentifier: String?
    let frontmostApplicationName: String?
    let frontmostBundleIdentifier: String?
    let restoreAttempted: Bool
    let waitedForFocusSettle: Bool
    let focusSettleDelayMilliseconds: Int
    let pasteboardChangeCountBeforeCopy: Int?
    let pasteboardChangeCountAfterCopy: Int?
    let pasteEventSourceCreated: Bool
    let pasteEventsCreated: Bool
    let pasteEventPosted: Bool
    let typingAttempted: Bool
    let finalPath: InsertionExecutionPath
    let outcome: InsertionOutcome

    var targetDisplayName: String {
        if let targetApplicationName, !targetApplicationName.isEmpty {
            return targetApplicationName
        }

        if let targetBundleIdentifier, !targetBundleIdentifier.isEmpty {
            return targetBundleIdentifier
        }

        return "Unknown target"
    }

    var frontmostDisplayName: String {
        if let frontmostApplicationName, !frontmostApplicationName.isEmpty {
            return frontmostApplicationName
        }

        if let frontmostBundleIdentifier, !frontmostBundleIdentifier.isEmpty {
            return frontmostBundleIdentifier
        }

        return "Unknown app"
    }

    var activitySummary: String {
        switch finalPath {
        case .copyOnly:
            return "Copied the transcription to the clipboard."
        case .typeOnlyTyped:
            return "Typed the transcription into \(targetDisplayName)."
        case .typeOnlyFailed:
            return "Typing failed in \(targetDisplayName)."
        case .pasteCommandPosted:
            return "Sent Cmd-V to \(targetDisplayName)."
        case .pasteCommandFailed:
            return "Could not send Cmd-V to \(targetDisplayName)."
        case .typedFallbackUsed:
            return "Used typed fallback in \(targetDisplayName)."
        case .copiedOnlyFallback:
            return "Copied the transcription after insert fallback failed."
        }
    }
}
