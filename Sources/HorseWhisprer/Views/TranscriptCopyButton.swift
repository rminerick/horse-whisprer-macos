import SwiftUI

/// A new attempt invalidates an older reset, so repeated clicks keep feedback visible.
struct TranscriptCopyFeedback: Equatable {
    private(set) var generation = 0
    private(set) var succeeded: Bool?

    mutating func record(success: Bool) {
        generation += 1
        succeeded = success
    }

    mutating func reset(generation: Int) {
        guard self.generation == generation else { return }
        succeeded = nil
    }
}

@MainActor
struct TranscriptCopyButton: View {
    let copy: @MainActor () -> Bool
    @State private var feedback = TranscriptCopyFeedback()

    private var title: LocalizedStringKey {
        switch feedback.succeeded {
        case true: "Copied"
        case false: "Copy failed"
        case nil: "Copy"
        }
    }

    private var symbol: String {
        switch feedback.succeeded {
        case true: "checkmark"
        case false: "exclamationmark.triangle"
        case nil: "doc.on.doc"
        }
    }

    var body: some View {
        Button {
            feedback.record(success: copy())
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .semibold))
                .fixedSize()
        }
        .buttonStyle(TranscriptCopyButtonStyle())
        .help(title)
        .accessibilityLabel(feedback.succeeded == nil ? "Copy transcript" : title)
        .task(id: feedback.generation) {
            guard feedback.succeeded != nil else { return }
            let generation = feedback.generation
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            feedback.reset(generation: generation)
        }
    }
}

/// An opaque surface keeps the label readable over the popover's glass and
/// wallpaper, independent of the system accent color or inherited control size.
private struct TranscriptCopyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(minWidth: 72, minHeight: 30)
            .background(configuration.isPressed ? Color(white: 0.32) : Color(white: 0.15),
                        in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color.white.opacity(0.7), lineWidth: 1)
            }
    }
}
