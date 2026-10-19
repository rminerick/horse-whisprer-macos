import SwiftUI

/// Everything the pill shows for one dictation activity. A pure value so the
/// wording for each state can be unit tested without a window.
struct PillPresentation: Equatable {
    enum Glyph: Equatable {
        case spinner
        case recording
        case paused
        case success
        case warning
        case cancelled
    }

    enum Action: Equatable {
        case copyTranscript
        case openPermissions
    }

    let glyph: Glyph
    let title: String
    let subtitle: String
    let showsTimer: Bool
    let showsCancelHint: Bool
    let action: Action?
    /// Seconds the pill stays visible after the session ends. Nil while a session is in flight.
    let lingerSeconds: Double?

    static func make(activity: DictationActivity, modelName: String, targetName: String?,
                     partialTranscript: String?, lastError: String?, escapeCancels: Bool) -> PillPresentation? {
        let into = targetName.map { " into \($0)" } ?? ""

        switch activity {
        case .idle:
            return nil

        case .starting:
            return PillPresentation(glyph: .spinner, title: "Starting…", subtitle: modelName,
                                    showsTimer: false, showsCancelHint: escapeCancels, action: nil, lingerSeconds: nil)

        case .recording(.insertOnStop):
            return PillPresentation(glyph: .recording, title: "Recording",
                                    subtitle: targetName.map { "Text goes into \($0) when you stop" }
                                        ?? "Text is inserted when you stop",
                                    showsTimer: true, showsCancelHint: escapeCancels, action: nil, lingerSeconds: nil)

        case .recording(.bufferingAudio):
            return PillPresentation(glyph: .recording, title: "Recording, keep talking",
                                    subtitle: "\(modelName) is loading. Your audio is buffered.",
                                    showsTimer: true, showsCancelHint: escapeCancels, action: nil, lingerSeconds: nil)

        case .recording(.insertingLive):
            let spoken = partialTranscript.map { tail(of: $0) } ?? ""
            return PillPresentation(glyph: .recording, title: spoken.isEmpty ? "Listening" : spoken,
                                    subtitle: "Inserting live\(into)",
                                    showsTimer: true, showsCancelHint: escapeCancels, action: nil, lingerSeconds: nil)

        case .recording(.liveInsertionPaused):
            return PillPresentation(glyph: .paused, title: "Still recording, typing paused",
                                    subtitle: "The full text is kept when you stop.",
                                    showsTimer: true, showsCancelHint: escapeCancels, action: nil, lingerSeconds: nil)

        case .stopping:
            return PillPresentation(glyph: .spinner, title: "Stopping…", subtitle: modelName,
                                    showsTimer: false, showsCancelHint: false, action: nil, lingerSeconds: nil)

        case .transcribing:
            return PillPresentation(glyph: .spinner, title: "Transcribing…", subtitle: modelName,
                                    showsTimer: false, showsCancelHint: escapeCancels, action: nil, lingerSeconds: nil)

        case .finished(.inserted(.pasted)):
            return PillPresentation(glyph: .success, title: "Inserted\(into)",
                                    subtitle: "Pasted. Your clipboard was put back.",
                                    showsTimer: false, showsCancelHint: false, action: .copyTranscript, lingerSeconds: 2.5)

        case .finished(.inserted(.typed)):
            return PillPresentation(glyph: .success, title: "Inserted\(into)", subtitle: "Typed",
                                    showsTimer: false, showsCancelHint: false, action: .copyTranscript, lingerSeconds: 2.5)

        case .finished(.inserted(.copiedOnly)):
            return PillPresentation(glyph: .success, title: "Copied to the clipboard",
                                    subtitle: "Paste it wherever you need it.",
                                    showsTimer: false, showsCancelHint: false, action: nil, lingerSeconds: 2.5)

        case .finished(.inserted(.failed(let reason))):
            return PillPresentation(glyph: .warning, title: "Could not insert", subtitle: reason,
                                    showsTimer: false, showsCancelHint: false, action: .copyTranscript, lingerSeconds: 6)

        case .finished(.insertedLive):
            return PillPresentation(glyph: .success, title: "Inserted\(into)", subtitle: "Typed while you spoke",
                                    showsTimer: false, showsCancelHint: false, action: .copyTranscript, lingerSeconds: 2.5)

        case .finished(.liveInsertionPaused):
            return PillPresentation(glyph: .warning, title: "Not fully inserted",
                                    subtitle: "The full transcript is in History.",
                                    showsTimer: false, showsCancelHint: false, action: .copyTranscript, lingerSeconds: 6)

        case .finished(.copiedWithoutAccessibility):
            return PillPresentation(glyph: .warning, title: "Copied to the clipboard instead",
                                    subtitle: "Accessibility access is missing.",
                                    showsTimer: false, showsCancelHint: false, action: .openPermissions, lingerSeconds: 8)

        case .finished(.notInserted):
            return PillPresentation(glyph: .warning, title: "Not inserted",
                                    subtitle: "The transcript is in History.",
                                    showsTimer: false, showsCancelHint: false, action: .copyTranscript, lingerSeconds: 6)

        case .cancelled:
            return PillPresentation(glyph: .cancelled, title: "Cancelled", subtitle: "Nothing was inserted.",
                                    showsTimer: false, showsCancelHint: false, action: nil, lingerSeconds: 1.5)

        case .failed:
            return PillPresentation(glyph: .warning, title: "Dictation failed",
                                    subtitle: lastError ?? "Something went wrong.",
                                    showsTimer: false, showsCancelHint: false, action: nil, lingerSeconds: 6)
        }
    }

