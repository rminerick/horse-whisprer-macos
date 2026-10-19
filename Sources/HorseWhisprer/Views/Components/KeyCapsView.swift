import SwiftUI

/// Small key caps such as ⌃ ⌥ Space.
struct KeyCapsView: View {
    let labels: [String]
    var onAccent = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                Text(label)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 6)
                    .frame(minWidth: 22, minHeight: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(onAccent ? Color.white.opacity(0.22) : Color.primary.opacity(0.10))
                    )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(labels.joined(separator: " "))
    }
}
