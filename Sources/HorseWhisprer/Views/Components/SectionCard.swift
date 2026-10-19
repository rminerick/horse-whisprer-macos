import SwiftUI

/// Card container used by the setup wizard.
struct SectionCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let subtitle: String
    let symbol: String
    let accent: Color
    @ViewBuilder let content: Content

    private var isDarkMode: Bool {
        colorScheme == .dark
    }

    private var backgroundFill: Color {
        isDarkMode ? Color.white.opacity(0.06) : Color.white.opacity(0.96)
    }

    private var borderColor: Color {
        isDarkMode ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
    }

    private var shadowColor: Color {
        isDarkMode ? Color.black.opacity(0.22) : Color.black.opacity(0.045)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(accent.opacity(0.14))
                    Image(systemName: symbol)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(accent)
                }
                .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.title3.weight(.bold))
                        .fontDesign(.rounded)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            content
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(backgroundFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(borderColor)
        )
        .shadow(color: shadowColor, radius: 16, x: 0, y: 8)
    }
}
