import Foundation

/// A short reply suggested by the skim model. The label is the entire message
/// sent on selection; the explanation is only help text, never hidden input.
struct SkimReplyAction: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var label: String
    var explanation: String
    var refs: [String]

    /// Title case the chip without changing an agent's exact reply phrase.
    /// Preserve deliberate casing in names and acronyms such as iOS and API.
    var displayLabel: String {
        label.split(whereSeparator: \.isWhitespace).map { word in
            word.contains(where: \.isUppercase)
                ? String(word)
                : word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }

    var isValid: Bool {
        let count = label.split(whereSeparator: \.isWhitespace).count
        return (1...5).contains(count) && label.count <= 64
            && label == label.trimmingCharacters(in: .whitespacesAndNewlines)
            && !explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && explanation.count <= 240 && !id.isEmpty && !refs.isEmpty
            && !label.contains(where: { "[]`*<>|".contains($0) })
            && !(label + explanation).unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}
