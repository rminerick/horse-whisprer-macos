import Foundation

/// "When I say X, write Y." Applied to every transcript before it is inserted.
struct TextReplacementRule: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id: UUID
    var heard: String
    var replacement: String

    init(id: UUID = UUID(), heard: String = "", replacement: String = "") {
        self.id = id
        self.heard = heard
        self.replacement = replacement
    }
}

enum TextReplacer {
    /// Replaces whole-word, case-insensitive matches. Rules run in order, so an
    /// earlier rule's output can be matched by a later rule.
    static func apply(_ rules: [TextReplacementRule], to text: String) -> String {
        var result = text
        for rule in rules {
            let heard = rule.heard.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !heard.isEmpty else { continue }
            // Letter/number lookarounds instead of \b so phrases that start or end
            // with punctuation ("c++") still match as whole words.
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: heard) + "(?![\\p{L}\\p{N}])"
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = expression.stringByReplacingMatches(
                in: result, options: [], range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: rule.replacement))
        }
        return result
    }
}