    /// The last few words of a transcript, cut at a word boundary.
    static func tail(of text: String, limit: Int = 44) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let suffix = String(trimmed.suffix(limit))
        if let space = suffix.firstIndex(of: " ") {
            return "…" + String(suffix[suffix.index(after: space)...])
        }
        return "…" + suffix
    }
}

@MainActor
struct DictationPillView: View {
    @ObservedObject var appModel: AppModel
    let onCopy: @MainActor () -> Void
    let onOpenPermissions: @MainActor () -> Void

    private let ink = Color(red: 0.95, green: 0.96, blue: 0.97)
    private let secondaryInk = Color(red: 0.66, green: 0.69, blue: 0.77)
    private let surface = Color(red: 0.07, green: 0.086, blue: 0.133)
    private let recordingRed = Color(red: 1.0, green: 0.42, blue: 0.39)
    private let cautionAmber = Color(red: 1.0, green: 0.72, blue: 0.30)
    private let successGreen = Color(red: 0.35, green: 0.86, blue: 0.58)

    private var presentation: PillPresentation? {
        PillPresentation.make(
            activity: appModel.activity,
            modelName: appModel.selectedModel.displayName,
            targetName: appModel.targetApplicationName,
            partialTranscript: appModel.partialTranscript,
            lastError: appModel.lastError,
            escapeCancels: appModel.settings.escapeCancelsDictation
        )
    }

    var body: some View {
        ZStack {
            if let presentation {
                pill(presentation)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pill(_ presentation: PillPresentation) -> some View {
        HStack(spacing: 12) {
            glyph(presentation.glyph)

            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ink)
                    .lineLimit(1)
                    .truncationMode(.head)
                Text(presentation.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(secondaryInk)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if presentation.showsTimer, let startedAt = appModel.recordingStartedAt {
                Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(ink)
                    .accessibilityLabel("Elapsed time")
            }

            if presentation.showsCancelHint {
                Text("esc")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(ink)
                    .padding(.horizontal, 7)
                    .frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.14)))
                    .accessibilityLabel("Press Escape to cancel")
            }

            if let action = presentation.action,
               action != .copyTranscript || appModel.lastResult != nil {
                actionButton(action)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .frame(width: 460, height: 60)
        .background(Capsule(style: .continuous).fill(surface))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.14)))
        .shadow(color: Color.black.opacity(0.35), radius: 14, x: 0, y: 8)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func glyph(_ glyph: PillPresentation.Glyph) -> some View {
        switch glyph {
        case .spinner:
            ProgressView()
                .controlSize(.small)
                .environment(\.colorScheme, .dark)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.white.opacity(0.10)))
        case .recording:
            Circle()
                .fill(recordingRed)
                .frame(width: 12, height: 12)
                .frame(width: 36, height: 36)
                .background(Circle().fill(recordingRed.opacity(0.20)))
                .accessibilityLabel("Recording")
        case .paused:
            symbol("pause.fill", tint: cautionAmber)
        case .success:
            symbol("checkmark", tint: successGreen)
        case .warning:
            symbol("exclamationmark", tint: cautionAmber)
        case .cancelled:
            symbol("xmark", tint: secondaryInk)
        }
    }

    private func symbol(_ name: String, tint: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: 36, height: 36)
            .background(Circle().fill(tint.opacity(0.20)))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func actionButton(_ action: PillPresentation.Action) -> some View {
        switch action {
        case .copyTranscript:
            Button("Copy", action: onCopy)
                .buttonStyle(PillButtonStyle(fill: Color.white.opacity(0.14), ink: ink))
        case .openPermissions:
            Button("Fix in Settings", action: onOpenPermissions)
                .buttonStyle(PillButtonStyle(fill: Color.accentColor, ink: .white))
        }
    }
}

private struct PillButtonStyle: ButtonStyle {
    let fill: Color
    let ink: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(ink)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Capsule(style: .continuous).fill(fill))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
